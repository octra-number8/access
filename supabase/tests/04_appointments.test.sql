-- Appointment scope (areas and systems, D-008), lifecycle (D-009), no widening,
-- self-appointment, competence evidence and revocation coverage.
begin;
\ir _helpers.psql
select no_plan();

-- Extra people with logins, created by the tenant admin.
create function tests.person_with_login(p_name text) returns uuid
language plpgsql as $$
declare p uuid; u uuid := tests.new_user(lower(p_name) || '@a.test');
begin
  perform tests.login(tests.w('u_a1'));
  p := tests.must(api.create_person(tests.key(), tests.w('cust_a'), p_name, 'Tester'));
  perform tests.must(api.link_user_account(tests.key(), p, u));
  perform tests.set_w('u_' || lower(p_name), u);
  perform tests.set_w('p_' || lower(p_name), p);
  perform tests.logout();
  return p;
end $$;

-- R grants an appointment to someone, who then acknowledges it.
create function tests.appoint(p_person uuid, p_user uuid, p_type_version uuid, p_classes uuid[], p_scopes jsonb,
                              p_from timestamptz, p_to timestamptz, p_by uuid default null, p_ack boolean default true)
returns uuid language plpgsql as $$
declare a uuid;
begin
  perform tests.login(coalesce(p_by, tests.w('u_r')));
  a := tests.must(api.grant_appointment(tests.key(), tests.w('v1'), p_person, p_type_version, p_classes, p_scopes,
                                        p_from, p_to, null, null, 'Assessment record'));
  if p_ack then
    perform tests.login(p_user);
    perform tests.must(api.acknowledge_appointment(tests.key(), a, tests.version('core.appointment', a)));
  end if;
  perform tests.logout();
  return a;
end $$;

-- ---- Area scope ------------------------------------------------------------
select tests.login(tests.w('u_h'));
select is(tests.can('test.area_action', tests.w('hall1')) ->> 'allowed', 'true', 'HALL1 appointee: allowed in HALL1');
select is(tests.can('test.area_action', tests.w('stand1')) ->> 'allowed', 'true', 'HALL1 appointee: allowed in a stand beneath HALL1');
select is(tests.can('test.area_action', tests.w('hall2')) ->> 'code', 'no_covering_appointment', 'HALL1 appointee: refused in HALL2');
select is(tests.can('test.area_action', tests.w('plant1')) ->> 'code', 'no_covering_appointment', 'HALL1 appointee: refused in a plant room');
select is(tests.can('test.area_action') ->> 'code', 'no_covering_appointment', 'HALL1 appointee: refused for a venue-wide target');
select is(tests.can('test.area_action', tests.w('hall1'), null, tests.w('pc_hw')) ->> 'allowed', 'true',
  'HALL1 appointee: allowed for their permit class');
select is(tests.can('test.area_action', tests.w('hall1'), null, tests.w('pc_el')) ->> 'code', 'no_covering_appointment',
  'HALL1 appointee: refused for a permit class they do not hold');
select is(tests.can('test.area_action', tests.w('hall1'), tests.w('fa1')) ->> 'code', 'no_covering_appointment',
  'area authority does not cover a system target, even in that area');
select tests.logout();

-- include_descendants = false covers the named area only.
select tests.person_with_login('Exact');
select tests.set_w('ap_exact', tests.appoint(tests.w('p_exact'), tests.w('u_exact'), tests.w('tv_hall'), array[tests.w('pc_hw')],
  jsonb_build_array(jsonb_build_object('area_id', tests.w('hall1'), 'include_descendants', false)),
  now() - interval '10 minutes', now() + interval '1 day'));
select tests.login(tests.w('u_exact'));
select is(tests.can('test.area_action', tests.w('hall1')) ->> 'allowed', 'true', 'exact-area appointee: allowed in the named area');
select is(tests.can('test.area_action', tests.w('stand1')) ->> 'code', 'no_covering_appointment',
  'exact-area appointee: refused beneath it');
select tests.logout();

