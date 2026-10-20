// Lytmoz backend — Cloudflare Worker + D1.
// Secrets (set with `wrangler secret put`): SETUP_KEY, RESEND_API_KEY (optional).
// Vars (wrangler.toml): ALLOWED_ORIGINS, ADMIN_EMAIL, MAIL_FROM.

const SESSION_DAYS = 14;
const enc = new TextEncoder();

export default {
  async fetch(request, env, ctx) {
    const origin = request.headers.get('Origin') || '';
    const cors = corsHeaders(origin, env);
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
    try {
      const res = await route(request, env, ctx);
      Object.entries(cors).forEach(([k, v]) => res.headers.set(k, v));
      return res;
    } catch (err) {
      const status = err.status || 500;
      if (status === 500) console.error(err);
      return json({ error: status === 500 ? 'Server error' : err.message }, status, cors);
    }
  }
};

async function route(request, env, ctx) {
  const url = new URL(request.url);
  const path = url.pathname.replace(/\/+$/, '');
  const m = request.method;

  if (m === 'GET' && path === '/api/health') return json({ ok: true });
  if (m === 'POST' && path === '/api/leads') return createLead(request, env, ctx);
  if (m === 'POST' && path === '/api/setup') return setup(request, env);
  if (m === 'POST' && path === '/api/login') return login(request, env);

  const user = await authenticate(request, env);
  if (m === 'POST' && path === '/api/logout') {
    await env.DB.prepare('DELETE FROM sessions WHERE token = ?').bind(bearer(request)).run();
    return json({ ok: true });
  }
  if (m === 'GET' && path === '/api/me') return json({ user: publicUser(user) });
  if (m === 'POST' && path === '/api/password') return changePassword(request, env, user);

  if (path.startsWith('/api/portal')) {
    if (user.role !== 'client') fail(403, 'Clients only');
    if (m === 'GET' && path === '/api/portal') return portal(env, user);
    if (m === 'POST' && path === '/api/portal/requests') return portalRequest(request, env, user, ctx);
  }

  if (path.startsWith('/api/admin')) {
    if (user.role !== 'admin') fail(403, 'Admins only');
    let r;
    if (m === 'GET' && path === '/api/admin/overview') return adminOverview(env);
    if (m === 'GET' && path === '/api/admin/leads') return adminLeads(env);
    if (m === 'PATCH' && (r = path.match(/^\/api\/admin\/leads\/(\d+)$/))) return adminLeadStatus(request, env, +r[1]);
    if (m === 'GET' && path === '/api/admin/projects') return adminProjects(env);
    if (m === 'POST' && path === '/api/admin/clients') return adminCreateClient(request, env);
    if (m === 'PATCH' && (r = path.match(/^\/api\/admin\/projects\/(\d+)$/))) return adminUpdateProject(request, env, +r[1]);
    if (m === 'POST' && (r = path.match(/^\/api\/admin\/projects\/(\d+)\/updates$/))) return adminAddUpdate(request, env, +r[1]);
    if (m === 'POST' && (r = path.match(/^\/api\/admin\/projects\/(\d+)\/invoices$/))) return adminAddInvoice(request, env, +r[1]);
    if (m === 'PATCH' && (r = path.match(/^\/api\/admin\/invoices\/(\d+)$/))) return adminInvoiceStatus(request, env, +r[1]);
    if (m === 'GET' && path === '/api/admin/requests') return adminRequests(env);
  }
  fail(404, 'Not found');
}

// ---------- public ----------
async function createLead(request, env, ctx) {
  const b = await body(request);
  if (b.company) return json({ ok: true }); // honeypot field: silently ignore bots
  const name = clean(b.name, 120), whatsapp = clean(b.whatsapp, 40), message = clean(b.message, 3000);
  const website = clean(b.website, 300);
  if (!name || !whatsapp || !message) fail(400, 'Name, WhatsApp and message are required');
  if (!/^[+\d][\d\s()-]{6,}$/.test(whatsapp)) fail(400, 'Please enter a valid WhatsApp number');
  // simple flood guard: max 5 leads per number per day
  const recent = await env.DB.prepare(
    "SELECT COUNT(*) AS n FROM leads WHERE whatsapp = ? AND created_at > datetime('now', '-1 day')"
  ).bind(whatsapp).first();
  if (recent.n >= 5) fail(429, 'Too many requests. Please message us on WhatsApp.');
  const res = await env.DB.prepare('INSERT INTO leads (name, website, whatsapp, message) VALUES (?, ?, ?, ?)')
    .bind(name, website || null, whatsapp, message).run();
  ctx.waitUntil(notify(env, `New consultation request from ${name}`,
    `Name: ${name}\nWhatsApp: ${whatsapp}\nWebsite: ${website || '-'}\n\n${message}`));
  return json({ ok: true, id: res.meta.last_row_id }, 201);
}

