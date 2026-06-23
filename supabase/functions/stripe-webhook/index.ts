// Black Label Leads - Stripe webhook (Supabase Edge Function).
// Verifies the Stripe signature, then updates the agent's subscription_status;
// the bl_sync_status_to_billing trigger then auto-pauses/resumes their leads.
// verify_jwt = false (Stripe sends no Supabase token; we verify the Stripe signature).
//
// v13: MERGES referral logic onto v12 (activation + coverage promotion are UNCHANGED). Added:
//   - invoice.paid (amount>0): accrue the referrer's credit on a qualifying friend payment.
//   - charge.refunded / charge.dispute.closed(status=lost): claw back PROPORTIONALLY.
//   - customer.subscription.deleted: mark a referred friend's referral canceled.
//
// v14: MERGES Brief 7 make-good onto v13 (referral + activation + coverage promotion UNCHANGED). Added in
//   invoice.paid (amount>0): evaluate the prior weekly cycle's supply via bl_eval_make_good; if short of the
//   tier target (and the agent did not self-limit), record idempotently (DB ledger) and issue a Stripe account
//   credit = shortfall * per-lead rate to the agent's own next invoice. Record-first; non-fatal.
//
// v15: HARDENS make-good per the Brief 7 adversarial review. Make-good now runs ONLY when
//   inv.billing_reason === 'subscription_cycle' (true weekly renewals), so a proration/one-off/manual invoice
//   can no longer fire a second evaluation of the same delivery week. The DB ledger also enforces a per-cycle
//   UNIQUE(agent_id,period_start,period_end) as defense-in-depth against a same-cycle double credit.
//
// REQUIRED Stripe config: this endpoint's enabled events must include `charge.refunded` and
// `charge.dispute.closed` (plus the existing invoice.paid etc.) or the clawback path never fires.

import Stripe from "https://esm.sh/stripe@17?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2024-06-20",
  httpClient: Stripe.createFetchHttpClient(),
});
const cryptoProvider = Stripe.createSubtleCryptoProvider();
const WEBHOOK_SECRET = Deno.env.get("STRIPE_WEBHOOK_SECRET")!;

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

function periodEndISO(obj: any): string | null {
  const sec = obj?.current_period_end ?? obj?.items?.data?.[0]?.current_period_end;
  return sec ? new Date(sec * 1000).toISOString() : null;
}
function idOf(v: any): string | null {
  if (!v) return null;
  return typeof v === "string" ? v : (v.id ?? null);
}
// BRIEF 5: a held (trialing) subscription is a RESERVED seat, not an active paid one.
function mapStatus(s: string): string {
  return s === "trialing" ? "reserved" : s;
}

async function raise(type: string, severity: string, subject: string, detail: any, dedupe = 6) {
  try {
    await supabase.rpc("bl_raise_alert", {
      p_type: type, p_severity: severity, p_subject: subject, p_detail: detail,
      p_agent: null, p_auto: null, p_dedupe_hours: dedupe,
    });
  } catch (_) { /* ignore */ }
}

// resolve the subscription invoice id for a charge; charge.invoice is null on the first invoice of a
// Checkout-created subscription, so fall back to the charge's payment_intent.invoice.
async function invoiceIdForCharge(ch: any): Promise<string | null> {
  let inv = idOf(ch?.invoice);
  if (inv) return inv;
  const piId = idOf(ch?.payment_intent);
  if (!piId) return null;
  try {
    const pi: any = await stripe.paymentIntents.retrieve(piId, { expand: ["invoice"] });
    return idOf(pi?.invoice);
  } catch (_) { return null; }
}

