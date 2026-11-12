-- Milestone 2: assigning work, submissions, corrections and approvals.

-- Department heads ask for invitations only into their own department (policy already allows that).
delete from public.permission_grants where permission = 'invites.request' and position_id = (select id from public.positions where code = 'dept_head');

-- Who may direct (assign) or review a person's work
create or replace function public.supervises(target uuid, k text)
returns boolean language sql stable security definer set search_path to '' as $$
  select target is distinct from (select auth.uid())
    and exists (select 1 from public.staff s where s.profile_id = target)
    and (public.is_admin() or (public.has_permission(k)
    and (
      exists (select 1 from public.positions p where p.id in (select public.my_position_ids((select auth.uid()))) and p.level <= 2)
      or (public.authority(case when k = 'work.assign' then 'head_assign_work' else 'head_review_work' end)
          and exists (select 1 from public.departments d join public.department_members m on m.department_id = d.id
                      where d.head = (select auth.uid()) and m.profile_id = target))
      or exists (select 1 from public.department_members m where m.profile_id = target and m.reports_to = (select auth.uid()))
      or exists (select 1 from public.teams t join public.team_members tm on tm.team_id = t.id
                 where t.leader = (select auth.uid()) and tm.profile_id = target))));
$$;
revoke execute on function public.supervises(uuid, text) from public, anon;

