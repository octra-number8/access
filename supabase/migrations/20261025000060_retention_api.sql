-- 0060 Retention, legal holds, disposal and live-record corrections API (phase 8d(a), D-022)
--
-- The schedule uses the venue configuration routes, approved by a `retention.approve` appointee.
-- Holds are requested and decided by different appointees. The job runner lists what has run out
-- (`api.run_retention_jobs`) and removes disposed files from storage; a `retention.dispose`
-- appointee confirms each batch (`api.decide_disposal_batch`), when every record is checked again.
-- Corrections to people's and organisations' details change the field and keep a correction
-- record beside it; corrections to an evidence file's recorded details are kept beside the file
-- and never applied, because a reviewer relied on them as submitted (8d-6).
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

-- ---------------------------------------------------------------------------
-- The schedule through the venue configuration routes
-- ---------------------------------------------------------------------------
do $m$
declare d text;
begin
  d := pg_get_functiondef('api.create_venue_config_draft(text,uuid,text)'::regprocedure);
  if position($s$not in ('access_purposes', 'outage_procedure', 'chasing')$s$ in d) = 0
     or position($s$when 'chasing' then '{"items": {}}'::jsonb$s$ in d) = 0 then
    raise exception 'api.create_venue_config_draft no longer has the expected structure';
  end if;
  d := replace(d, $s$not in ('access_purposes', 'outage_procedure', 'chasing')$s$, $s$not in ('access_purposes', 'outage_procedure', 'chasing', 'retention')$s$);
  d := replace(d, $s$when 'chasing' then '{"items": {}}'::jsonb$s$, $s$when 'chasing' then '{"items": {}}'::jsonb when 'retention' then '{"rules": {}}'::jsonb$s$);
  execute d;

  d := pg_get_functiondef('api.decide_venue_config(text,uuid,integer,text,text,uuid)'::regprocedure);
  if position($s$v_action := case when p_decision = 'reject'$s$ in d) = 0 then
    raise exception 'api.decide_venue_config no longer has the expected structure';
  end if;
  execute replace(d, $s$v_action := case when p_decision = 'reject'$s$,
                     $s$v_action := case when c.kind = 'retention' then 'retention.approve' when p_decision = 'reject'$s$);
end $m$;

-- ---------------------------------------------------------------------------
-- Who sees the retention and hold screens: the venue's tenant administrators and holders of the
-- retention and hold actions there. Never contractors.
-- ---------------------------------------------------------------------------
create function core.retention_viewer(p_venue_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from core.venue v where v.id = p_venue_id and v.customer_id in (select authz.my_admin_customer_ids()))
      or p_venue_id in (select authz.my_action_venue_ids('retention.approve') union select authz.my_action_venue_ids('retention.dispose')
                        union select authz.my_action_venue_ids('legal_hold.request') union select authz.my_action_venue_ids('legal_hold.approve')) $$;

create function core.venue_date(p_venue_id uuid) returns date
language sql stable security definer set search_path = '' as $$
  select (now() at time zone coalesce((select timezone from core.venue where id = p_venue_id), 'UTC'))::date $$;

create function core.category_name(p_code text) returns text
language sql stable security definer set search_path = '' as $$ select name from core.retention_categories() where code = p_code $$;

-- What a listed record is, in words, for the person reviewing a batch. Null once it is gone.
create function core.retention_label(p_table text, p_id uuid, p_venue_id uuid) returns text
language sql stable security definer set search_path = '' as $$
  select case p_table
    when 'core.entry_eligibility_evaluation' then
      (select 'Gate check at ' || core.venue_time(p_venue_id, e.evaluated_at) || coalesce(', ' || core.person_name(e.person_id), '')
         from core.entry_eligibility_evaluation e where e.id = p_id)
    when 'core.manual_fallback_entry' then
      (select 'Manual fallback entry at ' || core.venue_time(p_venue_id, f.recorded_at) || ', ' || f.name_given from core.manual_fallback_entry f where f.id = p_id)
    when 'core.gate_manifest' then
      (select 'Offline manifest made at ' || core.venue_time(p_venue_id, m.made_at) || ' (' || (select count(*) from core.gate_manifest_entry g where g.manifest_id = m.id) || ' people)'
         from core.gate_manifest m where m.id = p_id)
    when 'core.access_authorisation' then
      (select 'Visit ' || a.reference || ', ' || o.legal_name from core.access_authorisation a join core.organisation o on o.id = a.organisation_id where a.id = p_id)
    when 'core.induction_completion' then
      (select 'Induction completion, ' || core.person_name(c.person_id) || ', ' || ic.title || ', completed ' || to_char(c.completed_at, 'DD/MM/YYYY')
         from core.induction_completion c join core.course_version cv on cv.id = c.course_version_id join core.induction_course ic on ic.id = cv.course_id where c.id = p_id)
    when 'core.induction_attempt' then
      (select 'Unfinished induction attempt, ' || core.person_name(a.person_id) || ', started ' || to_char(a.started_at, 'DD/MM/YYYY')
         from core.induction_attempt a where a.id = p_id)
    when 'core.notification' then
      (select 'Notice to ' || core.person_name(n.recipient_person_id) || ', ' || to_char(n.created_at, 'DD/MM/YYYY') from core.notification n where n.id = p_id)
    when 'core.document_version' then
      (select d.title || ' version ' || dv.version_no || ' (' || coalesce(core.person_name(d.person_id), (select legal_name from core.organisation where id = d.organisation_id), 'unknown owner') || ')'
         from core.document_version dv join core.document d on d.id = dv.document_id where dv.id = p_id)
  end $$;

-- ---------------------------------------------------------------------------
-- Legal holds (§16.4)
-- ---------------------------------------------------------------------------
create function core.hold_target(h core.legal_hold, p_record_id uuid, p_excluded jsonb default '[]') returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('customer_id', h.customer_id, 'venue_id', h.venue_id, 'record_id', p_record_id, 'target_type', 'legal_hold',
                            'excluded_person_ids', p_excluded) $$;