async function setup(request, env) {
  const b = await body(request);
  if (!env.SETUP_KEY || b.key !== env.SETUP_KEY) fail(403, 'Invalid setup key');
  const existing = await env.DB.prepare("SELECT COUNT(*) AS n FROM users WHERE role = 'admin'").first();
  if (existing.n > 0) fail(409, 'An admin already exists');
  const user = await createUser(env, b.email, b.name || 'Admin', b.password, 'admin');
  return json({ ok: true, user: publicUser(user) }, 201);
}

async function login(request, env) {
  const b = await body(request);
  const email = clean(b.email, 200).toLowerCase();
  const user = await env.DB.prepare('SELECT * FROM users WHERE email = ?').bind(email).first();
  const ok = user && (await hashPassword(String(b.password || ''), user.salt)) === user.pass_hash;
  if (!ok) fail(401, 'Wrong email or password');
  const token = randomHex(32);
  const expires = new Date(Date.now() + SESSION_DAYS * 864e5).toISOString();
  await env.DB.prepare("DELETE FROM sessions WHERE expires_at < ?").bind(new Date().toISOString()).run();
  await env.DB.prepare('INSERT INTO sessions (token, user_id, expires_at) VALUES (?, ?, ?)').bind(token, user.id, expires).run();
  return json({ token, user: publicUser(user) });
}

async function changePassword(request, env, user) {
  const b = await body(request);
  const current = await hashPassword(String(b.current || ''), user.salt);
  if (current !== user.pass_hash) fail(401, 'Current password is wrong');
  checkPassword(b.password);
  const salt = randomHex(16);
  await env.DB.prepare('UPDATE users SET pass_hash = ?, salt = ? WHERE id = ?')
    .bind(await hashPassword(b.password, salt), salt, user.id).run();
  await env.DB.prepare('DELETE FROM sessions WHERE user_id = ? AND token != ?').bind(user.id, bearer(request)).run();
  return json({ ok: true });
}

// ---------- client portal ----------
async function portal(env, user) {
  const project = await env.DB.prepare('SELECT * FROM projects WHERE client_id = ? ORDER BY id DESC LIMIT 1').bind(user.id).first();
  if (!project) return json({ user: publicUser(user), project: null, updates: [], invoices: [] });
  const [updates, invoices] = await Promise.all([
    env.DB.prepare('SELECT id, text, created_at FROM updates WHERE project_id = ? ORDER BY id DESC LIMIT 20').bind(project.id).all(),
    env.DB.prepare("SELECT id, description, amount_cents, currency, status, pay_url, created_at FROM invoices WHERE project_id = ? AND status != 'void' ORDER BY id DESC").bind(project.id).all()
  ]);
  return json({ user: publicUser(user), project, updates: updates.results, invoices: invoices.results });
}

async function portalRequest(request, env, user, ctx) {
  const b = await body(request);
  const text = clean(b.text, 3000);
  if (!text) fail(400, 'Please describe the change');
  const project = await env.DB.prepare('SELECT id, name FROM projects WHERE client_id = ? ORDER BY id DESC LIMIT 1').bind(user.id).first();
  if (!project) fail(404, 'No project yet');
  await env.DB.prepare('INSERT INTO change_requests (project_id, text) VALUES (?, ?)').bind(project.id, text).run();
  ctx.waitUntil(notify(env, `Change request: ${project.name}`, `${user.name} (${user.email}) asked:\n\n${text}`));
  return json({ ok: true }, 201);
}

