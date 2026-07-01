import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// notify-consumer — THE HANDSHAKE.
// Fired by the DB on a FRESH lead assignment (trg_notify_consumer_after_assign) with {lead_id}.
// Sends the consumer a welcome that introduces their one assigned licensed agent: an NCG-branded
// email (Resend) and, once 10DLC is live, an MMS with the agent card image (Twilio).
//
// DORMANT BY DESIGN. Nothing sends unless ALL of:
//   - bl_config.handshake_send_enabled = 'true'   (master kill switch, Colton flips at go-live)
//   - the channel's secret(s) are present (RESEND_API_KEY for email; TWILIO_* for MMS)
//   - the channel's sub-flag is 'true' (handshake_email_enabled / handshake_sms_enabled)
// Idempotent: claims the lead via bl_claim_handshake (atomic) so it sends at most once per lead.
// Holds if the lead is unassigned/vaulted (only fires once an agent is on it). Founder-fallback
// leads send the founder's card; a not-yet-completed card degrades gracefully (initials avatar, no
// phone line) rather than shipping a broken "call you from ." sentence. Fail-open: a send error
// never throws.
//
// SECURITY: verify_jwt = false. The endpoint is safe WITHOUT a shared secret because the lead is
// resolved server-side from an unguessable UUID and the send is idempotent (one Handshake per lead),
// so a replayed/forged call can at worst deliver the SAME consumer's legit Handshake once. We do NOT
// gate on a header secret: the DB trigger sends none, so adding one would silently 401 every real
// call. STOP is honored by Twilio Advanced Opt-Out on the Messaging Service.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const TWILIO_SID = Deno.env.get("TWILIO_ACCOUNT_SID") ?? "";
const TWILIO_TOKEN = Deno.env.get("TWILIO_AUTH_TOKEN") ?? "";
const TWILIO_FROM = Deno.env.get("TWILIO_FROM_NUMBER") ?? "";
const TWILIO_MSG_SID = Deno.env.get("TWILIO_MESSAGING_SERVICE_SID") ?? "";
const FROM_EMAIL_ENV = Deno.env.get("HANDSHAKE_FROM_EMAIL") ?? "";

const VERT: Record<string, string> = {
  final_expense: "Final Expense", mortgage_protection: "Mortgage Protection", iul: "IUL", annuity: "Annuity",
};
function vertLabel(v: string) { return VERT[v] || v || "coverage"; }

// Truthfulness guard: may the card claim "Specializing in <the vertical this lead requested>"?
// Only when the agent EXPLICITLY covers it. active_verticals/verticals store comma-separated
// LABELS ("Final Expense, IUL"). An empty list is NOT treated as "covers all" here — we never
// claim a specialty we can't point to (founder-fallback leads route on state license only and
// can land on an agent who doesn't run that vertical). Falls back to just the trust checkmarks.
function agentCoversVertical(agent: any, leadVertical: string): boolean {
  const label = vertLabel(leadVertical).toLowerCase();
  const raw = ((agent.active_verticals && String(agent.active_verticals)) ||
               (agent.verticals && String(agent.verticals)) || "").trim();
  if (!raw) return false;
  return raw.split(/[,;/\n]+/).map((s: string) => s.trim().toLowerCase()).includes(label);
}

// Three fixed trust checkmarks — identical for every agent, every lead.
const TRUST_LINES = ["Licensed in your state", "One agent, never a call center", "Free quote, no obligation"];

function esc(s: unknown) {
  return String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/\"/g, "&quot;");
}

async function rest(path: string) {
  try {
    const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
      headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
    });
    return r.ok ? await r.json() : [];
  } catch { return []; }
}

