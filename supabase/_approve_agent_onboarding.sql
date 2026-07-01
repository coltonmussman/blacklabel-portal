-- ============================================================================
-- APPROVE -> INVITE agent onboarding  (source-of-record for migration
-- `approve_agent_onboarding`, applied 2026-07-01)
--
-- Lets the owner approve a waitlist applicant with one click. The approve-agent
-- edge function creates the agent's auth account FROM this waitlist row using the
-- EXACT application email, so handle_new_user copies their name + NPN into
-- agent_profiles automatically. `approved_at` drops the applicant off the pending
-- list once handled. Pairs with: supabase/functions/approve-agent/index.ts.
-- ============================================================================

alter table public.agent_waitlist add column if not exists approved_at timestamptz;

-- Owner-only list of applicants still awaiting an account (not approved, no auth
-- user yet). Mirrors the bl_is_owner() gate used by every other bl_owner_* RPC.
create or replace function public.bl_owner_list_applicants()
returns table (
  id uuid, first_name text, last_name text, email text, npn text,
  phone text, states_licensed text, verticals text, created_at timestamptz
)
language plpgsql stable security definer set search_path to 'public'
as $$
begin
  if not public.bl_is_owner() then raise exception 'owner only'; end if;
  return query
    select w.id, w.first_name, w.last_name, w.email, w.npn, w.phone, w.states_licensed, w.verticals, w.created_at
    from public.agent_waitlist w
    where w.approved_at is null
      and not exists (select 1 from auth.users u where lower(u.email) = lower(w.email))
    order by w.created_at desc;
end;
$$;

revoke all on function public.bl_owner_list_applicants() from public, anon;
grant execute on function public.bl_owner_list_applicants() to authenticated;