create function api.request_legal_hold(p_idempotency_key text, p_venue_id uuid, p_matter text, p_reason text, p_review_on date,
                                       p_organisation_id uuid default null, p_person_id uuid default null, p_work_package_id uuid default null,
                                       p_visit_id uuid default null, p_from timestamptz default null, p_to timestamptz default null,
                                       p_acting_appointment_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare vn core.venue; h_id uuid := gen_random_uuid(); t jsonb; r jsonb; v jsonb; errs text[] := '{}'; ref text;
begin
  select * into vn from core.venue where id = p_venue_id;
  t := jsonb_build_object('customer_id', vn.customer_id, 'venue_id', vn.id, 'record_id', h_id, 'target_type', 'legal_hold');
  r := jsonb_build_object('venue_id', p_venue_id, 'matter', p_matter, 'reason', p_reason, 'review_on', p_review_on, 'organisation_id', p_organisation_id,
                          'person_id', p_person_id, 'work_package_id', p_work_package_id, 'visit_id', p_visit_id, 'from', p_from, 'to', p_to);
  v := core.authorised_or_refusal('legal_hold.request', t, p_idempotency_key, r, p_acting_appointment_id);
  if v is not null then return v; end if;
  if length(btrim(coalesce(p_matter, ''))) not between 1 and 200 then errs := errs || text 'Give the matter''s reference or name.'; end if;
  if length(btrim(coalesce(p_reason, ''))) not between 1 and 2000 then errs := errs || text 'Give the reason for the hold.'; end if;
  if p_review_on is null or p_review_on <= core.venue_date(vn.id) then errs := errs || text 'Choose a review date after today.'; end if;
  if p_organisation_id is not null and not exists (select 1 from core.organisation where id = p_organisation_id and customer_id = vn.customer_id) then
    errs := errs || text 'The organisation is not one of this customer''s.'; end if;
  if p_person_id is not null and not exists (select 1 from core.person where id = p_person_id and customer_id = vn.customer_id) then
    errs := errs || text 'The person is not one of this customer''s.'; end if;
  if p_work_package_id is not null and not exists (select 1 from core.work_package where id = p_work_package_id and venue_id = vn.id) then
    errs := errs || text 'The job is not at this venue.'; end if;
  if p_visit_id is not null and not exists (select 1 from core.access_authorisation where id = p_visit_id and venue_id = vn.id) then
    errs := errs || text 'The visit is not at this venue.'; end if;
  if p_from is not null and p_to is not null and p_from >= p_to then errs := errs || text 'The period must end after it starts.'; end if;
  if cardinality(errs) > 0 then
    return core.refuse('legal_hold.request', 'invalid_content', 'The hold cannot be requested as given.', array_to_string(errs, ' '), 'You',
                       jsonb_build_object('problems', to_jsonb(errs)));
  end if;
  v := authz.require('legal_hold.request', t, p_idempotency_key, r, p_acting_appointment_id, null);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ref := 'LH-' || upper(left(replace(h_id::text, '-', ''), 8));
  insert into core.legal_hold (id, customer_id, venue_id, reference, matter, reason, scope_organisation_id, scope_person_id, scope_work_package_id,
                               scope_visit_id, scope_from, scope_to, review_on, status, requested_by_person_id)
  values (h_id, vn.customer_id, vn.id, ref, btrim(p_matter), btrim(p_reason), p_organisation_id, p_person_id, p_work_package_id, p_visit_id,
          p_from, p_to, p_review_on, 'requested', (v ->> 'actor_person_id')::uuid);
  perform core.notify(vn.customer_id, vn.id, core.venue_action_appointees(vn.id, 'legal_hold.approve'), 'routine', 'legal_hold_requested',
    'core.legal_hold', h_id, 'hold_requested:' || h_id, format('Legal hold requested: %s', btrim(p_matter)),
    format('%s asked for legal hold %s (%s). It needs a decision by a legal hold approver other than the requester.',
           core.person_name((v ->> 'actor_person_id')::uuid), ref, btrim(p_matter)),
    '/venue/holds', array[(v ->> 'actor_person_id')::uuid]);
  return v || jsonb_build_object('id', h_id, 'reference', ref);
end $$;

create function api.decide_legal_hold(p_idempotency_key text, p_hold_id uuid, p_expected_version integer, p_decision text, p_reason text,
                                      p_acting_appointment_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare h core.legal_hold; t jsonb; r jsonb; v jsonb;
begin
  select * into h from core.legal_hold where id = p_hold_id;
  if h.id is null then
    return core.refuse('legal_hold.approve', 'not_found', 'The record does not exist or you do not have access to it.', 'A legal hold', 'The venue');
  end if;
  t := core.hold_target(h, h.id, jsonb_build_array(h.requested_by_person_id));
  r := jsonb_build_object('hold_id', p_hold_id, 'expected_version', p_expected_version, 'decision', p_decision, 'reason', p_reason);
  v := core.authorised_or_refusal('legal_hold.approve', t, p_idempotency_key, r, p_acting_appointment_id);
  if v is not null then return v; end if;
  if h.status <> 'requested' or coalesce(p_decision, '') not in ('approve', 'refuse') or length(btrim(coalesce(p_reason, ''))) not between 1 and 2000 then
    return core.refuse('legal_hold.approve', 'invalid_content', 'Approve or refuse a requested hold, with a reason.', 'A requested hold and a reason', 'You');
  end if;
  v := authz.require('legal_hold.approve', t, p_idempotency_key, r, p_acting_appointment_id, null);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.legal_hold', h.id, case p_decision when 'approve' then 'active' else 'refused' end, p_expected_version,
    (v ->> 'decision_context_id')::uuid,
    jsonb_build_object('decided_by_person_id', v ->> 'actor_person_id', 'decided_at', clock_timestamp(), 'decision_reason', btrim(p_reason)));
  perform core.notify(h.customer_id, h.venue_id, array[h.requested_by_person_id], 'routine', 'legal_hold_decided', 'core.legal_hold', h.id,
    'hold_decided:' || h.id, format('Legal hold %s: %s', case p_decision when 'approve' then 'in force' else 'refused' end, h.matter),
    format('%s %s legal hold %s (%s). Reason: %s', core.person_name((v ->> 'actor_person_id')::uuid),
           case p_decision when 'approve' then 'approved' else 'refused' end, h.reference, h.matter, btrim(p_reason)),
    '/venue/holds', array[(v ->> 'actor_person_id')::uuid]);
  return v;
end $$;

create function api.renew_legal_hold(p_idempotency_key text, p_hold_id uuid, p_review_on date, p_reason text, p_acting_appointment_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare h core.legal_hold; t jsonb; r jsonb; v jsonb; n_id uuid := gen_random_uuid();
begin
  select * into h from core.legal_hold where id = p_hold_id;
  if h.id is null then
    return core.refuse('legal_hold.approve', 'not_found', 'The record does not exist or you do not have access to it.', 'A legal hold', 'The venue');
  end if;
  t := core.hold_target(h, h.id);
  r := jsonb_build_object('hold_id', p_hold_id, 'review_on', p_review_on, 'reason', p_reason);
  v := core.authorised_or_refusal('legal_hold.approve', t, p_idempotency_key, r, p_acting_appointment_id);
  if v is not null then return v; end if;
  if h.status <> 'active' or p_review_on is null or p_review_on <= core.venue_date(h.venue_id) or length(btrim(coalesce(p_reason, ''))) not between 1 and 2000 then
    return core.refuse('legal_hold.approve', 'invalid_content', 'Renew a hold in force with a review date after today and a reason.',
                       'A hold in force, a later review date and a reason', 'You');
  end if;
  v := authz.require('legal_hold.approve', t, p_idempotency_key, r, p_acting_appointment_id, null);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.legal_hold_renewal (id, customer_id, venue_id, hold_id, review_on, reason, renewed_by_person_id, decision_context_id)
  values (n_id, h.customer_id, h.venue_id, h.id, p_review_on, btrim(p_reason), (v ->> 'actor_person_id')::uuid, (v ->> 'decision_context_id')::uuid);
  return v || jsonb_build_object('review_on', p_review_on);
end $$;

create function api.lift_legal_hold(p_idempotency_key text, p_hold_id uuid, p_expected_version integer, p_reason text, p_acting_appointment_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare h core.legal_hold; t jsonb; r jsonb; v jsonb;
begin
  select * into h from core.legal_hold where id = p_hold_id;
  if h.id is null then
    return core.refuse('legal_hold.approve', 'not_found', 'The record does not exist or you do not have access to it.', 'A legal hold', 'The venue');
  end if;
  t := core.hold_target(h, h.id);
  r := jsonb_build_object('hold_id', p_hold_id, 'expected_version', p_expected_version, 'lift', true, 'reason', p_reason);
  v := core.authorised_or_refusal('legal_hold.approve', t, p_idempotency_key, r, p_acting_appointment_id);
  if v is not null then return v; end if;
  if h.status <> 'active' or length(btrim(coalesce(p_reason, ''))) not between 1 and 2000 then
    return core.refuse('legal_hold.approve', 'invalid_content', 'Lift a hold in force, with a reason.', 'A hold in force and a reason', 'You');
  end if;
  v := authz.require('legal_hold.approve', t, p_idempotency_key, r, p_acting_appointment_id, null);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.legal_hold', h.id, 'lifted', p_expected_version, (v ->> 'decision_context_id')::uuid,
    jsonb_build_object('lifted_by_person_id', v ->> 'actor_person_id', 'lifted_at', clock_timestamp(), 'lift_reason', btrim(p_reason)));
  perform core.notify(h.customer_id, h.venue_id, array[h.requested_by_person_id, h.decided_by_person_id], 'routine', 'legal_hold_lifted',
    'core.legal_hold', h.id, 'hold_lifted:' || h.id, format('Legal hold lifted: %s', h.matter),
    format('%s lifted legal hold %s (%s). Reason: %s. Records it kept are disposed of only when they are next listed and confirmed.',
           core.person_name((v ->> 'actor_person_id')::uuid), h.reference, h.matter, btrim(p_reason)),
    '/venue/holds', array[(v ->> 'actor_person_id')::uuid]);
  return v;
end $$;

create function core.hold_scope_words(h core.legal_hold) returns text
language sql stable security definer set search_path = '' as $$
  select coalesce(nullif(array_to_string(array_remove(array[
      case when h.scope_organisation_id is not null then 'organisation ' || coalesce((select legal_name from core.organisation where id = h.scope_organisation_id), 'no longer recorded') end,
      case when h.scope_person_id is not null then 'person ' || coalesce(core.person_name(h.scope_person_id), 'no longer recorded') end,
      case when h.scope_work_package_id is not null then 'job ' || coalesce((select reference from core.work_package where id = h.scope_work_package_id), 'no longer recorded') end,
      case when h.scope_visit_id is not null then 'visit ' || coalesce((select reference from core.access_authorisation where id = h.scope_visit_id), 'no longer recorded') end,
      case when h.scope_from is not null or h.scope_to is not null then
        'activity ' || coalesce('from ' || core.venue_time(h.venue_id, h.scope_from), '') || coalesce(' until ' || core.venue_time(h.venue_id, h.scope_to), '') end
    ], null), ' and '), ''), 'everything at the venue') $$;

create function api.legal_holds(p_venue_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare vn core.venue; me uuid;
begin
  select * into vn from core.venue where id = p_venue_id;
  if vn.id is null or not core.retention_viewer(vn.id) then
    return jsonb_build_object('ok', false, 'code', 'not_found', 'reason', 'The record does not exist or you do not have access to it.');
  end if;
  me := authz.actor_person(vn.customer_id);
  return jsonb_build_object('ok', true, 'venue', jsonb_build_object('id', vn.id, 'name', vn.name, 'timezone', vn.timezone), 'today', core.venue_date(vn.id),
    'can_request', vn.id in (select authz.my_action_venue_ids('legal_hold.request')),
    'can_decide', vn.id in (select authz.my_action_venue_ids('legal_hold.approve')),
    'holds', coalesce((select jsonb_agg(jsonb_build_object(
        'id', h.id, 'reference', h.reference, 'matter', h.matter, 'reason', h.reason, 'scope', core.hold_scope_words(h),
        'status', h.status, 'review_on', core.hold_review_on(h.id), 'review_due', h.status = 'active' and core.hold_review_on(h.id) <= core.venue_date(vn.id),
        'requested_by', core.person_name(h.requested_by_person_id), 'requested_at', h.created_at, 'mine', h.requested_by_person_id = me,
        'decided_by', core.person_name(h.decided_by_person_id), 'decided_at', h.decided_at, 'decision_reason', h.decision_reason,
        'lifted_by', core.person_name(h.lifted_by_person_id), 'lifted_at', h.lifted_at, 'lift_reason', h.lift_reason, 'row_version', h.row_version,
        'renewals', (select coalesce(jsonb_agg(jsonb_build_object('review_on', n.review_on, 'reason', n.reason, 'by', core.person_name(n.renewed_by_person_id),
                                                                  'at', n.created_at) order by n.created_at), '[]')
                       from core.legal_hold_renewal n where n.hold_id = h.id),
        'kept', (select count(*) from core.disposal_batch b, jsonb_array_elements(b.held_back) hb where b.venue_id = vn.id and hb ->> 'hold_id' = h.id::text))
      order by case h.status when 'requested' then 0 when 'active' then 1 else 2 end, h.created_at desc)
      from core.legal_hold h where h.venue_id = vn.id), '[]'),
    'options', jsonb_build_object(
      'organisations', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'name', o.legal_name) order by o.legal_name), '[]') from core.organisation o
                         where o.id in (select e.organisation_id from core.engagement e where e.venue_id = vn.id)),
      'people', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.given_name || ' ' || p.family_name) order by p.family_name, p.given_name), '[]')
                   from core.person p where p.customer_id = vn.customer_id),
      'jobs', (select coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'name', w.reference) order by w.created_at desc), '[]') from core.work_package w where w.venue_id = vn.id),
      'visits', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', a.reference) order by a.created_at desc), '[]') from core.access_authorisation a where a.venue_id = vn.id)));
