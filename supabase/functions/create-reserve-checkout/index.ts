import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import Stripe from "https://esm.sh/stripe@17?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// create-reserve-checkout — BRIEF 5. Agent reserves a seat: Stripe Checkout, subscription mode,
// CARD REQUIRED, long trial so NO charge now. Called from the portal (browser) so it needs CORS.
// verify_jwt = true. Stays in whatever mode STRIPE_SECRET_KEY points to (TEST for now).

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const PORTAL = "https://portal.blacklabelleads.app";
const ALLOWED = new Set(["https://portal.blacklabelleads.app"]);

function cors(origin: string | null) {
  const allow = origin && ALLOWED.has(origin) ? origin : PORTAL;
  return {
    "Access-Control-Allow-Origin": allow,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
    "Vary": "Origin",
  };
}

Deno.serve(async (req) => {
  const headers = { ...cors(req.headers.get("origin")), "Content-Type": "application/json" };
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers });
  const json = (o: any, s = 200) => new Response(JSON.stringify(o), { status: s, headers });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  try {
    const authz = req.headers.get("Authorization") || "";
    const userClient = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: authz } } });
    const { data: ures } = await userClient.auth.getUser();
    const user = ures?.user;
    if (!user) return json({ error: "unauthorized" }, 401);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });
    const { data: prof } = await admin.from("agent_profiles")
      .select("id, tier, stripe_customer_id, subscription_status").eq("id", user.id).single();
    if (!prof) return json({ error: "no_profile" }, 404);
    if (prof.subscription_status === "active") return json({ error: "already_active" }, 400);

    const tierKey = "price_" + String(prof.tier || "Silver").toLowerCase().replace(/[^a-z]/g, "") + "_weekly";
    const { data: priceId } = await admin.rpc("bl_cfg", { p_key: tierKey });
    if (!priceId) return json({ error: "no_price_for_tier" }, 400);

    const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", {
      apiVersion: "2024-06-20", httpClient: Stripe.createFetchHttpClient(),
    });
    const session = await stripe.checkout.sessions.create({
      mode: "subscription",
      client_reference_id: user.id,
      customer: prof.stripe_customer_id || undefined,
      customer_email: prof.stripe_customer_id ? undefined : (user.email || undefined),
      line_items: [{ price: priceId, quantity: 1 }],
      payment_method_collection: "always",
      subscription_data: { trial_period_days: 365 },
      success_url: PORTAL + "/home.html?reserved=1",
      cancel_url: PORTAL + "/setup.html",
    });
    return json({ url: session.url });
  } catch (e) {
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});
