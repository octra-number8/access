-- 0049 Reads for the gate and visit screens (phase 7c, D-020)
--
-- Two read functions, no new tables or actions:
--   api.access_consents_needed: the occupier consents a visit is waiting for. The occupier's
--     name is shown only to the venue's side (administrators and appointees); the visiting
--     organisation sees the area and its state, never who occupies it (P5-6).
--   api.gate_override_holders: who can set aside a refusal at a gate point, by name only, so
--     the operator knows whom to call (§11). It notifies nobody.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only (drop the functions).

create function api.access_consents_needed(p_authorisation_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare a core.access_authorisation; venue_side boolean;
begin
  select * into a from core.access_authorisation where id = p_authorisation_id and id in (select authz.visible_access_ids());
  if a.id is null then return '[]'; end if;
  venue_side := a.customer_id in (select authz.my_admin_customer_ids()) or a.venue_id in (select authz.my_appointee_venue_ids());
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'area_id', n.area_id, 'area', ar.name,
            'organisation_id', case when venue_side then n.organisation_id end,
            'organisation', case when venue_side then o.legal_name end,
            'state', case when n.refused then 'refused' when n.given then 'given' else 'waiting' end) order by ar.name), '[]')
            from core.consents_needed(a.id) n join core.area ar on ar.id = n.area_id join core.organisation o on o.id = n.organisation_id);
end $$;

create function api.gate_override_holders(p_gate_point_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare gp core.gate_point;
begin
  select * into gp from core.gate_point where id = p_gate_point_id;
  if gp.id is null or not (gp.customer_id in (select authz.my_admin_customer_ids())
                           or gp.venue_id in (select authz.my_action_venue_ids('gate.operate'))
                           or gp.venue_id in (select authz.my_action_venue_ids('gate.override'))) then
    return '[]';
  end if;
  return (select coalesce(jsonb_agg(distinct core.person_name(a.appointee_person_id)), '[]')
            from core.appointment a
           where a.venue_id = gp.venue_id and a.status = 'in_force' and now() <@ a.valid_during
             and not authz.person_restricted(a.appointee_person_id, gp.venue_id)
             and jsonb_array_length(authz.capacities('gate.override', core.gate_target(gp, gen_random_uuid(), 'entry_override'), a.appointee_person_id)) > 0);
end $$;

grant execute on function api.access_consents_needed(uuid), api.gate_override_holders(uuid) to authenticated;
revoke execute on function api.access_consents_needed(uuid), api.gate_override_holders(uuid) from anon, public;
