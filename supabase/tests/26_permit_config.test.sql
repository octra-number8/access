-- Permit class configuration (P5-5), the Work Approval class, starting a job's permits
-- (P5-2) and an authority requiring a class screening missed (P5-12).
begin;
\ir _helpers.psql
\ir _phase4.psql
select tests.approve_screening();
\ir _phase5.psql
select no_plan();

-- ---- Validation --------------------------------------------------------------------------
select tests.logout();
select ok(array_to_string(core.validate_class_config(tests.w('v1'), tests.class_config('[]'), true), ' ') like '%at least one approval step%',
  'a class needs an approval route');
select ok(array_to_string(core.validate_class_config(tests.w('v1'),
  tests.class_config('[{"key": "a", "name": "A", "kind": "review", "group": 1}, {"key": "b", "name": "B", "kind": "review", "group": 3}]'), false), ' ')
  like '%without gaps%', 'step groups run 1, 2, 3 without gaps');
select ok(array_to_string(core.validate_class_config(tests.w('v1'),
  tests.class_config('[{"key": "o", "name": "Occupier", "kind": "occupier", "group": 1}]'), true), ' ')
  like '%review step that always applies%', 'and at least one review step that always applies');
select ok(array_to_string(core.validate_class_config(tests.w('v1'),
  tests.class_config('[{"key": "a", "name": "A", "kind": "review", "group": 1}]') - 'physical_controls', true), ' ')
  like '%physical controls%', 'which physical controls the class needs must be chosen (no default)');
select ok(array_to_string(core.validate_class_config(tests.w('v1'),
  jsonb_set(tests.class_config('[{"key": "a", "name": "A", "kind": "review", "group": 1}]'), '{acceptance_declaration}', '[]'), true), ' ')
  like '%supervisor makes on acceptance%', 'and so must the acceptance declaration');

-- ---- The Work Approval class and configuration authority -----------------------------------
select tests.login(tests.w('u_a1'));
select throws_ok(format('select api.create_work_approval_class(%L, %L, %L, %L)', tests.key(), tests.w('v1'), 'WA2', 'Another'),
  '22023', 'this venue already has a Work Approval class', 'a venue has one Work Approval class');
select throws_ok(format('select api.create_class_draft(%L, %L)', tests.key(), tests.w('pc_cs')),
  '22023', 'a class handled by external reference is not requested as a permit', 'deferred specialist classes are not configured as permits');
select tests.set_w('el1', tests.must(api.create_class_draft(tests.key(), tests.w('pc_el'))));
select tests.must(api.save_class_draft(tests.key(), tests.w('el1'), tests.version('core.permit_class_version', tests.w('el1')),
  tests.class_config('[{"key": "el-review", "name": "Isolation review", "kind": "review", "group": 1}]')));
select tests.must(api.propose_class_version(tests.key(), tests.w('el1'), tests.version('core.permit_class_version', tests.w('el1'))));
select is(api.decide_class_version(tests.key(), tests.w('el1'), tests.version('core.permit_class_version', tests.w('el1')), 'approve', 'Mine')
  ->> 'code', 'separation_of_duties', 'the tenant administrator who proposed it cannot approve it');
select tests.login(tests.w('u_a2'));
select is(api.decide_class_version(tests.key(), tests.w('el1'), tests.version('core.permit_class_version', tests.w('el1')), 'approve', 'Fine')
  ->> 'code', 'no_covering_appointment', 'nor can any tenant administrator (invariant 9)');
select tests.login(tests.w('u_rex'));
select is(api.decide_class_version(tests.key(), tests.w('el1'), tests.version('core.permit_class_version', tests.w('el1')), 'approve', 'Fine')
  ->> 'code', 'no_covering_appointment', 'nor an authority without that class');
select tests.login(tests.w('u_pam'));
select tests.must(api.decide_class_version(tests.key(), tests.w('el1'), tests.version('core.permit_class_version', tests.w('el1')), 'approve', 'Validated'));
select is((select status from core.permit_class_version where id = tests.w('el1')), 'approved', 'an authority covering the class approves it');
select tests.logout();
select throws_ok(format($$update core.permit_class_version set content = '{}' where id = %L$$, tests.w('el1')), null, null,
  'an approved configuration cannot be edited');

