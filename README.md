# Lytmoz

From idea to a system that grows. The Lytmoz website, HQ dashboard and client portal.

| Page | What it is |
|---|---|
| `index.html` | Public website |
| `admin.html` | Lytmoz HQ (team login) |
| `portal.html` | Client portal (client login) |
| `supabase/` | Notes on the Supabase backend |
| `config.js` | Site settings: Supabase address, public key, WhatsApp number |


## 1. Website on GitHub Pages

Settings → Pages → Source: **Deploy from a branch**, branch `main`, folder `/ (root)`. The `CNAME` file points it at `lytmoz.com`.

### Namecheap DNS for lytmoz.com

Domain List → lytmoz.com → Manage → Advanced DNS. Remove the old records for `@` and `www`, then add:

| Type | Host | Value |
|---|---|---|
| A | @ | 185.199.108.153 |
| A | @ | 185.199.109.153 |
| A | @ | 185.199.110.153 |
| A | @ | 185.199.111.153 |
| CNAME | www | mozlyt.github.io. |

When GitHub shows the domain as verified, tick **Enforce HTTPS**.

### Old domain (mozlytfit.com)

In Namecheap, mozlytfit.com uses a permanent **URL Redirect Record** (`@` and `www`) to `https://lytmoz.com`, so old links keep working.

## 2. Backend (Supabase)

Already set up: see `supabase/README.md`. The site connects through `config.js`.

**First HQ login:** open `/admin.html`, tap **First time? Set up HQ**, and use the owner email. This works once.

## Security notes

- Logins are handled by Supabase Auth.
- The key in `config.js` is the public (publishable) key; database rules protect the data.
- No secret keys live in this repository.
