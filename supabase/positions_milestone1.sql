-- Milestone 1: position catalogue, position workspaces, position permissions, owner-approved invitations.

-- 1. Catalogue columns -------------------------------------------------------
alter table public.positions
  add column if not exists code text,
  add column if not exists summary text check (char_length(summary) <= 300),
  add column if not exists deliverables text check (char_length(deliverables) <= 2000),
  add column if not exists blocks text[] not null default '{}';
create unique index if not exists positions_code_key on public.positions (code) where code is not null;

alter table public.permission_grants add column if not exists deny boolean not null default false;
alter table public.staff_invites add column if not exists position_id bigint references public.positions (id) on delete set null;

-- 2. New permissions ---------------------------------------------------------
insert into public.org_permissions (key, description) values
  ('reports.view', 'See company figures: clients, projects, income and what is due.'),
  ('finance.view', 'See payments, invoices and subscriptions.'),
  ('finance.approve', 'Confirm or reject payments that clients report.'),
  ('clients.view', 'See clients, projects, service and change requests, websites and files.'),
  ('support.view', 'Read client support conversations.'),
  ('support.reply', 'Reply to clients in Support.'),
  ('consultations.view', 'See consultation requests sent from the website.'),
  ('consultations.manage', 'Update the status of consultation requests.'),
  ('invites.request', 'Ask the owner to invite a new person. Only the owner issues invitation links.')
on conflict (key) do update set description = excluded.description;

-- 3. Who holds which position (assignments + automatic head / team leader) ---
create or replace function public.my_position_ids(uid uuid default auth.uid())
returns setof bigint language sql stable security definer set search_path to '' as $$
  select a.position_id from public.position_assignments a join public.positions p on p.id = a.position_id and p.is_active
   where a.profile_id = uid and a.starts_on <= current_date and (a.ends_on is null or a.ends_on >= current_date)
  union
  select p.id from public.positions p where p.is_active and p.code = 'dept_head'
     and exists (select 1 from public.departments d where d.head = uid and d.is_active)
  union
  select p.id from public.positions p where p.is_active and p.code = 'team_lead'
     and exists (select 1 from public.teams t where t.leader = uid and t.is_active);
$$;
revoke execute on function public.my_position_ids(uuid) from public, anon;

create or replace function public.has_permission(k text)
returns boolean language sql stable security definer set search_path to '' as $$
  select public.is_admin() or (
    exists (
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

-- 4. What a signed-in staff member's workspace is made of -------------------
create or replace function public.my_workspace()
returns json language plpgsql stable security definer set search_path to '' as $$
declare uid uuid := auth.uid();
begin
  if not public.is_staff() then raise exception 'Lytmoz staff only'; end if;
  return json_build_object(
    'positions', (select coalesce(json_agg(json_build_object(
        'id', p.id, 'code', p.code, 'title', p.title, 'level', p.level, 'summary', p.summary,
        'responsibilities', p.responsibilities, 'deliverables', p.deliverables, 'blocks', p.blocks,
        'department', (select d.name from public.departments d where d.id = p.department_id),
        'reports_to', (select r.title from public.positions r where r.id = p.reports_to_position_id),
        'acting', exists (select 1 from public.position_assignments a where a.position_id = p.id and a.profile_id = uid and a.is_acting))
        order by p.level, p.id), '[]'::json)
      from public.positions p where p.id in (select public.my_position_ids(uid))),
    'permissions', (select coalesce(json_agg(k.key order by k.key), '[]'::json) from public.org_permissions k where public.has_permission(k.key)));
end $$;
revoke execute on function public.my_workspace() from public, anon;
grant execute on function public.my_workspace() to authenticated;

-- Company figures for anyone allowed to see them
do $$ declare d text; begin
  d := pg_get_functiondef('public.admin_overview'::regproc);
  d := replace(d, 'if not public.is_admin() then raise exception ''Admins only''', 'if not public.has_permission(''reports.view'') then raise exception ''You do not have access to company figures''');
  execute d;
end $$;

-- 5. Invitation requests: HR and heads ask, only the owner issues the link ---
drop policy if exists "create invitations" on public.staff_invites;
drop policy if exists "manage invitations" on public.staff_invites;
drop policy if exists "read invitations" on public.staff_invites;
create policy "owner creates invitations" on public.staff_invites for insert to authenticated
  with check ((select public.is_admin()) and invited_by = (select auth.uid()) and status = 'pending' and accepted_at is null and accepted_by is null);
create policy "owner manages invitations" on public.staff_invites for update to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));
create policy "owner reads invitations" on public.staff_invites for select to authenticated using ((select public.is_admin()));
update public.authority_settings set rules = rules - 'head_invite' where id = 1;

