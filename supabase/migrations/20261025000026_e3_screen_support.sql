-- 0026 What the phase 2 screens (E3) need from the API
--
-- api.appointment_type_version was created in 0012 as `select *`, which fixed its column
-- list before 0014 added the proposal and decision columns (D-011). It is restated so
-- screens can tell a proposed version from an approved one, and who decided it.
-- api.am_platform_admin() lets the app show the operations page to platform
-- administrators; it says only whether the caller is one, and grants nothing (invariant 9).
-- api.invitation gains acceptance_details (what the accepting organisation entered), so the
-- administrator resolving a duplicate company number can compare names (Q26). The table
-- grant already allowed it; the view's column list had left it out. The token hash stays hidden.
-- api.verify_competency is restated to explain, in words, why a confirmed check needs a
-- matching holder (the table already refuses it); nothing else changes.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

create or replace view api.appointment_type_version with (security_invoker = true) as
  select * from core.appointment_type_version;

create or replace view api.invitation with (security_invoker = true) as
  select id, customer_id, kind, venue_id, capacity_code, engagement_valid_from, engagement_valid_to, organisation_id,
         relationship_kind, invitee_given_name, invitee_family_name, invitee_email, owner_person_id,
         invited_by_person_id, expires_at, status, delivery_failed_at, delivery_failure_detail, accepted_by_user_id,
         accepted_at, match_organisation_id, resolution, result_organisation_id, result_person_id,
         result_engagement_id, row_version, created_at, acceptance_details
    from core.invitation;   -- the token hash is never exposed

create function api.am_platform_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select authz.is_platform_admin() $$;

grant execute on function api.am_platform_admin() to authenticated;
revoke execute on function api.am_platform_admin() from anon, public;

create or replace function api.verify_competency(
  p_idempotency_key text, p_competency_id uuid, p_method text, p_source_checked text, p_holder_match boolean,
  p_scope text, p_valid_until date, p_outcome text, p_notes text default null,
  p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  c    core.competency;
  v    jsonb;
begin
  select * into c from core.competency where id = p_competency_id;
  -- The table's check refuses this too; say why in words a verifier understands.
  if p_outcome = 'verified' and not coalesce(p_holder_match, false) then
    raise exception 'a check can be recorded as confirmed only when the card or certificate holder matches the person'
      using errcode = '22023';
  end if;
  v := authz.require('competency.verify',
         jsonb_build_object('customer_id', c.customer_id, 'venue_id', c.venue_id, 'record_id', v_id,
                            'target_type', 'competency_verification',
                            'excluded_person_ids', jsonb_build_array(c.person_id, c.declared_by_person_id)
                                                   || core.organisation_people(c.declared_via_organisation_id)),
         p_idempotency_key,
         jsonb_build_object('competency_id', p_competency_id, 'method', p_method, 'source_checked', p_source_checked,
                            'holder_match', p_holder_match, 'scope', p_scope, 'valid_until', p_valid_until,
                            'outcome', p_outcome, 'notes', p_notes),
         p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.competency_verification (id, customer_id, venue_id, competency_id, verifier_person_id,
                                            decision_context_id, method, source_checked, holder_match, scope,
                                            valid_until, outcome, notes)
  values (v_id, c.customer_id, c.venue_id, p_competency_id, (v ->> 'actor_person_id')::uuid,
          (v ->> 'decision_context_id')::uuid, p_method, p_source_checked, p_holder_match, p_scope, p_valid_until,
          p_outcome, p_notes);
  return v;
end $$;