// ---------- admin ----------
async function adminOverview(env) {
  const q = (sql) => env.DB.prepare(sql).first();
  const [leads, active, care, due, open] = await Promise.all([
    q("SELECT COUNT(*) AS n FROM leads WHERE created_at >= date('now', 'start of month')"),
    q('SELECT COUNT(*) AS n FROM projects WHERE stage BETWEEN 1 AND 4'),
    q('SELECT COALESCE(SUM(monthly_care_cents), 0) AS n FROM projects WHERE stage = 5'),
    q("SELECT COALESCE(SUM(amount_cents), 0) AS n FROM invoices WHERE status = 'due'"),
    q("SELECT COUNT(*) AS n FROM change_requests WHERE status = 'open'")
  ]);
  return json({ leadsThisMonth: leads.n, activeProjects: active.n, monthlyCareCents: care.n, invoicesDueCents: due.n, openRequests: open.n });
}

async function adminLeads(env) {
  const r = await env.DB.prepare('SELECT * FROM leads ORDER BY id DESC LIMIT 200').all();
  return json({ leads: r.results });
}

async function adminLeadStatus(request, env, id) {
  const b = await body(request);
  const allowed = ['new', 'contacted', 'call_booked', 'audit_sent', 'won', 'lost'];
  if (!allowed.includes(b.status)) fail(400, 'Unknown status');
  await env.DB.prepare('UPDATE leads SET status = ? WHERE id = ?').bind(b.status, id).run();
  return json({ ok: true });
}

async function adminProjects(env) {
  const r = await env.DB.prepare(
    `SELECT p.*, u.name AS client_name, u.email AS client_email,
       (SELECT COALESCE(SUM(amount_cents),0) FROM invoices i WHERE i.project_id = p.id AND i.status = 'due') AS due_cents
     FROM projects p JOIN users u ON u.id = p.client_id ORDER BY p.id DESC`
  ).all();
  return json({ projects: r.results });
}

async function adminCreateClient(request, env) {
  const b = await body(request);
  const projectName = clean(b.projectName, 160);
  if (!projectName) fail(400, 'Project name is required');
  const user = await createUser(env, b.email, b.name, b.password, 'client');
  const plan = ['Launch', 'Network', 'Empire'].includes(b.plan) ? b.plan : 'Network';
  const res = await env.DB.prepare('INSERT INTO projects (client_id, name, plan, monthly_care_cents) VALUES (?, ?, ?, ?)')
    .bind(user.id, projectName, plan, cents(b.monthlyCare || 0)).run();
  return json({ ok: true, user: publicUser(user), projectId: res.meta.last_row_id }, 201);
}

async function adminUpdateProject(request, env, id) {
  const b = await body(request);
  const sets = [], vals = [];
  if (b.stage !== undefined) { const s = +b.stage; if (!(s >= 1 && s <= 5)) fail(400, 'Stage must be 1 to 5'); sets.push('stage = ?'); vals.push(s); }
  if (b.previewUrl !== undefined) { sets.push('preview_url = ?'); vals.push(clean(b.previewUrl, 300) || null); }
  if (b.monthlyCare !== undefined) { sets.push('monthly_care_cents = ?'); vals.push(cents(b.monthlyCare)); }
  if (!sets.length) fail(400, 'Nothing to update');
  await env.DB.prepare(`UPDATE projects SET ${sets.join(', ')} WHERE id = ?`).bind(...vals, id).run();
  return json({ ok: true });
}

async function adminAddUpdate(request, env, id) {
  const text = clean((await body(request)).text, 1000);
  if (!text) fail(400, 'Update text is required');
  await env.DB.prepare('INSERT INTO updates (project_id, text) VALUES (?, ?)').bind(id, text).run();
  return json({ ok: true }, 201);
}

async function adminAddInvoice(request, env, id) {
  const b = await body(request);
  const description = clean(b.description, 200);
  const amount = cents(b.amount);
  if (!description || amount <= 0) fail(400, 'Description and a positive amount are required');
  const currency = ['USD', 'GHS', 'NGN'].includes(b.currency) ? b.currency : 'USD';
  await env.DB.prepare('INSERT INTO invoices (project_id, description, amount_cents, currency, pay_url) VALUES (?, ?, ?, ?, ?)')
    .bind(id, description, amount, currency, clean(b.payUrl, 500) || null).run();
  return json({ ok: true }, 201);
}

