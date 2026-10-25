-- Work packages (Q48-Q54, P4-3 to P4-5): who can start one, what it needs, revisions
-- and material change, visibility, and submission for screening.
begin;
\ir _helpers.psql
\ir _phase4.psql
select no_plan();

-- ---- Starting a job (Q48, Q49, P4-3) --------------------------------------------------------
select tests.set_w('wp1', tests.new_job());
select is((select status from core.work_package where id = tests.w('wp1')), 'draft', 'the performing organisation''s administrator starts a draft');
select is((select reference from core.work_package where id = tests.w('wp1')), 'WP-00001', 'it gets a venue reference');
select is((select change_kind from core.work_package_revision where work_package_id = tests.w('wp1')), 'initial', 'with an initial revision');
select is((select role from core.work_package_party p join core.work_package w on w.current_revision_id = p.revision_id
            where w.id = tests.w('wp1')), 'performing', 'and the performing organisation recorded as a party');

select tests.login(tests.w('u_a1'));
select is(api.create_work_package(tests.key(), tests.w('v1'), tests.w('e1'), tests.w('wt_maint'), tests.wp_input()) ->> 'ok', 'true',
  'a tenant administrator can start one for an engaged organisation');
select tests.login(tests.w('u_h'));
select is(api.create_work_package(tests.key(), tests.w('v1'), tests.w('e1'), tests.w('wt_maint'), tests.wp_input()) ->> 'code',
  'not_organisation_admin', 'someone who neither administers the organisation nor the venue cannot');
select tests.login(tests.w('u_b1'));
select is(api.create_work_package(tests.key(), tests.w('v1'), tests.w('e1'), tests.w('wt_maint'), tests.wp_input()) ->> 'code',
  'not_found', 'another tenant cannot');

select tests.login(tests.w('u_op'));
select is(api.create_work_package(tests.key(), tests.w('v1'), tests.w('e1'), tests.w('wt_maint'),
  tests.wp_input(p_areas => array[]::uuid[])) ->> 'code', 'invalid_content', 'a job needs at least one area');
select ok((api.create_work_package(tests.key(), tests.w('v1'), tests.w('e1'), tests.w('wt_maint'),
  tests.wp_input(p_areas => array[tests.w('site2')])) -> 'problems')::text like '%not a current area at this venue%',
  'and areas at this venue only');
select ok((api.create_work_package(tests.key(), tests.w('v1'), tests.w('e1'), tests.w('wt_maint'),
  tests.wp_input(p_supervisor => tests.w('p_h'))) -> 'problems')::text like '%supervisor must currently work%',
  'the supervisor must work with the performing organisation');
select is(api.create_work_package(tests.key(), tests.w('v1'), tests.w('e1'), tests.w('wt_maint'),
  tests.wp_input(p_parties => jsonb_build_array(jsonb_build_object('organisation_id', tests.w('org_o2'), 'role', 'performing')))) ->> 'code',
  'invalid_content', 'the performing organisation comes from the engagement, never from the applicant');

-- A proposed (unapproved) engagement cannot start work.
select tests.login(tests.w('u_a1'));
select tests.set_w('e2', tests.must(api.create_engagement(tests.key(), tests.w('v1'), tests.w('org_o2'), 'performing_contractor', now() - interval '1 hour')));
select is(api.create_work_package(tests.key(), tests.w('v1'), tests.w('e2'), tests.w('wt_maint'), tests.wp_input()) ->> 'code',
  'engagement_not_active', 'work cannot start for an engagement that has not been approved');

-- A restricted organisation cannot start work (D-010).
select tests.login(tests.w('u_r'));
select tests.set_w('rst', tests.must(api.impose_restriction(tests.key(), tests.w('v1'), 'organisation', tests.w('org_o'), 'Under investigation')));
select tests.login(tests.w('u_op'));
select is(api.create_work_package(tests.key(), tests.w('v1'), tests.w('e1'), tests.w('wt_maint'), tests.wp_input()) ->> 'code',
  'organisation_restricted', 'a restricted organisation cannot start work at the venue');
