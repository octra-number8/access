-- 0043 Hand-back, closure and emergency work API (phase 6c, D-019)
--
-- Same pattern as before. Hand-back is submitted by the supervisor (or, for a stopped or
-- expired job whose contractor has gone, started by an issuer), and accepted or rejected
-- by an appointed acceptor who is not connected with the job and did not submit it.
-- Acceptance closes the permit, which the database refuses while any duty is outstanding,
-- and freezes the close-out snapshot.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

-- ---------------------------------------------------------------------------
-- Hand-back (Q113, Q114, Q116, P6-10)
-- ---------------------------------------------------------------------------
create function api.hand_back_permit(p_idempotency_key text, p_permit_id uuid, p_expected_version integer, p_work_complete boolean,
                                     p_remaining_work text, p_area_state text, p_all_workers_out boolean,
                                     p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p core.permit; v_action text; decl jsonb; t jsonb; r jsonb; v jsonb; ctx uuid; h_id uuid := gen_random_uuid(); live jsonb;
begin
  set constraints core.live_dependency_check deferred;
  select * into p from core.permit where id = p_permit_id;
  v_action := case when exists (select 1 from core.permit_team_member m where m.permit_id = p.id and m.role = 'supervisor' and m.removed_at is null
                                   and m.person_id = authz.actor_person(p.customer_id))
                   then 'permit.hand_back_submit' else 'permit.close_out_for_issuer' end;
  t := core.live_target(p, case when v_action = 'permit.close_out_for_issuer' then core.permit_people(p.id) else '[]' end);
  r := jsonb_build_object('permit_id', p_permit_id, 'expected_version', p_expected_version, 'complete', p_work_complete, 'remaining', p_remaining_work,
                          'area_state', p_area_state, 'workers_out', p_all_workers_out);
  v := core.authorised_or_refusal(v_action, t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  v := core.stale(v_action, p, p_expected_version);
  if v is not null then return v; end if;
  if p.status not in ('active', 'suspended', 'expired') or (v_action = 'permit.close_out_for_issuer' and p.status = 'active') then
    return core.refuse(v_action, 'not_handbackable',
      case when v_action = 'permit.close_out_for_issuer' then 'An issuer starts a close-out only for a stopped or expired permit; an active permit is handed back by its supervisor.'
           else 'Only an active, stopped or expired permit is handed back.' end,
      'A permit in the right state', 'The permit''s supervisor');
  end if;
  decl := core.class_content(p) -> 'hand_back_declaration';
  if decl is null or jsonb_array_length(decl) = 0 then
    return core.refuse(v_action, 'not_configured', 'This class''s configuration has no hand-back declaration, so it cannot be handed back yet.',
                       'A configuration with a hand-back declaration (Q113)', 'The venue, by approving a new configuration');
  end if;
  live := (select jsonb_agg(pc.name) from core.permit c join core.permit_class pc on pc.id = c.permit_class_id
            where c.parent_permit_id = p.id and c.status in ('issued_awaiting_acceptance', 'active'));
  if live is not null then
    return core.refuse(v_action, 'children_live', 'The Work Approval is handed back after the permits under it: these are still live.',
                       'Each permit listed handed back or stopped', 'Their supervisors', jsonb_build_object('permits', live));
  end if;
  if p_work_complete is null or core.blank(p_area_state) or not coalesce(p_all_workers_out, false)
     or (not p_work_complete and core.blank(p_remaining_work)) then
    return core.refuse(v_action, 'invalid_content',
      'Say whether the work is complete (and what remains if not), the state the area is left in, and confirm everyone is out.',
      'The hand-back details', 'You');
  end if;
  v := authz.require(v_action, t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ctx := (v ->> 'decision_context_id')::uuid;
  insert into core.hand_back (id, customer_id, venue_id, permit_id, from_status, route, declaration, declaration_sha256, work_complete, remaining_work,
                              area_state, all_workers_out, submitted_by_person_id, decision_context_id)
  values (h_id, p.customer_id, p.venue_id, p.id, p.status, case v_action when 'permit.hand_back_submit' then 'supervisor' else 'issuer_close_out' end,
          decl, sha256(convert_to(decl::text, 'UTF8')), p_work_complete, nullif(btrim(coalesce(p_remaining_work, '')), ''), p_area_state, true,
          (v ->> 'actor_person_id')::uuid, ctx);
  perform core.transition('core.permit', p.id, 'hand_back_pending', p_expected_version, ctx);
  perform core.check_live_now();
  return v || jsonb_build_object('hand_back_id', h_id, 'duties', core.hand_back_duties(p.id));
end $$;

-- Everything the closure relied on, frozen.
create function core.close_out_content(p_permit_id uuid, p_decision jsonb) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'permit', jsonb_build_object('id', p.id, 'kind', p.kind, 'class', (select jsonb_build_object('id', id, 'code', code, 'name', name)
                                                                      from core.permit_class where id = p.permit_class_id),
                                 'parent_permit_id', p.parent_permit_id, 'job_reference', (select reference from core.work_package where id = p.work_package_id)),
    'issue_snapshots', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'sha256', encode(s.content_sha256, 'hex'), 'issued_at', s.issued_at)
                                                  order by s.issued_at), '[]') from core.issue_snapshot s where s.permit_id = p.id),
    'acceptances', (select coalesce(jsonb_agg(jsonb_build_object('at', a.accepted_at, 'by', a.supervisor_person_id, 'briefed', to_jsonb(a.briefed_person_ids))
                                              order by a.accepted_at), '[]')
                      from core.permit_acceptance a join core.issue_snapshot s on s.id = a.issue_snapshot_id where s.permit_id = p.id),
    'extensions', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'sha256', encode(e.content_sha256, 'hex'), 'previous_end', e.previous_end,
                                                                'new_end', e.new_end, 'acknowledged_at', e.acknowledged_at) order by e.created_at), '[]')
                     from core.permit_extension e where e.permit_id = p.id),
    'live', core.permit_live(p.id),
    'controls', core.permit_controls(p.id),
    'control_links', (select coalesce(jsonb_agg(jsonb_build_object('kind', l.control_kind, 'control_id', l.control_id, 'linked_at', l.created_at,
                                                                   'unlinked_at', l.unlinked_at, 'unlinked_reason', l.unlinked_reason,
                                                                   'events', (select coalesce(jsonb_agg(jsonb_build_object('step', e.step, 'by', e.person_id, 'at', e.created_at,
                                                                                                                          'content', e.content) order by e.created_at), '[]')
                                                                                from core.control_event e where e.control_kind = l.control_kind and e.control_id = l.control_id))
                                                  order by l.created_at), '[]')
                        from core.control_link_record l where l.permit_id = p.id),
    'area_returns', (select coalesce(jsonb_agg(jsonb_build_object('areas', to_jsonb(x.area_ids), 'outcome', x.outcome, 'decided_at', x.decided_at)
                                               order by x.created_at), '[]') from core.area_return x where x.permit_id = p.id),
    'hand_backs', (select coalesce(jsonb_agg(jsonb_build_object('id', h.id, 'from', h.from_status, 'route', h.route, 'declaration', h.declaration,
                                                                'work_complete', h.work_complete, 'remaining_work', h.remaining_work, 'area_state', h.area_state,
                                                                'by', h.submitted_by_person_id, 'at', h.created_at,
                                                                'decision', (select to_jsonb(d) - 'customer_id' - 'venue_id' - 'created_by_user_id'
                                                                               from core.hand_back_decision d where d.hand_back_id = h.id))
                                               order by h.created_at), '[]') from core.hand_back h where h.permit_id = p.id),
    'abandoned', (select jsonb_agg(jsonb_build_object('reason', a.reason, 'by', a.flagged_by_person_id, 'at', a.created_at))
                    from core.permit_abandonment a where a.permit_id = p.id),
    'emergency', (select jsonb_build_object('id', e.id, 'reference', e.reference) from core.emergency_work e where e.work_package_id = p.work_package_id),
    'closing_decision', p_decision,
    'closed_at', clock_timestamp())
  from core.permit p where p.id = p_permit_id $$;