end $$;

-- ---------------------------------------------------------------------------
-- The listing job (§16.3): never disposes. One proposed batch per venue and category at a time;
-- records already in a proposed batch, or declined under the same schedule, are not listed again.
-- Also tells requesters and approvers when an active hold reaches its review date.
-- ---------------------------------------------------------------------------
create function api.run_retention_jobs() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v jsonb := authz.evaluate('retention.list', '{}'::jsonb);
  vn core.venue; cfg core.venue_config_version; k text; days integer; cw record;
  c core.retention_candidate; listed core.retention_candidate[]; holds uuid[]; held jsonb; h uuid;
  b_id uuid; n_batches integer := 0; n_listed integer := 0; n_held integer := 0; n_reviews integer := 0; hd core.legal_hold;
begin
  if not (v ->> 'allowed')::boolean then return v; end if;
  for vn in select * from core.venue order by id loop
    cfg := core.venue_config(vn.id, 'retention');
    continue when cfg.id is null;
    for k in select jsonb_object_keys(cfg.content -> 'rules') loop
      continue when exists (select 1 from core.disposal_batch where venue_id = vn.id and category = k and status = 'proposed');
      continue when not exists (select 1 from core.retention_categories() rc where rc.code = k);
      days := (cfg.content #>> array['rules', k, 'days'])::int;
      select * into cw from core.customer_wide_rule(vn.customer_id, k);
      listed := '{}'; held := '{}';
      for c in select x.* from core.retention_candidates(vn.customer_id, k) x
                where (x.venue_id = vn.id or (x.venue_id is null and cw.venue_id = vn.id))
                  and x.trigger_at + make_interval(days => days) <= now()
                  and not exists (select 1 from core.disposal_item i join core.disposal_batch b on b.id = i.batch_id
                                   where i.root_id = x.root_id and i.root_table = x.root_table
                                     and (b.status = 'proposed' or (b.status = 'declined' and b.rule_config_id = cfg.id)))
                order by x.trigger_at, x.root_id loop
        holds := core.covering_holds(vn.customer_id, c);
        if cardinality(holds) > 0 then
          foreach h in array holds loop
            held := jsonb_set(held, array[h::text], to_jsonb(coalesce((held ->> h::text)::int, 0) + 1));
          end loop;
          n_held := n_held + 1;
        elsif cardinality(listed) < 2000 then
          listed := listed || c;
        end if;
      end loop;
      continue when cardinality(listed) = 0;
      b_id := gen_random_uuid();
      v := authz.require('retention.list', jsonb_build_object('customer_id', vn.customer_id, 'venue_id', vn.id, 'record_id', b_id, 'target_type', 'disposal_batch'),
                         'list:' || b_id, jsonb_build_object('venue_id', vn.id, 'category', k, 'rule', cfg.id));
      if not (v ->> 'ok')::boolean then return v; end if;
      insert into core.disposal_batch (id, customer_id, venue_id, reference, category, rule_config_id, period_days, held_back, listed_count, status)
      values (b_id, vn.customer_id, vn.id, 'DB-' || upper(left(replace(b_id::text, '-', ''), 8)), k, cfg.id, days,
              (select coalesce(jsonb_agg(jsonb_build_object('hold_id', lh.id, 'reference', lh.reference, 'matter', lh.matter, 'count', (held ->> lh.id::text)::int)
                                         order by lh.reference), '[]')
                 from core.legal_hold lh where held ? lh.id::text),
              cardinality(listed), 'proposed');
      insert into core.disposal_item (customer_id, batch_id, root_table, root_id, trigger_at)
      select vn.customer_id, b_id, x.root_table, x.root_id, x.trigger_at from unnest(listed) x;
      perform core.notify(vn.customer_id, vn.id, core.venue_action_appointees(vn.id, 'retention.dispose'), 'routine', 'disposal_listed',
        'core.disposal_batch', b_id, 'disposal_listed:' || b_id, format('Records listed for disposal: %s', core.category_name(k)),
        format('%s records of the category "%s" are past the %s days the venue''s retention schedule sets, and no legal hold covers them. Nothing is disposed of until someone confirms the batch.',
               cardinality(listed), core.category_name(k), days),
        '/venue/retention', array[cfg.decided_by_person_id]);
      n_batches := n_batches + 1; n_listed := n_listed + cardinality(listed);
    end loop;
  end loop;

  -- Holds at their review date: tell the requester and the approver; the hold stays in force.
  for hd in select * from core.legal_hold where status = 'active' and core.hold_review_on(id) <= core.venue_date(venue_id) loop
    n_reviews := n_reviews + core.notify(hd.customer_id, hd.venue_id, array[hd.requested_by_person_id, hd.decided_by_person_id], 'routine', 'legal_hold_review',
      'core.legal_hold', hd.id, 'hold_review:' || hd.id || ':' || core.hold_review_on(hd.id),
      format('Legal hold due for review: %s', hd.matter),
      format('Legal hold %s (%s) reached its review date of %s. It stays in force until a legal hold approver renews it with a new review date or lifts it with a reason.',
             hd.reference, hd.matter, to_char(core.hold_review_on(hd.id), 'DD/MM/YYYY')),
      '/venue/holds', '{}');
  end loop;
  return jsonb_build_object('ok', true, 'batches', n_batches, 'listed', n_listed, 'held_back', n_held, 'hold_reviews', n_reviews);
end $$;

-- ---------------------------------------------------------------------------
-- Confirmation (§16.3): every record checked again; then deleted (or its file marked for removal)
-- through core.dispose_rows, the only route past the delete guard.
-- ---------------------------------------------------------------------------
create function core.dispose_root(p_batch_id uuid, c core.retention_candidate) returns void
language plpgsql security definer set search_path = '' as $$
declare ids uuid[]; scans uuid[]; evals uuid[]; att core.induction_completion; dv core.document_version; d core.document;
begin
  if c.root_table = 'core.entry_eligibility_evaluation' then
    perform core.dispose_rows(p_batch_id, 'core.scan_event', array(select id from core.scan_event where evaluation_id = c.root_id));
    perform core.dispose_rows(p_batch_id, 'core.entry_eligibility_evaluation', array[c.root_id]);
  elsif c.root_table = 'core.manual_fallback_entry' then
    perform core.dispose_rows(p_batch_id, 'core.reconciliation_exception', array(select id from core.reconciliation_exception where fallback_entry_id = c.root_id));
    perform core.dispose_rows(p_batch_id, 'core.manual_fallback_entry', array[c.root_id]);
  elsif c.root_table = 'core.gate_manifest' then
    perform core.dispose_rows(p_batch_id, 'core.gate_manifest_entry', array(select id from core.gate_manifest_entry where manifest_id = c.root_id));
    perform core.dispose_rows(p_batch_id, 'core.gate_manifest', array[c.root_id]);
  elsif c.root_table = 'core.access_authorisation' then
    scans := core.clean_ids(array(select arrival_scan_id from core.visit_attendance where authorisation_id = c.root_id)
                            || array(select departure_scan_id from core.visit_attendance where authorisation_id = c.root_id));
    evals := core.clean_ids(array(select evaluation_id from core.scan_event where id = any (scans)));
    perform core.dispose_rows(p_batch_id, 'core.visit_attendance', array(select id from core.visit_attendance where authorisation_id = c.root_id));
    perform core.dispose_rows(p_batch_id, 'core.access_consent', array(select id from core.access_consent where authorisation_id = c.root_id));
    perform core.dispose_rows(p_batch_id, 'core.access_roster_member', array(select id from core.access_roster_member where authorisation_id = c.root_id));
    perform core.dispose_rows(p_batch_id, 'core.access_authorisation', array[c.root_id]);
    perform core.dispose_rows(p_batch_id, 'core.scan_event', scans);
    perform core.dispose_rows(p_batch_id, 'core.entry_eligibility_evaluation',
      array(select e from unnest(evals) e where not exists (select 1 from core.scan_event s where s.evaluation_id = e)));
  elsif c.root_table = 'core.induction_completion' then
    select * into att from core.induction_completion where id = c.root_id;
    perform core.dispose_rows(p_batch_id, 'core.completion_invalidation', array(select id from core.completion_invalidation where completion_id = c.root_id));
    perform core.dispose_rows(p_batch_id, 'core.induction_completion', array[c.root_id]);
    if att.attempt_id is not null and not exists (select 1 from core.induction_completion where attempt_id = att.attempt_id) then
      perform core.dispose_rows(p_batch_id, 'core.module_progress', array(select id from core.module_progress where attempt_id = att.attempt_id));
      perform core.dispose_rows(p_batch_id, 'core.question_response', array(select id from core.question_response where attempt_id = att.attempt_id));
      perform core.dispose_rows(p_batch_id, 'core.induction_attempt', array[att.attempt_id]);
    end if;
  elsif c.root_table = 'core.induction_attempt' then
    perform core.dispose_rows(p_batch_id, 'core.module_progress', array(select id from core.module_progress where attempt_id = c.root_id));
    perform core.dispose_rows(p_batch_id, 'core.question_response', array(select id from core.question_response where attempt_id = c.root_id));
    perform core.dispose_rows(p_batch_id, 'core.induction_attempt', array[c.root_id]);
  elsif c.root_table = 'core.notification' then
    perform core.dispose_rows(p_batch_id, 'core.notification_delivery', array(select id from core.notification_delivery where notification_id = c.root_id));
    perform core.dispose_rows(p_batch_id, 'core.notification', array[c.root_id]);
  elsif c.root_table = 'core.document_version' then
    select * into dv from core.document_version where id = c.root_id;
    select * into d from core.document where id = dv.document_id;
    insert into core.file_disposal (customer_id, venue_id, document_version_id, batch_id, bucket, storage_path)
    values (dv.customer_id, d.venue_id, dv.id, p_batch_id, 'documents', dv.storage_path);
  else
    raise exception 'no disposal route for %', c.root_table;
  end if;
end $$;

create function api.decide_disposal_batch(p_idempotency_key text, p_batch_id uuid, p_expected_version integer, p_decision text, p_reason text,
                                          p_acting_appointment_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  b core.disposal_batch; t jsonb; r jsonb; v jsonb; days integer; cw record; cfg core.venue_config_version;
  rec record; c core.retention_candidate; holds uuid[]; why text;
  outcomes jsonb := '{}'; keep_n integer := 0; go core.retention_candidate[] := '{}';
begin
  select * into b from core.disposal_batch where id = p_batch_id;
  if b.id is null then
    return core.refuse('retention.dispose', 'not_found', 'The record does not exist or you do not have access to it.', 'A disposal batch', 'The venue');
  end if;
  select * into cfg from core.venue_config_version where id = b.rule_config_id;
  t := jsonb_build_object('customer_id', b.customer_id, 'venue_id', b.venue_id, 'record_id', b.id, 'target_type', 'disposal_batch',
                          'excluded_person_ids', jsonb_build_array(cfg.decided_by_person_id));
  r := jsonb_build_object('batch_id', p_batch_id, 'expected_version', p_expected_version, 'decision', p_decision, 'reason', p_reason);
  v := core.authorised_or_refusal('retention.dispose', t, p_idempotency_key, r, p_acting_appointment_id);
  if v is not null then return v; end if;
  if b.status <> 'proposed' or coalesce(p_decision, '') not in ('confirm', 'decline') or length(btrim(coalesce(p_reason, ''))) not between 1 and 2000 then
    return core.refuse('retention.dispose', 'invalid_content', 'Confirm or decline a batch awaiting a decision, with a reason.',
                       'A batch awaiting a decision and a reason', 'You');
  end if;
  v := authz.require('retention.dispose', t, p_idempotency_key, r, p_acting_appointment_id, null);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  if p_decision = 'decline' then
    update core.disposal_item set outcome = 'kept', kept_reason = 'The batch was declined: ' || btrim(p_reason) where batch_id = b.id;
    perform core.transition('core.disposal_batch', b.id, 'declined', p_expected_version, (v ->> 'decision_context_id')::uuid,
      jsonb_build_object('decided_by_person_id', v ->> 'actor_person_id', 'decided_at', clock_timestamp(), 'decision_reason', btrim(p_reason),
                         'disposed_count', 0, 'kept_count', b.listed_count));
    return v || jsonb_build_object('disposed', 0, 'kept', b.listed_count);
  end if;

  -- Check every record again, under the schedule in force now and the holds active now.
  select r2.days into days from core.retention_rule(b.venue_id, b.category) r2;
  select * into cw from core.customer_wide_rule(b.customer_id, b.category);
  for rec in select i.id as item_id, x as cand
               from core.disposal_item i
               left join core.retention_candidates(b.customer_id, b.category) x on x.root_table = i.root_table and x.root_id = i.root_id
              where i.batch_id = b.id order by i.trigger_at, i.root_id loop
    c := rec.cand;
    holds := case when c.root_id is null then '{}' else core.covering_holds(b.customer_id, c) end;
    why := case
      when c.root_id is null then 'It can no longer be disposed of: its state changed after it was listed.'
      when c.venue_id is null and cw.venue_id is distinct from b.venue_id then 'The schedules of the customer''s venues no longer allow it to be disposed of from here.'
      when days is null then 'The venue''s schedule no longer has a rule for this category.'
      when c.trigger_at + make_interval(days => coalesce(case when c.venue_id is null then cw.days end, days)) > now()
        then 'Under the schedule in force now it is not yet past its period.'
      when cardinality(holds) > 0 then 'A legal hold now covers it: ' || (select string_agg(reference, ', ' order by reference) from core.legal_hold where id = any (holds)) || '.'
    end;
    if why is null then go := go || c; else outcomes := outcomes || jsonb_build_object(rec.item_id::text, why); keep_n := keep_n + 1; end if;
  end loop;

  perform core.transition('core.disposal_batch', b.id, 'confirmed', p_expected_version, (v ->> 'decision_context_id')::uuid,
    jsonb_build_object('decided_by_person_id', v ->> 'actor_person_id', 'decided_at', clock_timestamp(), 'decision_reason', btrim(p_reason),
                       'disposed_count', cardinality(go), 'kept_count', keep_n));
  foreach c in array go loop
    perform core.dispose_root(b.id, c);
  end loop;
  update core.disposal_item i set outcome = case when outcomes ? i.id::text then 'kept' else 'disposed' end, kept_reason = outcomes ->> i.id::text
   where i.batch_id = b.id;
  return v || jsonb_build_object('disposed', cardinality(go), 'kept', keep_n);
end $$;

create function api.retention_overview(p_venue_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare vn core.venue; cfg core.venue_config_version; draft core.venue_config_version;
begin
  select * into vn from core.venue where id = p_venue_id;
  if vn.id is null or not core.retention_viewer(vn.id) then
    return jsonb_build_object('ok', false, 'code', 'not_found', 'reason', 'The record does not exist or you do not have access to it.');
  end if;
  cfg := core.venue_config(vn.id, 'retention');
  select * into draft from core.venue_config_version where venue_id = vn.id and kind = 'retention' and status in ('draft', 'proposed');
  return jsonb_build_object('ok', true, 'venue', jsonb_build_object('id', vn.id, 'name', vn.name, 'timezone', vn.timezone),
    'is_admin', vn.customer_id in (select authz.my_admin_customer_ids()),
    'can_approve', vn.id in (select authz.my_action_venue_ids('retention.approve')),
    'can_dispose', vn.id in (select authz.my_action_venue_ids('retention.dispose')),
    'me', authz.actor_person(vn.customer_id),
    'categories', (select jsonb_agg(jsonb_build_object('code', rc.code, 'name', rc.name, 'trigger', rc.trigger_words, 'method', rc.method,
                                                       'never_while', rc.never_while, 'rule', cfg.content #> array['rules', rc.code]) order by rc.ord)
                     from core.retention_categories() rc),
    'schedule', case when cfg.id is null then null else jsonb_build_object('id', cfg.id, 'version_no', cfg.version_no, 'decided_by', core.person_name(cfg.decided_by_person_id),
                                                                         'decided_at', cfg.decided_at, 'decision_reason', cfg.decision_reason, 'source_ref', cfg.source_ref) end,
    'draft', case when draft.id is null then null else jsonb_build_object('id', draft.id, 'status', draft.status, 'version_no', draft.version_no, 'content', draft.content,
                                                                        'row_version', draft.row_version, 'authored_by', core.person_name(draft.authored_by_person_id),
                                                                        'authored_by_person_id', draft.authored_by_person_id,
                                                                        'proposed_by_person_id', draft.proposed_by_person_id) end,
    'batches', coalesce((select jsonb_agg(jsonb_build_object(
        'id', b.id, 'reference', b.reference, 'category', core.category_name(b.category), 'status', b.status, 'listed_count', b.listed_count,
        'period_days', b.period_days, 'listed_at', b.created_at, 'held_back', b.held_back, 'row_version', b.row_version,
        'rule_version', (select version_no from core.venue_config_version where id = b.rule_config_id),
        'rule_approver_person_id', (select decided_by_person_id from core.venue_config_version where id = b.rule_config_id),
        'decided_by', core.person_name(b.decided_by_person_id), 'decided_at', b.decided_at, 'decision_reason', b.decision_reason,
        'disposed_count', b.disposed_count, 'kept_count', b.kept_count,
        'items', case when b.status = 'proposed' then (select coalesce(jsonb_agg(jsonb_build_object('label', core.retention_label(i.root_table, i.root_id, b.venue_id),
                                                                                                   'trigger_at', i.trigger_at) order by i.trigger_at), '[]')
                                                         from (select * from core.disposal_item where batch_id = b.id order by trigger_at limit 200) i)
                      else (select coalesce(jsonb_agg(jsonb_build_object('kept_reason', i.kept_reason, 'label', core.retention_label(i.root_table, i.root_id, b.venue_id),
                                                                          'trigger_at', i.trigger_at) order by i.trigger_at), '[]')
                              from core.disposal_item i where i.batch_id = b.id and i.outcome = 'kept') end)
      order by case b.status when 'proposed' then 0 else 1 end, b.created_at desc)
      from (select * from core.disposal_batch where venue_id = vn.id order by created_at desc limit 50) b), '[]'),
    'files_waiting', (select count(*) from core.file_disposal where venue_id = vn.id and removed_at is null));
end $$;

-- ---------------------------------------------------------------------------
-- Removing disposed files from storage (job runner): claimed with a lease, recorded when done.
-- ---------------------------------------------------------------------------
create function api.claim_file_removals(p_limit integer default 20, p_lease_seconds integer default 120) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v jsonb := authz.evaluate('retention.remove_files', '{}'::jsonb); ids uuid[];
begin
  if not (v ->> 'allowed')::boolean then return v; end if;
  if p_limit not between 1 and 100 or p_lease_seconds not between 30 and 1800 then
    raise exception 'limit 1-100, lease 30-1800 seconds' using errcode = '22023';
  end if;
  select array_agg(id) into ids from (
    select f.id from core.file_disposal f where f.removed_at is null and (f.leased_until is null or f.leased_until < clock_timestamp())
     order by f.created_at limit p_limit for update skip locked) z;
  update core.file_disposal set leased_until = clock_timestamp() + make_interval(secs => p_lease_seconds), attempts = attempts + 1
   where id = any (coalesce(ids, '{}'));
  return jsonb_build_object('ok', true, 'files', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'bucket', f.bucket, 'storage_path', f.storage_path))
                                                             from core.file_disposal f where f.id = any (coalesce(ids, '{}'))), '[]'));
end $$;

create function api.record_file_removal(p_id uuid, p_ok boolean, p_error text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v jsonb := authz.evaluate('retention.remove_files', '{}'::jsonb);
begin
  if not (v ->> 'allowed')::boolean then return v; end if;
  update core.file_disposal set removed_at = case when p_ok then clock_timestamp() end, leased_until = null,
                                last_error = case when p_ok then null else left(coalesce(p_error, 'unknown error'), 500) end
   where id = p_id and removed_at is null;
  return jsonb_build_object('ok', true);
end $$;

-- Platform operations: disposed files still waiting to be removed from storage, without paths or content.
create function api.file_removal_status() returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when not authz.is_platform_admin() then jsonb_build_object('ok', false, 'code', 'not_found')
    else jsonb_build_object('ok', true,
      'waiting', (select count(*) from core.file_disposal where removed_at is null),
      'failing', (select coalesce(jsonb_agg(jsonb_build_object('since', f.created_at, 'attempts', f.attempts, 'last_error', f.last_error) order by f.created_at), '[]')
                    from (select * from core.file_disposal where removed_at is null and last_error is not null order by created_at limit 50) f)) end $$;

-- A disposed file is never released again; its record says so.
do $m$
declare d text; anchor text := $s$  select * into d from core.document where id = dv.document_id;$s$;
begin
  d := pg_get_functiondef('api.document_access(uuid)'::regprocedure);
  if position(anchor in d) = 0 then raise exception 'api.document_access no longer has the expected structure'; end if;
  execute replace(d, anchor, $s$  if exists (select 1 from core.file_disposal fd where fd.document_version_id = dv.id) then
    return authz.deny('document.access', 'disposed',
      'This file was removed under the venue''s retention schedule on ' || (select to_char(created_at, 'DD/MM/YYYY') from core.file_disposal where document_version_id = dv.id) || '.',
      'A file that is still kept', 'Nobody: it no longer exists');
  end if;
$s$ || anchor);
end $m$;

-- ---------------------------------------------------------------------------
-- Corrections to live records (8c-5, §16.5)
-- ---------------------------------------------------------------------------
alter table core.correction alter column work_package_id drop not null, alter column permit_id drop not null;
alter table core.correction drop constraint correction_target_type_check;
alter table core.correction add column field text;
alter table core.correction add constraint correction_target_type_check
  check (target_type in ('issue_snapshot', 'close_out_snapshot', 'step_decision', 'hand_back_decision', 'person', 'organisation', 'document_version'));
alter table core.correction add constraint correction_live_or_frozen
  check (case when target_type in ('person', 'organisation', 'document_version')
              then field is not null and permit_id is null and work_package_id is null
              else field is null and permit_id is not null and work_package_id is not null end);
create index correction_target_idx on core.correction (target_id);

-- The company number becomes correctable (only through api.correct_record).
drop trigger b_guard_update on core.organisation;
create trigger b_guard_update before update on core.organisation for each row
  execute function core.guard_update('legal_name,trading_name,company_number,deactivated_at');

create function core.correctable_fields(p_target_type text) returns table (field text, label text, applied boolean)
language sql immutable set search_path = '' as $$
  select f.field, f.label, f.applied from (values
    ('person', 'given_name', 'Given name', true), ('person', 'family_name', 'Family name', true), ('person', 'preferred_name', 'Preferred name', true),
    ('organisation', 'legal_name', 'Legal name', true), ('organisation', 'trading_name', 'Trading name', true), ('organisation', 'company_number', 'Company number', true),
    ('document_version', 'issuer', 'Issuer', false), ('document_version', 'reference', 'Reference', false),
    ('document_version', 'valid_from', 'Valid from', false), ('document_version', 'expires_on', 'Expiry date', false)) f(t, field, label, applied)
  where f.t = p_target_type $$;

create function core.creator_person(p_customer_id uuid, p_user_id uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select person_id from core.user_account where auth_user_id = p_user_id and customer_id = p_customer_id limit 1 $$;

create function api.correct_record(p_idempotency_key text, p_venue_id uuid, p_target_type text, p_target_id uuid, p_field text, p_corrected text,
                                   p_reason text, p_evidence text, p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  vn core.venue; pe core.person; o core.organisation; dv core.document_version; d core.document; f record;
  cust uuid; was text; excluded jsonb := '[]'; t jsonb; r jsonb; v jsonb; c_id uuid := gen_random_uuid(); errs text[] := '{}';
begin
  select * into vn from core.venue where id = p_venue_id;
  if p_target_type = 'person' then
    select * into pe from core.person where id = p_target_id; cust := pe.customer_id;
    was := to_jsonb(pe) ->> p_field;
    excluded := jsonb_build_array(pe.id, core.creator_person(pe.customer_id, pe.created_by_user_id));
  elsif p_target_type = 'organisation' then
    select * into o from core.organisation where id = p_target_id; cust := o.customer_id;
    was := to_jsonb(o) ->> p_field;
    excluded := core.organisation_people(o.id) || jsonb_build_array(core.creator_person(o.customer_id, o.created_by_user_id));
  elsif p_target_type = 'document_version' then
    select * into dv from core.document_version where id = p_target_id;
    select * into d from core.document where id = dv.document_id; cust := dv.customer_id;
    was := to_jsonb(dv) ->> p_field;
    excluded := jsonb_build_array(dv.uploaded_by_person_id, d.person_id, core.creator_person(dv.customer_id, dv.created_by_user_id));
  end if;
  if vn.id is null or cust is null or cust <> vn.customer_id or (p_target_type = 'document_version' and d.venue_id <> vn.id) then
    return core.refuse('record.correct', 'not_found', 'The record does not exist or you do not have access to it.', 'A person, organisation or evidence file', 'The venue');
  end if;
  t := jsonb_build_object('customer_id', vn.customer_id, 'venue_id', vn.id, 'record_id', c_id, 'target_type', 'correction',
                          'excluded_person_ids', excluded);
  r := jsonb_build_object('target_type', p_target_type, 'target_id', p_target_id, 'field', p_field, 'corrected', p_corrected,
                          'reason', p_reason, 'evidence', p_evidence);
  v := core.authorised_or_refusal('record.correct', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  select * into f from core.correctable_fields(p_target_type) cf where cf.field = p_field;
  if f.field is null then errs := errs || text 'That detail cannot be corrected here.'; end if;
  if length(btrim(coalesce(p_corrected, ''))) not between 1 and 300 then errs := errs || text 'Give the correct value.'; end if;
  if btrim(coalesce(p_corrected, '')) = coalesce(was, '') then errs := errs || text 'The correct value is the same as what the record says.'; end if;
  if p_field in ('valid_from', 'expires_on') and coalesce(p_corrected, '') !~ '^\d{4}-\d{2}-\d{2}$' then errs := errs || text 'Give the date as YYYY-MM-DD.'; end if;
  if length(btrim(coalesce(p_reason, ''))) not between 1 and 2000 then errs := errs || text 'Give the reason for the correction.'; end if;
  if length(btrim(coalesce(p_evidence, ''))) not between 1 and 2000 then errs := errs || text 'Say what shows the correct value.'; end if;
  if cardinality(errs) > 0 then
    return core.refuse('record.correct', 'invalid_content', 'The correction cannot be recorded as given.', array_to_string(errs, ' '), 'You',
                       jsonb_build_object('problems', to_jsonb(errs)));
  end if;
  v := authz.require('record.correct', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.correction (id, customer_id, venue_id, target_type, target_id, field, about, was, corrected, reason, evidence,
                               recorded_by_person_id, decision_context_id)
  values (c_id, vn.customer_id, vn.id, p_target_type, p_target_id, p_field, f.label, coalesce(was, '(blank)'), btrim(p_corrected),
          btrim(p_reason), btrim(p_evidence), (v ->> 'actor_person_id')::uuid, (v ->> 'decision_context_id')::uuid);
  if f.applied then
    execute format('update core.%I set %I = $1 where id = $2', p_target_type, p_field) using btrim(p_corrected), p_target_id;
  end if;
  return v || jsonb_build_object('id', c_id, 'applied', f.applied);
end $$;

-- Corrections to a person, organisation or evidence file, for anyone who can see it; and what the
-- caller may correct, if they hold `record.correct` at the given venue.
create function api.record_corrections(p_kind text, p_id uuid, p_venue_id uuid default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare visible boolean; cust uuid;
begin
  visible := case p_kind
    when 'person' then p_id in (select authz.visible_person_ids())
    when 'organisation' then p_id in (select authz.visible_organisation_ids())
    when 'document_version' then (select document_id from core.document_version where id = p_id) in (select authz.visible_document_ids())
    else false end;
  if not coalesce(visible, false) then
    return jsonb_build_object('ok', false, 'code', 'not_found', 'reason', 'The record does not exist or you do not have access to it.');
  end if;
  cust := case p_kind when 'person' then (select customer_id from core.person where id = p_id)
                      when 'organisation' then (select customer_id from core.organisation where id = p_id)
                      else (select customer_id from core.document_version where id = p_id) end;
  return jsonb_build_object('ok', true,
    'can_correct', p_venue_id is not null and p_venue_id in (select authz.my_action_venue_ids('record.correct'))
                   and exists (select 1 from core.venue where id = p_venue_id and customer_id = cust),
    'fields', (select coalesce(jsonb_agg(jsonb_build_object('field', cf.field, 'label', cf.label, 'applied', cf.applied)), '[]') from core.correctable_fields(p_kind) cf),
    'corrections', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'label', c.about, 'was', c.was, 'corrected', c.corrected, 'reason', c.reason,
                                                                  'evidence', c.evidence, 'by', core.person_name(c.recorded_by_person_id), 'at', c.created_at,
                                                                  'applied', (select cf.applied from core.correctable_fields(p_kind) cf where cf.field = c.field))
                                              order by c.created_at desc), '[]')
                      from core.correction c where c.target_type = p_kind and c.target_id = p_id));
end $$;

grant execute on function
  api.request_legal_hold(text, uuid, text, text, date, uuid, uuid, uuid, uuid, timestamptz, timestamptz, uuid),
  api.decide_legal_hold(text, uuid, integer, text, text, uuid), api.renew_legal_hold(text, uuid, date, text, uuid),
  api.lift_legal_hold(text, uuid, integer, text, uuid), api.legal_holds(uuid), api.run_retention_jobs(),
  api.decide_disposal_batch(text, uuid, integer, text, text, uuid), api.retention_overview(uuid),
  api.claim_file_removals(integer, integer), api.record_file_removal(uuid, boolean, text), api.file_removal_status(),
  api.correct_record(text, uuid, text, uuid, text, text, text, text, uuid, uuid), api.record_corrections(text, uuid, uuid)
to authenticated;
revoke execute on function
  api.request_legal_hold(text, uuid, text, text, date, uuid, uuid, uuid, uuid, timestamptz, timestamptz, uuid),
  api.decide_legal_hold(text, uuid, integer, text, text, uuid), api.renew_legal_hold(text, uuid, date, text, uuid),
  api.lift_legal_hold(text, uuid, integer, text, uuid), api.legal_holds(uuid), api.run_retention_jobs(),
  api.decide_disposal_batch(text, uuid, integer, text, text, uuid), api.retention_overview(uuid),
  api.claim_file_removals(integer, integer), api.record_file_removal(uuid, boolean, text), api.file_removal_status(),
  api.correct_record(text, uuid, text, uuid, text, text, text, text, uuid, uuid), api.record_corrections(text, uuid, uuid)
from anon, public;
revoke execute on function core.retention_viewer(uuid), core.venue_date(uuid), core.category_name(text), core.retention_label(text, uuid, uuid),
  core.hold_target(core.legal_hold, uuid, jsonb), core.hold_scope_words(core.legal_hold), core.dispose_root(uuid, core.retention_candidate),
  core.correctable_fields(text), core.creator_person(uuid, uuid) from public;
