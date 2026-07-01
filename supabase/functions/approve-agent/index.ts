import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// approve-agent — owner-only. Creates an agent's auth account FROM their waitlist row using their
// EXACT application email, then emails them a Black Label-branded "set your password" invite (via
// Resend, pointing at welcome.html). Because the email always comes from the application, the
// handle_new_user trigger copies their name + NPN into agent_profiles automatically, every time.
//
// SECURITY: the caller must be the OWNER. We re-resolve the caller from their Bearer token via
// GoTrue (/auth/v1/user) and require email === OWNER_EMAIL. The service-role key (admin API) never
// leaves this function. It can only ever create a user for an EXISTING waitlist row (by id) — never
// an arbitrary email. Does NOT touch routing / consent / Stripe / notify-consumer.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const OWNER_EMAIL = "blacklabelleads@gmail.com";
// Agent-facing sender. blacklabelleads.app is verified in Resend (confirmed 2026-07-01 via a live
// test send), so invites come from the Black Label domain. Override with the AGENT_INVITE_FROM secret.
const INVITE_FROM = Deno.env.get("AGENT_INVITE_FROM") || "Black Label Leads <hello@blacklabelleads.app>";
const WELCOME_URL = "https://portal.blacklabelleads.app/welcome.html";

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "content-type, authorization, apikey",
};

function esc(s: unknown) {
  return String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/\"/g, "&quot;");
}

function inviteEmailHtml(firstName: string, link: string): string {
  const hi = esc(String(firstName || "").trim() || "there");
  const href = esc(link);
  return `<div style="margin:0;padding:0;background:#0e0f12;font-family:Arial,Helvetica,sans-serif;">` +
    `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#0e0f12;padding:28px 0;"><tr><td align="center">` +
    `<table role="presentation" width="560" cellpadding="0" cellspacing="0" style="max-width:560px;width:100%;background:#16181d;border-radius:14px;overflow:hidden;border:1px solid #2a2e37;">` +
    `<tr><td style="padding:22px 28px 6px;"><span style="color:#f4f6f8;font-size:18px;font-weight:bold;letter-spacing:2px;">BLACK <span style="color:#aeb4bc;">LABEL</span> LEADS</span><div style="color:#7a8189;font-size:10px;letter-spacing:3px;margin-top:3px;">AGENT PORTAL</div></td></tr>` +
    `<tr><td style="padding:12px 28px 0;color:#f4f6f8;font-size:22px;font-weight:bold;font-family:Georgia,serif;">You're approved.</td></tr>` +
    `<tr><td style="padding:10px 28px 4px;color:#c7ccd3;font-size:15px;line-height:1.6;">Hi ${hi}, your Black Label Leads agent account is ready. Set your password to sign in and finish your quick setup, then your exclusive leads start flowing.</td></tr>` +
    `<tr><td style="padding:22px 28px 8px;"><a href="${href}" style="display:inline-block;background:#e9ecef;color:#101113;font-weight:bold;font-size:15px;text-decoration:none;padding:13px 26px;border-radius:10px;">Set your password</a></td></tr>` +
    `<tr><td style="padding:6px 28px 22px;color:#8a9099;font-size:12px;line-height:1.6;">This link is single-use and expires. If it stops working, go to the sign-in page and use <b style="color:#c7ccd3;">Forgot your password?</b> to get a fresh one. If a button doesn't work, copy this link:<br><span style="color:#7a8189;word-break:break-all;">${href}</span></td></tr>` +
    `<tr><td style="background:#101113;padding:16px 28px;color:#6b7178;font-size:11px;line-height:1.5;border-top:1px solid #2a2e37;">You're receiving this because you applied at blacklabelleads.app and were approved. If this wasn't you, ignore this email and no account will be usable.</td></tr>` +
    `</table></td></tr></table></div>`;
}

async function svcFetch(path: string, init?: RequestInit) {
  return fetch(`${SUPABASE_URL}${path}`, {
    ...init,
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json", ...(init?.headers || {}) },
  });
}

