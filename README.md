# Lytmoz

From idea to a system that grows. The Lytmoz website, HQ dashboard and client portal.

| Page | What it is |
|---|---|
| `index.html` | Public website |
| `admin.html` | Lytmoz HQ (team login) |
| `portal.html` | Client portal (client login) |
| `worker/` | Backend: Cloudflare Worker + D1 database |
| `config.js` | Site settings: backend address and WhatsApp number |

Until `config.js` has an `api` address, the site still works: the consultation form sends requests through WhatsApp, and HQ and the portal show labelled sample data.

## 1. Website on GitHub Pages

Settings → Pages → Source: **Deploy from a branch**, branch `main`, folder `/ (root)`. The `CNAME` file points it at `mozlytfit.com`.

### Namecheap DNS for mozlytfit.com

Domain List → mozlytfit.com → Manage → Advanced DNS. Remove the old records for `@` and `www`, then add:

| Type | Host | Value |
|---|---|---|
| A | @ | 185.199.108.153 |
| A | @ | 185.199.109.153 |
| A | @ | 185.199.110.153 |
| A | @ | 185.199.111.153 |
| CNAME | www | mozlyt.github.io. |

When GitHub shows the domain as verified, tick **Enforce HTTPS**.

## 2. Backend on Cloudflare

```sh
cd worker
npx wrangler login
npx wrangler d1 create lytmoz              # copy the database_id into wrangler.toml
npx wrangler d1 execute lytmoz --remote --file=schema.sql
npx wrangler secret put SETUP_KEY          # any long random phrase, used once
npx wrangler secret put RESEND_API_KEY     # optional: email alerts for new requests
npx wrangler deploy
```

Create the first HQ login (once):

```sh
curl -X POST https://<worker-address>/api/setup -H "Content-Type: application/json" \
  -d '{"key":"<SETUP_KEY>","email":"you@example.com","name":"Mensah","password":"a-strong-password"}'
```

Then put the worker address in `config.js` → `api`, and commit.

## Security notes

- Passwords are hashed (PBKDF2, 100k rounds); sessions expire after 14 days.
- The API only accepts requests from the origins listed in `ALLOWED_ORIGINS`.
- No secrets live in this repository. Keys are stored as Cloudflare secrets.
