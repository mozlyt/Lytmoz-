-- People & Membership Centre (HQ → Members & Staff).
-- Status (active / suspended), mentor and reporting manager per member, extra responsibilities,
-- position changes with effective dates and history, a directory, and stricter invitations.

alter table public.staff
  add column if not exists status text not null default 'active' check (status in ('active', 'suspended')),
  add column if not exists status_note text check (char_length(status_note) <= 300),
  add column if not exists status_at timestamptz,
  add column if not exists mentor uuid references public.profiles (id) on delete set null,
  add column if not exists reports_to uuid references public.profiles (id) on delete set null,
  add column if not exists responsibilities text[] not null default '{}';

alter table public.staff_invites
  add column if not exists phone text check (char_length(phone) <= 40),
  add column if not exists mentor uuid references public.profiles (id) on delete set null,
  add column if not exists team_id bigint references public.teams (id) on delete set null,
  add column if not exists responsibilities text[] not null default '{}',
  add column if not exists resent_at timestamptz,
  add column if not exists resend_count int not null default 0;

create table if not exists public.member_changes (
  id bigint generated always as identity primary key,
  profile_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null check (kind in ('joined', 'promoted', 'changed', 'transferred', 'acting', 'added', 'removed', 'suspended', 'reactivated', 'relationships')),
  position_id bigint references public.positions (id) on delete set null,
  from_position_id bigint references public.positions (id) on delete set null,
  department_id bigint references public.departments (id) on delete set null,
  from_department_id bigint references public.departments (id) on delete set null,
  effective_on date not null default current_date,
  ends_on date,
  note text check (char_length(note) <= 500),
  by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now());
create index if not exists member_changes_profile on public.member_changes (profile_id, id desc);
alter table public.member_changes enable row level security;
create policy "owner and the person read member history" on public.member_changes for select to authenticated
  using (public.is_admin() or profile_id = (select auth.uid()));

-- Suspended members keep their place but lose access.
create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path to '' as $$
  select public.is_admin() or exists (select 1 from public.staff s where s.profile_id = (select auth.uid()) and s.status = 'active');
$$;
create or replace function public.my_org_role()
returns text language sql stable security definer set search_path to '' as $$
  select case when public.is_admin() then 'owner'
    when exists (select 1 from public.staff s where s.profile_id = (select auth.uid()) and s.status = 'suspended') then 'suspended'
    when exists (select 1 from public.departments d where d.head = (select auth.uid())) then 'head'
    when exists (select 1 from public.staff s where s.profile_id = (select auth.uid())) then 'staff' end;
$$;
create or replace function public.has_permission(k text)
returns boolean language sql stable security definer set search_path to '' as $$
  select public.is_admin() or (
    exists (select 1 from public.staff s where s.profile_id = (select auth.uid()) and s.status = 'active')
    and exists (
      select 1 from public.permission_grants g
      where g.permission = k and not g.deny
        and (g.expires_at is null or g.expires_at > now())
        and (
          g.profile_id = (select auth.uid())
          or g.position_id in (select public.my_position_ids((select auth.uid())))
          or g.department_id in (
            select m.department_id from public.department_members m where m.profile_id = (select auth.uid())
            union select d.id from public.departments d where d.head = (select auth.uid()))))
    and not exists (
      select 1 from public.permission_grants g
      where g.permission = k and g.deny and g.profile_id = (select auth.uid())
        and (g.expires_at is null or g.expires_at > now())));
$$;

-- A one-person seat that is already filled, counting from a date and ignoring one person.
create or replace function public.seat_full(pos bigint, from_ date default current_date, except_ uuid default null)
returns boolean language sql stable security definer set search_path to '' as $$
  select coalesce((select p.max_holders is not null and
    (select count(*) from public.position_assignments a where a.position_id = p.id and a.profile_id is distinct from except_
       and (a.ends_on is null or a.ends_on >= from_)) >= p.max_holders
    from public.positions p where p.id = pos), false);
$$;