select tests.login(tests.w('u_r'));
select tests.must(api.lift_restriction(tests.key(), tests.w('rst'), tests.version('core.restriction', tests.w('rst')), 'Resolved'));

-- ---- Who sees it ----------------------------------------------------------------------------
select tests.login(tests.w('u_h'));
select is((select count(*)::int from api.work_package where id = tests.w('wp1')), 0, 'an appointee without screening authority does not see it');
select tests.login(tests.w('u_b1'));
select is((select count(*)::int from api.work_package_revision where work_package_id = tests.w('wp1')), 0, 'nor does another tenant');
select tests.login(tests.w('u_tara'));
select is((select count(*)::int from api.work_package where id = tests.w('wp1')), 1, 'the venue''s screening authority does');
select tests.login(tests.w('u_op'));
select is((select count(*)::int from api.work_package_area a join api.work_package w on w.current_revision_id = a.revision_id
            where w.id = tests.w('wp1')), 1, 'and so does the applicant, with its areas');

-- ---- Revisions (Q53, invariant 6, P4-5) ------------------------------------------------------
select is(api.revise_work_package(tests.key(), tests.w('wp1'), tests.version('core.work_package', tests.w('wp1')),
  tests.wp_input(), 'No change') ->> 'code', 'no_change', 'a revision must change something');
select is(api.revise_work_package(tests.key(), tests.w('wp1'), tests.version('core.work_package', tests.w('wp1')),
  tests.wp_input(p_title => 'Replace sockets on stand 1'), '') ->> 'code', 'invalid_content', 'a change needs a reason');
select is(api.revise_work_package(tests.key(), tests.w('wp1'), tests.version('core.work_package', tests.w('wp1')),
  tests.wp_input(p_title => 'Replace sockets on stand 1'), 'Typo') ->> 'change_kind', 'administrative',
  'changing only the title is administrative');
select is(api.revise_work_package(tests.key(), tests.w('wp1'), tests.version('core.work_package', tests.w('wp1')),
  tests.wp_input(p_areas => array[tests.w('hall1'), tests.w('hall2')], p_title => 'Replace sockets on stand 1'), 'Also hall 2') ->> 'change_kind',
  'material', 'changing the areas is material, whoever makes the change');
select is((select count(*)::int from core.work_package_revision where work_package_id = tests.w('wp1')), 3, 'each change is a new revision');
select throws_ok(format($$select api.revise_work_package(%L, %L, 1, tests.wp_input(p_title => 'Stale'), 'Stale edit')$$, tests.key(), tests.w('wp1')),
  'PT409', null, 'a change based on an out-of-date copy is refused');
select tests.logout();
select throws_ok(format($$update core.work_package_revision set scope = 'Rewritten' where work_package_id = %L$$, tests.w('wp1')),
  null, null, 'a revision can never be edited');

-- ---- Screening answers and submission ---------------------------------------------------------
select tests.login(tests.w('u_op'));
select tests.must(api.save_screening_answers(tests.key(), tests.w('wp1'), '{"hot": ["yes"], "isolate": ["no"], "height": ["no"], "confined": ["no"]}'));
select is(api.submit_work_package(tests.key(), tests.w('wp1'), tests.version('core.work_package', tests.w('wp1'))) ->> 'code',
  'no_screening', 'nothing can be screened before the venue''s technical authority approves the screening');
select tests.approve_screening();
select tests.login(tests.w('u_op'));
select tests.must(api.save_screening_answers(tests.key(), tests.w('wp1'), '{"hot": ["yes"], "isolate": ["no"], "height": ["yes"]}'));
select ok((api.submit_work_package(tests.key(), tests.w('wp1'), tests.version('core.work_package', tests.w('wp1'))) -> 'problems')::text
  like '%Where at height%', 'every question that applies must be answered, including those revealed by earlier answers');
select tests.must(api.save_screening_answers(tests.key(), tests.w('wp1'),
  '{"hot": ["no"], "isolate": ["no"], "height": ["no"], "height-kind": ["roof"], "confined": ["no"]}'));
select ok((api.submit_work_package(tests.key(), tests.w('wp1'), tests.version('core.work_package', tests.w('wp1'))) -> 'problems')::text
  like '%leave it blank%', 'and a question that does not apply must be left blank');
