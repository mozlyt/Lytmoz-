# Backend (Supabase)

Project: `lytmoz` (ref `rfcyjjtujrgzneokjfmd`, London). Separate from the MOZLYT project.

- **Tables:** profiles, leads, projects, updates, invoices, change_requests
- **Security:** row-level security on every table. Visitors can only *send* the consultation form.
  Clients see only their own project, updates and invoices. Only HQ admins see everything.
- **Edge function `hq-users`:** creates the first HQ account (owner email only, once) and client logins.
- **Rate limit:** max 5 consultation requests per WhatsApp number per day.

## Billing

- **invoices**: one invoice per agreed piece of work. `paid_cents` is kept up to date automatically; balance = `amount_cents - paid_cents`. Status turns `paid` only when the balance is cleared. Optional `due_on`.
- **payments**: every payment toward an invoice (deposit, milestone, balance). Clients can only add `pending` payments, never more than the balance. HQ confirms transfers in HQ → Payments.
- **Edge function `paystack-verify`**: after a client pays online in the portal, it asks Paystack whether the money arrived and records a confirmed payment. Needs the secret `PAYSTACK_SECRET_KEY` (Supabase → Edge Functions → Secrets). Without it, online payments still work but wait in HQ → Payments for a manual confirm.
- The Paystack **public** key is in `config.js`. Online payment shows on GHS invoices.

## Subscriptions

- **subscriptions**: one row per agreed recurring plan. A client can have several, each at its own price.
- **Price changes**: `next_amount_cents` + `next_amount_from` hold an agreed change that has not started. `apply_price_changes()` (run when HQ opens) moves it into `amount_cents` once the date arrives.
- **`bill_subscription(sub)`**: HQ → Subscriptions → Create invoice. Raises the invoice for the coming period at the price in force, then moves the renewal forward. Invoices keep their own amount, so later price edits never change them (`invoices.subscription_id` links them back).
- **History**: every change is recorded in `activity_logs` with who made it; HQ shows it under Edit.

## Team workplace (client side)

- **team_tasks**: work assigned inside a client's business (title, instructions, assignee, due date, status, optional project). Owners assign, edit and delete. The person assigned can only move the status.
- **team_posts**: the team discussion. `task_id` empty = general discussion; set = comments on that task.
- **Privacy**: database rules limit both tables to members of that business. Other businesses cannot see them, and they are not shown in Lytmoz HQ.

## HQ Settings (website wording and services)

- **site_settings** (one row): `draft` is what HQ is editing, `published` is what the public sees. **site_versions** keeps the last 30 published copies.
- HQ → Settings edits the draft. **Preview** opens `lytmoz.com/?preview=1` (admins only). **Publish** runs `publish_site()`.
- HQ → Settings is a menu (Organization, Website & Public Content, Services & Expertise, Consultation & Intake, Workflows & Projects, Billing & Pricing, Team & Permissions, Notifications & Integrations). Website & Public Content lists every public page.
- Every public page loads `assets/content.js`, which applies the published copy (text marked `data-lz`, the WhatsApp number and social links). Service pages use keys `p.<folder>.eyebrow|heading|lead`.
- The homepage reads `public_site()` on load and replaces the text of elements marked `data-lz="key"`, the specialists list and the questions. The text written in `index.html` is the fallback and what HQ shows before anything is published. The portal's "Request a service" list comes from the same published copy.
- To make another piece of homepage text editable: add `data-lz="some.key"` to its element and add the key to `SITE_GROUPS` in `admin.html`.

## Lytmoz organization (Stage 1: structure and authority)

- **Owner** = a profile with role `admin`. Everyone else who works for Lytmoz is a row in **staff** (added by email with `add_staff`).
- **departments** (name, purpose, `head`) and **department_members** (person, `kind`: lead, mentor or member, plus an optional job title). Appointing a head makes them a member automatically. Only the owner appoints heads.
- **authority_settings.rules** holds what heads and staff may do (`head_manage_members`, `head_edit_department`, `head_see_all`, `staff_see_all`, and `head_assign_work` / `head_review_work` for Stages 2 and 3). The database rules read these, so a switch in HQ → Organization → Authority Settings takes effect immediately.
- Staff and heads sign in at `admin.html` and see the Organization section only (`my_org_role()` decides). They cannot read clients, projects or billing.
- Not to be confused with **organizations**, which are client businesses.

