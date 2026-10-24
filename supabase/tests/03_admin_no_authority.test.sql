-- Invariant 9: platform and tenant administration grant no operational authority.
-- Phase 1's operational actions are appointment grant/revoke, delegation, and
-- engagement suspension/reinstatement; later phases add issue, approval and closure
-- to this file.
begin;
\ir _helpers.psql
select no_plan();

-- Something suspended, so lifting it can be attempted.
select tests.login(tests.w('u_r'));
select tests.must(api.suspend_engagement(tests.key(), tests.w('e1'), tests.version('core.engagement', tests.w('e1')), 'Test restriction'));
select tests.logout();

-- ---- Platform administrator, even with break-glass open ----------------------
select tests.login(tests.w('u_platform'));
select tests.must(api.open_break_glass(tests.key(), tests.w('cust_a'), 'Support ticket 4411: investigate login issue', 1));
select is(api.grant_appointment(tests.key(), tests.w('v1'), tests.w('p_op'), tests.w('tv_hall'), array[tests.w('pc_hw')],
            jsonb_build_array(jsonb_build_object('area_id', tests.w('hall2'))), now(), now() + interval '1 day',
            null, null, 'x') ->> 'ok',
  'false', 'super-admin cannot grant an appointment');
select is(api.revoke_appointment(tests.key(), tests.w('ap_h'), tests.version('core.appointment', tests.w('ap_h')), 'x') ->> 'ok',
  'false', 'super-admin cannot revoke an appointment');
select is(api.reinstate_engagement(tests.key(), tests.w('e1'), tests.version('core.engagement', tests.w('e1')), 'x') ->> 'ok',
  'false', 'super-admin cannot lift a suspension');
select is(api.grant_delegation(tests.key(), tests.w('ap_h'), tests.w('ap_h2'), array['test.area_action'], '{}',
            jsonb_build_array(jsonb_build_object('area_id', tests.w('hall1'))), now(), now() + interval '1 day', 'x') ->> 'ok',
  'false', 'super-admin cannot delegate');
select is(api.create_area(tests.key(), tests.w('site'), tests.w('k_hall'), 'PA', 'Platform area') ->> 'ok',
  'false', 'super-admin cannot even edit tenant master data');
select is((tests.can('test.area_action', tests.w('hall1'))) ->> 'allowed',
  'false', 'super-admin holds no operational capacity');
select tests.logout();

-- ---- Tenant administrator ---------------------------------------------------
select tests.login(tests.w('u_a1'));
select is(api.grant_appointment(tests.key(), tests.w('v1'), tests.w('p_op'), tests.w('tv_hall'), array[tests.w('pc_hw')],
            jsonb_build_array(jsonb_build_object('area_id', tests.w('hall2'))), now(), now() + interval '1 day',
            null, null, 'x') ->> 'code',
  'no_covering_appointment', 'tenant admin cannot grant an appointment');
select is(api.revoke_appointment(tests.key(), tests.w('ap_h'), tests.version('core.appointment', tests.w('ap_h')), 'x') ->> 'code',
  'no_covering_appointment', 'tenant admin cannot revoke an appointment');
select is(api.reinstate_engagement(tests.key(), tests.w('e1'), tests.version('core.engagement', tests.w('e1')), 'x') ->> 'code',
  'no_covering_appointment', 'tenant admin cannot lift a suspension');
select is(api.grant_delegation(tests.key(), tests.w('ap_h'), tests.w('ap_h2'), array['test.area_action'], '{}',
            jsonb_build_array(jsonb_build_object('area_id', tests.w('hall1'))), now(), now() + interval '1 day', 'x') ->> 'code',
  'capacity_not_valid', 'tenant admin cannot delegate from someone else''s appointment');
select throws_ok(format($$select api.end_engagement(%L, %L, %s, 'escape the suspension')$$,
                        tests.key(), tests.w('e1'), tests.version('core.engagement', tests.w('e1'))),
  '23514', null, 'tenant admin cannot end a suspended engagement to escape the suspension');

-- Recording a root appointment is administrative, but cannot be self-confirmed.
select tests.must(api.create_person(tests.key(), tests.w('cust_a'), 'Nia', 'NewRoot'));
create temp table t_root as
  select (api.record_root_appointment(tests.key(), tests.w('v1'),
            (select id from core.person where given_name = 'Nia'), tests.w('p_d'), tests.w('tv_root'),
            array[tests.w('pc_hw')], jsonb_build_array(jsonb_build_object('area_id', tests.w('site'))),
            now(), null, null, null, 'Letter of appointment DH-002') ->> 'id')::uuid as id;
grant select on t_root to authenticated;
select is(api.confirm_root_appointment(tests.key(), (select id from t_root),
            tests.version('core.appointment', (select id from t_root))) ->> 'code',
  'separation_of_duties', 'the administrator who recorded a root appointment cannot confirm it');
select is(api.record_root_appointment(tests.key(), tests.w('v1'), tests.w('p_a1'), tests.w('p_d'), tests.w('tv_root'),
            array[tests.w('pc_hw')], jsonb_build_array(jsonb_build_object('area_id', tests.w('site'))),
            now(), null, null, null, 'Letter DH-003') ->> 'code',
  'separation_of_duties', 'an administrator cannot record a root appointment for themselves');
select throws_ok(format($$select api.record_root_appointment(%L, %L, %L, %L, %L, '{}', '[{"area_id":"%s"}]', now(), null, null, null, 'Letter DH-004', 'x')$$,
                        tests.key(), tests.w('v1'), tests.w('p_op'), tests.w('p_d'), tests.w('tv_hall'), tests.w('site')),
  '23514', null, 'a non-root-eligible appointment type cannot be used for a root appointment');
select tests.logout();

select tests.login(tests.w('u_a2'));
select is(api.confirm_root_appointment(tests.key(), (select id from t_root),
            tests.version('core.appointment', (select id from t_root))) ->> 'ok',
  'true', 'a second administrator can confirm the root appointment');
select tests.logout();
select is((select status from core.appointment where id = (select id from t_root)), 'pending_acknowledgement',
  'a confirmed root appointment still waits for the appointee''s acknowledgement');

-- ---- Nothing changed, and every attempt is on record ------------------------
select is((select status from core.appointment where id = tests.w('ap_h')), 'in_force', 'H''s appointment is untouched');
select is((select status from core.engagement where id = tests.w('e1')), 'suspended', 'the suspension is still in place');
select is((select count(*)::int from core.delegation), 0, 'no delegation was created');
select ok((select count(*) from audit.audit_event
            where action = 'authz.denied' and actor_user_id = tests.w('u_platform')) >= 5,
  'super-admin attempts are audited');
select ok((select count(*) from audit.audit_event
            where action = 'authz.denied' and actor_user_id = tests.w('u_a1')) >= 5,
  'tenant admin attempts are audited');

select * from finish();
rollback;