-- ---- System scope (D-008) -------------------------------------------------
select tests.login(tests.w('u_f'));
select is(tests.can('test.system_action', null, tests.w('fa1')) ->> 'allowed', 'true', 'FA1 appointee: allowed on FA1');
select is(tests.can('test.system_action', tests.w('hall2'), tests.w('fa1')) ->> 'allowed', 'true',
  'FA1 appointee: allowed on FA1 in any area it serves');
select is(tests.can('test.system_action', null, tests.w('hv1')) ->> 'code', 'no_covering_appointment',
  'FA1 appointee: refused on another system');
select is(tests.can('test.system_action', tests.w('hall1')) ->> 'code', 'no_covering_appointment',
  'system authority does not cover an area-only target');
select tests.logout();

select tests.login(tests.w('u_r'));
select is(tests.can('test.system_action', null, tests.w('hv1')) ->> 'allowed', 'true',
  'a system-type scope covers every system of that type');
select tests.logout();

select tests.person_with_login('Restricted');
select tests.set_w('ap_restricted', tests.appoint(tests.w('p_restricted'), tests.w('u_restricted'), tests.w('tv_fire'), '{}',
  jsonb_build_array(jsonb_build_object('system_id', tests.w('fa1'), 'restrict_to_area_id', tests.w('hall1'))),
  now() - interval '10 minutes', now() + interval '1 day'));
select tests.login(tests.w('u_restricted'));
select is(tests.can('test.system_action', tests.w('hall1'), tests.w('fa1')) ->> 'allowed', 'true',
  'FA1-in-HALL1 appointee: allowed on FA1 in HALL1');
select is(tests.can('test.system_action', tests.w('stand1'), tests.w('fa1')) ->> 'allowed', 'true',
  'FA1-in-HALL1 appointee: allowed on FA1 beneath HALL1');
select is(tests.can('test.system_action', tests.w('hall2'), tests.w('fa1')) ->> 'code', 'no_covering_appointment',
  'FA1-in-HALL1 appointee: refused on FA1 in HALL2');
select is(tests.can('test.system_action', null, tests.w('fa1')) ->> 'code', 'no_covering_appointment',
  'FA1-in-HALL1 appointee: refused on FA1 system-wide');
select tests.logout();

-- ---- Lifecycle: pending, not yet effective, expired, revoked ---------------
select tests.person_with_login('Pending');
select tests.set_w('ap_pending', tests.appoint(tests.w('p_pending'), tests.w('u_pending'), tests.w('tv_hall'), array[tests.w('pc_hw')],
  jsonb_build_array(jsonb_build_object('area_id', tests.w('hall2'))), now() - interval '10 minutes', now() + interval '1 day',
  null, false));
select tests.login(tests.w('u_pending'));
select is(tests.can('test.area_action', tests.w('hall2')) ->> 'code', 'no_covering_appointment',
  'an unacknowledged appointment grants nothing (D-009)');
select is(api.acknowledge_appointment(tests.key(), tests.w('ap_pending'), tests.version('core.appointment', tests.w('ap_pending'))) ->> 'ok',
  'true', 'the appointee acknowledges');
select is(tests.can('test.area_action', tests.w('hall2')) ->> 'allowed', 'true', 'once acknowledged, it is in force');
select tests.logout();

select tests.login(tests.w('u_h'));
select is(api.acknowledge_appointment(tests.key(), tests.w('ap_pending'), tests.version('core.appointment', tests.w('ap_pending'))) ->> 'code',
  'not_subject', 'only the appointee can acknowledge their appointment');
select tests.logout();

select tests.person_with_login('Future');
select tests.set_w('ap_future', tests.appoint(tests.w('p_future'), tests.w('u_future'), tests.w('tv_hall'), array[tests.w('pc_hw')],
  jsonb_build_array(jsonb_build_object('area_id', tests.w('hall2'))), now() + interval '1 day', now() + interval '2 days'));
