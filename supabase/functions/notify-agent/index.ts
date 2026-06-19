import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// notify-agent — THE DROP alert, SMS channel.
// Called from the DB (auto_assign AFTER-insert trigger + bl_drain_vault_for_agent) with {lead_id}.
// Email is sent separately from the DB (vault Resend key). This function only sends the Twilio SMS,
// and only when: the lead is really assigned, the agent has sms_opt_in=true + a cell_phone, AND a
// Twilio sender (number or Messaging Service) is configured. Until the sender env var is set it
// no-ops (inert). Everything is derived from lead_id server-side, so it can't be used to text
// arbitrary numbers. Fail-open: a send error never blocks lead delivery. verify_jwt = false.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const TWILIO_SID = Deno.env.get("TWILIO_ACCOUNT_SID") ?? "";
const TWILIO_TOKEN = Deno.env.get("TWILIO_AUTH_TOKEN") ?? "";
const TWILIO_FROM = Deno.env.get("TWILIO_FROM_NUMBER") ?? "";
const TWILIO_MSG_SID = Deno.env.get("TWILIO_MESSAGING_SERVICE_SID") ?? "";
const NOTIFY_SECRET = Deno.env.get("NOTIFY_SECRET") ?? "";

const PORTAL = "https://portal.blacklabelleads.app/portal.html";

async function rest(path: string) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
  });
  return r.ok ? await r.json() : [];
}

function vertLabel(v: string) {
  const m: Record<string, string> = {
    final_expense: "Final Expense", mortgage_protection: "Mortgage Protection", iul: "IUL", annuity: "Annuity",
  };
  return m[v] || v || "";
}

Deno.serve(async (req: Request) => {
  const ok = () => new Response(JSON.stringify({ ok: true }), { status: 200, headers: { "Content-Type": "application/json" } });
  if (req.method !== "POST") return new Response(JSON.stringify({ error: "method_not_allowed" }), { status: 405, headers: { "Content-Type": "application/json" } });
  if (NOTIFY_SECRET && req.headers.get("x-notify-secret") !== NOTIFY_SECRET) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: { "Content-Type": "application/json" } });
  }

  let body: any;
  try { body = await req.json(); } catch { return ok(); }
  const leadId = body?.lead_id;
  if (!leadId) return ok();

  try {
    const leads = await rest(`leads?id=eq.${leadId}&select=assigned_agent_id,first_name,last_name,state,vertical&limit=1`);
    const lead = leads[0];
    if (!lead || !lead.assigned_agent_id) return ok();

    const agents = await rest(`agent_profiles?id=eq.${lead.assigned_agent_id}&select=cell_phone,sms_opt_in&limit=1`);
    const agent = agents[0];
    if (!agent || agent.sms_opt_in !== true || !agent.cell_phone) return ok();

    if (!TWILIO_SID || !TWILIO_TOKEN || (!TWILIO_FROM && !TWILIO_MSG_SID)) return ok();

    const name = `${lead.first_name ?? ""} ${(lead.last_name ?? "").slice(0, 1)}`.trim();
    const where = `${lead.state ?? ""}/${vertLabel(lead.vertical ?? "")}`;
    const msg = `Black Label: a lead just dropped - ${name}. ${where}. Call now: ${PORTAL} Reply STOP to opt out.`;

    const form = new URLSearchParams();
    form.set("To", agent.cell_phone);
    if (TWILIO_MSG_SID) form.set("MessagingServiceSid", TWILIO_MSG_SID); else form.set("From", TWILIO_FROM);
    form.set("Body", msg);

    await fetch(`https://api.twilio.com/2010-04-01/Accounts/${TWILIO_SID}/Messages.json`, {
      method: "POST",
      headers: { Authorization: "Basic " + btoa(`${TWILIO_SID}:${TWILIO_TOKEN}`), "Content-Type": "application/x-www-form-urlencoded" },
      body: form.toString(),
    });
  } catch (_e) {
    // fail-open
  }
  return ok();
});
