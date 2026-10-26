-- 0048 Access visits API (phase 7b, D-020)
--
-- Same pattern as before. A visit is approved by an access authority covering every area it
-- names, never anyone connected with the requesting organisation, and only once any occupier
-- consent the purpose needs is given. An approved visit naming a person is a reason for them
-- to enter during it (Q125); the gate records their arrivals and departures against it.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

-- ---------------------------------------------------------------------------
-- Venue configuration documents
-- ---------------------------------------------------------------------------
create function api.create_venue_config_draft(p_idempotency_key text, p_venue_id uuid, p_kind text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare vn core.venue; v_id uuid := gen_random_uuid(); prev core.venue_config_version; t jsonb; r jsonb; v jsonb;
begin
  select * into vn from core.venue where id = p_venue_id;
  t := jsonb_build_object('customer_id', vn.customer_id, 'venue_id', vn.id, 'record_id', v_id, 'target_type', 'venue_config_version');
  r := jsonb_build_object('venue_id', p_venue_id, 'kind', p_kind);
  v := core.authorised_or_refusal('venue_config.draft', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if coalesce(p_kind, '') not in ('access_purposes') then
    return core.refuse('venue_config.draft', 'invalid_content', 'Unknown kind of configuration.', 'A known kind', 'You');
  end if;
  if exists (select 1 from core.venue_config_version where venue_id = vn.id and kind = p_kind and status in ('draft', 'proposed')) then
    return core.refuse('venue_config.draft', 'in_progress', 'A version is already in progress: finish or reject it first.', 'No version in progress', 'You');
  end if;
  v := authz.require('venue_config.draft', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  select * into prev from core.venue_config_version where venue_id = vn.id and kind = p_kind order by version_no desc limit 1;
  insert into core.venue_config_version (id, customer_id, venue_id, kind, version_no, status, content, authored_by_person_id)
  values (v_id, vn.customer_id, vn.id, p_kind, coalesce(prev.version_no, 0) + 1, 'draft', coalesce(prev.content, '{"purposes": []}'), (v ->> 'actor_person_id')::uuid);
  return v || jsonb_build_object('id', v_id);
end $$;

create function api.save_venue_config_draft(p_idempotency_key text, p_version_id uuid, p_expected_version integer, p_content jsonb, p_source_ref text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c core.venue_config_version; t jsonb; r jsonb; v jsonb; problems text[];
begin
  select * into c from core.venue_config_version where id = p_version_id;
  t := jsonb_build_object('customer_id', c.customer_id, 'venue_id', c.venue_id, 'record_id', p_version_id, 'target_type', 'venue_config_version');
  r := jsonb_build_object('version_id', p_version_id, 'expected_version', p_expected_version, 'content', p_content, 'source', p_source_ref);
  v := core.authorised_or_refusal('venue_config.save_draft', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if c.status <> 'draft' then
    return core.refuse('venue_config.save_draft', 'not_draft', 'Only a draft can be changed.', 'A draft', 'You, by starting a new version');
  end if;
  problems := core.validate_venue_config(c.venue_id, c.kind, coalesce(p_content, '{}'), false);
  if cardinality(problems) > 0 then
    return core.refuse('venue_config.save_draft', 'invalid_content', 'The configuration has problems.', 'Each item listed', 'You',
                       jsonb_build_object('problems', to_jsonb(problems)));
  end if;
  v := authz.require('venue_config.save_draft', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  if c.row_version <> p_expected_version then raise exception 'this configuration changed since you opened it' using errcode = 'PT409'; end if;
  update core.venue_config_version set content = p_content, source_ref = p_source_ref where id = c.id;
  return v;
end $$;

create function api.propose_venue_config(p_idempotency_key text, p_version_id uuid, p_expected_version integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c core.venue_config_version; t jsonb; r jsonb; v jsonb; problems text[];
begin
  select * into c from core.venue_config_version where id = p_version_id;
  t := jsonb_build_object('customer_id', c.customer_id, 'venue_id', c.venue_id, 'record_id', p_version_id, 'target_type', 'venue_config_version');
  r := jsonb_build_object('version_id', p_version_id, 'expected_version', p_expected_version);
  v := core.authorised_or_refusal('venue_config.propose', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  problems := core.validate_venue_config(c.venue_id, c.kind, c.content, true);
  if c.status <> 'draft' then problems := problems || text 'Only a draft can be proposed.'; end if;
  if cardinality(problems) > 0 then
    return core.refuse('venue_config.propose', 'not_ready', 'This configuration is not ready for approval.', 'Each item listed', 'You',
                       jsonb_build_object('problems', to_jsonb(problems)));
  end if;
  v := authz.require('venue_config.propose', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.venue_config_version', c.id, 'proposed', p_expected_version, (v ->> 'decision_context_id')::uuid,
    jsonb_build_object('proposed_by_person_id', v ->> 'actor_person_id', 'content_sha256', encode(sha256(convert_to(c.content::text, 'UTF8')), 'hex')));
  return v;
end $$;

create function api.decide_venue_config(p_idempotency_key text, p_version_id uuid, p_expected_version integer, p_decision text, p_reason text,
                                        p_acting_appointment_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c core.venue_config_version; prev uuid; ctx uuid; t jsonb; r jsonb; v jsonb; v_action text;
begin
  select * into c from core.venue_config_version where id = p_version_id;
  v_action := case when p_decision = 'reject' then 'venue_config.reject' else 'venue_config.approve' end;
  t := jsonb_build_object('customer_id', c.customer_id, 'venue_id', c.venue_id, 'record_id', p_version_id, 'target_type', 'venue_config_version',
                          'excluded_person_ids', jsonb_build_array(c.authored_by_person_id, c.proposed_by_person_id));
  r := jsonb_build_object('version_id', p_version_id, 'expected_version', p_expected_version, 'decision', p_decision, 'reason', p_reason);
  v := core.authorised_or_refusal(v_action, t, p_idempotency_key, r, p_acting_appointment_id);
  if v is not null then return v; end if;
  if c.status <> 'proposed' or coalesce(p_decision, '') not in ('approve', 'reject') or core.blank(p_reason) then
    return core.refuse(v_action, 'invalid_content', 'Approve or reject a proposed version, with a reason.', 'A proposed version and a reason', 'You');
  end if;
  v := authz.require(v_action, t, p_idempotency_key, r, p_acting_appointment_id, null);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ctx := (v ->> 'decision_context_id')::uuid;
  if p_decision = 'approve' then
    select id into prev from core.venue_config_version where venue_id = c.venue_id and kind = c.kind and status = 'approved';
    if prev is not null then
      perform authz.derive('venue_config.supersede', 'venue_config_version', prev);
      perform core.transition('core.venue_config_version', prev, 'superseded', (select row_version from core.venue_config_version where id = prev),
                              core.ctx_uuid('decision_context_id'));
      perform authz.resume(ctx);
    end if;
  end if;
  perform core.transition('core.venue_config_version', c.id, case p_decision when 'approve' then 'approved' else 'rejected' end, p_expected_version, ctx,
    jsonb_build_object('decided_by_person_id', v ->> 'actor_person_id', 'decided_at', clock_timestamp(), 'decision_reason', p_reason));
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Visits
-- ---------------------------------------------------------------------------
create function core.access_target(a core.access_authorisation, p_record_id uuid, p_excluded jsonb default '[]') returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('customer_id', a.customer_id, 'venue_id', a.venue_id, 'record_id', p_record_id, 'target_type', 'access_authorisation',
                            'organisation_id', a.organisation_id, 'area_id', a.area_ids[1], 'area_ids', to_jsonb(a.area_ids),
                            'excluded_person_ids', p_excluded) $$;

-- Everyone working with the requesting organisation, and whoever asked: they cannot decide it.
create function core.access_people(a core.access_authorisation) returns jsonb
language sql stable security definer set search_path = '' as $$
  select core.organisation_people(a.organisation_id) || jsonb_build_array(a.requested_by_person_id) $$;

create function api.request_access(p_idempotency_key text, p_venue_id uuid, p_organisation_id uuid, p_purpose_key text, p_description text,
                                   p_area_ids uuid[], p_from timestamptz, p_to timestamptz, p_person_ids uuid[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  vn core.venue; cfg core.venue_config_version; eng core.engagement; v_action text; t jsonb; r jsonb; v jsonb; ctx uuid;
  a_id uuid := gen_random_uuid(); problems text[] := '{}'; x uuid;
begin
  select * into vn from core.venue where id = p_venue_id;
  v_action := case when p_organisation_id in (select authz.my_admin_organisation_ids()) then 'access.request'
                   when vn.customer_id in (select authz.my_admin_customer_ids()) then 'access.request_for_venue' else 'access.request' end;
  t := jsonb_build_object('customer_id', vn.customer_id, 'venue_id', vn.id, 'record_id', a_id, 'target_type', 'access_authorisation',
                          'organisation_id', p_organisation_id);
  r := jsonb_build_object('venue_id', p_venue_id, 'organisation_id', p_organisation_id, 'purpose', p_purpose_key, 'description', p_description,
                          'areas', to_jsonb(p_area_ids), 'from', p_from, 'to', p_to, 'people', to_jsonb(p_person_ids));
  v := core.authorised_or_refusal(v_action, t, p_idempotency_key, r);
  if v is not null then return v; end if;
  cfg := core.venue_config(vn.id, 'access_purposes');
  if cfg.id is null then
    return core.refuse(v_action, 'not_configured', 'The venue has not defined its access purposes (Q121), so visits cannot be requested yet.',
                       'The venue''s access purposes', 'The venue');
  end if;
  if not exists (select 1 from jsonb_array_elements(cfg.content -> 'purposes') pu where pu ->> 'key' = p_purpose_key) then
    problems := problems || text 'Choose one of the venue''s purposes.';
  end if;
  if p_from is null or p_to is null or p_to <= p_from then problems := problems || text 'Give the start and end of the visit or series.'; end if;
  select * into eng from core.engagement e where e.organisation_id = p_organisation_id and e.venue_id = vn.id and e.status = 'active'
     and (p_from is null or p_to is null or e.valid_during @> tstzrange(p_from, p_to)) order by e.created_at desc limit 1;
  if eng.id is null or authz.organisation_restricted(p_organisation_id, vn.id) then
    problems := problems || text 'The organisation needs an active, unrestricted engagement here covering the visit''s dates.';
  end if;
  if core.blank(p_description) then problems := problems || text 'Describe the visit.'; end if;
  if cardinality(coalesce(p_area_ids, '{}')) = 0 or exists (select 1 from unnest(p_area_ids) ar where not exists (select 1 from core.area where id = ar and venue_id = vn.id)) then
    problems := problems || text 'Name the areas at this venue.';
  end if;
  if cardinality(coalesce(p_person_ids, '{}')) = 0 or exists (select 1 from unnest(p_person_ids) pp where not exists (
       select 1 from core.person_organisation_relationship rr where rr.person_id = pp and rr.organisation_id = p_organisation_id and rr.status = 'active')) then
    problems := problems || text 'Name the people on the visit: each must currently work with the organisation (Q125).';
  end if;
  if cardinality(problems) > 0 then
    return core.refuse(v_action, 'invalid_content', 'The request has problems.', 'Each item listed', 'You', jsonb_build_object('problems', to_jsonb(problems)));
  end if;
  v := authz.require(v_action, t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ctx := (v ->> 'decision_context_id')::uuid;
  insert into core.access_authorisation (id, customer_id, venue_id, reference, organisation_id, engagement_id, purpose_config_id, purpose_key, description,
                                         area_ids, valid_during, status, requested_by_person_id)
  values (a_id, vn.customer_id, vn.id, 'AV-' || lpad(((select count(*) from core.access_authorisation where venue_id = vn.id) + 1)::text, 6, '0'),
          p_organisation_id, eng.id, cfg.id, p_purpose_key, p_description, p_area_ids, tstzrange(p_from, p_to), 'requested', (v ->> 'actor_person_id')::uuid);
  foreach x in array p_person_ids loop
    insert into core.access_roster_member (customer_id, venue_id, authorisation_id, person_id, added_by_person_id)
    values (vn.customer_id, vn.id, a_id, x, (v ->> 'actor_person_id')::uuid) on conflict do nothing;
  end loop;
  return v || jsonb_build_object('id', a_id);
end $$;

-- The occupier's consent for its area (Q123), where the purpose needs it.
create function api.consent_access(p_idempotency_key text, p_authorisation_id uuid, p_area_id uuid, p_organisation_id uuid, p_outcome text, p_reason text,
                                   p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare a core.access_authorisation; t jsonb; r jsonb; v jsonb;
begin
  select * into a from core.access_authorisation where id = p_authorisation_id;
  t := jsonb_build_object('customer_id', a.customer_id, 'venue_id', a.venue_id, 'record_id', a.id, 'target_type', 'access_authorisation',
                          'area_id', p_area_id, 'area_ids', jsonb_build_array(p_area_id), 'excluded_person_ids', core.access_people(a));
  r := jsonb_build_object('authorisation_id', p_authorisation_id, 'area_id', p_area_id, 'organisation_id', p_organisation_id, 'outcome', p_outcome, 'reason', p_reason);
  v := core.authorised_or_refusal('access.consent_occupier', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if a.status <> 'requested' or not exists (select 1 from core.consents_needed(a.id) n where n.area_id = p_area_id and n.organisation_id = p_organisation_id
                                              and not n.given and not n.refused) then
    return core.refuse('access.consent_occupier', 'not_needed', 'No consent is waiting for this area on this visit.', 'A consent waiting', 'Nobody');
  end if;
  if coalesce(p_outcome, '') not in ('given', 'refused') or core.blank(p_reason) then
    return core.refuse('access.consent_occupier', 'invalid_content', 'Give or refuse consent, with a reason.', 'A decision', 'You');
  end if;
  v := authz.require('access.consent_occupier', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.access_consent (customer_id, venue_id, authorisation_id, area_id, organisation_id, outcome, reason, decider_person_id, decision_context_id)
  values (a.customer_id, a.venue_id, a.id, p_area_id, p_organisation_id, p_outcome, p_reason, (v ->> 'actor_person_id')::uuid, (v ->> 'decision_context_id')::uuid);
  return v;
end $$;

-- Approval (Q123, Q124): an access authority covering every area, never anyone connected with
-- the organisation; only with every needed consent given; with the conditions it sets.
--   p_conditions: {escort: text | null, no_photography: bool, confidentiality: bool, other: text | null}
create function api.decide_access(p_idempotency_key text, p_authorisation_id uuid, p_expected_version integer, p_outcome text, p_reason text,
                                  p_conditions jsonb default '{}', p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare a core.access_authorisation; purpose jsonb; t jsonb; r jsonb; v jsonb; cond jsonb;
begin
  select * into a from core.access_authorisation where id = p_authorisation_id;
  t := core.access_target(a, a.id, core.access_people(a));
  r := jsonb_build_object('authorisation_id', p_authorisation_id, 'expected_version', p_expected_version, 'outcome', p_outcome, 'reason', p_reason, 'conditions', p_conditions);
  v := core.authorised_or_refusal('access.approve', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if a.status <> 'requested' then
    return core.refuse('access.approve', 'not_requested', 'Only a requested visit is decided.', 'A requested visit', 'Nobody');
  end if;
  if coalesce(p_outcome, '') not in ('approve', 'refuse') or core.blank(p_reason) then
    return core.refuse('access.approve', 'invalid_content', 'Approve or refuse, with a reason.', 'A decision', 'You');
  end if;
  purpose := core.visit_purpose(a);
  cond := jsonb_build_object('escort', nullif(btrim(coalesce(p_conditions ->> 'escort', '')), ''),
                             'no_photography', coalesce((p_conditions ->> 'no_photography')::boolean, false),
                             'confidentiality', coalesce((p_conditions ->> 'confidentiality')::boolean, false),
                             'other', nullif(btrim(coalesce(p_conditions ->> 'other', '')), ''));
  if p_outcome = 'approve' then
    if exists (select 1 from core.consents_needed(a.id) n where n.refused) then
      return core.refuse('access.approve', 'consent_refused', 'An occupier has refused consent for its area, so the visit cannot be approved as asked.',
                         'A visit without that area, or the occupier''s consent', 'The occupier');
    end if;
    if exists (select 1 from core.consents_needed(a.id) n where not n.given) then
      return core.refuse('access.approve', 'consent_pending', 'An occupier''s consent for its area is still waiting.', 'The occupier''s consent',
                         'The occupier''s representative for that area');
    end if;
    if purpose ->> 'escort' = 'always' and cond ->> 'escort' is null then
      return core.refuse('access.approve', 'escort_needed', 'This purpose is always escorted: name the escort or the role that escorts.', 'An escort', 'You');
    end if;
  end if;
  v := authz.require('access.approve', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.access_authorisation', a.id, case p_outcome when 'approve' then 'approved' else 'refused' end, p_expected_version,
    (v ->> 'decision_context_id')::uuid,
    jsonb_build_object('conditions', case when p_outcome = 'approve' then cond else '{}'::jsonb end,
                       'decided_by_person_id', v ->> 'actor_person_id', 'decision_reason', p_reason));
  return v;
end $$;

-- Roster changes (Q125): removals take effect at once; people added after approval are
-- approved like the original.
create function api.change_access_roster(p_idempotency_key text, p_authorisation_id uuid, p_add_person_ids uuid[], p_remove_member_ids uuid[], p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare a core.access_authorisation; v_action text; t jsonb; r jsonb; v jsonb; x uuid; actor uuid;
begin
  select * into a from core.access_authorisation where id = p_authorisation_id;
  v_action := case when a.organisation_id in (select authz.my_admin_organisation_ids()) then 'access.change_roster'
                   when a.customer_id in (select authz.my_admin_customer_ids()) then 'access.change_roster_for_venue' else 'access.change_roster' end;
  t := core.access_target(a, a.id);
  r := jsonb_build_object('authorisation_id', p_authorisation_id, 'add', to_jsonb(p_add_person_ids), 'remove', to_jsonb(p_remove_member_ids), 'reason', p_reason);
  v := core.authorised_or_refusal(v_action, t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if a.status not in ('requested', 'approved') or upper(a.valid_during) <= now() then
    return core.refuse(v_action, 'not_open', 'The roster changes only on a current visit.', 'A current visit', 'Nobody');
  end if;
  if core.blank(p_reason) or (cardinality(coalesce(p_add_person_ids, '{}')) + cardinality(coalesce(p_remove_member_ids, '{}'))) = 0
     or exists (select 1 from unnest(coalesce(p_add_person_ids, '{}')) pp where not exists (
          select 1 from core.person_organisation_relationship rr where rr.person_id = pp and rr.organisation_id = a.organisation_id and rr.status = 'active'))
     or exists (select 1 from unnest(coalesce(p_add_person_ids, '{}')) pp where exists (
          select 1 from core.access_roster_member m where m.authorisation_id = a.id and m.person_id = pp and m.removed_at is null))
     or exists (select 1 from unnest(coalesce(p_remove_member_ids, '{}')) mm where not exists (
          select 1 from core.access_roster_member m where m.id = mm and m.authorisation_id = a.id and m.removed_at is null)) then
    return core.refuse(v_action, 'invalid_content',
      'Add people who work with the organisation and are not already on the visit, or remove people who are; and say why.', 'A valid change', 'You');
  end if;
  v := authz.require(v_action, t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  actor := (v ->> 'actor_person_id')::uuid;
  foreach x in array coalesce(p_add_person_ids, '{}') loop
    insert into core.access_roster_member (customer_id, venue_id, authorisation_id, person_id, added_by_person_id, added_after_approval)
    values (a.customer_id, a.venue_id, a.id, x, actor, a.status = 'approved');
  end loop;
  update core.access_roster_member set removed_at = clock_timestamp(), removed_by_person_id = actor, removal_reason = p_reason
   where id = any (coalesce(p_remove_member_ids, '{}'));
  return v;
end $$;

create function api.approve_roster_addition(p_idempotency_key text, p_member_id uuid,
                                            p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare m core.access_roster_member; a core.access_authorisation; t jsonb; r jsonb; v jsonb;
begin
  select * into m from core.access_roster_member where id = p_member_id;
  select * into a from core.access_authorisation where id = m.authorisation_id;
  t := core.access_target(a, a.id, core.access_people(a));
  r := jsonb_build_object('member_id', p_member_id);
  v := core.authorised_or_refusal('access.approve', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if not m.added_after_approval or m.approved_at is not null or m.removed_at is not null or a.status <> 'approved' then
    return core.refuse('access.approve', 'not_pending', 'This person is not waiting to be approved onto the visit.', 'A pending addition', 'Nobody');
  end if;
  v := authz.require('access.approve', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  update core.access_roster_member set approved_at = clock_timestamp(), approved_by_person_id = (v ->> 'actor_person_id')::uuid where id = m.id;
  return v;
end $$;

create function api.cancel_access(p_idempotency_key text, p_authorisation_id uuid, p_expected_version integer, p_reason text,
                                  p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare a core.access_authorisation; v_action text; t jsonb; r jsonb; v jsonb;
begin
  select * into a from core.access_authorisation where id = p_authorisation_id;
  v_action := case when a.organisation_id in (select authz.my_admin_organisation_ids()) then 'access.cancel'
                   when a.customer_id in (select authz.my_admin_customer_ids()) then 'access.cancel_for_venue' else 'access.cancel_as_authority' end;
  t := core.access_target(a, a.id);
  r := jsonb_build_object('authorisation_id', p_authorisation_id, 'expected_version', p_expected_version, 'reason', p_reason);
  v := core.authorised_or_refusal(v_action, t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if a.status not in ('requested', 'approved') or (v_action = 'access.cancel_as_authority' and a.status <> 'approved') then
    return core.refuse(v_action, 'not_open', 'Only a requested or approved visit can be withdrawn or cancelled.', 'An open visit', 'Nobody');
  end if;
  if core.blank(p_reason) then return core.refuse(v_action, 'invalid_content', 'Say why.', 'A reason', 'You'); end if;
  v := authz.require(v_action, t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.access_authorisation', a.id, case a.status when 'requested' then 'withdrawn' else 'cancelled' end, p_expected_version,
                          (v ->> 'decision_context_id')::uuid, jsonb_build_object('decision_reason', p_reason));
  return v;
end $$;

-- A work request raised from a visit is a normal job, linked; the visit is unchanged (Q122).
create function api.link_work_request(p_idempotency_key text, p_authorisation_id uuid, p_work_package_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare a core.access_authorisation; wp core.work_package; t jsonb; r jsonb; v jsonb;
begin
  select * into a from core.access_authorisation where id = p_authorisation_id;
  select * into wp from core.work_package where id = p_work_package_id;
  t := core.access_target(a, a.id);
  r := jsonb_build_object('authorisation_id', p_authorisation_id, 'work_package_id', p_work_package_id);
  v := core.authorised_or_refusal('access.link_work_request', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if a.status <> 'approved' or wp.id is null or wp.venue_id <> a.venue_id or wp.performing_organisation_id <> a.organisation_id
     or exists (select 1 from core.access_work_request x where x.work_package_id = wp.id) then
    return core.refuse('access.link_work_request', 'invalid_content',
      'Link a job at the same venue, performed by the visiting organisation, to an approved visit.', 'A matching job', 'You');
  end if;
  v := authz.require('access.link_work_request', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.access_work_request (customer_id, venue_id, authorisation_id, work_package_id, linked_by_person_id, decision_context_id)
  values (a.customer_id, a.venue_id, a.id, wp.id, (v ->> 'actor_person_id')::uuid, (v ->> 'decision_context_id')::uuid);
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- The evaluation, restated: an approved visit naming the person, in force now, is also a
-- reason to be here (Q125). Its purpose's inductions and escort apply; its conditions are
-- shown. Everything else is as in 0045.
-- ---------------------------------------------------------------------------
create or replace function core.entry_evaluation(p_person_id uuid, p_venue_id uuid, p_gate_point_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  pe core.person; rule core.entry_rule_version; gp core.gate_point; gate_path uuid[];
  reasons jsonb := '[]'; notices jsonb := '[]'; best jsonb; cand jsonb; b record; a jsonb; missing jsonb; c text;
  any_engaged boolean := false; any_restricted_org boolean := false; overrides jsonb := '[]'; ov record; outcome text;
  never text[]; vis record; purpose jsonb; any_visit boolean := false;
begin
  select * into pe from core.person where id = p_person_id;
  select * into gp from core.gate_point where id = p_gate_point_id;
  gate_path := coalesce((select path from core.area where id = gp.area_id), (select path from core.area where venue_id = p_venue_id and parent_id is null));
  select * into rule from core.entry_rule_version where venue_id = p_venue_id and status = 'approved';
  never := array(select jsonb_array_elements_text(coalesce(rule.content -> 'never_overridable', '[]')));

  -- The fixed floor.
  if pe.deactivated_at is not null then
    reasons := reasons || jsonb_build_object('code', 'person_deactivated', 'severity', 'do_not_admit', 'words', 'This person''s record is no longer active.',
                                             'owner', 'The venue''s tenant administrator');
  end if;
  if authz.person_restricted(pe.id, p_venue_id) then
    reasons := reasons || jsonb_build_object('code', 'person_restricted', 'severity', 'do_not_admit', 'words', 'Restricted at this venue.',
                                             'owner', 'The authority that imposed the restriction');
  end if;

  -- A reason to be here now (Q191): an active engagement of an organisation they work with.
  for b in select r.kind, e.id as engagement_id, e.capacity_code, o.id as organisation_id, o.legal_name,
                  authz.organisation_restricted(o.id, p_venue_id) as restricted
             from core.person_organisation_relationship r
             join core.engagement e on e.organisation_id = r.organisation_id
             join core.organisation o on o.id = r.organisation_id
            where r.person_id = pe.id and r.status = 'active' and now() <@ r.valid_during
              and e.venue_id = p_venue_id and e.status = 'active' and now() <@ e.valid_during loop
    if b.restricted then any_restricted_org := true; continue; end if;
    any_engaged := true;
    for a in select x from jsonb_array_elements(coalesce(rule.content -> 'audiences', '[]')) x
              where x -> 'capacities' ? b.capacity_code and x -> 'relationship_kinds' ? b.kind
                and (jsonb_typeof(x -> 'event_phase') = 'null'
                     or exists (select 1 from core.event_phase ph where ph.venue_id = p_venue_id and ph.phase = x ->> 'event_phase' and now() <@ ph.valid_during)) loop
      missing := core.missing_inductions(pe, a -> 'induction_course_ids');
      cand := jsonb_build_object('audience', a ->> 'name', 'organisation', b.legal_name, 'organisation_id', b.organisation_id,
                                 'engagement_id', b.engagement_id, 'escort', a ->> 'escort', 'missing', missing, 'area_ids', a -> 'area_ids',
                                 'inductions', core.induction_states(pe, a -> 'induction_course_ids'));
      if core.better_basis(cand, best) then best := cand; end if;
    end loop;
  end loop;

  -- Or an approved visit naming them, in force now (Q125).
  for vis in select av.*, o.legal_name, authz.organisation_restricted(av.organisation_id, p_venue_id) as restricted
               from core.access_authorisation av join core.organisation o on o.id = av.organisation_id
               join core.engagement e on e.id = av.engagement_id
              where av.venue_id = p_venue_id and av.status = 'approved' and now() <@ av.valid_during
                and e.status = 'active' and now() <@ e.valid_during
                and exists (select 1 from core.access_roster_member m where m.authorisation_id = av.id and m.person_id = pe.id and m.removed_at is null
                              and (not m.added_after_approval or m.approved_at is not null)) loop
    if vis.restricted then any_restricted_org := true; continue; end if;
    any_visit := true;
    purpose := (select core.visit_purpose(x) from core.access_authorisation x where x.id = vis.id);
    missing := core.missing_inductions(pe, purpose -> 'induction_course_ids');
    cand := jsonb_build_object('audience', 'Visit ' || vis.reference || ': ' || (purpose ->> 'name'), 'organisation', vis.legal_name,
                               'organisation_id', vis.organisation_id, 'engagement_id', vis.engagement_id,
                               'escort', case when purpose ->> 'escort' = 'always' or vis.conditions ->> 'escort' is not null then 'always' else 'never' end,
                               'missing', missing, 'area_ids', to_jsonb(vis.area_ids), 'inductions', core.induction_states(pe, purpose -> 'induction_course_ids'),
                               'visit', jsonb_build_object('id', vis.id, 'reference', vis.reference, 'purpose', purpose ->> 'name', 'allows', purpose ->> 'allows',
                                                           'prohibits', purpose ->> 'prohibits', 'conditions', vis.conditions));
    if core.better_basis(cand, best) then best := cand; end if;
  end loop;

  if not any_engaged and not any_visit then
    reasons := reasons || case when any_restricted_org
      then jsonb_build_object('code', 'organisation_restricted', 'severity', 'do_not_admit', 'words', 'Their organisation is restricted at this venue.',
                              'owner', 'The authority that imposed the restriction')
      else jsonb_build_object('code', 'no_reason', 'severity', 'do_not_admit', 'words', 'No current engagement or visit here for now.',
                              'owner', 'Their organisation and the venue''s engagement owner') end;
  elsif best is null and rule.id is null then
    reasons := reasons || jsonb_build_object('code', 'no_rule', 'severity', 'check', 'words', 'The venue has no approved entry rules.',
                                             'owner', 'The venue''s access authority');
  elsif best is null then
    reasons := reasons || jsonb_build_object('code', 'no_rule', 'severity', 'check', 'words', 'No entry rule covers this person''s role here now.',
                                             'owner', 'The venue''s access authority');
  else
    reasons := reasons || (best -> 'missing');
  end if;

  -- Overrides in force for this place cover the reasons they name, never the floor or the
  -- venue's never-overridable list.
  for ov in select o.* from core.entry_override o where o.person_id = pe.id and o.venue_id = p_venue_id and now() <@ o.valid_during
                                                    and o.area_id = any (gate_path) loop
    if exists (select 1 from jsonb_array_elements(reasons) x where x ->> 'code' = any (ov.reason_codes)
                 and not (x ->> 'code' = any (core.entry_reason_floor())) and not (x ->> 'code' = any (never))) then
      overrides := overrides || jsonb_build_object('id', ov.id, 'reasons', to_jsonb(ov.reason_codes), 'until', upper(ov.valid_during),
                                                   'escort', ov.escort, 'purpose', ov.purpose, 'by', core.person_name(ov.granted_by_person_id));
      reasons := (select coalesce(jsonb_agg(case when x ->> 'code' = any (ov.reason_codes) and not (x ->> 'code' = any (core.entry_reason_floor()))
                                                  and not (x ->> 'code' = any (never))
                                             then x || jsonb_build_object('overridden_by', ov.id) else x end), '[]')
                    from jsonb_array_elements(reasons) x);
    end if;
  end loop;
  reasons := (select coalesce(jsonb_agg(x || jsonb_build_object('overridable', (x ->> 'code') = any (core.entry_reason_overridable()) and not ((x ->> 'code') = any (never)))), '[]')
                from jsonb_array_elements(reasons) x);

  outcome := case
    when exists (select 1 from jsonb_array_elements(reasons) x where x ->> 'severity' = 'do_not_admit' and not x ? 'overridden_by') then 'do_not_admit'
    when exists (select 1 from jsonb_array_elements(reasons) x where x ->> 'severity' = 'check' and not x ? 'overridden_by') then 'check'
    when best ->> 'escort' = 'always' or exists (select 1 from jsonb_array_elements(overrides) o where not core.blank(o ->> 'escort')) then 'admit_with_escort'
    else 'admit' end;

  -- Permits, as notices only (Q193, Q194, P7-12).
  notices := (select coalesce(jsonb_agg(n), '[]') from (
    select format('Not on the %s permit for %s: cannot join that task.', pc.name, w.reference) n
      from core.permit p join core.permit_class pc on pc.id = p.permit_class_id join core.work_package w on w.id = p.work_package_id
     where p.venue_id = p_venue_id and core.is_live(p.status)
       and exists (select 1 from core.permit_team_member m where m.permit_id = p.id and m.person_id = pe.id and m.removed_at is not null)
       and not exists (select 1 from core.permit_team_member m where m.permit_id = p.id and m.person_id = pe.id and m.removed_at is null)
    union all
    select format('The %s work for %s is stopped: do not start it.', pc.name, w.reference)
      from core.permit p join core.permit_class pc on pc.id = p.permit_class_id join core.work_package w on w.id = p.work_package_id
     where p.venue_id = p_venue_id and p.status in ('suspended', 'hand_back_pending')
       and exists (select 1 from core.permit_team_member m where m.permit_id = p.id and m.person_id = pe.id and m.removed_at is null)) z);
  -- A visit allows no work (Q121).
  if best ? 'visit' then
    notices := notices || to_jsonb(format('Visit only: %s. Not allowed: %s.', best #>> '{visit,allows}', best #>> '{visit,prohibits}'));
  end if;

  return jsonb_build_object(
    'outcome', outcome,
    'person', jsonb_build_object('id', pe.id, 'name', pe.given_name || ' ' || pe.family_name),
    'organisation', best ->> 'organisation', 'audience', best ->> 'audience', 'engagement_id', best -> 'engagement_id',
    'visit', best -> 'visit', 'visit_id', best #>> '{visit,id}',
    'areas', (select coalesce(jsonb_agg(ar.name order by ar.name), '[]') from core.area ar where ar.id::text in (select jsonb_array_elements_text(coalesce(best -> 'area_ids', '[]')))),
    'escort', coalesce(best ->> 'escort', 'never'),
    'inductions', coalesce(best -> 'inductions', '[]'),
    'reasons', reasons, 'overrides', overrides, 'notices', notices,
    'rule_version_id', rule.id,
    'entry_only', 'This is permission to be here, not permission to work.');
end $$;

-- Helpers the evaluation uses.
create function core.missing_inductions(pe core.person, p_course_ids jsonb) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('code', 'induction_missing', 'severity', 'do_not_admit',
            'words', format('No valid induction: %s.', k.title), 'owner', format('%s, by completing it', pe.given_name || ' ' || pe.family_name))), '[]')
    from core.induction_course k
   where k.id::text in (select jsonb_array_elements_text(coalesce(p_course_ids, '[]')))
     and not exists (select 1 from core.induction_completion ic join core.course_version cv on cv.id = ic.course_version_id
                      where ic.person_id = pe.id and cv.course_id = k.id and ic.valid_until >= now()
                        and not exists (select 1 from core.completion_invalidation i where i.completion_id = ic.id)) $$;

create function core.induction_states(pe core.person, p_course_ids jsonb) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('course', k.title,
           'valid_until', (select max(ic.valid_until) from core.induction_completion ic join core.course_version cv on cv.id = ic.course_version_id
                            where ic.person_id = pe.id and cv.course_id = k.id
                              and not exists (select 1 from core.completion_invalidation i where i.completion_id = ic.id)))), '[]')
    from core.induction_course k where k.id::text in (select jsonb_array_elements_text(coalesce(p_course_ids, '[]'))) $$;

-- The most favourable basis: nothing missing first, then without an escort.
create function core.better_basis(cand jsonb, best jsonb) returns boolean
language sql immutable set search_path = '' as $$
  select best is null or jsonb_array_length(cand -> 'missing') < jsonb_array_length(best -> 'missing')
      or (jsonb_array_length(cand -> 'missing') = jsonb_array_length(best -> 'missing') and cand ->> 'escort' = 'never' and best ->> 'escort' = 'always') $$;

-- Arrivals and departures against a visit, from the gate's record of what the operator did.
do $m$
declare d text;
begin
  d := pg_get_functiondef('api.record_gate_action(text,uuid,text,text,text,text,text)'::regprocedure);
  if position('  return v || jsonb_build_object(''scan_event_id'', s_id);' in d) = 0 then
    raise exception 'api.record_gate_action no longer has the expected structure';
  end if;
  execute replace(d, '  return v || jsonb_build_object(''scan_event_id'', s_id);', $r$  if p_action = 'admitted' and e.result ->> 'visit_id' is not null then
    if p_direction = 'in' then
      insert into core.visit_attendance (customer_id, venue_id, authorisation_id, person_id, arrived_at, arrival_scan_id)
      values (e.customer_id, e.venue_id, (e.result ->> 'visit_id')::uuid, e.person_id, clock_timestamp(), s_id);
    else
      update core.visit_attendance set left_at = clock_timestamp(), departure_scan_id = s_id
       where id = (select id from core.visit_attendance where authorisation_id = (e.result ->> 'visit_id')::uuid and person_id = e.person_id
                     and left_at is null order by arrived_at desc limit 1);
    end if;
  end if;
  return v || jsonb_build_object('scan_event_id', s_id);$r$);
end $m$;

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------
create view api.venue_config_version with (security_invoker = true) as select * from core.venue_config_version;
create view api.access_authorisation with (security_invoker = true) as
  select id, customer_id, venue_id, reference, organisation_id, engagement_id, purpose_config_id, purpose_key, description, area_ids,
         lower(valid_during) as starts_at, upper(valid_during) as ends_at, status, requested_by_person_id, conditions, decided_by_person_id,
         decision_reason, row_version, created_at
    from core.access_authorisation;
create view api.access_roster_member with (security_invoker = true) as select * from core.access_roster_member;
create view api.access_consent with (security_invoker = true) as select * from core.access_consent;
create view api.visit_attendance with (security_invoker = true) as select * from core.visit_attendance;
create view api.access_work_request with (security_invoker = true) as select * from core.access_work_request;

grant select on all tables in schema api to authenticated;
grant execute on all functions in schema api to authenticated;
revoke execute on all functions in schema api from anon, public;