-- One open invitation per email; never invite an existing member; never invite into a filled seat.
create unique index if not exists staff_invites_one_open on public.staff_invites (lower(email)) where status = 'pending';
create or replace function public.staff_invite_check() returns trigger language plpgsql security definer set search_path to '' as $$
begin
  new.email := lower(trim(new.email));
  if exists (select 1 from public.staff s join public.profiles p on p.id = s.profile_id where lower(p.email) = new.email) then
    raise exception '% is already a member of Lytmoz. Change their position from their profile instead.', new.email; end if;
  if exists (select 1 from public.profiles p where lower(p.email) = new.email and p.role = 'admin') then
    raise exception 'That is the owner''s email.'; end if;
  if exists (select 1 from public.staff_invites i where lower(i.email) = new.email and i.status = 'pending' and i.expires_at > now()) then
    raise exception 'That person already has an open invitation. Use Send again in Invitations.'; end if;
  update public.staff_invites set status = 'revoked' where lower(email) = new.email and status = 'pending' and expires_at <= now();
  if new.position_id is not null and public.seat_full(new.position_id) then
    raise exception '% is already filled. Remove the current holder first if this is a replacement.', (select title from public.positions where id = new.position_id); end if;
  return new;
end $$;
create trigger staff_invite_check before insert on public.staff_invites for each row execute function public.staff_invite_check();

-- The guard lets the owner extend an open invitation; it must also allow expired pending ones to be closed by the check above.
create or replace function public.staff_invite_guard() returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if coalesce(current_setting('lytmoz.accepting_invite', true), '') = '1' then return new; end if;
  if (new.token, new.email, new.department_id, new.invited_by, new.accepted_at, new.accepted_by, new.position_id) is distinct from (old.token, old.email, old.department_id, old.invited_by, old.accepted_at, old.accepted_by, old.position_id) then
    raise exception 'An invitation cannot be changed. Revoke it and send a new one.';
  end if;
  if old.status <> 'pending' or new.status not in ('pending', 'revoked') then raise exception 'This invitation is already closed.'; end if;
  return new;
end $$;

create or replace function public.invite_resend(inv bigint)
returns void language plpgsql security definer set search_path to '' as $$
begin
  if not public.is_admin() then raise exception 'Only the owner can send invitations again.'; end if;
  update public.staff_invites set expires_at = now() + make_interval(days => coalesce(public.org_setting('invite_days')::int, 7)),
    resent_at = now(), resend_count = resend_count + 1 where id = inv and status = 'pending';
  if not found then raise exception 'This invitation is already closed.'; end if;
end $$;

create or replace function public.accept_invite_as(tok text, uid uuid)
returns json language plpgsql security definer set search_path to '' as $$
declare i public.staff_invites; p public.profiles;
begin
  select * into i from public.staff_invites where token = tok and char_length(tok) >= 40 for update;
  if not found then raise exception 'This invitation link is not valid.'; end if;
  if i.status = 'accepted' then raise exception 'This invitation has already been used.'; end if;
  if i.status = 'revoked' then raise exception 'This invitation was withdrawn. Ask Lytmoz for a new one.'; end if;
  if i.expires_at < now() then raise exception 'This invitation has expired. Ask Lytmoz to send it again.'; end if;
  select * into p from public.profiles where id = uid;
  if not found then raise exception 'Account not found.'; end if;
  if lower(p.email) <> lower(i.email) then raise exception 'This invitation is for %. Sign in with that email.', i.email; end if;
  if p.role = 'admin' then raise exception 'You are already the owner.'; end if;
  if exists (select 1 from public.staff where profile_id = uid) then raise exception 'You are already a member of Lytmoz. Ask the owner to change your position instead.'; end if;
  if i.position_id is not null and public.seat_full(i.position_id) then
    raise exception 'The % position has already been filled, so this invitation can no longer be used. Ask Lytmoz for a new one.', (select title from public.positions where id = i.position_id); end if;
  if p.role = 'client'
     and not exists (select 1 from public.projects where client_id = uid)
     and not exists (select 1 from public.organization_members where profile_id = uid) then
    update public.profiles set role = 'staff' where id = uid;
  end if;
  if i.phone is not null and coalesce(p.phone, '') = '' then update public.profiles set phone = i.phone where id = uid; end if;
  insert into public.staff (profile_id, title, added_by, mentor, reports_to, responsibilities)
  values (uid, i.title, i.invited_by, i.mentor, i.reports_to, coalesce(i.responsibilities, '{}'));
  if i.department_id is not null then
    insert into public.department_members (department_id, profile_id, kind, role_title, reports_to)
    values (i.department_id, uid, i.kind, i.title, i.reports_to)
    on conflict (department_id, profile_id) do update set kind = excluded.kind, role_title = excluded.role_title, reports_to = excluded.reports_to;
  end if;
  if i.team_id is not null and exists (select 1 from public.teams t where t.id = i.team_id and t.is_active) then
    insert into public.team_members (team_id, profile_id, role_title) values (i.team_id, uid, i.title) on conflict do nothing;
    if i.kind = 'lead' then update public.teams set leader = uid where id = i.team_id and leader is null; end if;
  end if;
  perform set_config('lytmoz.accepting_invite', '1', true);
  update public.staff_invites set status = 'accepted', accepted_at = now(), accepted_by = uid where id = i.id;
  perform set_config('lytmoz.accepting_invite', '', true);
  insert into public.member_changes (profile_id, kind, position_id, department_id, note, by)
  values (uid, 'joined', i.position_id, i.department_id, 'Accepted the invitation from ' || coalesce((select name from public.profiles where id = i.invited_by), 'Lytmoz'), i.invited_by);
  return json_build_object('ok', true,
    'department', (select name from public.departments where id = i.department_id),
    'position', (select title from public.positions where id = i.position_id));
