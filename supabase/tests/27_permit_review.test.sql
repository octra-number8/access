-- Permit requests through their approval routes (Q61-Q83, P5-4, P5-7): preparing and
-- submitting, who decides each step, groups in order, conditions, information requests
-- and resubmission, refusal, withdrawal, the Work Approval's dependency on its children,
-- and what a material change to the job does.
begin;
\ir _helpers.psql
\ir _phase4.psql
select tests.approve_screening();
\ir _phase5.psql
select no_plan();

create temp table t_r (name text primary key, v jsonb);
grant all on t_r to authenticated;

select tests.set_w('wp', tests.routed_job());
select tests.login(tests.w('u_op'));
select tests.must(api.start_permits(tests.key(), tests.w('wp')));
select tests.set_w('wa', tests.permit_of(tests.w('wp'), tests.w('pc_wa')));
select tests.set_w('wah', tests.permit_of(tests.w('wp'), tests.w('pc_wah')));

-- ---- Preparing and submitting (Q61-Q68) -----------------------------------------------------
select ok((api.submit_permit(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah'))) -> 'problems')::text
  like '%How will people reach the work%', 'a permit cannot be submitted until its class questions are answered');
select is(api.save_permit_draft(tests.key(), tests.w('wah'), '{"access": ["mewp"]}', now() - interval '30 days', now() + interval '8 days') ->> 'ok', 'true',
  'the draft saves');
select ok((api.submit_permit(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah'))) -> 'problems')::text
  like '%within the job''s planned dates%', 'and its window must sit within the job''s dates');
select tests.must(api.save_permit_draft(tests.key(), tests.w('wah'), '{"access": ["mewp"]}',
  date_trunc('day', now()) + interval '7 days', date_trunc('day', now()) + interval '8 days'));
select tests.login(tests.w('u_h'));
select is(api.submit_permit(tests.key(), tests.w('wah'), 1) ->> 'code', 'not_organisation_admin', 'only the job''s organisation or the venue submits');
select tests.login(tests.w('u_op'));
select throws_ok(format('select api.submit_permit(%L, %L, 99)', tests.key(), tests.w('wah')), 'PT409', null,
  'submitting against an out-of-date copy is refused');
insert into t_r select 'submit', api.submit_permit(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')));
select is((select v ->> 'ok' from t_r where name = 'submit'), 'true', 'a complete request is submitted');
select is(tests.status_of(tests.w('wah')), 'submitted', 'and is recorded as submitted');
select is((select (v ->> 'steps')::int from t_r where name = 'submit'), 3, 'with the class''s three steps');
select is((select array_agg(area_ids[1]) from core.permit_step where id = tests.step_of(tests.w('wah'), 'occupier')),
  array[tests.w('hall2')], 'the occupier step covers only the area that occupier holds (P5-6)');
select is((select party_organisation_id from core.permit_step where id = tests.step_of(tests.w('wah'), 'occupier')),
  tests.w('org_o2'), 'and names the occupier');
select is((select declared_by_person_id from core.permit_version where permit_id = tests.w('wah')), tests.w('p_op'),
  'the declaration is recorded against the person who made it (Q68)');
select tests.logout();
select throws_ok(format($$update core.permit_version set answers = '{}' where permit_id = %L$$, tests.w('wah')), null, null,
  'a submitted version can never be edited');
select tests.login(tests.w('u_op'));
select is(api.save_permit_draft(tests.key(), tests.w('wah'), '{"access": ["scaffold"]}', now(), now() + interval '1 day') ->> 'code',
  'not_draft', 'nor can its draft change while it is in review');

-- ---- Who decides (Q76-Q79, invariants 1, 3, 9) ------------------------------------------------
select is(api.decide_step(tests.key(), tests.step_of(tests.w('wah'), 'rams'), 'no_further_comments', 'Mine',
  'RAMS reviewed for lamp replacement in Halls 1 and 2') ->> 'ok', 'false', 'the applicant cannot decide a step');
select tests.login(tests.w('u_a1'));
select is(api.decide_step(tests.key(), tests.step_of(tests.w('wah'), 'rams'), 'no_further_comments', 'Fine',
  'RAMS reviewed for lamp replacement in Halls 1 and 2') ->> 'code', 'no_covering_appointment', 'nor a tenant administrator (invariant 9)');
select tests.login(tests.w('u_platform'));
select is(api.decide_step(tests.key(), tests.step_of(tests.w('wah'), 'rams'), 'no_further_comments', 'Fine',
  'RAMS reviewed for lamp replacement in Halls 1 and 2') ->> 'ok', 'false', 'nor a platform administrator');
select tests.login(tests.w('u_rex'));
select is(api.decide_step(tests.key(), tests.step_of(tests.w('wah'), 'rams'), 'no_further_comments', 'Fine',
  'RAMS reviewed for lamp replacement in Halls 1 and 2') ->> 'code', 'no_covering_appointment',
  'nor an authority covering Hall 1 only, for a job in Halls 1 and 2');
select tests.login(tests.w('u_olga'));
select is(api.decide_step(tests.key(), tests.step_of(tests.w('wah'), 'rams'), 'no_further_comments', 'Fine',
  'RAMS reviewed for lamp replacement in Halls 1 and 2') ->> 'code', 'no_covering_appointment',
  'nor an occupier representative, on a review step');
select tests.login(tests.w('u_pam'));
select is(api.decide_step(tests.key(), tests.step_of(tests.w('wah'), 'final'), 'no_further_comments', 'Early',
  'Final review for lamp replacement') ->> 'code', 'step_not_open', 'a group 2 step waits for group 1');
select is(api.decide_step(tests.key(), tests.step_of(tests.w('wah'), 'rams'), 'no_further_comments', 'Fine',
  'RAMS approved for lamp replacement') ->> 'code', 'invalid_content', 'decision wording may not say "approved" (Q72)');
select is(api.decide_step(tests.key(), tests.step_of(tests.w('wah'), 'rams'), 'conditions', 'Fine',
  'RAMS reviewed for lamp replacement in Halls 1 and 2', '[]') ->> 'code', 'invalid_content', 'conditions must be listed');
select tests.must(api.decide_step(tests.key(), tests.step_of(tests.w('wah'), 'rams'), 'conditions', 'MEWP route agreed',
  'RAMS reviewed for lamp replacement in Halls 1 and 2',
  '[{"text": "Exclusion zone under the MEWP", "acknowledge": true}]'));
select is(tests.status_of(tests.w('wah')), 'under_review', 'the first decision puts the request under review');
select tests.login(tests.w('u_olga'));
select tests.must(api.decide_step(tests.key(), tests.step_of(tests.w('wah'), 'occupier'), 'no_further_comments', 'No impact on our stand',
  'Occupier agrees to lamp replacement in Hall 2'));
select is(tests.status_of(tests.w('wah')), 'under_review', 'group 1 settled; the final step is still open');

-- ---- Information request and resubmission (Q70-Q71, P5-7) --------------------------------------
select tests.login(tests.w('u_pam'));
select is(api.decide_step(tests.key(), tests.step_of(tests.w('wah'), 'final'), 'more_information', 'Need the MEWP') ->> 'code',
  'invalid_content', 'asking for information needs a message and items');
select tests.must(api.decide_step(tests.key(), tests.step_of(tests.w('wah'), 'final'), 'more_information', 'Need the MEWP details',
  p_rfi => '{"message": "Please confirm the MEWP and its operator.", "items": [{"about": "access", "text": "MEWP make and model"}, {"about": "job", "text": "Operator name and IPAF card"}]}'));
select is(tests.status_of(tests.w('wah')), 'more_information_required', 'the request needs more information');
select is(api.decide_step(tests.key(), tests.step_of(tests.w('wah'), 'final'), 'no_further_comments', 'Changed my mind',
  'Final review for lamp replacement') ->> 'code', 'step_not_open', 'no step can be decided while the applicant is answering');
select tests.login(tests.w('u_op'));
select tests.must(api.save_permit_draft(tests.key(), tests.w('wah'), '{"access": ["mewp"]}',
  date_trunc('day', now()) + interval '7 days', date_trunc('day', now()) + interval '8 days'));
select is(api.respond_to_rfi(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), '["Genie Z-45"]') ->> 'code',
  'not_ready', 'every item must be answered');
select tests.must(api.respond_to_rfi(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')),
  '["Genie Z-45 boom", "Oli Operative, IPAF 3b"]'));
select is((select version_no from core.permit_version where id = (select current_version_id from core.permit where id = tests.w('wah'))), 2,
  'the response is a new version');
select is(tests.status_of(tests.w('wah')), 'under_review', 'back under review');
select is((select count(*)::int from core.step_decision d join core.permit_step s on s.id = d.permit_step_id
            join core.permit p on p.current_version_id = s.permit_version_id where p.id = tests.w('wah')), 0,
  'and every step decides again on the new version (P5-7)');
select is((select count(*)::int from core.step_decision d join core.permit_step s on s.id = d.permit_step_id
            join core.permit_version v on v.id = s.permit_version_id where v.permit_id = tests.w('wah') and v.version_no = 1), 3,
  'while the first version keeps its decisions');

select tests.login(tests.w('u_pam'));
select tests.must(api.decide_step(tests.key(), tests.step_of(tests.w('wah'), 'rams'), 'no_further_comments', 'Unchanged', 'RAMS reviewed for lamp replacement in Halls 1 and 2'));
select tests.login(tests.w('u_olga'));
select tests.must(api.decide_step(tests.key(), tests.step_of(tests.w('wah'), 'occupier'), 'no_further_comments', 'Unchanged', 'Occupier agrees to lamp replacement in Hall 2'));
select tests.login(tests.w('u_pam'));
select tests.must(api.decide_step(tests.key(), tests.step_of(tests.w('wah'), 'final'), 'no_further_comments', 'MEWP confirmed', 'Final review for lamp replacement'));
select is(tests.status_of(tests.w('wah')), 'approved_for_issue', 'with every step settled, the permit is approved for issue');

-- ---- Withdrawal before issue (Q83) ----------------------------------------------------------------
select tests.set_w('u_pete', (tests.root_ta('pete@a.test', 'Pete', tests.w('tv_pa'), array[tests.w('pc_wa'), tests.w('pc_wah')], tests.w('site')))[1]);
select tests.login(tests.w('u_pete'));
select is(api.reopen_step(tests.key(), tests.step_of(tests.w('wah'), 'final'), 'Not mine') ->> 'code', 'not_decider',
  'only the person who made a decision can withdraw it, even another authority covering the step');
select tests.login(tests.w('u_pam'));
select tests.must(api.reopen_step(tests.key(), tests.step_of(tests.w('wah'), 'final'), 'Weather forecast changed'));
select is(tests.status_of(tests.w('wah')), 'under_review', 'withdrawing a decision returns the permit to review');
select tests.must(api.decide_step(tests.key(), tests.step_of(tests.w('wah'), 'final'), 'no_further_comments', 'Forecast fine', 'Final review for lamp replacement'));
select is(tests.status_of(tests.w('wah')), 'approved_for_issue', 'and deciding again approves it');

-- ---- The Work Approval and its children (invariant 4, P5-4) -------------------------------------
select tests.login(tests.w('u_op'));
select tests.must(api.submit_permit(tests.key(), tests.w('wa'), tests.version('core.permit', tests.w('wa'))));
-- Pam required hot works too, which nobody has submitted.
select tests.login(tests.w('u_pam'));
select tests.must(api.require_class(tests.key(), tests.w('wp'), tests.w('pc_hw'), 'Brackets are ground: hot works apply.'));
select tests.set_w('hw', tests.permit_of(tests.w('wp'), tests.w('pc_hw')));
select tests.must(api.decide_step(tests.key(), tests.step_of(tests.w('wa'), 'wa-review'), 'no_further_comments', 'Job reviewed',
  'Venue review of lamp replacement in Halls 1 and 2'));
select is(tests.status_of(tests.w('wa')), 'approved_for_issue',
  'a Work Approval can be approved while a required permit is still being prepared (its issue waits for it)');
select tests.login(tests.w('u_op'));
select tests.must(api.submit_permit(tests.key(), tests.w('hw'), tests.version('core.permit', tests.w('hw'))));
select tests.login(tests.w('u_pam'));
select tests.must(api.decide_step(tests.key(), tests.step_of(tests.w('hw'), 'hw-review'), 'refused', 'Grinding near the stand fabric is not acceptable'));
select is(tests.status_of(tests.w('hw')), 'refused', 'a refused step refuses the permit');
select is(tests.status_of(tests.w('wa')), 'under_review', 'but a required permit being refused takes its Work Approval back to review (P5-4)');
select tests.logout();
select throws_ok(format($$select set_config('octra.transition', '', true); update core.permit set status = 'approved_for_issue' where id = %L$$, tests.w('wa')),
  null, null, 'the status cannot be written directly');

-- ---- A material change to the job (invariant 6) --------------------------------------------------
select tests.login(tests.w('u_op'));
select is(api.revise_work_package(tests.key(), tests.w('wp'), tests.version('core.work_package', tests.w('wp')),
  tests.wp_input(p_areas => array[tests.w('hall1')], p_title => 'Replace lamps', p_supervisor => tests.w('p_op'),
    p_parties => jsonb_build_array(jsonb_build_object('organisation_id', tests.w('org_o2'), 'role', 'affected_occupier'))),
  'Hall 2 dropped') ->> 'change_kind', 'material', 'dropping an area is a material change');
select is((select string_agg(status, ',' order by id) from core.permit where work_package_id = tests.w('wp') and status <> 'cancelled'),
  'draft,draft,draft', 'and every permit not yet issued returns to draft, whatever state it reached');
select tests.logout();
select is((select count(*)::int from core.step_decision d join core.permit_step s on s.id = d.permit_step_id
            join core.permit_version v on v.id = s.permit_version_id where v.permit_id = tests.w('wah')), 8,
  'while every earlier decision stays recorded (3 on the first version, 5 on the second)');

-- ---- Someone connected with the job cannot decide on it (invariant 3) -------------------------
select tests.set_w('wp_pam', tests.new_job(jsonb_set(tests.wp_input(p_areas => array[tests.w('hall1')], p_title => 'Pam is our contact',
  p_supervisor => tests.w('p_op')), '{contact_person_id}', to_jsonb(tests.w('p_pam')))));
select tests.must(tests.answer_and_submit(tests.w('wp_pam'), tests.no_to_all(), array[tests.w('pc_wah')]));
select tests.login(tests.w('u_op'));
select tests.must(api.start_permits(tests.key(), tests.w('wp_pam')));
select tests.must(api.save_permit_draft(tests.key(), tests.permit_of(tests.w('wp_pam'), tests.w('pc_wah')), '{"access": ["mewp"]}',
  date_trunc('day', now()) + interval '7 days', date_trunc('day', now()) + interval '8 days'));
select tests.must(api.submit_permit(tests.key(), tests.permit_of(tests.w('wp_pam'), tests.w('pc_wah')),
  tests.version('core.permit', tests.permit_of(tests.w('wp_pam'), tests.w('pc_wah')))));
select tests.login(tests.w('u_pam'));
select is(api.decide_step(tests.key(), tests.step_of(tests.permit_of(tests.w('wp_pam'), tests.w('pc_wah')), 'rams'), 'no_further_comments',
  'Fine', 'RAMS reviewed for lamp replacement in Hall 1') ->> 'code', 'separation_of_duties',
  'the job''s named contact cannot decide its steps, even holding the authority');
select is(api.require_class(tests.key(), tests.w('wp_pam'), tests.w('pc_hw'), 'Grinding') ->> 'code', 'separation_of_duties',
  'nor require a permit for it (P5-12)');

-- While the applicant is answering, no other step can be decided either.
select tests.set_w('wp_par', tests.routed_job());
select tests.login(tests.w('u_op'));
select tests.must(api.start_permits(tests.key(), tests.w('wp_par')));
select tests.must(api.save_permit_draft(tests.key(), tests.permit_of(tests.w('wp_par'), tests.w('pc_wah')), '{"access": ["scaffold"]}',
  date_trunc('day', now()) + interval '7 days', date_trunc('day', now()) + interval '8 days'));
select tests.must(api.submit_permit(tests.key(), tests.permit_of(tests.w('wp_par'), tests.w('pc_wah')),
  tests.version('core.permit', tests.permit_of(tests.w('wp_par'), tests.w('pc_wah')))));
select tests.login(tests.w('u_pam'));
select tests.must(api.decide_step(tests.key(), tests.step_of(tests.permit_of(tests.w('wp_par'), tests.w('pc_wah')), 'rams'), 'more_information',
  'Scaffold design needed', p_rfi => '{"message": "Send the scaffold design.", "items": [{"about": "access", "text": "Scaffold design"}]}'));
select tests.login(tests.w('u_olga'));
select is(api.decide_step(tests.key(), tests.step_of(tests.permit_of(tests.w('wp_par'), tests.w('pc_wah')), 'occupier'), 'no_further_comments',
  'Fine', 'Occupier agrees to lamp replacement in Hall 2') ->> 'code', 'step_not_open',
  'a parallel step cannot be decided while more information is awaited');

-- ---- Isolation --------------------------------------------------------------------------------------
select tests.login(tests.w('u_b1'));
select is((select count(*)::int from (select id from api.permit union all select id from api.permit_version
  union all select id from api.permit_step union all select id from api.step_decision union all select id from api.rfi
  union all select id from api.permit_class_version union all select id from api.area_occupation) x), 0,
  'another tenant sees no permit, decision or configuration');
select tests.login(tests.w('u_op'));
select is((select count(*)::int from api.area_occupation), 0, 'a contractor never sees who occupies the venue''s areas');
select tests.login(tests.w('u_h'));
select is((select count(*)::int from api.permit), 0, 'an unrelated person at the venue sees no permits');

select tests.logout();
select * from finish();
rollback;
