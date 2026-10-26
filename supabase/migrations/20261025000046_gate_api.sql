-- 0046 Gate API (phase 7a, D-020)
--
-- Same pattern as before: a repeated request is replayed first; readiness checks refuse with
-- what is missing and who can resolve it; authority only from authz.evaluate. A scan writes
-- the evaluation it showed; what the operator then did is recorded separately, and only
-- against a recent evaluation, so nothing is admitted on an old answer (invariant 11).
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

-- ---------------------------------------------------------------------------
-- Entry rules: drafted and proposed by the venue, approved by an access authority (P7-2)
-- ---------------------------------------------------------------------------
create function api.create_entry_rule_draft(p_idempotency_key text, p_venue_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare vn core.venue; v_id uuid := gen_random_uuid(); prev core.entry_rule_version; t jsonb; v jsonb;
begin
  select * into vn from core.venue where id = p_venue_id;
  t := jsonb_build_object('customer_id', vn.customer_id, 'venue_id', vn.id, 'record_id', v_id, 'target_type', 'entry_rule_version');
  v := core.authorised_or_refusal('entry_rule_version.draft', t, p_idempotency_key, jsonb_build_object('venue_id', p_venue_id));
  if v is not null then return v; end if;
  if exists (select 1 from core.entry_rule_version where venue_id = vn.id and status in ('draft', 'proposed')) then
    return core.refuse('entry_rule_version.draft', 'in_progress', 'The entry rules already have a version in progress: finish or reject it first.',
                       'No version in progress', 'The venue''s tenant administrator');
  end if;
  v := authz.require('entry_rule_version.draft', t, p_idempotency_key, jsonb_build_object('venue_id', p_venue_id));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  select * into prev from core.entry_rule_version where venue_id = vn.id order by version_no desc limit 1;
  insert into core.entry_rule_version (id, customer_id, venue_id, version_no, status, content, authored_by_person_id)
  values (v_id, vn.customer_id, vn.id, coalesce(prev.version_no, 0) + 1, 'draft', coalesce(prev.content, '{"audiences": []}'), (v ->> 'actor_person_id')::uuid);
  return v || jsonb_build_object('id', v_id);
end $$;

create function api.save_entry_rule_draft(p_idempotency_key text, p_version_id uuid, p_expected_version integer, p_content jsonb, p_source_ref text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c core.entry_rule_version; t jsonb; r jsonb; v jsonb; problems text[];
begin
  select * into c from core.entry_rule_version where id = p_version_id;
  t := jsonb_build_object('customer_id', c.customer_id, 'venue_id', c.venue_id, 'record_id', p_version_id, 'target_type', 'entry_rule_version');
  r := jsonb_build_object('version_id', p_version_id, 'expected_version', p_expected_version, 'content', p_content, 'source', p_source_ref);
  v := core.authorised_or_refusal('entry_rule_version.save_draft', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if c.status <> 'draft' then
    return core.refuse('entry_rule_version.save_draft', 'not_draft', 'Only a draft can be changed.', 'A draft', 'You, by starting a new version');
  end if;
  problems := core.validate_entry_rules(c.venue_id, coalesce(p_content, '{}'), false);
  if cardinality(problems) > 0 then
    return core.refuse('entry_rule_version.save_draft', 'invalid_content', 'The entry rules have problems.', 'Each item listed', 'You',
                       jsonb_build_object('problems', to_jsonb(problems)));
  end if;
  v := authz.require('entry_rule_version.save_draft', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  if c.row_version <> p_expected_version then
    raise exception 'these entry rules changed since you opened them' using errcode = 'PT409';
  end if;
  update core.entry_rule_version set content = p_content, source_ref = p_source_ref where id = c.id;
  return v;
end $$;

create function api.propose_entry_rule_version(p_idempotency_key text, p_version_id uuid, p_expected_version integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c core.entry_rule_version; t jsonb; r jsonb; v jsonb; problems text[];
begin
  select * into c from core.entry_rule_version where id = p_version_id;
  t := jsonb_build_object('customer_id', c.customer_id, 'venue_id', c.venue_id, 'record_id', p_version_id, 'target_type', 'entry_rule_version');
  r := jsonb_build_object('version_id', p_version_id, 'expected_version', p_expected_version);
  v := core.authorised_or_refusal('entry_rule_version.propose', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  problems := core.validate_entry_rules(c.venue_id, c.content, true);
  if c.status <> 'draft' then problems := problems || text 'Only a draft can be proposed.'; end if;
  if cardinality(problems) > 0 then
    return core.refuse('entry_rule_version.propose', 'not_ready', 'These entry rules are not ready for approval.', 'Each item listed', 'You',
                       jsonb_build_object('problems', to_jsonb(problems)));
  end if;
  v := authz.require('entry_rule_version.propose', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.entry_rule_version', c.id, 'proposed', p_expected_version, (v ->> 'decision_context_id')::uuid,
    jsonb_build_object('proposed_by_person_id', v ->> 'actor_person_id', 'content_sha256', encode(sha256(convert_to(c.content::text, 'UTF8')), 'hex')));
  return v;
end $$;

-- Approved by an appointee whose appointment covers the whole venue; never the author or
-- the proposer.
create function api.decide_entry_rule_version(p_idempotency_key text, p_version_id uuid, p_expected_version integer, p_decision text, p_reason text,
                                              p_acting_appointment_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c core.entry_rule_version; prev uuid; ctx uuid; t jsonb; r jsonb; v jsonb; v_action text;
begin
  select * into c from core.entry_rule_version where id = p_version_id;
  v_action := case when p_decision = 'reject' then 'entry_rule_version.reject' else 'entry_rule_version.approve' end;
  t := jsonb_build_object('customer_id', c.customer_id, 'venue_id', c.venue_id, 'record_id', p_version_id, 'target_type', 'entry_rule_version',
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
    select id into prev from core.entry_rule_version where venue_id = c.venue_id and status = 'approved';
    if prev is not null then
      perform authz.derive('entry_rule_version.supersede', 'entry_rule_version', prev);
      perform core.transition('core.entry_rule_version', prev, 'superseded', (select row_version from core.entry_rule_version where id = prev),
                              core.ctx_uuid('decision_context_id'));
      perform authz.resume(ctx);
    end if;
  end if;
  perform core.transition('core.entry_rule_version', c.id, case p_decision when 'approve' then 'approved' else 'rejected' end, p_expected_version, ctx,
    jsonb_build_object('decided_by_person_id', v ->> 'actor_person_id', 'decided_at', clock_timestamp(), 'decision_reason', p_reason));
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Gate points and passes (P7-3)
-- ---------------------------------------------------------------------------
create function api.create_gate_point(p_idempotency_key text, p_venue_id uuid, p_area_id uuid, p_name text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare vn core.venue; t jsonb; r jsonb; v jsonb; g_id uuid := gen_random_uuid();
begin
  select * into vn from core.venue where id = p_venue_id;
  t := jsonb_build_object('customer_id', vn.customer_id, 'venue_id', vn.id, 'record_id', g_id, 'target_type', 'gate_point');
  r := jsonb_build_object('venue_id', p_venue_id, 'area_id', p_area_id, 'name', p_name);
  v := core.authorised_or_refusal('gate_point.create', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if core.blank(p_name) or not exists (select 1 from core.area where id = p_area_id and venue_id = vn.id)
     or exists (select 1 from core.gate_point where venue_id = vn.id and name = p_name) then
    return core.refuse('gate_point.create', 'invalid_content', 'Give the gate point a unique name and the area it opens into.', 'A name and area', 'You');
  end if;
  v := authz.require('gate_point.create', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.gate_point (id, customer_id, venue_id, area_id, name) values (g_id, vn.customer_id, vn.id, p_area_id, p_name);
  return v || jsonb_build_object('id', g_id);
end $$;

create function core.next_pass_number(p_venue_id uuid, p_prefix text) returns text
language sql stable security definer set search_path = '' as $$
  select p_prefix || '-' || lpad(((select count(*) from core.person_pass where venue_id = p_venue_id) + 1)::text, 6, '0') $$;

-- A printed card (for people without a phone or an account, 6b-2). The token is returned
-- once, for printing; only its hash is kept.
create function api.issue_card_pass(p_idempotency_key text, p_person_id uuid, p_venue_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare vn core.venue; t jsonb; r jsonb; v jsonb; p_id uuid := gen_random_uuid(); num text; token text;
begin
  select * into vn from core.venue where id = p_venue_id;
  t := jsonb_build_object('customer_id', vn.customer_id, 'venue_id', vn.id, 'record_id', p_id, 'target_type', 'person_pass');
  r := jsonb_build_object('person_id', p_person_id, 'venue_id', p_venue_id);
  v := core.authorised_or_refusal('pass.issue_card', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if not exists (select 1 from core.person where id = p_person_id and customer_id = vn.customer_id and deactivated_at is null) then
    return core.refuse('pass.issue_card', 'invalid_content', 'Choose an active person.', 'A person', 'You');
  end if;
  if exists (select 1 from core.person_pass where venue_id = vn.id and person_id = p_person_id and kind = 'card' and revoked_at is null) then
    return core.refuse('pass.issue_card', 'card_exists', 'This person already has a card here: revoke it first if it is lost.', 'No live card', 'You');
  end if;
  v := authz.require('pass.issue_card', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  num := core.next_pass_number(vn.id, 'C');
  token := translate(encode(extensions.gen_random_bytes(18), 'base64'), '+/', '-_');
  insert into core.person_pass (id, customer_id, venue_id, person_id, kind, pass_number, token_hash, issued_by_person_id, decision_context_id)
  values (p_id, vn.customer_id, vn.id, p_person_id, 'card', num, sha256(convert_to(token, 'UTF8')), (v ->> 'actor_person_id')::uuid,
          (v ->> 'decision_context_id')::uuid);
  return v || jsonb_build_object('pass_id', p_id, 'pass_number', num, 'payload', 'OCTRA1:C:' || num || ':' || token);
end $$;

create function api.create_phone_pass(p_idempotency_key text, p_venue_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare vn core.venue; me uuid; t jsonb; r jsonb; v jsonb; p_id uuid := gen_random_uuid(); num text;
begin
  select * into vn from core.venue where id = p_venue_id;
  me := authz.actor_person(vn.customer_id);
  t := jsonb_build_object('customer_id', vn.customer_id, 'venue_id', vn.id, 'record_id', p_id, 'target_type', 'person_pass', 'subject_person_id', me);
  r := jsonb_build_object('venue_id', p_venue_id);
  v := core.authorised_or_refusal('pass.create_phone', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if exists (select 1 from core.person_pass where venue_id = vn.id and person_id = me and kind = 'phone' and revoked_at is null) then
    return core.refuse('pass.create_phone', 'pass_exists', 'You already have a phone pass here.', 'No live phone pass', 'Nobody');
  end if;
  v := authz.require('pass.create_phone', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  num := core.next_pass_number(vn.id, 'M');
  insert into core.person_pass (id, customer_id, venue_id, person_id, kind, pass_number, secret, issued_by_person_id, decision_context_id)
  values (p_id, vn.customer_id, vn.id, me, 'phone', num, extensions.gen_random_bytes(32), me, (v ->> 'decision_context_id')::uuid);
  return v || jsonb_build_object('pass_id', p_id, 'pass_number', num);
end $$;

-- The caller's current phone pass code. The secret never leaves the database.
create function api.phone_pass_code(p_venue_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare k core.person_pass; step bigint := floor(extract(epoch from clock_timestamp()) / 30)::bigint;
begin
  select * into k from core.person_pass where venue_id = p_venue_id and kind = 'phone' and revoked_at is null
     and person_id in (select authz.my_person_ids());
  if k.id is null then
    return core.refuse('pass.create_phone', 'not_found', 'You have no phone pass here.', 'A phone pass', 'You, by creating one');
  end if;
  return jsonb_build_object('ok', true, 'pass_number', k.pass_number, 'payload', 'OCTRA1:P:' || k.pass_number || ':' || core.pass_code(k.secret, k.pass_number, step),
                            'seconds_left', 30 - (floor(extract(epoch from clock_timestamp()))::bigint % 30));
end $$;

create function api.revoke_pass(p_idempotency_key text, p_pass_id uuid, p_reason text,
                                p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare k core.person_pass; v_action text; t jsonb; r jsonb; v jsonb;
begin
  select * into k from core.person_pass where id = p_pass_id;
  v_action := case when k.customer_id in (select authz.my_admin_customer_ids()) then 'pass.revoke_for_venue' else 'pass.revoke' end;
  t := jsonb_build_object('customer_id', k.customer_id, 'venue_id', k.venue_id, 'record_id', p_pass_id, 'target_type', 'person_pass');
  r := jsonb_build_object('pass_id', p_pass_id, 'reason', p_reason);
  v := core.authorised_or_refusal(v_action, t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if k.revoked_at is not null then
    return core.refuse(v_action, 'already_revoked', 'This pass is already revoked.', 'A live pass', 'Nobody');
  end if;
  if core.blank(p_reason) then
    return core.refuse(v_action, 'invalid_content', 'Say why the pass is revoked.', 'A reason', 'You');
  end if;
  v := authz.require(v_action, t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  update core.person_pass set revoked_at = clock_timestamp(), revoked_by_person_id = (v ->> 'actor_person_id')::uuid, revoke_reason = p_reason,
                              revoke_decision_context_id = (v ->> 'decision_context_id')::uuid
   where id = k.id;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Scanning (Q191-Q197, P7-5)
-- ---------------------------------------------------------------------------
create function core.gate_target(gp core.gate_point, p_record_id uuid, p_type text, p_excluded jsonb default '[]') returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('customer_id', gp.customer_id, 'venue_id', gp.venue_id, 'record_id', p_record_id, 'target_type', p_type,
                            'area_id', gp.area_id, 'excluded_person_ids', p_excluded) $$;

-- Evaluates a pass at a gate point and records the evaluation shown.
create function core.scan(p_idempotency_key text, p_gate_point_id uuid, p_pass_number text, p_method text, p_secret_part text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare gp core.gate_point; k core.person_pass; t jsonb; r jsonb; v jsonb; e_id uuid := gen_random_uuid(); res jsonb; step bigint;
begin
  select * into gp from core.gate_point where id = p_gate_point_id and retired_at is null;
  t := core.gate_target(gp, e_id, 'entry_eligibility_evaluation');
  r := jsonb_build_object('gate_point_id', p_gate_point_id, 'pass_number', p_pass_number, 'method', p_method);
  v := core.authorised_or_refusal('gate.operate', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  v := authz.require('gate.operate', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  select * into k from core.person_pass where venue_id = gp.venue_id and pass_number = upper(btrim(coalesce(p_pass_number, '')));
  step := floor(extract(epoch from clock_timestamp()) / 30)::bigint;
  if k.id is null then
    res := jsonb_build_object('outcome', 'do_not_admit', 'person', null, 'reasons', jsonb_build_array(jsonb_build_object('code', 'pass_unknown', 'severity', 'do_not_admit',
             'words', 'This pass is not recognised here.', 'owner', 'The venue''s pass desk', 'overridable', false)), 'notices', '[]', 'overrides', '[]');
  elsif k.revoked_at is not null then
    res := core.entry_evaluation(k.person_id, gp.venue_id, gp.id);
    res := res || jsonb_build_object('outcome', 'do_not_admit', 'reasons', (res -> 'reasons') || jsonb_build_object('code', 'pass_revoked', 'severity', 'do_not_admit',
             'words', 'This pass has been revoked.', 'owner', 'The venue''s pass desk', 'overridable', false));
  elsif (p_method = 'phone' and (k.kind <> 'phone' or p_secret_part is null
          or p_secret_part not in (core.pass_code(k.secret, k.pass_number, step), core.pass_code(k.secret, k.pass_number, step - 1))))
        or (p_method = 'card' and (k.kind <> 'card' or k.token_hash is distinct from sha256(convert_to(coalesce(p_secret_part, ''), 'UTF8')))) then
    -- A code that does not verify (an old screenshot, a copy): the pass is not trusted, so look
    -- the person up by number and check identity (Q197).
    res := core.entry_evaluation(k.person_id, gp.venue_id, gp.id);
    res := res || jsonb_build_object('outcome', case when res ->> 'outcome' = 'do_not_admit' then 'do_not_admit' else 'check' end,
             'reasons', (res -> 'reasons') || jsonb_build_object('code', 'pass_not_verified', 'severity', 'check',
             'words', 'The pass code did not verify (it may be old or copied).', 'owner', 'The operator: check identity and look the pass up by number',
             'overridable', false));
  else
    res := core.entry_evaluation(k.person_id, gp.venue_id, gp.id);
  end if;
  insert into core.entry_eligibility_evaluation (id, customer_id, venue_id, gate_point_id, person_id, pass_id, method, outcome, result, rule_version_id,
                                                 operator_person_id, decision_context_id)
  values (e_id, gp.customer_id, gp.venue_id, gp.id, k.person_id, k.id, p_method, res ->> 'outcome', res, (res ->> 'rule_version_id')::uuid,
          (v ->> 'actor_person_id')::uuid, (v ->> 'decision_context_id')::uuid);
  return v || jsonb_build_object('evaluation_id', e_id, 'result', res,
                                 'pass', case when k.id is null then null else jsonb_build_object('number', k.pass_number, 'kind', k.kind) end);
end $$;

-- A scanned code: OCTRA1:P:<number>:<code> (phone) or OCTRA1:C:<number>:<token> (card).
create function api.scan_entry(p_idempotency_key text, p_gate_point_id uuid, p_payload text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare parts text[] := string_to_array(coalesce(p_payload, ''), ':');
begin
  if cardinality(parts) <> 4 or parts[1] <> 'OCTRA1' or parts[2] not in ('P', 'C') then
    return core.refuse('gate.operate', 'invalid_content', 'This is not an Octra pass. Look the person up by pass number instead.', 'An Octra pass', 'The operator');
  end if;
  return core.scan(p_idempotency_key, p_gate_point_id, parts[3], case parts[2] when 'P' then 'phone' else 'card' end, parts[4]);
end $$;

-- A typed pass number, when a code will not scan. Identity must then be checked in person.
create function api.lookup_entry(p_idempotency_key text, p_gate_point_id uuid, p_pass_number text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  return core.scan(p_idempotency_key, p_gate_point_id, p_pass_number, 'manual', null);
end $$;

-- What the operator did with an evaluation (Q197). Only against a recent evaluation, never a
-- stale one, and never admitting on Do not admit.
create function api.record_gate_action(p_idempotency_key text, p_evaluation_id uuid, p_direction text, p_identity_method text, p_action text,
                                       p_note text default null, p_escort_name text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e core.entry_eligibility_evaluation; gp core.gate_point; t jsonb; r jsonb; v jsonb; s_id uuid := gen_random_uuid();
begin
  select * into e from core.entry_eligibility_evaluation where id = p_evaluation_id;
  select * into gp from core.gate_point where id = e.gate_point_id;
  t := core.gate_target(gp, s_id, 'scan_event');
  r := jsonb_build_object('evaluation_id', p_evaluation_id, 'direction', p_direction, 'identity', p_identity_method, 'action', p_action,
                          'note', p_note, 'escort', p_escort_name);
  v := core.authorised_or_refusal('gate.operate', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if exists (select 1 from core.scan_event where evaluation_id = e.id) then
    return core.refuse('gate.operate', 'already_recorded', 'What happened with this scan is already recorded.', 'A new scan', 'The operator');
  end if;
  if clock_timestamp() - e.evaluated_at > interval '5 minutes' then
    return core.refuse('gate.operate', 'stale', 'This result is more than five minutes old. Scan again for a current answer.', 'A current scan', 'The operator');
  end if;
  if coalesce(p_direction, '') not in ('in', 'out') or coalesce(p_identity_method, '') not in ('photo_id', 'known_to_operator', 'not_checked')
     or coalesce(p_action, '') not in ('admitted', 'refused', 'referred') then
    return core.refuse('gate.operate', 'invalid_content', 'Record the direction, how identity was checked and what you did.', 'Each detail', 'The operator');
  end if;
  if p_direction = 'in' and p_action = 'admitted' then
    if p_identity_method = 'not_checked' then
      return core.refuse('gate.operate', 'identity_not_checked', 'Check the person''s identity before admitting them.', 'An identity check', 'The operator');
    end if;
    if e.outcome = 'do_not_admit' then
      return core.refuse('gate.operate', 'not_admissible', 'The result is Do not admit. Only an access authority can set a refusal aside, where it can be set aside.',
                         'An override, where allowed', 'The venue''s access authority');
    end if;
    if e.outcome = 'check' and core.blank(p_note) then
      return core.refuse('gate.operate', 'check_first', 'The result is Check: record who you checked with and what they said.', 'A note', 'The operator');
    end if;
    if e.outcome = 'admit_with_escort' and core.blank(p_escort_name) then
      return core.refuse('gate.operate', 'escort_required', 'Name the escort.', 'An escort', 'The operator');
    end if;
  end if;
  v := authz.require('gate.operate', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.scan_event (id, customer_id, venue_id, evaluation_id, gate_point_id, person_id, direction, identity_method, action, note, escort_name,
                               override_ids, operator_person_id, decision_context_id)
  values (s_id, e.customer_id, e.venue_id, e.id, e.gate_point_id, e.person_id, p_direction, p_identity_method, p_action, nullif(btrim(coalesce(p_note, '')), ''),
          nullif(btrim(coalesce(p_escort_name, '')), ''),
          array(select (o ->> 'id')::uuid from jsonb_array_elements(coalesce(e.result -> 'overrides', '[]')) o),
          (v ->> 'actor_person_id')::uuid, (v ->> 'decision_context_id')::uuid);
  return v || jsonb_build_object('scan_event_id', s_id);
end $$;

-- ---------------------------------------------------------------------------
-- Overrides (Q195, P7-6): an access authority covering the gate point's area, never the
-- person themselves or anyone from their organisations; time-limited; never the floor or
-- the venue's never-overridable reasons.
-- ---------------------------------------------------------------------------
create function api.override_entry(p_idempotency_key text, p_person_id uuid, p_gate_point_id uuid, p_reason_codes text[], p_purpose text, p_reason text,
                                   p_valid_to timestamptz, p_escort text default null,
                                   p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare gp core.gate_point; never text[]; t jsonb; r jsonb; v jsonb; o_id uuid := gen_random_uuid(); excluded jsonb;
begin
  select * into gp from core.gate_point where id = p_gate_point_id;
  excluded := jsonb_build_array(p_person_id) || coalesce((select jsonb_agg(x) from core.person_organisation_relationship rr,
                                                           jsonb_array_elements(core.organisation_people(rr.organisation_id)) x
                                                          where rr.person_id = p_person_id and rr.status = 'active'), '[]');
  t := core.gate_target(gp, o_id, 'entry_override', excluded);
  r := jsonb_build_object('person_id', p_person_id, 'gate_point_id', p_gate_point_id, 'reasons', to_jsonb(p_reason_codes), 'purpose', p_purpose,
                          'reason', p_reason, 'valid_to', p_valid_to, 'escort', p_escort);
  v := core.authorised_or_refusal('gate.override', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  never := array(select jsonb_array_elements_text(coalesce((select content -> 'never_overridable' from core.entry_rule_version
                                                             where venue_id = gp.venue_id and status = 'approved'), '[]')));
  if cardinality(coalesce(p_reason_codes, '{}')) = 0 or p_reason_codes && core.entry_reason_floor() or p_reason_codes && never
     or not (p_reason_codes <@ core.entry_reason_overridable()) then
    return core.refuse('gate.override', 'not_overridable',
      'These reasons cannot be set aside at a gate: a restriction, a revoked or unknown pass, an inactive record, and any reason the venue has made never-overridable.',
      'A reason that can be overridden', 'The authority that owns the underlying decision');
  end if;
  if not exists (select 1 from core.person where id = p_person_id and customer_id = gp.customer_id) or core.blank(p_purpose) or core.blank(p_reason)
     or p_valid_to is null or p_valid_to <= clock_timestamp() then
    return core.refuse('gate.override', 'invalid_content', 'Give the purpose, the reason, and when the override ends (never open-ended).', 'Each detail', 'You');
  end if;
  v := authz.require('gate.override', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.entry_override (id, customer_id, venue_id, person_id, area_id, reason_codes, purpose, reason, escort, valid_during, granted_by_person_id, decision_context_id)
  values (o_id, gp.customer_id, gp.venue_id, p_person_id, gp.area_id, p_reason_codes, p_purpose, p_reason, nullif(btrim(coalesce(p_escort, '')), ''),
          tstzrange(now(), p_valid_to), (v ->> 'actor_person_id')::uuid, (v ->> 'decision_context_id')::uuid);
  return v || jsonb_build_object('override_id', o_id);
end $$;

-- A person's own entry result at a venue, now: the same evaluation, recording nothing.
create function api.my_entry(p_venue_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare me uuid := authz.actor_person((select customer_id from core.venue where id = p_venue_id));
begin
  if me is null then
    return core.refuse('pass.create_phone', 'not_found', 'You have no record at this venue.', 'A person record', 'The venue');
  end if;
  return jsonb_build_object('ok', true) || core.entry_evaluation(me, p_venue_id, null);
end $$;

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------
create view api.entry_rule_version          with (security_invoker = true) as select * from core.entry_rule_version;
create view api.gate_point                  with (security_invoker = true) as select * from core.gate_point;
create view api.person_pass                 with (security_invoker = true) as
  select id, customer_id, venue_id, person_id, kind, pass_number, issued_by_person_id, revoked_at, revoked_by_person_id, revoke_reason, row_version, created_at
    from core.person_pass;
create view api.entry_eligibility_evaluation with (security_invoker = true) as select * from core.entry_eligibility_evaluation;
create view api.scan_event                  with (security_invoker = true) as select * from core.scan_event;
create view api.entry_override              with (security_invoker = true) as select * from core.entry_override;

grant select on all tables in schema api to authenticated;
grant execute on all functions in schema api to authenticated;
revoke execute on all functions in schema api from anon, public;
