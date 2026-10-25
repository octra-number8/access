-- Screening outcomes (Q58, Q59, P4-6, P4-7, invariants 3, 6, 9, 10): accepting and
-- challenging recommendations, who decides, "no permit required", external-reference
-- holds, routing, and what a material change does to all of it.
begin;
\ir _helpers.psql
\ir _phase4.psql
select no_plan();
select tests.approve_screening();

create temp table t_r (name text primary key, v jsonb);
grant all on t_r to authenticated;
create function tests.rec(p_wp uuid, p_class uuid) returns uuid language sql stable security definer as $$
  select id from core.screening_recommendation where work_package_id = p_wp and permit_class_id = p_class and status <> 'superseded' $$;
grant execute on function tests.rec(uuid, uuid) to authenticated;

-- ---- A: hot works and isolation recommended in Hall 1 -------------------------------------
select tests.set_w('wa', tests.new_job());
select tests.must(tests.answer_and_submit(tests.w('wa'), '{"hot": ["yes"], "isolate": ["yes"], "height": ["no"], "confined": ["no"]}'));
select is((select count(*)::int from api.screening_recommendation where work_package_id = tests.w('wa') and status = 'recommended'), 2,
  'two classes are recommended');

select tests.login(tests.w('u_h'));
select is(api.accept_recommendation(tests.key(), tests.rec(tests.w('wa'), tests.w('pc_el')), 1) ->> 'code', 'not_organisation_admin',
  'only the job''s own organisation can accept a recommendation');
select tests.login(tests.w('u_op'));
select throws_ok(format('select api.accept_recommendation(%L, %L, 99)', tests.key(), tests.rec(tests.w('wa'), tests.w('pc_el'))),
  'PT409', null, 'accepting against an out-of-date copy is refused');
select is(api.challenge_recommendation(tests.key(), tests.rec(tests.w('wa'), tests.w('pc_hw')), 1, '') ->> 'code', 'invalid_content',
  'a challenge needs a reason');
select is(api.challenge_recommendation(tests.key(), tests.rec(tests.w('wa'), tests.w('pc_hw')), 1, 'Cold cutting only',
  array[gen_random_uuid()]) ->> 'code', 'invalid_content', 'and can cite only the organisation''s own documents');
select tests.must(api.challenge_recommendation(tests.key(), tests.rec(tests.w('wa'), tests.w('pc_hw')),
  tests.version('core.screening_recommendation', tests.rec(tests.w('wa'), tests.w('pc_hw'))),
  'We use cold cutting and crimped connections only; no heat is produced.'));
select is(api.accept_recommendation(tests.key(), tests.rec(tests.w('wa'), tests.w('pc_el')),
  tests.version('core.screening_recommendation', tests.rec(tests.w('wa'), tests.w('pc_el')))) ->> 'routed', 'false',
  'accepting isolation does not route the job while the hot works challenge is open');
select is((select status from api.work_package where id = tests.w('wa')), 'screening',
  'while a challenge is open the job stays unresolved (invariant 10)');
select is(api.accept_recommendation(tests.key(), tests.rec(tests.w('wa'), tests.w('pc_hw')),
  tests.version('core.screening_recommendation', tests.rec(tests.w('wa'), tests.w('pc_hw')))) ->> 'code', 'not_open',
  'a challenged recommendation cannot then be quietly accepted');

-- Who may decide (Q59, invariants 3 and 9).
select tests.login(tests.w('u_op'));
select is(api.decide_challenge(tests.key(), tests.rec(tests.w('wa'), tests.w('pc_hw')), 2, 'not_required', 'Agreed',
  'No hot works permit for cold cutting at stand 1') ->> 'ok', 'false', 'the challenger cannot decide their own challenge');
select tests.login(tests.w('u_a2'));
select is(api.decide_challenge(tests.key(), tests.rec(tests.w('wa'), tests.w('pc_hw')), 2, 'not_required', 'Agreed',
  'No hot works permit for cold cutting at stand 1') ->> 'code', 'no_covering_appointment',
  'a tenant administrator cannot decide (invariant 9)');
select tests.login(tests.w('u_platform'));
select is(api.decide_challenge(tests.key(), tests.rec(tests.w('wa'), tests.w('pc_hw')), 2, 'not_required', 'Agreed',
  'No hot works permit for cold cutting at stand 1') ->> 'ok', 'false', 'nor can a platform administrator');