async function adminInvoiceStatus(request, env, id) {
  const b = await body(request);
  if (!['due', 'paid', 'void'].includes(b.status)) fail(400, 'Unknown status');
  await env.DB.prepare('UPDATE invoices SET status = ? WHERE id = ?').bind(b.status, id).run();
  return json({ ok: true });
}

async function adminRequests(env) {
  const r = await env.DB.prepare(
    `SELECT c.*, p.name AS project_name FROM change_requests c JOIN projects p ON p.id = c.project_id ORDER BY c.id DESC LIMIT 100`
  ).all();
  return json({ requests: r.results });
}

// ---------- helpers ----------
async function authenticate(request, env) {
  const token = bearer(request);
  if (!token) fail(401, 'Please log in');
  const row = await env.DB.prepare(
    'SELECT u.* FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token = ? AND s.expires_at > ?'
  ).bind(token, new Date().toISOString()).first();
  if (!row) fail(401, 'Your session has ended. Please log in again.');
  return row;
}

async function createUser(env, email, name, password, role) {
  email = clean(email, 200).toLowerCase();
  name = clean(name, 120);
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) fail(400, 'Please enter a valid email');
  if (!name) fail(400, 'Name is required');
  checkPassword(password);
  const taken = await env.DB.prepare('SELECT id FROM users WHERE email = ?').bind(email).first();
  if (taken) fail(409, 'That email already has an account');
  const salt = randomHex(16);
  const res = await env.DB.prepare('INSERT INTO users (email, name, role, pass_hash, salt) VALUES (?, ?, ?, ?, ?)')
    .bind(email, name, role, await hashPassword(password, salt), salt).run();
  return { id: res.meta.last_row_id, email, name, role };
}

function checkPassword(p) {
  if (typeof p !== 'string' || p.length < 10) fail(400, 'Password must be at least 10 characters');
}

async function hashPassword(password, saltHex) {
  const key = await crypto.subtle.importKey('raw', enc.encode(password), 'PBKDF2', false, ['deriveBits']);
  const bits = await crypto.subtle.deriveBits(
    { name: 'PBKDF2', hash: 'SHA-256', salt: hexToBytes(saltHex), iterations: 100000 }, key, 256);
  return bytesToHex(new Uint8Array(bits));
}

async function notify(env, subject, text) {
  if (!env.RESEND_API_KEY || !env.ADMIN_EMAIL) return;
  try {
    await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ from: env.MAIL_FROM || 'Lytmoz <onboarding@resend.dev>', to: [env.ADMIN_EMAIL], subject, text })
    });
  } catch (e) { console.error('notify failed', e); }
}

function corsHeaders(origin, env) {
  const allowed = String(env.ALLOWED_ORIGINS || '').split(',').map((s) => s.trim()).filter(Boolean);
  const h = { 'Access-Control-Allow-Methods': 'GET, POST, PATCH, OPTIONS', 'Access-Control-Allow-Headers': 'Content-Type, Authorization', 'Access-Control-Max-Age': '86400', Vary: 'Origin' };
  if (allowed.includes(origin)) h['Access-Control-Allow-Origin'] = origin;
  return h;
}

const bearer = (req) => (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '').trim();
const publicUser = (u) => ({ id: u.id, email: u.email, name: u.name, role: u.role });
const clean = (v, max) => String(v ?? '').trim().slice(0, max);
const cents = (v) => Math.round(Number(v) * 100) || 0;
function fail(status, message) { const e = new Error(message); e.status = status; throw e; }
async function body(req) {
  try { return await req.json(); } catch { fail(400, 'Invalid request'); }
}
function json(data, status = 200, headers = {}) {
  return new Response(JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json', ...headers } });
}
function randomHex(n) { return bytesToHex(crypto.getRandomValues(new Uint8Array(n))); }
function bytesToHex(b) { return [...b].map((x) => x.toString(16).padStart(2, '0')).join(''); }
function hexToBytes(h) { return new Uint8Array(h.match(/../g).map((x) => parseInt(x, 16))); }
