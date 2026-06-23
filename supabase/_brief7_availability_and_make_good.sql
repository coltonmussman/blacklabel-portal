-- ============================================================================
-- BRIEF 7 — Availability toggle + next-available routing, and the softened lead
-- guarantee with an automatic make-good account credit.
-- Source-of-record snapshot of the FINAL state (after the adversarial-review fixes).
-- Applied to project hqiyxeriugywlkbcuasu via these migrations (in order):
--   brief7_part_a_availability
--   brief7_lock_auto_assign_lead_execute
--   brief7_part_b_make_good
--   brief7_part_b_make_good_fix_reduction_log   (coverage_changes CHECK only allows add_*; use a
--                                                 dedicated coverage_reduction_log instead)
--   brief7_pin_active_verts_search_path
--   brief7_make_good_cycle_dedupe               (review HIGH: per-cycle unique, not per-invoice only)
--   brief7_make_good_dropdays_target            (review HIGH: scale eff_target by scheduled drop_days)
-- Edge: stripe-webhook v15 (see functions/stripe-webhook/index.ts) gates make-good to
--   billing_reason='subscription_cycle' and issues the Stripe account credit.
-- Decisions/knobs live in bl_config (make_good_floor_pct 0.80, per_lead_rate_cents 5000,
--   make_good_mode 'credit', make_good_self_limit_pause_pct 0.20, make_good_target_silver/gold/blacklabel
--   5/12/30, availability_default_pause_hours 4).
-- ============================================================================

-- ============================== PART A — AVAILABILITY ==============================

alter table public.agent_profiles
  add column if not exists is_available boolean not null default true,
  add column if not exists available_until timestamptz null,
  add column if not exists availability_changed_at timestamptz null;

-- New cols are NOT in the column-level authenticated UPDATE grant, so only the SECURITY DEFINER RPC
-- can set them. The UI must READ them (column-privilege-aware), so grant SELECT only.
grant select (is_available, available_until, availability_changed_at) on public.agent_profiles to authenticated;

insert into public.bl_config(key, value) values ('availability_default_pause_hours','4')
  on conflict (key) do nothing;

create table if not exists public.availability_log (
  id uuid primary key default gen_random_uuid(),
  agent_id uuid not null references public.agent_profiles(id) on delete cascade,
  is_available boolean not null,
  available_until timestamptz null,
  source text not null default 'agent',
  changed_at timestamptz not null default now()
);
create index if not exists availability_log_agent_time_idx on public.availability_log(agent_id, changed_at desc);
alter table public.availability_log enable row level security;
revoke all on public.availability_log from anon, authenticated;
grant select, insert on public.availability_log to service_role;

