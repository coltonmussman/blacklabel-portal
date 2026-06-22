-- Black Label Leads — Supabase schema migrations (source-of-record)
-- Captured read-only via MCP execute_sql from supabase_migrations.schema_migrations on 2026-06-19.
-- This is the applied-migration DDL history (the closest available equivalent to a schema-only pg_dump via MCP).
-- LIVE Supabase is the source of truth; refresh this before relying on it. Do NOT deploy from this file.

-- ============================================================
-- migration: 20260613073632  billing_helpers_jsonb_and_email_fallback
-- ============================================================
-- Helpers now RETURN jsonb (no more void/204 that the client misreads as a 500),
-- and bl_link_stripe_customer can fall back to matching an agent by their checkout
-- email when client_reference_id is absent. Both stay locked to service_role.

drop function if exists public.bl_apply_billing(text, text, text, timestamptz);
drop function if exists public.bl_link_stripe_customer(uuid, text, text, text, timestamptz);

create function public.bl_apply_billing(
  p_customer text, p_subscription text, p_status text, p_period_end timestamptz default null)
returns jsonb language plpgsql security definer as $fn$
declare v_matched int;
begin
  update public.agent_profiles
     set stripe_customer_id     = coalesce(stripe_customer_id, p_customer),
         stripe_subscription_id = coalesce(p_subscription, stripe_subscription_id),
         subscription_status    = coalesce(p_status, subscription_status),
         current_period_end     = coalesce(p_period_end, current_period_end),
         billing_started_at     = coalesce(billing_started_at, now())
   where stripe_customer_id = p_customer
      or stripe_subscription_id = p_subscription;
  get diagnostics v_matched = row_count;
  return jsonb_build_object('matched', v_matched);
end; $fn$;

create function public.bl_link_stripe_customer(
  p_agent_id uuid, p_email text, p_customer text, p_subscription text,
  p_status text default 'active', p_period_end timestamptz default null)
returns jsonb language plpgsql security definer as $fn$
declare v_id uuid; v_matched int;
begin
  v_id := p_agent_id;
  if v_id is null and coalesce(trim(p_email), '') <> '' then
    select id into v_id from auth.users where lower(email) = lower(p_email)
      order by created_at desc limit 1;
  end if;
  if v_id is null then
    return jsonb_build_object('matched', 0, 'reason', 'no_agent_match');
  end if;
  update public.agent_profiles
     set stripe_customer_id     = p_customer,
         stripe_subscription_id = coalesce(p_subscription, stripe_subscription_id),
         subscription_status    = coalesce(p_status, subscription_status),
         current_period_end     = coalesce(p_period_end, current_period_end),
         billing_started_at     = coalesce(billing_started_at, now())
   where id = v_id;
  get diagnostics v_matched = row_count;
  return jsonb_build_object('matched', v_matched, 'agent_id', v_id);
end; $fn$;

revoke all on function public.bl_apply_billing(text, text, text, timestamptz)
  from public, anon, authenticated;
revoke all on function public.bl_link_stripe_customer(uuid, text, text, text, text, timestamptz)
  from public, anon, authenticated;
grant execute on function public.bl_apply_billing(text, text, text, timestamptz)
  to service_role;
grant execute on function public.bl_link_stripe_customer(uuid, text, text, text, text, timestamptz)
  to service_role;

-- ============================================================
-- migration: 20260613080414  enable_pg_cron
-- ============================================================
create extension if not exists pg_cron;

-- ============================================================
-- migration: 20260613080506  owner_agents_add_subscription_and_hide_owner
-- ============================================================
-- Surface billing health in the owner agents list, and stop showing the owner's
-- own row among the agents.
create or replace function public.bl_owner_agents()
returns json language plpgsql security definer stable as $fn$
begin
  if not public.bl_is_owner() then raise exception 'not authorized'; end if;
  return (select coalesce(json_agg(row_to_json(t)), '[]'::json) from (
    select p.id, p.first_name, p.last_name, au.email, p.states_licensed, p.active_states,
           p.active_verticals, p.status, p.weekly_cap, p.received_this_week, p.tier,
           p.subscription_status, p.current_period_end
    from public.agent_profiles p left join auth.users au on au.id = p.id
    where coalesce(au.email, '') <> 'blacklabelleads@gmail.com'
    order by p.status, p.last_name nulls last
  ) t);
end; $fn$;

-- ============================================================
-- migration: 20260613080708  support_requests_table_and_email
-- ============================================================
-- Support requests submitted from the portal support page. Authenticated agents
-- can insert their own; they cannot read the table. Owner reads via bl_owner_support().
-- On insert, email the owner (same Resend + pg_net pattern as notify_refund_flag).

create table if not exists public.support_requests (
  id uuid primary key default gen_random_uuid(),
  agent_id uuid references public.agent_profiles(id) on delete set null,
  agent_email text,
  topic text,
  message text not null,
  created_at timestamptz not null default now(),
  resolved boolean not null default false
);

alter table public.support_requests enable row level security;

-- agents may submit only their own request; no SELECT/UPDATE/DELETE for them
drop policy if exists "agents submit support" on public.support_requests;
create policy "agents submit support" on public.support_requests
  for insert to authenticated with check (agent_id = (select auth.uid()));

revoke all on public.support_requests from anon, authenticated;
grant insert (agent_id, agent_email, topic, message) on public.support_requests to authenticated;

-- email the owner on a new request
create or replace function public.notify_support_request()
returns trigger language plpgsql security definer as $fn$
declare api_key text; agent_name text;
begin
  begin
    select decrypted_secret into api_key from vault.decrypted_secrets where name = 'resend_api_key';
    if api_key is null then return new; end if;
    select coalesce(first_name,'') || ' ' || coalesce(last_name,'') into agent_name
      from public.agent_profiles where id = new.agent_id;
    perform net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object('Authorization', 'Bearer ' || api_key, 'Content-Type', 'application/json'),
      body := jsonb_build_object(
        'from', 'Black Label Leads <alerts@blacklabelleads.app>',
        'to', jsonb_build_array('blacklabelleads@gmail.com'),
        'reply_to', coalesce(nullif(trim(new.agent_email), ''), 'blacklabelleads@gmail.com'),
        'subject', 'SUPPORT: ' || coalesce(nullif(trim(new.topic), ''), 'General') || ' - ' || coalesce(nullif(trim(agent_name), ''), coalesce(new.agent_email, 'agent')),
        'html', '<h2>New support request</h2><p><b>Agent:</b> ' || coalesce(agent_name, '') || ' (' || coalesce(new.agent_email, '') || ')<br><b>Topic:</b> ' || coalesce(new.topic, 'General') || '</p><p>' || replace(coalesce(new.message, ''), chr(10), '<br>') || '</p>'
      )
    );
  exception when others then null;
  end;
  return new;
end; $fn$;

drop trigger if exists on_support_request on public.support_requests;
create trigger on_support_request after insert on public.support_requests
  for each row execute function public.notify_support_request();

-- owner-only view of support requests
create or replace function public.bl_owner_support(p_limit int default 100)
returns json language plpgsql security definer stable as $fn$
begin
  if not public.bl_is_owner() then raise exception 'not authorized'; end if;
  return (select coalesce(json_agg(row_to_json(t)), '[]'::json) from (
    select id, agent_email, topic, message, created_at, resolved
    from public.support_requests order by created_at desc
    limit greatest(1, least(p_limit, 500))
  ) t);
end; $fn$;
grant execute on function public.bl_owner_support(int) to authenticated;

