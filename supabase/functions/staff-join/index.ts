// Accepts a Lytmoz staff invitation for someone who has no account yet.
// The secret invitation link is the proof: we create their account with the invited email,
// mark them as an organization member (not a client) and place them in their department.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const ALLOWED_ORIGINS = ['https://lytmoz.com', 'https://www.lytmoz.com', 'https://mozlyt.github.io', 'http://localhost:8811'];
function cors(origin: string) {
  const h: Record<string, string> = {
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Vary': 'Origin',
  };
  if (ALLOWED_ORIGINS.includes(origin)) h['Access-Control-Allow-Origin'] = origin;
  return h;
}
function reply(body: unknown, status: number, origin: string) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors(origin), 'Content-Type': 'application/json' } });
}

Deno.serve(async (req) => {
  const origin = req.headers.get('Origin') ?? '';
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors(origin) });
  if (req.method !== 'POST') return reply({ error: 'Not found' }, 404, origin);

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  let b: Record<string, unknown>;
  try { b = await req.json(); } catch { return reply({ error: 'Invalid request' }, 400, origin); }

  const token = String(b.token ?? '').trim();
  const name = String(b.name ?? '').trim().slice(0, 120);
  const password = String(b.password ?? '');
  if (token.length < 40 || token.length > 100) return reply({ error: 'This invitation link is not valid.' }, 400, origin);
  if (!name) return reply({ error: 'Please enter your name' }, 400, origin);
  if (password.length < 8) return reply({ error: 'Password must be at least 8 characters' }, 400, origin);

  try {
    const { data: inv } = await admin.from('staff_invites').select('id, email, status, expires_at').eq('token', token).maybeSingle();
    if (!inv) return reply({ error: 'This invitation link is not valid.' }, 404, origin);
    if (inv.status === 'accepted') return reply({ error: 'This invitation has already been used. Sign in to HQ instead.' }, 409, origin);
    if (inv.status === 'revoked') return reply({ error: 'This invitation was withdrawn. Ask Lytmoz for a new one.' }, 410, origin);
    if (new Date(inv.expires_at).getTime() < Date.now()) return reply({ error: 'This invitation has expired. Ask Lytmoz to send it again.' }, 410, origin);

    const { data: existing } = await admin.from('profiles').select('id').eq('email', inv.email).maybeSingle();
    if (existing) return reply({ error: 'This email already has a Lytmoz account. Sign in with it to accept.', code: 'has_account' }, 409, origin);

    const { data: made, error } = await admin.auth.admin.createUser({ email: inv.email, password, email_confirm: true, user_metadata: { name } });
    if (error || !made?.user) return reply({ error: /already/i.test(error?.message ?? '') ? 'This email already has an account. Sign in with it to accept.' : (error?.message ?? 'Could not create the account') }, 400, origin);
    const uid = made.user.id;

    const { error: pErr } = await admin.from('profiles').upsert({ id: uid, name, email: inv.email, role: 'staff' }, { onConflict: 'id' });
    if (pErr) { await admin.auth.admin.deleteUser(uid); return reply({ error: 'Could not save your profile' }, 400, origin); }

    const { error: aErr } = await admin.rpc('accept_invite_as', { tok: token, uid });
    if (aErr) { await admin.auth.admin.deleteUser(uid); return reply({ error: aErr.message }, 400, origin); }

    return reply({ ok: true, email: inv.email }, 201, origin);
  } catch (e) {
    console.error(e);
    return reply({ error: 'Something went wrong on our side.' }, 500, origin);
  }
});