create table if not exists public.work_items (
  id bigint generated always as identity primary key,
  title text not null check (char_length(trim(title)) between 2 and 160),
  instructions text check (char_length(instructions) <= 4000),
  assignee uuid not null references public.profiles (id) on delete cascade,
  assigned_by uuid default auth.uid() references public.profiles (id) on delete set null,
  reviewer uuid references public.profiles (id) on delete set null,
  department_id bigint references public.departments (id) on delete set null,
  project_id bigint references public.projects (id) on delete set null,
  priority text not null default 'normal' check (priority in ('low', 'normal', 'high', 'urgent')),
  due_on date,
  status text not null default 'assigned' check (status in ('assigned', 'in_progress', 'submitted', 'returned', 'approved', 'cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  started_at timestamptz, submitted_at timestamptz, approved_at timestamptz);
create index if not exists work_items_assignee on public.work_items (assignee, status);
create index if not exists work_items_assigned_by on public.work_items (assigned_by);
create index if not exists work_items_reviewer on public.work_items (reviewer);

create table if not exists public.work_events (
  id bigint generated always as identity primary key,
  item_id bigint not null references public.work_items (id) on delete cascade,
  actor uuid references public.profiles (id) on delete set null default auth.uid(),
  kind text not null check (kind in ('assigned', 'started', 'submitted', 'returned', 'approved', 'comment', 'cancelled')),
  text text check (char_length(text) <= 4000),
  link text check (link is null or (link ~ '^https?://' and char_length(link) <= 500)),
  created_at timestamptz not null default now());
create index if not exists work_events_item on public.work_events (item_id, id);

create or replace function public.can_review_work(w public.work_items)
returns boolean language sql stable security definer set search_path to '' as $$
  select w.assignee is distinct from (select auth.uid()) and (public.is_admin() or w.reviewer = (select auth.uid()) or w.assigned_by = (select auth.uid()) or public.supervises(w.assignee, 'work.review'));
$$;
create or replace function public.can_see_work(item bigint)
returns boolean language sql stable security definer set search_path to '' as $$
  select exists (select 1 from public.work_items w where w.id = item and (
    public.is_admin() or w.assignee = (select auth.uid()) or w.assigned_by = (select auth.uid()) or w.reviewer = (select auth.uid())
    or public.supervises(w.assignee, 'work.review')));
$$;
revoke execute on function public.can_review_work(public.work_items) from public, anon;
revoke execute on function public.can_see_work(bigint) from public, anon;

alter table public.work_items enable row level security;
alter table public.work_events enable row level security;
create policy "see work you are part of" on public.work_items for select to authenticated using ((select public.can_see_work(id)));
create policy "see the history of work you can see" on public.work_events for select to authenticated using ((select public.can_see_work(item_id)));
-- No insert/update/delete policies: work changes only through work_assign and work_act below.

create trigger log_work_items after insert or update or delete on public.work_items for each row execute function public.log_activity();

create or replace function public.work_assign(assignee_ uuid, title_ text, instructions_ text default null, due_ date default null,
  priority_ text default 'normal', project_ bigint default null, reviewer_ uuid default null)
returns bigint language plpgsql security definer set search_path to '' as $$
declare wid bigint; dep bigint;
begin
  if not public.supervises(assignee_, 'work.assign') then raise exception 'You cannot assign work to this person.'; end if;
  if due_ is not null and due_ < current_date then raise exception 'The due date is in the past.'; end if;
  select m.department_id into dep from public.department_members m where m.profile_id = assignee_ order by m.added_at limit 1;
  insert into public.work_items (title, instructions, assignee, assigned_by, reviewer, department_id, project_id, priority, due_on)
  values (trim(title_), nullif(trim(instructions_), ''), assignee_, auth.uid(), coalesce(reviewer_, auth.uid()), dep, project_, coalesce(priority_, 'normal'), due_)
  returning id into wid;
  insert into public.work_events (item_id, actor, kind, text) values (wid, auth.uid(), 'assigned', nullif(trim(instructions_), ''));
  return wid;
end $$;
revoke execute on function public.work_assign(uuid, text, text, date, text, bigint, uuid) from public, anon;

create or replace function public.work_act(item bigint, act text, note text default null, link_ text default null)
returns text language plpgsql security definer set search_path to '' as $$
declare w public.work_items; me uuid := auth.uid(); n text := nullif(trim(note), ''); l text := nullif(trim(link_), '');
begin
  select * into w from public.work_items where id = item for update;
  if not found or not public.can_see_work(item) then raise exception 'Task not found.'; end if;
  if act = 'start' then
    if w.assignee <> me or w.status not in ('assigned', 'returned') then raise exception 'This task cannot be started now.'; end if;
    update public.work_items set status = 'in_progress', started_at = coalesce(started_at, now()), updated_at = now() where id = item;
  elsif act = 'submit' then
    if w.assignee <> me or w.status not in ('assigned', 'in_progress', 'returned') then raise exception 'This task cannot be submitted now.'; end if;
    if n is null and l is null then raise exception 'Describe what you did or add a link to the work.'; end if;
    update public.work_items set status = 'submitted', submitted_at = now(), started_at = coalesce(started_at, now()), updated_at = now() where id = item;
  elsif act in ('approve', 'return') then
    if w.status <> 'submitted' then raise exception 'Only submitted work can be reviewed.'; end if;
    if not public.can_review_work(w) then raise exception 'You cannot review this work.'; end if;
    if act = 'return' and n is null then raise exception 'Say what needs correcting.'; end if;
    update public.work_items set status = case when act = 'approve' then 'approved' else 'returned' end,
      approved_at = case when act = 'approve' then now() end, updated_at = now() where id = item;
  elsif act = 'cancel' then
    if not (public.is_admin() or w.assigned_by = me) or w.status = 'approved' then raise exception 'You cannot cancel this task.'; end if;
    update public.work_items set status = 'cancelled', updated_at = now() where id = item;
  elsif act = 'comment' then
    if n is null then raise exception 'Write a comment.'; end if;
  else raise exception 'Unknown action.';
  end if;
  insert into public.work_events (item_id, actor, kind, text, link)
  values (item, me, case act when 'start' then 'started' when 'submit' then 'submitted' when 'approve' then 'approved' when 'return' then 'returned' when 'cancel' then 'cancelled' else 'comment' end, n, l);
  return (select status from public.work_items where id = item);
end $$;
revoke execute on function public.work_act(bigint, text, text, text) from public, anon;

create or replace function public.my_directs()
returns json language sql stable security definer set search_path to '' as $$
  select coalesce(json_agg(json_build_object('id', p.id, 'name', p.name, 'title', s.title) order by p.name), '[]'::json)
  from public.staff s join public.profiles p on p.id = s.profile_id
  where p.id <> (select auth.uid()) and public.supervises(p.id, 'work.assign');
$$;
revoke execute on function public.my_directs() from public, anon;
grant execute on function public.supervises(uuid, text), public.can_review_work(public.work_items), public.can_see_work(bigint),
  public.work_assign(uuid, text, text, date, text, bigint, uuid), public.work_act(bigint, text, text, text), public.my_directs() to authenticated;
