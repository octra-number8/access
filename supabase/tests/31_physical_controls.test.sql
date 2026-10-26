-- Physical controls 6b (Q118, Q127-Q148, Q160, P6-8, P6-9, invariants 3, 7, 9, 10, 11):
-- configuration with no default, isolations with their rules and personal locks,
-- impairments with measures, notifications and an approved maximum, fire watch, exclusion
-- zones, custody, the controls a class needs at issue, acceptance and re-acceptance, and
-- control failure.
begin;
\ir _helpers.psql
\ir _phase4.psql
select tests.approve_screening();
\ir _phase5.psql
\ir _phase6.psql
select no_plan();

create temp table t_r (name text primary key, v jsonb);
grant all on t_r to authenticated;

-- ---- Authorities scoped to systems (P6-9) ---------------------------------------------------------
-- A person with a root appointment of the given type over the given systems.
create function tests.root_sys(p_email text, p_given text, p_type_version uuid, p_systems uuid[]) returns uuid[]
language plpgsql as $$
declare u uuid := tests.new_user(p_email); p uuid; ap uuid;
begin
  perform tests.login(tests.w('u_a1'));
  p := tests.must(api.create_person(tests.key(), tests.w('cust_a'), p_given, 'Engineer', p_email => p_email));
  perform tests.must(api.link_user_account(tests.key(), p, u));
  ap := tests.must(api.record_root_appointment(tests.key(), tests.w('v1'), p, tests.w('p_d'), p_type_version, '{}',
    (select jsonb_agg(jsonb_build_object('system_id', s)) from unnest(p_systems) s), now() - interval '1 minute', null, null, null,
    'Letter of appointment ' || p_given));
  perform tests.login(tests.w('u_a2'));
  perform tests.must(api.confirm_root_appointment(tests.key(), ap, tests.version('core.appointment', ap)));
  perform tests.login(u);
  perform tests.must(api.acknowledge_appointment(tests.key(), ap, tests.version('core.appointment', ap)));
  perform tests.logout();
  return array[u, p];
end $$;
create function tests.new_type(p_code text, p_name text, p_actions text[], p_system_types uuid[]) returns uuid language plpgsql as $$
declare t uuid; tv uuid;
begin
  perform tests.login(tests.w('u_a1'));
  t := tests.must(api.create_appointment_type(tests.key(), tests.w('v1'), p_code, p_name));
  tv := tests.must(api.propose_appointment_type_version(tests.key(), t, p_actions, array[tests.w('pc_wa'), tests.w('pc_wah'), tests.w('pc_hw')],
    p_system_types, '{}', true, false, tests.w('p_a1'), now() - interval '1 minute', p_name));
  perform tests.login(tests.w('u_r'));
  perform tests.must(api.decide_appointment_type_version(tests.key(), tv, tests.version('core.appointment_type_version', tv), 'approve', 'Agreed'));
  perform tests.logout();
  return tv;
end $$;
grant execute on all functions in schema tests to authenticated;

select tests.set_w('tv_ia', tests.new_type('IA', 'Isolation Authority',
  array['isolation.authorise', 'isolation.withdraw', 'isolation.remove', 'isolation.return', 'isolation.lock_off_on_behalf',
        'impairment.authorise', 'impairment.reauthorise', 'impairment.withdraw', 'control.lift_failure', 'control.report_failure_as_authority'],
  array[tests.w('st_hv'), tests.w('st_fa')]));
select tests.set_w('tv_ap', tests.new_type('AP', 'Authorised Person',
  array['isolation.apply', 'isolation.prove', 'impairment.impair', 'impairment.test', 'impairment.restore'], array[tests.w('st_hv'), tests.w('st_fa')]));
select tests.set_w('tv_tr', tests.new_type('TR', 'Technical Rules', array['control_rule.publish', 'custody.issue', 'custody.return'], '{}'));
select tests.set_w('u_ada', (tests.root_sys('ada@a.test', 'Ada', tests.w('tv_ia'), array[tests.w('hv1'), tests.w('fa1')]))[1]);
select tests.set_w('u_abe', (tests.root_sys('abe@a.test', 'Abe', tests.w('tv_ia'), array[tests.w('fa1')]))[1]);
select tests.set_w('u_al', (tests.root_sys('al@a.test', 'Al', tests.w('tv_ap'), array[tests.w('hv1'), tests.w('fa1')]))[1]);
select tests.set_w('x_bo', (tests.root_sys('bo@a.test', 'Bo', tests.w('tv_ap'), array[tests.w('hv1'), tests.w('fa1')]))[2]);
select tests.set_w('u_bo', (select ua.auth_user_id from core.user_account ua where ua.person_id = tests.w('x_bo')));
select tests.set_w('u_tom', (tests.root_ta('tom@a.test', 'Tom', tests.w('tv_tr'), array[tests.w('pc_wa')], tests.w('site')))[1]);
-- OP, the contractor's supervisor, is also appointed as an isolation authority for HV1.
select tests.login(tests.w('u_a1'));
select tests.set_w('ap_op_ia', tests.must(api.record_root_appointment(tests.key(), tests.w('v1'), tests.w('p_op'), tests.w('p_d'), tests.w('tv_ia'), '{}',
  jsonb_build_array(jsonb_build_object('system_id', tests.w('hv1'))), now() - interval '1 minute', null, null, null, 'Letter of appointment OP-IA')));