-- ============================================================
-- migration: 20260613082250  owner_refund_workflow
-- ============================================================
-- Owner-side refund/credit workflow. No money movement -- this tracks and clears
-- the flag the agent raises (the actual replacement/credit decision stays the owner's).
alter table public.leads
  add column if not exists refund_resolved_at timestamptz,
  add column if not exists refund_resolution text;

create or replace function public.bl_owner_refunds()
returns json language plpgsql security definer stable as $fn$
begin
  if not public.bl_is_owner() then raise exception 'not authorized'; end if;
  return (select coalesce(json_agg(row_to_json(t)), '[]'::json) from (
    select l.id, l.first_name, l.last_name, l.phone, l.state, l.vertical,
           l.refund_reason, l.refund_requested_at, l.annual_premium, l.assigned_agent_id,
           (select coalesce(ap.first_name,'') || ' ' || coalesce(ap.last_name,'')
              from public.agent_profiles ap where ap.id = l.assigned_agent_id) as agent_name
    from public.leads l
    where l.refund_requested = true
    order by l.refund_requested_at desc nulls last
  ) t);
end; $fn$;

create or replace function public.bl_owner_resolve_refund(p_lead uuid, p_resolution text)
returns void language plpgsql security definer as $fn$
begin
  if not public.bl_is_owner() then raise exception 'not authorized'; end if;
  update public.leads
     set refund_requested  = false,
         refund_resolved_at = now(),
         refund_resolution  = coalesce(nullif(trim(p_resolution), ''), 'resolved')
   where id = p_lead;
end; $fn$;

grant execute on function public.bl_owner_refunds() to authenticated;
grant execute on function public.bl_owner_resolve_refund(uuid, text) to authenticated;

-- ============================================================
-- migration: 20260613151951  lead_quality_flag
-- ============================================================
-- Heuristic lead-quality flag (no external API). Read-only: used by the owner leads
-- view to surface obviously-bad contact info. Does NOT touch the insert path, so it
-- can never block or delay a real lead. Owner reviews; nothing is auto-rejected.
create or replace function public.bl_quality_flag(p_phone text, p_email text)
returns text language plpgsql immutable as $fn$
declare d text; e text; issues text[] := '{}';
begin
  -- phone: reduce to digits, drop a leading US country code
  d := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if length(d) = 11 and left(d, 1) = '1' then d := right(d, 10); end if;
  if length(d) <> 10
     or d ~ '^(\d)\1{9}$'                       -- all same digit
     or d in ('1234567890', '0123456789')        -- sequential
     or left(d, 1) in ('0', '1')                 -- invalid US area code start
  then issues := array_append(issues, 'phone'); end if;

  -- email: only flag if present and clearly bad (email can be optional)
  e := lower(trim(coalesce(p_email, '')));
  if e <> '' and (
       e !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
       or split_part(e, '@', 2) in ('test.com','example.com','mailinator.com','test.test','email.com','none.com','x.com')
       or split_part(e, '@', 1) in ('test','fake','none','na','asdf','qwerty')
     )
  then issues := array_append(issues, 'email'); end if;

  if array_length(issues, 1) is null then return null; end if;
  return array_to_string(issues, '+');
end; $fn$;

-- add the flag to the owner leads view
create or replace function public.bl_owner_leads(p_limit int default 200)
returns json language plpgsql security definer stable as $fn$
begin
  if not public.bl_is_owner() then raise exception 'not authorized'; end if;
  return (select coalesce(json_agg(row_to_json(t)), '[]'::json) from (
    select l.id, l.first_name, l.last_name, l.phone, l.email, l.state, l.vertical,
           coalesce(l.lead_status,'NEW') as lead_status, l.annual_premium,
           l.assigned_at, l.submitted_at, l.assigned_agent_id,
           public.bl_quality_flag(l.phone, l.email) as quality_flag,
           (select coalesce(ap.first_name,'') || ' ' || coalesce(ap.last_name,'')
              from public.agent_profiles ap where ap.id = l.assigned_agent_id) as agent_name
    from public.leads l
    order by coalesce(l.assigned_at, l.submitted_at, l.created_at) desc
    limit greatest(1, least(p_limit, 1000))
  ) t);
end; $fn$;

-- ============================================================
-- migration: 20260613152400  webhook_debug_table
-- ============================================================
-- Temporary debug capture for the stripe-webhook 500s. The function will insert the
-- event type + error detail here so we can read the real cause. Safe to drop later.
create table if not exists public.webhook_debug (
  id bigserial primary key,
  at timestamptz not null default now(),
  event_type text,
  detail text
);

-- ============================================================
-- migration: 20260616184333  harden_leads_revoke_unused_anon_grants
-- ============================================================
-- Defense in depth on the PII leads table.
-- The public anon (publishable) key is embedded in the consumer landing pages and
-- only needs INSERT. RLS already blocks anon SELECT/UPDATE (no anon read/update
-- policy exists), but these leftover table-level grants are unnecessary attack
-- surface. Revoke them. Fully reversible via: grant select, update on public.leads to anon;
revoke select, update on public.leads from anon;

-- ============================================================
-- migration: 20260616201647  rate_limit_and_dedup_layer
-- ============================================================
-- Abuse protection for public lead/waitlist intake (called by the capture-* edge functions).
create table if not exists public.bl_rate_limit (
  ip           text primary key,
  hits         int  not null default 0,
  window_start timestamptz not null default now()
);
alter table public.bl_rate_limit enable row level security;
revoke all on public.bl_rate_limit from anon, authenticated;

-- performance indexes for dedup + rate checks
create index if not exists idx_leads_phone        on public.leads (phone);
create index if not exists idx_leads_email_lower   on public.leads (lower(email));
create index if not exists idx_leads_created       on public.leads (created_at);

-- per-IP sliding 1-hour rate check. returns true if the request is allowed.
create or replace function public.bl_rate_check(p_ip text, p_max int default 30)
returns boolean language plpgsql security definer as $fn$
declare v_hits int;
begin
  if coalesce(p_ip,'') = '' then return true; end if;
  insert into public.bl_rate_limit (ip, hits, window_start) values (p_ip, 1, now())
  on conflict (ip) do update
    set hits = case when public.bl_rate_limit.window_start < now() - interval '1 hour'
                    then 1 else public.bl_rate_limit.hits + 1 end,
        window_start = case when public.bl_rate_limit.window_start < now() - interval '1 hour'
                    then now() else public.bl_rate_limit.window_start end
  returning hits into v_hits;
  return v_hits <= greatest(1, p_max);
end; $fn$;

-- full pre-insert gate for consumer leads: rate limit + duplicate guard.
create or replace function public.bl_precheck_lead(p_ip text, p_phone text, p_email text)
returns jsonb language plpgsql security definer as $fn$
declare v_phone_norm text := regexp_replace(coalesce(p_phone,''), '\D', '', 'g');
begin
  if not public.bl_rate_check(p_ip, 30) then
    return jsonb_build_object('ok', false, 'reason', 'rate_limited');
  end if;
  if v_phone_norm <> '' and exists (
       select 1 from public.leads
       where regexp_replace(coalesce(phone,''),'\D','','g') = v_phone_norm
         and created_at > now() - interval '10 minutes') then
    return jsonb_build_object('ok', false, 'reason', 'duplicate');
  end if;
  if coalesce(p_email,'') <> '' and exists (
       select 1 from public.leads
       where lower(email) = lower(p_email)
         and created_at > now() - interval '10 minutes') then
    return jsonb_build_object('ok', false, 'reason', 'duplicate');
  end if;
  return jsonb_build_object('ok', true);
end; $fn$;

revoke all on function public.bl_rate_check(text,int)            from public, anon, authenticated;
revoke all on function public.bl_precheck_lead(text,text,text)   from public, anon, authenticated;
grant execute on function public.bl_rate_check(text,int)          to service_role;
grant execute on function public.bl_precheck_lead(text,text,text) to service_role;

-- ============================================================
-- migration: 20260616201944  owner_command_center_v2
-- ============================================================
-- ===== Owner command center v2: profit, gifting, refund+replace, drilldown, action log =====

-- tier -> weekly price (live pricing)
create or replace function public.bl_tier_price(t text)
returns int language sql immutable as $fn$
  select case lower(coalesce(t,'')) when 'silver' then 400 when 'gold' then 600 when 'black label' then 1250 else 0 end;
$fn$;

-- action/audit log
create table if not exists public.bl_action_log (
  id uuid primary key default gen_random_uuid(),
  at timestamptz not null default now(),
  action text not null,
  detail jsonb
);
alter table public.bl_action_log enable row level security;
revoke all on public.bl_action_log from anon, authenticated;

create or replace function public.bl_owner_action_log(p_limit int default 100)
returns json language plpgsql security definer stable as $fn$
begin
  if not public.bl_is_owner() then raise exception 'not authorized'; end if;
  return (select coalesce(json_agg(row_to_json(t)),'[]'::json) from (
    select at, action, detail from public.bl_action_log order by at desc limit greatest(1, least(p_limit,500))
  ) t);
end; $fn$;

-- BUSINESS P&L (owner's actual take)
create or replace function public.bl_owner_business_pl()
returns json language plpgsql security definer stable as $fn$
declare v_weekly numeric; v_monthly numeric; v_ad_month numeric; v_ad_total numeric; v_prem numeric;
begin
  if not public.bl_is_owner() then raise exception 'not authorized'; end if;
  select coalesce(sum(public.bl_tier_price(tier)),0) into v_weekly from public.agent_profiles where status='active';
  v_monthly := round(v_weekly * 4.33, 2);
  select coalesce(sum(amount_cents),0)/100.0 into v_ad_month from public.ad_spend where spend_date >= date_trunc('month', now())::date;
  select coalesce(sum(amount_cents),0)/100.0 into v_ad_total from public.ad_spend;
  select coalesce(sum(annual_premium),0) into v_prem from public.leads where lead_status='SOLD';
  return json_build_object(
    'weekly_subscription_revenue', v_weekly,
    'monthly_subscription_revenue', v_monthly,
    'active_agents', (select count(*) from public.agent_profiles where status='active'),
    'ad_spend_this_month', v_ad_month,
    'ad_spend_all_time', v_ad_total,
    'business_gross_profit_month', round(v_monthly - v_ad_month, 2),
    'agent_premium_written_total', v_prem
  );
end; $fn$;

-- PER-AGENT profit + totals (owner only)
create or replace function public.bl_owner_agent_profit()
returns json language plpgsql security definer stable as $fn$
begin
  if not public.bl_is_owner() then raise exception 'not authorized'; end if;
  return json_build_object(
    'agents', (select coalesce(json_agg(row_to_json(t)),'[]'::json) from (
      select p.id, nullif(trim(coalesce(p.first_name,'')||' '||coalesce(p.last_name,'')),'') as name, p.tier, p.status,
             (select count(*) from public.leads l where l.assigned_agent_id=p.id) as leads_received,
             (select count(*) from public.leads l where l.assigned_agent_id=p.id and l.lead_status='SOLD') as deals,
             (select coalesce(sum(l.annual_premium),0) from public.leads l where l.assigned_agent_id=p.id and l.lead_status='SOLD') as premium_written
      from public.agent_profiles p left join auth.users au on au.id=p.id
      where coalesce(au.email,'')<>'blacklabelleads@gmail.com'
      order by premium_written desc nulls last
    ) t),
    'total_premium_written', (select coalesce(sum(annual_premium),0) from public.leads where lead_status='SOLD'),
    'total_deals', (select count(*) from public.leads where lead_status='SOLD'),
    'active_agents', (select count(*) from public.agent_profiles where status='active')
  );
end; $fn$;

-- AGENTS-ONLY aggregate pool: combined totals across all agents, NO individual data
create or replace function public.bl_agent_pool_total()
returns json language plpgsql security definer stable as $fn$
begin
  if auth.uid() is null then raise exception 'not authorized'; end if;
  return json_build_object(
    'total_premium_written', (select coalesce(sum(annual_premium),0) from public.leads where lead_status='SOLD'),
    'total_deals', (select count(*) from public.leads where lead_status='SOLD'),
    'active_agents', (select count(*) from public.agent_profiles where status='active'),
    'total_leads_worked', (select count(*) from public.leads where assigned_agent_id is not null)
  );
end; $fn$;

-- GIFT / BULK ASSIGN vault leads to a chosen agent (owner override of routing)
create or replace function public.bl_owner_assign_leads(p_agent uuid, p_count int default 1, p_state text default null, p_vertical text default null)
returns json language plpgsql security definer as $fn$
declare v_ids uuid[]; v_n int;
begin
  if not public.bl_is_owner() then raise exception 'not authorized'; end if;
  with picked as (
    select id from public.leads
    where assigned_agent_id is null and coalesce(lead_status,'NEW')<>'DEAD'
      and (p_state is null or public.bl_state_code(state)=public.bl_state_code(p_state))
      and (p_vertical is null or public.bl_vert_label(vertical)=p_vertical or lower(coalesce(vertical,'')) like '%'||lower(p_vertical)||'%')
    order by coalesce(submitted_at, created_at) asc
    limit greatest(1, least(coalesce(p_count,1), 100)) for update skip locked
  ), upd as (
    update public.leads l set assigned_agent_id=p_agent, assigned_at=now(), lead_status=coalesce(lead_status,'NEW')
    from picked where l.id=picked.id returning l.id
  )
  select array_agg(id), count(*) into v_ids, v_n from upd;
  if coalesce(v_n,0) > 0 then
    update public.agent_profiles set received_this_week=received_this_week+v_n, last_assigned_at=now() where id=p_agent;
  end if;
  insert into public.bl_action_log(action, detail) values ('assign_leads', json_build_object('agent',p_agent,'count',coalesce(v_n,0),'state',p_state,'vertical',p_vertical));
  return json_build_object('assigned', coalesce(v_n,0), 'lead_ids', to_jsonb(coalesce(v_ids,'{}'::uuid[])));
end; $fn$;

-- RESOLVE a refund AND auto-pull a replacement lead to the same agent
create or replace function public.bl_owner_refund_replace(p_lead uuid, p_resolution text default 'credited')
returns json language plpgsql security definer as $fn$
declare v_agent uuid; v_state text; v_vert text; v_repl uuid;
begin
  if not public.bl_is_owner() then raise exception 'not authorized'; end if;
  select assigned_agent_id, state, vertical into v_agent, v_state, v_vert from public.leads where id=p_lead;
  update public.leads set refund_requested=false, refund_resolved_at=now(),
         refund_resolution=coalesce(nullif(trim(p_resolution),''),'credited') where id=p_lead;
  if v_agent is not null then
    with pick as (
      select id from public.leads
      where assigned_agent_id is null and coalesce(lead_status,'NEW')<>'DEAD'
        and (v_state is null or public.bl_state_code(state)=public.bl_state_code(v_state))
        and (v_vert is null or coalesce(vertical,'')=v_vert)
      order by coalesce(submitted_at,created_at) asc limit 1 for update skip locked
    )
    update public.leads l set assigned_agent_id=v_agent, assigned_at=now(), lead_status=coalesce(lead_status,'NEW')
    from pick where l.id=pick.id returning l.id into v_repl;
    if v_repl is not null then
      update public.agent_profiles set received_this_week=received_this_week+1 where id=v_agent;
    end if;
  end if;
  insert into public.bl_action_log(action, detail) values ('refund_replace', json_build_object('lead',p_lead,'agent',v_agent,'resolution',p_resolution,'replacement',v_repl));
  return json_build_object('resolved', true, 'replacement_assigned', v_repl is not null, 'replacement_id', v_repl);
end; $fn$;

-- PER-AGENT drilldown
create or replace function public.bl_owner_agent_detail(p_agent uuid)
returns json language plpgsql security definer stable as $fn$
begin
  if not public.bl_is_owner() then raise exception 'not authorized'; end if;
  return json_build_object(
    'profile', (select row_to_json(t) from (
      select p.id, p.first_name, p.last_name, au.email, p.tier, p.status, p.states_licensed,
             p.active_states, p.verticals, p.weekly_cap, p.received_this_week,
             p.subscription_status, p.current_period_end, p.weekly_investment, p.monthly_goal
      from public.agent_profiles p left join auth.users au on au.id=p.id where p.id=p_agent) t),
    'stats', (select row_to_json(s) from (
      select count(*) as leads_received,
             count(*) filter (where lead_status in ('CONTACTED','APPOINTMENT','SOLD')) as worked,
             count(*) filter (where lead_status='APPOINTMENT') as appointments,
             count(*) filter (where lead_status='SOLD') as deals,
             count(*) filter (where lead_status='DEAD') as dead,
             coalesce(sum(annual_premium) filter (where lead_status='SOLD'),0) as premium_written
      from public.leads where assigned_agent_id=p_agent) s),
    'recent_leads', (select coalesce(json_agg(row_to_json(r)),'[]'::json) from (
      select id, first_name, last_name, state, vertical, coalesce(lead_status,'NEW') as lead_status, annual_premium, assigned_at
      from public.leads where assigned_agent_id=p_agent order by coalesce(assigned_at, created_at) desc limit 25) r)
  );
end; $fn$;

-- set an agent's tier (drives the P&L pricing)
create or replace function public.bl_owner_set_agent_tier(p_agent uuid, p_tier text)
returns void language plpgsql security definer as $fn$
begin
  if not public.bl_is_owner() then raise exception 'not authorized'; end if;
  if p_tier not in ('Silver','Gold','Black Label') then raise exception 'invalid tier'; end if;
  update public.agent_profiles set tier=p_tier where id=p_agent;
  insert into public.bl_action_log(action, detail) values ('set_tier', json_build_object('agent',p_agent,'tier',p_tier));
end; $fn$;

grant execute on function
  public.bl_owner_action_log(int),
  public.bl_owner_business_pl(),
  public.bl_owner_agent_profit(),
  public.bl_owner_assign_leads(uuid,int,text,text),
  public.bl_owner_refund_replace(uuid,text),
  public.bl_owner_agent_detail(uuid),
  public.bl_owner_set_agent_tier(uuid,text)
  to authenticated;
grant execute on function public.bl_agent_pool_total() to authenticated;

-- ============================================================
-- migration: 20260618165141  command_center_alerts_table
-- ============================================================
-- Alerts store for the command center watchdog
create table if not exists public.bl_alerts (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  severity text not null default 'warn' check (severity in ('info','warn','critical')),
  type text not null,
  subject text not null,
  detail jsonb,
  agent_id uuid references public.agent_profiles(id) on delete set null,
  auto_action text,
  resolved boolean not null default false,
  resolved_at timestamptz
);
create index if not exists bl_alerts_open_idx on public.bl_alerts (resolved, created_at desc);
alter table public.bl_alerts enable row level security;
-- no anon/authenticated policies: access is only through the owner-gated SECURITY DEFINER RPCs below

create or replace function public.bl_owner_alerts(p_include_resolved boolean default false, p_limit int default 100)
returns json language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.bl_is_owner() then raise exception 'not authorized'; end if;
  return coalesce((
    select json_agg(row_to_json(a) order by a.resolved asc, a.created_at desc)
    from (
      select id, created_at, severity, type, subject, detail, agent_id, auto_action, resolved, resolved_at
      from public.bl_alerts
      where p_include_resolved or not resolved
      order by resolved asc, created_at desc
      limit greatest(p_limit, 1)
    ) a
  ), '[]'::json);
end; $$;

create or replace function public.bl_owner_alert_summary()
returns json language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.bl_is_owner() then raise exception 'not authorized'; end if;
  return (select json_build_object(
    'open',     count(*) filter (where not resolved),
    'critical', count(*) filter (where not resolved and severity = 'critical'),
    'warn',     count(*) filter (where not resolved and severity = 'warn')
  ) from public.bl_alerts);
end; $$;

create or replace function public.bl_owner_resolve_alert(p_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.bl_is_owner() then raise exception 'not authorized'; end if;
  update public.bl_alerts set resolved = true, resolved_at = now() where id = p_id;
  insert into public.bl_action_log(action, detail) values ('alert_resolved', jsonb_build_object('alert_id', p_id));
end; $$;

-- ============================================================
-- migration: 20260618165200  command_center_metrics_rpcs
-- ============================================================
-- Which landing page / source is winning
create or replace function public.bl_owner_landing_performance(p_days int default 30)
returns json language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.bl_is_owner() then raise exception 'not authorized'; end if;
  return coalesce((
    select json_agg(row_to_json(t) order by t.leads desc)
    from (
      select
        coalesce(nullif(trim(source), ''), 'Unknown') as source,
        coalesce(vertical, 'unknown') as vertical,
        count(*) as leads,
        count(*) filter (where consent_given and trustedform_cert_url is not null and coalesce(phone,'') <> '') as billable,
        count(*) filter (where assigned_agent_id is not null) as assigned,
        count(*) filter (where lead_status = 'SOLD') as sold
      from public.leads
      where created_at >= now() - (p_days || ' days')::interval
      group by 1, 2
    ) t
  ), '[]'::json);
end; $$;

-- Lead flow: totals + daily trend + by vertical + by state
create or replace function public.bl_owner_lead_flow(p_days int default 30)
returns json language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.bl_is_owner() then raise exception 'not authorized'; end if;
  return json_build_object(
    'window_days', p_days,
    'today',      (select count(*) from public.leads where created_at >= date_trunc('day', now())),
    'this_week',  (select count(*) from public.leads where created_at >= date_trunc('week', now())),
    'this_month', (select count(*) from public.leads where created_at >= date_trunc('month', now())),
    'by_day', coalesce((select json_agg(row_to_json(d) order by d.day) from (
        select to_char(date_trunc('day', created_at), 'YYYY-MM-DD') as day, count(*) as leads
        from public.leads where created_at >= now() - (p_days || ' days')::interval
        group by 1) d), '[]'::json),
    'by_vertical', coalesce((select json_agg(row_to_json(v) order by v.leads desc) from (
        select coalesce(vertical, 'unknown') as vertical, count(*) as leads
        from public.leads where created_at >= now() - (p_days || ' days')::interval
        group by 1) v), '[]'::json),
    'by_state', coalesce((select json_agg(row_to_json(s) order by s.leads desc) from (
        select coalesce(nullif(trim(state), ''), '?') as state, count(*) as leads
        from public.leads where created_at >= now() - (p_days || ' days')::interval
        group by 1) s), '[]'::json)
  );
end; $$;

-- Per-agent delivery vs. their weekly cap
create or replace function public.bl_owner_agent_delivery()
returns json language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.bl_is_owner() then raise exception 'not authorized'; end if;
  return coalesce((
    select json_agg(row_to_json(t))
    from (
      select
        p.id,
        coalesce(nullif(trim(coalesce(p.first_name,'') || ' ' || coalesce(p.last_name,'')), ''), '(unnamed)') as name,
        p.tier, p.status, p.weekly_cap, p.received_this_week,
        case when p.weekly_cap > 0 then round(100.0 * p.received_this_week / p.weekly_cap) else 0 end as pct_of_cap,
        p.last_assigned_at,
        case when p.last_assigned_at is null then null
             else floor(extract(epoch from (now() - p.last_assigned_at)) / 86400)::int end as days_since_last,
        p.subscription_status, p.current_period_end
      from public.agent_profiles p
      order by (p.status = 'active') desc, p.received_this_week desc
    ) t
  ), '[]'::json);
end; $$;

-- Lead quality / compliance snapshot
create or replace function public.bl_owner_quality(p_days int default 30)
returns json language plpgsql stable security definer set search_path = public
as $$
declare w interval := (p_days || ' days')::interval;
begin
  if not public.bl_is_owner() then raise exception 'not authorized'; end if;
  return json_build_object(
    'window_days', p_days,
    'total',            (select count(*) from public.leads where created_at >= now() - w),
    'billable',         (select count(*) from public.leads where created_at >= now() - w and consent_given and trustedform_cert_url is not null and coalesce(phone,'') <> ''),
    'missing_cert',     (select count(*) from public.leads where created_at >= now() - w and trustedform_cert_url is null),
    'no_consent',       (select count(*) from public.leads where created_at >= now() - w and not consent_given),
    'unassigned',       (select count(*) from public.leads where created_at >= now() - w and assigned_agent_id is null),
    'refund_requested', (select count(*) from public.leads where created_at >= now() - w and refund_requested),
    'sold',             (select count(*) from public.leads where created_at >= now() - w and lead_status = 'SOLD')
  );
end; $$;

-- Billing health from synced Stripe status on agent_profiles
create or replace function public.bl_owner_billing_health()
returns json language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.bl_is_owner() then raise exception 'not authorized'; end if;
  return json_build_object(
    'active_subs',      (select count(*) from public.agent_profiles where subscription_status = 'active'),
    'past_due',         (select count(*) from public.agent_profiles where subscription_status in ('past_due','unpaid')),
    'canceled',         (select count(*) from public.agent_profiles where subscription_status = 'canceled'),
    'active_no_sub',    (select count(*) from public.agent_profiles where status = 'active' and coalesce(subscription_status,'none') <> 'active'),
    'weekly_recurring', (select coalesce(sum(weekly_investment),0) from public.agent_profiles where subscription_status = 'active'),
    'mrr_est',          (select coalesce(round(sum(weekly_investment) * 52 / 12.0), 0) from public.agent_profiles where subscription_status = 'active'),
    'renewals_7d',      (select count(*) from public.agent_profiles where current_period_end between now() and now() + interval '7 days')
  );
end; $$;

-- ============================================================
-- migration: 20260618165324  command_center_watchdog
-- ============================================================
-- Insert an alert unless an identical unresolved one already exists in the dedupe window
create or replace function public.bl_raise_alert(
  p_type text, p_severity text, p_subject text, p_detail jsonb,
  p_agent uuid default null, p_auto text default null, p_dedupe_hours int default 12
) returns boolean language plpgsql security definer set search_path = public
as $$
declare existing int;
begin
  select count(*) into existing from public.bl_alerts
   where type = p_type and subject = p_subject and not resolved
     and created_at >= now() - (p_dedupe_hours || ' hours')::interval;
  if existing > 0 then return false; end if;
  insert into public.bl_alerts(severity, type, subject, detail, agent_id, auto_action)
   values (p_severity, p_type, p_subject, p_detail, p_agent, p_auto);
  return true;
end; $$;

-- The watchdog: runs the checks, takes the one safe auto-fix (pause on failed payment), emails new alerts
create or replace function public.bl_run_watchdog()
returns json language plpgsql security definer set search_path = public
as $$
declare
  r record;
  new_alerts int := 0;
  new_critical int := 0;
  api_key text;
  digest text := '';
  dow int := extract(dow from now())::int;
  miss int; prior int; recent int; spam int;
begin
  -- 1) Failed payment -> AUTO-PAUSE (safe, reversible) + critical alert
  for r in
    select id, first_name, last_name, subscription_status
    from public.agent_profiles
    where subscription_status in ('past_due','unpaid','canceled') and status = 'active'
  loop
    update public.agent_profiles set status = 'paused' where id = r.id;
    insert into public.bl_action_log(action, detail)
      values ('watchdog_pause_failed_payment', jsonb_build_object('agent', r.id, 'sub_status', r.subscription_status));
    if public.bl_raise_alert('failed_payment','critical',
        'Paused ' || coalesce(r.first_name,'agent') || ' ' || coalesce(r.last_name,'') || ' (payment ' || r.subscription_status || ')',
        jsonb_build_object('agent_id', r.id, 'subscription_status', r.subscription_status), r.id, 'paused_agent', 24) then
      new_alerts := new_alerts + 1; new_critical := new_critical + 1;
      digest := digest || '- PAUSED ' || coalesce(r.first_name,'agent') || ' (payment ' || r.subscription_status || ')' || chr(10);
    end if;
  end loop;

  -- 2) Active agent with no active subscription -> notify
  for r in
    select id, first_name from public.agent_profiles
    where status = 'active' and coalesce(subscription_status,'none') not in ('active','past_due','unpaid','canceled')
  loop
    if public.bl_raise_alert('no_subscription','warn',
        'Active agent with no paid subscription: ' || coalesce(r.first_name,'(unnamed)'),
        jsonb_build_object('agent_id', r.id), r.id, null, 48) then
      new_alerts := new_alerts + 1;
      digest := digest || '- ' || coalesce(r.first_name,'agent') || ' is active but has no paid subscription' || chr(10);
    end if;
  end loop;

  -- 3) Missing consent cert on leads in last 24h -> compliance (notify)
  select count(*) into miss from public.leads
   where created_at >= now() - interval '24 hours' and trustedform_cert_url is null;
  if miss > 0 then
    if public.bl_raise_alert('missing_cert','critical',
        miss || ' lead(s) in last 24h missing a TrustedForm consent cert',
        jsonb_build_object('count', miss), null, null, 6) then
      new_alerts := new_alerts + 1; new_critical := new_critical + 1;
      digest := digest || '- ' || miss || ' new lead(s) missing a consent cert (compliance)' || chr(10);
    end if;
  end if;

  -- 4) Under-delivery: Sunday, active paid agent under half their cap -> notify
  if dow = 0 then
    for r in
      select id, first_name, weekly_cap, received_this_week from public.agent_profiles
      where status = 'active' and subscription_status = 'active'
        and weekly_cap > 0 and received_this_week < ceil(weekly_cap / 2.0)
    loop
      if public.bl_raise_alert('under_delivery','warn',
          'Under-delivery: ' || coalesce(r.first_name,'agent') || ' got ' || r.received_this_week || '/' || r.weekly_cap || ' this week',
          jsonb_build_object('agent_id', r.id, 'received', r.received_this_week, 'cap', r.weekly_cap), r.id, null, 24) then
        new_alerts := new_alerts + 1;
        digest := digest || '- ' || coalesce(r.first_name,'agent') || ' under-delivered (' || r.received_this_week || '/' || r.weekly_cap || ')' || chr(10);
      end if;
    end loop;
  end if;

  -- 5) Pipeline drop: >=5 leads in the prior week but ZERO in last 24h (stays quiet pre-launch)
  select count(*) into prior from public.leads where created_at between now() - interval '8 days' and now() - interval '24 hours';
  select count(*) into recent from public.leads where created_at >= now() - interval '24 hours';
  if prior >= 5 and recent = 0 then
    if public.bl_raise_alert('pipeline_drop','critical',
        'No new leads in 24h (prior week had ' || prior || ')',
        jsonb_build_object('prior_7d', prior), null, null, 12) then
      new_alerts := new_alerts + 1; new_critical := new_critical + 1;
      digest := digest || '- Lead flow dropped to ZERO in last 24h - check ads/forms' || chr(10);
    end if;
  end if;

  -- 6) Bot/spam spike from the rate limiter -> notify
  select coalesce(sum(hits),0) into spam from public.bl_rate_limit
   where window_start >= now() - interval '1 hour' and hits >= 10;
  if spam >= 30 then
    if public.bl_raise_alert('spam_spike','warn',
        'Bot/spam spike: ' || spam || ' blocked attempts in the last hour',
        jsonb_build_object('hits', spam), null, null, 3) then
      new_alerts := new_alerts + 1;
      digest := digest || '- Spam spike: ' || spam || ' blocked submissions in last hour' || chr(10);
    end if;
  end if;

  -- Email a digest of NEW alerts (best-effort, mirrors the existing Resend pattern)
  if new_alerts > 0 then
    begin
      select decrypted_secret into api_key from vault.decrypted_secrets where name = 'resend_api_key';
      if api_key is not null then
        perform net.http_post(
          url := 'https://api.resend.com/emails',
          headers := jsonb_build_object('Authorization','Bearer ' || api_key, 'Content-Type','application/json'),
          body := jsonb_build_object(
            'from','Black Label Leads <onboarding@resend.dev>',
            'to', jsonb_build_array('coltonmussman0@gmail.com'),
            'subject', (case when new_critical > 0 then '[ACTION] ' else '[Heads up] ' end) || new_alerts || ' command-center alert(s)',
            'html','<h2>Command Center Alerts</h2><p>' || replace(digest, chr(10), '<br>') || '</p><p><a href="https://portal.blacklabelleads.app/owner.html">Open the command center</a></p>'
          )
        );
      end if;
    exception when others then null;
    end;
  end if;

  insert into public.bl_action_log(action, detail)
    values ('watchdog_run', jsonb_build_object('new_alerts', new_alerts, 'new_critical', new_critical));
  return json_build_object('new_alerts', new_alerts, 'new_critical', new_critical, 'ran_at', now());
