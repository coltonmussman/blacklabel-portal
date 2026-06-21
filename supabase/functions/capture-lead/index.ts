import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// capture-lead (hardened + validated): server-side intake for National Coverage Group.
// Pipeline: Turnstile -> honeypot (soft when Turnstile passed, hard otherwise) -> consent gate
// -> rate limit + dedup -> SILENT contact validation (Twilio Lookup for phone, format +
// disposable-domain + optional verifier for email) -> insert via service role with server-stamped
// ip_address + timestamp -> optional Meta Conversions API 'Lead' on the BILLABLE signal.
// All external checks fail OPEN (an API outage never drops a real lead).
// verify_jwt = false. Each check activates only when its secret is configured.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const TURNSTILE_SECRET = Deno.env.get("TURNSTILE_SECRET") ?? "";
const TWILIO_SID = Deno.env.get("TWILIO_ACCOUNT_SID") ?? "";
const TWILIO_TOKEN = Deno.env.get("TWILIO_AUTH_TOKEN") ?? "";
const EMAIL_VERIFY_KEY = Deno.env.get("EMAIL_VERIFY_KEY") ?? ""; // ZeroBounce-style (optional)
const META_PIXEL_ID = Deno.env.get("META_PIXEL_ID") ?? "";       // Meta CAPI (optional; dormant until set)
const META_CAPI_TOKEN = Deno.env.get("META_CAPI_TOKEN") ?? "";   // Meta CAPI access token (optional)

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

async function sha256Hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

// Fire a Meta Conversions API 'Lead' on the BILLABLE signal (consent + cert + reachable phone),
// not the raw form-fill, so Meta optimizes toward sellable leads. Dormant until both secrets are set.
// Fail-open and time-bounded: a CAPI error or slowness never blocks lead intake.
async function fireCapiLead(lead: Record<string, any>, ip: string | null, origin: string | null) {
  if (!META_PIXEL_ID || !META_CAPI_TOKEN) return;
  const phoneDigits = String(lead.phone || "").replace(/\D/g, "");
  const billable = lead.consent_given === true && !!lead.trustedform_cert_url && phoneDigits.length >= 10;
  if (!billable) return;
  try {
    const user_data: Record<string, unknown> = {
      client_ip_address: ip || undefined,
      client_user_agent: lead.user_agent || undefined,
    };
    const email = String(lead.email || "").trim().toLowerCase();
    if (email && email !== "not provided" && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) user_data.em = [await sha256Hex(email)];
    const phoneE = phoneDigits.length === 10 ? "1" + phoneDigits : phoneDigits;
    if (phoneE) user_data.ph = [await sha256Hex(phoneE)];

    const srcUrl = origin && ALLOWED_ORIGINS.has(origin) ? origin + "/" : "https://nationalcoveragegroup.com/";
    const body = {
      data: [{
        event_name: "Lead",
        event_time: Math.floor(Date.now() / 1000),
        action_source: "website",
        event_id: crypto.randomUUID(), // if the client pixel is later enabled, send the same id to dedup
        event_source_url: srcUrl,
        user_data,
        custom_data: { lead_source: lead.source || undefined, content_category: lead.vertical || undefined },
      }],
    };
    await fetch(`https://graph.facebook.com/v19.0/${META_PIXEL_ID}/events?access_token=${encodeURIComponent(META_CAPI_TOKEN)}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(3000),
    });
  } catch (_e) {
    // fail-open: never block intake on a tracking call
  }
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  const headers = { ...cors(origin), "Content-Type": "application/json" };
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers });
  if (req.method !== "POST") return new Response(JSON.stringify({ error: "method_not_allowed" }), { status: 405, headers });

  let lead: Record<string, any>;
  try { lead = await req.json(); } catch { return new Response(JSON.stringify({ error: "bad_json" }), { status: 400, headers }); }

  const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || null;

  // Cloudflare Turnstile (enforced only when the secret is configured)
  let turnstilePassed = false;
  if (TURNSTILE_SECRET) {
    const token = lead["cf-turnstile-response"] ?? lead["turnstile_token"] ?? "";
    const form = new URLSearchParams({ secret: TURNSTILE_SECRET, response: String(token), remoteip: ip ?? "" });
    const v = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", { method: "POST", body: form });
    const out = await v.json().catch(() => ({}));
    if (out?.success !== true) return new Response(JSON.stringify({ error: "captcha_failed" }), { status: 403, headers });
    turnstilePassed = true;
  }

  // Honeypot: a hidden field was filled. When Turnstile is the active gate and already passed, this is
  // most likely browser/password-manager autofill on a real human -> log and continue (do NOT drop a
  // paying lead). When Turnstile is NOT configured, the honeypot is the only bot gate -> silent drop.
  if (HONEYPOTS.some((h) => lead[h])) {
    if (turnstilePassed) {
      console.warn("capture-lead: honeypot filled but Turnstile passed; treating as human");
    } else {
      return new Response(JSON.stringify({ ok: true }), { status: 200, headers });
    }
  }

  // Consent gate (server-side): never accept a record that does not assert consent. Both live forms
  // hardcode consent_given=true behind the checkbox, so legitimate traffic is unaffected; this blocks
  // crafted/partial posts. (The cert is enforced as the billable signal, not a hard reject, so a real
  // lead whose TrustedForm script was slow/blocked is still captured but not sold.)
  if (lead.consent_given !== true) return new Response(JSON.stringify({ error: "missing_consent" }), { status: 422, headers });

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

  // Optional Meta CAPI 'Lead' on the billable signal (dormant until META_PIXEL_ID + META_CAPI_TOKEN set).
  await fireCapiLead(lead, ip, origin);

  return new Response(JSON.stringify({ ok: true }), { status: 200, headers });
});