-- Agent toggles their OWN availability. p_available true=resume (clears timer + drains queued leads);
-- false + null hours = config default window; false + >0 = that many hours; false + <=0 = indefinite.
create or replace function public.bl_set_availability(p_available boolean, p_hours integer default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare uid uuid := auth.uid(); v_until timestamptz; v_default int; n int := 0;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if p_available is null then raise exception 'p_available is required'; end if;
  if p_available then
    v_until := null;
  else
    if p_hours is null then
      v_default := coalesce(nullif(public.bl_cfg('availability_default_pause_hours'),'')::int, 4);
      v_until := now() + make_interval(hours => v_default);
    elsif p_hours > 0 then
      v_until := now() + make_interval(hours => p_hours);
    else
      v_until := null;  -- indefinite
    end if;
  end if;
  update public.agent_profiles
    set is_available = p_available, available_until = v_until, availability_changed_at = now()
    where id = uid;
  insert into public.availability_log(agent_id, is_available, available_until, source)
    values (uid, p_available, v_until, 'agent');
  if p_available then
    begin n := public.bl_drain_vault_for_agent(uid); exception when others then n := 0; end;
  end if;
  return jsonb_build_object('is_available', p_available, 'available_until', v_until, 'drained', n);
end; $$;
revoke all on function public.bl_set_availability(boolean, integer) from public, anon;
grant execute on function public.bl_set_availability(boolean, integer) to authenticated;

-- server/cron only: materialize lapsed timed pauses back to available.
create or replace function public.bl_revert_expired_availability()
returns integer language plpgsql security definer set search_path to 'public' as $$
declare n int := 0;
begin
  with reverted as (
    update public.agent_profiles
      set is_available = true, available_until = null, availability_changed_at = now()
      where is_available = false and available_until is not null and available_until <= now()
      returning id
  ),
  logged as (
    insert into public.availability_log(agent_id, is_available, available_until, source)
      select id, true, null, 'auto_revert' from reverted returning agent_id
  )
  select count(*) into n from logged;
  return coalesce(n,0);
end; $$;
revoke all on function public.bl_revert_expired_availability() from public, anon, authenticated;
grant execute on function public.bl_revert_expired_availability() to service_role;

-- ROUTING: effective-availability = is_available OR a timed pause already lapsed. Merged identically into
-- the live-route trigger (auto_assign_lead) and the drain (bl_drain_vault_for_agent). Founder fallback is
-- left UNCONDITIONAL on availability. bl_drain_vault_all reverts lapsed pauses before each */15 pass.
-- (Full bodies of auto_assign_lead / bl_drain_vault_for_agent / bl_drain_vault_all are in
--  schema-migrations.sql; the only Brief 7 change is the added predicate, marked "BRIEF 7 availability".)
-- auto_assign_lead direct EXECUTE was revoked from public/anon/authenticated (trigger fires regardless).
revoke execute on function public.auto_assign_lead() from public, anon, authenticated;

-- ============================== PART B — MAKE-GOOD ==============================

insert into public.bl_config(key, value) values
  ('make_good_floor_pct','0.80'),
  ('per_lead_rate_cents','5000'),
  ('make_good_mode','credit'),
  ('make_good_self_limit_pause_pct','0.20'),
  ('make_good_target_silver','5'),
  ('make_good_target_gold','12'),
  ('make_good_target_blacklabel','30')
on conflict (key) do nothing;

create table if not exists public.make_good_ledger (
  id uuid primary key default gen_random_uuid(),
  agent_id uuid not null references public.agent_profiles(id) on delete cascade,
  trigger_invoice text unique,                 -- idempotency: blocks webhook re-delivery
  period_start timestamptz not null,
  period_end timestamptz not null,
  target int not null,
  billable_delivered int not null,             -- gross leads assigned in window (refunds not subtracted; see note)
  shortfall int not null default 0,
  amount_cents int not null default 0,
  paused_pct int not null default 0,
  narrowed boolean not null default false,
  status text not null,                        -- credited | above_floor | skipped_self_limit | no_target | no_prior_cycle
  reason text,
  stripe_ref text,
  created_at timestamptz not null default now()
);
create index if not exists make_good_ledger_agent_idx on public.make_good_ledger(agent_id, created_at desc);
-- per-CYCLE idempotency (review HIGH): a different invoice covering the same cycle cannot double-credit.
create unique index if not exists make_good_ledger_cycle_uniq
  on public.make_good_ledger(agent_id, period_start, period_end);
alter table public.make_good_ledger enable row level security;
revoke all on public.make_good_ledger from anon, authenticated;
grant select, insert, update on public.make_good_ledger to service_role;

-- the canonical verticals active for a given active_verticals string (null/empty = all four)
create or replace function public.bl_active_verts(av text)
returns text[] language sql immutable set search_path to 'public' as $$
  select coalesce(array_agg(v) filter (where av is null or btrim(av) = '' or av ilike '%' || v || '%'), '{}'::text[])
  from unnest(array['Final Expense','Mortgage Protection','IUL','Annuity']) as v;
$$;

-- total seconds the agent was paused within [p_start,p_end), reconstructed from availability_log
-- (carry-in state + events + timer expiry). Server-only. Feeds the make-good self-limit guard.
create or replace function public.bl_make_good_paused_seconds(p_agent uuid, p_start timestamptz, p_end timestamptz)
returns numeric language plpgsql security definer set search_path to 'public' as $$
declare ev record; carry record; paused_secs numeric := 0; state_paused boolean := false; seg_start timestamptz; seg_until timestamptz;
begin
  select is_available, available_until into carry from public.availability_log
    where agent_id = p_agent and changed_at <= p_start order by changed_at desc limit 1;
  if found and carry.is_available = false then state_paused := true; seg_start := p_start; seg_until := carry.available_until; end if;
  for ev in select is_available, available_until, changed_at from public.availability_log
    where agent_id = p_agent and changed_at > p_start and changed_at < p_end order by changed_at loop
    if state_paused then
      paused_secs := paused_secs + greatest(0, extract(epoch from (least(ev.changed_at, coalesce(seg_until, ev.changed_at)) - seg_start)));
      state_paused := false;
    end if;
    if ev.is_available = false then state_paused := true; seg_start := ev.changed_at; seg_until := ev.available_until; end if;
  end loop;
  if state_paused then
    paused_secs := paused_secs + greatest(0, extract(epoch from (least(p_end, coalesce(seg_until, p_end)) - seg_start)));
  end if;
  return greatest(0, paused_secs);
end; $$;
revoke all on function public.bl_make_good_paused_seconds(uuid, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.bl_make_good_paused_seconds(uuid, timestamptz, timestamptz) to service_role;

-- trigger: when an agent NARROWS active states/verticals, log it (the make-good guard reads this).
-- NOTE: coverage_changes.change_type CHECK only allows add_state/add_vertical, so reductions go to a
-- dedicated locked table instead.
create table if not exists public.coverage_reduction_log (
  id uuid primary key default gen_random_uuid(),
  agent_id uuid not null references public.agent_profiles(id) on delete cascade,
  kind text not null,            -- 'state' | 'vertical'
  value text not null,
  changed_at timestamptz not null default now()
);
create index if not exists coverage_reduction_log_agent_idx on public.coverage_reduction_log(agent_id, changed_at desc);
alter table public.coverage_reduction_log enable row level security;
revoke all on public.coverage_reduction_log from anon, authenticated;
grant select, insert on public.coverage_reduction_log to service_role;

create or replace function public.bl_log_coverage_reduction()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare removed_states text[]; removed_verts text[];
begin
  select array_agg(s) into removed_states from (
    select unnest(public.bl_norm_states(coalesce(nullif(btrim(old.active_states),''), old.states_licensed)))
    except select unnest(public.bl_norm_states(coalesce(nullif(btrim(new.active_states),''), new.states_licensed)))) t(s);
  if removed_states is not null and array_length(removed_states,1) > 0 then
    insert into public.coverage_reduction_log(agent_id, kind, value) values (new.id, 'state', array_to_string(removed_states, ', '));
  end if;
  select array_agg(v) into removed_verts from (
    select unnest(public.bl_active_verts(old.active_verticals))
    except select unnest(public.bl_active_verts(new.active_verticals))) t(v);
  if removed_verts is not null and array_length(removed_verts,1) > 0 then
    insert into public.coverage_reduction_log(agent_id, kind, value) values (new.id, 'vertical', array_to_string(removed_verts, ', '));
  end if;
  return new;
end; $$;
revoke all on function public.bl_log_coverage_reduction() from public, anon, authenticated;
drop trigger if exists trg_log_coverage_reduction on public.agent_profiles;
create trigger trg_log_coverage_reduction after update of active_states, active_verticals on public.agent_profiles
  for each row when (new.active_states is distinct from old.active_states or new.active_verticals is distinct from old.active_verticals)
  execute function public.bl_log_coverage_reduction();

-- the testable evaluator core. Prior cycle = [period_start - interval, period_start] clamped to first_drop_at.
-- eff_target = tier target scaled by the agent's SCHEDULED drop-days in the window (closes the drop_days
-- self-throttle hole + subsumes partial-window proration). delivered = gross leads assigned in the window
-- (refunds compensated separately by the refund standard; not subtracted, to avoid double-paying a lead the
-- refund+replace already covered). Self-limit guard: paused >= 20% of cycle OR coverage narrowed -> skip.
-- Idempotent: per-invoice AND per-cycle (unique_violation -> already_processed).
create or replace function public.bl_eval_make_good_for_agent(
  p_agent uuid, p_trigger_invoice text, p_period_start timestamptz, p_period_end timestamptz)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  ag record; v_interval interval; cyc_start timestamptz; cyc_end timestamptz; cyc_secs numeric;
  tier_key text; tier_target int; eff_target int; enabled_days int;
  delivered int; floor_pct numeric; rate_cents int; self_pct numeric;
  paused_secs numeric; paused_frac numeric; narrowed boolean;
  shortfall int; amount int; v_status text; v_reason text;
begin
  select id, first_drop_at, tier, stripe_customer_id, agent_tz, drop_days into ag
    from public.agent_profiles where id = p_agent;
  if not found then return jsonb_build_object('evaluated', false, 'reason','no_agent'); end if;
  v_interval := p_period_end - p_period_start;
  cyc_end := p_period_start;
  cyc_start := greatest(p_period_start - v_interval, coalesce(ag.first_drop_at, p_period_start));
  if cyc_end <= cyc_start then
    return jsonb_build_object('evaluated', true, 'claimed', false, 'credit', false, 'status','no_prior_cycle'); end if;
  cyc_secs := extract(epoch from (cyc_end - cyc_start));
  floor_pct  := coalesce(nullif(public.bl_cfg('make_good_floor_pct'),'')::numeric, 0.80);
  rate_cents := coalesce(nullif(public.bl_cfg('per_lead_rate_cents'),'')::int, 5000);
  self_pct   := coalesce(nullif(public.bl_cfg('make_good_self_limit_pause_pct'),'')::numeric, 0.20);
  select count(*) into enabled_days
    from generate_series(cyc_start, cyc_end - interval '1 microsecond', interval '1 day') as gd(d)
    where extract(isodow from (gd.d at time zone coalesce(ag.agent_tz,'America/Chicago')))::int = any(coalesce(ag.drop_days, '{}'::int[]));
  tier_key    := lower(regexp_replace(coalesce(ag.tier,'Silver'),'[^a-zA-Z]','','g'));
  tier_target := coalesce(nullif(public.bl_cfg('make_good_target_' || tier_key),'')::int, 0);
  eff_target  := round(tier_target * (enabled_days / 7.0))::int;
  if eff_target < 1 then
    return jsonb_build_object('evaluated', true, 'claimed', false, 'credit', false, 'status','no_target', 'enabled_days', enabled_days); end if;
  select count(*) into delivered from public.leads
    where assigned_agent_id = ag.id and assigned_at >= cyc_start and assigned_at < cyc_end;
  paused_secs := public.bl_make_good_paused_seconds(ag.id, cyc_start, cyc_end);
  paused_frac := case when cyc_secs > 0 then paused_secs / cyc_secs else 0 end;
  narrowed := exists (select 1 from public.coverage_reduction_log where agent_id = ag.id and changed_at >= cyc_start and changed_at < cyc_end);
  if delivered >= floor_pct * eff_target then
    v_status := 'above_floor'; amount := 0; shortfall := greatest(0, eff_target - delivered);
    v_reason := delivered || ' delivered vs target ' || eff_target || ' (at/above ' || round(floor_pct*100) || '% floor)';
  elsif paused_frac >= self_pct or narrowed then
    v_status := 'skipped_self_limit'; amount := 0; shortfall := greatest(0, eff_target - delivered);
    v_reason := 'self-limited: paused ' || round(paused_frac*100) || '% of cycle'
                || case when narrowed then ', narrowed coverage mid-cycle' else '' end
                || ' (delivered ' || delivered || ' of ' || eff_target || ')';
  else
    shortfall := eff_target - delivered; amount := shortfall * rate_cents; v_status := 'credited';
    v_reason := shortfall || ' short of target ' || eff_target || ' (delivered ' || delivered || ', ' || enabled_days || ' scheduled days)';
  end if;
  begin
    insert into public.make_good_ledger(agent_id, trigger_invoice, period_start, period_end, target,
      billable_delivered, shortfall, amount_cents, paused_pct, narrowed, status, reason)
    values (ag.id, p_trigger_invoice, cyc_start, cyc_end, eff_target, delivered,
      shortfall, amount, round(paused_frac*100)::int, narrowed, v_status, v_reason);
  exception when unique_violation then
    return jsonb_build_object('evaluated', true, 'claimed', false, 'credit', false, 'status','already_processed');
  end;
  return jsonb_build_object('evaluated', true, 'claimed', true, 'credit', (amount > 0),
    'amount_cents', amount, 'customer', ag.stripe_customer_id, 'status', v_status,
    'shortfall', shortfall, 'target', eff_target, 'delivered', delivered, 'period_start', cyc_start, 'period_end', cyc_end);
end; $$;
revoke all on function public.bl_eval_make_good_for_agent(uuid, text, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.bl_eval_make_good_for_agent(uuid, text, timestamptz, timestamptz) to service_role;

-- webhook entry: resolve agent by Stripe customer, delegate to the core.
create or replace function public.bl_eval_make_good(
  p_customer text, p_trigger_invoice text, p_period_start timestamptz, p_period_end timestamptz)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_agent uuid;
begin
  select id into v_agent from public.agent_profiles where stripe_customer_id = p_customer
    order by first_drop_at desc nulls last limit 1;
  if v_agent is null then return jsonb_build_object('evaluated', false, 'reason','no_agent_for_customer'); end if;
  return public.bl_eval_make_good_for_agent(v_agent, p_trigger_invoice, p_period_start, p_period_end);
end; $$;
revoke all on function public.bl_eval_make_good(text, text, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.bl_eval_make_good(text, text, timestamptz, timestamptz) to service_role;

create or replace function public.bl_make_good_mark_paid(p_trigger_invoice text, p_ref text)
returns void language sql security definer set search_path to 'public' as $$
  update public.make_good_ledger set stripe_ref = p_ref where trigger_invoice = p_trigger_invoice;
$$;
revoke all on function public.bl_make_good_mark_paid(text, text) from public, anon, authenticated;
grant execute on function public.bl_make_good_mark_paid(text, text) to service_role;

-- agent reads their own short-week credits (portal transparency).
create or replace function public.bl_my_make_good()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not authenticated'; end if;
  return jsonb_build_object(
    'total_credited_cents', coalesce((select sum(amount_cents) from public.make_good_ledger where agent_id = uid and status = 'credited'), 0),
    'rows', coalesce((select jsonb_agg(r) from (
        select period_start, period_end, target, billable_delivered, shortfall, amount_cents, status, reason, created_at
        from public.make_good_ledger where agent_id = uid order by created_at desc limit 12) r), '[]'::jsonb));
end; $$;
revoke all on function public.bl_my_make_good() from public, anon;
grant execute on function public.bl_my_make_good() to authenticated;

-- owner command-center make-good cost panel.
create or replace function public.bl_owner_make_good()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.bl_is_owner() then raise exception 'not authorized'; end if;
  return jsonb_build_object(
    'credited_cents_90d', coalesce((select sum(amount_cents) from public.make_good_ledger where status='credited' and created_at > now() - interval '90 days'), 0),
    'credited_count_90d', (select count(*) from public.make_good_ledger where status='credited' and created_at > now() - interval '90 days'),
    'skipped_self_limit_90d', (select count(*) from public.make_good_ledger where status='skipped_self_limit' and created_at > now() - interval '90 days'),
    'recent', coalesce((select jsonb_agg(r) from (
        select agent_id, period_start, period_end, target, billable_delivered, shortfall, amount_cents, paused_pct, narrowed, status, reason, created_at
        from public.make_good_ledger order by created_at desc limit 25) r), '[]'::jsonb));
end; $$;
revoke all on function public.bl_owner_make_good() from public, anon;
grant execute on function public.bl_owner_make_good() to authenticated, service_role;