end $$;

-- Promote, change, transfer, acting, add or remove a position. Owner only. Every change is dated and kept.
create or replace function public.member_change(person uuid, kind_ text, pos bigint default null, dept bigint default null,
  effective date default null, until date default null, note_ text default null)
returns void language plpgsql security definer set search_path to '' as $$
declare p public.positions; cur public.positions; d_from bigint; k text; eff date := coalesce(effective, current_date);
begin
  if not public.is_admin() then raise exception 'Only the owner can change positions.'; end if;
  if not exists (select 1 from public.staff where profile_id = person) then raise exception 'This person is not a member of Lytmoz.'; end if;
  if kind_ not in ('change', 'transfer', 'acting', 'add', 'remove') then raise exception 'Unknown change.'; end if;
  if eff < current_date - 31 then raise exception 'The effective date can be at most a month in the past.'; end if;
  if kind_ in ('change', 'acting', 'add', 'remove') then
    select * into p from public.positions where id = pos;
    if not found then raise exception 'Choose a position.'; end if;
  end if;
  if kind_ in ('change', 'acting', 'add') then
    if not p.is_active then raise exception '% is no longer in use.', p.title; end if;
    if p.code in ('dept_head', 'team_lead') then raise exception '% is given automatically to whoever heads a department or leads a team.', p.title; end if;
    if public.seat_full(p.id, eff, person) then raise exception '% is already filled. Remove the current holder first.', p.title; end if;
  end if;
  if kind_ = 'acting' and (until is null or until < eff) then raise exception 'Give the date the acting position ends.'; end if;
  select pp.* into cur from public.position_assignments a join public.positions pp on pp.id = a.position_id
   where a.profile_id = person and not a.is_acting and a.starts_on <= current_date and (a.ends_on is null or a.ends_on >= current_date)
   order by pp.level limit 1;

  if kind_ = 'change' then
    delete from public.position_assignments where profile_id = person and not is_acting and starts_on >= eff;
    update public.position_assignments set ends_on = eff - 1 where profile_id = person and not is_acting and (ends_on is null or ends_on >= eff);
    insert into public.position_assignments (position_id, profile_id, starts_on, assigned_by) values (p.id, person, eff, auth.uid());
    update public.staff set title = p.title where profile_id = person;
    k := case when cur.id is not null and p.level < cur.level then 'promoted' else 'changed' end;
  elsif kind_ in ('add', 'acting') then
    if exists (select 1 from public.position_assignments a where a.profile_id = person and a.position_id = p.id and (a.ends_on is null or a.ends_on >= eff)) then
      raise exception 'They already hold %.', p.title; end if;
    insert into public.position_assignments (position_id, profile_id, is_acting, starts_on, ends_on, assigned_by)
    values (p.id, person, kind_ = 'acting', eff, case when kind_ = 'acting' then until end, auth.uid());
    k := case when kind_ = 'acting' then 'acting' else 'added' end;
  elsif kind_ = 'remove' then
    if not exists (select 1 from public.position_assignments a where a.profile_id = person and a.position_id = p.id and (a.ends_on is null or a.ends_on >= eff)) then
      raise exception 'They do not hold %.', p.title; end if;
    delete from public.position_assignments where profile_id = person and position_id = p.id and starts_on >= eff;
    update public.position_assignments set ends_on = eff - 1 where profile_id = person and position_id = p.id and (ends_on is null or ends_on >= eff);
    k := 'removed';
  end if;

  if kind_ = 'transfer' or (kind_ = 'change' and dept is not null) then
    if dept is null or not exists (select 1 from public.departments where id = dept and is_active) then raise exception 'Choose a department.'; end if;
    if exists (select 1 from public.departments d where d.head = person and d.id <> dept) then
      raise exception 'They head %. Appoint a new head there first.', (select name from public.departments d where d.head = person and d.id <> dept limit 1); end if;
    select department_id into d_from from public.department_members where profile_id = person and department_id <> dept limit 1;
    insert into public.department_members (department_id, profile_id, kind, role_title)
      select dept, person, coalesce((select m.kind from public.department_members m where m.profile_id = person limit 1), 'member'), coalesce(p.title, (select s.title from public.staff s where s.profile_id = person))
      on conflict (department_id, profile_id) do nothing;
    delete from public.department_members where profile_id = person and department_id <> dept;
    delete from public.team_members tm using public.teams t where t.id = tm.team_id and tm.profile_id = person and t.department_id is distinct from dept;
    update public.teams set leader = null where leader = person and department_id is distinct from dept;
    if kind_ = 'transfer' then k := 'transferred'; end if;
  end if;

  insert into public.member_changes (profile_id, kind, position_id, from_position_id, department_id, from_department_id, effective_on, ends_on, note)
  values (person, k, case when kind_ = 'transfer' then null else p.id end, case when kind_ = 'change' then cur.id end,
    case when kind_ = 'transfer' or (kind_ = 'change' and dept is not null) then dept end, d_from, eff, until, nullif(trim(note_), ''));
