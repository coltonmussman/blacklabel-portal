-- ============================================================================
-- THE HANDSHAKE (Phase 2) — canonical source-of-record (final, post-review state)
-- Applied 2026-06-23 via migrations:
--   handshake_p2_cols_and_config (20260623020006)
--   handshake_p2_storage_bucket  (20260623020019)
--   handshake_p2_rpcs_and_gate   (20260623020200)
--   handshake_p2_notify_trigger  (20260623020734)
--   handshake_p2_advisor_hardening (20260623021244)
--   handshake_p2_review_fixes    (20260623023938)
--
-- WHAT IT DOES: the moment a lead is assigned to one exclusive agent, NCG sends the CONSUMER a
-- welcome introducing that agent with a generated NCG-branded business card (email now / MMS later).
-- An agent must finish their card (headshot + call-from number) BEFORE receiving leads — this REUSES
-- the existing setup_complete gate (routing functions auto_assign_lead / bl_drain_vault_for_agent are
-- UNCHANGED). Messaging is DORMANT until bl_config.handshake_send_enabled='true' AND the channel
-- secrets exist. Stripe + lead-capture/consent/TrustedForm untouched.
-- ============================================================================

-- ---- 1. additive columns + dormant config -------------------------------------------------
alter table public.agent_profiles
  add column if not exists headshot_url     text,
  add column if not exists dial_number      text,
  add column if not exists display_title    text,   -- card DISPLAY NAME override (NOT a title)
  add column if not exists agent_card_title text,    -- the job title shown on the card
  add column if not exists intro_line       text,
  add column if not exists card_status      text not null default 'pending',  -- pending|active|rejected
  add column if not exists card_image_url   text;    -- rasterized card PNG, used for MMS media only

comment on column public.agent_profiles.display_title is 'Handshake: the agent card DISPLAY NAME override (NOT a job title); defaults to first+last. The job title lives in agent_card_title.';

alter table public.leads
  add column if not exists handshake_sent_at timestamptz;  -- idempotency stamp (at most one Handshake/lead)

insert into public.bl_config (key, value) values
  ('handshake_send_enabled','false'),   -- MASTER kill switch. Flip to 'true' at go-live.
  ('handshake_email_enabled','true'),
  ('handshake_sms_enabled','true'),
  ('handshake_from_email','National Coverage Group <hello@nationalcoveragegroup.com>')
on conflict (key) do nothing;

-- ---- 2. public storage bucket for headshots + rasterized cards ----------------------------
-- Public read is served by the public object endpoint (no RLS needed); writes are owner-folder only.
-- NOTE: no broad SELECT/listing policy (advisor: public_bucket_allows_listing) and no DELETE policy
-- (re-upload writes a new timestamped object; DELETE let an agent orphan their headshot post-gate).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('agent-assets','agent-assets', true, 5242880, array['image/png','image/jpeg','image/jpg','image/webp'])
on conflict (id) do nothing;

drop policy if exists "agent_assets_owner_insert" on storage.objects;
create policy "agent_assets_owner_insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'agent-assets' and (storage.foldername(name))[1] = (select auth.uid())::text);