end; $$;

revoke all on function public.bl_raise_alert(text,text,text,jsonb,uuid,text,int) from public, anon, authenticated;
revoke all on function public.bl_run_watchdog() from public, anon, authenticated;

-- ============================================================
-- migration: 20260618173104  harden_owner_rpcs_and_vault_overview
-- ============================================================
-- Finding #1: vault_overview was readable by anon (public key) and bypasses RLS.
-- Remove anon/authenticated/PUBLIC access; leave postgres + service_role only.
revoke all on public.vault_overview from anon, authenticated, public;

-- Finding #2: all bl_owner_* RPCs were callable by anon/PUBLIC (protected only by the
-- internal bl_is_owner() gate). Double-lock: remove anon + PUBLIC execute. The logged-in
-- owner calls these as the `authenticated` role (keeps its explicit grant), and service_role
-- (server-side) is untouched, so the dashboard keeps working.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'bl_owner_%'
  loop
    execute format('revoke execute on function %s from anon, public;', r.sig);
  end loop;
end $$;

-- ============================================================
-- migration: 20260618181027  lock_bl_drain_vault_for_agent
-- ============================================================
-- bl_drain_vault_for_agent assigns vaulted leads to an agent and sends emails, with no
-- owner guard, yet was callable by anon AND authenticated. Its only legitimate caller is the
-- bl_on_agent_eligible trigger (SECURITY DEFINER, runs as definer/postgres), which is
-- unaffected by API-role grants. Lock it to server/trigger only.
revoke execute on function public.bl_drain_vault_for_agent(uuid) from anon, authenticated, public;

-- ============================================================
-- migration: 20260619040151  drop_brief3_schema
-- ============================================================
-- BRIEF 3 (The Drop) — additive schema, default-safe.

-- agent_profiles: Drop-delivery prefs (all-7-days default = current behavior)
alter table public.agent_profiles
  add column if not exists drop_days int[] not null default '{1,2,3,4,5,6,7}',
  add column if not exists agent_tz text not null default 'America/Chicago',
  add column if not exists cell_phone text,
  add column if not exists sms_opt_in boolean not null default false;

-- leads: 24h age-out marker
alter table public.leads
  add column if not exists aged_out_at timestamptz;

-- speed vault/drain/age-out scans (fresh, unassigned leads)
create index if not exists idx_leads_vault_open
  on public.leads ((coalesce(submitted_at, created_at)))
  where assigned_agent_id is null and aged_out_at is null;

-- bl_config: owner-only key/value (RLS on, no policy => only definer/service_role reach it)
create table if not exists public.bl_config (
  key text primary key,
  value text,
  updated_at timestamptz not null default now()
);
alter table public.bl_config enable row level security;

insert into public.bl_config (key, value) values
  ('freshness_hours','24'),
  ('drop_window_hours','6'),
  ('fallback_mode','founder'),
  ('fallback_agent_id', null)   -- BLOCKED: seed with Colton's founder agent uuid later; NULL = fallback inert
on conflict (key) do nothing;

-- config reader for SECURITY DEFINER routing functions
create or replace function public.bl_cfg(p_key text)
returns text language sql stable security definer set search_path = public
as $$ select value from public.bl_config where key = p_key $$;
revoke execute on function public.bl_cfg(text) from anon, authenticated, public;