end $$;

create or replace function public.member_set_status(person uuid, active boolean, note_ text default null)
returns void language plpgsql security definer set search_path to '' as $$
begin
  if not public.is_admin() then raise exception 'Only the owner can suspend or reactivate members.'; end if;
  update public.staff set status = case when active then 'active' else 'suspended' end, status_note = nullif(trim(note_), ''), status_at = now()
   where profile_id = person and status <> case when active then 'active' else 'suspended' end;
  if not found then raise exception 'Nothing to change.'; end if;
  insert into public.member_changes (profile_id, kind, note) values (person, case when active then 'reactivated' else 'suspended' end, nullif(trim(note_), ''));
end $$;

create or replace function public.member_set_links(person uuid, mentor_ uuid, reports_ uuid, responsibilities_ text[])
returns void language plpgsql security definer set search_path to '' as $$
begin
  if not public.is_admin() then raise exception 'Only the owner can change this.'; end if;
  if person in (mentor_, reports_) then raise exception 'Someone cannot mentor or supervise themselves.'; end if;
  if (mentor_ is not null and not public.is_staff_profile(mentor_)) or (reports_ is not null and not public.is_staff_profile(reports_)) then
    raise exception 'Choose someone at Lytmoz.'; end if;
  update public.staff set mentor = mentor_, reports_to = reports_, responsibilities = coalesce(responsibilities_, '{}') where profile_id = person;
  if not found then raise exception 'This person is not a member of Lytmoz.'; end if;
  update public.department_members set reports_to = reports_ where profile_id = person;
  insert into public.member_changes (profile_id, kind, note) values (person, 'relationships',
    concat_ws(' · ', 'Reports to ' || (select name from public.profiles where id = reports_), 'Mentor ' || (select name from public.profiles where id = mentor_),
      case when array_length(responsibilities_, 1) > 0 then 'Also: ' || array_to_string(responsibilities_, ', ') end));
end $$;

