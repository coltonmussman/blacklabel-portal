-- migration: lead_notes_feature  (applied 2026-06-22, project hqiyxeriugywlkbcuasu)
-- Per-lead timestamped notes log for the agent portal (My Leads).
-- Additive + locked: new table (RLS on, NO client policies) + SECURITY DEFINER RPCs.
-- Access only via the RPCs below (ownership re-checked server-side) + service_role.
-- The 4th RPC (bl_lead_note_counts) is an add beyond the original build brief: it powers
-- the per-lead notes count badge in a single round trip (language sql to avoid the
-- plpgsql RETURNS TABLE column-name ambiguity).

create table if not exists public.lead_notes (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null references public.leads(id) on delete cascade,
  agent_id uuid not null references public.agent_profiles(id) on delete cascade,
  body text not null,
  created_at timestamptz not null default now(),
  constraint lead_notes_body_len check (char_length(btrim(body)) between 1 and 5000)
);
create index if not exists idx_lead_notes_lead on public.lead_notes(lead_id);
create index if not exists idx_lead_notes_agent on public.lead_notes(agent_id);

alter table public.lead_notes enable row level security;
-- locked: no client policies; access only via the SECURITY DEFINER RPCs below + service_role
revoke all on public.lead_notes from anon, authenticated;

create or replace function public.bl_add_lead_note(p_lead_id uuid, p_body text)
returns public.lead_notes
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_agent uuid := auth.uid(); v_row public.lead_notes;
begin
  if v_agent is null then raise exception 'not authenticated'; end if;
  if not exists (select 1 from public.leads l where l.id = p_lead_id and l.assigned_agent_id = v_agent) then
    raise exception 'lead not found or not yours';
  end if;
  if p_body is null or char_length(btrim(p_body)) = 0 then raise exception 'note is empty'; end if;
  insert into public.lead_notes (lead_id, agent_id, body)
  values (p_lead_id, v_agent, btrim(p_body)) returning * into v_row;
  return v_row;
end; $$;

create or replace function public.bl_list_lead_notes(p_lead_id uuid)
returns setof public.lead_notes
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_agent uuid := auth.uid();
begin
  if v_agent is null then raise exception 'not authenticated'; end if;
  if not exists (select 1 from public.leads l where l.id = p_lead_id and l.assigned_agent_id = v_agent) then
    raise exception 'lead not found or not yours';
  end if;
  return query select * from public.lead_notes
    where lead_id = p_lead_id and agent_id = v_agent order by created_at desc;
end; $$;

create or replace function public.bl_delete_lead_note(p_note_id uuid)
returns boolean
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_agent uuid := auth.uid();
begin
  if v_agent is null then raise exception 'not authenticated'; end if;
  delete from public.lead_notes where id = p_note_id and agent_id = v_agent;
  return found;
end; $$;

-- counts for the agent's own leads (powers the notes badge in one round trip).
-- auth.uid() evaluated once (single SELECT, Supabase best practice) + explicit null guard.
-- (updated by migration lead_note_counts_single_uid)
create or replace function public.bl_lead_note_counts()
returns table(lead_id uuid, n bigint)
language sql security definer set search_path = public, pg_temp
as $$
  with me as (select auth.uid() as uid)
  select ln.lead_id, count(*)::bigint
  from public.lead_notes ln
  join public.leads l on l.id = ln.lead_id
  join me on l.assigned_agent_id = me.uid and ln.agent_id = me.uid
  where me.uid is not null
  group by ln.lead_id;
$$;

revoke all on function public.bl_add_lead_note(uuid, text) from public, anon;
revoke all on function public.bl_list_lead_notes(uuid) from public, anon;
revoke all on function public.bl_delete_lead_note(uuid) from public, anon;
revoke all on function public.bl_lead_note_counts() from public, anon;
grant execute on function public.bl_add_lead_note(uuid, text) to authenticated;
grant execute on function public.bl_list_lead_notes(uuid) to authenticated;
grant execute on function public.bl_delete_lead_note(uuid) to authenticated;
grant execute on function public.bl_lead_note_counts() to authenticated;
