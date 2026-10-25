-- Activity screening configuration (Q55-Q57, P4-2): content validation, proposal and
-- approval by the technical authority, immutability, and who may not approve.
begin;
\ir _helpers.psql
\ir _phase4.psql
select no_plan();

-- ---- Content validation (run as the owner: core functions are not callable by clients) ---
select tests.logout();
select ok(cardinality(core.validate_screening_content(tests.w('v1'), tests.screening_content(), true)) = 0,
  'the fixture content is valid');
select ok(array_to_string(core.validate_screening_content(tests.w('v1'),
  jsonb_set(tests.screening_content(), '{rules,0,rationale}', '""'), false), ' ') like '%plain-English reason%',
  'every rule needs a reason the applicant will see');
select ok(array_to_string(core.validate_screening_content(tests.w('v1'),
  jsonb_set(tests.screening_content(), '{rules,0,all,0,answers}', '["maybe"]'), false), ' ') like '%does not offer%',
  'a rule cannot trigger on an answer the question does not offer');
select ok(array_to_string(core.validate_screening_content(tests.w('v1'),
  jsonb_set(tests.screening_content(), '{questions,3,show_if,question}', '"confined"'), false), ' ') like '%earlier question%',
  'a question can depend only on an earlier one');
select ok(array_to_string(core.validate_screening_content(tests.w('v1'),
  jsonb_set(tests.screening_content(), '{rules,0,permit_class_id}', to_jsonb(gen_random_uuid())), false), ' ') like '%permit class at this venue%',
  'a rule must name a permit class at the venue');
-- A rule fires only when all of its conditions hold.
select is((select count(*)::int from core.screening_matches(
  jsonb_set(tests.screening_content(), '{rules,0,all}',
    '[{"question": "hot", "answers": ["yes"]}, {"question": "isolate", "answers": ["yes"]}]'),
  '{"hot": ["yes"], "isolate": ["no"]}') m where m.rule_key = 'r-hot'), 0,
  'a rule with two conditions does not fire when only one holds');
select is((select count(*)::int from core.screening_matches(
  jsonb_set(tests.screening_content(), '{rules,0,all}',
    '[{"question": "hot", "answers": ["yes"]}, {"question": "isolate", "answers": ["yes"]}]'),
  '{"hot": ["yes"], "isolate": ["yes"]}') m where m.rule_key = 'r-hot'), 1,
  'and fires when both hold');
select ok(array_to_string(core.validate_screening_content(tests.w('v1'), '{"questions": [], "rules": []}', true), ' ')
  like '%at least one question%', 'an empty screening cannot be proposed');

select tests.login(tests.w('u_a1'));
select is(api.save_screening_draft(tests.key(), tests.w('ss1'), tests.version('core.screening_set_version', tests.w('ss1')),
  jsonb_set(tests.screening_content(), '{rules,0,rationale}', '""')) ->> 'code', 'invalid_content',
  'an invalid draft is refused with its problems listed');
select throws_ok(format('select api.create_screening_draft(%L, %L)', tests.key(), tests.w('v1')),
  '22023', 'this venue already has a screening version in progress; finish or reject it first',
  'a second draft cannot start while one is in progress');

-- ---- Who may draft and approve -------------------------------------------------------------
select tests.login(tests.w('u_op'));
select is(api.save_screening_draft(tests.key(), tests.w('ss1'), 1, tests.screening_content()) ->> 'code', 'not_tenant_admin',
  'a contractor cannot edit the venue''s screening');
select tests.login(tests.w('u_tara'));
select is(api.decide_screening_version(tests.key(), tests.w('ss1'), tests.version('core.screening_set_version', tests.w('ss1')),
  'approve', 'Too early') ->> 'code', 'not_proposed', 'a draft cannot be approved before it is proposed');

select tests.login(tests.w('u_a1'));
select tests.must(api.propose_screening_version(tests.key(), tests.w('ss1'), tests.version('core.screening_set_version', tests.w('ss1'))));
select is((select status from core.screening_set_version where id = tests.w('ss1')), 'proposed', 'the draft is proposed');
select throws_ok(format($$update core.screening_set_version set content = '{"questions": [], "rules": []}' where id = %L$$, tests.w('ss1')),
  null, null, 'a proposed version cannot be edited');