-- ---- Starting permits (P5-2) -------------------------------------------------------------------
select tests.set_w('wp', tests.routed_job());
select tests.login(tests.w('u_h'));
select is(api.start_permits(tests.key(), tests.w('wp')) ->> 'code', 'not_organisation_admin', 'only the job''s organisation or the venue can start its permits');
select tests.login(tests.w('u_op'));
select tests.must(api.start_permits(tests.key(), tests.w('wp')));
select is((select string_agg(kind || ':' || status, ',' order by kind desc) from core.permit where work_package_id = tests.w('wp')),
  'work_approval:draft,child:draft', 'a Work Approval and one child permit for the class the job needs');
select is((select parent_permit_id from core.permit where id = tests.permit_of(tests.w('wp'), tests.w('pc_wah'))),
  tests.permit_of(tests.w('wp'), tests.w('pc_wa')), 'linked to the Work Approval');
select is((select permit_class_id from core.permit where id = tests.permit_of(tests.w('wp'), tests.w('pc_wa'))), tests.w('pc_wa'),
  'which uses the venue''s Work Approval class');
select is((api.start_permits(tests.key(), tests.w('wp')) ->> 'created')::int, 0, 'starting again creates nothing new');

select tests.set_w('wp_surv', tests.new_job(tests.wp_input(p_title => 'Survey')));
select tests.must(tests.answer_and_submit(tests.w('wp_surv'), tests.no_to_all()));
select tests.login(tests.w('u_op'));
select is(api.start_permits(tests.key(), tests.w('wp_surv')) ->> 'code', 'not_routed', 'a job still being settled has no permits');

-- A class without an approved configuration blocks starting, by name.
select tests.login(tests.w('u_a1'));
select tests.set_w('pc_tw', tests.must(api.create_permit_class(tests.key(), tests.w('v1'), 'TW', 'Temporary works')));
select tests.set_w('wp_tw', tests.new_job(tests.wp_input(p_title => 'Temporary works')));
select tests.must(tests.answer_and_submit(tests.w('wp_tw'), tests.no_to_all(), array[tests.w('pc_tw')]));
select tests.login(tests.w('u_op'));
select is(api.start_permits(tests.key(), tests.w('wp_tw')) ->> 'reason',
  'Some permits this job needs have no approved configuration at this venue yet: Temporary works.',
  'a class with no approved configuration blocks starting, and is named');
select tests.login(tests.w('u_a1'));
select tests.set_w('wah2', tests.must(api.create_class_draft(tests.key(), tests.w('pc_wah'))));
select tests.must(api.propose_class_version(tests.key(), tests.w('wah2'), tests.version('core.permit_class_version', tests.w('wah2'))));
select tests.login(tests.w('u_pam'));
select tests.must(api.decide_class_version(tests.key(), tests.w('wah2'), tests.version('core.permit_class_version', tests.w('wah2')), 'approve', 'v2'));
select is((select status from core.permit_class_version where id = tests.w('cv_wah')), 'superseded', 'a new approved configuration supersedes the old');

-- ---- Requiring a class screening missed (P5-12) -------------------------------------------------
select tests.login(tests.w('u_op'));
select is(api.require_class(tests.key(), tests.w('wp'), tests.w('pc_hw'), 'Grinding brackets') ->> 'ok', 'false',
  'the applicant cannot add a requirement by decision');
select tests.login(tests.w('u_a1'));
select is(api.require_class(tests.key(), tests.w('wp'), tests.w('pc_hw'), 'Grinding brackets') ->> 'code', 'no_covering_appointment',
  'nor can a tenant administrator');
select tests.login(tests.w('u_pam'));
select is(api.require_class(tests.key(), tests.w('wp'), tests.w('pc_wah'), 'Again') ->> 'code', 'already_required', 'a class already needed is refused');
select is(api.require_class(tests.key(), tests.w('wp'), tests.w('pc_hw'), '') ->> 'code', 'invalid_content', 'a reason is needed');
select tests.must(api.require_class(tests.key(), tests.w('wp'), tests.w('pc_hw'), 'Brackets are cut with a grinder: hot works apply.'));
select is(tests.status_of(tests.permit_of(tests.w('wp'), tests.w('pc_hw'))), 'draft',
  'the authority adds the class, and because permits are started its draft joins them');
select is((select decider_person_id from core.class_requirement where work_package_id = tests.w('wp')), tests.w('p_pam'),
  'recorded against the authority who required it');

select tests.logout();
select * from finish();
rollback;