create table if not exists public.invite_requests (
  id bigint generated always as identity primary key,
  name text not null check (char_length(trim(name)) between 2 and 120),
  email text not null check (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' and char_length(email) <= 200),
  department_id bigint not null references public.departments (id) on delete cascade,
  position_id bigint references public.positions (id) on delete set null,
  kind text not null default 'member' check (kind in ('member', 'lead', 'mentor')),
  title text check (char_length(title) <= 80),
  reports_to uuid references public.profiles (id) on delete set null,
  note text check (char_length(note) <= 1000),
  requested_by uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  status text not null default 'requested' check (status in ('requested', 'approved', 'declined', 'withdrawn')),
  decided_by uuid references public.profiles (id) on delete set null,
  decided_at timestamptz,
  decision_note text check (char_length(decision_note) <= 500),
  invite_id bigint references public.staff_invites (id) on delete set null,
  created_at timestamptz not null default now());
create unique index if not exists invite_requests_one_open on public.invite_requests (lower(email), department_id) where status = 'requested';
create index if not exists invite_requests_requested_by on public.invite_requests (requested_by);
alter table public.invite_requests enable row level security;
create policy "read invite requests" on public.invite_requests for select to authenticated
  using ((select public.is_admin()) or requested_by = (select auth.uid()) or (select public.has_permission('members.manage')));
create policy "ask for an invitation" on public.invite_requests for insert to authenticated
  with check (requested_by = (select auth.uid()) and status = 'requested' and decided_by is null and invite_id is null
    and email = lower(trim(email))
    and ((select public.has_permission('invites.request')) or public.is_dept_head(department_id)));
create trigger log_invite_requests after insert or update or delete on public.invite_requests for each row execute function public.log_activity();

create or replace function public.decide_invite_request(req bigint, approve boolean, note_ text default null)
returns json language plpgsql security definer set search_path to '' as $$
declare r public.invite_requests; inv public.staff_invites;
begin
  if not public.is_admin() then raise exception 'Only the owner can approve invitations.'; end if;
  select * into r from public.invite_requests where id = req for update;
  if not found then raise exception 'Request not found.'; end if;
  if r.status <> 'requested' then raise exception 'This request has already been decided.'; end if;
  if approve then
    insert into public.staff_invites (name, email, department_id, kind, title, reports_to, invited_by, position_id)
    values (r.name, r.email, r.department_id, r.kind, r.title, r.reports_to, auth.uid(), r.position_id) returning * into inv;
  end if;
  update public.invite_requests set status = case when approve then 'approved' else 'declined' end,
    decided_by = auth.uid(), decided_at = now(), decision_note = nullif(trim(note_), ''), invite_id = inv.id where id = req;
  return json_build_object('ok', true, 'invite_id', inv.id);
end $$;
revoke execute on function public.decide_invite_request(bigint, boolean, text) from public, anon;

create or replace function public.withdraw_invite_request(req bigint)
returns void language plpgsql security definer set search_path to '' as $$
begin
  update public.invite_requests set status = 'withdrawn' where id = req and status = 'requested'
    and (requested_by = auth.uid() or public.is_admin());
  if not found then raise exception 'This request cannot be withdrawn.'; end if;
end $$;
revoke execute on function public.withdraw_invite_request(bigint) from public, anon;

-- When an invitation with a position is accepted, the person takes that position
create or replace function public.invite_position_assign()
returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if new.status = 'accepted' and old.status <> 'accepted' and new.position_id is not null and new.accepted_by is not null
     and not exists (select 1 from public.position_assignments a where a.position_id = new.position_id and a.profile_id = new.accepted_by and (a.ends_on is null or a.ends_on >= current_date)) then
    insert into public.position_assignments (position_id, profile_id, assigned_by) values (new.position_id, new.accepted_by, new.invited_by);
  end if;
  return new;
end $$;
drop trigger if exists invite_position_assign on public.staff_invites;
create trigger invite_position_assign after update on public.staff_invites for each row execute function public.invite_position_assign();

-- 6. Data access by permission (read) ----------------------------------------
create policy "staff with finance access read payments" on public.payments for select to authenticated using ((select public.has_permission('finance.view')));
create policy "staff with finance access read invoices" on public.invoices for select to authenticated using ((select public.has_permission('finance.view')));
create policy "staff with finance access read subscriptions" on public.subscriptions for select to authenticated using ((select public.has_permission('finance.view')));
create policy "staff with client access read projects" on public.projects for select to authenticated using ((select public.has_permission('clients.view')));
create policy "staff with client access read service requests" on public.service_requests for select to authenticated using ((select public.has_permission('clients.view')));
create policy "staff with client access read change requests" on public.change_requests for select to authenticated using ((select public.has_permission('clients.view')));
create policy "staff with client access read sites" on public.client_sites for select to authenticated using ((select public.has_permission('clients.view')));
create policy "staff with client access read files" on public.client_files for select to authenticated using ((select public.has_permission('clients.view')));
create policy "staff with client access read updates" on public.updates for select to authenticated using ((select public.has_permission('clients.view')));
create policy "staff with client access read businesses" on public.organizations for select to authenticated using ((select public.has_permission('clients.view')));
create policy "staff with support access read messages" on public.messages for select to authenticated using ((select public.has_permission('support.view')));
create policy "staff with consultation access read leads" on public.leads for select to authenticated using ((select public.has_permission('consultations.view')));
create policy "staff read client names they work with" on public.profiles for select to authenticated using (
  role = 'client' and ((select public.has_permission('clients.view')) or (select public.has_permission('finance.view'))
    or (select public.has_permission('support.view')) or (select public.has_permission('consultations.view'))));

-- 7. Actions by permission ----------------------------------------------------
create policy "staff reply in support" on public.messages for insert to authenticated
  with check ((select public.has_permission('support.reply')) and from_admin = true and read_by_admin = true);

create policy "staff confirm payments" on public.payments for update to authenticated
  using ((select public.has_permission('finance.approve'))) with check ((select public.has_permission('finance.approve')));
create or replace function public.payment_staff_guard()
returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if public.is_admin() then return new; end if;
  if old.status <> 'pending' or new.status not in ('confirmed', 'rejected')
     or (to_jsonb(new) - array['status', 'reviewed_at']) is distinct from (to_jsonb(old) - array['status', 'reviewed_at']) then
    raise exception 'You can only confirm or reject a payment that is waiting.';
  end if;
  return new;
end $$;
drop trigger if exists payment_staff_guard on public.payments;
create trigger payment_staff_guard before update on public.payments for each row execute function public.payment_staff_guard();

create policy "staff update consultation status" on public.leads for update to authenticated
  using ((select public.has_permission('consultations.manage'))) with check ((select public.has_permission('consultations.manage')));
create or replace function public.lead_staff_guard()
returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if public.is_admin() then return new; end if;
  if (to_jsonb(new) - 'status') is distinct from (to_jsonb(old) - 'status') then raise exception 'You can only change the status of a consultation.'; end if;
  return new;
end $$;
drop trigger if exists lead_staff_guard on public.leads;
create trigger lead_staff_guard before update on public.leads for each row execute function public.lead_staff_guard();

-- 8. Seed the first 16 positions ----------------------------------------------
update public.positions set code = 'ceo' where id = 1 and code is null;
update public.positions set code = 'coo' where id = 7 and code is null;
update public.positions set code = 'tech_manager' where id = 3 and code is null;
update public.positions set code = 'finance_manager' where id = 5 and code is null;
update public.positions set code = 'bizdev_head' where id = 2 and code is null;
update public.positions set code = 'legal_head' where id = 4 and code is null;

insert into public.positions (code, title, level, department_id, reports_to_position_id) values
  ('board_member', 'Board Member', 1, null, null),
  ('hr_manager', 'HR Manager', 3, null, (select id from public.positions where code = 'coo')),
  ('dept_head', 'Department Head', 3, null, (select id from public.positions where code = 'coo'));
insert into public.positions (code, title, level, department_id, reports_to_position_id) values
  ('team_lead', 'Team Leader', 4, null, (select id from public.positions where code = 'dept_head')),
  ('accountant', 'Accountant', 5, 7, (select id from public.positions where code = 'finance_manager')),
  ('hr_officer', 'HR Officer', 5, null, (select id from public.positions where code = 'hr_manager')),
  ('receptionist', 'Receptionist', 5, null, (select id from public.positions where code = 'coo')),
  ('csr', 'Customer Service Representative', 5, null, (select id from public.positions where code = 'coo')),
  ('developer', 'Software Developer', 5, 5, (select id from public.positions where code = 'tech_manager')),
  ('sales_rep', 'Sales Representative', 5, 4, (select id from public.positions where code = 'bizdev_head')),
  ('general_staff', 'General Staff / Support Personnel', 5, null, (select id from public.positions where code = 'coo'));

update public.positions p set
  summary = s.summary,
  responsibilities = coalesce(nullif(p.responsibilities, ''), s.duties),
  deliverables = s.deliverables,
  blocks = s.blocks
from (values
  ('board_member', 'Governance and oversight of Lytmoz on behalf of the owner.',
   E'Provides corporate governance and oversight\nReviews executive performance\nExamines strategic plans and major proposals\nReviews financial and organizational reports\nRecords board decisions and resolutions\nMonitors compliance with organizational policies',
   E'Board resolutions and decisions\nQuarterly review of company performance\nRecommendations to the owner', array['duties', 'company', 'org']),
  ('ceo', 'Leads daily operations and delivers the owner''s vision.',
   E'Leads the organization''s overall operations\nTranslates the owner''s vision into objectives\nCoordinates executive managers\nReviews departmental performance\nMakes executive decisions within delegated authority\nReports progress to the Owner and the Board',
   E'Monthly company report to the owner\nApproved objectives for each department\nDecisions on escalated issues', array['duties', 'company', 'finance', 'clients', 'requests', 'support', 'consult', 'people', 'org']),
  ('coo', 'Runs day-to-day operations so departments work together.',
   E'Coordinates daily operations\nEnsures departments work together\nMonitors operational efficiency\nResolves operational bottlenecks\nEnsures approved processes are followed\nReports operational performance to the CEO',
   E'Weekly operations summary\nClient projects delivered on schedule\nFixes for recurring operational problems', array['duties', 'company', 'clients', 'requests', 'sites', 'support', 'consult', 'people', 'org']),
  ('hr_manager', 'Leads people: recruitment, onboarding, records and staff policy.',
   E'Plans recruitment with department heads\nRecommends appointments to the owner\nOrganizes onboarding for new staff\nKeeps staff records and positions up to date\nHandles staff concerns and discipline\nReports on the workforce',
   E'Invitation requests for approved hires\nOnboarding plan for each new person\nUp-to-date staff directory', array['duties', 'people', 'dept', 'org']),
  ('finance_manager', 'Oversees money in and out, invoices and financial reports.',
   E'Oversees finance operations\nConfirms client payments and follows up what is due\nReviews invoices and subscriptions\nPrepares financial reports\nSupervises accounts staff\nReports financial performance to the CEO',
   E'Monthly income and outstanding balance report\nPayments confirmed within one working day\nRenewals followed up before they lapse', array['duties', 'finance', 'company', 'work', 'dept']),
  ('tech_manager', 'Leads the build and care of client websites, apps and systems.',
   E'Plans and assigns technical work\nReviews code and releases\nKeeps client websites and systems reliable\nResponds to technical change requests\nSupervises developers\nReports technical progress',
   E'Delivery plan for each client project\nReviewed releases\nUptime and renewal checks for client sites', array['duties', 'clients', 'requests', 'sites', 'work', 'dept']),
  ('bizdev_head', 'Leads sales: consultations, proposals and new clients.',
   E'Follows up consultation requests\nPrepares proposals and quotes\nConverts leads into clients\nSupervises sales staff\nReports on new business',
   E'Response to every consultation within one day\nProposals for qualified leads\nMonthly new-business report', array['duties', 'consult', 'clients', 'work', 'dept']),
  ('legal_head', 'Keeps Lytmoz and its client work legally sound.',
   E'Reviews contracts and terms\nAdvises on compliance and data protection\nReviews client projects with legal risk\nKeeps policies up to date',
   E'Reviewed contracts\nUp-to-date privacy policy and terms\nCompliance notes on flagged projects', array['duties', 'clients', 'work', 'dept']),
  ('dept_head', 'Leads a department: its people, work and results.',
   E'Leads the department''s work and people\nAssigns duties and reviews submitted work\nRequests new hires from the owner\nReports department performance',
   E'Department plan and priorities\nReviewed work from the team\nMonthly department report', array['duties', 'work', 'dept', 'people']),
  ('team_lead', 'Leads a team inside a department day to day.',
   E'Organizes the team''s daily work\nGuides and supports team members\nChecks work before it goes for review\nReports progress to the department head',
   E'Daily priorities for the team\nChecked work ready for review', array['duties', 'work', 'dept']),
  ('accountant', 'Keeps the financial records accurate.',
   E'Records payments and receipts\nReconciles payments against invoices\nConfirms payments clients report\nPrepares financial statements',
   E'Payments checked and confirmed\nMonthly reconciliation\nFinancial statements', array['duties', 'finance', 'work', 'dept']),
  ('hr_officer', 'Supports recruitment, onboarding and staff records.',
   E'Prepares recruitment and invitation requests\nSupports onboarding of new staff\nKeeps staff records up to date\nAnswers staff questions about policies',
   E'Invitation requests ready for the owner\nOnboarding checklist completed for each new person', array['duties', 'people', 'work', 'dept']),
  ('receptionist', 'First contact for everyone who reaches Lytmoz.',
   E'Welcomes visitors and callers\nRecords and routes consultation requests\nBooks consultation calls\nPasses client questions to the right person',
   E'Every consultation request routed the same day\nBooked consultation calls', array['duties', 'consult', 'support', 'work']),
  ('csr', 'Helps clients with questions and requests.',
   E'Answers client support messages\nTracks service and change requests\nKeeps clients informed of progress\nPasses technical issues to the right team',
   E'Replies to clients within working hours\nRequests passed on with clear notes', array['duties', 'support', 'requests', 'consult', 'work']),
  ('developer', 'Builds and maintains client websites, apps and systems.',
   E'Builds features assigned to them\nFixes issues and change requests\nTests work before submitting it\nDocuments what they build',
   E'Working, tested features\nCompleted change requests', array['duties', 'work', 'clients', 'requests', 'sites', 'dept']),
  ('sales_rep', 'Turns enquiries into clients.',
   E'Contacts new consultation requests\nExplains services and prices\nBooks calls and follows up\nRecords the status of every lead',
   E'Every lead contacted and its status updated\nBooked calls and won clients', array['duties', 'consult', 'clients', 'work', 'dept']),
  ('general_staff', 'Supports the team wherever needed.',
   E'Completes duties assigned by their supervisor\nSupports the department''s daily work\nReports problems early',
   E'Assigned duties completed on time', array['duties', 'work', 'dept'])
) as s(code, summary, duties, deliverables, blocks)
where p.code = s.code;

insert into public.permission_grants (permission, position_id, reason)
select g.perm, p.id, 'Standard for this position' from (values
  ('board_member', 'reports.view'), ('board_member', 'departments.view_all'),
  ('ceo', 'reports.view'), ('ceo', 'finance.view'), ('ceo', 'clients.view'), ('ceo', 'support.view'), ('ceo', 'consultations.view'), ('ceo', 'departments.view_all'), ('ceo', 'work.assign'), ('ceo', 'work.review'), ('ceo', 'invites.request'),
  ('coo', 'reports.view'), ('coo', 'clients.view'), ('coo', 'support.view'), ('coo', 'consultations.view'), ('coo', 'departments.view_all'), ('coo', 'work.assign'), ('coo', 'work.review'), ('coo', 'invites.request'),
  ('hr_manager', 'invites.request'), ('hr_manager', 'members.manage'), ('hr_manager', 'departments.view_all'),
  ('finance_manager', 'finance.view'), ('finance_manager', 'finance.approve'), ('finance_manager', 'reports.view'), ('finance_manager', 'work.assign'), ('finance_manager', 'work.review'),
  ('tech_manager', 'clients.view'), ('tech_manager', 'work.assign'), ('tech_manager', 'work.review'),
  ('bizdev_head', 'consultations.view'), ('bizdev_head', 'consultations.manage'), ('bizdev_head', 'clients.view'), ('bizdev_head', 'work.assign'), ('bizdev_head', 'work.review'),
  ('legal_head', 'clients.view'), ('legal_head', 'work.review'),
  ('dept_head', 'work.assign'), ('dept_head', 'work.review'),  -- heads may ask for invites into their own department (see policy)
  ('team_lead', 'work.review'),
  ('accountant', 'finance.view'), ('accountant', 'finance.approve'),
  ('hr_officer', 'invites.request'),
  ('receptionist', 'consultations.view'), ('receptionist', 'consultations.manage'), ('receptionist', 'support.view'),
  ('csr', 'support.view'), ('csr', 'support.reply'), ('csr', 'clients.view'), ('csr', 'consultations.view'),
  ('developer', 'clients.view'),
  ('sales_rep', 'consultations.view'), ('sales_rep', 'consultations.manage'), ('sales_rep', 'clients.view')
) as g(code, perm) join public.positions p on p.code = g.code
where not exists (select 1 from public.permission_grants x where x.permission = g.perm and x.position_id = p.id);