-- agents may set their own Drop days + timezone (RLS already restricts to own row).
-- cell_phone + sms_opt_in are intentionally NOT granted to agents here: only the verified-phone
-- flow (BRIEF 4 check-phone-code, service role) writes them, for TCPA/opt-in integrity.
grant update (drop_days, agent_tz) on public.agent_profiles to authenticated;

-- ============================================================
-- migration: 20260619040915  drop_brief3_routing_and_vault
-- ============================================================
-- BRIEF 3 (The Drop) — routing waterfall, freshness-aware vault, alerts. One transaction.

-- Safe tz -> ISO day-of-week (bad/blank tz falls back to Central; never throws inside routing)
create or replace function public.bl_local_isodow(p_tz text)
returns int language plpgsql stable set search_path = public as $fn$
begin
  return extract(isodow from (now() at time zone coalesce(nullif(trim(p_tz),''),'America/Chicago')))::int;
exception when others then
  return extract(isodow from (now() at time zone 'America/Chicago'))::int;
end; $fn$;

-- Consolidated agent email (Drop / Same-Day Drop label by age). Fail-open.
create or replace function public.bl_send_agent_email(p_lead_id uuid)
returns void language plpgsql security definer set search_path = public as $fn$
declare
  l record; api_key text; agent_email text; agent_first text;
  age_hours numeric; drop_window numeric; label text; tstamp text;
begin
  select * into l from public.leads where id = p_lead_id;
  if not found or l.assigned_agent_id is null then return; end if;

  select au.email into agent_email from auth.users au where au.id = l.assigned_agent_id;
  select first_name into agent_first from public.agent_profiles where id = l.assigned_agent_id;
  select decrypted_secret into api_key from vault.decrypted_secrets where name = 'resend_api_key';
  if api_key is null or agent_email is null then return; end if;

  age_hours := extract(epoch from (now() - coalesce(l.submitted_at, l.created_at))) / 3600.0;
  drop_window := coalesce(public.bl_cfg('drop_window_hours'),'6')::numeric;
  label := case when age_hours <= drop_window then 'Drop' else 'Same-Day Drop' end;
  tstamp := to_char(coalesce(l.submitted_at, l.created_at) at time zone 'America/Chicago', 'Mon DD, HH12:MI AM') || ' CT';

  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization','Bearer '||api_key,'Content-Type','application/json'),
    body := jsonb_build_object(
      'from','Black Label Leads <alerts@blacklabelleads.app>',
      'to', jsonb_build_array(agent_email),
      'subject', label || ': ' || coalesce(l.first_name,'') || ' ' || coalesce(l.last_name,'') || ' (' || coalesce(l.state,'') || ')',
      'html','<h2>A ' || label || ' just landed</h2><p>Hi ' || coalesce(agent_first,'') || ',<br><br><b>' || coalesce(l.first_name,'') || ' ' || coalesce(l.last_name,'') || '</b> -- ' || coalesce(l.state,'') || ' / ' || public.bl_vert_label(coalesce(l.vertical,'')) || '<br>Phone: ' || coalesce(l.phone,'') || '<br>Submitted: ' || tstamp || '<br><br>Exclusively yours, held for you. Call while they are warmest: <a href="https://portal.blacklabelleads.app/portal.html">your portal</a>.</p>'
    )
  );
exception when others then null;
end; $fn$;

-- Routing waterfall (BEFORE INSERT on leads): live route -> founder fallback -> vault.
create or replace function public.auto_assign_lead()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare
  pick uuid; fb_id uuid; fb_mode text; api_key text;
  vert text := coalesce(new.vertical,''); st text := coalesce(new.state,'');
begin
  if new.assigned_agent_id is not null then return new; end if;

  -- 1) LIVE ROUTE: licensed + opted-in for state, vertical pref, under cap, today is a Drop day (agent tz)
  select p.id into pick
  from public.agent_profiles p
  where p.status = 'active'
    and public.bl_state_code(st) = any(public.bl_norm_states(p.states_licensed))
    and (p.active_states is null or trim(p.active_states) = ''
         or public.bl_state_code(st) = any(public.bl_norm_states(p.active_states)))
    and (p.active_verticals is null or trim(p.active_verticals) = ''
         or p.active_verticals ilike '%' || public.bl_vert_label(vert) || '%')
    and p.received_this_week < p.weekly_cap
    and (public.bl_local_isodow(p.agent_tz) = any(p.drop_days))
  order by p.last_assigned_at asc nulls first, p.received_this_week asc
  limit 1
  for update skip locked;

  if pick is not null then
    new.assigned_agent_id := pick;
    new.assigned_at := now();
    new.lead_status := coalesce(new.lead_status,'NEW');
    update public.agent_profiles
      set received_this_week = received_this_week + 1, last_assigned_at = now()
      where id = pick;
    return new;  -- AFTER-insert trigger fires the Drop alert
  end if;

  -- 2) FOUNDER FALLBACK (config-driven; inert while fallback_agent_id is NULL). License gate required.
  begin
    fb_mode := public.bl_cfg('fallback_mode');
    fb_id := nullif(public.bl_cfg('fallback_agent_id'),'')::uuid;
  exception when others then
    fb_mode := null; fb_id := null;
  end;
  if fb_mode = 'founder' and fb_id is not null then
    if exists (
      select 1 from public.agent_profiles p
      where p.id = fb_id
        and public.bl_state_code(st) = any(public.bl_norm_states(p.states_licensed))
    ) then
      new.assigned_agent_id := fb_id;
      new.assigned_at := now();
      new.lead_status := coalesce(new.lead_status,'NEW');
      update public.agent_profiles set last_assigned_at = now() where id = fb_id;  -- catch-all: do NOT bump weekly cap count
      return new;
    end if;
  end if;

  -- 3) VAULT: leave unassigned + owner alert
  begin
    select decrypted_secret into api_key from vault.decrypted_secrets where name = 'resend_api_key';
    if api_key is not null then
      perform net.http_post(
        url := 'https://api.resend.com/emails',
        headers := jsonb_build_object('Authorization','Bearer '||api_key,'Content-Type','application/json'),
        body := jsonb_build_object(
          'from','Black Label Leads <alerts@blacklabelleads.app>',
          'to', jsonb_build_array('blacklabelleads@gmail.com'),
          'subject','UNASSIGNED LEAD: ' || coalesce(new.first_name,'') || ' ' || coalesce(new.last_name,'') || ' (' || st || ')',
          'html','<h2>A lead came in with no eligible agent</h2><p>No active agent is licensed + opted-in for <b>' || st || ' / ' || public.bl_vert_label(vert) || '</b> on their Drop day (or all are at weekly cap), and founder fallback did not apply.<br><br><b>' || coalesce(new.first_name,'') || ' ' || coalesce(new.last_name,'') || '</b> -- ' || coalesce(new.phone,'') || '<br><br>Saved in the vault; the drain retries until it ages out at 24h.</p>'
        )
      );
    end if;
  exception when others then null;
  end;

  return new;
end; $fn$;

-- AFTER INSERT: fire The Drop alert (email now, SMS via notify-agent) for any assigned lead. Fail-open.
create or replace function public.bl_notify_after_assign()
returns trigger language plpgsql security definer set search_path = public as $fn$
begin
  if new.assigned_agent_id is not null then
    perform public.bl_send_agent_email(new.id);
    begin
      perform net.http_post(
        url := 'https://hqiyxeriugywlkbcuasu.supabase.co/functions/v1/notify-agent',
        headers := jsonb_build_object('Content-Type','application/json'),
        body := jsonb_build_object('lead_id', new.id)
      );
    exception when others then null;
    end;
  end if;
  return null;
end; $fn$;

drop trigger if exists trg_notify_after_assign on public.leads;
create trigger trg_notify_after_assign
  after insert on public.leads
  for each row execute function public.bl_notify_after_assign();

-- Vault drain (per agent): + drop-day + 24h-freshness filters; alerts via the shared paths.
create or replace function public.bl_drain_vault_for_agent(p_agent uuid)
returns integer language plpgsql security definer set search_path = public as $fn$
declare prof record; l record; assigned int := 0; fresh interval;
begin
  select * into prof from public.agent_profiles where id = p_agent and status = 'active';
  if not found then return 0; end if;
  if prof.received_this_week >= prof.weekly_cap then return 0; end if;
  if not (public.bl_local_isodow(prof.agent_tz) = any(prof.drop_days)) then return 0; end if;  -- only on their Drop day

  fresh := (coalesce(public.bl_cfg('freshness_hours'),'24') || ' hours')::interval;

  for l in
    select ld.* from public.leads ld
    where ld.assigned_agent_id is null
      and coalesce(ld.lead_status,'NEW') <> 'DEAD'
      and ld.aged_out_at is null
      and (now() - coalesce(ld.submitted_at, ld.created_at)) <= fresh
      and public.bl_state_code(coalesce(ld.state,'')) = any(public.bl_norm_states(prof.states_licensed))
      and (prof.active_states is null or trim(prof.active_states) = ''
           or public.bl_state_code(coalesce(ld.state,'')) = any(public.bl_norm_states(prof.active_states)))
      and (prof.active_verticals is null or trim(prof.active_verticals) = ''
           or prof.active_verticals ilike '%' || public.bl_vert_label(coalesce(ld.vertical,'')) || '%')
    order by ld.submitted_at asc nulls last, ld.created_at asc
    for update skip locked
  loop
    exit when (prof.received_this_week + assigned) >= prof.weekly_cap;
    update public.leads
      set assigned_agent_id = p_agent, assigned_at = now(), lead_status = coalesce(lead_status,'NEW')
      where id = l.id;
    assigned := assigned + 1;
    perform public.bl_send_agent_email(l.id);
    begin
      perform net.http_post(
        url := 'https://hqiyxeriugywlkbcuasu.supabase.co/functions/v1/notify-agent',
        headers := jsonb_build_object('Content-Type','application/json'),
        body := jsonb_build_object('lead_id', l.id)
      );
    exception when others then null;
    end;
  end loop;

  if assigned > 0 then
    update public.agent_profiles
      set received_this_week = received_this_week + assigned, last_assigned_at = now()
      where id = p_agent;
  end if;
  return assigned;
end; $fn$;

-- Drain the vault for every active agent (cron engine for held-fresh leads releasing on Drop days)
create or replace function public.bl_drain_vault_all()
returns integer language plpgsql security definer set search_path = public as $fn$
declare a record; total int := 0; n int;
begin
  for a in select id from public.agent_profiles where status = 'active' loop
    n := public.bl_drain_vault_for_agent(a.id);
    total := total + coalesce(n,0);
  end loop;
  if total > 0 then
    begin insert into public.bl_action_log(action, detail) values ('vault_drain_all', jsonb_build_object('assigned', total)); exception when others then null; end;
  end if;
  return total;
end; $fn$;

-- Age out stale (past freshness) vaulted leads — never delivered as a Drop again. Idempotent.
create or replace function public.bl_age_out_stale()
returns integer language plpgsql security definer set search_path = public as $fn$
declare fresh interval; n int;
begin
  fresh := (coalesce(public.bl_cfg('freshness_hours'),'24') || ' hours')::interval;
  update public.leads
    set aged_out_at = now()
    where assigned_agent_id is null
      and aged_out_at is null
      and coalesce(lead_status,'NEW') <> 'DEAD'
      and (now() - coalesce(submitted_at, created_at)) > fresh;
  get diagnostics n = row_count;
  if n > 0 then
    begin insert into public.bl_action_log(action, detail) values ('vault_age_out', jsonb_build_object('aged_out', n)); exception when others then null; end;
  end if;
  return n;
end; $fn$;

-- Recruiting count + owner view: show only real deliverable (fresh, not aged-out) leads.
create or replace function public.bl_vault_count(p_state text default null, p_vertical text default null)
returns integer language sql stable security definer set search_path = public as $fn$
  select count(*)::int from public.leads
  where assigned_agent_id is null
    and coalesce(lead_status,'NEW') <> 'DEAD'
    and aged_out_at is null
    and (now() - coalesce(submitted_at, created_at)) <= (coalesce(public.bl_cfg('freshness_hours'),'24')||' hours')::interval
    and (p_state is null or public.bl_state_code(coalesce(state,'')) = public.bl_state_code(p_state))
    and (p_vertical is null or public.bl_vert_label(coalesce(vertical,'')) = public.bl_vert_label(p_vertical));
$fn$;

grant execute on function public.bl_cfg(text) to service_role;  -- so vault_overview (queried by service_role) can read config

create or replace view public.vault_overview as
 select coalesce(state,'(unknown)') as state,
        coalesce(vertical,'(unknown)') as vertical,
        count(*) as waiting,
        min(coalesce(submitted_at, created_at)) as oldest,
        now() - min(coalesce(submitted_at, created_at)) as oldest_age
   from public.leads
  where assigned_agent_id is null
    and coalesce(lead_status,'NEW') <> 'DEAD'
    and aged_out_at is null
    and (now() - coalesce(submitted_at, created_at)) <= (coalesce(public.bl_cfg('freshness_hours'),'24')||' hours')::interval
  group by coalesce(state,'(unknown)'), coalesce(vertical,'(unknown)')
  order by count(*) desc;

-- ============================================================
-- migration: 20260619045559  drop_brief4_onboarding_gate
-- ============================================================
-- BRIEF 4 — onboarding gate. One transaction.

-- Schema: setup tracking (phone_verified_at reserved for when Twilio Verify is added later)
alter table public.agent_profiles
  add column if not exists setup_complete boolean not null default false,
  add column if not exists setup_step int not null default 0,
  add column if not exists phone_verified_at timestamptz;

-- Backfill existing agents so none go dark when the gate turns on. New signups default false.
update public.agent_profiles set setup_complete = true where setup_complete = false;

-- Agents manage their own setup fields (RLS already restricts to own row).
-- cell_phone / phone_verified_at / sms_opt_in stay UNgranted (verified-phone flow only).
grant update (setup_complete, setup_step) on public.agent_profiles to authenticated;

-- Routing gate: only setup-complete agents are eligible for live routing (built on BRIEF 3 waterfall).
create or replace function public.auto_assign_lead()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare
  pick uuid; fb_id uuid; fb_mode text; api_key text;
  vert text := coalesce(new.vertical,''); st text := coalesce(new.state,'');
