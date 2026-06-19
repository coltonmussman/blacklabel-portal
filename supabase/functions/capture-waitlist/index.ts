import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// capture-waitlist (hardened): server-side intake for the agent apply form.
// Honeypot + Cloudflare Turnstile + per-IP rate limit, then inserts into
// agent_waitlist via service role. verify_jwt = false (public form endpoint).

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const TURNSTILE_SECRET = Deno.env.get("TURNSTILE_SECRET") ?? "";

const ALLOWED_ORIGINS = new Set([
  "https://blacklabelleads.app",
  "https://www.blacklabelleads.app",
]);
const HONEYPOTS = ["hp_field", "website", "company_website"];

function cors(origin: string | null) {
  const allow = origin && ALLOWED_ORIGINS.has(origin) ? origin : "https://blacklabelleads.app";
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

Deno.serve(async (req: Request) => {
  const headers = { ...cors(req.headers.get("origin")), "Content-Type": "application/json" };
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers });
  if (req.method !== "POST") return new Response(JSON.stringify({ error: "method_not_allowed" }), { status: 405, headers });

  let app: Record<string, any>;
  try { app = await req.json(); } catch { return new Response(JSON.stringify({ error: "bad_json" }), { status: 400, headers }); }

  for (const h of HONEYPOTS) { if (app[h]) return new Response(JSON.stringify({ ok: true }), { status: 200, headers }); }

  const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || null;

  if (TURNSTILE_SECRET) {
    const token = app["cf-turnstile-response"] ?? app["turnstile_token"] ?? "";
    const form = new URLSearchParams({ secret: TURNSTILE_SECRET, response: String(token), remoteip: ip ?? "" });
    const v = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", { method: "POST", body: form });
    const out = await v.json().catch(() => ({}));
    if (out?.success !== true) return new Response(JSON.stringify({ error: "captcha_failed" }), { status: 403, headers });
  }

  if (!app.email) return new Response(JSON.stringify({ error: "missing_email" }), { status: 422, headers });

  const allowed = await rpc("bl_rate_check", { p_ip: ip, p_max: 10 });
  if (allowed === false) return new Response(JSON.stringify({ error: "rate_limited" }), { status: 429, headers });

  for (const h of HONEYPOTS) delete app[h];
  delete app["cf-turnstile-response"];
  delete app["turnstile_token"];

  const resp = await fetch(`${SUPABASE_URL}/rest/v1/agent_waitlist`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "apikey": SERVICE_KEY, "Authorization": `Bearer ${SERVICE_KEY}`, "Prefer": "return=minimal" },
    body: JSON.stringify(app),
  });
  if (!resp.ok) { console.error("waitlist insert failed", resp.status, await resp.text()); return new Response(JSON.stringify({ error: "insert_failed" }), { status: 502, headers }); }
  return new Response(JSON.stringify({ ok: true }), { status: 200, headers });
});
