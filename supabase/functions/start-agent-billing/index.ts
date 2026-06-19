import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import Stripe from "https://esm.sh/stripe@17?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// start-agent-billing — BRIEF 5 activation + REFERRAL welcome discount.
// End the held trial on a reserved agent's first Drop (first charge + weekly anchor), flip to active.
// If the agent was REFERRED: apply a one-time welcome discount (Stripe coupon) to that FIRST real
// invoice — attached in the SAME subscriptions.update that ends the trial, so it lands on invoice #1.
// Self-referral by card -> disqualify, no discount. All referral work is wrapped so it can NEVER 500
// and never blocks the lead. Idempotent + fail-open. verify_jwt = false.

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

// best-effort card fingerprint for a customer (subscription default PM -> customer default -> first card)
async function cardFingerprint(stripe: Stripe, customerId: string | null, subId: string | null): Promise<string | null> {
  try {
    let pmId: any = null;
    if (subId) { const sub = await stripe.subscriptions.retrieve(subId); pmId = (sub as any).default_payment_method ?? null; }
    if (!pmId && customerId) {
      const cust: any = await stripe.customers.retrieve(customerId);
      pmId = cust?.invoice_settings?.default_payment_method ?? cust?.default_source ?? null;
    }
    if (!pmId && customerId) {
      const pms = await stripe.paymentMethods.list({ customer: customerId, type: "card", limit: 1 });
      pmId = pms.data?.[0]?.id ?? null;
    }
    if (!pmId) return null;
    const pm: any = await stripe.paymentMethods.retrieve(typeof pmId === "string" ? pmId : pmId.id);
    return pm?.card?.fingerprint ?? null;
  } catch (_) { return null; }
}

// retrieve-or-create the welcome coupon, asserting the amount/currency match (Stripe coupons are
// immutable, so a stale/edited object is rejected and a fresh one is made).
async function ensureWelcomeCoupon(stripe: Stripe, cents: number): Promise<string | null> {
  const id = "bllwelcome" + cents;
  try {
    const c: any = await stripe.coupons.retrieve(id);
    if (c && !c.deleted && c.valid !== false && Number(c.amount_off) === cents && c.currency === "usd") return id;
  } catch (_) { /* not found -> create */ }
  try {
    await stripe.coupons.create({ id, amount_off: cents, currency: "usd", duration: "once", name: "Black Label welcome credit" });
    return id;
  } catch (e: any) {
    // racing create or a pre-existing object: re-retrieve and accept only if it matches
    if (e?.code === "resource_already_exists" || String(e?.message ?? "").includes("already exists")) {
      try {
        const c: any = await stripe.coupons.retrieve(id);
        if (c && Number(c.amount_off) === cents && c.currency === "usd") return id;
      } catch (_) { /* fall through */ }
    }
    return null;
  }
}

Deno.serve(async (req) => {
  const ok = () => new Response(JSON.stringify({ ok: true }), { status: 200, headers: { "Content-Type": "application/json" } });
  if (req.method !== "POST") return new Response("method_not_allowed", { status: 405 });

  let agentId: string | null = null;
  try {
    let body: any;
    try { body = await req.json(); } catch { return ok(); }
    agentId = body?.agent_id ?? null;
    if (!agentId) return ok();

    const { data: rows, error: selErr } = await supabase
      .from("agent_profiles")
      .select("id, stripe_customer_id, stripe_subscription_id, subscription_status, first_drop_at, billing_started_at")
      .eq("id", agentId).limit(1);
    if (selErr) { console.error("select error:", selErr.message); return ok(); }
    const a = rows?.[0];
    if (!a) return ok();
    if (a.subscription_status === "active") return ok();
    if (a.subscription_status !== "reserved") return ok();
    if (!a.first_drop_at) return ok();

    if (!a.stripe_subscription_id) {
      const { error: alErr } = await supabase.rpc("bl_raise_alert", {
        p_type: "activation_no_sub", p_severity: "warn",
        p_subject: "Reserved agent got a Drop but has no Stripe subscription to charge",
        p_detail: { agent_id: agentId }, p_agent: agentId, p_auto: null, p_dedupe_hours: 24,
      });
      if (alErr) console.error("alert error (no_sub):", alErr.message);
      return ok();
    }

    const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", {
      apiVersion: "2024-06-20", httpClient: Stripe.createFetchHttpClient(),
    });

    // ---- REFERRAL welcome discount (friend side) — decide the coupon; it is attached in the SAME
    //      trial-ending update below so it lands on invoice #1. Self-referral by card -> disqualify.
    let couponToApply: string | null = null;
    try {
      const { data: elig } = await supabase.rpc("bl_referral_welcome_eligibility", { p_agent: agentId });
      if (elig && elig.eligible) {
        const friendFp = await cardFingerprint(stripe, a.stripe_customer_id, a.stripe_subscription_id);
        const refFp = elig.referrer_customer ? await cardFingerprint(stripe, elig.referrer_customer, null) : null;
        if (friendFp && refFp && friendFp === refFp) {
          await supabase.rpc("bl_referral_disqualify", { p_agent: agentId, p_reason: "payment_method_match" });
        } else {
          const cents = Math.round(Number(elig.cents || 0));
          if (cents > 0) couponToApply = await ensureWelcomeCoupon(stripe, cents);
          // fail-open self-check: if we couldn't compare cards, still apply but flag for review.
          if (!(friendFp && refFp)) {
            await supabase.rpc("bl_raise_alert", {
              p_type: "referral_welcome_unverified_card", p_severity: "info",
              p_subject: "Welcome discount applied without a card-fingerprint self-check",
              p_detail: { agent_id: agentId }, p_agent: agentId, p_auto: null, p_dedupe_hours: 24,
            });
          }
        }
      }
    } catch (e) {
      console.error("welcome eligibility (non-fatal):", String((e as Error)?.message ?? e));
      couponToApply = null;
    }

    // ---- end the held trial (+ welcome coupon if any) -> first real charge + weekly anchor
    const upd: any = { trial_end: "now", proration_behavior: "none" };
    if (couponToApply) upd.coupon = couponToApply;
    await stripe.subscriptions.update(a.stripe_subscription_id, upd);
    if (couponToApply) { try { await supabase.rpc("bl_referral_mark_welcome", { p_agent: agentId }); } catch (_) { /* ignore */ } }

    const { error: upErr } = await supabase.from("agent_profiles")
      .update({ subscription_status: "active", billing_started_at: a.billing_started_at ?? new Date().toISOString() })
      .eq("id", agentId);
    if (upErr) console.error("update error:", upErr.message);
  } catch (e) {
    console.error("start-agent-billing error:", String((e as Error)?.stack ?? (e as Error)?.message ?? e));
    try {
      await supabase.rpc("bl_raise_alert", {
        p_type: "activation_failed", p_severity: "critical",
        p_subject: "Billing activation failed on first Drop (lead still delivered)",
        p_detail: { agent_id: agentId, err: String((e as Error)?.message ?? e) },
        p_agent: agentId, p_auto: null, p_dedupe_hours: 6,
      });
    } catch (_) { /* ignore */ }
  }
  return ok();
});
