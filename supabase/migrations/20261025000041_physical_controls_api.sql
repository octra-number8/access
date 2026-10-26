-- 0041 Physical controls API (phase 6b, D-019)
--
-- Same pattern as before: a repeated request is replayed first; readiness checks refuse
-- with what is missing and who can resolve it; authority only from authz.evaluate (system
-- controls are scoped to the system through the system register, P6-9); status only
-- through core.transition. Each step also writes a control_event with what was recorded.
-- No platform or tenant administrator can take any step (invariant 9): every step needs
-- an appointment or a part in the permit.
--
-- Wiring: issue, acceptance and re-acceptance now check the controls the class needs
-- (replacing the P5-11 block), and the issue snapshot records them.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
create function core.system_target(p_system_id uuid, p_record_id uuid, p_type text, p_excluded jsonb default '[]') returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('customer_id', s.customer_id, 'venue_id', s.venue_id, 'record_id', p_record_id, 'target_type', p_type,
                            'system_id', s.id, 'system_ids', jsonb_build_array(s.id), 'excluded_person_ids', p_excluded)
    from core.system s where s.id = p_system_id $$;

-- The people who cannot authorise a control: whoever asked for it, and everyone
-- connected with the jobs it protects (as at issue, P5-10).
create function core.control_people(p_kind text, p_control_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(distinct x), '[]') from (
    select to_jsonb(coalesce((select requested_by_person_id from core.isolation where id = p_control_id and p_kind = 'isolation'),
                             (select requested_by_person_id from core.impairment where id = p_control_id and p_kind = 'impairment'))) x
    union all
    select jsonb_array_elements(core.permit_people(l.permit_id)) from core.control_link l
     where l.control_kind = p_kind and l.control_id = p_control_id) y where x is not null and x <> 'null' $$;

create function core.add_control_event(p_kind text, p_control_id uuid, p_customer uuid, p_venue uuid, p_step text, p_person uuid, p_content jsonb)
returns void language sql security definer set search_path = '' as $$
  insert into core.control_event (customer_id, venue_id, control_kind, control_id, step, person_id, content, decision_context_id)
  values (p_customer, p_venue, p_kind, p_control_id, p_step, p_person, coalesce(p_content, '{}'), core.ctx_uuid('decision_context_id')) $$;

create function core.blank(p text) returns boolean language sql immutable set search_path = '' as $$ select length(btrim(coalesce(p, ''))) = 0 $$;

-- Who may ask for a system control on these permits: their supervisor, or an
-- administrator of the performing organisation of each.
create function core.request_route(p_base text, p_permit_ids uuid[]) returns jsonb
language sql stable security definer set search_path = '' as $$
  select case
    when cardinality(p_permit_ids) > 0 and not exists (
           select 1 from unnest(p_permit_ids) x where not exists (
             select 1 from core.permit_team_member m join core.permit p on p.id = m.permit_id
              where m.permit_id = x and m.role = 'supervisor' and m.removed_at is null
                and m.person_id = authz.actor_person(p.customer_id)))
      then jsonb_build_object('action', p_base || '_as_supervisor', 'permit_id', p_permit_ids[1])
    else jsonb_build_object('action', p_base, 'permit_id', p_permit_ids[1],
                            'organisation_id', (select w.performing_organisation_id from core.permit p join core.work_package w on w.id = p.work_package_id
                                                 where p.id = p_permit_ids[1]))
  end $$;

create function core.request_problems(p_permit_ids uuid[], p_system_id uuid, p_from timestamptz, p_to timestamptz, p_org_admin boolean) returns text[]
language sql stable security definer set search_path = '' as $$
  select array_remove(array[
    case when cardinality(coalesce(p_permit_ids, '{}')) = 0 then 'Name the permits this control protects.' end,
    case when exists (select 1 from unnest(coalesce(p_permit_ids, '{}')) x
                       where not exists (select 1 from core.permit p join core.system s on s.venue_id = p.venue_id and s.id = p_system_id
                                          where p.id = x and p.status not in ('cancelled', 'refused', 'expired')))
         then 'Each permit must be a current permit at the same venue as the system.' end,
    case when p_org_admin and exists (select 1 from unnest(coalesce(p_permit_ids, '{}')) x join core.permit p on p.id = x
                                        join core.work_package w on w.id = p.work_package_id
                                       where w.performing_organisation_id not in (select authz.my_admin_organisation_ids()))
         then 'You can ask only for your own organisation''s permits.' end,
    case when p_from is null or p_to is null or p_to <= p_from then 'Give the start and end of the time the control is needed.' end], null) $$;