## Staff invitations and workspace (Stage 1)

- People join Lytmoz only through **staff_invites** (HQ → People & Roles → Invite a member). Each invitation has a secret 64-character link (`/join.html?t=…`), one email, one department, a role (member, team lead, mentor), optional position and who they report to. It expires after 7 days; HQ can send it again (extends it) or revoke it.
- `invite_info(token)` shows the invited person what they are accepting. `accept_invite(token)` (signed in, matching email) or the **staff-join** edge function (no account yet) creates the organization membership. New staff get `profiles.role = 'staff'`, never `client`.
- Department heads can invite into their own department only when Authority Settings → `head_invite` is on (off by default).
- **dept_posts** is department communication, readable and writable by that department and the owner.
- Staff and heads sign in at `admin.html` and get their own workspace (Overview, My Work, Submissions, Department, Messages, My Profile). Changes to staff, departments, memberships, invitations and authority are recorded in `activity_logs`.

## Admin HQ layout (owner)

- The owner sees a left sidebar (Organization Structure, Projects & Tasks, Communication, Reports & Analytics, System Logs, Settings, Help & Support, Log out) and a top bar (Dashboard Overview, Work, Report and Review, Inbox, Members, Billing, Set Up, bell, account menu). Both are built from `NAV` in `admin.html`; `goTo(key)` opens a section. Staff and department heads keep their own workspace menu.
- The dashboard is computed in the browser from the latest rows of each table (up to 1,000 per table), so its figures are exact at Lytmoz's current size.
- Owner / Founder, Board of Directors, CEO, Executive Management and Teams use `positions` (level 1 = governance, 2 = executive), `position_assignments` and `teams` / `team_members`.

## Messages, top menu and privacy (migration `chat_visibility_and_hq_menu`)

- **Messages** (HQ Inbox → Messages, portal → Messages): WhatsApp-style chat. Tables `chat_threads`, `chat_messages`, `chat_blocks`; only the two people in a chat can read it (the owner cannot read client-to-client chats). Clients are **hidden by default**; a client turns on "Show me in Messages" in Privacy & security (`profiles.chat_visible`, RPC `chat_set_visible`). A new chat between two clients needs both visible. Everyone can always chat with Lytmoz. Online = `last_seen` within 2 minutes (`chat_seen` every minute). RPCs: `chat_people`, `chat_open`, `chat_list`, `chat_read`. `chat_messages` is in the realtime publication; the page also polls every 8 s.
- **Top menu editor** (Set Up → Edit top menu): rename, hide, reorder and move items between top-bar buttons. Saved in `hq_settings.menu` (row id 1, admins only). "Back to the standard menu" + Save restores the default.
- **Privacy policy**: public page `/privacy/`, edited in Set Up → Privacy & Policy (keys `privacy.updated`, `privacy.body`; `## ` = heading, `- ` = bullet). Draft/publish like the other website text.
- **Email** (Inbox → Email): opens the Gmail mailbox and lists clients with a "Write email" link. Reading mail inside HQ needs the mailbox connected later.

## Positions, workspaces and permissions (Milestone 1, `supabase/positions_milestone1.sql`)