-- Accepting (closes) or rejecting (back to where it was) a hand-back (Q114). Never by
-- anyone connected with the job, nor whoever submitted it.
create function api.decide_hand_back(p_idempotency_key text, p_permit_id uuid, p_expected_version integer, p_outcome text, p_inspection text,
                                     p_reason text, p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p core.permit; h core.hand_back; t jsonb; r jsonb; v jsonb; ctx uuid; duties jsonb; back text; content jsonb;
begin
  set constraints core.live_dependency_check deferred;
  select * into p from core.permit where id = p_permit_id;
  select * into h from core.hand_back where permit_id = p.id and not exists (select 1 from core.hand_back_decision d where d.hand_back_id = hand_back.id)
   order by created_at desc limit 1;
  t := core.live_target(p, core.permit_people(p.id) || coalesce(jsonb_build_array(h.submitted_by_person_id), '[]'));
  r := jsonb_build_object('permit_id', p_permit_id, 'expected_version', p_expected_version, 'outcome', p_outcome, 'inspection', p_inspection, 'reason', p_reason);
  v := core.authorised_or_refusal('permit.hand_back_accept', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  v := core.stale('permit.hand_back_accept', p, p_expected_version);
  if v is not null then return v; end if;
  if p.status <> 'hand_back_pending' or h.id is null then
    return core.refuse('permit.hand_back_accept', 'not_pending', 'This permit is not waiting for its hand-back to be accepted.', 'A pending hand-back', 'Nobody');
  end if;
  if coalesce(p_outcome, '') not in ('accept', 'reject') or coalesce(p_inspection, '') not in ('in_person', 'remote') or core.blank(p_reason) then
    return core.refuse('permit.hand_back_accept', 'invalid_content', 'Accept or reject, say how it was inspected, and give your reason.', 'A decision', 'You');
  end if;
  if p_inspection = 'remote' and coalesce(core.class_content(p) ->> 'hand_back_inspection', 'in_person') <> 'remote_allowed' then
    return core.refuse('permit.hand_back_accept', 'inspection_in_person', 'This class''s hand-back must be inspected in person.', 'An inspection in person', 'You');
  end if;
  duties := core.hand_back_duties(p.id);
  if p_outcome = 'accept' and jsonb_array_length(duties) > 0 then
    return core.refuse('permit.hand_back_accept', 'duties_outstanding', 'The permit cannot close: duties are still outstanding (invariant 8).',
                       'Each duty listed resolved', 'As listed for each duty', jsonb_build_object('duties', duties));
  end if;
  v := authz.require('permit.hand_back_accept', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ctx := (v ->> 'decision_context_id')::uuid;
  insert into core.hand_back_decision (customer_id, venue_id, hand_back_id, outcome, inspection, reason, decider_person_id, decision_context_id)
  values (p.customer_id, p.venue_id, h.id, case p_outcome when 'accept' then 'accepted' else 'rejected' end, p_inspection, p_reason,
          (v ->> 'actor_person_id')::uuid, ctx);
  if p_outcome = 'accept' then
    content := core.close_out_content(p.id, jsonb_build_object('decider', v ->> 'actor_person_id', 'appointment_id', v -> 'acting_appointment_id',
                                                               'delegation_id', v -> 'acting_delegation_id', 'inspection', p_inspection, 'reason', p_reason));
    insert into core.close_out_snapshot (customer_id, venue_id, permit_id, content, content_sha256, decision_context_id)
    values (p.customer_id, p.venue_id, p.id, content, sha256(convert_to(content::text, 'UTF8')), ctx);
    perform core.transition('core.permit', p.id, 'closed', p_expected_version, ctx);
  else
    -- Back to where it was; a permit whose window has ended returns as expired; a Work
    -- Approval with a held permit under it returns stopped (invariant 4).
    back := case when h.from_status = 'active' and now() >= core.permit_window_end(p.id) then 'expired'
                 when h.from_status = 'active' and exists (select 1 from core.permit c where c.parent_permit_id = p.id and core.permit_holding(c.id)) then 'suspended'
                 else h.from_status end;
    perform core.transition('core.permit', p.id, back, p_expected_version, ctx);
  end if;
  perform core.check_live_now();
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Partial hand-back of areas (Q115, P6-12)
-- ---------------------------------------------------------------------------
-- The areas still in the live scope: the job's areas less those returned and accepted.
create function core.live_area_ids(p_permit_id uuid) returns uuid[]
language sql stable security definer set search_path = '' as $$
  select array(select x.area_id from core.permit p join core.permit_version v on v.id = p.current_version_id
                 join core.work_package_area x on x.revision_id = v.revision_id
                where p.id = p_permit_id
                  and not exists (select 1 from core.area_return r where r.permit_id = p.id and r.outcome = 'accepted' and x.area_id = any (r.area_ids))
                order by x.area_id) $$;

create function api.return_areas(p_idempotency_key text, p_permit_id uuid, p_expected_version integer, p_area_ids uuid[], p_area_state text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p core.permit; live uuid[]; t jsonb; r jsonb; v jsonb; problems text[] := '{}'; a_id uuid := gen_random_uuid();
begin
  select * into p from core.permit where id = p_permit_id;
  live := core.live_area_ids(p.id);
  t := core.live_target(p);
  r := jsonb_build_object('permit_id', p_permit_id, 'expected_version', p_expected_version, 'areas', to_jsonb(p_area_ids), 'area_state', p_area_state);
  v := core.authorised_or_refusal('permit.return_areas', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  v := core.stale('permit.return_areas', p, p_expected_version);
  if v is not null then return v; end if;
  if p.status not in ('active', 'suspended') then
    return core.refuse('permit.return_areas', 'not_live', 'Areas are returned from a live permit; otherwise hand the whole permit back.', 'A live permit', 'Nobody');
  end if;
  if cardinality(coalesce(p_area_ids, '{}')) = 0 or not (p_area_ids <@ live) then
    problems := problems || text 'Choose areas the permit still covers.';
  elsif live <@ p_area_ids then
    problems := problems || text 'Returning every area is handing the permit back: use hand-back instead.';
  end if;
  if exists (select 1 from core.area_return x where x.permit_id = p.id and x.outcome is null) then
    problems := problems || text 'An earlier return of areas is still waiting for a decision.';
  end if;
  if exists (select 1 from core.exclusion_zone z where z.permit_id = p.id and z.status = 'set_up' and z.area_id = any (coalesce(p_area_ids, '{}'))) then
    problems := problems || text 'An exclusion zone is still in place in a returned area: remove it first.';
  end if;
  if exists (select 1 from core.custody_movement m join core.custody_item c on c.id = m.item_id
              where m.permit_id = p.id and m.returned_at is null and c.area_id = any (coalesce(p_area_ids, '{}'))) then
    problems := problems || text 'A key or pass for a returned area is still out: return it first.';
  end if;
  if core.blank(p_area_state) then problems := problems || text 'Describe the state the areas are left in.'; end if;
  if cardinality(problems) > 0 then
    return core.refuse('permit.return_areas', 'not_ready', 'These areas cannot be returned yet.', 'Each item listed', 'You',
                       jsonb_build_object('problems', to_jsonb(problems)));
  end if;
  v := authz.require('permit.return_areas', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.area_return (id, customer_id, venue_id, permit_id, area_ids, area_state, submitted_by_person_id, decision_context_id)
  values (a_id, p.customer_id, p.venue_id, p.id, p_area_ids, p_area_state, (v ->> 'actor_person_id')::uuid, (v ->> 'decision_context_id')::uuid);
  return v || jsonb_build_object('area_return_id', a_id);
end $$;

create function api.decide_area_return(p_idempotency_key text, p_area_return_id uuid, p_outcome text, p_reason text,
                                       p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare a core.area_return; p core.permit; t jsonb; r jsonb; v jsonb;
begin
  select * into a from core.area_return where id = p_area_return_id;
  select * into p from core.permit where id = a.permit_id;
  t := core.live_target(p, core.permit_people(p.id) || coalesce(jsonb_build_array(a.submitted_by_person_id), '[]'));
  r := jsonb_build_object('area_return_id', p_area_return_id, 'outcome', p_outcome, 'reason', p_reason);
  v := core.authorised_or_refusal('permit.hand_back_accept', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if a.outcome is not null then
    return core.refuse('permit.hand_back_accept', 'already_decided', 'This return of areas has already been decided.', 'A pending return', 'Nobody');
  end if;
  if coalesce(p_outcome, '') not in ('accept', 'reject') or core.blank(p_reason) then
    return core.refuse('permit.hand_back_accept', 'invalid_content', 'Accept or reject, with your reason.', 'A decision', 'You');
  end if;
  v := authz.require('permit.hand_back_accept', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  update core.area_return set outcome = case p_outcome when 'accept' then 'accepted' else 'rejected' end, decided_by_person_id = (v ->> 'actor_person_id')::uuid,
                              decision_reason = p_reason, decided_at = clock_timestamp(), decided_decision_context_id = (v ->> 'decision_context_id')::uuid
   where id = a.id;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Cancelled and abandoned (Q117)
-- ---------------------------------------------------------------------------
create function api.cancel_issued_permit(p_idempotency_key text, p_permit_id uuid, p_expected_version integer, p_reason text,
                                         p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p core.permit; t jsonb; r jsonb; v jsonb; duties jsonb;
begin
  select * into p from core.permit where id = p_permit_id;
  t := core.live_target(p, core.permit_people(p.id));
  r := jsonb_build_object('permit_id', p_permit_id, 'expected_version', p_expected_version, 'reason', p_reason);
  v := core.authorised_or_refusal('permit.cancel_issued', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  v := core.stale('permit.cancel_issued', p, p_expected_version);
  if v is not null then return v; end if;
  if p.status <> 'issued_awaiting_acceptance' then
    return core.refuse('permit.cancel_issued', 'not_cancellable',
      'Only an issued permit not yet accepted can be cancelled; once work has been authorised it is handed back.', 'A permit awaiting acceptance', 'Nobody');
  end if;
  duties := core.hand_back_duties(p.id);
  if jsonb_array_length(duties) > 0 then
    return core.refuse('permit.cancel_issued', 'duties_outstanding', 'Controls or items are still in place for this permit, so it cannot simply be cancelled.',
                       'Each duty listed resolved', 'As listed for each duty', jsonb_build_object('duties', duties));
  end if;
  if core.blank(p_reason) then
    return core.refuse('permit.cancel_issued', 'invalid_content', 'Say why the permit is cancelled.', 'A reason', 'You');
  end if;
  v := authz.require('permit.cancel_issued', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.permit', p.id, 'cancelled', p_expected_version, (v ->> 'decision_context_id')::uuid);
  return v;
end $$;

create function api.flag_abandoned(p_idempotency_key text, p_permit_id uuid, p_reason text,
                                   p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p core.permit; t jsonb; r jsonb; v jsonb;
begin
  select * into p from core.permit where id = p_permit_id;
  t := core.live_target(p, core.permit_people(p.id));
  r := jsonb_build_object('permit_id', p_permit_id, 'reason', p_reason);
  v := core.authorised_or_refusal('permit.flag_abandoned', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if p.status not in ('suspended', 'expired') then
    return core.refuse('permit.flag_abandoned', 'not_stopped', 'Only a stopped or expired job is flagged abandoned.', 'A stopped or expired permit', 'Nobody');
  end if;
  if core.blank(p_reason) then
    return core.refuse('permit.flag_abandoned', 'invalid_content', 'Say why the job is abandoned.', 'A reason', 'You');
  end if;
  v := authz.require('permit.flag_abandoned', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.permit_abandonment (customer_id, venue_id, permit_id, reason, flagged_by_person_id, decision_context_id)
  values (p.customer_id, p.venue_id, p.id, p_reason, (v ->> 'actor_person_id')::uuid, (v ->> 'decision_context_id')::uuid);
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Continuing controls (Q141, Q147, invariant 8): a named authority takes ownership; the
-- control's links to permits end, and it lives on as a separately owned control. Only
-- once no permit it protects is live, and with no personal lock on.
-- ---------------------------------------------------------------------------
create function api.transfer_control(p_idempotency_key text, p_kind text, p_control_id uuid, p_reason text, p_review_on date,
                                     p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare sys uuid; cst uuid; vn uuid; st text; t jsonb; r jsonb; v jsonb; v_action text := coalesce(p_kind, '') || '.transfer'; live jsonb; ctx uuid;
begin
  if p_kind = 'isolation' then select system_id, customer_id, venue_id, status into sys, cst, vn, st from core.isolation where id = p_control_id;
  elsif p_kind = 'impairment' then select system_id, customer_id, venue_id, status into sys, cst, vn, st from core.impairment where id = p_control_id;
  else v_action := 'isolation.transfer'; end if;
  t := core.system_target(sys, p_control_id, coalesce(p_kind, 'isolation'), core.control_people(coalesce(p_kind, 'isolation'), p_control_id));
  r := jsonb_build_object('kind', p_kind, 'control_id', p_control_id, 'reason', p_reason, 'review_on', p_review_on);
  v := core.authorised_or_refusal(v_action, t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if not ((p_kind = 'isolation' and st in ('applied', 'proved')) or (p_kind = 'impairment' and st in ('impaired', 'tested'))) then
    return core.refuse(v_action, 'not_in_place', 'Only a control in place is transferred; one not yet in place is withdrawn.', 'A control in place', 'Nobody');
  end if;
  live := (select jsonb_agg(w.reference) from core.control_link l join core.permit pp on pp.id = l.permit_id join core.work_package w on w.id = pp.work_package_id
            where l.control_kind = p_kind and l.control_id = p_control_id and core.is_live(pp.status));
  if live is not null then
    return core.refuse(v_action, 'permits_live', 'A permit this control protects is still live: it is transferred at hand-back, not while work relies on it.',
                       'Each permit handed back', 'The permit''s supervisor', jsonb_build_object('jobs', live));
  end if;
  if p_kind = 'isolation' and exists (select 1 from core.isolation_lock where isolation_id = p_control_id and off_at is null) then
    return core.refuse(v_action, 'locks_on', 'Personal locks are still on: they belong to the people doing the work and come off before the isolation continues alone.',
                       'Every personal lock off', 'Each lock holder, or the isolation authority for an absent holder');
  end if;
  if core.blank(p_reason) or p_review_on is null or p_review_on < current_date then
    return core.refuse(v_action, 'invalid_content', 'Say why the control must continue, and when it will next be reviewed.', 'A reason and review date', 'You');
  end if;
  v := authz.require(v_action, t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ctx := (v ->> 'decision_context_id')::uuid;
  insert into core.control_ownership (customer_id, venue_id, control_kind, control_id, owner_person_id, reason, review_on, decision_context_id)
  values (cst, vn, p_kind, p_control_id, (v ->> 'actor_person_id')::uuid, p_reason, p_review_on, ctx);
  update core.control_link_record set unlinked_at = clock_timestamp(), unlinked_reason = 'Transferred to a continuing owner: ' || p_reason,
                                      unlink_decision_context_id = ctx
   where control_kind = p_kind and control_id = p_control_id and unlinked_at is null;
  perform core.add_control_event(p_kind, p_control_id, cst, vn, 'transfer', (v ->> 'actor_person_id')::uuid,
                                 jsonb_build_object('reason', p_reason, 'review_on', p_review_on));
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Emergency work (Q91, Q92, Q94-Q97, P6-11)
-- ---------------------------------------------------------------------------
create function api.publish_emergency_config(p_idempotency_key text, p_venue_id uuid, p_categories text[], p_retrospective_hours numeric,
                                             p_effective_from timestamptz, p_change_reason text,
                                             p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare vn core.venue; t jsonb; r jsonb; v jsonb; c_id uuid := gen_random_uuid();
begin
  select * into vn from core.venue where id = p_venue_id;
  t := jsonb_build_object('customer_id', vn.customer_id, 'venue_id', vn.id, 'record_id', c_id, 'target_type', 'emergency_config_version');
  r := jsonb_build_object('venue_id', p_venue_id, 'categories', to_jsonb(p_categories), 'hours', p_retrospective_hours, 'from', p_effective_from, 'reason', p_change_reason);
  v := core.authorised_or_refusal('emergency_config.publish', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if cardinality(coalesce(p_categories, '{}')) = 0 or exists (select 1 from unnest(p_categories) c where core.blank(c))
     or p_retrospective_hours is null or p_retrospective_hours <= 0 or p_effective_from is null or core.blank(p_change_reason) then
    return core.refuse('emergency_config.publish', 'invalid_content',
      'Define the categories of emergency and urgent make-safe work (Q91), the hours within which the retrospective permit is due (Q97), the date it takes effect and its source. None has a default.',
      'Each detail', 'You');
  end if;
  v := authz.require('emergency_config.publish', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.emergency_config_version (id, customer_id, venue_id, categories, retrospective_hours, owner_person_id, effective_from, change_reason, decision_context_id)
  values (c_id, vn.customer_id, vn.id, p_categories, p_retrospective_hours, (v ->> 'actor_person_id')::uuid, p_effective_from, p_change_reason,
          (v ->> 'decision_context_id')::uuid);
  return v || jsonb_build_object('config_id', c_id);
end $$;

-- Emergency work starts on this decision (Q92): an appointed authority covering every area
-- and system it touches. It is not a permit, and says so everywhere.
create function api.authorise_emergency(p_idempotency_key text, p_venue_id uuid, p_category text, p_description text, p_why_could_not_wait text,
                                        p_area_ids uuid[], p_system_ids uuid[], p_organisation_id uuid, p_person_ids uuid[], p_controls_applied text,
                                        p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare vn core.venue; cfg core.emergency_config_version; t jsonb; r jsonb; v jsonb; e_id uuid := gen_random_uuid(); problems text[] := '{}'; ref text;
begin
  select * into vn from core.venue where id = p_venue_id;
  t := jsonb_build_object('customer_id', vn.customer_id, 'venue_id', vn.id, 'record_id', e_id, 'target_type', 'emergency_work',
                          'area_id', (coalesce(p_area_ids, '{}'))[1], 'area_ids', to_jsonb(coalesce(p_area_ids, '{}')), 'system_ids', to_jsonb(coalesce(p_system_ids, '{}')));
  r := jsonb_build_object('venue_id', p_venue_id, 'category', p_category, 'description', p_description, 'why', p_why_could_not_wait,
                          'areas', to_jsonb(p_area_ids), 'systems', to_jsonb(p_system_ids), 'organisation_id', p_organisation_id,
                          'people', to_jsonb(p_person_ids), 'controls', p_controls_applied);
  v := core.authorised_or_refusal('emergency.authorise', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  select * into cfg from core.emergency_config_version where venue_id = vn.id and effective_from <= now() order by effective_from desc, created_at desc limit 1;
  if cfg.id is null then
    return core.refuse('emergency.authorise', 'not_configured',
      'The venue has not defined its emergency work categories and retrospective deadline (Q91, Q97), so emergency work cannot be authorised here.',
      'The venue''s emergency definitions', 'The venue''s technical authority');
  end if;
  if not (coalesce(p_category, '') = any (cfg.categories)) then problems := problems || text 'Choose one of the venue''s categories.'; end if;
  if core.blank(p_description) then problems := problems || text 'Describe the work.'; end if;
  if core.blank(p_why_could_not_wait) then problems := problems || text 'Say why the work could not wait for a permit (Q96).'; end if;
  if core.blank(p_controls_applied) then problems := problems || text 'Record the controls applied at the time (Q94).'; end if;
  if cardinality(coalesce(p_area_ids, '{}')) = 0 or exists (select 1 from unnest(p_area_ids) a where not exists (select 1 from core.area where id = a and venue_id = vn.id))
     or exists (select 1 from unnest(coalesce(p_system_ids, '{}')) s where not exists (select 1 from core.system where id = s and venue_id = vn.id)) then
    problems := problems || text 'Name the areas (and any systems) at this venue.';
  end if;
  if not exists (select 1 from core.organisation where id = p_organisation_id and customer_id = vn.customer_id) then
    problems := problems || text 'Name the organisation doing the work.';
  end if;
  if cardinality(coalesce(p_person_ids, '{}')) = 0
     or exists (select 1 from unnest(p_person_ids) x where not exists (select 1 from core.person where id = x and customer_id = vn.customer_id)) then
    problems := problems || text 'Name the people doing the work.';
  end if;
  if cardinality(problems) > 0 then
    return core.refuse('emergency.authorise', 'invalid_content', 'The emergency record has problems.', 'Each item listed', 'You',
                       jsonb_build_object('problems', to_jsonb(problems)));
  end if;
  v := authz.require('emergency.authorise', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ref := 'EM-' || to_char(now() at time zone vn.timezone, 'YYYYMMDD') || '-' ||
         lpad(((select count(*) from core.emergency_work where venue_id = vn.id) + 1)::text, 3, '0');
  insert into core.emergency_work (id, customer_id, venue_id, reference, config_version_id, category, description, why_could_not_wait, area_ids, system_ids,
                                   organisation_id, person_ids, controls_applied, authorised_by_person_id, deadline_at, decision_context_id)
  values (e_id, vn.customer_id, vn.id, ref, cfg.id, p_category, p_description, p_why_could_not_wait, p_area_ids, coalesce(p_system_ids, '{}'),
          p_organisation_id, p_person_ids, p_controls_applied, (v ->> 'actor_person_id')::uuid,
          clock_timestamp() + make_interval(secs => (cfg.retrospective_hours * 3600)::double precision), (v ->> 'decision_context_id')::uuid);
  return v || jsonb_build_object('emergency_id', e_id, 'reference', ref);
end $$;

-- The retrospective permit is a normal job by the organisation that did the work (Q97);
-- linking it makes the emergency's authoriser one of the job's people.
create function api.link_retrospective_job(p_idempotency_key text, p_emergency_id uuid, p_work_package_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e core.emergency_work; wp core.work_package; v_action text; t jsonb; r jsonb; v jsonb;
begin
  select * into e from core.emergency_work where id = p_emergency_id;
  select * into wp from core.work_package where id = p_work_package_id;
  v_action := case when e.organisation_id in (select authz.my_admin_organisation_ids()) then 'emergency.link_retrospective'
                   when e.customer_id in (select authz.my_admin_customer_ids()) then 'emergency.link_retrospective_for_venue'
                   else 'emergency.link_retrospective' end;
  t := jsonb_build_object('customer_id', e.customer_id, 'venue_id', e.venue_id, 'record_id', e.id, 'target_type', 'emergency_work',
                          'organisation_id', e.organisation_id);
  r := jsonb_build_object('emergency_id', p_emergency_id, 'work_package_id', p_work_package_id);
  v := core.authorised_or_refusal(v_action, t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if e.work_package_id is not null then
    return core.refuse(v_action, 'already_linked', 'This emergency work already has its retrospective job.', 'An unlinked emergency record', 'Nobody');
  end if;
  if wp.id is null or wp.venue_id <> e.venue_id or wp.performing_organisation_id <> e.organisation_id or wp.status = 'cancelled'
     or exists (select 1 from core.emergency_work x where x.work_package_id = wp.id) then
    return core.refuse(v_action, 'invalid_content', 'Link a current job at the same venue, performed by the organisation that did the emergency work.',
                       'A matching job', 'You');
  end if;
  v := authz.require(v_action, t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  update core.emergency_work set work_package_id = wp.id, linked_by_person_id = (v ->> 'actor_person_id')::uuid, linked_at = clock_timestamp(),
                                 link_decision_context_id = (v ->> 'decision_context_id')::uuid
   where id = e.id;
  return v;
end $$;

-- The register of emergency work (Q96): every record the caller can see, with its
-- retrospective permit's state and whether it is overdue.
create function api.emergency_register() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('ok', true, 'emergencies', coalesce(jsonb_agg(jsonb_build_object(
    'id', e.id, 'reference', e.reference, 'category', e.category, 'description', e.description, 'why_could_not_wait', e.why_could_not_wait,
    'organisation', (select legal_name from core.organisation where id = e.organisation_id), 'authorised_by', core.person_name(e.authorised_by_person_id),
    'at', e.created_at, 'deadline_at', e.deadline_at, 'venue_timezone', (select timezone from core.venue where id = e.venue_id),
    'job_reference', (select reference from core.work_package where id = e.work_package_id), 'work_package_id', e.work_package_id)
    || core.emergency_status(e) order by e.created_at desc), '[]'))
    from core.emergency_work e
   where e.customer_id in (select authz.my_admin_customer_ids()) or e.venue_id in (select authz.my_appointee_venue_ids())
      or e.organisation_id in (select authz.my_admin_organisation_ids()) $$;

-- ---------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------
create function core.permit_close_out(p_permit_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'duties', core.hand_back_duties(p.id),
    'live_area_ids', to_jsonb(core.live_area_ids(p.id)),
    'hand_back_declaration', core.class_content(p) -> 'hand_back_declaration',
    'hand_back_inspection', core.class_content(p) ->> 'hand_back_inspection',
    'hand_backs', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', h.id, 'from', h.from_status, 'route', h.route, 'work_complete', h.work_complete, 'remaining_work', h.remaining_work,
        'area_state', h.area_state, 'by', core.person_name(h.submitted_by_person_id), 'at', h.created_at,
        'decision', (select jsonb_build_object('outcome', d.outcome, 'inspection', d.inspection, 'reason', d.reason,
                                               'by', core.person_name(d.decider_person_id), 'at', d.created_at)
                       from core.hand_back_decision d where d.hand_back_id = h.id)) order by h.created_at desc), '[]')
      from core.hand_back h where h.permit_id = p.id),
    'area_returns', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', x.id, 'areas', (select jsonb_agg(a.name order by a.name) from core.area a where a.id = any (x.area_ids)), 'area_state', x.area_state,
        'by', core.person_name(x.submitted_by_person_id), 'at', x.created_at, 'outcome', x.outcome, 'decided_by', core.person_name(x.decided_by_person_id),
        'reason', x.decision_reason) order by x.created_at desc), '[]')
      from core.area_return x where x.permit_id = p.id),
    'transferred', (select coalesce(jsonb_agg(jsonb_build_object('kind', l.control_kind, 'control_id', l.control_id, 'at', l.unlinked_at, 'reason', l.unlinked_reason,
                                                                 'owner', (select core.person_name(o.owner_person_id) from core.control_ownership o
                                                                            where o.control_kind = l.control_kind and o.control_id = l.control_id
                                                                            order by o.created_at desc limit 1))), '[]')
      from core.control_link_record l where l.permit_id = p.id and l.unlinked_at is not null),
    'abandoned', (select jsonb_build_object('reason', a.reason, 'by', core.person_name(a.flagged_by_person_id), 'at', a.created_at)
                    from core.permit_abandonment a where a.permit_id = p.id order by a.created_at desc limit 1),
    'close_out', (select jsonb_build_object('id', s.id, 'sha256', encode(s.content_sha256, 'hex'), 'at', s.created_at)
                    from core.close_out_snapshot s where s.permit_id = p.id),
    'emergency', (select jsonb_build_object('id', e.id, 'reference', e.reference, 'category', e.category, 'authorised_by', core.person_name(e.authorised_by_person_id),
                                            'at', e.created_at, 'deadline_at', e.deadline_at) || core.emergency_status(e)
                    from core.emergency_work e where e.work_package_id = p.work_package_id))
  from core.permit p where p.id = p_permit_id $$;

do $m$
declare d text;
begin
  d := pg_get_functiondef('api.permit_detail(uuid)'::regprocedure);
  if position('jsonb_build_object(''controls'', core.permit_controls(p.id));' in d) = 0 then
    raise exception 'api.permit_detail no longer has the expected structure';
  end if;
  execute replace(d, 'jsonb_build_object(''controls'', core.permit_controls(p.id));',
                     'jsonb_build_object(''controls'', core.permit_controls(p.id), ''close_out'', core.permit_close_out(p.id));');
end $m$;

-- The controls desk also shows continuing controls, with their owner and review date.
create or replace function api.controls_desk() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('ok', true,
    'isolations', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', i.id, 'system', y.name, 'points', i.points, 'status', i.status, 'row_version', i.row_version, 'from', lower(i.planned_window),
        'to', upper(i.planned_window), 'requested_by', core.person_name(i.requested_by_person_id), 'failure_open', core.failure_open('isolation', i.id),
        'locks_on', (select count(*) from core.isolation_lock k where k.isolation_id = i.id and k.off_at is null),
        'venue_timezone', (select timezone from core.venue where id = i.venue_id),
        'continuing', (select jsonb_build_object('owner', core.person_name(o.owner_person_id), 'review_on', o.review_on, 'reason', o.reason,
                                                 'review_overdue', o.review_on < current_date)
                         from core.control_ownership o where o.control_kind = 'isolation' and o.control_id = i.id order by o.created_at desc limit 1),
        'jobs', (select jsonb_agg(distinct w.reference) from core.control_link l join core.permit pp on pp.id = l.permit_id
                   join core.work_package w on w.id = pp.work_package_id where l.control_kind = 'isolation' and l.control_id = i.id))
        order by lower(i.planned_window)), '[]')
      from core.isolation i join core.system y on y.id = i.system_id
     where i.status not in ('returned', 'refused', 'withdrawn')
       and i.venue_id in (select authz.my_action_venue_ids(a) from unnest(array['isolation.authorise', 'isolation.apply', 'isolation.prove',
                                                                                'isolation.remove', 'isolation.return', 'isolation.transfer']) a)),
    'impairments', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', i.id, 'system', y.name, 'zones', i.zones, 'status', i.status, 'row_version', i.row_version, 'from', lower(i.planned_window),
        'to', upper(i.planned_window), 'requested_by', core.person_name(i.requested_by_person_id), 'max_hours', i.max_hours,
        'impaired_at', i.impaired_at, 'overdue', core.impairment_overdue(i), 'failure_open', core.failure_open('impairment', i.id),
        'venue_timezone', (select timezone from core.venue where id = i.venue_id),
        'continuing', (select jsonb_build_object('owner', core.person_name(o.owner_person_id), 'review_on', o.review_on, 'reason', o.reason,
                                                 'review_overdue', o.review_on < current_date)
                         from core.control_ownership o where o.control_kind = 'impairment' and o.control_id = i.id order by o.created_at desc limit 1),
        'jobs', (select jsonb_agg(distinct w.reference) from core.control_link l join core.permit pp on pp.id = l.permit_id
                   join core.work_package w on w.id = pp.work_package_id where l.control_kind = 'impairment' and l.control_id = i.id))
        order by core.impairment_overdue(i) desc, lower(i.planned_window)), '[]')
      from core.impairment i join core.system y on y.id = i.system_id
     where i.status not in ('restored', 'refused', 'withdrawn')
       and i.venue_id in (select authz.my_action_venue_ids(a) from unnest(array['impairment.authorise', 'impairment.impair', 'impairment.test',
                                                                                'impairment.restore', 'impairment.reauthorise', 'impairment.transfer']) a))) $$;

-- The watch after the work usually runs while the permit waits for hand-back.
do $m$
declare d text;
begin
  d := pg_get_functiondef('api.start_fire_watch(text,uuid,integer)'::regprocedure);
  if position('  if w.phase = ''post'' and ps not in (''active'', ''suspended'', ''expired'') then' in d) = 0 then
    raise exception 'api.start_fire_watch no longer has the expected structure';
  end if;
  execute replace(d, '  if w.phase = ''post'' and ps not in (''active'', ''suspended'', ''expired'') then',
                     '  if w.phase = ''post'' and ps not in (''active'', ''suspended'', ''expired'', ''hand_back_pending'') then');
end $m$;

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------
drop view api.control_link;
create view api.control_link            with (security_invoker = true) as select * from core.control_link_record;
create view api.control_ownership       with (security_invoker = true) as select * from core.control_ownership;
create view api.hand_back               with (security_invoker = true) as
  select id, customer_id, venue_id, permit_id, from_status, route, declaration, work_complete, remaining_work, area_state, all_workers_out,
         submitted_by_person_id, created_at from core.hand_back;
create view api.hand_back_decision      with (security_invoker = true) as select * from core.hand_back_decision;
create view api.area_return             with (security_invoker = true) as select * from core.area_return;
create view api.permit_abandonment      with (security_invoker = true) as select * from core.permit_abandonment;
create view api.close_out_snapshot      with (security_invoker = true) as
  select id, customer_id, venue_id, permit_id, content, encode(content_sha256, 'hex') as content_sha256, created_at from core.close_out_snapshot;
create view api.emergency_config_version with (security_invoker = true) as select * from core.emergency_config_version;
create view api.emergency_work          with (security_invoker = true) as select * from core.emergency_work;

grant select on all tables in schema api to authenticated;
grant execute on all functions in schema api to authenticated;
revoke execute on all functions in schema api from anon, public;
