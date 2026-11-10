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