select tests.login(tests.w('u_b1'));
select is(api.decide_challenge(tests.key(), tests.rec(tests.w('wa'), tests.w('pc_hw')), 2, 'not_required', 'Agreed',
  'No hot works permit for cold cutting at stand 1') ->> 'code', 'not_found', 'nor another tenant');
select tests.login(tests.w('u_tara'));
select is(api.decide_challenge(tests.key(), tests.rec(tests.w('wa'), tests.w('pc_hw')), 2, 'not_required', 'Agreed',
  'Hot works approved as safe') ->> 'code', 'invalid_content',
  '"no permit required" wording may not say approved or safe');
insert into t_r select 'a-decide', api.decide_challenge(tests.key(), tests.rec(tests.w('wa'), tests.w('pc_hw')),
  tests.version('core.screening_recommendation', tests.rec(tests.w('wa'), tests.w('pc_hw'))), 'not_required',
  'Method statement shows cold cutting only.', 'No hot works permit for cold cutting of sockets at stand 1, Hall 1, on the planned dates');
select is((select v ->> 'routed' from t_r where name = 'a-decide'), 'true',
  'once every recommendation is settled the job is routed');
select is((select status from api.work_package where id = tests.w('wa')), 'routed', 'and recorded as routed');
select is((select count(*)::int from api.no_permit_required_decision where work_package_id = tests.w('wa')
            and recommendation_id is not null and decider_person_id = tests.w('p_tara')), 1,
  'the "no permit required" decision is recorded against the deciding authority');
select is((select outcome from api.challenge_decision), 'not_required', 'with the challenge outcome');

-- ---- B: a job in two halls needs an authority covering both --------------------------------
select tests.set_w('wb', tests.new_job(tests.wp_input(p_areas => array[tests.w('hall1'), tests.w('hall2')], p_title => 'Two halls')));
select tests.must(tests.answer_and_submit(tests.w('wb'), '{"hot": ["yes"], "isolate": ["no"], "height": ["no"], "confined": ["no"]}'));
select tests.login(tests.w('u_op'));
select tests.must(api.challenge_recommendation(tests.key(), tests.rec(tests.w('wb'), tests.w('pc_hw')), 1, 'Disputed'));
select tests.login(tests.w('u_tess'));
select is(api.decide_challenge(tests.key(), tests.rec(tests.w('wb'), tests.w('pc_hw')), 2, 'upheld', 'Needed') ->> 'code',
  'no_covering_appointment', 'an authority covering only Hall 1 cannot decide for a job that also covers Hall 2');
select tests.login(tests.w('u_tara'));
select tests.must(api.decide_challenge(tests.key(), tests.rec(tests.w('wb'), tests.w('pc_hw')), 2, 'upheld',
  'Grinding produces sparks in both halls.'));
select is((select status from api.work_package where id = tests.w('wb')), 'routed', 'an upheld recommendation means the permit is required, and the job is routed');

-- Tess can decide within her scope and class, and not outside her class.
select tests.set_w('wc', tests.new_job(tests.wp_input(p_title => 'Hall 1 only')));
select tests.must(tests.answer_and_submit(tests.w('wc'), '{"hot": ["yes"], "isolate": ["yes"], "height": ["no"], "confined": ["no"]}'));
select tests.login(tests.w('u_op'));
select tests.must(api.challenge_recommendation(tests.key(), tests.rec(tests.w('wc'), tests.w('pc_el')), 1, 'Disputed'));
select tests.must(api.challenge_recommendation(tests.key(), tests.rec(tests.w('wc'), tests.w('pc_hw')), 1, 'Disputed'));
select tests.login(tests.w('u_tess'));
select is(api.decide_challenge(tests.key(), tests.rec(tests.w('wc'), tests.w('pc_el')), 2, 'upheld', 'Needed') ->> 'code',
  'no_covering_appointment', 'an authority cannot decide for a permit class her appointment does not cover');
select is(api.decide_challenge(tests.key(), tests.rec(tests.w('wc'), tests.w('pc_hw')), 2, 'upheld', 'Needed') ->> 'ok', 'true',
  'but can within her class and area');