begin
  if new.assigned_agent_id is not null then return new; end if;

  -- 1) LIVE ROUTE: active, SETUP-COMPLETE, licensed + opted-in for state, vertical pref, under cap, Drop day today
  select p.id into pick
  from public.agent_profiles p
  where p.status = 'active'
    and p.setup_complete
    and public.bl_state_code(st) = any(public.bl_norm_states(p.states_licensed))
    and (p.active_states is null or trim(p.active_states) = ''
         or public.bl_state_code(st) = any(public.bl_norm_states(p.active_states)))
    and (p.active_verticals is null or trim(p.active_verticals) = ''
         or p.active_verticals ilike '%' || public.bl_vert_label(vert) || '%')
    and p.received_this_week < p.weekly_cap
    and (public.bl_local_isodow(p.agent_tz) = any(p.drop_days))
  order by p.last_assigned_at asc nulls first, p.received_this_week asc
  limit 1
  for update skip locked;

  if pick is not null then
    new.assigned_agent_id := pick;
    new.assigned_at := now();
    new.lead_status := coalesce(new.lead_status,'NEW');
    update public.agent_profiles
      set received_this_week = received_this_week + 1, last_assigned_at = now()
      where id = pick;
    return new;
  end if;

  -- 2) FOUNDER FALLBACK (config-driven; license gate required)
  begin
    fb_mode := public.bl_cfg('fallback_mode');
    fb_id := nullif(public.bl_cfg('fallback_agent_id'),'')::uuid;
  exception when others then
    fb_mode := null; fb_id := null;
  end;
  if fb_mode = 'founder' and fb_id is not null then
    if exists (
      select 1 from public.agent_profiles p
      where p.id = fb_id
        and public.bl_state_code(st) = any(public.bl_norm_states(p.states_licensed))
    ) then
      new.assigned_agent_id := fb_id;
      new.assigned_at := now();
      new.lead_status := coalesce(new.lead_status,'NEW');
      update public.agent_profiles set last_assigned_at = now() where id = fb_id;
      return new;
    end if;
  end if;

  -- 3) VAULT: unassigned + owner alert
  begin
    select decrypted_secret into api_key from vault.decrypted_secrets where name = 'resend_api_key';
    if api_key is not null then
      perform net.http_post(
        url := 'https://api.resend.com/emails',
        headers := jsonb_build_object('Authorization','Bearer '||api_key,'Content-Type','application/json'),
        body := jsonb_build_object(
          'from','Black Label Leads <alerts@blacklabelleads.app>',
          'to', jsonb_build_array('blacklabelleads@gmail.com'),
          'subject','UNASSIGNED LEAD: ' || coalesce(new.first_name,'') || ' ' || coalesce(new.last_name,'') || ' (' || st || ')',
          'html','<h2>A lead came in with no eligible agent</h2><p>No active, set-up agent is licensed + opted-in for <b>' || st || ' / ' || public.bl_vert_label(vert) || '</b> on their Drop day (or all at weekly cap), and founder fallback did not apply.<br><br><b>' || coalesce(new.first_name,'') || ' ' || coalesce(new.last_name,'') || '</b> -- ' || coalesce(new.phone,'') || '<br><br>Saved in the vault; the drain retries until it ages out at 24h.</p>'
        )
      );
    end if;
  exception when others then null;
  end;

  return new;
end; $fn$;

-- Drain gate: also require setup_complete (built on BRIEF 3 drain)
create or replace function public.bl_drain_vault_for_agent(p_agent uuid)
returns integer language plpgsql security definer set search_path = public as $fn$
declare prof record; l record; assigned int := 0; fresh interval;
begin
  select * into prof from public.agent_profiles where id = p_agent and status = 'active';
  if not found then return 0; end if;
  if not coalesce(prof.setup_complete,false) then return 0; end if;          -- BRIEF 4 gate
  if prof.received_this_week >= prof.weekly_cap then return 0; end if;
  if not (public.bl_local_isodow(prof.agent_tz) = any(prof.drop_days)) then return 0; end if;

  fresh := (coalesce(public.bl_cfg('freshness_hours'),'24') || ' hours')::interval;

  for l in
    select ld.* from public.leads ld
    where ld.assigned_agent_id is null
      and coalesce(ld.lead_status,'NEW') <> 'DEAD'
      and ld.aged_out_at is null
      and (now() - coalesce(ld.submitted_at, ld.created_at)) <= fresh
      and public.bl_state_code(coalesce(ld.state,'')) = any(public.bl_norm_states(prof.states_licensed))
      and (prof.active_states is null or trim(prof.active_states) = ''
           or public.bl_state_code(coalesce(ld.state,'')) = any(public.bl_norm_states(prof.active_states)))
      and (prof.active_verticals is null or trim(prof.active_verticals) = ''
           or prof.active_verticals ilike '%' || public.bl_vert_label(coalesce(ld.vertical,'')) || '%')
    order by ld.submitted_at asc nulls last, ld.created_at asc
    for update skip locked
  loop
    exit when (prof.received_this_week + assigned) >= prof.weekly_cap;
    update public.leads
      set assigned_agent_id = p_agent, assigned_at = now(), lead_status = coalesce(lead_status,'NEW')
      where id = l.id;
    assigned := assigned + 1;
    perform public.bl_send_agent_email(l.id);
    begin
      perform net.http_post(
        url := 'https://hqiyxeriugywlkbcuasu.supabase.co/functions/v1/notify-agent',
        headers := jsonb_build_object('Content-Type','application/json'),
        body := jsonb_build_object('lead_id', l.id)
      );
    exception when others then null;
    end;
  end loop;

  if assigned > 0 then
    update public.agent_profiles
      set received_this_week = received_this_week + assigned, last_assigned_at = now()
      where id = p_agent;
  end if;
  return assigned;
end; $fn$;

-- Agent finishes their own setup, then their waiting leads drain immediately (first Drops).
-- SECURITY DEFINER so it can call the locked drain without exposing it to the browser.
create or replace function public.bl_finish_setup()
returns integer language plpgsql security definer set search_path = public as $fn$
declare uid uuid := auth.uid(); n int;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  update public.agent_profiles set setup_complete = true, setup_step = 6 where id = uid;
  n := public.bl_drain_vault_for_agent(uid);
  return coalesce(n,0);
end; $fn$;
revoke execute on function public.bl_finish_setup() from anon, public;
grant execute on function public.bl_finish_setup() to authenticated;

-- ============================================================
-- migration: 20260619050715  drop_brief5_markets_foundation
-- ============================================================
-- BRIEF 5 foundation: activation timestamp + markets (state ramp) + owner market controls.

-- once-only activation guard / "billing started on first Drop" marker
alter table public.agent_profiles add column if not exists first_drop_at timestamptz;

-- markets: which state/vertical you are actively advertising (expectations + ops, NOT a routing gate)
create table if not exists public.markets (
  state text not null,
  vertical text not null,
  is_open boolean not null default false,
  opened_at timestamptz,
  notes text,
  updated_at timestamptz not null default now(),
  primary key (state, vertical)
);
alter table public.markets enable row level security;  -- no policies: owner reaches it only via the RPCs below

-- owner: list markets + how many reserved agents are waiting per state
create or replace function public.bl_owner_markets()
returns json language plpgsql stable security definer set search_path = public as $fn$
begin
  if not public.bl_is_owner() then raise exception 'not authorized'; end if;
  return coalesce((
    select json_agg(row_to_json(t)) from (
      select m.state, m.vertical, m.is_open, m.opened_at, m.notes,
        (select count(*) from public.agent_profiles p
          where p.subscription_status = 'reserved'
            and public.bl_state_code(m.state) = any(public.bl_norm_states(p.states_licensed))) as reserved_agents
      from public.markets m
      order by m.is_open, m.state, m.vertical
    ) t
  ), '[]'::json);
end; $fn$;

-- owner: open/close a market; opening drains waiting leads to eligible agents there (their first Drops)
create or replace function public.bl_owner_set_market(p_state text, p_vertical text, p_open boolean, p_notes text default null)
returns json language plpgsql security definer set search_path = public as $fn$
declare a record; drained int := 0;
begin
  if not public.bl_is_owner() then raise exception 'not authorized'; end if;
  insert into public.markets(state, vertical, is_open, opened_at, notes, updated_at)
    values (p_state, p_vertical, p_open, case when p_open then now() else null end, p_notes, now())
  on conflict (state, vertical) do update
    set is_open = excluded.is_open,
        opened_at = coalesce(markets.opened_at, case when excluded.is_open then now() end),
        notes = coalesce(excluded.notes, markets.notes),
        updated_at = now();
  if p_open then
    for a in
      select p.id from public.agent_profiles p
      where coalesce(p.setup_complete,false)
        and (p.status = 'active' or p.subscription_status = 'reserved')
        and public.bl_state_code(p_state) = any(public.bl_norm_states(p.states_licensed))
    loop
      drained := drained + coalesce(public.bl_drain_vault_for_agent(a.id), 0);
    end loop;
  end if;
  return json_build_object('ok', true, 'drained', drained);
end; $fn$;

revoke execute on function public.bl_owner_markets() from anon, public;
grant execute on function public.bl_owner_markets() to authenticated;
revoke execute on function public.bl_owner_set_market(text,text,boolean,text) from anon, public;
grant execute on function public.bl_owner_set_market(text,text,boolean,text) to authenticated;

-- ============================================================
-- migration: 20260619051116  drop_brief5_activation_hook
-- ============================================================
-- BRIEF 5 — activation hook: on a reserved agent's FIRST Drop, start their billing.
-- Once-only (atomic claim of first_drop_at) + fail-open (never blocks the lead). Built on BRIEF 4.

create or replace function public.auto_assign_lead()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare
  pick uuid; fb_id uuid; fb_mode text; api_key text;
  vert text := coalesce(new.vertical,''); st text := coalesce(new.state,'');
begin
  if new.assigned_agent_id is not null then return new; end if;

  select p.id into pick
  from public.agent_profiles p
  where p.status = 'active'
    and p.setup_complete
    and public.bl_state_code(st) = any(public.bl_norm_states(p.states_licensed))
    and (p.active_states is null or trim(p.active_states) = ''
         or public.bl_state_code(st) = any(public.bl_norm_states(p.active_states)))
    and (p.active_verticals is null or trim(p.active_verticals) = ''
         or p.active_verticals ilike '%' || public.bl_vert_label(vert) || '%')
    and p.received_this_week < p.weekly_cap
    and (public.bl_local_isodow(p.agent_tz) = any(p.drop_days))
  order by p.last_assigned_at asc nulls first, p.received_this_week asc
  limit 1
  for update skip locked;

  if pick is not null then
    new.assigned_agent_id := pick;
    new.assigned_at := now();
    new.lead_status := coalesce(new.lead_status,'NEW');
    update public.agent_profiles
      set received_this_week = received_this_week + 1, last_assigned_at = now()
      where id = pick;
    -- BRIEF 5: first Drop for a RESERVED agent -> start their billing (once-only, fail-open)
    begin
      update public.agent_profiles set first_drop_at = now()
        where id = pick and first_drop_at is null and subscription_status = 'reserved';
      if found then
        perform net.http_post(
          url := 'https://hqiyxeriugywlkbcuasu.supabase.co/functions/v1/start-agent-billing',
          headers := jsonb_build_object('Content-Type','application/json'),
          body := jsonb_build_object('agent_id', pick)
        );
      end if;
    exception when others then null;
    end;
    return new;
  end if;

  -- 2) FOUNDER FALLBACK
  begin
    fb_mode := public.bl_cfg('fallback_mode');
    fb_id := nullif(public.bl_cfg('fallback_agent_id'),'')::uuid;
  exception when others then
    fb_mode := null; fb_id := null;
  end;
  if fb_mode = 'founder' and fb_id is not null then
    if exists (
      select 1 from public.agent_profiles p
      where p.id = fb_id
        and public.bl_state_code(st) = any(public.bl_norm_states(p.states_licensed))
    ) then
      new.assigned_agent_id := fb_id;
      new.assigned_at := now();
      new.lead_status := coalesce(new.lead_status,'NEW');
      update public.agent_profiles set last_assigned_at = now() where id = fb_id;
      return new;
    end if;
  end if;

  -- 3) VAULT: unassigned + owner alert
  begin
    select decrypted_secret into api_key from vault.decrypted_secrets where name = 'resend_api_key';
    if api_key is not null then
      perform net.http_post(
        url := 'https://api.resend.com/emails',
        headers := jsonb_build_object('Authorization','Bearer '||api_key,'Content-Type','application/json'),
        body := jsonb_build_object(
          'from','Black Label Leads <alerts@blacklabelleads.app>',
          'to', jsonb_build_array('blacklabelleads@gmail.com'),
          'subject','UNASSIGNED LEAD: ' || coalesce(new.first_name,'') || ' ' || coalesce(new.last_name,'') || ' (' || st || ')',
          'html','<h2>A lead came in with no eligible agent</h2><p>No active, set-up agent is licensed + opted-in for <b>' || st || ' / ' || public.bl_vert_label(vert) || '</b> on their Drop day (or all at weekly cap), and founder fallback did not apply.<br><br><b>' || coalesce(new.first_name,'') || ' ' || coalesce(new.last_name,'') || '</b> -- ' || coalesce(new.phone,'') || '<br><br>Saved in the vault; the drain retries until it ages out at 24h.</p>'
        )
      );
    end if;
  exception when others then null;
  end;

  return new;
end; $fn$;

