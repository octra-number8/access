-- Competencies (Q38): declared, then verified as a separate act; appointment grants
-- check the appointee's required, verified evidence (Q39).
begin;
\ir _helpers.psql
\ir _phase2.psql
select no_plan();

-- ---- Declaration ----------------------------------------------------------------
select tests.login(tests.w('u_ian'));
select tests.set_w('comp_own', tests.must(api.declare_competency(tests.key(), tests.w('p_ian'), tests.w('ct_ipaf'),
  'IPAF', 'IP-12345', (now() + interval '2 years')::date)));
select is(api.declare_competency(tests.key(), tests.w('p_cara'), tests.w('ct_ipaf'), 'IPAF', 'X', null) ->> 'code',
  'not_subject', 'a person cannot declare a competency for someone else on their own account');
select tests.login(tests.w('u_cara'));
select is(api.declare_competency(tests.key(), tests.w('p_ian'), tests.w('ct_ipaf'), 'IPAF', 'IP-12345',
            (now() + interval '2 years')::date, null, tests.w('org_c')) ->> 'ok',
  'true', 'an organisation administrator can declare one for their person');
select is(api.declare_competency(tests.key(), tests.w('p_op'), tests.w('ct_ipaf'), 'IPAF', 'X', null, null, tests.w('org_c')) ->> 'code',
  'person_not_in_organisation', 'but not for someone who does not work with them');
select tests.logout();

-- ---- Verification is separate, recorded with method and source -----------------
select tests.login(tests.w('u_f'));
select is(api.verify_competency(tests.key(), tests.w('comp_own'), 'issuer_register', 'IPAF online register', true,
            'MEWP 3a/3b', (now() + interval '2 years')::date, 'verified') ->> 'code',
  'no_covering_appointment', 'someone without competency.verify cannot verify');
select tests.login(tests.w('u_ian'));
select is(api.verify_competency(tests.key(), tests.w('comp_own'), 'issuer_register', 'IPAF online register', true,
            'MEWP 3a/3b', null, 'verified') ->> 'code',
  'separation_of_duties', 'the holder cannot verify their own competency');
select tests.login(tests.w('u_r'));
select throws_ok(format($$select api.verify_competency(%L, %L, 'issuer_register', 'IPAF online register', false, 'MEWP 3a/3b', null, 'verified')$$,
                        tests.key(), tests.w('comp_own')),
  '23514', null, 'a competency cannot be verified if the holder does not match');
select tests.logout();

-- ---- Appointments check the appointee's required, verified evidence ------------
select tests.login(tests.w('u_a1'));
select tests.set_w('er_ipaf', tests.must(api.create_evidence_requirement(tests.key(), tests.w('v1'), 'HALL_IPAF',
  'Hall APs hold verified IPAF', 'appointment_type', null, tests.w('t_hall'), 'competency_type', null, tests.w('ct_ipaf'))));
select tests.must(api.publish_evidence_requirement_version(tests.key(), tests.w('er_ipaf'), true, tests.w('p_a1'),
  now() - interval '1 minute', 'Agreed with the technical authority'));
select tests.logout();

select tests.login(tests.w('u_r'));
create temp table t_grant as select api.grant_appointment(tests.key(), tests.w('v1'), tests.w('p_ian'), tests.w('tv_hall'),
  array[tests.w('pc_hw')], jsonb_build_array(jsonb_build_object('area_id', tests.w('hall2'))), now(), now() + interval '30 days',
  null, null, 'Assessment AR-30') as r;
grant select on t_grant to authenticated;
select is((select r ->> 'code' from t_grant), 'evidence_incomplete',
  'an appointment is refused while its required competency is unverified');
select is((select r -> 'evidence' -> 0 ->> 'state' from t_grant), 'not_verified', 'and says why');
select is((select r -> 'evidence' -> 0 ->> 'resolvable_by' from t_grant), 'A competency verifier at this venue',
  'and who can resolve it');

select is(api.verify_competency(tests.key(), tests.w('comp_own'), 'issuer_register', 'IPAF online register, checked 24/10/2026',
            true, 'MEWP 3a/3b', (now() + interval '2 years')::date, 'verified') ->> 'ok',
  'true', 'an appointed verifier records the verification');
select is(api.grant_appointment(tests.key(), tests.w('v1'), tests.w('p_ian'), tests.w('tv_hall'),
            array[tests.w('pc_hw')], jsonb_build_array(jsonb_build_object('area_id', tests.w('hall2'))), now(),
            now() + interval '30 days', null, null, 'Assessment AR-30') ->> 'ok',
  'true', 'with it verified, the appointment can be made');
select tests.logout();

select is((select count(*)::int from core.competency_verification where competency_id = tests.w('comp_own')), 1,
  'verification is its own record');
select is((select method from core.competency_verification where competency_id = tests.w('comp_own')), 'issuer_register',
  'with its method');

-- A verification that expires inside the appointment is flagged but not blocking.
select tests.set_w('u_mo', tests.new_user('mo@a.test'));
select tests.login(tests.w('u_a1'));
select tests.set_w('p_mo', tests.must(api.create_person(tests.key(), tests.w('cust_a'), 'Mo', 'Shortcert')));
select tests.must(api.link_user_account(tests.key(), tests.w('p_mo'), tests.w('u_mo')));
select tests.login(tests.w('u_mo'));
select tests.set_w('comp_mo', tests.must(api.declare_competency(tests.key(), tests.w('p_mo'), tests.w('ct_ipaf'), 'IPAF',
  'IP-999', (now() + interval '10 days')::date)));
select tests.login(tests.w('u_r'));
select tests.must(api.verify_competency(tests.key(), tests.w('comp_mo'), 'original_seen', 'Card inspected at site office',
  true, 'MEWP 3a', (now() + interval '10 days')::date, 'verified'));
select is(api.grant_appointment(tests.key(), tests.w('v1'), tests.w('p_mo'), tests.w('tv_hall'),
            array[tests.w('pc_hw')], jsonb_build_array(jsonb_build_object('area_id', tests.w('hall2'))), now(),
            now() + interval '30 days', null, null, 'AR-31') -> 'evidence' -> 0 ->> 'state',
  'expires_within_window', 'a verification expiring during the appointment is reported, not blocking');
select tests.logout();

select * from finish();
rollback;