select tests.login(tests.w('u_a2'));
select tests.must(api.confirm_root_appointment(tests.key(), tests.w('ap_op_ia'), tests.version('core.appointment', tests.w('ap_op_ia'))));
select tests.login(tests.w('u_op'));
select tests.must(api.acknowledge_appointment(tests.key(), tests.w('ap_op_ia'), tests.version('core.appointment', tests.w('ap_op_ia'))));
select tests.logout();

-- ---- Configuration has no default (P6-8) ------------------------------------------------------------
select ok(array_to_string(core.validate_class_config(tests.w('v1'), tests.class_config('[{"key": "r", "name": "R", "kind": "review", "group": 1}]')
  || '{"physical_controls": [{"kind": "scaffold"}]}', true), ' ') like '%Physical controls are a list of%', 'only the known control kinds');
select ok(array_to_string(core.validate_class_config(tests.w('v1'), tests.class_config('[{"key": "r", "name": "R", "kind": "review", "group": 1}]')
  || '{"physical_controls": [{"kind": "isolation"}, {"kind": "isolation"}]}', true), ' ') like '%each once%', 'each once');
select ok(array_to_string(core.validate_class_config(tests.w('v1'), tests.class_config('[{"key": "r", "name": "R", "kind": "review", "group": 1}]')
  || '{"physical_controls": [{"kind": "fire_watch", "during_work": true}]}', true), ' ') like '%Physical controls are a list of%',
  'a fire watch must state its minutes after the work: there is no default');
select ok(array_to_string(core.validate_class_config(tests.w('v1'), tests.class_config('[{"key": "r", "name": "R", "kind": "review", "group": 1}]')
  || '{"requires_physical_controls": true}', true), ' ') like '%replaced by the list%', 'the old yes/no choice is not accepted');

select tests.set_w('cv_wah_b', tests.configure_class(tests.w('pc_wah'), tests.class_config(
  '[{"key": "rams", "name": "RAMS review", "kind": "review", "group": 1}]',
  '[{"key": "access", "text": "How will people reach the work?", "type": "choose_one",
     "options": [{"key": "mewp", "text": "MEWP"}, {"key": "scaffold", "text": "Scaffold"}]}]')
  || '{"physical_controls": [{"kind": "isolation"}, {"kind": "impairment"}, {"kind": "exclusion_zone"}]}'));
select tests.set_w('cv_hw_b', tests.configure_class(tests.w('pc_hw'), tests.class_config(
  '[{"key": "hw-review", "name": "Hot works review", "kind": "review", "group": 1}]')
  || '{"physical_controls": [{"kind": "fire_watch", "during_work": true, "post_work_minutes": 60}]}'));

-- A job for today needing work at height and hot works, approved but not issued.
select tests.set_w('wp', tests.today_job('Rewire high-level lamps', array[tests.w('pc_wah'), tests.w('pc_hw')]));
select tests.set_w('wa', tests.permit_of(tests.w('wp'), tests.w('pc_wa')));
select tests.set_w('wah', tests.permit_of(tests.w('wp'), tests.w('pc_wah')));
select tests.set_w('hw', tests.permit_of(tests.w('wp'), tests.w('pc_hw')));
select tests.approve_permit(tests.w('wa'), '{}');
select tests.approve_permit(tests.w('wah'), '{"access": ["mewp"]}');
select tests.approve_permit(tests.w('hw'), '{}');
select tests.login(tests.w('u_ivy'));
select tests.must(api.issue_permit(tests.key(), tests.w('wa'), tests.version('core.permit', tests.w('wa'))));
insert into t_r select 'b0', api.issue_blockers(tests.w('wah'));
select ok((select v::text from t_r where name = 'b0') like '%needs an isolation, and none is linked%'
      and (select v::text from t_r where name = 'b0') like '%needs an impairment, and none is linked%'
      and (select v::text from t_r where name = 'b0') like '%needs an exclusion zone%',
  'an approved permit is not issued until the controls its class needs are in place (P6-8)');
