-- Restrictions with real effects (Q18, D-010, P2-7) and appointment type approval
-- by the root appointee (D-011).
begin;
\ir _helpers.psql
\ir _phase2.psql
select no_plan();

-- ---- Restricting a person ---------------------------------------------------------
select tests.login(tests.w('u_a1'));
select is(api.impose_restriction(tests.key(), tests.w('v1'), 'person', tests.w('p_h'), 'Site rules breach') ->> 'code',
  'no_covering_appointment', 'a tenant administrator cannot restrict a person');
select tests.login(tests.w('u_r'));
select throws_ok(format($$select api.impose_restriction(%L, %L, 'person', %L, '  ')$$, tests.key(), tests.w('v1'), tests.w('p_h')),
  '23514', null, 'a restriction needs a reason');
select tests.set_w('rx_h', tests.must(api.impose_restriction(tests.key(), tests.w('v1'), 'person', tests.w('p_h'),
  'Working outside the permitted area')));
select tests.login(tests.w('u_h'));
select is(tests.can('test.area_action', tests.w('hall1')) ->> 'code', 'person_restricted',
  'a restricted person cannot use their appointments at the venue');
select is((select count(*)::int from api.restriction where id = tests.w('rx_h')), 1,
  'and can see the restriction, so the refusal can be explained');
select is(api.lift_restriction(tests.key(), tests.w('rx_h'), tests.version('core.restriction', tests.w('rx_h')), 'Sorted') ->> 'code',
  'separation_of_duties', 'nobody can lift their own restriction');
select tests.login(tests.w('u_h2'));
select is(api.lift_restriction(tests.key(), tests.w('rx_h'), tests.version('core.restriction', tests.w('rx_h')), 'Sorted') ->> 'code',
  'no_covering_appointment', 'a different kind of appointee cannot lift it (D-010)');
select tests.login(tests.w('u_r'));
select is(api.lift_restriction(tests.key(), tests.w('rx_h'), tests.version('core.restriction', tests.w('rx_h')),
            'Retrained and briefed') ->> 'ok', 'true', 'the authority that imposed it can lift it');
select tests.login(tests.w('u_h'));
select is(tests.can('test.area_action', tests.w('hall1')) ->> 'allowed', 'true', 'and the person can act again');
select tests.logout();

-- ---- Restricting an organisation ----------------------------------------------------
select tests.login(tests.w('u_r'));
select tests.set_w('rx_c', tests.must(api.impose_restriction(tests.key(), tests.w('v1'), 'organisation', tests.w('org_c'),
  'Insurance under investigation')));
select is(api.approve_engagement(tests.key(), tests.w('e_c'), tests.version('core.engagement', tests.w('e_c'))) ->> 'code',
  'organisation_restricted', 'a restricted organisation''s engagement cannot be approved');
select tests.login(tests.w('u_a1'));
select is(api.create_engagement(tests.key(), tests.w('v1'), tests.w('org_c'), 'exhibitor', now()) ->> 'code',
  'organisation_restricted', 'nor can it be newly engaged at the venue');
select tests.login(tests.w('u_cara'));
select is((select count(*)::int from api.restriction where id = tests.w('rx_c')), 1, 'the organisation can see its restriction');
select is(api.lift_restriction(tests.key(), tests.w('rx_c'), tests.version('core.restriction', tests.w('rx_c')), 'x') ->> 'code',
  'separation_of_duties', 'people from the organisation cannot lift it');
select tests.login(tests.w('u_r'));
select is(api.lift_restriction(tests.key(), tests.w('rx_c'), tests.version('core.restriction', tests.w('rx_c')),
            'Cover confirmed by broker') ->> 'ok', 'true', 'its owner can');
select tests.logout();

-- ---- Appointment type versions need the root appointee (D-011) ------------------------
select tests.login(tests.w('u_a1'));
select is(api.publish_appointment_type_version(tests.key(), tests.w('t_fire'), array['test.system_action'], '{}',
            array[tests.w('st_fa')], '{}', false, false, tests.w('p_a1'), now(), 'Direct change') ->> 'code',
  'bootstrap_closed', 'once a venue has a root appointment, versions cannot be published directly');