create or replace function public.bl_drain_vault_for_agent(p_agent uuid)
returns integer language plpgsql security definer set search_path = public as $fn$
declare prof record; l record; assigned int := 0; fresh interval;
begin
  select * into prof from public.agent_profiles where id = p_agent and status = 'active';
  if not found then return 0; end if;
  if not coalesce(prof.setup_complete,false) then return 0; end if;
  if prof.received_this_week >= prof.weekly_cap then return 0; end if;
  if not (public.bl_local_isodow(prof.agent_tz) = any(prof.drop_days)) then return 0; end if;

  fresh := (coalesce(public.bl_cfg('freshness_hours'),'24') || ' hours')::interval;

  for l in
    select ld.* from public.leads ld
    where ld.assigned_agent_id is null
      and coalesce(ld.lead_status,'NEW') <> 'DEAD'
      and ld.aged_out_at is null
      and (now() - coalesce(ld.submitted_at, ld.created_at)) <= fresh
      and public.bl_state_code(coalesce(ld.state,'')) = any(public.bl_norm_states(prof.states_licensed))
      and (prof.active_states is null or trim(prof.active_states) = ''
           or public.bl_state_code(coalesce(ld.state,'')) = any(public.bl_norm_states(prof.active_states)))
      and (prof.active_verticals is null or trim(prof.active_verticals) = ''
           or prof.active_verticals ilike '%' || public.bl_vert_label(coalesce(ld.vertical,'')) || '%')
    order by ld.submitted_at asc nulls last, ld.created_at asc
    for update skip locked
  loop
    exit when (prof.received_this_week + assigned) >= prof.weekly_cap;
    update public.leads
      set assigned_agent_id = p_agent, assigned_at = now(), lead_status = coalesce(lead_status,'NEW')
      where id = l.id;
    assigned := assigned + 1;
    perform public.bl_send_agent_email(l.id);
    begin
      perform net.http_post(
        url := 'https://hqiyxeriugywlkbcuasu.supabase.co/functions/v1/notify-agent',
        headers := jsonb_build_object('Content-Type','application/json'),
        body := jsonb_build_object('lead_id', l.id)
      );
    exception when others then null;
    end;
  end loop;

  if assigned > 0 then
    update public.agent_profiles
      set received_this_week = received_this_week + assigned, last_assigned_at = now()
      where id = p_agent;
    -- BRIEF 5: first Drop for a RESERVED agent -> start their billing (once-only, fail-open)
    begin
      update public.agent_profiles set first_drop_at = now()
        where id = p_agent and first_drop_at is null and subscription_status = 'reserved';
      if found then
        perform net.http_post(
          url := 'https://hqiyxeriugywlkbcuasu.supabase.co/functions/v1/start-agent-billing',
          headers := jsonb_build_object('Content-Type','application/json'),
          body := jsonb_build_object('agent_id', p_agent)
        );
      end if;
    exception when others then null;
    end;
  end if;
  return assigned;
end; $fn$;

-- ============================================================
-- migration: 20260619051716  drop_brief5_activation_retry
-- ============================================================
-- BRIEF 5 — retry sweep: re-attempt billing activation for any reserved agent whose first Drop
-- was claimed (first_drop_at set) but whose charge hasn't gone through yet (still 'reserved').
-- Fail-open companion to the inline activation hook.
create or replace function public.bl_retry_activations()
returns integer language plpgsql security definer set search_path = public as $fn$
declare a record; n int := 0;
begin
  for a in
    select id from public.agent_profiles
    where subscription_status = 'reserved' and first_drop_at is not null
  loop
    begin
      perform net.http_post(
        url := 'https://hqiyxeriugywlkbcuasu.supabase.co/functions/v1/start-agent-billing',
        headers := jsonb_build_object('Content-Type','application/json'),
        body := jsonb_build_object('agent_id', a.id)
      );
      n := n + 1;
    exception when others then null;
    end;
  end loop;
  return n;
end; $fn$;
revoke execute on function public.bl_retry_activations() from anon, authenticated, public;

select cron.schedule('drop-activation-retry', '*/10 * * * *', $$select public.bl_retry_activations();$$);