-- Everyone at Lytmoz with their place in it. Email and phone only for the owner and the person themselves.
create or replace function public.org_directory()
returns json language plpgsql stable security definer set search_path to '' as $$
declare full_ boolean := public.is_admin(); me uuid := auth.uid();
begin
  if not public.is_staff() then raise exception 'Lytmoz staff only'; end if;
  return (select coalesce(json_agg(x order by x.rank, x.name), '[]'::json) from (
    select p.id, p.name, case when full_ or p.id = me then p.email end as email, case when full_ or p.id = me then p.phone end as phone,
      true as owner, 'active' as status, null::text as status_note, 0 as rank, 'Owner' as title, p.created_at as joined,
      '[]'::json as positions, '[]'::json as departments, '[]'::json as teams, null::json as mentor, null::json as reports_to, '{}'::text[] as responsibilities
    from public.profiles p where p.role = 'admin'
    union all
    select p.id, p.name, case when full_ or p.id = me then p.email end, case when full_ or p.id = me then p.phone end,
      false, s.status, case when full_ then s.status_note end,
      coalesce((select min(pp.level) from public.position_assignments a join public.positions pp on pp.id = a.position_id
        where a.profile_id = p.id and a.starts_on <= current_date and (a.ends_on is null or a.ends_on >= current_date)), 9),
      s.title, s.added_at,
      (select coalesce(json_agg(json_build_object('id', pp.id, 'title', pp.title, 'level', pp.level, 'acting', a.is_acting, 'starts_on', a.starts_on, 'ends_on', a.ends_on) order by pp.level), '[]'::json)
         from public.position_assignments a join public.positions pp on pp.id = a.position_id
        where a.profile_id = p.id and a.starts_on <= current_date and (a.ends_on is null or a.ends_on >= current_date)),
      (select coalesce(json_agg(json_build_object('id', d.id, 'name', d.name, 'head', d.head = p.id, 'kind', m.kind)), '[]'::json)
         from public.departments d left join public.department_members m on m.department_id = d.id and m.profile_id = p.id
        where d.head = p.id or m.profile_id is not null),
      (select coalesce(json_agg(json_build_object('id', t.id, 'name', t.name, 'lead', t.leader = p.id)), '[]'::json)
         from public.teams t where t.is_active and (t.leader = p.id or exists (select 1 from public.team_members tm where tm.team_id = t.id and tm.profile_id = p.id))),
      (select json_build_object('id', mp.id, 'name', mp.name) from public.profiles mp where mp.id = s.mentor),
      (select json_build_object('id', rp.id, 'name', rp.name) from public.profiles rp where rp.id = coalesce(s.reports_to,
         (select m.reports_to from public.department_members m where m.profile_id = p.id and m.reports_to is not null limit 1),
         (select d.head from public.department_members m join public.departments d on d.id = m.department_id where m.profile_id = p.id and d.head <> p.id limit 1))),
      s.responsibilities
    from public.staff s join public.profiles p on p.id = s.profile_id where p.role <> 'admin') x);
end $$;

-- What one person can do and see, with their history. For the owner and the person themselves.
create or replace function public.member_profile(person uuid)
returns json language plpgsql stable security definer set search_path to '' as $$
begin
  if not (public.is_admin() or person = auth.uid()) then raise exception 'Only the owner can see this.'; end if;
  return json_build_object(
    'permissions', (select coalesce(json_agg(distinct g.permission), '[]'::json) from public.permission_grants g
      where not g.deny and (g.expires_at is null or g.expires_at > now())
        and (g.profile_id = person or g.position_id in (select public.my_position_ids(person))
          or g.department_id in (select m.department_id from public.department_members m where m.profile_id = person union select d.id from public.departments d where d.head = person))
        and not exists (select 1 from public.permission_grants x where x.deny and x.permission = g.permission and x.profile_id = person and (x.expires_at is null or x.expires_at > now()))),
    'blocks', (select coalesce(json_agg(distinct b), '[]'::json) from public.positions pp, unnest(pp.blocks) b where pp.id in (select public.my_position_ids(person))),
    'assignments', (select coalesce(json_agg(json_build_object('title', pp.title, 'acting', a.is_acting, 'starts_on', a.starts_on, 'ends_on', a.ends_on) order by a.starts_on desc, a.id desc), '[]'::json)
      from public.position_assignments a join public.positions pp on pp.id = a.position_id where a.profile_id = person),
    'changes', (select coalesce(json_agg(json_build_object('kind', c.kind, 'position', (select title from public.positions where id = c.position_id),
        'from_position', (select title from public.positions where id = c.from_position_id), 'department', (select name from public.departments where id = c.department_id),
        'from_department', (select name from public.departments where id = c.from_department_id), 'effective_on', c.effective_on, 'ends_on', c.ends_on,
        'note', c.note, 'by', (select name from public.profiles where id = c.by), 'created_at', c.created_at) order by c.id desc), '[]'::json)
      from public.member_changes c where c.profile_id = person));
end $$;

grant execute on function public.seat_full(bigint, date, uuid), public.invite_resend(bigint), public.member_change(uuid, text, bigint, bigint, date, date, text),
  public.member_set_status(uuid, boolean, text), public.member_set_links(uuid, uuid, uuid, text[]), public.org_directory(), public.member_profile(uuid) to authenticated;