// REFERRAL: reverse the referrer's credit, proportional to the refunded/disputed amount. Non-fatal.
async function referralClawback(invoiceId: string | null, refundedCents: number, totalCents: number) {
  if (!invoiceId) { await raise("referral_clawback_unresolved", "warn", "Referral clawback: could not resolve invoice", { refundedCents, totalCents }, 6); return; }
  try {
    const { data: plan, error: pe } = await supabase.rpc("bl_referral_eval_clawback", {
      p_invoice: invoiceId, p_refunded_cents: Math.round(refundedCents || 0), p_total_cents: Math.round(totalCents || 0),
    });
    if (pe) { console.error("clawback eval (non-fatal):", pe.message); return; }
    if (!(plan && plan.clawback)) return;
    const amt = Math.round(Number(plan.amount_cents));
    const { data: claimed, error: re } = await supabase.rpc("bl_referral_record_clawback", {
      p_referral_id: plan.referral_id, p_beneficiary: plan.beneficiary, p_amount_cents: amt, p_friend_invoice: invoiceId,
    });
    if (re) { console.error("clawback record (non-fatal):", re.message); return; }
    if (claimed !== true) return;                       // already clawed for this invoice
    try {
      await stripe.customers.createBalanceTransaction(
        plan.referrer_customer,
        { amount: amt, currency: "usd", description: "Black Label referral clawback (invoice " + invoiceId + ")" },
        { idempotencyKey: "bllclawback_" + invoiceId },
      );
    } catch (e) {
      await raise("referral_clawback_unfunded", "critical", "Referral clawback recorded but Stripe debit failed",
        { invoice: invoiceId, amount_cents: amt, err: String((e as Error)?.message ?? e) }, 6);
      return;
    }
    if (plan.partial) await raise("referral_partial_clawback", "info", "Partial referral clawback - review",
      { invoice: invoiceId, amount_cents: amt }, 24);
  } catch (e) {
    console.error("referral clawback threw (non-fatal):", (e as Error)?.message ?? String(e));
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const signature = req.headers.get("Stripe-Signature");
  const body = await req.text();
  if (!signature) return new Response("Missing Stripe-Signature header", { status: 400 });

  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(body, signature, WEBHOOK_SECRET, undefined, cryptoProvider);
  } catch (err) {
    console.error("Signature verification failed:", (err as Error).message);
    return new Response("Webhook signature verification failed", { status: 400 });
  }

  try {
    switch (event.type) {
      case "checkout.session.completed": {
        const s = event.data.object as Stripe.Checkout.Session;
        const agentId = s.client_reference_id;
        const email = (s.customer_details && s.customer_details.email) || (s as any).customer_email || null;
        const customer = idOf(s.customer);
        const subId = idOf(s.subscription);
        if (!customer || (!agentId && !email)) { console.warn("checkout missing customer or agent id/email"); break; }
        let status = "active";
        let periodEnd: string | null = null;
        if (subId) { const sub = await stripe.subscriptions.retrieve(subId); status = mapStatus(sub.status); periodEnd = periodEndISO(sub); }
        const { error } = await supabase.rpc("bl_link_stripe_customer", {
          p_agent_id: agentId, p_email: email, p_customer: customer, p_subscription: subId, p_status: status, p_period_end: periodEnd,
        });
        if (error) throw error;
        break;
      }
      case "customer.subscription.updated":
      case "customer.subscription.deleted": {
        const sub = event.data.object as Stripe.Subscription;
        const status = event.type === "customer.subscription.deleted" ? "canceled" : mapStatus(sub.status);
        const { error } = await supabase.rpc("bl_apply_billing", {
          p_customer: idOf(sub.customer), p_subscription: sub.id, p_status: status, p_period_end: periodEndISO(sub),
        });
        if (error) throw error;
        if (event.type === "customer.subscription.deleted") {
          try { await supabase.rpc("bl_referral_mark_canceled_by_customer", { p_customer: idOf(sub.customer) }); }
          catch (e) { console.error("referral cancel (non-fatal):", (e as Error)?.message ?? String(e)); }
        }
        break;
      }
      case "invoice.payment_failed": {
        const inv = event.data.object as any;
        const { error } = await supabase.rpc("bl_apply_billing", {
          p_customer: idOf(inv.customer), p_subscription: idOf(inv.subscription), p_status: "past_due", p_period_end: null,
        });
        if (error) throw error;
        break;
      }
      case "invoice.paid": {
        const inv = event.data.object as any;
        // A $0 trial-start invoice is NOT a real activation; leave the reserved status untouched.
        if (Number(inv.amount_paid ?? 0) <= 0) break;
        const pe = inv.lines?.data?.[0]?.period?.end ? new Date(inv.lines.data[0].period.end * 1000).toISOString() : null;
        const { error } = await supabase.rpc("bl_apply_billing", {
          p_customer: idOf(inv.customer), p_subscription: idOf(inv.subscription), p_status: "active", p_period_end: pe,
        });
        if (error) throw error;
        // BRIEF 6: a real renewal payment promotes any coverage expansions now due. Non-fatal.
        try {
          const { error: pErr } = await supabase.rpc("bl_promote_coverage_changes", { p_agent: null });
          if (pErr) console.error("coverage promote (non-fatal):", pErr.message);
        } catch (e) {
          console.error("coverage promote threw (non-fatal):", (e as Error)?.message ?? String(e));
        }
        // REFERRAL: accrue the referrer's credit on a qualifying friend payment. Non-fatal.
        try {
          const customer = idOf(inv.customer);
          const invoiceId = inv.id as string;
          const amountCents = Number(inv.amount_paid ?? 0);
          if (customer && invoiceId && amountCents > 0) {
            const { data: plan, error: refErr } = await supabase.rpc("bl_referral_eval_payment", {
              p_customer: customer, p_invoice: invoiceId, p_amount_cents: amountCents,
            });
            if (refErr) console.error("referral eval (non-fatal):", refErr.message);
            else if (plan && plan.accrue) {
              const amt = Math.round(Number(plan.amount_cents));
              const { data: claimed, error: re } = await supabase.rpc("bl_referral_record_accrual", {
                p_referral_id: plan.referral_id, p_beneficiary: plan.beneficiary,
                p_period_week: plan.period_week, p_amount_cents: amt, p_friend_invoice: invoiceId,
              });
              if (re) console.error("referral record (non-fatal):", re.message);
              else if (claimed === true) {
                try {
                  await stripe.customers.createBalanceTransaction(
                    plan.referrer_customer,
                    { amount: -amt, currency: "usd", description: "Black Label referral credit (invoice " + invoiceId + ")" },
                    { idempotencyKey: "bllaccrual_" + invoiceId },
                  );
                } catch (e) {
                  await raise("referral_credit_unfunded", "critical", "Referral accrual recorded but Stripe credit failed",
                    { invoice: invoiceId, amount_cents: amt, err: String((e as Error)?.message ?? e) }, 6);
                }
              }
            }
          }
        } catch (e) {
          console.error("referral accrual threw (non-fatal):", (e as Error)?.message ?? String(e));
          await raise("referral_accrual_error", "warn", "Referral accrual failed on invoice.paid",
            { err: String((e as Error)?.message ?? e) }, 6);
        }
        // BRIEF 7 (v15): make-good - ONLY on a true weekly renewal (billing_reason='subscription_cycle'),
        // evaluate the PRIOR cycle's supply and auto-credit a supply-side shortfall to the agent's own next
        // invoice. Record-first (DB ledger = idempotency, per-invoice AND per-cycle); only a winning claim
        // issues the Stripe credit. Non-fatal. Gating to subscription_cycle stops proration/one-off invoices
        // from re-evaluating (and double-crediting) the same delivery week.
        try {
          const customer = idOf(inv.customer);
          const invoiceId = inv.id as string;
          const period = inv.lines?.data?.[0]?.period;
          const periodStart = period?.start ? new Date(period.start * 1000).toISOString() : null;
          const periodEnd = period?.end ? new Date(period.end * 1000).toISOString() : null;
          if (customer && invoiceId && periodStart && periodEnd && inv.billing_reason === "subscription_cycle") {
            const { data: mg, error: mgErr } = await supabase.rpc("bl_eval_make_good", {
              p_customer: customer, p_trigger_invoice: invoiceId,
              p_period_start: periodStart, p_period_end: periodEnd,
            });
            if (mgErr) console.error("make-good eval (non-fatal):", mgErr.message);
            else if (mg && mg.claimed && mg.credit) {
              const amt = Math.round(Number(mg.amount_cents));
              const mgCustomer = mg.customer || customer;
              if (amt > 0 && mgCustomer) {
                try {
                  const bt: any = await stripe.customers.createBalanceTransaction(
                    mgCustomer,
                    { amount: -amt, currency: "usd", description: "Black Label short-week make-good (invoice " + invoiceId + ")" },
                    { idempotencyKey: "bllmakegood_" + invoiceId },
                  );
                  try { await supabase.rpc("bl_make_good_mark_paid", { p_trigger_invoice: invoiceId, p_ref: bt?.id ?? null }); } catch (_) { /* ignore */ }
                } catch (e) {
                  await raise("make_good_credit_unfunded", "critical", "Make-good recorded but Stripe credit failed",
                    { invoice: invoiceId, amount_cents: amt, err: String((e as Error)?.message ?? e) }, 6);
                }
              }
            }
          }
        } catch (e) {
          console.error("make-good threw (non-fatal):", (e as Error)?.message ?? String(e));
          await raise("make_good_error", "warn", "Make-good failed on invoice.paid",
            { err: String((e as Error)?.message ?? e) }, 6);
        }
        break;
      }
      case "charge.refunded": {
        const ch = event.data.object as any;
        const invoiceId = await invoiceIdForCharge(ch);
        await referralClawback(invoiceId, Number(ch.amount_refunded ?? 0), Number(ch.amount ?? 0));
        break;
      }
      case "charge.dispute.closed": {
        const dp = event.data.object as any;
        if (String(dp.status) !== "lost") break;
        try {
          const ch: any = await stripe.charges.retrieve(idOf(dp.charge) as string);
          const invoiceId = await invoiceIdForCharge(ch);
          await referralClawback(invoiceId, Number(dp.amount ?? ch.amount ?? 0), Number(ch.amount ?? 0));
        } catch (e) {
          console.error("dispute clawback threw (non-fatal):", (e as Error)?.message ?? String(e));
        }
        break;
      }
      default: break;
    }
  } catch (err) {
    console.error("Handler error on", event?.type, (err as Error)?.message ?? String(err));
    return new Response("Handler error", { status: 500 });
  }

  return new Response(JSON.stringify({ received: true }), { headers: { "Content-Type": "application/json" }, status: 200 });
});