select is(api.decide_screening_version(tests.key(), tests.w('ss1'), tests.version('core.screening_set_version', tests.w('ss1')),
  'approve', 'Looks fine') ->> 'code', 'separation_of_duties',
  'the tenant administrator who drafted and proposed it cannot approve it');
select tests.login(tests.w('u_a2'));
select is(api.decide_screening_version(tests.key(), tests.w('ss1'), tests.version('core.screening_set_version', tests.w('ss1')),
  'approve', 'Looks fine') ->> 'code', 'no_covering_appointment',
  'another tenant administrator cannot approve screening either (invariant 9)');
select tests.login(tests.w('u_platform'));
select is(api.decide_screening_version(tests.key(), tests.w('ss1'), tests.version('core.screening_set_version', tests.w('ss1')),
  'approve', 'Looks fine') ->> 'ok', 'false', 'nor can a platform administrator');
select tests.login(tests.w('u_h'));
select is(api.decide_screening_version(tests.key(), tests.w('ss1'), tests.version('core.screening_set_version', tests.w('ss1')),
  'approve', 'Looks fine') ->> 'code', 'no_covering_appointment',
  'nor an appointee whose appointment does not include screening approval');
select tests.login(tests.w('u_b1'));
select is(api.decide_screening_version(tests.key(), tests.w('ss1'), tests.version('core.screening_set_version', tests.w('ss1')),
  'approve', 'Looks fine') ->> 'code', 'not_found', 'another tenant cannot see it');

select tests.login(tests.w('u_tara'));
select tests.must(api.decide_screening_version(tests.key(), tests.w('ss1'), tests.version('core.screening_set_version', tests.w('ss1')),
  'approve', 'Validated against the venue procedures'));
select is((select status from core.screening_set_version where id = tests.w('ss1')), 'approved',
  'the technical authority approves it');
select is((select decided_by_person_id from core.screening_set_version where id = tests.w('ss1')), tests.w('p_tara'),
  'with the decision recorded against her');

-- ---- A new version: the author and proposer cannot approve their own ---------------------
select tests.login(tests.w('u_a1'));
select tests.must(api.grant_tenant_admin(tests.key(), tests.w('cust_a'), tests.w('p_tara')));
select tests.login(tests.w('u_tara'));
select tests.set_w('ss2', tests.must(api.create_screening_draft(tests.key(), tests.w('v1'))));
select is((select content from core.screening_set_version where id = tests.w('ss2')),
          (select content from core.screening_set_version where id = tests.w('ss1')),
  'a new draft starts from the previous version''s content');
select tests.must(api.propose_screening_version(tests.key(), tests.w('ss2'), tests.version('core.screening_set_version', tests.w('ss2'))));
select is(api.decide_screening_version(tests.key(), tests.w('ss2'), tests.version('core.screening_set_version', tests.w('ss2')),
  'approve', 'My own work') ->> 'code', 'separation_of_duties',
  'the person who drafted and proposed a version cannot approve it, even holding the authority');
select tests.login(tests.w('u_tess'));
select is(api.decide_screening_version(tests.key(), tests.w('ss2'), tests.version('core.screening_set_version', tests.w('ss2')),
  'approve', 'Second review') ->> 'code', 'no_covering_appointment',
  'an authority whose appointment covers only part of the venue cannot approve venue-wide screening');
select tests.set_w('u_theo', (tests.root_ta('theo@a.test', 'Theo', tests.w('tv_ta'), array[tests.w('pc_hw')], tests.w('site')))[1]);
select tests.login(tests.w('u_theo'));
select tests.must(api.decide_screening_version(tests.key(), tests.w('ss2'), tests.version('core.screening_set_version', tests.w('ss2')),
  'approve', 'Second review'));
select is((select status from core.screening_set_version where id = tests.w('ss1')), 'superseded',
  'approving a new version supersedes the previous one');
select is((select count(*)::int from core.screening_set_version where venue_id = tests.w('v1') and status = 'approved'), 1,
  'only one version is approved at a time');

select tests.logout();
select * from finish();
rollback;