-- Re-created with the failure it came from, where there is one.
drop function core.suspend_one(uuid, text, text, text, uuid, uuid, uuid);
create function core.suspend_one(p_permit_id uuid, p_kind text, p_category text, p_reason text, p_origin uuid, p_area_stop uuid,
                                 p_actor uuid, p_failure uuid default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare q core.permit; s_id uuid := gen_random_uuid();
begin
  select * into q from core.permit where id = p_permit_id for update;
  insert into core.permit_suspension (id, customer_id, venue_id, permit_id, kind, category, reason, origin_suspension_id, area_stop_id,
                                      control_failure_id, stopped_by_person_id, decision_context_id)
  values (s_id, q.customer_id, q.venue_id, q.id, p_kind, p_category, p_reason, p_origin, p_area_stop, p_failure, p_actor,
          core.ctx_uuid('decision_context_id'));
  if q.status <> 'suspended' then
    perform core.transition('core.permit', q.id, 'suspended', q.row_version, core.ctx_uuid('decision_context_id'));
  end if;
  return s_id;
end $$;

-- ---------------------------------------------------------------------------
-- Rules per system type (P6-9)
-- ---------------------------------------------------------------------------
create function api.publish_control_rule(p_idempotency_key text, p_system_type_id uuid, p_kind text, p_content jsonb,
                                         p_effective_from timestamptz, p_change_reason text,
                                         p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare st core.system_type; t jsonb; r jsonb; v jsonb; problems text[]; r_id uuid := gen_random_uuid();
begin
  select * into st from core.system_type where id = p_system_type_id;
  t := jsonb_build_object('customer_id', st.customer_id, 'venue_id', st.venue_id, 'record_id', r_id, 'target_type', 'system_control_rule');
  r := jsonb_build_object('system_type_id', p_system_type_id, 'kind', p_kind, 'content', p_content, 'from', p_effective_from, 'reason', p_change_reason);
  v := core.authorised_or_refusal('control_rule.publish', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  problems := core.control_rule_problems(p_kind, coalesce(p_content, '{}'));
  if p_effective_from is null then problems := problems || text 'Give the date the rule takes effect.'; end if;
  if core.blank(p_change_reason) then problems := problems || text 'Say where the rule comes from or why it changed.'; end if;
  if cardinality(problems) > 0 then
    return core.refuse('control_rule.publish', 'invalid_content', 'The rule has problems.', 'Each item listed', 'You',
                       jsonb_build_object('problems', to_jsonb(problems)));
  end if;
  v := authz.require('control_rule.publish', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.system_control_rule (id, customer_id, venue_id, system_type_id, kind, content, owner_person_id, effective_from, change_reason, decision_context_id)
  values (r_id, st.customer_id, st.venue_id, st.id, p_kind, p_content, (v ->> 'actor_person_id')::uuid, p_effective_from, p_change_reason,
          (v ->> 'decision_context_id')::uuid);
  return v || jsonb_build_object('rule_id', r_id);
end $$;

-- ---------------------------------------------------------------------------
-- Isolations (Q142-Q148, P6-9)
-- ---------------------------------------------------------------------------
create function api.request_isolation(p_idempotency_key text, p_permit_ids uuid[], p_system_id uuid, p_points text, p_reason text,
                                      p_from timestamptz, p_to timestamptz)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare route jsonb; p core.permit; t jsonb; r jsonb; v jsonb; ctx uuid; i_id uuid := gen_random_uuid(); problems text[]; x uuid;
begin
  route := core.request_route('isolation.request', coalesce(p_permit_ids, '{}'));
  select * into p from core.permit where id = (route ->> 'permit_id')::uuid;
  t := core.permit_target(p, i_id, 'isolation', (route ->> 'organisation_id')::uuid) || jsonb_build_object('permit_id', p.id);
  r := jsonb_build_object('permits', to_jsonb(p_permit_ids), 'system_id', p_system_id, 'points', p_points, 'reason', p_reason, 'from', p_from, 'to', p_to);
  v := core.authorised_or_refusal(route ->> 'action', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  problems := core.request_problems(p_permit_ids, p_system_id, p_from, p_to, route ->> 'action' = 'isolation.request');
  if core.blank(p_points) then problems := problems || text 'Describe the isolation points or boundary needed.'; end if;
  if core.blank(p_reason) then problems := problems || text 'Say why the isolation is needed.'; end if;
  if cardinality(problems) > 0 then
    return core.refuse(route ->> 'action', 'invalid_content', 'The request has problems.', 'Each item listed', 'You',
                       jsonb_build_object('problems', to_jsonb(problems)));
  end if;
  v := authz.require(route ->> 'action', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ctx := (v ->> 'decision_context_id')::uuid;
  insert into core.isolation (id, customer_id, venue_id, system_id, points, reason, planned_window, status, requested_by_person_id)
  values (i_id, p.customer_id, p.venue_id, p_system_id, p_points, p_reason, tstzrange(p_from, p_to), 'requested', (v ->> 'actor_person_id')::uuid);
  foreach x in array p_permit_ids loop
    insert into core.control_link (customer_id, venue_id, control_kind, control_id, permit_id, linked_by_person_id, decision_context_id)
    values (p.customer_id, p.venue_id, 'isolation', i_id, x, (v ->> 'actor_person_id')::uuid, ctx) on conflict do nothing;
  end loop;
  perform core.add_control_event('isolation', i_id, p.customer_id, p.venue_id, 'request', (v ->> 'actor_person_id')::uuid, r);
  return v || jsonb_build_object('isolation_id', i_id);
end $$;

-- Authorise or refuse the boundary (Q136): an isolation authority for the system, never
-- whoever asked or anyone connected with the jobs it protects.
create function api.authorise_isolation(p_idempotency_key text, p_isolation_id uuid, p_expected_version integer, p_outcome text, p_note text,
                                        p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare i core.isolation; rule core.system_control_rule; t jsonb; r jsonb; v jsonb;
begin
  select * into i from core.isolation where id = p_isolation_id;
  t := core.system_target(i.system_id, i.id, 'isolation', core.control_people('isolation', i.id));
  r := jsonb_build_object('isolation_id', p_isolation_id, 'expected_version', p_expected_version, 'outcome', p_outcome, 'note', p_note);
  v := core.authorised_or_refusal('isolation.authorise', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if i.status <> 'requested' then
    return core.refuse('isolation.authorise', 'not_requested', 'Only a requested isolation is authorised or refused.', 'A requested isolation', 'Nobody');
  end if;
  if coalesce(p_outcome, '') not in ('authorise', 'refuse') or core.blank(p_note) then
    return core.refuse('isolation.authorise', 'invalid_content', 'Authorise or refuse, and record the boundary and method approved, or why it is refused.',
                       'A decision and its wording', 'You');
  end if;
  rule := core.control_rule(i.system_id, 'isolation');
  if p_outcome = 'authorise' and rule.id is null then
    return core.refuse('isolation.authorise', 'not_configured',
      'This system''s type has no published isolation rules (who may prove, whether return to service is witnessed), so it cannot be isolated yet.',
      'Published isolation rules for the system type (P6-9)', 'The venue''s technical authority');
  end if;
  v := authz.require('isolation.authorise', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.isolation', i.id, case p_outcome when 'authorise' then 'authorised' else 'refused' end, p_expected_version,
                          (v ->> 'decision_context_id')::uuid, case when p_outcome = 'authorise' then jsonb_build_object('rule_version_id', rule.id) else '{}' end);
  perform core.add_control_event('isolation', i.id, i.customer_id, i.venue_id, p_outcome, (v ->> 'actor_person_id')::uuid,
                                 jsonb_build_object('note', p_note, 'rule_version_id', rule.id, 'rule', rule.content));
  return v;
end $$;

create function api.apply_isolation(p_idempotency_key text, p_isolation_id uuid, p_expected_version integer, p_certificate_ref text,
                                    p_lock_refs text[], p_lock_box_ref text,
                                    p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare i core.isolation; t jsonb; r jsonb; v jsonb;
begin
  select * into i from core.isolation where id = p_isolation_id;
  t := core.system_target(i.system_id, i.id, 'isolation');
  r := jsonb_build_object('isolation_id', p_isolation_id, 'expected_version', p_expected_version, 'certificate', p_certificate_ref,
                          'locks', to_jsonb(p_lock_refs), 'lock_box', p_lock_box_ref);
  v := core.authorised_or_refusal('isolation.apply', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if i.status <> 'authorised' then
    return core.refuse('isolation.apply', 'not_authorised', 'An isolation is applied only once it is authorised.', 'An authorised isolation',
                       'The isolation authority for the system');
  end if;
  if core.blank(p_certificate_ref) or cardinality(coalesce(p_lock_refs, '{}')) = 0
     or exists (select 1 from unnest(p_lock_refs) l where core.blank(l)) then
    return core.refuse('isolation.apply', 'invalid_content', 'Record the isolation certificate and every lock applied (Q144).', 'The certificate and locks', 'You');
  end if;
  v := authz.require('isolation.apply', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.isolation', i.id, 'applied', p_expected_version, (v ->> 'decision_context_id')::uuid);
  perform core.add_control_event('isolation', i.id, i.customer_id, i.venue_id, 'apply', (v ->> 'actor_person_id')::uuid,
    jsonb_build_object('certificate_ref', p_certificate_ref, 'lock_refs', to_jsonb(p_lock_refs), 'lock_box_ref', nullif(btrim(coalesce(p_lock_box_ref, '')), '')));
  return v;
end $$;

-- Proving dead or zero energy (Q144). Whether the person who applied it may prove it is
-- the system type's rule, fixed when the isolation was authorised.
create function api.prove_isolation(p_idempotency_key text, p_isolation_id uuid, p_expected_version integer, p_instrument_ref text,
                                    p_method text, p_confirmed boolean,
                                    p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare i core.isolation; rule jsonb; applier uuid; t jsonb; r jsonb; v jsonb;
begin
  select * into i from core.isolation where id = p_isolation_id;
  rule := (select content from core.system_control_rule where id = i.rule_version_id);
  applier := (select person_id from core.control_event where control_kind = 'isolation' and control_id = i.id and step = 'apply'
               order by created_at desc limit 1);
  t := core.system_target(i.system_id, i.id, 'isolation',
                          case when rule ->> 'prove_by' = 'different_person' and applier is not null then jsonb_build_array(applier) else '[]' end);
  r := jsonb_build_object('isolation_id', p_isolation_id, 'expected_version', p_expected_version, 'instrument', p_instrument_ref,
                          'method', p_method, 'confirmed', p_confirmed);
  v := core.authorised_or_refusal('isolation.prove', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if i.status <> 'applied' then
    return core.refuse('isolation.prove', 'not_applied', 'An isolation is proved only once it is applied.', 'An applied isolation',
                       'The authorised person for the system');
  end if;
  if core.blank(p_instrument_ref) or core.blank(p_method) then
    return core.refuse('isolation.prove', 'invalid_content', 'Record the test instrument and the method used.', 'The test record', 'You');
  end if;
  if not coalesce(p_confirmed, false) then
    return core.refuse('isolation.prove', 'not_confirmed',
      'The isolation is proved only when the test confirms it is dead or at zero energy. Do not start work: tell the isolation authority.',
      'A test that confirms the isolation', 'The isolation authority for the system');
  end if;
  v := authz.require('isolation.prove', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.isolation', i.id, 'proved', p_expected_version, (v ->> 'decision_context_id')::uuid);
  perform core.add_control_event('isolation', i.id, i.customer_id, i.venue_id, 'prove', (v ->> 'actor_person_id')::uuid,
                                 jsonb_build_object('instrument_ref', p_instrument_ref, 'method', p_method, 'confirmed', true));
  return v;
end $$;

-- Removal (Q143): never while a permit it protects is live or a personal lock is on.
create function api.remove_isolation(p_idempotency_key text, p_isolation_id uuid, p_expected_version integer, p_note text,
                                     p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare i core.isolation; t jsonb; r jsonb; v jsonb; live jsonb; locks jsonb;
begin
  select * into i from core.isolation where id = p_isolation_id;
  t := core.system_target(i.system_id, i.id, 'isolation');
  r := jsonb_build_object('isolation_id', p_isolation_id, 'expected_version', p_expected_version, 'note', p_note);
  v := core.authorised_or_refusal('isolation.remove', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if i.status not in ('applied', 'proved') then
    return core.refuse('isolation.remove', 'not_in_place', 'Only an applied isolation can be removed.', 'An applied isolation', 'Nobody');
  end if;
  live := (select jsonb_agg(jsonb_build_object('permit_id', p.id, 'job_reference', w.reference, 'class', pc.name, 'status', p.status))
             from core.control_link l join core.permit p on p.id = l.permit_id join core.work_package w on w.id = p.work_package_id
             join core.permit_class pc on pc.id = p.permit_class_id
            where l.control_kind = 'isolation' and l.control_id = i.id and core.is_live(p.status));
  if live is not null then
    return core.refuse('isolation.remove', 'permits_live', 'A permit this isolation protects is still live, so it cannot be removed.',
                       'Each permit listed handed back or closed', 'The permit''s supervisor and issuer', jsonb_build_object('permits', live));
  end if;
  locks := (select jsonb_agg(core.person_name(person_id)) from core.isolation_lock where isolation_id = i.id and off_at is null);
  if locks is not null then
    return core.refuse('isolation.remove', 'locks_on', 'Personal locks are still on this isolation.', 'Every personal lock taken off',
                       'Each lock holder, or the isolation authority for an absent holder', jsonb_build_object('locks', locks));
  end if;
  if core.blank(p_note) then
    return core.refuse('isolation.remove', 'invalid_content', 'Record the locks removed and keys returned.', 'A removal record', 'You');
  end if;
  v := authz.require('isolation.remove', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.isolation', i.id, 'removed', p_expected_version, (v ->> 'decision_context_id')::uuid);
  perform core.add_control_event('isolation', i.id, i.customer_id, i.venue_id, 'remove', (v ->> 'actor_person_id')::uuid, jsonb_build_object('note', p_note));
  return v;
end $$;

-- Return to service (Q148), witnessed where the system type's rule says so.
create function api.return_isolation(p_idempotency_key text, p_isolation_id uuid, p_expected_version integer, p_evidence text,
                                     p_witness_person_id uuid default null,
                                     p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare i core.isolation; rule jsonb; t jsonb; r jsonb; v jsonb;
begin
  select * into i from core.isolation where id = p_isolation_id;
  rule := (select content from core.system_control_rule where id = i.rule_version_id);
  t := core.system_target(i.system_id, i.id, 'isolation');
  r := jsonb_build_object('isolation_id', p_isolation_id, 'expected_version', p_expected_version, 'evidence', p_evidence, 'witness', p_witness_person_id);
  v := core.authorised_or_refusal('isolation.return', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if i.status <> 'removed' then
    return core.refuse('isolation.return', 'not_removed', 'A system is returned to service only after its isolation is removed.', 'A removed isolation', 'Nobody');
  end if;
  if core.blank(p_evidence) then
    return core.refuse('isolation.return', 'invalid_content', 'Record the evidence that the system is safe to return to service (Q148).', 'The evidence', 'You');
  end if;
  if rule ->> 'return_witness' = 'required' and (p_witness_person_id is null or p_witness_person_id = authz.actor_person(i.customer_id)
       or not exists (select 1 from core.person where id = p_witness_person_id and customer_id = i.customer_id)) then
    return core.refuse('isolation.return', 'witness_required', 'Return to service for this system needs a witness other than you.', 'A named witness',
                       'You, with a second person');
  end if;
  v := authz.require('isolation.return', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.isolation', i.id, 'returned', p_expected_version, (v ->> 'decision_context_id')::uuid);
  perform core.add_control_event('isolation', i.id, i.customer_id, i.venue_id, 'return', (v ->> 'actor_person_id')::uuid,
                                 jsonb_build_object('evidence', p_evidence, 'witness_person_id', p_witness_person_id));
  return v;
end $$;

create function api.withdraw_isolation(p_idempotency_key text, p_isolation_id uuid, p_expected_version integer, p_reason text,
                                       p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare i core.isolation; t jsonb; r jsonb; v jsonb;
begin
  select * into i from core.isolation where id = p_isolation_id;
  t := core.system_target(i.system_id, i.id, 'isolation');
  r := jsonb_build_object('isolation_id', p_isolation_id, 'expected_version', p_expected_version, 'reason', p_reason);
  v := core.authorised_or_refusal('isolation.withdraw', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if i.status not in ('requested', 'authorised') then
    return core.refuse('isolation.withdraw', 'not_withdrawable', 'Only an isolation not yet applied can be withdrawn; an applied one is removed.',
                       'An isolation not yet applied', 'Nobody');
  end if;
  if core.blank(p_reason) then
    return core.refuse('isolation.withdraw', 'invalid_content', 'Say why the isolation is no longer needed.', 'A reason', 'You');
  end if;
  v := authz.require('isolation.withdraw', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.isolation', i.id, 'withdrawn', p_expected_version, (v ->> 'decision_context_id')::uuid);
  perform core.add_control_event('isolation', i.id, i.customer_id, i.venue_id, 'withdraw', (v ->> 'actor_person_id')::uuid, jsonb_build_object('reason', p_reason));
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Personal locks (Q145, Q146): by the holder, or by the supervisor of a permit the
-- isolation protects for someone on that permit's team.
-- ---------------------------------------------------------------------------
-- The linked permit through which the caller acts on someone's lock, and whether as
-- that permit's supervisor.
create function core.lock_permit(p_isolation_id uuid, p_holder uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('permit_id', p.id, 'as_supervisor', me.role = 'supervisor')
    from core.control_link l join core.permit p on p.id = l.permit_id
    join core.permit_team_member me on me.permit_id = p.id and me.removed_at is null and me.person_id = authz.actor_person(p.customer_id)
   where l.control_kind = 'isolation' and l.control_id = p_isolation_id
     and exists (select 1 from core.permit_team_member h where h.permit_id = p.id and h.person_id = p_holder and core.member_counts(h))
     and (me.role = 'supervisor' or me.person_id = p_holder)
   order by (me.role = 'supervisor') desc, p.id limit 1 $$;

create function api.isolation_lock_on(p_idempotency_key text, p_isolation_id uuid, p_person_id uuid, p_lock_ref text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare i core.isolation; lp jsonb; p core.permit; t jsonb; r jsonb; v jsonb; l_id uuid := gen_random_uuid();
begin
  select * into i from core.isolation where id = p_isolation_id;
  lp := core.lock_permit(p_isolation_id, p_person_id);
  select * into p from core.permit where id = coalesce((lp ->> 'permit_id')::uuid,
    (select l.permit_id from core.control_link l where l.control_kind = 'isolation' and l.control_id = p_isolation_id order by l.permit_id limit 1));
  t := core.permit_target(p, i.id, 'isolation', null) || jsonb_build_object('permit_id', p.id);
  r := jsonb_build_object('isolation_id', p_isolation_id, 'person_id', p_person_id, 'lock_ref', p_lock_ref);
  v := core.authorised_or_refusal('isolation.lock_on', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if lp is null then
    return core.refuse('isolation.lock_on', 'not_on_team',
      'A personal lock is put on by its holder, or recorded by their supervisor, for someone on the team of a permit this isolation protects.',
      'A place on a linked permit''s team', 'The permit''s supervisor');
  end if;
  if i.status <> 'proved' or core.failure_open('isolation', i.id) then
    return core.refuse('isolation.lock_on', 'not_proved', 'Personal locks go on a proved isolation.', 'A proved isolation', 'The isolation authority for the system');
  end if;
  if exists (select 1 from core.isolation_lock where isolation_id = i.id and person_id = p_person_id and off_at is null) then
    return core.refuse('isolation.lock_on', 'already_on', 'This person already has a lock on.', 'No lock on', 'Nobody');
  end if;
  if core.blank(p_lock_ref) then
    return core.refuse('isolation.lock_on', 'invalid_content', 'Record the lock''s number or tag.', 'A lock reference', 'You');
  end if;
  v := authz.require('isolation.lock_on', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.isolation_lock (id, customer_id, venue_id, isolation_id, person_id, lock_ref, on_recorded_by_person_id, on_decision_context_id)
  values (l_id, i.customer_id, i.venue_id, i.id, p_person_id, p_lock_ref, (v ->> 'actor_person_id')::uuid, (v ->> 'decision_context_id')::uuid);
  return v || jsonb_build_object('lock_id', l_id);
end $$;

create function api.isolation_lock_off(p_idempotency_key text, p_lock_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare k core.isolation_lock; lp jsonb; p core.permit; t jsonb; r jsonb; v jsonb;
begin
  select * into k from core.isolation_lock where id = p_lock_id;
  lp := core.lock_permit(k.isolation_id, k.person_id);
  select * into p from core.permit where id = coalesce((lp ->> 'permit_id')::uuid,
    (select l.permit_id from core.control_link l where l.control_kind = 'isolation' and l.control_id = k.isolation_id order by l.permit_id limit 1));
  t := core.permit_target(p, k.isolation_id, 'isolation', null) || jsonb_build_object('permit_id', p.id);
  r := jsonb_build_object('lock_id', p_lock_id);
  v := core.authorised_or_refusal('isolation.lock_off', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if lp is null then
    return core.refuse('isolation.lock_off', 'not_holder',
      'A personal lock is taken off by its holder, or recorded by their supervisor; for a holder who is not there, by the isolation authority.',
      'The holder or their supervisor', 'The isolation authority for the system');
  end if;
  if k.off_at is not null then
    return core.refuse('isolation.lock_off', 'already_off', 'This lock is already off.', 'A lock that is on', 'Nobody');
  end if;
  v := authz.require('isolation.lock_off', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  update core.isolation_lock set off_at = clock_timestamp(), off_recorded_by_person_id = (v ->> 'actor_person_id')::uuid, off_on_behalf = false,
                                 off_decision_context_id = (v ->> 'decision_context_id')::uuid
   where id = k.id;
  return v;
end $$;

-- An absent holder (Q146): the isolation authority, with a reason and a confirmation that
-- the person is not in the area.
create function api.isolation_lock_off_on_behalf(p_idempotency_key text, p_lock_id uuid, p_reason text, p_confirmed_not_in_area boolean,
                                                 p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare k core.isolation_lock; i core.isolation; t jsonb; r jsonb; v jsonb;
begin
  select * into k from core.isolation_lock where id = p_lock_id;
  select * into i from core.isolation where id = k.isolation_id;
  t := core.system_target(i.system_id, i.id, 'isolation');
  r := jsonb_build_object('lock_id', p_lock_id, 'reason', p_reason, 'confirmed', p_confirmed_not_in_area);
  v := core.authorised_or_refusal('isolation.lock_off_on_behalf', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if k.off_at is not null then
    return core.refuse('isolation.lock_off_on_behalf', 'already_off', 'This lock is already off.', 'A lock that is on', 'Nobody');
  end if;
  if core.blank(p_reason) or not coalesce(p_confirmed_not_in_area, false) then
    return core.refuse('isolation.lock_off_on_behalf', 'invalid_content',
      'Say why the holder cannot remove their own lock, and confirm they are not in the isolated area.', 'A reason and the confirmation', 'You');
  end if;
  v := authz.require('isolation.lock_off_on_behalf', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  update core.isolation_lock set off_at = clock_timestamp(), off_recorded_by_person_id = (v ->> 'actor_person_id')::uuid, off_on_behalf = true,
                                 off_reason = p_reason, off_decision_context_id = (v ->> 'decision_context_id')::uuid
   where id = k.id;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Impairments (Q135-Q141)
-- ---------------------------------------------------------------------------
create function api.request_impairment(p_idempotency_key text, p_permit_ids uuid[], p_system_id uuid, p_zones text, p_reason text,
                                       p_from timestamptz, p_to timestamptz)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare route jsonb; p core.permit; t jsonb; r jsonb; v jsonb; ctx uuid; i_id uuid := gen_random_uuid(); problems text[]; x uuid;
begin
  route := core.request_route('impairment.request', coalesce(p_permit_ids, '{}'));
  select * into p from core.permit where id = (route ->> 'permit_id')::uuid;
  t := core.permit_target(p, i_id, 'impairment', (route ->> 'organisation_id')::uuid) || jsonb_build_object('permit_id', p.id);
  r := jsonb_build_object('permits', to_jsonb(p_permit_ids), 'system_id', p_system_id, 'zones', p_zones, 'reason', p_reason, 'from', p_from, 'to', p_to);
  v := core.authorised_or_refusal(route ->> 'action', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  problems := core.request_problems(p_permit_ids, p_system_id, p_from, p_to, route ->> 'action' = 'impairment.request');
  if core.blank(p_zones) then problems := problems || text 'Say which zones or devices will be impaired.'; end if;
  if core.blank(p_reason) then problems := problems || text 'Say why the impairment is needed.'; end if;
  if cardinality(problems) > 0 then
    return core.refuse(route ->> 'action', 'invalid_content', 'The request has problems.', 'Each item listed', 'You',
                       jsonb_build_object('problems', to_jsonb(problems)));
  end if;
  v := authz.require(route ->> 'action', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ctx := (v ->> 'decision_context_id')::uuid;
  insert into core.impairment (id, customer_id, venue_id, system_id, zones, reason, planned_window, status, requested_by_person_id)
  values (i_id, p.customer_id, p.venue_id, p_system_id, p_zones, p_reason, tstzrange(p_from, p_to), 'requested', (v ->> 'actor_person_id')::uuid);
  foreach x in array p_permit_ids loop
    insert into core.control_link (customer_id, venue_id, control_kind, control_id, permit_id, linked_by_person_id, decision_context_id)
    values (p.customer_id, p.venue_id, 'impairment', i_id, x, (v ->> 'actor_person_id')::uuid, ctx) on conflict do nothing;
  end loop;
  perform core.add_control_event('impairment', i_id, p.customer_id, p.venue_id, 'request', (v ->> 'actor_person_id')::uuid, r);
  return v || jsonb_build_object('impairment_id', i_id);
end $$;

create function api.authorise_impairment(p_idempotency_key text, p_impairment_id uuid, p_expected_version integer, p_outcome text, p_note text,
                                         p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare i core.impairment; rule core.system_control_rule; t jsonb; r jsonb; v jsonb;
begin
  select * into i from core.impairment where id = p_impairment_id;
  t := core.system_target(i.system_id, i.id, 'impairment', core.control_people('impairment', i.id));
  r := jsonb_build_object('impairment_id', p_impairment_id, 'expected_version', p_expected_version, 'outcome', p_outcome, 'note', p_note);
  v := core.authorised_or_refusal('impairment.authorise', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if i.status <> 'requested' then
    return core.refuse('impairment.authorise', 'not_requested', 'Only a requested impairment is authorised or refused.', 'A requested impairment', 'Nobody');
  end if;
  if coalesce(p_outcome, '') not in ('authorise', 'refuse') or core.blank(p_note) then
    return core.refuse('impairment.authorise', 'invalid_content', 'Authorise or refuse, and say why.', 'A decision and its reason', 'You');
  end if;
  rule := core.control_rule(i.system_id, 'impairment');
  if p_outcome = 'authorise' and rule.id is null then
    return core.refuse('impairment.authorise', 'not_configured',
      'This system''s type has no published impairment rules (maximum duration, compensatory measures, notifications), so it cannot be impaired yet.',
      'Published impairment rules for the system type (P6-9)', 'The venue''s technical authority');
  end if;
  v := authz.require('impairment.authorise', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.impairment', i.id, case p_outcome when 'authorise' then 'authorised' else 'refused' end, p_expected_version,
                          (v ->> 'decision_context_id')::uuid,
                          case when p_outcome = 'authorise' then jsonb_build_object('rule_version_id', rule.id, 'max_hours', rule.content -> 'max_duration_hours')
                               else '{}' end);
  perform core.add_control_event('impairment', i.id, i.customer_id, i.venue_id, p_outcome, (v ->> 'actor_person_id')::uuid,
                                 jsonb_build_object('note', p_note, 'rule_version_id', rule.id, 'rule', rule.content));
  return v;
end $$;

-- Impairing (Q137, Q138): refused until every compensatory measure the rule lists is
-- recorded in place by a named person, and every notification recorded as given.
--   p_measures:      [{measure, in_place_person_id}]
--   p_notifications: [{notification, told, how, at}]
create function api.impair_system(p_idempotency_key text, p_impairment_id uuid, p_expected_version integer, p_measures jsonb, p_notifications jsonb,
                                  p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare i core.impairment; rule jsonb; t jsonb; r jsonb; v jsonb; missing jsonb;
begin
  select * into i from core.impairment where id = p_impairment_id;
  rule := (select content from core.system_control_rule where id = i.rule_version_id);
  t := core.system_target(i.system_id, i.id, 'impairment');
  r := jsonb_build_object('impairment_id', p_impairment_id, 'expected_version', p_expected_version, 'measures', p_measures, 'notifications', p_notifications);
  v := core.authorised_or_refusal('impairment.impair', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if i.status <> 'authorised' then
    return core.refuse('impairment.impair', 'not_authorised', 'A system is impaired only once the impairment is authorised.', 'An authorised impairment',
                       'The impairment authority for the system');
  end if;
  missing := coalesce((select jsonb_agg(m) from jsonb_array_elements_text(coalesce(rule -> 'compensatory_measures', '[]')) m
               where not exists (select 1 from jsonb_array_elements(case when jsonb_typeof(p_measures) = 'array' then p_measures else '[]' end) x
                                  where x ->> 'measure' = m and coalesce(x ->> 'in_place_person_id', '') ~ '^[0-9a-f-]{36}$'
                                    and exists (select 1 from core.person where id = (x ->> 'in_place_person_id')::uuid and customer_id = i.customer_id))), '[]')
             || coalesce((select jsonb_agg('Notify: ' || m) from jsonb_array_elements_text(coalesce(rule -> 'notifications', '[]')) m
                           where not exists (select 1 from jsonb_array_elements(case when jsonb_typeof(p_notifications) = 'array' then p_notifications else '[]' end) x
                                              where x ->> 'notification' = m and not core.blank(x ->> 'told') and not core.blank(x ->> 'how')
                                                and (x ->> 'at') is not null and (x ->> 'at')::timestamptz <= clock_timestamp())), '[]');
  if jsonb_array_length(coalesce(missing, '[]')) > 0 then
    return core.refuse('impairment.impair', 'measures_missing',
      'Before the system is impaired, record each compensatory measure in place with the person responsible, and each notification given.',
      'Each item listed', 'The impairment authority for the system', jsonb_build_object('missing', missing));
  end if;
  v := authz.require('impairment.impair', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.impairment', i.id, 'impaired', p_expected_version, (v ->> 'decision_context_id')::uuid,
                          jsonb_build_object('impaired_at', clock_timestamp()));
  perform core.add_control_event('impairment', i.id, i.customer_id, i.venue_id, 'impair', (v ->> 'actor_person_id')::uuid,
                                 jsonb_build_object('measures', p_measures, 'notifications', p_notifications));
  return v;
end $$;

-- Reinstatement test (Q140): the tester and a different witness. A failed test is
-- recorded and the system stays impaired.
create function api.test_reinstatement(p_idempotency_key text, p_impairment_id uuid, p_expected_version integer, p_witness_person_id uuid,
                                       p_passed boolean, p_note text,
                                       p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare i core.impairment; t jsonb; r jsonb; v jsonb;
begin
  select * into i from core.impairment where id = p_impairment_id;
  t := core.system_target(i.system_id, i.id, 'impairment');
  r := jsonb_build_object('impairment_id', p_impairment_id, 'expected_version', p_expected_version, 'witness', p_witness_person_id,
                          'passed', p_passed, 'note', p_note);
  v := core.authorised_or_refusal('impairment.test', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if i.status <> 'impaired' then
    return core.refuse('impairment.test', 'not_impaired', 'Only an impaired system is tested for reinstatement.', 'An impaired system', 'Nobody');
  end if;
  if p_witness_person_id is null or p_witness_person_id = authz.actor_person(i.customer_id)
     or not exists (select 1 from core.person where id = p_witness_person_id and customer_id = i.customer_id) then
    return core.refuse('impairment.test', 'witness_required', 'A reinstatement test needs a witness other than the tester (Q140).', 'A named witness',
                       'You, with a second person');
  end if;
  if p_passed is null or core.blank(p_note) then
    return core.refuse('impairment.test', 'invalid_content', 'Record whether the test passed, and what was tested.', 'The test record', 'You');
  end if;
  v := authz.require('impairment.test', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  if p_passed then
    perform core.transition('core.impairment', i.id, 'tested', p_expected_version, (v ->> 'decision_context_id')::uuid);
  end if;
  perform core.add_control_event('impairment', i.id, i.customer_id, i.venue_id, case when p_passed then 'test_passed' else 'test_failed' end,
                                 (v ->> 'actor_person_id')::uuid, jsonb_build_object('witness_person_id', p_witness_person_id, 'note', p_note));
  return v;
end $$;

create function api.restore_system(p_idempotency_key text, p_impairment_id uuid, p_expected_version integer, p_note text,
                                   p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare i core.impairment; t jsonb; r jsonb; v jsonb;
begin
  select * into i from core.impairment where id = p_impairment_id;
  t := core.system_target(i.system_id, i.id, 'impairment');
  r := jsonb_build_object('impairment_id', p_impairment_id, 'expected_version', p_expected_version, 'note', p_note);
  v := core.authorised_or_refusal('impairment.restore', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if i.status <> 'tested' then
    return core.refuse('impairment.restore', 'not_tested', 'A system is confirmed back in service only after a passed reinstatement test.',
                       'A passed reinstatement test', 'The impairment authority for the system');
  end if;
  if core.blank(p_note) then
    return core.refuse('impairment.restore', 'invalid_content', 'Record how the system was confirmed back in service.', 'A note', 'You');
  end if;
  v := authz.require('impairment.restore', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.impairment', i.id, 'restored', p_expected_version, (v ->> 'decision_context_id')::uuid);
  perform core.add_control_event('impairment', i.id, i.customer_id, i.venue_id, 'restore', (v ->> 'actor_person_id')::uuid, jsonb_build_object('note', p_note));
  return v;
end $$;

-- Continuing past the maximum (Q139, Q141): a fresh decision with a new maximum and a
-- reason. Time passing never extends it (invariant 10).
create function api.reauthorise_impairment(p_idempotency_key text, p_impairment_id uuid, p_expected_version integer, p_new_max_hours numeric,
                                           p_reason text, p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare i core.impairment; t jsonb; r jsonb; v jsonb;
begin
  select * into i from core.impairment where id = p_impairment_id;
  t := core.system_target(i.system_id, i.id, 'impairment', core.control_people('impairment', i.id));
  r := jsonb_build_object('impairment_id', p_impairment_id, 'expected_version', p_expected_version, 'max_hours', p_new_max_hours, 'reason', p_reason);
  v := core.authorised_or_refusal('impairment.reauthorise', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if i.row_version is distinct from p_expected_version then
    return core.refuse('impairment.reauthorise', 'changed', 'This impairment has changed since you opened it. Reload it.', 'Its current state', 'You');
  end if;
  if i.status <> 'impaired' then
    return core.refuse('impairment.reauthorise', 'not_impaired', 'Only an impaired system''s maximum can be extended.', 'An impaired system', 'Nobody');
  end if;
  if p_new_max_hours is null or p_new_max_hours <= i.max_hours or core.blank(p_reason) then
    return core.refuse('impairment.reauthorise', 'invalid_content', 'Give a longer maximum than the current one, and the reason it must continue.',
                       'A new maximum and a reason', 'You');
  end if;
  v := authz.require('impairment.reauthorise', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  update core.impairment set max_hours = p_new_max_hours where id = i.id;
  perform core.add_control_event('impairment', i.id, i.customer_id, i.venue_id, 'reauthorise', (v ->> 'actor_person_id')::uuid,
                                 jsonb_build_object('previous_max_hours', i.max_hours, 'max_hours', p_new_max_hours, 'reason', p_reason));
  return v;
end $$;

create function api.withdraw_impairment(p_idempotency_key text, p_impairment_id uuid, p_expected_version integer, p_reason text,
                                        p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare i core.impairment; t jsonb; r jsonb; v jsonb;
begin
  select * into i from core.impairment where id = p_impairment_id;
  t := core.system_target(i.system_id, i.id, 'impairment');
  r := jsonb_build_object('impairment_id', p_impairment_id, 'expected_version', p_expected_version, 'reason', p_reason);
  v := core.authorised_or_refusal('impairment.withdraw', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if i.status not in ('requested', 'authorised') then
    return core.refuse('impairment.withdraw', 'not_withdrawable', 'Only an impairment not yet in place can be withdrawn.', 'An impairment not yet in place', 'Nobody');
  end if;
  if core.blank(p_reason) then
    return core.refuse('impairment.withdraw', 'invalid_content', 'Say why the impairment is no longer needed.', 'A reason', 'You');
  end if;
  v := authz.require('impairment.withdraw', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.impairment', i.id, 'withdrawn', p_expected_version, (v ->> 'decision_context_id')::uuid);
  perform core.add_control_event('impairment', i.id, i.customer_id, i.venue_id, 'withdraw', (v ->> 'actor_person_id')::uuid, jsonb_build_object('reason', p_reason));
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Fire watch (Q130, Q134): arranged with a named watcher; the watch after the work
-- cannot end before its minimum, measured from when it actually started.
-- ---------------------------------------------------------------------------
create function api.arrange_fire_watch(p_idempotency_key text, p_permit_id uuid, p_phase text, p_watcher_person_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p core.permit; cfg jsonb; t jsonb; r jsonb; v jsonb; w_id uuid := gen_random_uuid();
begin
  select * into p from core.permit where id = p_permit_id;
  cfg := (select k from jsonb_array_elements(coalesce(core.permit_class_controls(p), '[]')) k where k ->> 'kind' = 'fire_watch');
  t := core.permit_target(p, w_id, 'fire_watch', null) || jsonb_build_object('permit_id', p.id);
  r := jsonb_build_object('permit_id', p_permit_id, 'phase', p_phase, 'watcher', p_watcher_person_id);
  v := core.authorised_or_refusal('fire_watch.arrange', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if cfg is null then
    return core.refuse('fire_watch.arrange', 'not_required', 'This permit''s class does not include a fire watch.', 'A class with a fire watch', 'Nobody');
  end if;
  if p.status in ('cancelled', 'refused', 'expired') then
    return core.refuse('fire_watch.arrange', 'not_open', 'This permit is no longer current.', 'A current permit', 'Nobody');
  end if;
  if coalesce(p_phase, '') not in ('during', 'post') or (p_phase = 'during' and not (cfg ->> 'during_work')::boolean)
     or not exists (select 1 from core.person where id = p_watcher_person_id and customer_id = p.customer_id) then
    return core.refuse('fire_watch.arrange', 'invalid_content', 'Name the watcher, and whether the watch is during or after the work (as the class requires).',
                       'A watcher and phase', 'You');
  end if;
  if exists (select 1 from core.fire_watch where permit_id = p.id and phase = p_phase and status <> 'ended') then
    return core.refuse('fire_watch.arrange', 'already_arranged', 'A fire watch for this phase is already arranged.', 'No open watch for this phase', 'Nobody');
  end if;
  v := authz.require('fire_watch.arrange', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.fire_watch (id, customer_id, venue_id, permit_id, phase, watcher_person_id, status, minimum_minutes, arranged_by_person_id)
  values (w_id, p.customer_id, p.venue_id, p.id, p_phase, p_watcher_person_id, 'arranged',
          case when p_phase = 'post' then (cfg ->> 'post_work_minutes')::integer else 0 end, (v ->> 'actor_person_id')::uuid);
  perform core.add_control_event('fire_watch', w_id, p.customer_id, p.venue_id, 'arrange', (v ->> 'actor_person_id')::uuid, r);
  return v || jsonb_build_object('fire_watch_id', w_id);
end $$;

create function core.fire_watch_target(w core.fire_watch) returns jsonb
language sql stable security definer set search_path = '' as $$
  select core.permit_target(p, w.id, 'fire_watch', null) || jsonb_build_object('permit_id', p.id) from core.permit p where p.id = w.permit_id $$;

create function api.start_fire_watch(p_idempotency_key text, p_fire_watch_id uuid, p_expected_version integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare w core.fire_watch; ps text; t jsonb; r jsonb; v jsonb;
begin
  select * into w from core.fire_watch where id = p_fire_watch_id;
  ps := (select status from core.permit where id = w.permit_id);
  t := core.fire_watch_target(w);
  r := jsonb_build_object('fire_watch_id', p_fire_watch_id, 'expected_version', p_expected_version);
  v := core.authorised_or_refusal('fire_watch.start', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if w.status <> 'arranged' then
    return core.refuse('fire_watch.start', 'not_arranged', 'This fire watch has already started.', 'An arranged watch', 'Nobody');
  end if;
  if w.phase = 'during' and ps <> 'active' then
    return core.refuse('fire_watch.start', 'not_active', 'The watch during the work starts when the permit is active.', 'An active permit', 'The permit''s supervisor');
  end if;
  if w.phase = 'post' and ps not in ('active', 'suspended', 'expired') then
    return core.refuse('fire_watch.start', 'not_live', 'The watch after the work starts once the permit has been active.', 'A permit that has been active', 'Nobody');
  end if;
  v := authz.require('fire_watch.start', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.fire_watch', w.id, 'started', p_expected_version, (v ->> 'decision_context_id')::uuid,
                          jsonb_build_object('started_at', clock_timestamp()));
  perform core.add_control_event('fire_watch', w.id, w.customer_id, w.venue_id, 'start', (v ->> 'actor_person_id')::uuid, '{}');
  return v;
end $$;

create function api.check_fire_watch(p_idempotency_key text, p_fire_watch_id uuid, p_findings text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare w core.fire_watch; t jsonb; r jsonb; v jsonb;
begin
  select * into w from core.fire_watch where id = p_fire_watch_id;
  t := core.fire_watch_target(w);
  r := jsonb_build_object('fire_watch_id', p_fire_watch_id, 'findings', p_findings);
  v := core.authorised_or_refusal('fire_watch.check', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if w.status <> 'started' or core.blank(p_findings) then
    return core.refuse('fire_watch.check', 'invalid_content', 'Record findings for a watch that has started.', 'A started watch and findings', 'You');
  end if;
  v := authz.require('fire_watch.check', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.add_control_event('fire_watch', w.id, w.customer_id, w.venue_id, 'check', (v ->> 'actor_person_id')::uuid,
                                 jsonb_build_object('findings', p_findings, 'watcher_person_id', w.watcher_person_id));
  return v;
end $$;

-- The final check (Q134), recorded on the watcher's word by the supervisor.
create function api.end_fire_watch(p_idempotency_key text, p_fire_watch_id uuid, p_expected_version integer, p_final_findings text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare w core.fire_watch; t jsonb; r jsonb; v jsonb; earliest timestamptz;
begin
  select * into w from core.fire_watch where id = p_fire_watch_id;
  t := core.fire_watch_target(w);
  r := jsonb_build_object('fire_watch_id', p_fire_watch_id, 'expected_version', p_expected_version, 'findings', p_final_findings);
  v := core.authorised_or_refusal('fire_watch.end', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if w.status <> 'started' then
    return core.refuse('fire_watch.end', 'not_started', 'Only a started watch can end.', 'A started watch', 'The permit''s supervisor');
  end if;
  earliest := w.started_at + make_interval(mins => w.minimum_minutes);
  if clock_timestamp() < earliest then
    return core.refuse('fire_watch.end', 'too_soon',
      format('This watch must run until at least %s.', to_char(earliest at time zone (select timezone from core.venue where id = w.venue_id), 'HH24:MI')),
      'The minimum watch time', 'Nobody: keep watching');
  end if;
  if core.blank(p_final_findings) then
    return core.refuse('fire_watch.end', 'invalid_content', 'Record the final check and its findings.', 'The final findings', 'You');
  end if;
  v := authz.require('fire_watch.end', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.fire_watch', w.id, 'ended', p_expected_version, (v ->> 'decision_context_id')::uuid,
                          jsonb_build_object('ended_at', clock_timestamp()));
  perform core.add_control_event('fire_watch', w.id, w.customer_id, w.venue_id, 'final_check', (v ->> 'actor_person_id')::uuid,
                                 jsonb_build_object('findings', p_final_findings, 'watcher_person_id', w.watcher_person_id));
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Exclusion zones
-- ---------------------------------------------------------------------------
create function api.set_up_exclusion_zone(p_idempotency_key text, p_permit_id uuid, p_area_id uuid, p_description text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p core.permit; t jsonb; r jsonb; v jsonb; z_id uuid := gen_random_uuid();
begin
  select * into p from core.permit where id = p_permit_id;
  t := core.permit_target(p, z_id, 'exclusion_zone', null) || jsonb_build_object('permit_id', p.id);
  r := jsonb_build_object('permit_id', p_permit_id, 'area_id', p_area_id, 'description', p_description);
  v := core.authorised_or_refusal('exclusion_zone.set_up', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if p.status in ('cancelled', 'refused', 'expired') then
    return core.refuse('exclusion_zone.set_up', 'not_open', 'This permit is no longer current.', 'A current permit', 'Nobody');
  end if;
  if core.blank(p_description) or (p_area_id is not null and not exists (select 1 from core.area where id = p_area_id and venue_id = p.venue_id)) then
    return core.refuse('exclusion_zone.set_up', 'invalid_content', 'Describe the zone, and its area if it has one at this venue.', 'A description', 'You');
  end if;
  v := authz.require('exclusion_zone.set_up', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.exclusion_zone (id, customer_id, venue_id, permit_id, area_id, description, status, set_up_by_person_id)
  values (z_id, p.customer_id, p.venue_id, p.id, p_area_id, p_description, 'set_up', (v ->> 'actor_person_id')::uuid);
  perform core.add_control_event('exclusion_zone', z_id, p.customer_id, p.venue_id, 'set_up', (v ->> 'actor_person_id')::uuid, r);
  return v || jsonb_build_object('exclusion_zone_id', z_id);
end $$;

-- Removing a zone while the work is under way is not a route: stop the work first.
create function api.remove_exclusion_zone(p_idempotency_key text, p_zone_id uuid, p_expected_version integer, p_note text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare z core.exclusion_zone; p core.permit; t jsonb; r jsonb; v jsonb;
begin
  select * into z from core.exclusion_zone where id = p_zone_id;
  select * into p from core.permit where id = z.permit_id;
  t := core.permit_target(p, z.id, 'exclusion_zone', null) || jsonb_build_object('permit_id', p.id);
  r := jsonb_build_object('zone_id', p_zone_id, 'expected_version', p_expected_version, 'note', p_note);
  v := core.authorised_or_refusal('exclusion_zone.remove', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if z.status <> 'set_up' then
    return core.refuse('exclusion_zone.remove', 'not_set_up', 'This zone has already been removed.', 'A zone in place', 'Nobody');
  end if;
  if p.status in ('issued_awaiting_acceptance', 'active') then
    return core.refuse('exclusion_zone.remove', 'permit_live', 'The work is live, so its exclusion zone stays. Stop or hand back the work first.',
                       'A permit that is not live', 'The permit''s supervisor');
  end if;
  if core.blank(p_note) then
    return core.refuse('exclusion_zone.remove', 'invalid_content', 'Record that the area was checked clear.', 'A note', 'You');
  end if;
  v := authz.require('exclusion_zone.remove', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.exclusion_zone', z.id, 'removed', p_expected_version, (v ->> 'decision_context_id')::uuid,
                          jsonb_build_object('removed_at', clock_timestamp()));
  perform core.add_control_event('exclusion_zone', z.id, z.customer_id, z.venue_id, 'remove', (v ->> 'actor_person_id')::uuid, jsonb_build_object('note', p_note));
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Custody (Q118, Q160)
-- ---------------------------------------------------------------------------
create function api.register_custody_item(p_idempotency_key text, p_venue_id uuid, p_kind text, p_label text, p_reference text, p_area_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare vn core.venue; t jsonb; r jsonb; v jsonb; c_id uuid := gen_random_uuid();
begin
  select * into vn from core.venue where id = p_venue_id;
  t := jsonb_build_object('customer_id', vn.customer_id, 'venue_id', vn.id, 'record_id', c_id, 'target_type', 'custody_item');
  r := jsonb_build_object('venue_id', p_venue_id, 'kind', p_kind, 'label', p_label, 'reference', p_reference, 'area_id', p_area_id);
  v := core.authorised_or_refusal('custody_item.register', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if coalesce(p_kind, '') not in ('key', 'pass', 'hatch_key', 'lock_box_key', 'certificate', 'other') or core.blank(p_label) or core.blank(p_reference)
     or (p_area_id is not null and not exists (select 1 from core.area where id = p_area_id and venue_id = vn.id)) then
    return core.refuse('custody_item.register', 'invalid_content', 'Give the kind, a label and a unique reference.', 'Each detail', 'You');
  end if;
  if exists (select 1 from core.custody_item where venue_id = vn.id and reference = p_reference) then
    return core.refuse('custody_item.register', 'duplicate', 'Another item at this venue has that reference.', 'A unique reference', 'You');
  end if;
  v := authz.require('custody_item.register', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.custody_item (id, customer_id, venue_id, kind, label, reference, area_id)
  values (c_id, vn.customer_id, vn.id, p_kind, p_label, p_reference, p_area_id);
  return v || jsonb_build_object('custody_item_id', c_id);
end $$;

create function api.issue_custody_item(p_idempotency_key text, p_item_id uuid, p_permit_id uuid, p_holder_person_id uuid,
                                       p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c core.custody_item; p core.permit; t jsonb; r jsonb; v jsonb; m_id uuid := gen_random_uuid();
begin
  select * into c from core.custody_item where id = p_item_id;
  select * into p from core.permit where id = p_permit_id;
  t := jsonb_build_object('customer_id', c.customer_id, 'venue_id', c.venue_id, 'record_id', m_id, 'target_type', 'custody_movement', 'area_id', c.area_id);
  r := jsonb_build_object('item_id', p_item_id, 'permit_id', p_permit_id, 'holder', p_holder_person_id);
  v := core.authorised_or_refusal('custody.issue', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if c.retired_at is not null or exists (select 1 from core.custody_movement where item_id = c.id and returned_at is null) then
    return core.refuse('custody.issue', 'not_available', 'This item is out, or no longer in use.', 'An item in the venue''s custody', 'Whoever holds it');
  end if;
  if p.id is null or p.venue_id <> c.venue_id or p.status not in ('approved_for_issue', 'issued_awaiting_acceptance', 'active', 'suspended')
     or not exists (select 1 from core.person where id = p_holder_person_id and customer_id = c.customer_id) then
    return core.refuse('custody.issue', 'invalid_content', 'Issue it against a current permit at this venue, to a named person.', 'A permit and a holder', 'You');
  end if;
  v := authz.require('custody.issue', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.custody_movement (id, customer_id, venue_id, item_id, permit_id, holder_person_id, issued_by_person_id, issue_decision_context_id)
  values (m_id, c.customer_id, c.venue_id, c.id, p.id, p_holder_person_id, (v ->> 'actor_person_id')::uuid, (v ->> 'decision_context_id')::uuid);
  return v || jsonb_build_object('movement_id', m_id);
end $$;

create function api.return_custody_item(p_idempotency_key text, p_movement_id uuid,
                                        p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare m core.custody_movement; c core.custody_item; t jsonb; r jsonb; v jsonb;
begin
  select * into m from core.custody_movement where id = p_movement_id;
  select * into c from core.custody_item where id = m.item_id;
  t := jsonb_build_object('customer_id', c.customer_id, 'venue_id', c.venue_id, 'record_id', m.id, 'target_type', 'custody_movement', 'area_id', c.area_id);
  r := jsonb_build_object('movement_id', p_movement_id);
  v := core.authorised_or_refusal('custody.return', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if m.returned_at is not null then
    return core.refuse('custody.return', 'already_returned', 'This item has already been returned.', 'An item that is out', 'Nobody');
  end if;
  v := authz.require('custody.return', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  update core.custody_movement set returned_at = clock_timestamp(), received_by_person_id = (v ->> 'actor_person_id')::uuid,
                                   return_decision_context_id = (v ->> 'decision_context_id')::uuid
   where id = m.id;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Control failure (design §8.5)
-- ---------------------------------------------------------------------------
insert into core.authority_action (code, basis, delegable, description) values
  ('isolation.failed', 'derived', false, 'Record that a proved isolation has failed and must be proved again');
insert into core.derived_action (parent_action, child_action) values
  ('control.report_failure',              'isolation.failed'),
  ('control.report_failure_as_authority', 'isolation.failed');
insert into core.state_transition (machine, from_state, to_state, required_action) values
  ('isolation', 'proved', 'applied', 'isolation.failed');

-- Reported by someone on the team of a protected permit, or a venue authority for the
-- system. Every live job relying on the control is suspended; a failed isolation must be
-- proved again.
create function api.report_control_failure(p_idempotency_key text, p_kind text, p_control_id uuid, p_reason text,
                                           p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  sys uuid; cst uuid; vn uuid; st text; via uuid; p core.permit; v_action text; t jsonb; r jsonb; v jsonb; ctx uuid; f_id uuid := gen_random_uuid();
  actor uuid; x record; q record; first_s uuid; s_id uuid;
begin
  set constraints core.live_dependency_check deferred;
  if p_kind = 'isolation' then
    select system_id, customer_id, venue_id, status into sys, cst, vn, st from core.isolation where id = p_control_id;
  elsif p_kind = 'impairment' then
    select system_id, customer_id, venue_id, status into sys, cst, vn, st from core.impairment where id = p_control_id;
  end if;
  via := (select l.permit_id from core.control_link l join core.permit_team_member m on m.permit_id = l.permit_id
           where l.control_kind = p_kind and l.control_id = p_control_id and m.removed_at is null and m.person_id = authz.actor_person(cst)
           order by l.permit_id limit 1);
  if via is not null then
    v_action := 'control.report_failure';
    select * into p from core.permit where id = via;
    t := core.permit_target(p, f_id, 'control_failure', null) || jsonb_build_object('permit_id', p.id);
  else
    v_action := 'control.report_failure_as_authority';
    t := core.system_target(sys, f_id, 'control_failure');
  end if;
  r := jsonb_build_object('kind', p_kind, 'control_id', p_control_id, 'reason', p_reason);
  v := core.authorised_or_refusal(v_action, t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if not ((p_kind = 'isolation' and st in ('applied', 'proved')) or (p_kind = 'impairment' and st = 'impaired')) then
    return core.refuse(v_action, 'not_in_place', 'Only a control in place can fail.', 'A control in place', 'Nobody');
  end if;
  if core.blank(p_reason) then
    return core.refuse(v_action, 'invalid_content', 'Say what has failed.', 'A reason', 'You');
  end if;
  v := authz.require(v_action, t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ctx := (v ->> 'decision_context_id')::uuid;
  actor := (v ->> 'actor_person_id')::uuid;
  insert into core.control_failure (id, customer_id, venue_id, control_kind, control_id, reason, reported_by_person_id, decision_context_id)
  values (f_id, cst, vn, p_kind, p_control_id, p_reason, actor, ctx);
  if p_kind = 'isolation' and st = 'proved' then
    perform authz.derive('isolation.failed', 'isolation', p_control_id);
    perform core.transition('core.isolation', p_control_id, 'applied', (select row_version from core.isolation where id = p_control_id),
                            core.ctx_uuid('decision_context_id'));
    perform core.add_control_event('isolation', p_control_id, cst, vn, 'failed', actor, jsonb_build_object('reason', p_reason, 'failure_id', f_id));
    perform authz.resume(ctx);
  elsif p_kind = 'impairment' then
    perform core.add_control_event('impairment', p_control_id, cst, vn, 'failed', actor, jsonb_build_object('reason', p_reason, 'failure_id', f_id));
  end if;
  -- Each job relying on the control: its linked permits held by the failure, the rest of
  -- the job by a stop that is lifted with it.
  for x in select distinct w.id as wp_id from core.control_link l join core.permit pp on pp.id = l.permit_id join core.work_package w on w.id = pp.work_package_id
            where l.control_kind = p_kind and l.control_id = p_control_id and core.is_live(pp.status) loop
    first_s := null;
    for q in select pp.id, exists (select 1 from core.control_link l where l.control_kind = p_kind and l.control_id = p_control_id and l.permit_id = pp.id) as linked
               from core.permit pp where pp.work_package_id = x.wp_id and core.is_live(pp.status)
              order by 2 desc, pp.kind desc, pp.id loop
      perform authz.derive('permit.suspend_with_job', 'permit', q.id);
      if q.linked then
        s_id := core.suspend_one(q.id, 'control_failure', null, p_reason, null, null, actor, f_id);
        first_s := coalesce(first_s, s_id);
      else
        perform core.suspend_one(q.id, 'job_stop', null, p_reason, first_s, null, actor);
      end if;
      perform authz.resume(ctx);
    end loop;
  end loop;
  perform core.check_live_now();
  return v || jsonb_build_object('failure_id', f_id);
end $$;

-- Lifted only by an authority for the system, never anyone connected with the jobs, and
-- only once the control is back in place (a failed isolation proved again).
create function api.lift_control_failure(p_idempotency_key text, p_failure_id uuid, p_reason text, p_conditions text[] default '{}',
                                         p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare f core.control_failure; sys uuid; st text; t jsonb; r jsonb; v jsonb;
begin
  select * into f from core.control_failure where id = p_failure_id;
  if f.control_kind = 'isolation' then select system_id, status into sys, st from core.isolation where id = f.control_id;
  else select system_id, status into sys, st from core.impairment where id = f.control_id; end if;
  t := core.system_target(sys, f.id, 'control_failure', core.control_people(f.control_kind, f.control_id));
  r := jsonb_build_object('failure_id', p_failure_id, 'reason', p_reason, 'conditions', to_jsonb(p_conditions));
  v := core.authorised_or_refusal('control.lift_failure', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if exists (select 1 from core.control_failure_resolution where failure_id = f.id) then
    return core.refuse('control.lift_failure', 'already_lifted', 'This failure has already been lifted.', 'An open failure', 'Nobody');
  end if;
  if (f.control_kind = 'isolation' and st <> 'proved') or (f.control_kind = 'impairment' and st <> 'impaired') then
    return core.refuse('control.lift_failure', 'not_restored',
      case f.control_kind when 'isolation' then 'The isolation must be proved again before the failure is lifted.'
                          else 'The impairment is no longer in place, so there is nothing to restore.' end,
      'The control back in place', 'The authorised person for the system');
  end if;
  if core.blank(p_reason) or exists (select 1 from unnest(coalesce(p_conditions, '{}')) c where core.blank(c)) then
    return core.refuse('control.lift_failure', 'invalid_content', 'Say how the control was restored, and give each condition wording.', 'A reason', 'You');
  end if;
  v := authz.require('control.lift_failure', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.control_failure_resolution (customer_id, venue_id, failure_id, reason, conditions, resolver_person_id, decision_context_id)
  values (f.customer_id, f.venue_id, f.id, p_reason, coalesce(p_conditions, '{}'), (v ->> 'actor_person_id')::uuid, (v ->> 'decision_context_id')::uuid);
  perform core.add_control_event(f.control_kind, f.control_id, f.customer_id, f.venue_id, 'failure_lifted', (v ->> 'actor_person_id')::uuid,
                                 jsonb_build_object('failure_id', f.id, 'reason', p_reason));
  return v;
end $$;

-- Suspensions: who lifts a control failure, and its conditions at re-acceptance.
create or replace function core.suspension_owner(s core.permit_suspension) returns text
language sql stable security definer set search_path = '' as $$
  select case s.kind
    when 'stop' then 'An issuer for this permit''s class and area'
    when 'job_stop' then format('Whoever can lift the stop on the job''s %s',
                                (select pc.name from core.permit_suspension o join core.permit x on x.id = o.permit_id
                                   join core.permit_class pc on pc.id = x.permit_class_id where o.id = s.origin_suspension_id))
    when 'area_stop' then format('A venue authority for %s',
                                 (select a.name from core.area_stop z join core.area a on a.id = z.area_id where z.id = s.area_stop_id))
    when 'control_failure' then format('The %s authority for %s, once the control is restored',
                                       (select f.control_kind from core.control_failure f where f.id = s.control_failure_id),
                                       (select y.name from core.control_failure f join core.system y
                                           on y.id = coalesce((select system_id from core.isolation where id = f.control_id),
                                                              (select system_id from core.impairment where id = f.control_id))
                                         where f.id = s.control_failure_id))
    when 'material_change' then 'Nobody: the job changed, so the permit must be submitted again and reissued'
    when 'supervisor_change' then 'Lifted by the change; the new supervisor re-accepts'
    when 'parent_ended' then 'Nobody: the Work Approval''s window has ended, so this permit must be handed back'
  end $$;

create or replace function core.permit_open_lifts(p_permit_id uuid) returns table (id uuid, conditions text[], created_at timestamptz)
language sql stable security definer set search_path = '' as $$
  with s as (select x.*, coalesce(o.id, x.id) as origin_id, coalesce(o.control_failure_id, x.control_failure_id) as failure_id
               from core.permit_suspension x left join core.permit_suspension o on o.id = x.origin_suspension_id
              where x.permit_id = p_permit_id)
  select l.id, l.conditions, l.created_at from s join core.permit_suspension_lift l on l.suspension_id = s.origin_id
   where l.created_at > coalesce(core.last_accepted_at(p_permit_id), '-infinity')
  union
  select l.id, l.conditions, l.created_at from s join core.area_stop_lift l on l.area_stop_id = s.area_stop_id
   where l.created_at > coalesce(core.last_accepted_at(p_permit_id), '-infinity')
  union
  select l.id, l.conditions, l.created_at from s join core.control_failure_resolution l on l.failure_id = s.failure_id
   where l.created_at > coalesce(core.last_accepted_at(p_permit_id), '-infinity') $$;

-- ---------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------
create function core.permit_controls(p_permit_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'required', core.permit_class_controls(p),
    'blockers', core.control_blockers(p.id),
    'isolations', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', i.id, 'system', y.name, 'points', i.points, 'status', i.status, 'row_version', i.row_version,
        'failure_open', core.failure_open('isolation', i.id),
        'locks', (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'name', core.person_name(k.person_id), 'lock_ref', k.lock_ref, 'on_at', k.on_at)
                                            order by k.on_at), '[]') from core.isolation_lock k where k.isolation_id = i.id and k.off_at is null),
        'steps', (select coalesce(jsonb_agg(jsonb_build_object('step', e.step, 'by', core.person_name(e.person_id), 'at', e.created_at) order by e.created_at), '[]')
                    from core.control_event e where e.control_kind = 'isolation' and e.control_id = i.id))
        order by y.name), '[]')
      from core.control_link l join core.isolation i on i.id = l.control_id join core.system y on y.id = i.system_id
     where l.control_kind = 'isolation' and l.permit_id = p.id),
    'impairments', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', i.id, 'system', y.name, 'zones', i.zones, 'status', i.status, 'row_version', i.row_version, 'max_hours', i.max_hours,
        'impaired_at', i.impaired_at, 'due_at', i.impaired_at + make_interval(secs => (coalesce(i.max_hours, 0) * 3600)::double precision),
        'overdue', core.impairment_overdue(i), 'failure_open', core.failure_open('impairment', i.id))
        order by y.name), '[]')
      from core.control_link l join core.impairment i on i.id = l.control_id join core.system y on y.id = i.system_id
     where l.control_kind = 'impairment' and l.permit_id = p.id),
    'fire_watches', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', w.id, 'phase', w.phase, 'watcher', core.person_name(w.watcher_person_id), 'status', w.status, 'row_version', w.row_version,
        'minimum_minutes', w.minimum_minutes, 'started_at', w.started_at, 'ended_at', w.ended_at,
        'earliest_end', w.started_at + make_interval(mins => w.minimum_minutes)) order by w.created_at), '[]')
      from core.fire_watch w where w.permit_id = p.id),
    'exclusion_zones', (select coalesce(jsonb_agg(jsonb_build_object('id', z.id, 'description', z.description, 'area', (select name from core.area where id = z.area_id),
                                                                      'status', z.status, 'row_version', z.row_version, 'removed_at', z.removed_at)
                                                   order by z.created_at), '[]')
      from core.exclusion_zone z where z.permit_id = p.id),
    'custody', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'item', c.label, 'kind', c.kind, 'reference', c.reference,
                                                             'holder', core.person_name(m.holder_person_id), 'issued_at', m.issued_at, 'returned_at', m.returned_at)
                                          order by m.issued_at), '[]')
      from core.custody_movement m join core.custody_item c on c.id = m.item_id where m.permit_id = p.id))
  from core.permit p where p.id = p_permit_id $$;

-- The controls desk: system controls at venues where the caller holds a control action.
create function api.controls_desk() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('ok', true,
    'isolations', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', i.id, 'system', y.name, 'points', i.points, 'status', i.status, 'row_version', i.row_version, 'from', lower(i.planned_window),
        'to', upper(i.planned_window), 'requested_by', core.person_name(i.requested_by_person_id), 'failure_open', core.failure_open('isolation', i.id),
        'locks_on', (select count(*) from core.isolation_lock k where k.isolation_id = i.id and k.off_at is null),
        'venue_timezone', (select timezone from core.venue where id = i.venue_id),
        'jobs', (select jsonb_agg(distinct w.reference) from core.control_link l join core.permit pp on pp.id = l.permit_id
                   join core.work_package w on w.id = pp.work_package_id where l.control_kind = 'isolation' and l.control_id = i.id))
        order by lower(i.planned_window)), '[]')
      from core.isolation i join core.system y on y.id = i.system_id
     where i.status not in ('returned', 'refused', 'withdrawn')
       and i.venue_id in (select authz.my_action_venue_ids(a) from unnest(array['isolation.authorise', 'isolation.apply', 'isolation.prove',
                                                                                'isolation.remove', 'isolation.return']) a)),
    'impairments', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', i.id, 'system', y.name, 'zones', i.zones, 'status', i.status, 'row_version', i.row_version, 'from', lower(i.planned_window),
        'to', upper(i.planned_window), 'requested_by', core.person_name(i.requested_by_person_id), 'max_hours', i.max_hours,
        'impaired_at', i.impaired_at, 'overdue', core.impairment_overdue(i), 'failure_open', core.failure_open('impairment', i.id),
        'venue_timezone', (select timezone from core.venue where id = i.venue_id),
        'jobs', (select jsonb_agg(distinct w.reference) from core.control_link l join core.permit pp on pp.id = l.permit_id
                   join core.work_package w on w.id = pp.work_package_id where l.control_kind = 'impairment' and l.control_id = i.id))
        order by core.impairment_overdue(i) desc, lower(i.planned_window)), '[]')
      from core.impairment i join core.system y on y.id = i.system_id
     where i.status not in ('restored', 'refused', 'withdrawn')
       and i.venue_id in (select authz.my_action_venue_ids(a) from unnest(array['impairment.authorise', 'impairment.impair', 'impairment.test',
                                                                                'impairment.restore', 'impairment.reauthorise']) a))) $$;

-- ---------------------------------------------------------------------------
-- Wiring: issue, acceptance, re-acceptance and the snapshot (P6-8 replaces P5-11)
-- ---------------------------------------------------------------------------
create or replace function core.live_blockers(p_permit_id uuid, p_window tstzrange) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare b jsonb := '[]';
begin
  if isempty(p_window) or upper(p_window) <= now() then
    return jsonb_build_array(jsonb_build_object('check', 'window', 'problem', 'The permit''s window has ended.', 'who', 'Nobody: the work must be handed back'));
  end if;
  return b || core.org_blockers(p_permit_id, p_window) || core.team_blockers(p_permit_id, p_window)
           || core.restriction_blockers(p_permit_id, p_window) || core.control_blockers(p_permit_id);
end $$;

do $m$
declare d text;
  old_block constant text := $o$  -- Physical controls (P5-11).
  if (cv.content ->> 'requires_physical_controls')::boolean then
    b := b || jsonb_build_object('check', 'controls', 'problem',
      'This class needs physical controls (isolation, impairment or fire watch), which cannot be recorded yet, so it cannot be issued.',
      'who', 'Nobody until live controls are available');
  end if;$o$;
begin
  d := pg_get_functiondef('core.issue_blockers(uuid)'::regprocedure);
  if position(old_block in d) = 0 then
    raise exception 'core.issue_blockers no longer has the expected structure';
  end if;
  execute replace(d, old_block, E'  -- Physical controls (P6-8): the controls the class needs, in place now.\n  b := b || core.control_blockers(p.id);');

  d := pg_get_functiondef('api.accept_permit(text,uuid,integer,uuid[],uuid[],timestamptz)'::regprocedure);
  if position('  v := authz.require(''permit.accept'', t, p_idempotency_key, r);' in d) = 0 then
    raise exception 'api.accept_permit no longer has the expected structure';
  end if;
  execute replace(d, '  v := authz.require(''permit.accept'', t, p_idempotency_key, r);', $r$  if jsonb_array_length(core.control_blockers(p.id)) > 0 then
    return core.refuse('permit.accept', 'controls_not_ready', 'The physical controls this permit needs are not all in place.', 'Each item listed',
                       'As listed for each item', jsonb_build_object('blockers', core.control_blockers(p.id)));
  end if;
  v := authz.require('permit.accept', t, p_idempotency_key, r);$r$);

  d := pg_get_functiondef('api.issue_permit(text,uuid,integer,uuid,uuid)'::regprocedure);
  if position('''issued_at'', clock_timestamp(), ''previous_snapshot_id''' in d) = 0 then
    raise exception 'api.issue_permit no longer has the expected structure';
  end if;
  execute replace(d, '''issued_at'', clock_timestamp(), ''previous_snapshot_id''',
                     '''controls'', core.permit_controls(p.id), ''issued_at'', clock_timestamp(), ''previous_snapshot_id''');

  d := pg_get_functiondef('api.permit_detail(uuid)'::regprocedure);
  if position('|| core.permit_live(p.id);' in d) = 0 then
    raise exception 'api.permit_detail no longer has the expected structure';
  end if;
  execute replace(d, '|| core.permit_live(p.id);', '|| core.permit_live(p.id) || jsonb_build_object(''controls'', core.permit_controls(p.id));');

  d := pg_get_functiondef('api.lift_suspension(text,uuid,text,text[],uuid,uuid)'::regprocedure);
  if position('                  when ''material_change'' then' in d) = 0 then
    raise exception 'api.lift_suspension no longer has the expected structure';
  end if;
  execute replace(d, '                  when ''material_change'' then', $r$                  when 'control_failure' then 'This permit was stopped because a physical control failed. The control''s authority lifts it, once the control is restored.'
                  when 'material_change' then$r$);
end $m$;

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------
create view api.system_control_rule        with (security_invoker = true) as select * from core.system_control_rule;
create view api.isolation                  with (security_invoker = true) as
  select id, customer_id, venue_id, system_id, points, reason, lower(planned_window) as starts_at, upper(planned_window) as ends_at, status,
         requested_by_person_id, rule_version_id, row_version, created_at from core.isolation;
create view api.impairment                 with (security_invoker = true) as
  select id, customer_id, venue_id, system_id, zones, reason, lower(planned_window) as starts_at, upper(planned_window) as ends_at, status,
         requested_by_person_id, rule_version_id, max_hours, impaired_at, row_version, created_at from core.impairment;
create view api.control_link               with (security_invoker = true) as select * from core.control_link;
create view api.control_event              with (security_invoker = true) as select * from core.control_event;
create view api.isolation_lock             with (security_invoker = true) as select * from core.isolation_lock;
create view api.fire_watch                 with (security_invoker = true) as select * from core.fire_watch;
create view api.exclusion_zone             with (security_invoker = true) as select * from core.exclusion_zone;
create view api.custody_item               with (security_invoker = true) as select * from core.custody_item;
create view api.custody_movement           with (security_invoker = true) as select * from core.custody_movement;
create view api.control_failure            with (security_invoker = true) as select * from core.control_failure;
create view api.control_failure_resolution with (security_invoker = true) as select * from core.control_failure_resolution;
create or replace view api.permit_suspension with (security_invoker = true) as select * from core.permit_suspension;

grant select on all tables in schema api to authenticated;
grant execute on all functions in schema api to authenticated;
revoke execute on all functions in schema api from anon, public;