async function rpcClaim(leadId: string): Promise<boolean> {
  try {
    const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/bl_claim_handshake`, {
      method: "POST",
      headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({ p_lead_id: leadId }),
    });
    if (!r.ok) return false;
    const v = await r.json();
    return v === true;
  } catch { return false; }
}

function firstName(n: unknown) { return String(n ?? "").trim() || "there"; }

function cardName(agent: any): string {
  const dn = (agent.display_title && String(agent.display_title).trim()) || "";
  if (dn) return dn;
  return `${agent.first_name ?? ""} ${agent.last_name ?? ""}`.trim() || "Your licensed agent";
}

function buildEmailHtml(lead: any, agent: any, dateStr: string): string {
  const name = cardName(agent);
  const title = (agent.agent_card_title && String(agent.agent_card_title).trim()) || "Licensed Insurance Agent";
  const intro = (agent.intro_line && String(agent.intro_line).trim()) || "";
  const dialRaw = String(agent.dial_number || "").trim();
  const dial = esc(dialRaw);
  const npn = (agent.npn && String(agent.npn).trim()) || "";
  const vlabel = vertLabel(lead.vertical || "");
  const active = agent.card_status === "active" && agent.headshot_url;

  const head = active
    ? `<img src="${esc(agent.headshot_url)}" width="84" height="84" alt="${esc(name)}" style="display:block;margin:0 auto;border-radius:50%;border:3px solid #ffffff;object-fit:cover;">`
    : `<div style="width:84px;height:84px;border-radius:50%;background:#9bb8d6;color:#0f2747;font-size:30px;font-weight:bold;line-height:84px;text-align:center;margin:0 auto;font-family:Georgia,serif;">${esc((name[0] || "A").toUpperCase())}</div>`;

  // Per-lead specialty line: only when the agent explicitly covers THIS lead's vertical.
  const specialtyLine = agentCoversVertical(agent, lead.vertical || "")
    ? `<div style="font-size:13px;font-weight:bold;color:#13294b;margin:10px 0 6px;">Specializing in ${esc(vlabel)}</div>`
    : "";
  // Three fixed trust checkmarks (identical for every agent).
  const trustBlock = TRUST_LINES.map((t) =>
    `<div style="font-size:13px;color:#1f2a37;margin:4px 0;"><span style="color:#2f6fed;font-weight:bold;">&#10003;</span>&nbsp; ${esc(t)}</div>`
  ).join("");
  const specBlock = specialtyLine + trustBlock;
  const introBlock = intro ? `<div style="font-size:13px;color:#374151;line-height:1.5;margin-top:4px;">${esc(intro)}</div>` : "";
  const npnLine = npn
    ? `<div style="color:#c4d3e6;font-size:12px;margin-top:6px;">NPN ${esc(npn)} &middot; Licensed &amp; Trusted</div>`
    : `<div style="color:#c4d3e6;font-size:12px;margin-top:6px;">Licensed &amp; Trusted</div>`;
  // Phone line only when the agent has actually set a call-from number (graceful degrade otherwise).
  const phoneLine = dialRaw ? `<div style="color:#eef3fa;font-size:15px;font-weight:bold;">&#9742;&nbsp; ${dial}</div>` : "";
  const expectLine = dialRaw
    ? `<b>Expect a call shortly</b> from ${dial}. You requested a ${esc(vlabel)} quote at NationalCoverageGroup.com on ${esc(dateStr)}.`
    : `<b>Expect a call shortly.</b> You requested a ${esc(vlabel)} quote at NationalCoverageGroup.com on ${esc(dateStr)}.`;

  return `<div style="margin:0;padding:0;background:#eef3fa;font-family:Arial,Helvetica,sans-serif;">` +
    `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#eef3fa;padding:24px 0;"><tr><td align="center">` +
    `<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:#ffffff;border-radius:14px;overflow:hidden;border:1px solid #dfe3ea;">` +
    `<tr><td style="background:#0f2747;padding:16px 24px;"><span style="color:#ffffff;font-size:16px;font-weight:bold;letter-spacing:1px;">NATIONAL <span style="color:#5a8df0;">COVERAGE</span> GROUP</span><div style="color:#9fb3d0;font-size:10px;letter-spacing:3px;margin-top:2px;">LICENSED INSURANCE</div></td></tr>` +
    `<tr><td style="padding:22px 24px 4px;color:#13233d;font-size:16px;">Hi ${esc(firstName(lead.first_name))},</td></tr>` +
    `<tr><td style="padding:2px 24px 14px;color:#41506a;font-size:14px;line-height:1.55;">Thanks for requesting your free quote from National Coverage Group. Your request goes to <b>one licensed agent, and only you</b>. Here is who will reach out:</td></tr>` +
    `<tr><td style="padding:0 24px 8px;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border:1px solid #e2e7f0;border-radius:12px;overflow:hidden;"><tr>` +
    `<td width="130" valign="top" style="background:#cfe2f3;padding:18px 12px;text-align:center;">${head}</td>` +
    `<td valign="top" style="padding:16px 18px;"><div style="font-size:21px;font-weight:bold;color:#13294b;font-family:Georgia,serif;">${esc(name)}</div>` +
    `<div style="font-size:13px;font-weight:bold;color:#13294b;letter-spacing:.3px;margin-top:2px;">${esc(title.toUpperCase())}</div>` +
    `<div style="height:2px;width:90px;background:#2f6fed;margin:8px 0;"></div>${introBlock}${specBlock}</td>` +
    `</tr><tr><td colspan="2" style="background:#0f2747;padding:13px 18px;">${phoneLine}${npnLine}</td></tr></table></td></tr>` +
    `<tr><td style="padding:16px 24px 4px;color:#13233d;font-size:14px;line-height:1.55;">${expectLine}</td></tr>` +
    `<tr><td style="padding:6px 24px 18px;color:#41506a;font-size:13px;line-height:1.55;">We never sell your information to call-center lists. One licensed agent contacts you, that is it.</td></tr>` +
    `<tr><td style="background:#f4f7fb;padding:16px 24px;color:#7a87a0;font-size:11px;line-height:1.5;border-top:1px solid #e2e7f0;">&copy; 2026 National Coverage Group, a service of Black Label Leads. An insurance quote and referral service, not an insurance company. Reply STOP to opt out of texts. Opt out or questions: blacklabelleads@gmail.com</td></tr>` +
    `</table></td></tr></table></div>`;
}