drop policy if exists "agent_assets_owner_update" on storage.objects;
create policy "agent_assets_owner_update" on storage.objects
  for update to authenticated
  using (bucket_id = 'agent-assets' and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'agent-assets' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- ---- 3. card-save RPC (only write path for the card cols) ---------------------------------
create or replace function public.bl_save_agent_card(
  p_headshot_url text, p_dial_number text, p_agent_card_title text default null,
  p_display_name text default null, p_intro_line text default null, p_card_image_url text default null
) returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare
  uid uuid := (select auth.uid());
  v_pfx text; v_head text; v_cardi text; v_dig text; v_dial text; v_title text; v_name text; v_intro text; v_status text;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  v_pfx := 'https://hqiyxeriugywlkbcuasu.supabase.co/storage/v1/object/public/agent-assets/' || uid::text || '/';
  v_head  := nullif(btrim(coalesce(p_headshot_url,'')), '');
  v_cardi := nullif(btrim(coalesce(p_card_image_url,'')), '');
  -- an agent can only point the card at images in their OWN storage folder
  if v_head  is not null and v_head  not like v_pfx || '%' then raise exception 'Headshot must be uploaded to your own account.' using errcode='22023'; end if;
  if v_cardi is not null and v_cardi not like v_pfx || '%' then raise exception 'Card image must be generated from your own account.' using errcode='22023'; end if;
  v_dig := regexp_replace(coalesce(p_dial_number,''), '\D', '', 'g');
  if length(v_dig) = 11 and left(v_dig,1) = '1' then v_dig := substr(v_dig,2); end if;
  if length(v_dig) <> 10 then raise exception 'A valid 10-digit call-from number is required.' using errcode='22023'; end if;
  v_dial := substr(v_dig,1,3) || '-' || substr(v_dig,4,3) || '-' || substr(v_dig,7,4);
  v_title := nullif(btrim(coalesce(p_agent_card_title,'')), ''); if v_title is null then v_title := 'Licensed Insurance Agent'; end if; v_title := left(v_title, 48);
  v_name  := nullif(btrim(coalesce(p_display_name,'')), ''); if v_name is not null then v_name := left(v_name, 60); end if;
  v_intro := nullif(btrim(coalesce(p_intro_line,'')), ''); if v_intro is not null then v_intro := left(v_intro, 160); end if;
  v_status := case when v_head is not null then 'active' else 'pending' end;
  update public.agent_profiles set
    headshot_url=v_head, dial_number=v_dial, agent_card_title=v_title, display_title=v_name,
    intro_line=v_intro, card_image_url=v_cardi, card_status=v_status
  where id = uid;
  return jsonb_build_object('ok', true, 'card_status', v_status, 'dial_number', v_dial, 'agent_card_title', v_title);
end;
$function$;

-- ---- 4. idempotent consumer-send claim (service_role only) --------------------------------
create or replace function public.bl_claim_handshake(p_lead_id uuid)
returns boolean language plpgsql security definer set search_path to 'public'
as $function$
declare ok boolean;
begin
  update public.leads set handshake_sent_at = now()
   where id = p_lead_id and handshake_sent_at is null and assigned_agent_id is not null
  returning true into ok;
  return coalesce(ok, false);
end;
$function$;

-- ---- 5. fold the mandatory card into the EXISTING setup_complete gate ----------------------
create or replace function public.bl_finish_setup()
returns integer language plpgsql security definer set search_path to 'public'
as $function$
declare uid uuid := auth.uid(); n int; v_head text; v_dial text;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  select btrim(coalesce(headshot_url,'')), btrim(coalesce(dial_number,'')) into v_head, v_dial
    from public.agent_profiles where id = uid;
  if coalesce(v_head,'') = '' or coalesce(v_dial,'') = '' then
    raise exception 'Your agent card must be finished (headshot + call-from number) before setup can complete.' using errcode='22023';
  end if;
  update public.agent_profiles set setup_complete = true, setup_step = 6 where id = uid;
  n := public.bl_drain_vault_for_agent(uid);
  return coalesce(n,0);
end;
$function$;

-- close the gate bypass: setup_complete is settable ONLY via bl_finish_setup (which requires the card)
revoke update (setup_complete) on public.agent_profiles from authenticated;

-- grants (locked pattern)
revoke all on function public.bl_save_agent_card(text,text,text,text,text,text) from public, anon;
grant execute on function public.bl_save_agent_card(text,text,text,text,text,text) to authenticated;
revoke all on function public.bl_claim_handshake(uuid) from public, anon, authenticated;
grant execute on function public.bl_claim_handshake(uuid) to service_role;

-- ---- 6. consumer-notify trigger (additive; routing untouched) -----------------------------
-- Fires on a FRESH assignment (insert-time route/founder-fallback OR vault-drain null->agent).
-- Gated on the master flag so DORMANT = zero outbound calls. The edge fn re-checks everything.
create or replace function public.bl_notify_consumer_after_assign()
returns trigger language plpgsql security definer set search_path to 'public'
as $function$
begin
  if new.assigned_agent_id is null then return null; end if;
  if tg_op = 'UPDATE' and old.assigned_agent_id is not null then return null; end if;  -- fresh only
  if coalesce(public.bl_cfg('handshake_send_enabled'),'false') <> 'true' then return null; end if;  -- dormant
  begin
    perform net.http_post(
      url := 'https://hqiyxeriugywlkbcuasu.supabase.co/functions/v1/notify-consumer',
      headers := jsonb_build_object('Content-Type','application/json'),
      body := jsonb_build_object('lead_id', new.id)
    );
  exception when others then null;  -- fail-open
  end;
  return null;
end;
$function$;
revoke all on function public.bl_notify_consumer_after_assign() from public, anon, authenticated;

drop trigger if exists trg_notify_consumer_after_assign on public.leads;
create trigger trg_notify_consumer_after_assign
  after insert or update of assigned_agent_id on public.leads
  for each row execute function public.bl_notify_consumer_after_assign();

-- ============================================================================
-- Edge function source of record: supabase/functions/notify-consumer/index.ts (v2).
-- Required edge secrets at go-live: RESEND_API_KEY (email), TWILIO_ACCOUNT_SID/TWILIO_AUTH_TOKEN/
-- TWILIO_MESSAGING_SERVICE_SID (or TWILIO_FROM_NUMBER) (MMS). Optional HANDSHAKE_FROM_EMAIL.
-- Go-live switch: update public.bl_config set value='true' where key='handshake_send_enabled';
-- ============================================================================
