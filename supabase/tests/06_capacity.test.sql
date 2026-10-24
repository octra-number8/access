-- Acting capacity (Q16): chosen explicitly when ambiguous, recorded on the decision.
begin;
\ir _helpers.psql
select no_plan();

-- H2 gets a second HALL appointment covering HALL2, alongside their whole-site one.
select tests.login(tests.w('u_r'));
select tests.set_w('ap_h2b', tests.must(api.grant_appointment(tests.key(), tests.w('v1'), tests.w('p_h2'), tests.w('tv_hall'),
  array[tests.w('pc_hw')], jsonb_build_array(jsonb_build_object('area_id', tests.w('hall2'))),
  now() - interval '10 minutes', now() + interval '1 day', null, null, 'Assessment record AR-19')));
select tests.login(tests.w('u_h2'));
select tests.must(api.acknowledge_appointment(tests.key(), tests.w('ap_h2b'), tests.version('core.appointment', tests.w('ap_h2b'))));

select is(tests.can('test.area_action', tests.w('hall2')) ->> 'code', 'capacity_selection_required',
  'two covering appointments and no choice: the user must choose');
select is(jsonb_array_length(tests.can('test.area_action', tests.w('hall2')) -> 'options'), 2,
  'the refusal lists both capacities');
select is(tests.can('test.area_action', tests.w('hall2'), null, null, tests.w('ap_h2b')) ->> 'acting_appointment_id',
  tests.w('ap_h2b')::text, 'choosing one capacity is accepted');
select is(tests.can('test.area_action', tests.w('hall2'), null, null, tests.w('ap_r')) ->> 'code', 'capacity_not_valid',
  'choosing someone else''s appointment is refused');
select is(tests.can('test.area_action', tests.w('hall1')) ->> 'acting_appointment_id', tests.w('ap_h2')::text,
  'where only one appointment covers the action, it is used automatically');

-- The capacity used is recorded on the decision and in the audit trail.
select tests.must(api.suspend_engagement(tests.key(), tests.w('e1'), tests.version('core.engagement', tests.w('e1')),
  'Recorded capacity test'));
select tests.logout();
select is((select acting_appointment_id from core.decision_context
            where action_code = 'engagement.suspend' and target_id = tests.w('e1')),
  tests.w('ap_h2'), 'the decision context records the acting appointment');
select ok(exists (select 1 from audit.audit_event
                   where target_table = 'core.engagement' and target_id = tests.w('e1')
                     and action = 'row.update' and acting_appointment_id = tests.w('ap_h2')),
  'the audit event for the change records the acting appointment');
select is((select actor_kind from core.decision_context
            where action_code = 'engagement.suspend' and target_id = tests.w('e1')),
  'user', 'an appointment-based decision is recorded as a user decision, not an administrative one');

select * from finish();
rollback;
