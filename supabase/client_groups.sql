-- Client groups (portal → My Team → Groups). Members see only the group's messages and the files shared in its chat.
create table if not exists public.chat_groups (
  id bigint generated always as identity primary key,
  name text not null check (char_length(trim(name)) between 2 and 80),
  purpose text check (char_length(purpose) <= 300),
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  last_at timestamptz not null default now());
create table if not exists public.chat_group_members (
  group_id bigint not null references public.chat_groups (id) on delete cascade,
  profile_id uuid not null references public.profiles (id) on delete cascade,
  role text not null default 'member' check (role in ('admin', 'member')),
  added_by uuid references public.profiles (id) on delete set null default auth.uid(),
  joined_at timestamptz not null default now(),
  last_read_id bigint not null default 0,
  primary key (group_id, profile_id));
create index if not exists chat_group_members_profile on public.chat_group_members (profile_id);
create table if not exists public.chat_group_messages (
  id bigint generated always as identity primary key,
  group_id bigint not null references public.chat_groups (id) on delete cascade,
  sender uuid references public.profiles (id) on delete set null default auth.uid(),
  text text check (char_length(text) <= 4000),
  file_path text check (file_path is null or char_length(file_path) <= 400),
  file_name text check (file_name is null or char_length(file_name) <= 200),
  file_size bigint, file_type text check (file_type is null or char_length(file_type) <= 120),
  created_at timestamptz not null default now(),
  check (coalesce(char_length(trim(text)), 0) > 0 or file_path is not null));
create index if not exists chat_group_messages_group on public.chat_group_messages (group_id, id desc);

create or replace function public.in_group(g bigint)
returns boolean language sql stable security definer set search_path to '' as $$
  select exists (select 1 from public.chat_group_members m where m.group_id = g and m.profile_id = (select auth.uid()));
$$;
create or replace function public.group_admin(g bigint)
returns boolean language sql stable security definer set search_path to '' as $$
  select exists (select 1 from public.chat_group_members m where m.group_id = g and m.profile_id = (select auth.uid()) and m.role = 'admin');
$$;
create or replace function public.in_group_folder(f text)
returns boolean language sql stable security definer set search_path to '' as $$
  select case when f ~ '^[0-9]{1,18}$' then public.in_group(f::bigint) else false end;
$$;
grant execute on function public.in_group(bigint), public.group_admin(bigint), public.in_group_folder(text) to authenticated;

alter table public.chat_groups enable row level security;
alter table public.chat_group_members enable row level security;
alter table public.chat_group_messages enable row level security;
create policy "members see their groups" on public.chat_groups for select to authenticated using (public.in_group(id));
create policy "members see who is in their groups" on public.chat_group_members for select to authenticated using (public.in_group(group_id));
create policy "members mark their own reading" on public.chat_group_members for update to authenticated using (profile_id = (select auth.uid())) with check (profile_id = (select auth.uid()));
create policy "members read group messages" on public.chat_group_messages for select to authenticated using (public.in_group(group_id));
create policy "members write in their groups" on public.chat_group_messages for insert to authenticated with check (
  sender = (select auth.uid()) and public.in_group(group_id) and (file_path is null or file_path like group_id::text || '/%'));
create or replace function public.group_bump() returns trigger language plpgsql security definer set search_path to '' as $$
begin update public.chat_groups set last_at = new.created_at where id = new.group_id; return new; end $$;
create trigger group_bump after insert on public.chat_group_messages for each row execute function public.group_bump();
create or replace function public.group_member_guard() returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if (to_jsonb(new) - 'last_read_id') is distinct from (to_jsonb(old) - 'last_read_id') and not coalesce(current_setting('lytmoz.group_admin', true), '') = '1' then
    raise exception 'Only the group admin can change roles.'; end if;
  return new;
end $$;
create trigger group_member_guard before update on public.chat_group_members for each row execute function public.group_member_guard();

create or replace function public.group_candidates(g bigint default null)
returns json language sql stable security definer set search_path to '' as $$
  select coalesce(json_agg(x order by x.online desc, x.today desc, x.name), '[]'::json) from (
    select p.id, p.name,
      coalesce((select o.name from public.organization_members m join public.organizations o on o.id = m.organization_id where m.profile_id = p.id and m.role <> 'guest' limit 1), p.company) as business,
      coalesce(p.last_seen > now() - interval '2 minutes', false) as online,
      coalesce(p.last_seen > now() - interval '24 hours', false) as today
    from public.profiles p
    where p.role = 'client' and p.chat_visible and p.id <> (select auth.uid())
      and not exists (select 1 from public.staff s where s.profile_id = p.id)
      and not public.chat_blocked((select auth.uid()), p.id)
      and (g is null or not exists (select 1 from public.chat_group_members m where m.group_id = g and m.profile_id = p.id))) x;
$$;
create or replace function public.group_add_people(g bigint, people uuid[])
returns int language plpgsql security definer set search_path to '' as $$
declare pid uuid; n int := 0;
begin
  if not public.group_admin(g) then raise exception 'Only a group admin can add people.'; end if;
  foreach pid in array coalesce(people, '{}') loop
    if not exists (select 1 from public.profiles p where p.id = pid and p.role = 'client' and p.chat_visible and not exists (select 1 from public.staff s where s.profile_id = pid))
       or public.chat_blocked((select auth.uid()), pid) then
      raise exception 'One of the people you chose is no longer available. Refresh the list and try again.'; end if;
    insert into public.chat_group_members (group_id, profile_id, role) values (g, pid, 'member') on conflict do nothing;
    if found then n := n + 1; end if;
  end loop;
  return n;