select tests.login(tests.w('u_future'));
select is(tests.can('test.area_action', tests.w('hall2')) ->> 'code', 'no_covering_appointment',
  'an appointment that has not yet started grants nothing');
select tests.logout();

select tests.person_with_login('Expired');
select tests.set_w('ap_expired', tests.appoint(tests.w('p_expired'), tests.w('u_expired'), tests.w('tv_hall'), array[tests.w('pc_hw')],
  jsonb_build_array(jsonb_build_object('area_id', tests.w('hall2'))), now() - interval '20 minutes', now() - interval '1 minute'));
select tests.login(tests.w('u_expired'));
select is(tests.can('test.area_action', tests.w('hall2')) ->> 'code', 'no_covering_appointment',
  'an expired appointment grants nothing');
select tests.logout();
select is((select status from core.appointment where id = tests.w('ap_expired')), 'in_force',
  'expiry is derived from the dates; no job rewrote the status');

select tests.login(tests.w('u_r'));
select is(api.revoke_appointment(tests.key(), tests.w('ap_h'), tests.version('core.appointment', tests.w('ap_h')),
            'Left the organisation') ->> 'ok', 'true', 'the appointer can revoke');
select tests.logout();
select tests.login(tests.w('u_h'));
select is(tests.can('test.area_action', tests.w('hall1')) ->> 'code', 'no_covering_appointment',
  'a revoked appointment grants nothing');
select tests.logout();
select is((select revoked_by_person_id from core.appointment where id = tests.w('ap_h')), tests.w('p_r'),
  'the revocation records who revoked');

-- ---- No widening ------------------------------------------------------------
select tests.login(tests.w('u_h2'));
select is(api.grant_appointment(tests.key(), tests.w('v1'), tests.w('p_op'), tests.w('tv_hall'), array[tests.w('pc_hw')],
            jsonb_build_array(jsonb_build_object('area_id', tests.w('hall2'))), now(), now() + interval '1 day',
            null, null, 'x') ->> 'code',
  'no_covering_appointment', 'an appointee whose type cannot appoint cannot grant');
select tests.logout();

select tests.login(tests.w('u_r'));
select is(api.grant_appointment(tests.key(), tests.w('v1'), tests.w('p_op'), tests.w('tv_root'), array[tests.w('pc_hw')],
            jsonb_build_array(jsonb_build_object('area_id', tests.w('hall2'))), now(), now() + interval '1 day') ->> 'code',
  'no_covering_appointment', 'cannot grant an appointment type one''s own type cannot grant');
select is(api.grant_appointment(tests.key(), tests.w('v1'), tests.w('p_op'), tests.w('tv_hall'), array[tests.w('pc_hw')],
            jsonb_build_array(jsonb_build_object('area_id', tests.w('hall2'))), now() - interval '2 hours', now() + interval '1 day',
            null, null, 'x') ->> 'code',
  'no_covering_appointment', 'cannot grant a window starting before one''s own appointment');
select is(api.grant_appointment(tests.key(), tests.w('v2'), tests.w('p_op'), tests.w('tv_hall'), array[tests.w('pc_hw')],
            jsonb_build_array(jsonb_build_object('area_id', tests.w('site2'))), now(), now() + interval '1 day',
            null, null, 'x') ->> 'code',
  'no_covering_appointment', 'cannot grant at a venue where one holds no appointment');
select is(api.grant_appointment(tests.key(), tests.w('v1'), tests.w('p_r'), tests.w('tv_hall'), array[tests.w('pc_hw')],
            jsonb_build_array(jsonb_build_object('area_id', tests.w('hall2'))), now(), now() + interval '1 day',
            null, null, 'x') ->> 'code',
  'separation_of_duties', 'nobody can appoint themselves');
select throws_ok(format($$select api.grant_appointment(%L, %L, %L, %L, array[%L]::uuid[], '[{"area_id":"%s"}]', now(), now() + interval '1 day', null, null, 'x')$$,
                        tests.key(), tests.w('v1'), tests.w('p_op'), tests.w('tv_hall'), tests.w('pc_el'), tests.w('hall2')),
  '23514', null, 'cannot name a permit class the appointment type does not allow');