select tests.login(tests.w('u_tara'));
select is(api.record_no_permit_required(tests.key(), tests.w('wc'), tests.version('core.work_package', tests.w('wc')),
  'No permit required for anything at stand 1', 'Override') ->> 'code', 'has_recommendations',
  'a whole-job "no permit required" cannot override recommendations still being settled');

-- Someone connected with the job cannot decide, even holding the authority (invariant 3).
select tests.set_w('wd', tests.new_job(jsonb_set(tests.wp_input(p_title => 'Contact is Tara'), '{contact_person_id}', to_jsonb(tests.w('p_tara')))));
select tests.must(tests.answer_and_submit(tests.w('wd'), '{"hot": ["yes"], "isolate": ["no"], "height": ["no"], "confined": ["no"]}'));
select tests.login(tests.w('u_op'));
select tests.must(api.challenge_recommendation(tests.key(), tests.rec(tests.w('wd'), tests.w('pc_hw')), 1, 'Disputed'));
select tests.login(tests.w('u_tara'));
select is(api.decide_challenge(tests.key(), tests.rec(tests.w('wd'), tests.w('pc_hw')), 2, 'upheld', 'Needed') ->> 'code',
  'separation_of_duties', 'the job''s named contact cannot decide on it, even holding the authority');

-- ---- E: nothing recommended is not a decision (P4-6) ---------------------------------------
select tests.set_w('we', tests.new_job(tests.wp_input(p_title => 'Survey')));
select is((tests.answer_and_submit(tests.w('we'), tests.no_to_all())) ->> 'routed', 'false',
  'a job with nothing recommended is not routed on submission');
select is((select status from api.work_package where id = tests.w('we')), 'screening', 'it waits for a decision');
select tests.login(tests.w('u_tara'));
select is(api.record_no_permit_required(tests.key(), tests.w('wa'), 1, 'No permit for anything', 'Because') ->> 'code',
  'not_ready', 'a whole-job decision is only for a job in screening');
select is(api.record_no_permit_required(tests.key(), tests.w('wb'), tests.version('core.work_package', tests.w('wb')),
  'No permit for anything', 'Because') ->> 'code', 'not_ready', 'and never overrides what screening recommended');
select tests.login(tests.w('u_a1'));
select is(api.record_no_permit_required(tests.key(), tests.w('we'), tests.version('core.work_package', tests.w('we')),
  'No permit required for a visual survey of Hall 1', 'Visual only') ->> 'code', 'no_covering_appointment',
  'a tenant administrator cannot record "no permit required"');
select tests.login(tests.w('u_tara'));
select tests.must(api.record_no_permit_required(tests.key(), tests.w('we'), tests.version('core.work_package', tests.w('we')),
  'No permit required for a visual survey of Hall 1 on the planned dates', 'Visual inspection only; no tools, no access equipment.'));
select is((select status from api.work_package where id = tests.w('we')), 'routed', 'the authority''s decision routes it');

-- ---- F: deferred specialist work (P4-7) ---------------------------------------------------------
select tests.set_w('wf', tests.new_job(tests.wp_input(p_title => 'Tank inspection')));
select tests.must(tests.answer_and_submit(tests.w('wf'), '{"hot": ["no"], "isolate": ["no"], "height": ["no"], "confined": ["yes"]}'));
select tests.set_w('hold', (select id from core.external_reference_hold where work_package_id = tests.w('wf')));
select tests.login(tests.w('u_tara'));
select is(api.decide_external_reference(tests.key(), tests.w('hold'), 1, 'accepted', 'Looks fine') ->> 'code', 'evidence_incomplete',
  'a hold cannot be accepted without external evidence');
select tests.login(tests.w('u_op'));
select tests.must(api.add_external_evidence(tests.key(), tests.w('hold'), 'J. Smith CEng', 'Specialist Entry Ltd', 'SE-221',
  'Entry to tank T1 under specialist safe system of work', current_date, 'Gas monitoring throughout'));
select tests.login(tests.w('u_tess'));
select is(api.decide_external_reference(tests.key(), tests.w('hold'), 1, 'accepted', 'Fine') ->> 'code', 'no_covering_appointment',
  'only an authority covering that specialist class can accept the evidence');
select tests.login(tests.w('u_tara'));
select is(api.decide_external_reference(tests.key(), tests.w('hold'), 1, 'accepted',
  'Evidence reviewed against the specialist procedure.') ->> 'routed', 'false',
  'an accepted hold alone does not route the job: no permit class was decided either way');