select is(api.save_screening_answers(tests.key(), tests.w('wp1'), tests.no_to_all(), array[tests.w('pc_cs')]) ->> 'code',
  'invalid_content', 'a deferred specialist class cannot be selected directly');

select tests.must(api.save_screening_answers(tests.key(), tests.w('wp1'),
  '{"hot": ["yes"], "isolate": ["no"], "height": ["yes"], "height-kind": ["roof"], "confined": ["yes"]}', array[tests.w('pc_el')]));
create temp table t_k (k text, ver integer);
grant all on t_k to authenticated;
insert into t_k values (tests.key(), tests.version('core.work_package', tests.w('wp1')));
create temp table t_r (name text primary key, v jsonb);
grant all on t_r to authenticated;
insert into t_r select 'submit', api.submit_work_package((select k from t_k), tests.w('wp1'), (select ver from t_k));
select is((select v ->> 'ok' from t_r where name = 'submit'), 'true', 'a complete job is submitted');
select is((select status from api.work_package where id = tests.w('wp1')), 'screening', 'and is in screening');
select is((select v ->> 'replayed' from (select api.submit_work_package((select k from t_k), tests.w('wp1'), (select ver from t_k)) v) x), 'true',
  'submitting the same request again replays it rather than screening twice');

-- What screening found (Q55-Q57).
select is((select matched_rule_keys from api.screening_recommendation where work_package_id = tests.w('wp1') and permit_class_id = tests.w('pc_hw')),
  array['r-hot', 'r-roof'], 'hot works is recommended, citing both rules that matched');
select is((select status from api.screening_recommendation where work_package_id = tests.w('wp1') and permit_class_id = tests.w('pc_hw')),
  'recommended', 'and waits for the applicant');
select is((select status || '/' || applicant_selected from api.screening_recommendation where work_package_id = tests.w('wp1')
            and permit_class_id = tests.w('pc_el')), 'accepted/true',
  'the class the applicant selected directly is recorded as accepted by that choice');
select is((select status from api.external_reference_hold where work_package_id = tests.w('wp1') and permit_class_id = tests.w('pc_cs')),
  'open', 'confined space becomes an external-reference hold, not a permit');
select is((select count(*)::int from api.screening_recommendation where work_package_id = tests.w('wp1') and permit_class_id = tests.w('pc_cs')), 0,
  'and is never offered as an ordinary recommendation');
select is((select set_version_id from api.screening_response where work_package_id = tests.w('wp1')), tests.w('ss1'),
  'the response records which approved screening version was used');
select tests.logout();
select throws_ok(format($$update core.screening_response set answers = '{}' where work_package_id = %L$$, tests.w('wp1')),
  null, null, 'submitted answers can never be changed');
select tests.login(tests.w('u_op'));
select is(api.save_screening_answers(tests.key(), tests.w('wp1'), tests.no_to_all()) ->> 'code', 'not_draft',
  'and the draft answers lock once submitted');
select is(api.submit_work_package(tests.key(), tests.w('wp1'), tests.version('core.work_package', tests.w('wp1'))) ->> 'code', 'not_draft',
  'a job in screening cannot be submitted again');

-- ---- Cancelling -------------------------------------------------------------------------------
select tests.set_w('wp2', tests.new_job());
select tests.login(tests.w('u_op'));
select is(api.cancel_work_package(tests.key(), tests.w('wp2'), tests.version('core.work_package', tests.w('wp2')), '') ->> 'code',
  'invalid_content', 'cancelling needs a reason');
select tests.must(api.cancel_work_package(tests.key(), tests.w('wp2'), tests.version('core.work_package', tests.w('wp2')), 'Not needed'));
select is((select status from api.work_package where id = tests.w('wp2')), 'cancelled', 'a draft can be cancelled');
select is(api.revise_work_package(tests.key(), tests.w('wp2'), tests.version('core.work_package', tests.w('wp2')),
  tests.wp_input(p_title => 'Revived'), 'Try again') ->> 'code', 'not_ready', 'a cancelled job cannot be changed');

select tests.logout();
select * from finish();
rollback;