select throws_ok(format($$select api.grant_appointment(%L, %L, %L, %L, array[%L]::uuid[], '[{"area_id":"%s"}]', now(), now() + interval '1 day')$$,
                        tests.key(), tests.w('v1'), tests.w('p_op'), tests.w('tv_hall'), tests.w('pc_hw'), tests.w('hall2')),
  '23514', null, 'a type that requires competence evidence refuses an appointment without it');
select tests.logout();

-- A scoped appointer: HALL v2 may appoint HALL within its own scope.
select tests.login(tests.w('u_a1'));
select tests.set_w('tv_hall2', tests.must(api.publish_appointment_type_version(tests.key(), tests.w('t_hall'),
  array['engagement.suspend','engagement.reinstate','test.area_action','delegation.grant','appointment.grant','appointment.revoke'],
  array[tests.w('pc_hw')], '{}', array[tests.w('t_hall')], false, true, tests.w('p_a1'),
  now() - interval '1 minute', 'Hall APs may appoint within their halls')));
select tests.logout();

select tests.login(tests.w('u_r'));
select throws_ok(format($$select api.grant_appointment(%L, %L, %L, %L, array[%L]::uuid[], '[{"area_id":"%s"}]', now(), now() + interval '1 day', null, null, 'x')$$,
                        tests.key(), tests.w('v1'), tests.w('p_op'), tests.w('tv_hall'), tests.w('pc_hw'), tests.w('hall2')),
  '23514', null, 'a superseded appointment type version cannot be used');
select tests.logout();

select tests.person_with_login('Lead');
select tests.set_w('ap_lead', tests.appoint(tests.w('p_lead'), tests.w('u_lead'), tests.w('tv_hall2'), array[tests.w('pc_hw')],
  jsonb_build_array(jsonb_build_object('area_id', tests.w('hall1'))), now() - interval '10 minutes', now() + interval '10 days'));
select tests.person_with_login('Sub');
select tests.login(tests.w('u_lead'));
select is(api.grant_appointment(tests.key(), tests.w('v1'), tests.w('p_sub'), tests.w('tv_hall2'), array[tests.w('pc_hw')],
            jsonb_build_array(jsonb_build_object('area_id', tests.w('stand1'))), now(), now() + interval '5 days',
            null, null, 'x') ->> 'ok',
  'true', 'a scoped appointer can appoint within their scope');
select is(api.grant_appointment(tests.key(), tests.w('v1'), tests.w('p_sub'), tests.w('tv_hall2'), array[tests.w('pc_hw')],
            jsonb_build_array(jsonb_build_object('area_id', tests.w('hall2'))), now(), now() + interval '5 days',
            null, null, 'x') ->> 'code',
  'no_covering_appointment', 'a scoped appointer cannot appoint in another area');
select is(api.grant_appointment(tests.key(), tests.w('v1'), tests.w('p_sub'), tests.w('tv_hall2'), array[tests.w('pc_hw')],
            jsonb_build_array(jsonb_build_object('area_id', tests.w('site'))), now(), now() + interval '5 days',
            null, null, 'x') ->> 'code',
  'no_covering_appointment', 'a scoped appointer cannot appoint over a wider area');
select is(api.grant_appointment(tests.key(), tests.w('v1'), tests.w('p_sub'), tests.w('tv_hall2'), array[tests.w('pc_hw')],
            jsonb_build_array(jsonb_build_object('area_id', tests.w('stand1'))), now(), now() + interval '20 days',
            null, null, 'x') ->> 'code',
  'no_covering_appointment', 'a scoped appointer cannot appoint beyond their own end date');
select is(api.revoke_appointment(tests.key(), tests.w('ap_h2'), tests.version('core.appointment', tests.w('ap_h2')), 'x') ->> 'code',
  'no_covering_appointment', 'a scoped appointer cannot revoke an appointment wider than their own');
select tests.logout();

select * from finish();
rollback;