select is(api.issue_permit(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah'))) ->> 'code', 'not_ready', 'so issue is refused');

-- ---- Isolation rules (P6-9) -----------------------------------------------------------------------------
select tests.login(tests.w('u_a1'));
select is(api.publish_control_rule(tests.key(), tests.w('st_hv'), 'isolation', '{"prove_by": "different_person", "return_witness": "required"}',
  now() - interval '1 minute', 'Electrical safety rules rev. 4') ->> 'code', 'no_covering_appointment',
  'a tenant administrator cannot set isolation rules (invariant 9)');
select tests.login(tests.w('u_tom'));
select is(api.publish_control_rule(tests.key(), tests.w('st_hv'), 'isolation', '{"prove_by": "whoever"}', now(), 'Rules') ->> 'code', 'invalid_content',
  'isolation rules have no default: who proves and whether return is witnessed must be chosen');

-- ---- Isolation (Q142-Q148) ------------------------------------------------------------------------------
select tests.login(tests.w('u_nia'));
select is(api.request_isolation(tests.key(), array[tests.w('wah')], tests.w('hv1'), 'HV1 feeder 3', 'Lamp circuits', now(), now() + interval '1 day') ->> 'ok',
  'false', 'someone who is neither the supervisor nor an administrator of the organisation cannot ask for an isolation');
select tests.login(tests.w('u_op'));
insert into t_r select 'iso', api.request_isolation(tests.key(), array[tests.w('wah')], tests.w('hv1'), 'HV1 feeder 3 at panel B', 'Lamp circuits in Hall 1',
  now() - interval '1 hour', now() + interval '1 day');
select is((select v ->> 'ok' from t_r where name = 'iso'), 'true', 'the supervisor asks for an isolation of HV1');
select tests.set_w('iso', (select (v ->> 'isolation_id')::uuid from t_r where name = 'iso'));
select is((select action_code from core.decision_context where id = (select v ->> 'decision_context_id' from t_r where name = 'iso')::uuid),
  'isolation.request_as_supervisor', 'as the permit''s supervisor');
select tests.login(tests.w('u_ada'));
select is(api.authorise_isolation(tests.key(), tests.w('iso'), tests.version('core.isolation', tests.w('iso')), 'authorise', 'Boundary at panel B') ->> 'code',
  'not_configured', 'nothing is authorised for a system type with no published rules');
select tests.login(tests.w('u_tom'));
select is(api.publish_control_rule(tests.key(), tests.w('st_hv'), 'isolation', '{"prove_by": "different_person", "return_witness": "required"}',
  now() - interval '1 minute', 'Electrical safety rules rev. 4 (test values)') ->> 'ok', 'true', 'the technical authority publishes the rules for HV');
select tests.login(tests.w('u_op'));
select is(api.authorise_isolation(tests.key(), tests.w('iso'), tests.version('core.isolation', tests.w('iso')), 'authorise', 'Fine') ->> 'code',
  'separation_of_duties', 'whoever asked cannot authorise it, even holding the appointment (invariant 3)');
select tests.login(tests.w('u_platform'));
select is(api.authorise_isolation(tests.key(), tests.w('iso'), tests.version('core.isolation', tests.w('iso')), 'authorise', 'Fine') ->> 'ok', 'false',
  'nor a platform administrator (invariant 9)');
select tests.login(tests.w('u_abe'));
select is(api.authorise_isolation(tests.key(), tests.w('iso'), tests.version('core.isolation', tests.w('iso')), 'authorise', 'Fine') ->> 'code',
  'no_covering_appointment', 'nor an isolation authority for a different system');
select tests.login(tests.w('u_ada'));
select throws_ok($$ select api.authorise_isolation(tests.key(), tests.w('iso'), tests.version('core.isolation', tests.w('iso')) - 1, 'authorise', 'Fine') $$,
  'PT409', null, 'a decision on an out-of-date version fails');
select is(api.authorise_isolation(tests.key(), tests.w('iso'), tests.version('core.isolation', tests.w('iso')), 'authorise',
  'Boundary at panel B, feeder 3 breaker and downstream isolator') ->> 'ok', 'true', 'the isolation authority for HV1 authorises the boundary');
select is((select rule_version_id from core.isolation where id = tests.w('iso')) is not null, true, 'under the rules in force, recorded');
select is(api.apply_isolation(tests.key(), tests.w('iso'), tests.version('core.isolation', tests.w('iso')), 'IC-104', array['L-17'], null) ->> 'code',
  'no_covering_appointment', 'authorising is not applying: the authority has no apply appointment');
select tests.login(tests.w('u_al'));
select is(api.apply_isolation(tests.key(), tests.w('iso'), tests.version('core.isolation', tests.w('iso')), ' ', '{}', null) ->> 'code', 'invalid_content',
  'applying records the certificate and the locks (Q144)');
insert into t_r select 'apply_k', jsonb_build_object('k', tests.key(), 'ver', tests.version('core.isolation', tests.w('iso')));
insert into t_r select 'apply', api.apply_isolation((select v ->> 'k' from t_r where name = 'apply_k'), tests.w('iso'), (select (v ->> 'ver')::int from t_r where name = 'apply_k'),
  'IC-104', array['L-17', 'L-18'], 'LB-2');
select is((select v ->> 'ok' from t_r where name = 'apply'), 'true', 'an authorised person applies it');
select is(api.apply_isolation((select v ->> 'k' from t_r where name = 'apply_k'), tests.w('iso'), (select (v ->> 'ver')::int from t_r where name = 'apply_k'), 'IC-104', array['L-17', 'L-18'], 'LB-2') ->> 'replayed', 'true',
  'repeating the request replays it (idempotency)');
select ok(api.issue_blockers(tests.w('wah'))::text like '%The isolation of HV ring is applied, not proved.%', 'an isolation applied but not proved does not count');
select is(api.prove_isolation(tests.key(), tests.w('iso'), tests.version('core.isolation', tests.w('iso')), 'MFT-22', 'Prove-test-prove', true) ->> 'code',
  'separation_of_duties', 'the rules say a different person proves it');
select tests.login(tests.w('u_bo'));
select is(api.prove_isolation(tests.key(), tests.w('iso'), tests.version('core.isolation', tests.w('iso')), 'MFT-22', 'Prove-test-prove', false) ->> 'code',
  'not_confirmed', 'a test that does not confirm dead does not prove it');
select is(api.prove_isolation(tests.key(), tests.w('iso'), tests.version('core.isolation', tests.w('iso')), 'MFT-22', 'Prove-test-prove', true) ->> 'ok', 'true',
  'a second authorised person proves it dead');
select is((select array_agg(step order by created_at) from core.control_event where control_kind = 'isolation' and control_id = tests.w('iso')),
  array['request', 'authorise', 'apply', 'prove'], 'each step recorded');
select is((select content #>> '{lock_refs,1}' from core.control_event where control_kind = 'isolation' and control_id = tests.w('iso') and step = 'apply'),
  'L-18', 'with the locks applied');

-- ---- Impairment (Q135-Q141) ------------------------------------------------------------------------------
select tests.login(tests.w('u_op'));
insert into t_r select 'imp', api.request_impairment(tests.key(), array[tests.w('wah')], tests.w('fa1'), 'Hall 1 detectors 12 to 18', 'Dust from the work',
  now() - interval '1 hour', now() + interval '1 day');
select tests.set_w('imp', (select (v ->> 'impairment_id')::uuid from t_r where name = 'imp'));
select tests.login(tests.w('u_ada'));
select is(api.authorise_impairment(tests.key(), tests.w('imp'), tests.version('core.impairment', tests.w('imp')), 'authorise', 'Agreed') ->> 'code',
  'not_configured', 'no impairment without published rules for the system type');
select tests.login(tests.w('u_tom'));
select is(api.publish_control_rule(tests.key(), tests.w('st_fa'), 'impairment', '{"compensatory_measures": [], "notifications": []}', now(), 'Rules') ->> 'code',
  'invalid_content', 'the maximum impairment time has no default (Q139)');
select tests.must(api.publish_control_rule(tests.key(), tests.w('st_fa'), 'impairment',
  '{"max_duration_hours": 4, "compensatory_measures": ["Fire marshal patrol of Hall 1 every 30 minutes"], "notifications": ["Alarm receiving centre"]}',
  now() - interval '1 minute', 'Fire strategy rev. 2 (test values)'));
select tests.login(tests.w('u_ada'));
select is(api.authorise_impairment(tests.key(), tests.w('imp'), tests.version('core.impairment', tests.w('imp')), 'authorise', 'Agreed for dust') ->> 'ok', 'true',
  'the authority authorises the impairment');
select is((select max_hours from core.impairment where id = tests.w('imp')), 4::numeric, 'with the rule''s maximum');
select tests.login(tests.w('u_al'));
insert into t_r select 'impair_missing', api.impair_system(tests.key(), tests.w('imp'), tests.version('core.impairment', tests.w('imp')), '[]', '[]');
select is((select v ->> 'code' from t_r where name = 'impair_missing'), 'measures_missing',
  'a system is not impaired until its compensatory measures and notifications are recorded (Q137, Q138)');
select is((select jsonb_array_length(v -> 'missing') from t_r where name = 'impair_missing'), 2, 'each one listed');
select is(api.impair_system(tests.key(), tests.w('imp'), tests.version('core.impairment', tests.w('imp')),
  jsonb_build_array(jsonb_build_object('measure', 'Fire marshal patrol of Hall 1 every 30 minutes', 'in_place_person_id', tests.w('p_vic'))),
  jsonb_build_array(jsonb_build_object('notification', 'Alarm receiving centre', 'told', 'ARC operator 4', 'how', 'Phone', 'at', clock_timestamp() + interval '1 hour')))
  ->> 'code', 'measures_missing', 'a notification cannot be recorded as given in the future');
select is(api.impair_system(tests.key(), tests.w('imp'), tests.version('core.impairment', tests.w('imp')),
  jsonb_build_array(jsonb_build_object('measure', 'Fire marshal patrol of Hall 1 every 30 minutes', 'in_place_person_id', tests.w('p_vic'))), '[]')
  ->> 'code', 'measures_missing', 'nor left out when every measure is recorded');
select is(api.impair_system(tests.key(), tests.w('imp'), tests.version('core.impairment', tests.w('imp')),
  jsonb_build_array(jsonb_build_object('measure', 'Fire marshal patrol of Hall 1 every 30 minutes', 'in_place_person_id', tests.w('p_vic'))),
  jsonb_build_array(jsonb_build_object('notification', 'Alarm receiving centre', 'told', 'ARC operator 4', 'how', 'Phone', 'at', clock_timestamp())))
  ->> 'ok', 'true', 'with them recorded, the system is impaired');

-- ---- Exclusion zone and issue --------------------------------------------------------------------------------
select tests.login(tests.w('u_nia'));
select is(api.set_up_exclusion_zone(tests.key(), tests.w('wah'), tests.w('hall1'), 'Barriers round the MEWP') ->> 'code', 'not_permit_part',
  'only the supervisor records an exclusion zone');
select tests.login(tests.w('u_op'));
select tests.set_w('zone', tests.must(api.set_up_exclusion_zone(tests.key(), tests.w('wah'), tests.w('hall1'), 'Barriers round the MEWP, 3 m')));
select is(jsonb_array_length(api.issue_blockers(tests.w('wah')) -> 'blockers'), 0, 'with every control in place, nothing blocks issue');
select tests.login(tests.w('u_ivy'));
select tests.must(api.issue_permit(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah'))));
select is((select jsonb_array_length(content #> '{controls,isolations}') from core.issue_snapshot where id = (select issue_snapshot_id from core.permit where id = tests.w('wah'))),
  1, 'the issue snapshot records the controls relied on (invariant 5)');
select ok(api.issue_blockers(tests.w('hw'))::text like '%fire watch during the work%', 'hot works needs its fire watches arranged first');
select tests.login(tests.w('u_op'));
select is(api.arrange_fire_watch(tests.key(), tests.w('hw'), 'during', tests.w('p_h')) ->> 'ok', 'true', 'the supervisor arranges a named watcher during the work');
select is(api.arrange_fire_watch(tests.key(), tests.w('hw'), 'during', tests.w('p_owen')) ->> 'code', 'already_arranged', 'one watch per phase at a time');
select is(api.arrange_fire_watch(tests.key(), tests.w('wah'), 'post', tests.w('p_owen')) ->> 'code', 'not_required', 'and only where the class needs one');
select tests.must(api.arrange_fire_watch(tests.key(), tests.w('hw'), 'post', tests.w('p_owen')));
select tests.login(tests.w('u_ivy'));
select tests.must(api.issue_permit(tests.key(), tests.w('hw'), tests.version('core.permit', tests.w('hw'))));
select tests.logout();
-- Acceptance re-checks the controls at the workface: an isolation that failed in between stops it.
select tests.login(tests.w('u_op'));
select tests.must(api.accept_permit(tests.key(), tests.w('wa'), tests.version('core.permit', tests.w('wa')), tests.conditions_of(tests.w('wa')),
  array[tests.w('p_op'), tests.w('p_owen')], clock_timestamp()));
select tests.logout();
update core.impairment set impaired_at = now() - interval '5 hours' where id = tests.w('imp');   -- time cannot pass inside a test
select tests.login(tests.w('u_op'));
select is(api.accept_permit(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), tests.conditions_of(tests.w('wah')),
  array[tests.w('p_op'), tests.w('p_owen')], clock_timestamp()) ->> 'code', 'controls_not_ready',
  'acceptance re-checks the controls: an impairment past its maximum stops it');
select tests.logout();
update core.impairment set impaired_at = clock_timestamp() where id = tests.w('imp');
select tests.login(tests.w('u_op'));
select tests.must(api.accept_permit(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), tests.conditions_of(tests.w('wah')),
  array[tests.w('p_op'), tests.w('p_owen')], clock_timestamp()));
select tests.must(api.accept_permit(tests.key(), tests.w('hw'), tests.version('core.permit', tests.w('hw')), tests.conditions_of(tests.w('hw')),
  array[tests.w('p_op'), tests.w('p_owen')], clock_timestamp()));
select is(tests.status_of(tests.w('wa')) || '/' || tests.status_of(tests.w('wah')) || '/' || tests.status_of(tests.w('hw')), 'active/active/active',
  'issued and accepted with its controls in place');

-- ---- Personal locks (Q145, Q146) ---------------------------------------------------------------------------
select tests.login(tests.w('u_nia'));
select is(api.isolation_lock_on(tests.key(), tests.w('iso'), tests.w('p_nia'), 'P-9') ->> 'code', 'not_permit_part',
  'someone not on the team of a permit the isolation protects cannot lock on');
select tests.login(tests.w('u_op'));
insert into t_r select 'lock', api.isolation_lock_on(tests.key(), tests.w('iso'), tests.w('p_owen'), 'P-31');
select is((select v ->> 'ok' from t_r where name = 'lock'), 'true', 'the supervisor records Owen''s personal lock');
select is(api.isolation_lock_on(tests.key(), tests.w('iso'), tests.w('p_owen'), 'P-32') ->> 'code', 'already_on', 'one lock per person');
select is(api.isolation_lock_on(tests.key(), tests.w('iso'), tests.w('p_nia'), 'P-9') ->> 'code', 'not_on_team',
  'and only for someone on the team of a permit the isolation protects');
select tests.login(tests.w('u_ada'));
insert into t_r select 'rm_live', api.remove_isolation(tests.key(), tests.w('iso'), tests.version('core.isolation', tests.w('iso')), 'Removed');
select is((select v ->> 'code' from t_r where name = 'rm_live'), 'permits_live', 'an isolation is not removed while a permit it protects is live');
select ok((select v::text from t_r where name = 'rm_live') like '%Work at height%', 'naming the permit');

-- ---- Control failure (design §8.5, invariant 7) ------------------------------------------------------------
select tests.login(tests.w('u_op'));
insert into t_r select 'fail', api.report_control_failure(tests.key(), 'isolation', tests.w('iso'), 'Breaker found closed during a check');
select is((select v ->> 'ok' from t_r where name = 'fail'), 'true', 'someone on the team reports the isolation failed');
select is(tests.status_of(tests.w('wa')) || '/' || tests.status_of(tests.w('wah')) || '/' || tests.status_of(tests.w('hw')), 'suspended/suspended/suspended',
  'every permit on the job relying on it is suspended');
select is(tests.holding(tests.w('wah')), array['control_failure'], 'the protected permit by the failure');
select is(tests.holding(tests.w('hw')), array['job_stop'], 'the rest of the job by a stop that is lifted with it');
select is((select status from core.isolation where id = tests.w('iso')), 'applied', 'and the isolation must be proved again');
select tests.login(tests.w('u_ivy'));
select is(api.lift_suspension(tests.key(), (select id from core.permit_suspension where permit_id = tests.w('wah') and kind = 'control_failure'), 'Fine') ->> 'code',
  'not_this_route', 'a permit issuer cannot lift a control failure');
select tests.login(tests.w('u_ada'));
select is(api.lift_control_failure(tests.key(), (select (v ->> 'failure_id')::uuid from t_r where name = 'fail'), 'Breaker reopened') ->> 'code',
  'not_restored', 'the isolation authority lifts it only once the isolation is proved again');
select tests.login(tests.w('u_bo'));
select tests.must(api.prove_isolation(tests.key(), tests.w('iso'), tests.version('core.isolation', tests.w('iso')), 'MFT-22', 'Prove-test-prove', true));
select tests.login(tests.w('u_op'));
select ok(api.permit_detail(tests.w('wah'))::text like '%The isolation of HV ring has failed and is not restored.%',
  'a re-proved isolation still does not count until the failure is lifted');
select is(tests.reaccept(tests.w('wa')) ->> 'code', 'still_suspended', 'proving it again does not restart work on its own');
select tests.login(tests.w('u_op'));
select is(api.lift_control_failure(tests.key(), (select (v ->> 'failure_id')::uuid from t_r where name = 'fail'), 'Re-proved') ->> 'code',
  'separation_of_duties', 'an isolation authority connected with the job cannot lift a failure on it');
select tests.login(tests.w('u_al'));
select is(api.lift_control_failure(tests.key(), (select (v ->> 'failure_id')::uuid from t_r where name = 'fail'), 'Re-proved') ->> 'code',
  'no_covering_appointment', 'an authorised person without the lifting appointment cannot lift it');
select tests.login(tests.w('u_ada'));
select is(api.lift_control_failure(tests.key(), (select (v ->> 'failure_id')::uuid from t_r where name = 'fail'), 'Breaker reopened and locked; re-proved',
  array['Check the breaker lock at each break']) ->> 'ok', 'true', 'the isolation authority lifts it, with a condition');
select is(tests.reaccept(tests.w('wa')) ->> 'ok', 'true', 'the supervisor re-accepts the Work Approval');
select is(tests.reaccept(tests.w('wah')) ->> 'ok', 'true', 'and the protected permit, acknowledging the condition');
select is(tests.reaccept(tests.w('hw')) ->> 'ok', 'true', 'and hot works');

-- ---- Impairment overrun (Q139, Q141, invariant 10) ---------------------------------------------------------
select tests.logout();
update core.impairment set impaired_at = now() - interval '5 hours' where id = tests.w('imp');   -- time cannot pass inside a test
select ok(core.control_blockers(tests.w('wah'))::text like '%run past its approved maximum%', 'past its maximum, the impairment is overdue');
select is((select status from core.impairment where id = tests.w('imp')), 'impaired', 'and stays impaired: time restores nothing and approves nothing');
select tests.login(tests.w('u_op'));
select tests.must(api.stop_work(tests.key(), tests.w('wah'), 'other', 'Checking the dust screens'));
select tests.login(tests.w('u_ivy'));
select tests.must(api.lift_suspension(tests.key(), (select id from core.permit_suspension where permit_id = tests.w('wah') and reason = 'Checking the dust screens'), 'Screens fine'));
select tests.must(tests.reaccept(tests.w('wa')));
select ok(tests.reaccept(tests.w('wah'))::text like '%run past its approved maximum%', 'nor can work restart under an impairment past its maximum');
select tests.login(tests.w('u_ada'));
select ok((select bool_or((x ->> 'overdue')::boolean) from jsonb_array_elements(api.controls_desk() -> 'impairments') x), 'the controls desk shows it overdue');
select is(api.reauthorise_impairment(tests.key(), tests.w('imp'), tests.version('core.impairment', tests.w('imp')), 3, 'Dust continues') ->> 'code',
  'invalid_content', 'a fresh authorisation must set a longer maximum');
select is(api.reauthorise_impairment(tests.key(), tests.w('imp'), tests.version('core.impairment', tests.w('imp')), 8, 'Ceiling work runs late') ->> 'ok', 'true',
  'the authority authorises it to continue, with a reason');
select is(api.permit_detail(tests.w('wah')) #> '{controls,blockers}', '[]'::jsonb, 'and it is no longer overdue');
select tests.must(tests.reaccept(tests.w('wah')));
select tests.must(tests.reaccept(tests.w('hw')));

-- ---- Fire watch (Q130, Q134) ---------------------------------------------------------------------------------
select tests.login(tests.w('u_op'));
select tests.set_w('fw_d', (select id from core.fire_watch where permit_id = tests.w('hw') and phase = 'during'));
select tests.set_w('fw_p', (select id from core.fire_watch where permit_id = tests.w('hw') and phase = 'post'));
select tests.must(api.start_fire_watch(tests.key(), tests.w('fw_d'), tests.version('core.fire_watch', tests.w('fw_d'))));
select is(api.check_fire_watch(tests.key(), tests.w('fw_d'), 'No smouldering; screens in place') ->> 'ok', 'true', 'checks are recorded');
select is(api.end_fire_watch(tests.key(), tests.w('fw_d'), tests.version('core.fire_watch', tests.w('fw_d')), 'Hot work finished, area cool') ->> 'ok', 'true',
  'the watch during the work ends with the work');
select tests.must(api.start_fire_watch(tests.key(), tests.w('fw_p'), tests.version('core.fire_watch', tests.w('fw_p'))));
select is(api.end_fire_watch(tests.key(), tests.w('fw_p'), tests.version('core.fire_watch', tests.w('fw_p')), 'All clear') ->> 'code', 'too_soon',
  'the watch after the work cannot end before its minimum');
select tests.logout();
alter table core.fire_watch disable trigger b_guard_update;
update core.fire_watch set started_at = started_at - interval '61 minutes' where id = tests.w('fw_p');   -- time cannot pass inside a test
alter table core.fire_watch enable trigger b_guard_update;
select tests.login(tests.w('u_op'));
select is(api.end_fire_watch(tests.key(), tests.w('fw_p'), tests.version('core.fire_watch', tests.w('fw_p')), ' ') ->> 'code', 'invalid_content',
  'the final check needs its findings');
select is(api.end_fire_watch(tests.key(), tests.w('fw_p'), tests.version('core.fire_watch', tests.w('fw_p')), 'All clear at 60 minutes, no hot spots') ->> 'ok', 'true',
  'after the minimum, the final check ends it');

-- ---- Custody (Q118, Q160) ------------------------------------------------------------------------------------
select tests.login(tests.w('u_a1'));
select tests.set_w('key', tests.must(api.register_custody_item(tests.key(), tests.w('v1'), 'hatch_key', 'Roof hatch 2 key', 'K-RH2')));
select is(api.register_custody_item(tests.key(), tests.w('v1'), 'key', 'Copy', 'K-RH2') ->> 'code', 'duplicate', 'references are unique at the venue');
select is(api.issue_custody_item(tests.key(), tests.w('key'), tests.w('wah'), tests.w('p_op')) ->> 'code', 'no_covering_appointment',
  'a tenant administrator registers items but does not issue them');
select tests.login(tests.w('u_tom'));
insert into t_r select 'cust', api.issue_custody_item(tests.key(), tests.w('key'), tests.w('wah'), tests.w('p_op'));
select is((select v ->> 'ok' from t_r where name = 'cust'), 'true', 'the key controller issues the roof hatch key against the permit');
select is(api.issue_custody_item(tests.key(), tests.w('key'), tests.w('hw'), tests.w('p_owen')) ->> 'code', 'not_available', 'it cannot be issued twice');
select is((api.permit_detail(tests.w('wah')) #>> '{controls,custody,0,holder}'), 'Oli Operative', 'the permit shows who holds it');
select is(api.return_custody_item(tests.key(), (select (v ->> 'movement_id')::uuid from t_r where name = 'cust')) ->> 'ok', 'true', 'and its return is recorded');

-- ---- Removing an isolation and returning to service (Q143, Q146, Q148) ---------------------------------------
-- A second job's isolation, whose permit is not yet issued.
select tests.set_w('wp2', tests.today_job('Socket outlets', array[tests.w('pc_wah')]));
select tests.login(tests.w('u_op'));
select tests.set_w('iso2', (api.request_isolation(tests.key(), array[tests.permit_of(tests.w('wp2'), tests.w('pc_wah'))], tests.w('hv1'), 'HV1 feeder 5',
  'Socket circuits', now() - interval '1 hour', now() + interval '1 day') ->> 'isolation_id')::uuid);
select tests.login(tests.w('u_ada'));
select tests.must(api.authorise_isolation(tests.key(), tests.w('iso2'), tests.version('core.isolation', tests.w('iso2')), 'authorise', 'Feeder 5 breaker'));
select tests.login(tests.w('u_al'));
select tests.must(api.apply_isolation(tests.key(), tests.w('iso2'), tests.version('core.isolation', tests.w('iso2')), 'IC-105', array['L-21'], null));
select tests.login(tests.w('u_bo'));
select tests.must(api.prove_isolation(tests.key(), tests.w('iso2'), tests.version('core.isolation', tests.w('iso2')), 'MFT-22', 'Prove-test-prove', true));
-- OP puts on a lock for himself, then leaves site without taking it off.
select tests.login(tests.w('u_op'));
select tests.must(api.save_permit_draft(tests.key(), tests.permit_of(tests.w('wp2'), tests.w('pc_wah')), '{"access": ["mewp"]}', now() - interval '1 hour', now() + interval '1 day'));
select tests.must(api.set_permit_team(tests.key(), tests.permit_of(tests.w('wp2'), tests.w('pc_wah')),
  jsonb_build_array(jsonb_build_object('person_id', tests.w('p_op'), 'role', 'supervisor'))));
insert into t_r select 'lock2', api.isolation_lock_on(tests.key(), tests.w('iso2'), tests.w('p_op'), 'P-7');
select tests.must((select v from t_r where name = 'lock2'));
select tests.login(tests.w('u_ada'));
select is(api.remove_isolation(tests.key(), tests.w('iso2'), tests.version('core.isolation', tests.w('iso2')), 'Removed') ->> 'code', 'locks_on',
  'an isolation is not removed while a personal lock is on');
select is(api.isolation_lock_off_on_behalf(tests.key(), (select (v ->> 'lock_id')::uuid from t_r where name = 'lock2'), 'Holder has left site', false) ->> 'code',
  'invalid_content', 'removing a lock for an absent holder needs confirmation they are not in the area');
select tests.login(tests.w('u_tom'));
select is(api.isolation_lock_off_on_behalf(tests.key(), (select (v ->> 'lock_id')::uuid from t_r where name = 'lock2'), 'Holder has left site', true) ->> 'code',
  'no_covering_appointment', 'and only the isolation authority can do it');
select tests.login(tests.w('u_ada'));
select is(api.isolation_lock_off_on_behalf(tests.key(), (select (v ->> 'lock_id')::uuid from t_r where name = 'lock2'), 'Holder has left site; phoned, confirmed', true)
  ->> 'ok', 'true', 'the isolation authority removes it on the holder''s behalf');
select is((select off_on_behalf from core.isolation_lock where id = (select (v ->> 'lock_id')::uuid from t_r where name = 'lock2')), true, 'recorded as on their behalf');
select is(api.remove_isolation(tests.key(), tests.w('iso2'), tests.version('core.isolation', tests.w('iso2')), 'Locks L-21 off, keys returned') ->> 'ok', 'true',
  'then the isolation is removed');
select is(api.return_isolation(tests.key(), tests.w('iso2'), tests.version('core.isolation', tests.w('iso2')), 'Insulation resistance test passed') ->> 'code',
  'witness_required', 'return to service needs a witness under these rules');
select is(api.return_isolation(tests.key(), tests.w('iso2'), tests.version('core.isolation', tests.w('iso2')), 'IR test passed', (select person_id from core.user_account where auth_user_id = tests.w('u_ada'))) ->> 'code',
  'witness_required', 'who is not the person returning it');
select is(api.return_isolation(tests.key(), tests.w('iso2'), tests.version('core.isolation', tests.w('iso2')), 'IR test passed, energised by Ada', tests.w('x_bo')) ->> 'ok',
  'true', 'with a witness, the system returns to service (Q148)');

-- ---- Withdrawn and refused requests, reinstatement test ------------------------------------------------------
select tests.login(tests.w('u_op'));
select tests.set_w('imp2', (api.request_impairment(tests.key(), array[tests.permit_of(tests.w('wp2'), tests.w('pc_wah'))], tests.w('fa1'), 'Hall 2 detector 4',
  'Not needed after all', now(), now() + interval '1 day') ->> 'impairment_id')::uuid);
select tests.login(tests.w('u_ada'));
select is(api.withdraw_impairment(tests.key(), tests.w('imp2'), tests.version('core.impairment', tests.w('imp2')), 'Job changed') ->> 'ok', 'true',
  'a request no longer needed is withdrawn, not left open');
select tests.login(tests.w('u_al'));
select is(api.test_reinstatement(tests.key(), tests.w('imp'), tests.version('core.impairment', tests.w('imp')), (select person_id from core.user_account where auth_user_id = tests.w('u_al')),
  true, 'Detectors tested') ->> 'code', 'witness_required', 'the reinstatement test needs a witness other than the tester (Q140)');
select is(api.test_reinstatement(tests.key(), tests.w('imp'), tests.version('core.impairment', tests.w('imp')), tests.w('x_bo'), false, 'Detector 15 failed') ->> 'ok',
  'true', 'a failed test is recorded');
select is((select status from core.impairment where id = tests.w('imp')), 'impaired', 'and the system stays impaired');
select is(api.restore_system(tests.key(), tests.w('imp'), tests.version('core.impairment', tests.w('imp')), 'Back in service') ->> 'code', 'not_tested',
  'it cannot be confirmed back in service without a passed test');

-- ---- Separation and visibility --------------------------------------------------------------------------------
select tests.login(tests.w('u_a1'));
select is(api.apply_isolation(tests.key(), tests.w('iso2'), 1, 'IC', array['L'], null) ->> 'code', 'no_covering_appointment',
  'a tenant administrator takes no step on a control (invariant 9)');
select tests.login(tests.w('u_nia'));
select is((select count(*)::int from api.isolation) + (select count(*)::int from api.impairment) + (select count(*)::int from api.fire_watch)
          + (select count(*)::int from api.exclusion_zone) + (select count(*)::int from api.control_event), 0,
  'an operative with no part in the jobs sees none of their controls');
select is(jsonb_array_length(api.controls_desk() -> 'isolations'), 0, 'and has no controls desk');
select tests.login(tests.w('u_b1'));
select is((select count(*)::int from api.isolation) + (select count(*)::int from api.impairment) + (select count(*)::int from api.control_link)
          + (select count(*)::int from api.isolation_lock) + (select count(*)::int from api.custody_item) + (select count(*)::int from api.custody_movement)
          + (select count(*)::int from api.control_failure) + (select count(*)::int from api.system_control_rule), 0,
  'another tenant sees none of them');
select is(api.authorise_isolation(tests.key(), tests.w('iso'), 1, 'refuse', 'Mine') ->> 'code', 'not_found', 'and cannot act on them');
select tests.login(tests.w('u_ada'));
select ok((select bool_or(x ->> 'system' = 'HV ring') from jsonb_array_elements(api.controls_desk() -> 'isolations') x), 'the isolation authority''s desk lists HV1');
select tests.login(tests.w('u_op'));
select ok(api.permit_detail(tests.w('wah'))::text !~* '(op@a\.test|07000|ada@a\.test)', 'the permit''s controls carry names, never contact details');

select tests.logout();
select * from finish();
rollback;
