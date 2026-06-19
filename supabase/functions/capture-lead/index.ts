import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// capture-lead (hardened + validated): server-side intake for National Coverage Group.
// Pipeline: honeypot -> Turnstile -> rate limit + dedup -> SILENT contact validation
// (Twilio Lookup for phone, format + disposable-domain + optional verifier for email)
// -> insert via service role with server-stamped ip_address + timestamp.
// All external checks fail OPEN (an API outage never drops a real lead).
// verify_jwt = false. Each check activates only when its secret is configured.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const TURNSTILE_SECRET = Deno.env.get("TURNSTILE_SECRET") ?? "";
const TWILIO_SID = Deno.env.get("TWILIO_ACCOUNT_SID") ?? "";
const TWILIO_TOKEN = Deno.env.get("TWILIO_AUTH_TOKEN") ?? "";
const EMAIL_VERIFY_KEY = Deno.env.get("EMAIL_VERIFY_KEY") ?? ""; // ZeroBounce-style (optional)

const ALLOWED_ORIGINS = new Set([
  "https://nationalcoveragegroup.com",
  "https://www.nationalcoveragegroup.com",
]);
const HONEYPOTS = ["hp_field", "website", "company_website"];
const DISPOSABLE = new Set([
  "mailinator.com","guerrillamail.com","10minutemail.com","tempmail.com","temp-mail.org",
  "trashmail.com","yopmail.com","getnada.com","dispostable.com","fakeinbox.com","sharklasers.com",
  "guerrillamailblock.com","throwawaymail.com","maildrop.cc","mailnesia.com","mintemail.com",
  "mohmal.com","tempinbox.com","emailondeck.com","spam4.me","grr.la","tempr.email","discard.email",
  "mailcatch.com","burnermail.io","getairmail.com","moakt.com","nada.email","easytrashmail.com",
  "test.com","example.com","none.com","email.com","test.test"
]);

function cors(origin: string | null) {
  const allow = origin && ALLOWED_ORIGINS.has(origin) ? origin : "https://nationalcoveragegroup.com";
  return { "Access-Control-Allow-Origin": allow, "Access-Control-Allow-Methods": "POST, OPTIONS", "Access-Control-Allow-Headers": "content-type", "Vary": "Origin" };
}

async function rpc(name: string, args: Record<string, unknown>) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "apikey": SERVICE_KEY, "Authorization": `Bearer ${SERVICE_KEY}` },
    body: JSON.stringify(args),
  });
  return r.ok ? await r.json() : null;
}

function emailBasicValid(email: string) {
  const e = String(email || "").trim().toLowerCase();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e)) return false;
  const domain = e.split("@")[1];
  if (DISPOSABLE.has(domain)) return false;
  return true;
}

async function emailDeliverable(email: string): Promise<boolean> {
  if (!EMAIL_VERIFY_KEY) return true; // optional layer; skip if not configured
  try {
    const r = await fetch(`https://api.zerobounce.net/v2/validate?api_key=${EMAIL_VERIFY_KEY}&email=${encodeURIComponent(email)}`);
    if (!r.ok) return true; // fail open
    const d = await r.json();
    return !["invalid", "spamtrap", "abuse", "do_not_mail"].includes(String(d?.status || ""));
  } catch { return true; }
}

async function phoneValid(raw: string): Promise<boolean> {
  if (!TWILIO_SID || !TWILIO_TOKEN) return true; // skip if not configured
  const digits = String(raw || "").replace(/\D/g, "");
  const e164 = digits.length === 10 ? "+1" + digits : (digits.length === 11 && digits[0] === "1" ? "+" + digits : null);
  if (!e164) return false;
  try {
    const auth = btoa(`${TWILIO_SID}:${TWILIO_TOKEN}`);
    const r = await fetch(`https://lookups.twilio.com/v2/PhoneNumbers/${e164}`, { headers: { Authorization: `Basic ${auth}` } });
    if (!r.ok) return true; // fail open on API/credential error
    const d = await r.json();
    return d?.valid !== false;
  } catch { return true; }
}

Deno.serve(async (req: Request) => {
  const headers = { ...cors(req.headers.get("origin")), "Content-Type": "application/json" };
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers });
  if (req.method !== "POST") return new Response(JSON.stringify({ error: "method_not_allowed" }), { status: 405, headers });

  let lead: Record<string, any>;
  try { lead = await req.json(); } catch { return new Response(JSON.stringify({ error: "bad_json" }), { status: 400, headers }); }

  // honeypot: a bot filled a hidden field -> pretend success, drop it
  for (const h of HONEYPOTS) { if (lead[h]) return new Response(JSON.stringify({ ok: true }), { status: 200, headers }); }

  const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || null;

  // Cloudflare Turnstile (enforced only when the secret is configured)
  if (TURNSTILE_SECRET) {
    const token = lead["cf-turnstile-response"] ?? lead["turnstile_token"] ?? "";
    const form = new URLSearchParams({ secret: TURNSTILE_SECRET, response: String(token), remoteip: ip ?? "" });
    const v = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", { method: "POST", body: form });
    const out = await v.json().catch(() => ({}));
    if (out?.success !== true) return new Response(JSON.stringify({ error: "captcha_failed" }), { status: 403, headers });
  }

  if (!lead.phone && !lead.email) return new Response(JSON.stringify({ error: "missing_contact" }), { status: 422, headers });

  // per-IP rate limit + duplicate guard (cheap/local; blocks floods before paid lookups)
  const pre = await rpc("bl_precheck_lead", { p_ip: ip, p_phone: lead.phone ?? null, p_email: lead.email ?? null });
  if (pre && pre.ok === false) {
    const status = pre.reason === "rate_limited" ? 429 : 409;
    return new Response(JSON.stringify({ error: pre.reason }), { status, headers });
  }

  // SILENT contact validation
  if (lead.email) {
    if (!emailBasicValid(lead.email)) return new Response(JSON.stringify({ error: "invalid_email" }), { status: 422, headers });
    if (!(await emailDeliverable(lead.email))) return new Response(JSON.stringify({ error: "invalid_email" }), { status: 422, headers });
  }
  if (lead.phone) {
    if (!(await phoneValid(lead.phone))) return new Response(JSON.stringify({ error: "invalid_phone" }), { status: 422, headers });
  }

  // strip control/honeypot fields, stamp server truth
  for (const h of HONEYPOTS) delete lead[h];
  delete lead["cf-turnstile-response"];
  delete lead["turnstile_token"];
  lead.ip_address = ip;
  lead.submitted_at = new Date().toISOString();
  lead.user_agent = req.headers.get("user-agent") ?? lead.user_agent ?? null;

  const resp = await fetch(`${SUPABASE_URL}/rest/v1/leads`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "apikey": SERVICE_KEY, "Authorization": `Bearer ${SERVICE_KEY}`, "Prefer": "return=minimal" },
    body: JSON.stringify(lead),
  });
  if (!resp.ok) { console.error("insert failed", resp.status, await resp.text()); return new Response(JSON.stringify({ error: "insert_failed" }), { status: 502, headers }); }
  return new Response(JSON.stringify({ ok: true }), { status: 200, headers });
});
