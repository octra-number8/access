-- 0033 Permits API (phase 5a, D-018)
--
-- Pattern as before: readiness checks run before authz.require and return a refusal
-- (a repeated request is replayed first); authority only from authz.evaluate; status
-- only through core.transition, with derived decisions for what one decision settles.
-- A permit's state follows from the latest decision on each step of its current
-- version (core.settle_permit), so it can never be set directly.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

-- ---------------------------------------------------------------------------
-- Helpers (not executable by clients)
-- ---------------------------------------------------------------------------
create function core.current_class_version(p_class_id uuid) returns core.permit_class_version
language sql stable security definer set search_path = '' as $$
  select * from core.permit_class_version where permit_class_id = p_class_id and status = 'approved' $$;

create function core.latest_decision(p_step_id uuid) returns core.step_decision
language sql stable security definer set search_path = '' as $$
  select * from core.step_decision where permit_step_id = p_step_id order by created_at desc, id desc limit 1 $$;

create function core.favourable(p_outcome text) returns boolean
language sql immutable set search_path = '' as $$
  select p_outcome in ('no_further_comments', 'conditions', 'not_applicable') $$;

-- A step can be decided when its version is current, the permit is in review, every
-- earlier group is settled favourably, and it has no standing decision of its own.
create function core.step_open(p_step_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p.current_version_id = s.permit_version_id
     and p.status in ('submitted', 'under_review')
     and coalesce((core.latest_decision(s.id)).outcome, 'reopened') = 'reopened'
     and not exists (select 1 from core.permit_step e
                      where e.permit_version_id = s.permit_version_id and e.group_no < s.group_no
                        and not coalesce(core.favourable((core.latest_decision(e.id)).outcome), false))
    from core.permit_step s
    join core.permit_version v on v.id = s.permit_version_id
    join core.permit p on p.id = v.permit_id
   where s.id = p_step_id $$;

-- The state a permit's decisions call for.
create function core.permit_target_state(p_permit_id uuid) returns text
language sql stable security definer set search_path = '' as $$
  with d as (select (core.latest_decision(s.id)).outcome o
               from core.permit p join core.permit_step s on s.permit_version_id = p.current_version_id
              where p.id = p_permit_id)
  select case when exists (select 1 from d where o = 'refused') then 'refused'
              when exists (select 1 from d where o = 'more_information') then 'more_information_required'
              when not exists (select 1 from d where not coalesce(core.favourable(o), false))
                   and (select kind from core.permit where id = p_permit_id) = 'child' then 'approved_for_issue'
              when not exists (select 1 from d where not coalesce(core.favourable(o), false))
                   and core.wa_children_ready(p_permit_id) then 'approved_for_issue'
              when exists (select 1 from d where o is not null and o <> 'reopened') then 'under_review'
              else 'submitted' end $$;

-- Moves a permit to the state its decisions call for, as a derived decision of the
-- step decision being recorded; then does the same for its Work Approval.
create function core.settle_permit(p_permit_id uuid, p_parent uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare p core.permit; target text; via text;
begin
  select * into p from core.permit where id = p_permit_id;
  if p.status in ('submitted', 'under_review', 'approved_for_issue') then
    target := core.permit_target_state(p.id);
    if target is distinct from p.status and not (target = 'submitted' and p.status = 'under_review') then
      via := case target when 'refused' then 'permit.refuse'
                         when 'more_information_required' then 'permit.request_information'
                         when 'approved_for_issue' then 'permit.approve_for_issue'
                         else case p.status when 'approved_for_issue' then 'permit.reopen' else 'permit.start_review' end end;
      if target = 'submitted' then target := 'under_review'; end if;
      perform authz.derive(via, 'permit', p.id);
      perform core.transition('core.permit', p.id, target, p.row_version, core.ctx_uuid('decision_context_id'));
      perform authz.resume(p_parent);
    end if;
  end if;
  if p.kind = 'child' then
    perform core.settle_permit(p.parent_permit_id, p_parent);
  end if;
end $$;

-- Everyone connected with the job, and whoever made this version's declaration.
create function core.permit_people(p_permit_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select core.work_package_people(p.work_package_id)
         || coalesce((select jsonb_agg(distinct v.declared_by_person_id) from core.permit_version v where v.permit_id = p.id), '[]')
    from core.permit p where p.id = p_permit_id $$;

create function core.permit_target(p core.permit, p_record_id uuid, p_type text, p_org uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select core.wp_target(wp, p_record_id, p_type, p_org) from core.work_package wp where wp.id = p.work_package_id $$;

-- Problems with a permit draft before it can be submitted.
create function core.permit_draft_problems(p_permit_id uuid) returns text[]
language plpgsql stable security definer set search_path = '' as $$
declare
  p core.permit; wp core.work_package; rev core.work_package_revision; d core.permit_draft;
  cv core.permit_class_version; errs text[] := '{}';
begin
  select * into p from core.permit where id = p_permit_id;
  select * into wp from core.work_package where id = p.work_package_id;
  select * into rev from core.work_package_revision where id = wp.current_revision_id;
  select * into d from core.permit_draft where permit_id = p_permit_id;
  cv := core.current_class_version(p.permit_class_id);
  if wp.status <> 'routed' then
    errs := errs || text 'The job is not routed: it changed, or its screening is not settled. Settle the job first.';
  end if;
  if cv.id is null then
    errs := errs || text 'This permit class has no approved configuration at this venue, so it cannot be requested yet.';
  else
    errs := errs || core.screening_answer_problems(jsonb_build_object('questions', cv.content -> 'questions'), d.answers);
  end if;
  if d.window_from is null or d.window_to is null or d.window_to <= d.window_from then
    errs := errs || text 'Give the start and end of the permit''s window.';
  elsif not (tstzrange(d.window_from, d.window_to) <@ rev.planned_window) then
    errs := errs || text 'The permit''s window must sit within the job''s planned dates.';
  end if;
  return errs;
end $$;

-- Steps for a new version, from the class route (Q76-Q78): review and external steps
-- cover the whole job; occupier and landlord steps are one per party of that role,
-- scoped to the areas the register says that party occupies (else the whole job).
create function core.instantiate_steps(p_version core.permit_version, p_content jsonb) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  s jsonb; party record; n integer := 0;
  v_areas uuid[] := array(select area_id from core.work_package_area where revision_id = p_version.revision_id);
  v_systems uuid[] := array(select system_id from core.work_package_system where revision_id = p_version.revision_id);
  occupied uuid[];
begin
  for s in select * from jsonb_array_elements(p_content -> 'route') loop
    if s ? 'when' and not exists (select 1 from core.system y where y.id = any (v_systems)
                                                           and y.system_type_id = (s #>> '{when,system_type_id}')::uuid) then
      continue;
    end if;
    if s ->> 'kind' in ('review', 'external') then
      insert into core.permit_step (customer_id, venue_id, permit_version_id, step_key, name, kind, group_no, area_ids, system_ids)
      values (p_version.customer_id, p_version.venue_id, p_version.id, s ->> 'key', s ->> 'name', s ->> 'kind',
              (s ->> 'group')::integer, v_areas, v_systems);
      n := n + 1;
    else
      for party in select organisation_id from core.work_package_party
                    where revision_id = p_version.revision_id
                      and role = case s ->> 'kind' when 'occupier' then 'affected_occupier' else 'landlord_operator' end loop
        occupied := array(select o.area_id from core.area_occupation o
                           where o.organisation_id = party.organisation_id and o.area_id = any (v_areas)
                             and o.ended_at is null and o.valid_during && p_version.planned_window);
        insert into core.permit_step (customer_id, venue_id, permit_version_id, step_key, name, kind, group_no,
                                      party_organisation_id, area_ids, system_ids)
        values (p_version.customer_id, p_version.venue_id, p_version.id, s ->> 'key', s ->> 'name', s ->> 'kind',
                (s ->> 'group')::integer, party.organisation_id,
                case when cardinality(occupied) > 0 then occupied else v_areas end,
                case when s ->> 'kind' = 'landlord_operator' then v_systems else '{}' end);
        n := n + 1;
      end loop;
    end if;
  end loop;
  return n;
end $$;

-- Writes a new version from the draft; returns it. Runs inside an authorised decision.
create function core.new_permit_version(p core.permit, p_actor uuid, p_ctx uuid, p_rfi uuid) returns core.permit_version
language plpgsql security definer set search_path = '' as $$
declare
  wp core.work_package; d core.permit_draft; cv core.permit_class_version; v core.permit_version;
begin
  select * into wp from core.work_package where id = p.work_package_id;
  select * into d from core.permit_draft where permit_id = p.id;
  cv := core.current_class_version(p.permit_class_id);
  insert into core.permit_version (customer_id, venue_id, permit_id, version_no, revision_id, class_version_id, answers,
                                   planned_window, document_version_ids, declaration, declaration_sha256,
                                   declared_by_person_id, responds_to_rfi_id, decision_context_id)
  values (p.customer_id, p.venue_id, p.id,
          coalesce((select max(version_no) from core.permit_version where permit_id = p.id), 0) + 1,
          wp.current_revision_id, cv.id, d.answers, tstzrange(d.window_from, d.window_to), d.document_version_ids,
          cv.content -> 'submission_declaration',
          sha256(convert_to((cv.content -> 'submission_declaration')::text, 'UTF8')), p_actor, p_rfi, p_ctx)
  returning * into v;
  perform core.instantiate_steps(v, cv.content);
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Class configuration (P5-5), Work Approval class and area occupation
-- ---------------------------------------------------------------------------
create function api.create_work_approval_class(p_idempotency_key text, p_venue_id uuid, p_code text, p_name text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_id uuid := gen_random_uuid(); v_customer uuid := core.venue_customer(p_venue_id); v jsonb;
begin
  v := authz.require('permit_class.create_work_approval',
         jsonb_build_object('customer_id', v_customer, 'venue_id', p_venue_id, 'record_id', v_id, 'target_type', 'permit_class'),
         p_idempotency_key, jsonb_build_object('venue_id', p_venue_id, 'code', p_code, 'name', p_name));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  if exists (select 1 from core.permit_class where venue_id = p_venue_id and handling = 'work_approval') then
    raise exception 'this venue already has a Work Approval class' using errcode = '22023';
  end if;
  insert into core.permit_class (id, customer_id, venue_id, code, name, handling)
  values (v_id, v_customer, p_venue_id, p_code, p_name, 'work_approval');
  return v;
end $$;

create function api.create_class_draft(p_idempotency_key text, p_permit_class_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_id uuid := gen_random_uuid(); pc core.permit_class; prev core.permit_class_version; v jsonb;
begin
  select * into pc from core.permit_class where id = p_permit_class_id;
  v := authz.require('permit_class_version.draft',
         jsonb_build_object('customer_id', pc.customer_id, 'venue_id', pc.venue_id, 'record_id', v_id,
                            'target_type', 'permit_class_version'),
         p_idempotency_key, jsonb_build_object('permit_class_id', p_permit_class_id));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  if pc.handling = 'external_reference' then
    raise exception 'a class handled by external reference is not requested as a permit' using errcode = '22023';
  end if;
  if exists (select 1 from core.permit_class_version where permit_class_id = pc.id and status in ('draft', 'proposed')) then
    raise exception 'this class already has a configuration in progress; finish or reject it first' using errcode = '22023';
  end if;
  select * into prev from core.permit_class_version where permit_class_id = pc.id order by version_no desc limit 1;
  insert into core.permit_class_version (id, customer_id, venue_id, permit_class_id, version_no, status, content, authored_by_person_id)
  values (v_id, pc.customer_id, pc.venue_id, pc.id, coalesce(prev.version_no, 0) + 1, 'draft',
          coalesce(prev.content, '{"questions": [], "route": [], "submission_declaration": [], "acceptance_declaration": []}'),
          (v ->> 'actor_person_id')::uuid);
  return v;
end $$;

create function api.save_class_draft(p_idempotency_key text, p_version_id uuid, p_expected_version integer,
                                     p_content jsonb, p_source_ref text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c core.permit_class_version; t jsonb; r jsonb; v jsonb; problems text[];
begin
  select * into c from core.permit_class_version where id = p_version_id;
  t := jsonb_build_object('customer_id', c.customer_id, 'venue_id', c.venue_id, 'record_id', p_version_id,
                          'target_type', 'permit_class_version');
  r := jsonb_build_object('version_id', p_version_id, 'expected_version', p_expected_version, 'content', p_content);
  v := core.authorised_or_refusal('permit_class_version.save_draft', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if c.status <> 'draft' then
    raise exception 'only a draft configuration can be changed' using errcode = 'PT409';
  end if;
  problems := core.validate_class_config(c.venue_id, p_content, false);
  if cardinality(problems) > 0 then
    return core.refuse('permit_class_version.save_draft', 'invalid_content', 'The class configuration has problems.',
                       'Each item listed', 'Whoever is editing it', jsonb_build_object('problems', to_jsonb(problems)));
  end if;
  v := authz.require('permit_class_version.save_draft', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  if c.row_version <> p_expected_version then
    raise exception 'this configuration changed since you opened it' using errcode = 'PT409';
  end if;
  update core.permit_class_version set content = p_content, source_ref = p_source_ref where id = p_version_id;
  return v;
end $$;

create function api.propose_class_version(p_idempotency_key text, p_version_id uuid, p_expected_version integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c core.permit_class_version; t jsonb; r jsonb; v jsonb; problems text[];
begin
  select * into c from core.permit_class_version where id = p_version_id;
  t := jsonb_build_object('customer_id', c.customer_id, 'venue_id', c.venue_id, 'record_id', p_version_id,
                          'target_type', 'permit_class_version');
  r := jsonb_build_object('version_id', p_version_id, 'expected_version', p_expected_version);
  v := core.authorised_or_refusal('permit_class_version.propose', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  problems := core.validate_class_config(c.venue_id, c.content, true);
  if cardinality(problems) > 0 then
    return core.refuse('permit_class_version.propose', 'not_ready', 'This configuration is not ready for approval.',
                       'Each item listed', 'Whoever is editing it', jsonb_build_object('problems', to_jsonb(problems)));
  end if;
  v := authz.require('permit_class_version.propose', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.permit_class_version', p_version_id, 'proposed', p_expected_version,
    (v ->> 'decision_context_id')::uuid,
    jsonb_build_object('proposed_by_person_id', v ->> 'actor_person_id',
                       'content_sha256', encode(sha256(convert_to(c.content::text, 'UTF8')), 'hex')));
  return v;
end $$;

-- Approved by the technical authority, holding an appointment that covers this class
-- across the venue. The author and proposer are excluded.
create function api.decide_class_version(p_idempotency_key text, p_version_id uuid, p_expected_version integer,
                                         p_decision text, p_reason text, p_acting_appointment_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c core.permit_class_version; prev uuid; ctx uuid; t jsonb; r jsonb; v jsonb; problems text[];
begin
  if p_decision not in ('approve', 'reject') then
    raise exception 'decision must be approve or reject' using errcode = '22023';
  end if;
  select * into c from core.permit_class_version where id = p_version_id;
  t := jsonb_build_object('customer_id', c.customer_id, 'venue_id', c.venue_id, 'record_id', p_version_id,
                          'target_type', 'permit_class_version', 'permit_class_id', c.permit_class_id,
                          'excluded_person_ids', jsonb_build_array(c.authored_by_person_id, c.proposed_by_person_id));
  r := jsonb_build_object('version_id', p_version_id, 'expected_version', p_expected_version, 'decision', p_decision, 'reason', p_reason);
  v := core.authorised_or_refusal('permit_class_version.' || p_decision, t, p_idempotency_key, r, p_acting_appointment_id);
  if v is not null then return v; end if;
  if c.status <> 'proposed' then
    return core.refuse('permit_class_version.' || p_decision, 'not_proposed', 'Only a proposed configuration can be decided.',
                       'A proposed configuration', 'The venue''s tenant administrator, who proposes it');
  end if;
  if length(btrim(coalesce(p_reason, ''))) = 0 then
    return core.refuse('permit_class_version.' || p_decision, 'invalid_content', 'Give a reason for the decision.', 'A reason', 'You');
  end if;
  v := authz.require('permit_class_version.' || p_decision, t, p_idempotency_key, r, p_acting_appointment_id, null);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ctx := (v ->> 'decision_context_id')::uuid;
  if p_decision = 'approve' then
    problems := core.validate_class_config(c.venue_id, c.content, true);
    if cardinality(problems) > 0 then
      raise exception 'this configuration cannot be approved: %', array_to_string(problems, ' ') using errcode = '22023';
    end if;
    select id into prev from core.permit_class_version where permit_class_id = c.permit_class_id and status = 'approved';
    if prev is not null then
      perform authz.derive('permit_class_version.supersede', 'permit_class_version', prev);
      perform core.transition('core.permit_class_version', prev, 'superseded',
                              (select row_version from core.permit_class_version where id = prev), core.ctx_uuid('decision_context_id'));
      perform authz.resume(ctx);
    end if;
  end if;
  perform core.transition('core.permit_class_version', p_version_id, case p_decision when 'approve' then 'approved' else 'rejected' end,
                          p_expected_version, ctx,
                          jsonb_build_object('decided_by_person_id', v ->> 'actor_person_id', 'decided_at', now(), 'decision_reason', p_reason));
  return v;
end $$;

create function api.record_area_occupation(p_idempotency_key text, p_area_id uuid, p_organisation_id uuid,
                                           p_valid_from timestamptz, p_valid_to timestamptz default null,
                                           p_evidence_ref text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_id uuid := gen_random_uuid(); a core.area; v jsonb;
begin
  select * into a from core.area where id = p_area_id;
  v := authz.require('area_occupation.record',
         jsonb_build_object('customer_id', a.customer_id, 'venue_id', a.venue_id, 'record_id', v_id, 'target_type', 'area_occupation'),
         p_idempotency_key, jsonb_build_object('area_id', p_area_id, 'organisation_id', p_organisation_id,
                                               'from', p_valid_from, 'to', p_valid_to, 'evidence', p_evidence_ref));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.area_occupation (id, customer_id, venue_id, area_id, organisation_id, valid_during, evidence_ref)
  values (v_id, a.customer_id, a.venue_id, p_area_id, p_organisation_id, tstzrange(p_valid_from, p_valid_to), p_evidence_ref);
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Starting the permits a routed job needs (P5-2) and a class screening missed (P5-12)
-- ---------------------------------------------------------------------------
create function core.create_permit(wp core.work_package, p_kind text, p_class uuid, p_parent uuid, p_ctx uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid := gen_random_uuid(); rev core.work_package_revision;
begin
  select * into rev from core.work_package_revision where id = wp.current_revision_id;
  perform authz.derive('permit.create', 'permit', v_id);
  insert into core.permit (id, customer_id, venue_id, work_package_id, kind, permit_class_id, parent_permit_id, status)
  values (v_id, wp.customer_id, wp.venue_id, wp.id, p_kind, p_class, p_parent, 'draft');
  insert into core.permit_draft (customer_id, venue_id, permit_id, window_from, window_to)
  values (wp.customer_id, wp.venue_id, v_id, lower(rev.planned_window), upper(rev.planned_window));
  perform authz.resume(p_ctx);
  return v_id;
end $$;

create function api.start_permits(p_idempotency_key text, p_work_package_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  wp core.work_package; v_action text; t jsonb; r jsonb; v jsonb; ctx uuid; wa uuid; wa_class uuid;
  missing text[]; c uuid; x record; created integer := 0;
begin
  select * into wp from core.work_package where id = p_work_package_id;
  v_action := core.wp_action('permit.start', p_work_package_id, wp.customer_id);
  t := core.wp_target(wp, p_work_package_id, 'work_package', coalesce(core.wp_actor_org(p_work_package_id), wp.performing_organisation_id));
  r := jsonb_build_object('work_package_id', p_work_package_id);
  v := core.authorised_or_refusal(v_action, t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if wp.status <> 'routed' then
    return core.refuse(v_action, 'not_routed', 'Permits can be started only for a job whose screening is settled.',
                       'A routed job', 'Whoever is preparing the job');
  end if;
  if not exists (select 1 from core.wp_required_classes(wp.id)) then
    return core.refuse(v_action, 'no_permit_needed', 'This job was routed with no permit needed.',
                       'A permit the job needs', 'The venue''s screening authority, if a permit was missed');
  end if;
  select id into wa_class from core.permit_class where venue_id = wp.venue_id and handling = 'work_approval' and retired_at is null;
  select array_agg(pc.name order by pc.name) into missing
    from core.permit_class pc
   where (pc.id in (select core.wp_required_classes(wp.id)) or pc.id = wa_class)
     and (core.current_class_version(pc.id)).id is null;
  if wa_class is null or missing is not null then
    return core.refuse(v_action, 'class_not_configured',
      'Some permits this job needs have no approved configuration at this venue yet: '
        || array_to_string(coalesce(missing, '{}') || case when wa_class is null then array['Work Approval'] else '{}' end, ', ') || '.',
      'An approved configuration for each', 'The venue''s technical authority');
  end if;
  v := authz.require(v_action, t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ctx := (v ->> 'decision_context_id')::uuid;

  select id into wa from core.permit where work_package_id = wp.id and kind = 'work_approval' and status <> 'cancelled';
  if wa is null then
    wa := core.create_permit(wp, 'work_approval', wa_class, null, ctx);
    created := created + 1;
  end if;
  for c in select core.wp_required_classes(wp.id) loop
    if not exists (select 1 from core.permit where parent_permit_id = wa and permit_class_id = c and status <> 'cancelled') then
      perform core.create_permit(wp, 'child', c, wa, ctx);
      created := created + 1;
    end if;
  end loop;
  -- A child for a class the job no longer needs (after a change and re-screening) is cancelled.
  for x in select id, row_version from core.permit
            where parent_permit_id = wa and status <> 'cancelled'
              and permit_class_id not in (select core.wp_required_classes(wp.id)) loop
    perform authz.derive('permit.cancel_unrequired', 'permit', x.id);
    perform core.transition('core.permit', x.id, 'cancelled', x.row_version, core.ctx_uuid('decision_context_id'));
    perform authz.resume(ctx);
  end loop;
  return v || jsonb_build_object('work_approval_id', wa, 'created', created);
end $$;

create function api.require_class(p_idempotency_key text, p_work_package_id uuid, p_permit_class_id uuid, p_reason text,
                                  p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare wp core.work_package; pc core.permit_class; v_id uuid := gen_random_uuid(); t jsonb; r jsonb; v jsonb; ctx uuid; wa uuid;
begin
  select * into wp from core.work_package where id = p_work_package_id;
  select * into pc from core.permit_class where id = p_permit_class_id;
  t := core.wp_target(wp, v_id, 'class_requirement', null) || core.revision_scope(wp.screened_revision_id)
       || jsonb_build_object('permit_class_id', p_permit_class_id, 'excluded_person_ids', core.work_package_people(wp.id));
  r := jsonb_build_object('work_package_id', p_work_package_id, 'permit_class_id', p_permit_class_id, 'reason', p_reason);
  v := core.authorised_or_refusal('work_package.require_class', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if wp.status <> 'routed' then
    return core.refuse('work_package.require_class', 'not_routed', 'A class can be required only on a routed job.',
                       'A routed job', 'The applicant, by settling the job');
  end if;
  if pc.id is null or pc.venue_id <> wp.venue_id or pc.handling <> 'permit' or pc.retired_at is not null then
    return core.refuse('work_package.require_class', 'invalid_content', 'Choose a current permit class at this venue.', 'A permit class', 'You');
  end if;
  if pc.id in (select core.wp_required_classes(wp.id)) then
    return core.refuse('work_package.require_class', 'already_required', 'The job already needs this permit.', 'Nothing', 'Nobody');
  end if;
  if length(btrim(coalesce(p_reason, ''))) = 0 then
    return core.refuse('work_package.require_class', 'invalid_content', 'Give the reason the permit is needed.', 'A reason', 'You');
  end if;
  v := authz.require('work_package.require_class', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ctx := (v ->> 'decision_context_id')::uuid;
  insert into core.class_requirement (id, customer_id, venue_id, work_package_id, revision_id, permit_class_id, reason,
                                      decider_person_id, decision_context_id)
  values (v_id, wp.customer_id, wp.venue_id, wp.id, wp.screened_revision_id, pc.id, p_reason, (v ->> 'actor_person_id')::uuid, ctx);
  -- If the job's permits are already started, the new one joins them as a draft.
  select id into wa from core.permit where work_package_id = wp.id and kind = 'work_approval' and status <> 'cancelled';
  if wa is not null then
    perform core.create_permit(wp, 'child', pc.id, wa, ctx);
  end if;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Preparing, submitting, responding and cancelling (Q61-Q68, Q70)
-- ---------------------------------------------------------------------------
create function api.save_permit_draft(p_idempotency_key text, p_permit_id uuid, p_answers jsonb,
                                      p_window_from timestamptz, p_window_to timestamptz,
                                      p_document_version_ids uuid[] default '{}')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p core.permit; wp core.work_package; v_action text; t jsonb; r jsonb; v jsonb;
begin
  select * into p from core.permit where id = p_permit_id;
  select * into wp from core.work_package where id = p.work_package_id;
  v_action := core.wp_action('permit.save_draft', p.work_package_id, p.customer_id);
  t := core.permit_target(p, p_permit_id, 'permit', coalesce(core.wp_actor_org(p.work_package_id), wp.performing_organisation_id));
  r := jsonb_build_object('permit_id', p_permit_id, 'answers', p_answers, 'from', p_window_from, 'to', p_window_to,
                          'documents', p_document_version_ids);
  v := core.authorised_or_refusal(v_action, t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if p.status not in ('draft', 'more_information_required') then
    return core.refuse(v_action, 'not_draft', 'This permit request can be changed only as a draft or when more information is asked for.',
                       'A draft request', 'You');
  end if;
  if jsonb_typeof(p_answers) is distinct from 'object' or exists (select 1 from jsonb_each(p_answers) a where jsonb_typeof(a.value) <> 'array') then
    return core.refuse(v_action, 'invalid_content', 'Answers must be lists of chosen options.', 'Valid answers', 'You');
  end if;
  if not core.documents_of(wp.performing_organisation_id, p_document_version_ids) then
    return core.refuse(v_action, 'invalid_content', 'Documents must be the performing organisation''s own.', 'Your documents', 'You');
  end if;
  v := authz.require(v_action, t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  update core.permit_draft set answers = p_answers, window_from = p_window_from, window_to = p_window_to,
                               document_version_ids = coalesce(p_document_version_ids, '{}')
   where permit_id = p_permit_id;
  return v;
end $$;

create function api.submit_permit(p_idempotency_key text, p_permit_id uuid, p_expected_version integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p core.permit; wp core.work_package; v_action text; t jsonb; r jsonb; v jsonb; ctx uuid; pv core.permit_version; problems text[];
begin
  select * into p from core.permit where id = p_permit_id;
  select * into wp from core.work_package where id = p.work_package_id;
  v_action := core.wp_action('permit.submit', p.work_package_id, p.customer_id);
  t := core.permit_target(p, p_permit_id, 'permit', coalesce(core.wp_actor_org(p.work_package_id), wp.performing_organisation_id));
  r := jsonb_build_object('permit_id', p_permit_id, 'expected_version', p_expected_version);
  v := core.authorised_or_refusal(v_action, t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if p.status <> 'draft' then
    return core.refuse(v_action, 'not_draft', 'Only a draft permit request can be submitted.', 'A draft request', 'You');
  end if;
  problems := core.permit_draft_problems(p_permit_id);
  if cardinality(problems) > 0 then
    return core.refuse(v_action, 'not_ready', 'This permit request is not ready to submit.', 'Each item listed', 'You',
                       jsonb_build_object('problems', to_jsonb(problems)));
  end if;
  v := authz.require(v_action, t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ctx := (v ->> 'decision_context_id')::uuid;
  pv := core.new_permit_version(p, (v ->> 'actor_person_id')::uuid, ctx, null);
  perform core.transition('core.permit', p.id, 'submitted', p_expected_version, ctx, jsonb_build_object('current_version_id', pv.id));
  return v || jsonb_build_object('version_id', pv.id, 'version_no', pv.version_no,
                                 'steps', (select count(*) from core.permit_step where permit_version_id = pv.id));
end $$;

-- Q70, P5-7: answering an information request is a new version with a fresh declaration;
-- every step decides again.
create function api.respond_to_rfi(p_idempotency_key text, p_permit_id uuid, p_expected_version integer, p_responses jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  p core.permit; wp core.work_package; q core.rfi; v_action text; t jsonb; r jsonb; v jsonb; ctx uuid;
  pv core.permit_version; problems text[];
begin
  select * into p from core.permit where id = p_permit_id;
  select * into wp from core.work_package where id = p.work_package_id;
  select x.* into q from core.rfi x where x.permit_version_id = p.current_version_id order by x.created_at desc limit 1;
  v_action := core.wp_action('permit.respond', p.work_package_id, p.customer_id);
  t := core.permit_target(p, p_permit_id, 'permit', coalesce(core.wp_actor_org(p.work_package_id), wp.performing_organisation_id));
  r := jsonb_build_object('permit_id', p_permit_id, 'expected_version', p_expected_version, 'responses', p_responses);
  v := core.authorised_or_refusal(v_action, t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if p.status <> 'more_information_required' or q.id is null then
    return core.refuse(v_action, 'not_open', 'There is no information request waiting for an answer.', 'An open request', 'Nobody');
  end if;
  problems := core.permit_draft_problems(p_permit_id);
  if jsonb_typeof(p_responses) is distinct from 'array' or jsonb_array_length(p_responses) <> jsonb_array_length(q.items)
     or exists (select 1 from jsonb_array_elements(p_responses) x where length(btrim(coalesce(x #>> '{}', ''))) = 0) then
    problems := problems || text 'Answer every item of the information request.';
  end if;
  if cardinality(problems) > 0 then
    return core.refuse(v_action, 'not_ready', 'The response is not ready to send.', 'Each item listed', 'You',
                       jsonb_build_object('problems', to_jsonb(problems)));
  end if;
  v := authz.require(v_action, t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ctx := (v ->> 'decision_context_id')::uuid;
  pv := core.new_permit_version(p, (v ->> 'actor_person_id')::uuid, ctx, q.id);
  insert into core.rfi_response (customer_id, venue_id, rfi_id, permit_version_id, responses, responder_person_id)
  values (p.customer_id, p.venue_id, q.id, pv.id, p_responses, (v ->> 'actor_person_id')::uuid);
  perform core.transition('core.permit', p.id, 'under_review', p_expected_version, ctx, jsonb_build_object('current_version_id', pv.id));
  return v || jsonb_build_object('version_id', pv.id, 'version_no', pv.version_no);
end $$;

create function api.cancel_permit(p_idempotency_key text, p_permit_id uuid, p_expected_version integer, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p core.permit; wp core.work_package; v_action text; t jsonb; r jsonb; v jsonb;
begin
  select * into p from core.permit where id = p_permit_id;
  select * into wp from core.work_package where id = p.work_package_id;
  v_action := core.wp_action('permit.cancel', p.work_package_id, p.customer_id);
  t := core.permit_target(p, p_permit_id, 'permit', coalesce(core.wp_actor_org(p.work_package_id), wp.performing_organisation_id));
  r := jsonb_build_object('permit_id', p_permit_id, 'expected_version', p_expected_version, 'reason', p_reason);
  v := core.authorised_or_refusal(v_action, t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if length(btrim(coalesce(p_reason, ''))) = 0 then
    return core.refuse(v_action, 'invalid_content', 'Say why the request is being cancelled.', 'A reason', 'You');
  end if;
  v := authz.require(v_action, t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.permit', p.id, 'cancelled', p_expected_version, (v ->> 'decision_context_id')::uuid);
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Deciding steps (Q76-Q83)
-- ---------------------------------------------------------------------------
create function core.step_action(p_kind text) returns text
language sql immutable set search_path = '' as $$
  select case p_kind when 'occupier' then 'permit_step.decide_occupier'
                     when 'landlord_operator' then 'permit_step.decide_landlord'
                     when 'external' then 'permit_step.record_external'
                     else 'permit_step.decide' end $$;

-- Review and external steps need an appointment covering the class; occupier and
-- landlord steps are about the place and its systems, not the class.
create function core.step_target(s core.permit_step, p core.permit, p_record_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select core.permit_target(p, p_record_id, 'step_decision', null)
         || jsonb_build_object('area_id', s.area_ids[1], 'area_ids', to_jsonb(s.area_ids), 'system_ids', to_jsonb(s.system_ids),
                               'excluded_person_ids', core.permit_people(p.id))
         || case when s.kind in ('review', 'external') then jsonb_build_object('permit_class_id', p.permit_class_id) else '{}'::jsonb end $$;

create function api.decide_step(p_idempotency_key text, p_step_id uuid, p_outcome text, p_reason text,
                                p_scope_wording text default null, p_conditions jsonb default '[]',
                                p_rfi jsonb default null, p_external jsonb default null,
                                p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  s core.permit_step; p core.permit; v_id uuid := gen_random_uuid(); v_action text; t jsonb; r jsonb; v jsonb; ctx uuid;
  problem text; c jsonb;
begin
  if p_outcome not in ('no_further_comments', 'conditions', 'more_information', 'refused', 'not_applicable') then
    raise exception 'outcome must be no_further_comments, conditions, more_information, refused or not_applicable' using errcode = '22023';
  end if;
  select * into s from core.permit_step where id = p_step_id;
  select p2.* into p from core.permit p2 join core.permit_version pv on pv.permit_id = p2.id where pv.id = s.permit_version_id;
  v_action := core.step_action(s.kind);
  t := core.step_target(s, p, v_id);
  r := jsonb_build_object('step_id', p_step_id, 'outcome', p_outcome, 'reason', p_reason, 'scope_wording', p_scope_wording,
                          'conditions', p_conditions, 'rfi', p_rfi, 'external', p_external);
  v := core.authorised_or_refusal(v_action, t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  -- One decision at a time per permit, so two reviewers cannot settle the same step.
  perform 1 from core.permit where id = p.id for update;
  if not core.step_open(p_step_id) then
    return core.refuse(v_action, 'step_not_open',
      'This step cannot be decided now: it is decided already, an earlier step is still open, or the request has changed.',
      'An open step on the current version', 'Whoever holds the earlier step, or the applicant');
  end if;
  problem := case
    when length(btrim(coalesce(p_reason, ''))) = 0 then 'Give the reason for the decision.'
    when p_outcome in ('no_further_comments', 'conditions') then core.wording_problem(p_scope_wording)
    when p_outcome = 'more_information' and (jsonb_typeof(p_rfi -> 'items') is distinct from 'array'
                                             or jsonb_array_length(p_rfi -> 'items') = 0
                                             or length(btrim(coalesce(p_rfi ->> 'message', ''))) = 0)
      then 'Say what information is needed: a message and at least one item.' end;
  if problem is null and p_outcome = 'conditions' and (jsonb_typeof(p_conditions) is distinct from 'array'
                                                        or jsonb_array_length(p_conditions) = 0
                                                        or exists (select 1 from jsonb_array_elements(p_conditions) x
                                                                    where length(btrim(coalesce(x ->> 'text', ''))) = 0
                                                                       or jsonb_typeof(x -> 'acknowledge') is distinct from 'boolean')) then
    problem := 'List each condition, and whether the supervisor must acknowledge it at acceptance.';
  end if;
  if problem is null and s.kind = 'external' and p_outcome <> 'not_applicable'
     and (length(btrim(coalesce(p_external ->> 'decider', ''))) = 0 or length(btrim(coalesce(p_external ->> 'organisation', ''))) = 0
          or length(btrim(coalesce(p_external ->> 'scope', ''))) = 0 or (p_external ->> 'decided_on') is null) then
    problem := 'Record the external decision: who made it, their organisation, what it covers and when (Q82).';
  end if;
  if problem is not null then
    return core.refuse(v_action, 'invalid_content', problem, 'A complete decision', 'You');
  end if;
  v := authz.require(v_action, t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ctx := (v ->> 'decision_context_id')::uuid;
  insert into core.step_decision (id, customer_id, venue_id, permit_step_id, outcome, reason, scope_wording, decider_person_id,
                                  decision_context_id)
  values (v_id, s.customer_id, s.venue_id, s.id, p_outcome, p_reason, nullif(btrim(coalesce(p_scope_wording, '')), ''),
          (v ->> 'actor_person_id')::uuid, ctx);
  if p_outcome = 'conditions' then
    for c in select * from jsonb_array_elements(p_conditions) loop
      insert into core.permit_condition (customer_id, venue_id, step_decision_id, text, acknowledge_at_acceptance)
      values (s.customer_id, s.venue_id, v_id, c ->> 'text', (c ->> 'acknowledge')::boolean);
    end loop;
  end if;
  if p_outcome = 'more_information' then
    insert into core.rfi (customer_id, venue_id, step_decision_id, permit_version_id, message, items)
    values (s.customer_id, s.venue_id, v_id, s.permit_version_id, p_rfi ->> 'message', p_rfi -> 'items');
  end if;
  if s.kind = 'external' and p_outcome <> 'not_applicable' then
    insert into core.external_decision (customer_id, venue_id, step_decision_id, external_decider, external_organisation,
                                        reference, scope, decided_on, conditions, document_version_ids)
    values (s.customer_id, s.venue_id, v_id, p_external ->> 'decider', p_external ->> 'organisation', p_external ->> 'reference',
            p_external ->> 'scope', (p_external ->> 'decided_on')::date, p_external ->> 'conditions',
            coalesce((select array_agg(x::uuid) from jsonb_array_elements_text(p_external -> 'document_version_ids') x), '{}'));
  end if;
  perform core.settle_permit(p.id, ctx);
  return v || jsonb_build_object('permit_status', (select status from core.permit where id = p.id));
end $$;

-- Q83: before issue, a decider can withdraw their own decision; the permit returns to review.
create function api.reopen_step(p_idempotency_key text, p_step_id uuid, p_reason text,
                                p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s core.permit_step; p core.permit; d core.step_decision; v_id uuid := gen_random_uuid(); v_action text; t jsonb; r jsonb; v jsonb; ctx uuid;
begin
  select * into s from core.permit_step where id = p_step_id;
  select p2.* into p from core.permit p2 join core.permit_version pv on pv.permit_id = p2.id where pv.id = s.permit_version_id;
  d := core.latest_decision(p_step_id);
  v_action := core.step_action(s.kind);
  t := core.step_target(s, p, v_id);
  r := jsonb_build_object('step_id', p_step_id, 'outcome', 'reopened', 'reason', p_reason);
  v := core.authorised_or_refusal(v_action, t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  perform 1 from core.permit where id = p.id for update;
  if d.id is null or not core.favourable(d.outcome) or p.current_version_id <> s.permit_version_id
     or p.status not in ('submitted', 'under_review', 'approved_for_issue') then
    return core.refuse(v_action, 'not_open', 'Only a standing decision on a request that is not yet issued can be withdrawn.',
                       'A standing decision', 'Nobody');
  end if;
  if d.decider_person_id is distinct from authz.actor_person(p.customer_id) then
    return core.refuse(v_action, 'not_decider', 'Only the person who made a decision can withdraw it.',
                       'The original decider', 'The person who made the decision');
  end if;
  if length(btrim(coalesce(p_reason, ''))) = 0 then
    return core.refuse(v_action, 'invalid_content', 'Say why the decision is being withdrawn.', 'A reason', 'You');
  end if;
  v := authz.require(v_action, t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ctx := (v ->> 'decision_context_id')::uuid;
  insert into core.step_decision (id, customer_id, venue_id, permit_step_id, outcome, reason, decider_person_id, decision_context_id)
  values (v_id, s.customer_id, s.venue_id, s.id, 'reopened', p_reason, (v ->> 'actor_person_id')::uuid, ctx);
  perform core.settle_permit(p.id, ctx);
  return v || jsonb_build_object('permit_status', (select status from core.permit where id = p.id));
end $$;

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------
create view api.permit_class_version with (security_invoker = true) as
  select id, customer_id, venue_id, permit_class_id, version_no, status, content, source_ref, authored_by_person_id,
         proposed_by_person_id, decided_by_person_id, decided_at, decision_reason, encode(content_sha256, 'hex') as content_sha256,
         row_version, created_at
    from core.permit_class_version;
create view api.area_occupation      with (security_invoker = true) as select * from core.area_occupation;
create view api.class_requirement    with (security_invoker = true) as select * from core.class_requirement;
create view api.permit               with (security_invoker = true) as select * from core.permit;
create view api.permit_draft         with (security_invoker = true) as select * from core.permit_draft;
create view api.permit_version       with (security_invoker = true) as
  select id, customer_id, venue_id, permit_id, version_no, revision_id, class_version_id, answers,
         lower(planned_window) as window_from, upper(planned_window) as window_to, document_version_ids, declaration,
         declared_by_person_id, responds_to_rfi_id, created_at
    from core.permit_version;
create view api.permit_step          with (security_invoker = true) as select * from core.permit_step;
create view api.step_decision        with (security_invoker = true) as select * from core.step_decision;
create view api.permit_condition     with (security_invoker = true) as select * from core.permit_condition;
create view api.external_decision    with (security_invoker = true) as select * from core.external_decision;
create view api.rfi                  with (security_invoker = true) as select * from core.rfi;
create view api.rfi_response         with (security_invoker = true) as select * from core.rfi_response;

grant select on all tables in schema api to authenticated;
grant execute on all functions in schema api to authenticated;
revoke execute on all functions in schema api from anon, public;
