// Confirms a Paystack payment against a Lytmoz invoice.
// The client pays in the portal, then sends us the reference. We ask Paystack
// whether the money really arrived, and only then record a confirmed payment.
// Needs the secret PAYSTACK_SECRET_KEY (set in Supabase, never in the website).
import { createClient } from "jsr:@supabase/supabase-js@2";

const ORIGINS = ["https://lytmoz.com", "https://www.lytmoz.com"];
function cors(req: Request) {
  const o = req.headers.get("origin") || "";
  return {
    "Access-Control-Allow-Origin": ORIGINS.includes(o) ? o : ORIGINS[0],
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

Deno.serve(async (req: Request) => {
  const headers = { ...cors(req), "Content-Type": "application/json" };
  const out = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers });
  if (req.method === "OPTIONS") return new Response("ok", { headers });
  if (req.method !== "POST") return out({ ok: false, error: "Method not allowed" }, 405);

  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    // Who is asking?
    const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: auth } = await admin.auth.getUser(token);
    const user = auth?.user;
    if (!user) return out({ ok: false, error: "Please sign in again." }, 401);

    const body = await req.json().catch(() => ({}));
    const reference = String(body.reference || "").trim();
    const invoiceId = Number(body.invoice_id);
    if (!/^LZ[A-Z0-9-]{6,60}$/.test(reference) || !Number.isInteger(invoiceId)) return out({ ok: false, error: "Bad request" }, 400);

    // Can this person see the invoice? (uses their own login, so database rules apply)
    const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY") || "sb_publishable_oUnHKZ1NqD1Q7_aKe40Riw_xaMh6e3e", { global: { headers: { Authorization: "Bearer " + token } } });
    const { data: inv } = await asUser.from("invoices").select("id, amount_cents, paid_cents, currency, status").eq("id", invoiceId).maybeSingle();
    if (!inv) return out({ ok: false, error: "Invoice not found" }, 404);

    // Already recorded? Then we are done.
    const { data: seen } = await admin.from("payments").select("id, invoice_id").eq("reference", reference).eq("verified_by", "paystack").maybeSingle();
    if (seen) return out({ ok: seen.invoice_id === invoiceId, confirmed: seen.invoice_id === invoiceId });

    const secret = Deno.env.get("PAYSTACK_SECRET_KEY");
    if (!secret) return out({ ok: false, code: "no_key" });

    const res = await fetch("https://api.paystack.co/transaction/verify/" + encodeURIComponent(reference), { headers: { Authorization: "Bearer " + secret } });
    const ps = await res.json().catch(() => null);
    const t = ps?.data;
    if (!res.ok || !t) return out({ ok: false, code: "not_found" });
    if (t.status !== "success") return out({ ok: false, code: "not_paid", status: t.status });

    // The payment must have been made for this invoice, in its currency.
    const meta = typeof t.metadata === "string" ? JSON.parse(t.metadata || "{}") : (t.metadata || {});
    if (String(meta.lytmoz_invoice) !== String(invoiceId) || t.currency !== inv.currency) return out({ ok: false, code: "mismatch" });

    const { error } = await admin.from("payments").insert({
      invoice_id: invoiceId, client_id: user.id, method: "online", amount_cents: t.amount, currency: t.currency,
      reference, note: "Paystack · " + (t.channel || "online"), status: "confirmed", verified_by: "paystack", reviewed_at: new Date().toISOString(),
    });
    if (error && error.code !== "23505") throw error;
    return out({ ok: true, confirmed: true, amount_cents: t.amount, currency: t.currency });
  } catch (e) {
    console.error(e);
    return out({ ok: false, error: "Something went wrong on our side." }, 500);
  }
});