select tests.set_w('tv_fire2', tests.must(api.propose_appointment_type_version(tests.key(), tests.w('t_fire'),
  array['test.system_action', 'delegation.grant'], '{}', array[tests.w('st_fa'), tests.w('st_hv')], '{}', false, false,
  tests.w('p_a1'), now() - interval '1 minute', 'Fire APs also cover HV interlocks')));
select tests.logout();
select is((select status from core.appointment_type_version where id = tests.w('tv_fire2')), 'proposed', 'it is proposed');

select tests.login(tests.w('u_r'));
select throws_ok(format($$select api.grant_appointment(%L, %L, %L, %L, '{}', '[{"system_id":"%s"}]', now(), now() + interval '1 day')$$,
                        tests.key(), tests.w('v1'), tests.w('p_op'), tests.w('tv_fire2'), tests.w('hv1')),
  '23514', null, 'a proposed version cannot be used for an appointment');
select tests.login(tests.w('u_h2'));
select is(api.decide_appointment_type_version(tests.key(), tests.w('tv_fire2'),
            tests.version('core.appointment_type_version', tests.w('tv_fire2')), 'approve', 'ok') ->> 'code',
  'no_covering_appointment', 'only a root appointee can approve it');
select tests.login(tests.w('u_a1'));
select is(api.decide_appointment_type_version(tests.key(), tests.w('tv_fire2'),
            tests.version('core.appointment_type_version', tests.w('tv_fire2')), 'approve', 'ok') ->> 'code',
  'separation_of_duties', 'the person who proposed it cannot approve it');
select tests.login(tests.w('u_a2'));
select is(api.decide_appointment_type_version(tests.key(), tests.w('tv_fire2'),
            tests.version('core.appointment_type_version', tests.w('tv_fire2')), 'approve', 'ok') ->> 'code',
  'no_covering_appointment', 'nor can another tenant administrator');
select tests.login(tests.w('u_r'));
select is(api.decide_appointment_type_version(tests.key(), tests.w('tv_fire2'),
            tests.version('core.appointment_type_version', tests.w('tv_fire2')), 'approve', 'Reviewed at technical meeting') ->> 'ok',
  'true', 'the root appointee approves it');
select is(api.grant_appointment(tests.key(), tests.w('v1'), tests.w('p_op'), tests.w('tv_fire2'), '{}',
            jsonb_build_array(jsonb_build_object('system_id', tests.w('hv1'))), now(), now() + interval '1 day') ->> 'ok',
  'true', 'and it can then be used');
select tests.logout();

select tests.login(tests.w('u_a1'));
select tests.set_w('tv_fire3', tests.must(api.propose_appointment_type_version(tests.key(), tests.w('t_fire'),
  array['test.system_action'], '{}', array[tests.w('st_fa')], '{}', false, false, tests.w('p_a1'), now(), 'Narrower')));
select tests.login(tests.w('u_r'));
select is(api.decide_appointment_type_version(tests.key(), tests.w('tv_fire3'),
            tests.version('core.appointment_type_version', tests.w('tv_fire3')), 'reject', 'Not agreed') ->> 'ok',
  'true', 'the root appointee can reject a proposal');
select tests.logout();
select is((select status from core.appointment_type_version where id = tests.w('tv_fire3')), 'rejected', 'it is rejected');

-- A venue with no root appointment can still be set up directly.
select tests.login(tests.w('u_a1'));
select tests.set_w('t_v2', tests.must(api.create_appointment_type(tests.key(), tests.w('v2'), 'ROOT2', 'Authorising Engineer')));
select is(api.publish_appointment_type_version(tests.key(), tests.w('t_v2'), array['appointment.grant'], '{}', '{}', '{}',
            true, false, tests.w('p_a1'), now(), 'Initial set-up') ->> 'ok',
  'true', 'a venue with no root appointment can publish directly (bootstrap)');
select tests.logout();

select * from finish();
rollback;
