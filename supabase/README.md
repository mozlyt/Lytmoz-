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