Deno.serve(async (req: Request) => {
  const json = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { "Content-Type": "application/json", ...CORS } });
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  let body: any; try { body = await req.json(); } catch { body = {}; }

  // ---- owner gate: re-resolve the caller from their Bearer token; must be the owner ----
  const authz = req.headers.get("Authorization") || "";
  if (!authz.startsWith("Bearer ")) return json({ error: "unauthorized" }, 401);
  let caller: any = null;
  try {
    const u = await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: { apikey: SERVICE_KEY, Authorization: authz } });
    caller = u.ok ? await u.json() : null;
  } catch { caller = null; }
  if (!caller || String(caller.email || "").toLowerCase() !== OWNER_EMAIL) return json({ error: "forbidden" }, 403);

  const waitlistId = body?.waitlist_id;
  if (!waitlistId) return json({ error: "missing_waitlist_id" }, 400);

  // ---- load the waitlist row (service role) ----
  const rows = await (await svcFetch(`/rest/v1/agent_waitlist?id=eq.${encodeURIComponent(waitlistId)}&select=id,first_name,email,approved_at&limit=1`)).json().catch(() => []);
  const w = rows?.[0];
  if (!w) return json({ error: "applicant_not_found" }, 404);
  const email = String(w.email || "").trim().toLowerCase();
  if (!email) return json({ error: "applicant_has_no_email" }, 400);

  // ---- atomically CLAIM the approval (flip approved_at null -> now()); only the winning call
  //      proceeds, so a double-click or network retry can never send two invites. ----
  const claimRes = await svcFetch(`/rest/v1/agent_waitlist?id=eq.${encodeURIComponent(waitlistId)}&approved_at=is.null`, {
    method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify({ approved_at: new Date().toISOString() }),
  });
  const claimedRows = await claimRes.json().catch(() => []);
  if (!claimRes.ok) return json({ ok: false, stage: "claim", status: claimRes.status }, 500);
  if (!Array.isArray(claimedRows) || claimedRows.length === 0) {
    return json({ ok: true, already_approved: true, email, message: "This applicant was already approved." });
  }
  const releaseClaim = () => svcFetch(`/rest/v1/agent_waitlist?id=eq.${encodeURIComponent(waitlistId)}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ approved_at: null }) });

  // ---- create the user + invite link (type=invite creates the user; handle_new_user copies name/NPN) ----
  const gl = await svcFetch(`/auth/v1/admin/generate_link`, { method: "POST", body: JSON.stringify({ type: "invite", email, redirect_to: WELCOME_URL }) });
  const glBody = await gl.json().catch(() => ({}));
  if (!gl.ok) {
    const msg = glBody?.msg || glBody?.error_description || glBody?.error || JSON.stringify(glBody);
    // 422 = already registered: the account already exists, so keep it marked approved and tell the owner.
    if (gl.status === 422) return json({ ok: false, stage: "create_user", status: 409, detail: msg, hint: "An account already exists for this email. Have them use Forgot your password on the sign-in page." }, 409);
    await releaseClaim(); // transient failure: release the claim so Approve can be retried
    return json({ ok: false, stage: "create_user", status: gl.status, detail: msg }, 500);
  }
  const link = String(glBody?.action_link || "");

  // ---- send the branded invite via Resend (non-fatal: the account already exists either way) ----
  let emailSent = false, resendInfo = "no_resend_key";
  if (RESEND_KEY && link) {
    try {
      const r = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { Authorization: `Bearer ${RESEND_KEY}`, "Content-Type": "application/json" },
        body: JSON.stringify({ from: INVITE_FROM, to: [email], subject: "You're approved - set up your Black Label Leads account", html: inviteEmailHtml(w.first_name, link) }),
      });
      resendInfo = await r.text(); emailSent = r.ok;
    } catch (e) { resendInfo = String(e); }
  }

  return json({ ok: true, email, account_created: true, invite_email_sent: emailSent, resend: resendInfo });
});