- **positions** is the Position Catalogue: `code`, `title`, `level` (1 governance … 5 employees), `department_id` (empty = any), `reports_to_position_id`, `summary`, `responsibilities` (duties, one per line), `deliverables`, `blocks` (workspace sections: duties, work, dept, company, finance, clients, requests, sites, support, consult, people, org). Edited in HQ → Organization Structure → Position Catalogue.
- People hold positions through **position_assignments**. `my_position_ids()` adds the `dept_head` position for anyone heading a department and `team_lead` for anyone leading a team.
- **permission_grants** give a permission to a position, department or person; `deny = true` on a person removes it for them only. `has_permission(key)` is used by the database rules, so access is enforced on the server.
- New permissions: `reports.view`, `finance.view`, `finance.approve`, `clients.view`, `support.view`, `support.reply`, `consultations.view`, `consultations.manage`, `invites.request`. Staff with them can read the matching client data; confirming payments and changing a consultation's status are limited to those single changes by triggers.
- `my_workspace()` returns the signed-in person's positions and permissions; HQ builds their menu from it.
- **Invitations**: only the owner creates `staff_invites`. HR, executives (with `invites.request`) and department heads (own department) create **invite_requests**; the owner runs `decide_invite_request(id, approve, note)`, which creates the invitation link. An accepted invitation with a `position_id` assigns that position.

## Tasks, submissions and reviews (Milestone 2, `supabase/work_milestone2.sql`)

- **work_items**: one task (title, instructions, assignee, assigned_by, reviewer, priority, due date, optional client project). Status: assigned → in_progress → submitted → returned (correction) → submitted → approved, or cancelled. **work_events** is its history (assigned, started, submitted with note and link, returned with the correction, approved, comments).
- Changes only through RPCs: `work_assign(...)` and `work_act(item, act, note, link)` with act = start, submit, approve, return, cancel, comment. Nobody can approve their own work; a return needs a note; a submission needs a note or a link.
- `supervises(person, 'work.assign' | 'work.review')` decides who may direct whom: the owner; executives (level 1–2) with the permission; department heads for their department when Authority Settings allows (`head_assign_work`, `head_review_work`); whoever a member reports to; team leaders for their team. `my_directs()` lists the people you can assign to.
- HQ: owner → Projects & Tasks → Staff tasks (bell shows work to review). Staff → My Tasks, Submissions, and Team Work for people who assign or review.
- **Leadership invitations** (`supabase/leadership_invites.sql`): the owner invites by position first. Board (level 1) and executive (level 2) seats have no department; others pick a department (pre-filled from the position). One-person seats (`positions.max_holders = 1`) show who holds them and warn before a second invitation.
- **Removing people** (`supabase/staff_leave.sql`): "Remove from this position only" ends that title; they stay staff with the basic workspace. "Remove from Lytmoz" (Members & Staff, or from a position) deletes the staff row: HQ access, workspace and every permission end at once, positions end (history kept), teams and open tasks are cleared.

## Settings in three places (`supabase/org_settings.sql`)

- **Side menu → Organization Settings**: Structure, Positions & permissions, Joining & leaving (invitation validity, what happens to tasks when someone leaves), Work rules (heads assign/review, link required, own tasks), Staff workspace (default sections, welcome line).
- **Top bar → Set Up**: public setup (website, business details, services, consultation, billing & pricing, privacy, top menu, client accounts, activity log).
- **Side menu bottom → General Settings**: all of the above plus Account & system (owner name and password, notifications and integrations, project stages, security summary). Each setting exists once; the three places open the same screens.

## Communication rooms (`supabase/rooms.sql`)