-- ============================================================
-- migration: 20260619054040  drop_brief5_billing_gate
-- ============================================================
-- BRIEF 5 — billing gate: live routing requires a card on file (reserved) or active billing.
-- Founder fallback is intentionally NOT gated on billing (it's the owner catch-all, license-gated only).
-- Built on the BRIEF 5 activation-hook versions.

create or replace function public.auto_assign_lead()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare
  pick uuid; fb_id uuid; fb_mode text; api_key text;
  vert text := coalesce(new.vertical,''); st text := coalesce(new.state,'');
begin
  if new.assigned_agent_id is not null then return new; end if;

  select p.id into pick
  from public.agent_profiles p
  where p.status = 'active'
    and p.setup_complete
    and coalesce(p.subscription_status,'none') in ('reserved','active')   -- BRIEF 5 billing gate
    and public.bl_state_code(st) = any(public.bl_norm_states(p.states_licensed))
    and (p.active_states is null or trim(p.active_states) = ''
         or public.bl_state_code(st) = any(public.bl_norm_states(p.active_states)))
    and (p.active_verticals is null or trim(p.active_verticals) = ''
         or p.active_verticals ilike '%' || public.bl_vert_label(vert) || '%')
    and p.received_this_week < p.weekly_cap
    and (public.bl_local_isodow(p.agent_tz) = any(p.drop_days))
  order by p.last_assigned_at asc nulls first, p.received_this_week asc
  limit 1
  for update skip locked;

  if pick is not null then
    new.assigned_agent_id := pick;
    new.assigned_at := now();
    new.lead_status := coalesce(new.lead_status,'NEW');
    update public.agent_profiles
      set received_this_week = received_this_week + 1, last_assigned_at = now()
      where id = pick;
    begin
      update public.agent_profiles set first_drop_at = now()
        where id = pick and first_drop_at is null and subscription_status = 'reserved';
      if found then
        perform net.http_post(
          url := 'https://hqiyxeriugywlkbcuasu.supabase.co/functions/v1/start-agent-billing',
          headers := jsonb_build_object('Content-Type','application/json'),
          body := jsonb_build_object('agent_id', pick)
        );
      end if;
    exception when others then null;
    end;
    return new;
  end if;

  begin
    fb_mode := public.bl_cfg('fallback_mode');
    fb_id := nullif(public.bl_cfg('fallback_agent_id'),'')::uuid;
  exception when others then
    fb_mode := null; fb_id := null;
  end;
  if fb_mode = 'founder' and fb_id is not null then
    if exists (
      select 1 from public.agent_profiles p
      where p.id = fb_id
        and public.bl_state_code(st) = any(public.bl_norm_states(p.states_licensed))
    ) then
      new.assigned_agent_id := fb_id;
      new.assigned_at := now();
      new.lead_status := coalesce(new.lead_status,'NEW');
      update public.agent_profiles set last_assigned_at = now() where id = fb_id;
      return new;
    end if;
  end if;

  begin
    select decrypted_secret into api_key from vault.decrypted_secrets where name = 'resend_api_key';
    if api_key is not null then
      perform net.http_post(
        url := 'https://api.resend.com/emails',
        headers := jsonb_build_object('Authorization','Bearer '||api_key,'Content-Type','application/json'),
        body := jsonb_build_object(
          'from','Black Label Leads <alerts@blacklabelleads.app>',
          'to', jsonb_build_array('blacklabelleads@gmail.com'),
          'subject','UNASSIGNED LEAD: ' || coalesce(new.first_name,'') || ' ' || coalesce(new.last_name,'') || ' (' || st || ')',
          'html','<h2>A lead came in with no eligible agent</h2><p>No active, set-up, billing-ready agent is licensed + opted-in for <b>' || st || ' / ' || public.bl_vert_label(vert) || '</b> on their Drop day, and founder fallback did not apply.<br><br><b>' || coalesce(new.first_name,'') || ' ' || coalesce(new.last_name,'') || '</b> -- ' || coalesce(new.phone,'') || '<br><br>Saved in the vault; the drain retries until it ages out at 24h.</p>'
        )
      );
    end if;
  exception when others then null;
  end;

  return new;
end; $fn$;

create or replace function public.bl_drain_vault_for_agent(p_agent uuid)
returns integer language plpgsql security definer set search_path = public as $fn$
declare prof record; l record; assigned int := 0; fresh interval;
begin
  select * into prof from public.agent_profiles where id = p_agent and status = 'active';
  if not found then return 0; end if;
  if not coalesce(prof.setup_complete,false) then return 0; end if;
  if coalesce(prof.subscription_status,'none') not in ('reserved','active') then return 0; end if;  -- BRIEF 5 billing gate
  if prof.received_this_week >= prof.weekly_cap then return 0; end if;
  if not (public.bl_local_isodow(prof.agent_tz) = any(prof.drop_days)) then return 0; end if;

  fresh := (coalesce(public.bl_cfg('freshness_hours'),'24') || ' hours')::interval;

  for l in
    select ld.* from public.leads ld
    where ld.assigned_agent_id is null
      and coalesce(ld.lead_status,'NEW') <> 'DEAD'
      and ld.aged_out_at is null
      and (now() - coalesce(ld.submitted_at, ld.created_at)) <= fresh
      and public.bl_state_code(coalesce(ld.state,'')) = any(public.bl_norm_states(prof.states_licensed))
      and (prof.active_states is null or trim(prof.active_states) = ''
           or public.bl_state_code(coalesce(ld.state,'')) = any(public.bl_norm_states(prof.active_states)))
      and (prof.active_verticals is null or trim(prof.active_verticals) = ''
           or prof.active_verticals ilike '%' || public.bl_vert_label(coalesce(ld.vertical,'')) || '%')
    order by ld.submitted_at asc nulls last, ld.created_at asc
    for update skip locked
  loop
    exit when (prof.received_this_week + assigned) >= prof.weekly_cap;
    update public.leads
      set assigned_agent_id = p_agent, assigned_at = now(), lead_status = coalesce(lead_status,'NEW')
      where id = l.id;
    assigned := assigned + 1;
    perform public.bl_send_agent_email(l.id);
    begin
      perform net.http_post(
        url := 'https://hqiyxeriugywlkbcuasu.supabase.co/functions/v1/notify-agent',
        headers := jsonb_build_object('Content-Type','application/json'),
        body := jsonb_build_object('lead_id', l.id)
      );
    exception when others then null;
    end;
  end loop;

  if assigned > 0 then
    update public.agent_profiles
      set received_this_week = received_this_week + assigned, last_assigned_at = now()
      where id = p_agent;
    begin
      update public.agent_profiles set first_drop_at = now()
        where id = p_agent and first_drop_at is null and subscription_status = 'reserved';
      if found then
        perform net.http_post(
          url := 'https://hqiyxeriugywlkbcuasu.supabase.co/functions/v1/start-agent-billing',
          headers := jsonb_build_object('Content-Type','application/json'),
          body := jsonb_build_object('agent_id', p_agent)
        );
      end if;
    exception when others then null;
    end;
  end if;
  return assigned;
end; $fn$;

-- ============================================================
-- migration: 20260619062046  drop_brief6_coverage_changes
-- ============================================================
-- BRIEF 6 — mid-cycle coverage changes. Expansions pend to next paid week; reductions are immediate
-- (reductions just update active_states/active_verticals directly via the agent's existing column grant).

create table if not exists public.coverage_changes (
  id uuid primary key default gen_random_uuid(),
  agent_id uuid not null,
  change_type text not null check (change_type in ('add_state','add_vertical')),
  value text not null,
  effective_at timestamptz not null,
  applied boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists idx_coverage_changes_due on public.coverage_changes (agent_id, applied, effective_at);
alter table public.coverage_changes enable row level security;
-- agents read their own pending changes; all writes go through the RPCs below (no direct insert/update)
drop policy if exists coverage_changes_select_own on public.coverage_changes;
create policy coverage_changes_select_own on public.coverage_changes for select to authenticated using (agent_id = auth.uid());
grant select on public.coverage_changes to authenticated;

-- Agent requests an expansion (add a licensed state, or a vertical). Pends to next paid week.
create or replace function public.bl_request_expansion(p_change_type text, p_value text)
returns json language plpgsql security definer set search_path = public as $fn$
declare uid uuid := auth.uid(); prof record; eff timestamptz;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if p_change_type not in ('add_state','add_vertical') then raise exception 'bad change_type'; end if;
  if coalesce(trim(p_value),'') = '' then raise exception 'empty value'; end if;
  select * into prof from public.agent_profiles where id = uid;
  if not found then raise exception 'no profile'; end if;

  -- compliance: can only add a state you're licensed in
  if p_change_type = 'add_state'
     and not (public.bl_state_code(p_value) = any(public.bl_norm_states(prof.states_licensed))) then
    raise exception 'not licensed in that state';
  end if;

  -- already active? (active_states/active_verticals null = all on)
  if p_change_type = 'add_state' then
    if prof.active_states is null or trim(prof.active_states) = ''
       or public.bl_state_code(p_value) = any(public.bl_norm_states(prof.active_states)) then
      return json_build_object('ok', true, 'already_active', true);
    end if;
  else
    if prof.active_verticals is null or trim(prof.active_verticals) = ''
       or prof.active_verticals ilike '%' || p_value || '%' then
      return json_build_object('ok', true, 'already_active', true);
    end if;
  end if;

  -- already pending? return its date
  if exists (select 1 from public.coverage_changes
             where agent_id = uid and change_type = p_change_type and value = p_value and applied = false) then
    select effective_at into eff from public.coverage_changes
      where agent_id = uid and change_type = p_change_type and value = p_value and applied = false
      order by created_at desc limit 1;
    return json_build_object('ok', true, 'pending', true, 'effective_at', eff);
  end if;

  -- effective at the next billing boundary; if no active cycle yet, apply now
  eff := coalesce(prof.current_period_end, now());
  if eff <= now() then
    if p_change_type = 'add_state' then
      update public.agent_profiles
        set active_states = case when active_states is null or trim(active_states) = '' then null
                                 else active_states || ', ' || p_value end
        where id = uid;
    else
      update public.agent_profiles
        set active_verticals = case when active_verticals is null or trim(active_verticals) = '' then p_value
                                    else active_verticals || ', ' || p_value end
        where id = uid;
    end if;
    return json_build_object('ok', true, 'immediate', true, 'effective_at', now());
  end if;

  insert into public.coverage_changes(agent_id, change_type, value, effective_at)
    values (uid, p_change_type, p_value, eff);
  return json_build_object('ok', true, 'pending', true, 'effective_at', eff);
end; $fn$;
revoke execute on function public.bl_request_expansion(text,text) from anon, public;
grant execute on function public.bl_request_expansion(text,text) to authenticated;

-- Promote due, unapplied expansions into active coverage. Idempotent. Cron + invoice.paid call this.
create or replace function public.bl_promote_coverage_changes(p_agent uuid default null)
returns integer language plpgsql security definer set search_path = public as $fn$
declare c record; n int := 0;
begin
  for c in
    select * from public.coverage_changes
    where applied = false and effective_at <= now() and (p_agent is null or agent_id = p_agent)
    order by created_at asc
  loop
    if c.change_type = 'add_state' then
      update public.agent_profiles
        set active_states = case when active_states is null or trim(active_states) = '' then null
                                 else active_states || ', ' || c.value end
        where id = c.agent_id
          and not (active_states is not null and trim(active_states) <> ''
                   and public.bl_state_code(c.value) = any(public.bl_norm_states(active_states)));
    elsif c.change_type = 'add_vertical' then
      update public.agent_profiles
        set active_verticals = case when active_verticals is null or trim(active_verticals) = '' then c.value
                                    else active_verticals || ', ' || c.value end
        where id = c.agent_id
          and not (active_verticals is not null and active_verticals ilike '%' || c.value || '%');
    end if;
    update public.coverage_changes set applied = true where id = c.id;
    n := n + 1;
    begin insert into public.bl_action_log(action, detail)
      values ('coverage_promoted', jsonb_build_object('agent_id', c.agent_id, 'type', c.change_type, 'value', c.value));
    exception when others then null; end;
    perform public.bl_drain_vault_for_agent(c.agent_id);  -- deliver any waiting leads the new coverage now matches
  end loop;
  return n;
end; $fn$;
revoke execute on function public.bl_promote_coverage_changes(uuid) from anon, authenticated, public;

select cron.schedule('drop-coverage-promote', '0 * * * *', $$select public.bl_promote_coverage_changes();$$);

-- ============================================================
-- migration: 20260619062854  drop_brief6_cancel_expansion
-- ============================================================
-- Let an agent undo a still-pending expansion (before it activates/bills). Reductions/cancels are immediate.
create or replace function public.bl_cancel_expansion(p_change_type text, p_value text)
returns json language plpgsql security definer set search_path = public as $fn$
declare uid uuid := auth.uid(); n int;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  delete from public.coverage_changes
    where agent_id = uid and applied = false and change_type = p_change_type and value = p_value;
  get diagnostics n = row_count;
  return json_build_object('ok', true, 'cancelled', n);
end; $fn$;
revoke execute on function public.bl_cancel_expansion(text,text) from anon, public;
grant execute on function public.bl_cancel_expansion(text,text) to authenticated;

-- ============================================================
-- migration: 20260619065956  harden_cron_fns_and_table_grants
-- ============================================================
-- SECURITY FIX (systems check 2026-06-19): bl_age_out_stale() and bl_drain_vault_all() were left
-- EXECUTE-able by anon/public (default-on-CREATE) with no owner gate. They are cron-only. Lock them.
-- (pg_cron runs as postgres, which owns these SECURITY DEFINER fns, so the crons keep working.)
revoke execute on function public.bl_age_out_stale() from anon, authenticated, public;
revoke execute on function public.bl_drain_vault_all() from anon, authenticated, public;
grant execute on function public.bl_age_out_stale() to service_role;
grant execute on function public.bl_drain_vault_all() to service_role;

-- Defense-in-depth: drop leftover default-privilege write grants (RLS already neutralizes them).
-- coverage_changes: agents read their own rows only (via the select policy); all writes go through the RPCs.
revoke select, insert, update, delete on public.coverage_changes from anon;
revoke insert, update, delete on public.coverage_changes from authenticated;
-- markets: agents only READ openness; owner writes via bl_owner_set_market (SECURITY DEFINER).
revoke insert, update, delete, select on public.markets from anon;
revoke insert, update, delete on public.markets from authenticated;
-- Make the profile.html "starts once your state opens" caveat work once markets is seeded:
-- markets RLS was ON with no policy, so authenticated SELECT returned nothing. Add a read policy.
drop policy if exists markets_read_authenticated on public.markets;
create policy markets_read_authenticated on public.markets for select to authenticated using (true);

-- ============================================================
-- migration: 20260619075710  referral_phase1_schema
-- ============================================================
-- REFERRAL PHASE 1 — MIGRATION 1 of 2: SCHEMA (additive only)
insert into public.bl_config(key, value) values
  ('referral_pct',             '10'),
  ('welcome_discount_cents',   '20000'),
  ('qualifying_days',          '30'),
  ('reward_cap_months',        '12'),
  ('welcome_cap_per_referrer', '20')
on conflict (key) do nothing;

alter table public.agent_profiles add column if not exists referral_code text;
alter table public.agent_profiles add column if not exists referred_by uuid references public.agent_profiles(id);

create or replace function public.bl_gen_referral_code()
returns text language plpgsql security definer set search_path to 'public' as $fn$
declare alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; code text; i int;
begin
  loop
    code := '';
    for i in 1..6 loop
      code := code || substr(alphabet, 1 + floor(random()*length(alphabet))::int, 1);
    end loop;
    if not exists (select 1 from public.agent_profiles where referral_code = code) then
      return code;
    end if;
  end loop;
end; $fn$;

create unique index if not exists agent_profiles_referral_code_key on public.agent_profiles(referral_code);

do $do$
declare r record;
begin
  for r in select id from public.agent_profiles where referral_code is null loop
    update public.agent_profiles set referral_code = public.bl_gen_referral_code() where id = r.id;
  end loop;
end $do$;

create or replace function public.bl_assign_referral_code()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
begin
  if new.referral_code is null or btrim(new.referral_code) = '' then
    new.referral_code := public.bl_gen_referral_code();
  end if;
  return new;
end; $fn$;

drop trigger if exists trg_assign_referral_code on public.agent_profiles;
create trigger trg_assign_referral_code before insert on public.agent_profiles
for each row execute function public.bl_assign_referral_code();

alter table public.agent_profiles alter column referral_code set not null;

alter table public.agent_waitlist add column if not exists referral_code_used text;

create table if not exists public.referrals (
  id uuid primary key default gen_random_uuid(),
  referrer_agent_id  uuid not null references public.agent_profiles(id),
  referred_agent_id  uuid not null unique references public.agent_profiles(id),
  referral_code_used text,
  signed_up_at  timestamptz not null default now(),
  qualified_at  timestamptz,
  status text not null default 'pending'
    check (status in ('pending','qualified','active','canceled','disqualified')),
  welcome_discount_applied boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists referrals_referrer_idx on public.referrals(referrer_agent_id);

create table if not exists public.reward_ledger (
  id uuid primary key default gen_random_uuid(),
  referral_id          uuid not null references public.referrals(id),
  beneficiary_agent_id uuid not null references public.agent_profiles(id),
  period_week date,
  amount numeric not null check (amount = trunc(amount) and amount >= 0),
  entry_type text not null
    check (entry_type in ('accrued','applied_as_credit','paid_cash','clawed_back')),
  stripe_ref text,
  created_at timestamptz not null default now()
);
create index if not exists reward_ledger_beneficiary_idx on public.reward_ledger(beneficiary_agent_id);
create index if not exists reward_ledger_referral_idx     on public.reward_ledger(referral_id);
create unique index if not exists reward_ledger_dedupe_idx
  on public.reward_ledger(entry_type, stripe_ref);

alter table public.referrals     enable row level security;
alter table public.reward_ledger enable row level security;
revoke all on public.referrals     from anon, authenticated;
revoke all on public.reward_ledger from anon, authenticated;
grant select, insert, update, delete on public.referrals     to service_role;
grant select, insert, update, delete on public.reward_ledger to service_role;

revoke all on function public.bl_gen_referral_code()     from public, anon, authenticated;
revoke all on function public.bl_assign_referral_code()  from public, anon, authenticated;
grant execute on function public.bl_gen_referral_code()    to service_role;
grant execute on function public.bl_assign_referral_code() to service_role;

-- ============================================================
-- migration: 20260619075833  referral_phase1_functions
-- ============================================================
-- REFERRAL PHASE 1 — MIGRATION 2 of 2: FUNCTIONS / RPCs / attribution
create or replace function public.bl_referral_attribute(p_new_agent uuid, p_code text, p_email text default null)
returns void language plpgsql security definer set search_path to 'public' as $fn$
declare ref record; newp record; v_code text := upper(btrim(coalesce(p_code,'')));
begin
  if v_code = '' then return; end if;

  select id, npn into ref from public.agent_profiles where referral_code = v_code;
  if not found then
    perform public.bl_raise_alert('referral_code_unknown','info','Referral code used but not found: '||v_code,
      jsonb_build_object('agent',p_new_agent,'code',v_code), p_new_agent, null, 24);
    return;
  end if;

  select id, npn, referred_by, subscription_status into newp
    from public.agent_profiles where id = p_new_agent;
  if not found then return; end if;
  if newp.referred_by is not null then return; end if;
  if exists (select 1 from public.referrals where referred_agent_id = p_new_agent) then return; end if;
  if coalesce(newp.subscription_status,'none') not in ('none','reserved') then
    perform public.bl_raise_alert('referral_not_brand_new','info','Referral code used by a non-new account',
      jsonb_build_object('agent',p_new_agent,'code',v_code,'status',newp.subscription_status), p_new_agent, null, 24);
    return;
  end if;

  if ref.id = p_new_agent then
    perform public.bl_raise_alert('referral_self_block','warn','Self-referral blocked (same account)',
      jsonb_build_object('agent',p_new_agent,'code',v_code), p_new_agent, null, 24);
    return;
  end if;
  if ref.npn is not null and newp.npn is not null and ref.npn = newp.npn then
    perform public.bl_raise_alert('referral_self_block','warn','Self-referral blocked (matching NPN)',
      jsonb_build_object('agent',p_new_agent,'referrer',ref.id,'npn',newp.npn), p_new_agent, null, 24);
    return;
  end if;
  if p_email is not null and exists (
      select 1 from auth.users u where u.id = ref.id and lower(u.email) = lower(p_email)) then
    perform public.bl_raise_alert('referral_self_block','warn','Self-referral blocked (matching email)',
      jsonb_build_object('agent',p_new_agent,'referrer',ref.id), p_new_agent, null, 24);
    return;
  end if;

  update public.agent_profiles set referred_by = ref.id where id = p_new_agent and referred_by is null;
  insert into public.referrals(referrer_agent_id, referred_agent_id, referral_code_used, status)
  values (ref.id, p_new_agent, v_code, 'pending')
  on conflict (referred_agent_id) do nothing;
end; $fn$;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
declare w record; v_wl boolean;
begin
  select * into w from public.agent_waitlist where email = new.email order by created_at desc limit 1;
  v_wl := found;
  if v_wl then
    insert into public.agent_profiles (id, first_name, last_name, npn, states_licensed, status)
    values (new.id, w.first_name, w.last_name, w.npn, w.states_licensed, 'paused')
    on conflict (id) do nothing;
  else
    insert into public.agent_profiles (id, status) values (new.id, 'paused')
    on conflict (id) do nothing;
  end if;

  begin
    if v_wl and w.referral_code_used is not null and btrim(w.referral_code_used) <> '' then
      perform public.bl_referral_attribute(new.id, w.referral_code_used, new.email);
    end if;
  exception when others then null;
  end;

  return new;
end; $fn$;

create or replace function public.bl_referral_welcome_eligibility(p_agent uuid)
returns json language plpgsql security definer set search_path to 'public' as $fn$
declare r record; v_cents int; v_npn text; v_ref_customer text; v_ref_status text; v_cap int; v_used int;
begin
  select * into r from public.referrals where referred_agent_id = p_agent;
  if not found then return json_build_object('eligible',false,'reason','not_referred'); end if;
  if r.welcome_discount_applied then return json_build_object('eligible',false,'reason','already_applied'); end if;
  if r.status = 'disqualified' then return json_build_object('eligible',false,'reason','disqualified'); end if;

  select npn into v_npn from public.agent_profiles where id = p_agent;

  if v_npn is null or btrim(v_npn) = '' then
    perform public.bl_raise_alert('referral_welcome_npn_missing','warn',
      'Welcome discount held: referred agent has no NPN', jsonb_build_object('agent',p_agent), p_agent, null, 24);
    return json_build_object('eligible',false,'reason','npn_required_hold');
  end if;

  if exists (
      select 1 from public.referrals rr join public.agent_profiles ap on ap.id = rr.referred_agent_id
       where rr.welcome_discount_applied and ap.npn = v_npn and rr.referred_agent_id <> p_agent) then
    return json_build_object('eligible',false,'reason','npn_used');
  end if;

  v_cap := coalesce(nullif(public.bl_cfg('welcome_cap_per_referrer'),'')::int, 20);
  select count(*) into v_used from public.referrals
    where referrer_agent_id = r.referrer_agent_id and welcome_discount_applied;
  if v_used >= v_cap then
    perform public.bl_raise_alert('referral_welcome_cap','warn',
      'Welcome discount held: per-referrer cap reached',
      jsonb_build_object('referrer',r.referrer_agent_id,'used',v_used,'cap',v_cap,'agent',p_agent),
      r.referrer_agent_id, null, 24);
    return json_build_object('eligible',false,'reason','referrer_cap_hold');
  end if;

  v_cents := coalesce(nullif(public.bl_cfg('welcome_discount_cents'),'')::int, 0);
  if v_cents <= 0 then return json_build_object('eligible',false,'reason','no_discount_configured'); end if;

  select subscription_status, stripe_customer_id into v_ref_status, v_ref_customer
    from public.agent_profiles where id = r.referrer_agent_id;
  if coalesce(v_ref_status,'none') <> 'active' then
    perform public.bl_raise_alert('referral_welcome_inactive_referrer','info',
      'Welcome discount applied while referrer is not active',
      jsonb_build_object('referrer',r.referrer_agent_id,'status',v_ref_status,'agent',p_agent),
      r.referrer_agent_id, null, 24);
  end if;

  return json_build_object('eligible',true,'cents',v_cents,'referral_id',r.id,'referrer_customer',v_ref_customer);
end; $fn$;

create or replace function public.bl_referral_mark_welcome(p_agent uuid)
returns void language plpgsql security definer set search_path to 'public' as $fn$
begin
  update public.referrals set welcome_discount_applied = true where referred_agent_id = p_agent;
end; $fn$;

create or replace function public.bl_referral_disqualify(p_agent uuid, p_reason text)
returns void language plpgsql security definer set search_path to 'public' as $fn$
begin
  update public.referrals set status = 'disqualified' where referred_agent_id = p_agent and status <> 'disqualified';
  perform public.bl_raise_alert('referral_disqualified','warn','Referral disqualified: ' || coalesce(p_reason,''),
    jsonb_build_object('agent',p_agent,'reason',p_reason), p_agent, null, 24);
end; $fn$;

create or replace function public.bl_referral_eval_payment(p_customer text, p_invoice text, p_amount_cents bigint)
returns json language plpgsql security definer set search_path to 'public' as $fn$
declare friend record; r record; refr record; v_days int; v_cap int; v_pct numeric; v_amt bigint;
begin
  if p_customer is null or p_invoice is null then return json_build_object('accrue',false,'reason','bad_input'); end if;

  select id, first_drop_at, subscription_status into friend
    from public.agent_profiles where stripe_customer_id = p_customer limit 1;
  if not found then return json_build_object('accrue',false,'reason','no_friend'); end if;

  select * into r from public.referrals where referred_agent_id = friend.id;
  if not found then return json_build_object('accrue',false,'reason','not_referred'); end if;
  if r.status in ('disqualified','canceled') then return json_build_object('accrue',false,'reason',r.status); end if;

  v_days := coalesce(nullif(public.bl_cfg('qualifying_days'),'')::int, 30);

  if r.qualified_at is null then
    if friend.subscription_status = 'active' and friend.first_drop_at is not null
       and now() >= friend.first_drop_at + (v_days || ' days')::interval then
      update public.referrals set qualified_at = now(), status = 'active'
        where id = r.id and qualified_at is null;
      r.qualified_at := now();
    else
      return json_build_object('accrue',false,'reason','not_yet_qualified');
    end if;
  end if;

  select id, subscription_status, stripe_customer_id into refr
    from public.agent_profiles where id = r.referrer_agent_id;
  if not found or refr.subscription_status <> 'active' then
    return json_build_object('accrue',false,'reason','referrer_inactive');
  end if;
  if refr.stripe_customer_id is null then
    perform public.bl_raise_alert('referral_no_customer','warn','Referrer has no Stripe customer to credit',
      jsonb_build_object('referrer',refr.id,'referral',r.id), refr.id, null, 24);
    return json_build_object('accrue',false,'reason','referrer_no_customer');
  end if;

  v_cap := coalesce(nullif(public.bl_cfg('reward_cap_months'),'')::int, 12);
  if now() > r.qualified_at + (v_cap || ' months')::interval then
    return json_build_object('accrue',false,'reason','past_cap');
  end if;

  if exists (select 1 from public.reward_ledger where entry_type='accrued' and stripe_ref = p_invoice) then
    return json_build_object('accrue',false,'reason','already_accrued');
  end if;

  v_pct := coalesce(nullif(public.bl_cfg('referral_pct'),'')::numeric, 10);
  v_amt := round(p_amount_cents * v_pct / 100.0);
  if v_amt <= 0 then return json_build_object('accrue',false,'reason','zero_amount'); end if;

  return json_build_object('accrue',true,'amount_cents',v_amt,'referral_id',r.id,
    'beneficiary',refr.id,'referrer_customer',refr.stripe_customer_id,
    'period_week', date_trunc('week', now())::date);
end; $fn$;

create or replace function public.bl_referral_record_accrual(
  p_referral_id uuid, p_beneficiary uuid, p_period_week date, p_amount_cents bigint, p_friend_invoice text)
returns boolean language plpgsql security definer set search_path to 'public' as $fn$
declare v_n int;
begin
  insert into public.reward_ledger(referral_id, beneficiary_agent_id, period_week, amount, entry_type, stripe_ref)
  values (p_referral_id, p_beneficiary, p_period_week, p_amount_cents, 'accrued', p_friend_invoice)
  on conflict (entry_type, stripe_ref) do nothing;
  get diagnostics v_n = row_count;
  return v_n > 0;
end; $fn$;

create or replace function public.bl_referral_eval_clawback(p_invoice text, p_refunded_cents bigint, p_total_cents bigint)
returns json language plpgsql security definer set search_path to 'public' as $fn$
declare acc record; refr record; v_amt bigint;
begin
  if p_invoice is null then return json_build_object('clawback',false,'reason','no_invoice'); end if;
  select * into acc from public.reward_ledger where entry_type='accrued' and stripe_ref = p_invoice limit 1;
  if not found then return json_build_object('clawback',false,'reason','no_accrual'); end if;
  if exists (select 1 from public.reward_ledger where entry_type='clawed_back' and stripe_ref = p_invoice) then
    return json_build_object('clawback',false,'reason','already_clawed');
  end if;
  select id, stripe_customer_id into refr from public.agent_profiles where id = acc.beneficiary_agent_id;
  if not found or refr.stripe_customer_id is null then
    return json_build_object('clawback',false,'reason','no_referrer_customer');
  end if;

  if coalesce(p_total_cents,0) > 0 and coalesce(p_refunded_cents,0) > 0 then
    v_amt := round(acc.amount * p_refunded_cents::numeric / p_total_cents::numeric);
  else
    v_amt := acc.amount;
  end if;
  if v_amt > acc.amount then v_amt := acc.amount; end if;
  if v_amt <= 0 then return json_build_object('clawback',false,'reason','zero_amount'); end if;

  return json_build_object('clawback',true,'amount_cents',v_amt,'partial',(v_amt < acc.amount),
    'referral_id',acc.referral_id,'beneficiary',acc.beneficiary_agent_id,'referrer_customer',refr.stripe_customer_id);
end; $fn$;

create or replace function public.bl_referral_record_clawback(
  p_referral_id uuid, p_beneficiary uuid, p_amount_cents bigint, p_friend_invoice text)
returns boolean language plpgsql security definer set search_path to 'public' as $fn$
declare v_n int;
begin
  insert into public.reward_ledger(referral_id, beneficiary_agent_id, period_week, amount, entry_type, stripe_ref)
  values (p_referral_id, p_beneficiary, date_trunc('week', now())::date, p_amount_cents, 'clawed_back', p_friend_invoice)
  on conflict (entry_type, stripe_ref) do nothing;
  get diagnostics v_n = row_count;
  return v_n > 0;
end; $fn$;

create or replace function public.bl_referral_mark_canceled_by_customer(p_customer text)
returns void language plpgsql security definer set search_path to 'public' as $fn$
declare fid uuid;
begin
  if p_customer is null then return; end if;
  select id into fid from public.agent_profiles where stripe_customer_id = p_customer limit 1;
  if fid is null then return; end if;
  update public.referrals set status = 'canceled'
    where referred_agent_id = fid and status in ('pending','qualified','active');
end; $fn$;

create or replace function public.bl_my_referrals()
returns json language plpgsql security definer set search_path to 'public' as $fn$
declare uid uuid := auth.uid(); v_code text; v_earned numeric; v_clawed numeric; v_pending int; v_list json;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  select referral_code into v_code from public.agent_profiles where id = uid;
  select coalesce(sum(amount),0) into v_earned from public.reward_ledger where beneficiary_agent_id = uid and entry_type='accrued';
  select coalesce(sum(amount),0) into v_clawed from public.reward_ledger where beneficiary_agent_id = uid and entry_type='clawed_back';
  select count(*) into v_pending from public.referrals where referrer_agent_id = uid and status in ('pending','qualified');
  select coalesce(json_agg(j order by j.signed_up_at desc), '[]'::json) into v_list
  from (
    select r.signed_up_at, r.qualified_at, r.status,
           coalesce(nullif(btrim(coalesce(ap.first_name,'')||' '||left(coalesce(ap.last_name,''),1)),''),'New agent') as who
    from public.referrals r join public.agent_profiles ap on ap.id = r.referred_agent_id
    where r.referrer_agent_id = uid
  ) j;
  return json_build_object(
    'code', v_code,
    'link', 'https://blacklabelleads.app/apply.html?ref=' || coalesce(v_code,''),
    'net_credit_cents', (v_earned - v_clawed),
    'earned_cents', v_earned,
    'clawed_cents', v_clawed,
    'pending_count', v_pending,
    'referred', v_list
  );
end; $fn$;

create or replace function public.bl_owner_referrals()
returns json language plpgsql security definer set search_path to 'public' as $fn$
declare v_accrued numeric; v_clawed numeric; v_welcome_n int; v_welcome_cents int; v_list json;
begin
  if not public.bl_is_owner() then raise exception 'not authorized'; end if;
  select coalesce(sum(amount),0) into v_accrued from public.reward_ledger where entry_type='accrued';
  select coalesce(sum(amount),0) into v_clawed  from public.reward_ledger where entry_type='clawed_back';
  select count(*) into v_welcome_n from public.referrals where welcome_discount_applied;
  v_welcome_cents := v_welcome_n * coalesce(nullif(public.bl_cfg('welcome_discount_cents'),'')::int, 0);
  select coalesce(json_agg(j order by j.signed_up_at desc), '[]'::json) into v_list
  from (
    select r.id, r.status, r.signed_up_at, r.qualified_at, r.welcome_discount_applied,
           rr.referral_code as referrer_code,
           coalesce(nullif(btrim(coalesce(rr.first_name,'')||' '||coalesce(rr.last_name,'')),''),'?') as referrer,
           coalesce(nullif(btrim(coalesce(fr.first_name,'')||' '||coalesce(fr.last_name,'')),''),'?') as friend,
           coalesce((select sum(amount) from public.reward_ledger l where l.referral_id=r.id and l.entry_type='accrued'),0)
         - coalesce((select sum(amount) from public.reward_ledger l where l.referral_id=r.id and l.entry_type='clawed_back'),0) as net_cents
    from public.referrals r
    join public.agent_profiles rr on rr.id = r.referrer_agent_id
    join public.agent_profiles fr on fr.id = r.referred_agent_id
  ) j;
  return json_build_object(
    'total_accrued_cents',     v_accrued,
    'total_applied_cents',     (v_accrued - v_clawed),
    'total_clawed_back_cents', v_clawed,
    'net_program_cost_cents',  (v_accrued - v_clawed) + v_welcome_cents,
    'welcome_discounts_count', v_welcome_n,
    'welcome_discounts_cents', v_welcome_cents,
    'referrals', v_list
  );
end; $fn$;

revoke all on function public.bl_referral_attribute(uuid,text,text)              from public, anon, authenticated;
revoke all on function public.bl_referral_welcome_eligibility(uuid)              from public, anon, authenticated;
revoke all on function public.bl_referral_mark_welcome(uuid)                     from public, anon, authenticated;
revoke all on function public.bl_referral_disqualify(uuid,text)                  from public, anon, authenticated;
revoke all on function public.bl_referral_eval_payment(text,text,bigint)         from public, anon, authenticated;
revoke all on function public.bl_referral_record_accrual(uuid,uuid,date,bigint,text) from public, anon, authenticated;
revoke all on function public.bl_referral_eval_clawback(text,bigint,bigint)      from public, anon, authenticated;
revoke all on function public.bl_referral_record_clawback(uuid,uuid,bigint,text) from public, anon, authenticated;
revoke all on function public.bl_referral_mark_canceled_by_customer(text)        from public, anon, authenticated;

grant execute on function public.bl_referral_attribute(uuid,text,text)              to service_role;
grant execute on function public.bl_referral_welcome_eligibility(uuid)              to service_role;
grant execute on function public.bl_referral_mark_welcome(uuid)                     to service_role;
grant execute on function public.bl_referral_disqualify(uuid,text)                  to service_role;
grant execute on function public.bl_referral_eval_payment(text,text,bigint)         to service_role;
grant execute on function public.bl_referral_record_accrual(uuid,uuid,date,bigint,text) to service_role;
grant execute on function public.bl_referral_eval_clawback(text,bigint,bigint)      to service_role;
grant execute on function public.bl_referral_record_clawback(uuid,uuid,bigint,text) to service_role;
grant execute on function public.bl_referral_mark_canceled_by_customer(text)        to service_role;

revoke all on function public.bl_my_referrals()    from public, anon;
revoke all on function public.bl_owner_referrals() from public, anon;
grant execute on function public.bl_my_referrals()    to authenticated, service_role;
grant execute on function public.bl_owner_referrals() to authenticated, service_role;

-- ============================================================
-- migration: 20260619081728  referral_phase1_my_referrals_terms
-- ============================================================
create or replace function public.bl_my_referrals()
returns json language plpgsql security definer set search_path to 'public' as $fn$
declare uid uuid := auth.uid(); v_code text; v_earned numeric; v_clawed numeric; v_pending int; v_list json;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  select referral_code into v_code from public.agent_profiles where id = uid;
  select coalesce(sum(amount),0) into v_earned from public.reward_ledger where beneficiary_agent_id = uid and entry_type='accrued';
  select coalesce(sum(amount),0) into v_clawed from public.reward_ledger where beneficiary_agent_id = uid and entry_type='clawed_back';
  select count(*) into v_pending from public.referrals where referrer_agent_id = uid and status in ('pending','qualified');
  select coalesce(json_agg(j order by j.signed_up_at desc), '[]'::json) into v_list
  from (
    select r.signed_up_at, r.qualified_at, r.status,
           coalesce(nullif(btrim(coalesce(ap.first_name,'')||' '||left(coalesce(ap.last_name,''),1)),''),'New agent') as who
    from public.referrals r join public.agent_profiles ap on ap.id = r.referred_agent_id
    where r.referrer_agent_id = uid
  ) j;
  return json_build_object(
    'code', v_code,
    'link', 'https://blacklabelleads.app/apply.html?ref=' || coalesce(v_code,''),
    'net_credit_cents', (v_earned - v_clawed),
    'earned_cents', v_earned,
    'clawed_cents', v_clawed,
    'pending_count', v_pending,
    'referred', v_list,
    'terms', json_build_object(
      'pct', coalesce(nullif(public.bl_cfg('referral_pct'),'')::numeric, 10),
      'welcome_cents', coalesce(nullif(public.bl_cfg('welcome_discount_cents'),'')::int, 0),
      'qualifying_days', coalesce(nullif(public.bl_cfg('qualifying_days'),'')::int, 30),
      'cap_months', coalesce(nullif(public.bl_cfg('reward_cap_months'),'')::int, 12)
    )
  );
end; $fn$;

-- ============================================================
-- migration: 20260621010320  leads_add_quiz_funnel_columns
-- ============================================================
-- Additive, nullable, no defaults/backfill (FE quiz funnel). Columns inherit the leads table RLS.
alter table public.leads
  add column if not exists zip               text,
  add column if not exists coverage_purpose  text,
  add column if not exists existing_coverage text;
comment on column public.leads.zip               is 'Customer ZIP code (quiz funnel).';
comment on column public.leads.coverage_purpose  is 'What the customer wants the coverage to do (quiz funnel).';
comment on column public.leads.existing_coverage is 'Whether the customer already has life/burial coverage: Yes/No (quiz funnel).';

-- ============================================================
-- migration: 20260622163118  leads_add_address_column
-- ============================================================
-- Additive, nullable (optional address on the quiz funnel, esp. mortgage protection).
alter table public.leads add column if not exists address text;
comment on column public.leads.address is 'Customer street address (optional; quiz funnel, esp. mortgage protection).';