select tests.must(api.record_no_permit_required(tests.key(), tests.w('wf'), tests.version('core.work_package', tests.w('wf')),
  'No venue permit class required for tank T1 entry beyond the accepted specialist arrangement', 'Specialist arrangement covers it.'));
select is((select status from api.work_package where id = tests.w('wf')), 'routed', 'with that recorded, the job is routed');

-- ---- G: change after routing (invariant 6, P4-5) --------------------------------------------------
select tests.login(tests.w('u_op'));
select is(api.revise_work_package(tests.key(), tests.w('wb'), tests.version('core.work_package', tests.w('wb')),
  tests.wp_input(p_areas => array[tests.w('hall1'), tests.w('hall2')], p_title => 'Two halls, corrected'), 'Title typo') ->> 'change_kind',
  'administrative', 'an administrative correction to a routed job');
select is((select status from api.work_package where id = tests.w('wb')), 'routed', 'keeps it routed');
insert into t_r select 'wa-before', jsonb_build_object(
  'npr', (select jsonb_agg(to_jsonb(n) order by n.id) from core.no_permit_required_decision n where n.work_package_id = tests.w('wa')),
  'response', (select to_jsonb(x) from core.screening_response x where x.work_package_id = tests.w('wa')));
select is(api.revise_work_package(tests.key(), tests.w('wa'), tests.version('core.work_package', tests.w('wa')),
  tests.wp_input(p_areas => array[tests.w('hall1'), tests.w('plant1')]), 'Also the plant room') ->> 'change_kind',
  'material', 'adding an area to a routed job is material');
select is((select status from api.work_package where id = tests.w('wa')), 'draft', 'and returns it to draft for screening again');
select is((select count(*)::int from api.screening_recommendation where work_package_id = tests.w('wa') and status <> 'superseded'), 0,
  'its recommendations are superseded');
select tests.logout();
select is(jsonb_build_object(
  'npr', (select jsonb_agg(to_jsonb(n) order by n.id) from core.no_permit_required_decision n where n.work_package_id = tests.w('wa')),
  'response', (select to_jsonb(x) from core.screening_response x where x.work_package_id = tests.w('wa'))),
  (select v from t_r where name = 'wa-before'),
  'while the earlier answers and decisions stay exactly as they were');
select tests.login(tests.w('u_op'));
select is((tests.answer_and_submit(tests.w('wa'), '{"hot": ["no"], "isolate": ["yes"], "height": ["no"], "confined": ["no"]}')) ->> 'ok', 'true',
  'the changed job is screened again from fresh answers');
select is((select count(*)::int from api.screening_recommendation where work_package_id = tests.w('wa') and status = 'recommended'), 1,
  'and its new outcome stands on its own');

-- ---- Isolation: every new view, as another tenant and as an unrelated person ---------------
select tests.login(tests.w('u_b1'));
select is((select count(*)::int from (
  select id from api.work_package union all select id from api.work_package_revision
  union all select id from api.work_package_area union all select id from api.work_package_system
  union all select id from api.work_package_party union all select id from api.screening_draft
  union all select id from api.screening_response union all select id from api.screening_recommendation
  union all select id from api.screening_challenge union all select id from api.challenge_decision
  union all select id from api.no_permit_required_decision union all select id from api.external_reference_hold
  union all select id from api.external_reference_evidence union all select id from api.external_reference_decision
  union all select id from api.screening_set_version union all select id from api.work_type) x), 0,
  'another tenant sees nothing of any job, screening or configuration');
select tests.login(tests.w('u_h'));
select is((select count(*)::int from (
  select id from api.work_package union all select id from api.work_package_revision
  union all select id from api.screening_response union all select id from api.screening_recommendation
  union all select id from api.screening_challenge union all select id from api.no_permit_required_decision
  union all select id from api.external_reference_hold union all select id from api.external_reference_evidence) x), 0,
  'someone at the same venue with no part in the jobs and no screening authority sees none of them');
select tests.login(tests.w('u_op'));
select is((select count(*)::int from api.screening_set_version where status = 'approved'), 1,
  'the applicant can read the approved screening questions and rules (transparent screening)');
select is((select count(*)::int from api.work_package where performing_organisation_id <> tests.w('org_o')), 0,
  'and sees only jobs their organisation is party to');

select tests.logout();
select * from finish();
rollback;