async function sendEmail(toEmail: string, fromEmail: string, subject: string, html: string) {
  await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${RESEND_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      from: fromEmail,
      to: [toEmail],
      subject,
      html,
      headers: { "List-Unsubscribe": "<mailto:blacklabelleads@gmail.com?subject=unsubscribe>" },
    }),
  });
}

async function sendMms(toPhone: string, body: string, mediaUrl: string) {
  const form = new URLSearchParams();
  form.set("To", toPhone);
  if (TWILIO_MSG_SID) form.set("MessagingServiceSid", TWILIO_MSG_SID); else form.set("From", TWILIO_FROM);
  form.set("Body", body);
  if (mediaUrl) form.set("MediaUrl", mediaUrl);
  await fetch(`https://api.twilio.com/2010-04-01/Accounts/${TWILIO_SID}/Messages.json`, {
    method: "POST",
    headers: { Authorization: "Basic " + btoa(`${TWILIO_SID}:${TWILIO_TOKEN}`), "Content-Type": "application/x-www-form-urlencoded" },
    body: form.toString(),
  });
}

Deno.serve(async (req: Request) => {
  const ok = () => new Response(JSON.stringify({ ok: true }), { status: 200, headers: { "Content-Type": "application/json" } });
  if (req.method !== "POST") return new Response(JSON.stringify({ error: "method_not_allowed" }), { status: 405, headers: { "Content-Type": "application/json" } });

  let body: any;
  try { body = await req.json(); } catch { return ok(); }
  const leadId = body?.lead_id;
  if (!leadId) return ok();

  try {
    // Config: master flag + per-channel flags + sender.
    const cfgRows = await rest(`bl_config?key=in.(handshake_send_enabled,handshake_email_enabled,handshake_sms_enabled,handshake_from_email)&select=key,value`);
    const cfg: Record<string, string> = {};
    for (const row of cfgRows) cfg[row.key] = row.value;
    if (cfg.handshake_send_enabled !== "true") return ok(); // master kill switch (dormant)

    const emailOn = (cfg.handshake_email_enabled ?? "true") === "true";
    const smsOn = (cfg.handshake_sms_enabled ?? "true") === "true";
    const fromEmail = FROM_EMAIL_ENV || cfg.handshake_from_email || "National Coverage Group <hello@nationalcoveragegroup.com>";

    // Lead — hold if unassigned/vaulted.
    const leads = await rest(`leads?id=eq.${leadId}&select=assigned_agent_id,first_name,last_name,email,phone,state,vertical,submitted_at,created_at,handshake_sent_at&limit=1`);
    const lead = leads[0];
    if (!lead || !lead.assigned_agent_id) return ok();

    const hasEmail = !!(lead.email && String(lead.email).includes("@"));
    const hasPhone = !!(lead.phone && String(lead.phone).trim());
    const emailReady = emailOn && !!RESEND_KEY && hasEmail;
    const smsReady = smsOn && !!TWILIO_SID && !!TWILIO_TOKEN && (!!TWILIO_FROM || !!TWILIO_MSG_SID) && hasPhone;
    if (!emailReady && !smsReady) return ok(); // nothing we can send; do NOT claim, let a later send try

    // Atomic, idempotent claim — at most one Handshake per lead.
    const claimed = await rpcClaim(leadId);
    if (!claimed) return ok();

    // Agent card.
    const agents = await rest(`agent_profiles?id=eq.${lead.assigned_agent_id}&select=first_name,last_name,npn,dial_number,agent_card_title,display_title,intro_line,headshot_url,card_image_url,card_status,active_verticals,verticals&limit=1`);
    const agent = agents[0];
    if (!agent) return ok();

    const dateStr = new Date((lead.submitted_at || lead.created_at) ?? Date.now()).toLocaleDateString("en-US", { month: "long", day: "numeric", timeZone: "America/Chicago" });
    const vlabel = vertLabel(lead.vertical || "");
    const agentFirst = String(agent.first_name ?? "").trim() || "your licensed agent";

    if (emailReady) {
      try {
        const subject = `Your ${vlabel} quote — your licensed agent is ${agentFirst}`;
        const html = buildEmailHtml(lead, agent, dateStr);
        await sendEmail(lead.email, fromEmail, subject, html);
      } catch (_e) { /* fail-open */ }
    }

    if (smsReady) {
      try {
        const dial = String(agent.dial_number || "").trim();
        const cardImg = (agent.card_status === "active" && agent.card_image_url) ? String(agent.card_image_url) : "";
        const msg = `National Coverage Group: Thanks for your request! Your licensed agent ${agentFirst}${dial ? ` will call you shortly from ${dial}` : " will call you shortly"} about your ${vlabel} quote. Reply STOP to opt out.`;
        await sendMms(lead.phone, msg, cardImg);
      } catch (_e) { /* fail-open (incl. Twilio STOP 21610) */ }
    }
  } catch (_e) {
    // fail-open — never block on a notification
  }
  return ok();
});
