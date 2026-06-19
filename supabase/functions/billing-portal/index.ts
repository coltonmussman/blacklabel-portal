// Black Label Leads - open the Stripe customer portal for the signed-in agent.
// Called from the portal 'Manage billing' button. verify_jwt = true, so only an
// authenticated agent can reach it; we read their id from the JWT, look up their
// Stripe customer, and hand back a one-time portal URL. Self-bootstraps the portal
// configuration so no Stripe dashboard step is needed.

import Stripe from "https://esm.sh/stripe@17?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2024-06-20",
  httpClient: Stripe.createFetchHttpClient(),
});
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RETURN_URL = "https://portal.blacklabelleads.app/home.html";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const authHeader = req.headers.get("Authorization") || "";
    const userClient = createClient(SUPABASE_URL, ANON, { global: { headers: { Authorization: authHeader } } });
    const { data: { user }, error: uerr } = await userClient.auth.getUser();
    if (uerr || !user) return json({ error: "Not signed in" }, 401);

    const admin = createClient(SUPABASE_URL, SERVICE, { auth: { persistSession: false } });
    const { data: prof } = await admin.from("agent_profiles").select("stripe_customer_id").eq("id", user.id).single();
    const customer = prof?.stripe_customer_id;
    if (!customer) return json({ error: "No subscription on file yet." }, 400);

    const configs = await stripe.billingPortal.configurations.list({ active: true, limit: 1 });
    let configId = configs.data[0]?.id;
    if (!configId) {
      const cfg = await stripe.billingPortal.configurations.create({
        business_profile: { headline: "Black Label Leads - manage your subscription" },
        features: {
          invoice_history: { enabled: true },
          payment_method_update: { enabled: true },
          subscription_cancel: { enabled: true, mode: "at_period_end" },
        },
      });
      configId = cfg.id;
    }

    const session = await stripe.billingPortal.sessions.create({
      customer,
      return_url: RETURN_URL,
      configuration: configId,
    });
    return json({ url: session.url }, 200);
  } catch (err) {
    console.error("billing-portal error:", (err as Error).message);
    return json({ error: "Could not open billing portal" }, 500);
  }
});