end $$;
create or replace function public.group_create(name_ text, purpose_ text default null, people uuid[] default '{}')
returns bigint language plpgsql security definer set search_path to '' as $$
declare g bigint;
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'client') then raise exception 'Groups are for client accounts.'; end if;
  insert into public.chat_groups (name, purpose) values (trim(name_), nullif(trim(purpose_), '')) returning id into g;
  insert into public.chat_group_members (group_id, profile_id, role) values (g, auth.uid(), 'admin');
  if coalesce(array_length(people, 1), 0) > 0 then perform public.group_add_people(g, people); end if;
  return g;
end $$;
create or replace function public.group_remove(g bigint, person uuid)
returns void language plpgsql security definer set search_path to '' as $$
begin
  if person = auth.uid() then
    if public.group_admin(g) and (select count(*) from public.chat_group_members where group_id = g and role = 'admin') = 1
       and (select count(*) from public.chat_group_members where group_id = g) > 1 then
      perform set_config('lytmoz.group_admin', '1', true);
      update public.chat_group_members set role = 'admin' where group_id = g and profile_id = (select profile_id from public.chat_group_members where group_id = g and profile_id <> person order by joined_at limit 1);
      perform set_config('lytmoz.group_admin', '', true);
    end if;
  elsif not public.group_admin(g) then raise exception 'Only a group admin can remove people.';
  end if;
  delete from public.chat_group_members where group_id = g and profile_id = person;
end $$;
create or replace function public.group_set_admin(g bigint, person uuid, on_ boolean)
returns void language plpgsql security definer set search_path to '' as $$
begin
  if not public.group_admin(g) then raise exception 'Only a group admin can do this.'; end if;
  if not on_ and (select count(*) from public.chat_group_members where group_id = g and role = 'admin') = 1 and (select role from public.chat_group_members where group_id = g and profile_id = person) = 'admin' then raise exception 'A group needs at least one admin.'; end if;
  perform set_config('lytmoz.group_admin', '1', true);
  update public.chat_group_members set role = case when on_ then 'admin' else 'member' end where group_id = g and profile_id = person;
  perform set_config('lytmoz.group_admin', '', true);
end $$;
create or replace function public.group_update(g bigint, name_ text, purpose_ text)
returns void language plpgsql security definer set search_path to '' as $$
begin
  if not public.group_admin(g) then raise exception 'Only a group admin can change the group.'; end if;
  update public.chat_groups set name = trim(name_), purpose = nullif(trim(purpose_), '') where id = g;
end $$;
create or replace function public.group_list()
returns json language sql stable security definer set search_path to '' as $$
  select coalesce(json_agg(x order by x.last_at desc), '[]'::json) from (
    select g.id, g.name, g.purpose, g.last_at, me.role as my_role,
      (select count(*) from public.chat_group_members m where m.group_id = g.id) as members,
      (select json_build_object('text', coalesce(m.text, 'File: ' || m.file_name), 'sender', p.name, 'mine', m.sender = (select auth.uid())) from public.chat_group_messages m left join public.profiles p on p.id = m.sender where m.group_id = g.id order by m.id desc limit 1) as last,
      (select count(*) from public.chat_group_messages m where m.group_id = g.id and m.id > me.last_read_id and m.sender is distinct from (select auth.uid())) as unread
    from public.chat_groups g join public.chat_group_members me on me.group_id = g.id and me.profile_id = (select auth.uid())) x;
$$;
create or replace function public.group_people(g bigint)
returns json language sql stable security definer set search_path to '' as $$
  select case when not public.in_group(g) then '[]'::json else (select coalesce(json_agg(json_build_object('id', p.id, 'name', p.name, 'role', m.role,
    'online', coalesce(p.last_seen > now() - interval '2 minutes', false) and p.chat_visible) order by m.role, p.name), '[]'::json)
    from public.chat_group_members m join public.profiles p on p.id = m.profile_id where m.group_id = g) end;
$$;
grant execute on function public.group_candidates(bigint), public.group_add_people(bigint, uuid[]), public.group_create(text, text, uuid[]), public.group_remove(bigint, uuid), public.group_set_admin(bigint, uuid, boolean), public.group_update(bigint, text, text), public.group_list(), public.group_people(bigint) to authenticated;
alter publication supabase_realtime add table public.chat_group_messages;
-- Files shared inside a group chat: private bucket, readable and writable only by that group's members.
insert into storage.buckets (id, name, public, file_size_limit) values ('group-files', 'group-files', false, 20971520) on conflict (id) do nothing;
create policy "group members read group files" on storage.objects for select to authenticated
  using (bucket_id = 'group-files' and public.in_group_folder((storage.foldername(name))[1]));
create policy "group members upload group files" on storage.objects for insert to authenticated
  with check (bucket_id = 'group-files' and public.in_group_folder((storage.foldername(name))[1]));