- **Department Room**: private to each department and its head; the owner reads (HQ → Internal Communication → Department Rooms) but cannot post. Staff are told the owner can read it.
- **Organization Room**: company news (pinned, shown on every workspace's Announcements card) and discussion for everyone. Owner switch (Open / Approval needed / Closed) in the room and in Organization Settings → Communication; owner approves, removes and pins posts and can stop one person posting. News posters: positions with `news.post`.

## Review round (`supabase/org_review.sql`)

- **Private messages for staff**: Messages in every workspace. Anyone at Lytmoz can message anyone at Lytmoz (not clients). Private to the two people; a participant can **Report** a conversation, after which the owner can read it (HQ → Internal Communication → Reported conversations). Owner can switch staff messaging off or stop one person (Organization Settings → Communication); everyone can always message the owner.
- **Team Rooms**: private to each team and its leader; owner reads (Internal Communication → Team Rooms).
- **Organization records**: Organization Settings → Organization records, a readable history of joining, positions, permissions, work and settings changes from `activity_logs`.
- **Escalation**: overdue tasks are flagged at once; after `escalate_days` they also reach the head, executives and owner (Overdue tab in Staff tasks / Team Work).
- **Reviewer**: chosen when assigning (must be above the person).
- **Workspace home**: My Team, My Performance, My Notifications (and a Notifications page).

## Top bar review (round 2)

- Top bar: Dashboard Overview · Work · **Reports & Quality** · Inbox (Client messages, Support, Email, Consultations) · **Clients & Accounts** (Businesses, Client members, Client accounts) · Billing (Payments & invoices, Subscriptions, Public prices) · **Public Setup**, grouped as Website, Business Profile, Services, Client Experience, Legal & Policies, Records & menu (`PUB_GROUP`).
- The owner's Inbox → Client messages shows client chats only; chats with staff are in the side menu → Internal Communication → Staff messages (`LZChat.mount({ only: 'clients' | 'staff' })`, `chat_list().staff`).
- Bell: "Client & Public" and "Internal Organization" groups; staff work and reported conversations open the exact item (`data-deep`).
- Edit top menu shows a live preview; hiding never changes access. Picture menu → My account.
- **Reports & Quality** (`supabase/quality.sql`): Delivery reviews (quality checklist for projects at stage 6 · Review), Client feedback (clients rate delivered projects in the portal), Project performance (stage, time since start, change requests, last quality check, rating).
- **Billing additions** (`supabase/billing_adjustments.sql`): Billing → Outstanding balances (per client, oldest first, overdue marked, WhatsApp/email reminder) and Refunds & adjustments (discount, write-off, refund, each with a reason). Clients see the new amounts and "was … before a discount" in the portal.
- **Client portal administrators** (`supabase/client_admins.sql`): business owners can make someone an Administrator, who adds and removes members for them. Only owners change roles; a business always keeps one owner.
- **Client groups** (`supabase/client_groups.sql`): in the portal, My team → Groups. Any client can create a group with a name and purpose and add other clients who are visible in Messages (online and active today first, never staff, never blocked people). Members see only that group's messages and the files shared in its chat (private `group-files` bucket, 20 MB, folder = group id). Admins add, remove and promote; anyone can leave; the last admin leaving hands over to the longest-standing member, and an empty group is deleted. The owner does not read client groups, the same as client-to-client Messages. Live updates use realtime on `chat_group_messages`.
- **Client follows** (`supabase/client_follows.sql`): My team → Following and Followers. Clients follow other clients who are visible in Messages; each person sees only follows that involve them. People you follow are listed first when adding people to a group. The business workspace screen was removed from My team (its tables and data are kept).
- **People & Membership Centre** (`supabase/people_centre.sql`, applied as `people_centre_1_tables` … `people_centre_5_changes`): HQ → Members & Staff has three tabs. *Invite a member* is a four-part form (personal, placement, working relationship, invitation preview); the position fills in level, department, reporting manager, workspace and permissions, and the owner can adjust them for that one person. *Organizational directory* (`org_directory()`) is searchable and filterable; each person has a profile (`member_profile()`, owner or self only) with placement, workspace, permissions and membership history (`member_changes`). The owner can promote/change, transfer, give an acting position with an end date, add or remove a position (`member_change()`), set reporting manager, mentor and extra responsibilities (`member_set_links()`), and suspend or reactivate (`member_set_status()`; suspended people lose HQ and permissions but keep their place). *Invitations* has Pending / Accepted / Expired / Revoked; `invite_resend()` renews the same link. The database refuses a second open invitation for an email, invitations for existing members, invitations into a filled one-person seat, and accepting into a seat that has since been filled. The owner is never a staff record and cannot be changed from HQ.
- **HR records** (`supabase/hr_records.sql`): the `people.records` permission (HR Manager by default) lets HR open full profiles and record position changes, transfers, acting positions, reporting lines, mentors and responsibilities for staff below department-head level, never for themselves. Suspend, remove, invitations and leadership positions stay with the owner.
