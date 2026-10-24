-- Delegation (invariant 7): within both appointments, never re-delegable, lapses
-- with the delegator's appointment, withdrawn only by the delegator.
begin;
\ir _helpers.psql
select no_plan();

create function tests.delegate(p_from uuid, p_to uuid, p_actions text[], p_scopes jsonb,
                               p_target_type text default null, p_target_id uuid default null)
returns jsonb language sql as $$
  select api.grant_delegation(tests.key(), p_from, p_to, p_actions, '{}', p_scopes,
                              now() - interval '1 minute', now() + interval '1 day', 'Cover during leave',
                              p_target_type, p_target_id) $$;
grant execute on function tests.delegate(uuid, uuid, text[], jsonb, text, uuid) to authenticated;

-- ---- Within both appointments -----------------------------------------------
select tests.login(tests.w('u_h'));
select is(tests.delegate(tests.w('ap_h'), tests.w('ap_f'), array['test.area_action'],
            jsonb_build_array(jsonb_build_object('area_id', tests.w('hall1')))) ->> 'code',
  'no_covering_appointment', 'cannot delegate an area to someone whose own appointment does not cover it');
select is(tests.delegate(tests.w('ap_h'), tests.w('ap_h2'), array['test.area_action'],
            jsonb_build_array(jsonb_build_object('area_id', tests.w('hall2')))) ->> 'code',
  'no_covering_appointment', 'cannot delegate an area beyond one''s own appointment');
select is(tests.delegate(tests.w('ap_h'), tests.w('ap_h2'), array['test.system_action'],
            jsonb_build_array(jsonb_build_object('area_id', tests.w('hall1')))) ->> 'code',
  'no_covering_appointment', 'cannot delegate an action one''s own appointment does not hold');
create temp table t_d1 as
  select (tests.delegate(tests.w('ap_h'), tests.w('ap_h2'), array['test.area_action'],
            jsonb_build_array(jsonb_build_object('area_id', tests.w('hall1')))) ->> 'id')::uuid as id;
grant select on t_d1 to authenticated;
select isnt((select id from t_d1), null, 'can delegate an action within both appointments');
select tests.logout();

select tests.login(tests.w('u_r'));
select is(tests.delegate(tests.w('ap_r'), tests.w('ap_h2'), array['appointment.grant'],
            jsonb_build_array(jsonb_build_object('area_id', tests.w('hall1')))) ->> 'code',
  'no_covering_appointment', 'the power to appoint cannot be delegated');
select is(tests.delegate(tests.w('ap_r'), tests.w('ap_h2'), array['delegation.grant'],
            jsonb_build_array(jsonb_build_object('area_id', tests.w('hall1')))) ->> 'code',
  'no_covering_appointment', 'the power to delegate cannot itself be delegated');
select is(tests.delegate(tests.w('ap_h'), tests.w('ap_h2'), array['test.area_action'],
            jsonb_build_array(jsonb_build_object('area_id', tests.w('hall1')))) ->> 'code',
  'capacity_not_valid', 'cannot delegate from someone else''s appointment');
select tests.logout();

-- ---- The delegation is a real, recorded capacity -----------------------------
select tests.login(tests.w('u_h2'));
select is(api.check('test.area_action',
            jsonb_build_object('customer_id', tests.w('cust_a'), 'venue_id', tests.w('v1'), 'area_id', tests.w('hall1'),
                               'record_id', gen_random_uuid(), 'target_type', 'test'),
            null, (select id from t_d1)) ->> 'acting_delegation_id',
  (select id::text from t_d1), 'the delegate can act in the delegated capacity');
select is(api.revoke_delegation(tests.key(), (select id from t_d1), tests.version('core.delegation', (select id from t_d1)), 'x') ->> 'code',
  'not_subject', 'only the delegator can withdraw a delegation');
select tests.logout();

-- ---- Lapses the moment the delegator's appointment ends -----------------------
select tests.login(tests.w('u_r'));
select tests.must(api.revoke_appointment(tests.key(), tests.w('ap_h'), tests.version('core.appointment', tests.w('ap_h')),
  'Appointment withdrawn'));
select tests.logout();
select tests.login(tests.w('u_h2'));
select is(api.check('test.area_action',
            jsonb_build_object('customer_id', tests.w('cust_a'), 'venue_id', tests.w('v1'), 'area_id', tests.w('hall1'),
                               'record_id', gen_random_uuid(), 'target_type', 'test'),
            null, (select id from t_d1)) ->> 'code',
  'no_covering_appointment', 'a delegation stops working when the delegator''s appointment is revoked');
select tests.logout();
select is((select status from core.delegation where id = (select id from t_d1)), 'in_force',
  'the lapse is derived; the delegation record itself is unchanged');

-- ---- Withdrawal by the delegator -------------------------------------------
select tests.login(tests.w('u_f'));
create temp table t_d2 as
  select (tests.delegate(tests.w('ap_f'), tests.w('ap_r'), array['test.system_action'],
            jsonb_build_array(jsonb_build_object('system_id', tests.w('fa1')))) ->> 'id')::uuid as id;
select isnt((select id from t_d2), null, 'a system authority can delegate within the system');
select is(api.revoke_delegation(tests.key(), (select id from t_d2), tests.version('core.delegation', (select id from t_d2)),
            'No longer needed') ->> 'ok',
  'true', 'the delegator can withdraw it');
select tests.logout();
select is((select status from core.delegation where id = (select id from t_d2)), 'revoked', 'the delegation is revoked');

select * from finish();
rollback;
