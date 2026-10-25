-- The learner journey (Q41-Q47, P3-2, P3-5, P3-6, P3-8): personal links, server-side
-- order and timing, scoring with safety-critical questions, retries, assisted review,
-- declaration, immutable completions, facilitation and invalidation.
begin;
\ir _helpers.psql
\ir _phase3.psql
select no_plan();

-- Runs a whole attempt for the signed-in learner. p_right=false answers the
-- safety-critical question q-b wrongly (score 66%, above the 60% pass mark).
create function tests.run_attempt(p_course uuid, p_right boolean) returns jsonb language plpgsql as $$
declare a uuid; r jsonb;
begin
  a := tests.must(api.start_induction(tests.key(), p_course));
  perform tests.must(api.module_progress(tests.key(), a, 'm-one', 'start'));
  perform tests.must(api.module_progress(tests.key(), a, 'm-one', 'complete'));
  perform tests.must(api.answer_question(tests.key(), a, 'q-a', array['anyone']));
  perform tests.must(api.module_progress(tests.key(), a, 'm-two', 'start'));
  perform tests.must(api.module_progress(tests.key(), a, 'm-two', 'complete'));
  perform tests.must(api.answer_question(tests.key(), a, 'q-b', case when p_right then array['stop', 'leave'] else array['stop'] end));
  perform tests.must(api.answer_question(tests.key(), a, 'q-c', array['false']));
  r := api.finish_attempt(tests.key(), a, tests.version('core.induction_attempt', a));
  return r || jsonb_build_object('attempt_id', a);
end $$;
grant execute on function tests.run_attempt(uuid, boolean) to authenticated;

-- ---- Personal links (P3-2) -------------------------------------------------------------
select tests.login(tests.w('u_h'));
select is(api.claim_induction_link(tests.key(), tests.tok_op()) ->> 'code', 'link_wrong_account',
  'someone signed in with a different email cannot use the link');
select is(api.claim_induction_link(tests.key(), 'not-a-token') ->> 'code', 'not_found', 'a made-up link is refused');
select is(api.start_induction(tests.key(), tests.w('course_core')) ->> 'code', 'no_link',
  'nobody can start an induction without a personal link');
select tests.login(tests.w('u_op'));
select is(api.claim_induction_link(tests.key(), tests.tok_op()) ->> 'ok', 'true', 'the person it was sent to can open it');
select tests.logout();

-- Someone with no login yet: opening the link links their new login to their person record.
select tests.set_w('u_nina', tests.new_user('nina@a.test'));
select tests.login(tests.w('u_a1'));
select tests.set_w('p_nina', tests.must(api.create_person(tests.key(), tests.w('cust_a'), 'Nina', 'New', p_email => 'nina@a.test')));
create temp table t_tok (name text primary key, token text);
grant select on t_tok to authenticated;
insert into t_tok select 'nina', api.issue_induction_link(tests.key(), tests.w('course_core'), tests.w('p_nina'), now() + interval '7 days') ->> 'token';
select tests.login(tests.w('u_nina'));
select is(api.learner_course(tests.w('course_core')) ->> 'code', 'not_found', 'before opening the link, the person has no access');
select is(api.claim_induction_link(tests.key(), (select token from t_tok where name = 'nina')) ->> 'ok', 'true',
  'opening the link with the matching email works');
select tests.logout();
select is((select person_id from core.user_account where auth_user_id = tests.w('u_nina')), tests.w('p_nina'),
  'and links the new login to the person the link was issued to');

-- Revoked and expired links.
select tests.login(tests.w('u_a1'));
insert into t_tok select 'rev', api.issue_induction_link(tests.key(), tests.w('course_core'), tests.w('p_nina'), now() + interval '7 days') ->> 'token';
insert into t_tok select 'old', api.issue_induction_link(tests.key(), tests.w('course_core'), tests.w('p_nina'), now() + interval '7 days') ->> 'token';
select tests.logout();
select tests.set_w('link_rev', (select id from core.induction_link where token_hash = core.token_hash((select token from t_tok where name = 'rev'))));
select tests.login(tests.w('u_a1'));
select tests.must(api.revoke_induction_link(tests.key(), tests.w('link_rev'), 1));
select tests.logout();
-- Simulate time passing for one link (tests only).
alter table core.induction_link disable trigger b_guard_update;
update core.induction_link set created_at = now() - interval '10 days', expires_at = now() - interval '1 day'
 where token_hash = core.token_hash((select token from t_tok where name = 'old'));
alter table core.induction_link enable trigger b_guard_update;
select tests.login(tests.w('u_nina'));
select is(api.claim_induction_link(tests.key(), (select token from t_tok where name = 'rev')) ->> 'code', 'link_revoked',
  'a withdrawn link no longer works');
select is(api.claim_induction_link(tests.key(), (select token from t_tok where name = 'old')) ->> 'code', 'link_expired',
  'nor does an expired one');
select tests.logout();

-- ---- What the learner sees ----------------------------------------------------------------
select tests.login(tests.w('u_op'));
create temp table t_lc as select api.learner_course(tests.w('course_core')) as r;
grant select on t_lc to authenticated;
select is((select r ->> 'version_id' from t_lc), tests.w('cv1')::text, 'the learner gets the current published version');
select is((select count(*)::int from t_lc, jsonb_array_elements(r -> 'content' -> 'questions') q, jsonb_array_elements(q -> 'options') o
            where o ? 'correct'), 0, 'with no correct answers anywhere in it');

-- ---- Order and timing on the server ----------------------------------------------------------
select tests.set_w('att1', tests.must(api.start_induction(tests.key(), tests.w('course_core'))));
select is(api.start_induction(tests.key(), tests.w('course_core')) ->> 'id', tests.w('att1')::text,
  'starting again resumes the open attempt');
select is(api.module_progress(tests.key(), tests.w('att1'), 'm-one', 'complete') ->> 'code', 'not_started',
  'a module must be started before it is completed');
select is(api.module_progress(tests.key(), tests.w('att1'), 'm-two', 'start') ->> 'code', 'out_of_order',
  'modules are taken in order');
select tests.must(api.module_progress(tests.key(), tests.w('att1'), 'm-one', 'start'));
select is(api.answer_question(tests.key(), tests.w('att1'), 'q-a', array['anyone']) ->> 'code', 'not_yet',
  'a module''s question waits until the module is finished');
select tests.must(api.module_progress(tests.key(), tests.w('att1'), 'm-one', 'complete'));
select is(api.answer_question(tests.key(), tests.w('att1'), 'q-b', array['stop']) ->> 'code', 'not_yet',
  'final questions wait until every module is finished');
select is(api.answer_question(tests.key(), tests.w('att1'), 'q-a', array['anyone', 'managers']) ->> 'code', 'invalid_answer',
  'a single-choice question takes one answer');
select is(api.answer_question(tests.key(), tests.w('att1'), 'q-a', array['nobody']) ->> 'code', 'invalid_answer',
  'answers must be among the options');
select tests.must(api.answer_question(tests.key(), tests.w('att1'), 'q-a', array['anyone']));
select is(api.answer_question(tests.key(), tests.w('att1'), 'q-a', array['managers']) ->> 'code', 'already_answered',
  'an answer cannot be changed');
select is(api.finish_attempt(tests.key(), tests.w('att1'), tests.version('core.induction_attempt', tests.w('att1'))) ->> 'code',
  'incomplete', 'an attempt cannot finish with modules or questions left');

-- ---- Scoring with a safety-critical question (P3-6) ---------------------------------------------
select tests.must(api.module_progress(tests.key(), tests.w('att1'), 'm-two', 'start'));
select tests.must(api.module_progress(tests.key(), tests.w('att1'), 'm-two', 'complete'));
select tests.must(api.answer_question(tests.key(), tests.w('att1'), 'q-b', array['stop']));
select tests.must(api.answer_question(tests.key(), tests.w('att1'), 'q-c', array['false']));
create temp table t_res as select api.finish_attempt(tests.key(), tests.w('att1'), tests.version('core.induction_attempt', tests.w('att1'))) as r;
grant select on t_res to authenticated;
select is((select (r ->> 'score_percent')::int from t_res), 66, 'scores 66%, above the 60% pass mark');
select is((select r ->> 'passed' from t_res), 'false', 'but fails, because a safety-critical question was missed');
select is((select r -> 'wrong' -> 0 ->> 'explanation' from t_res), 'Stop and leave by the nearest exit.',
  'the wrong answer is explained');
select is((select r -> 'wrong' -> 0 ->> 'module_key' from t_res), 'm-two', 'and points back to its module');
select ok((select not (r::text like '%"correct"%') from t_res), 'without revealing the correct options');
select is((select (r ->> 'attempts_left')::int from t_res), 1, 'and says how many attempts are left');
select is(api.complete_induction(tests.key(), tests.w('att1'), tests.version('core.induction_attempt', tests.w('att1')),
            array['d-1', 'd-2'], 'Oli Operative') ->> 'code', 'not_passed', 'a failed attempt cannot be signed off');

select is(tests.run_attempt(tests.w('course_core'), true) ->> 'passed', 'true', 'a second attempt with every answer right passes');
select tests.set_w('att2', (select id from core.induction_attempt where person_id = tests.w('p_op') and status = 'passed'));

-- ---- Declaration and completion (P3-8) ----------------------------------------------------------
select is(api.complete_induction(tests.key(), tests.w('att2'), tests.version('core.induction_attempt', tests.w('att2')),
            array['d-1'], 'Oli Operative') ->> 'code', 'declaration_incomplete', 'every declaration item must be confirmed');
select is(api.complete_induction(tests.key(), tests.w('att2'), tests.version('core.induction_attempt', tests.w('att2')),
            array['d-1', 'd-2'], '  ') ->> 'code', 'name_required', 'the declaration is signed with a typed name');
select is(api.complete_induction(tests.key(), tests.w('att2'), tests.version('core.induction_attempt', tests.w('att2')),
            array['d-1', 'd-2'], 'Oli Operative', true) ->> 'code', 'signature_mode',
  'a drawn signature is refused where the venue chose typed names');
select tests.set_w('comp_op', (api.complete_induction(tests.key(), tests.w('att2'), tests.version('core.induction_attempt', tests.w('att2')),
            array['d-1', 'd-2'], 'Oli Operative') ->> 'completion_id')::uuid);
select tests.logout();
select isnt(tests.w('comp_op'), null, 'the learner completes the induction');
select ok((select valid_until between now() + interval '364 days' and now() + interval '366 days' from core.induction_completion
            where id = tests.w('comp_op')), 'valid for the 365 days the venue set');
select is((select method || '/' || language || '/' || signature_kind from core.induction_completion where id = tests.w('comp_op')),
  'self/en-GB/typed', 'recording method, language and signature');
select is((select course_version_id from core.induction_completion where id = tests.w('comp_op')), tests.w('cv1'),
  'and the exact course version');
select is((select status from core.induction_attempt where id = tests.w('att2')), 'completed', 'the attempt is closed');
select throws_ok(format($$update core.induction_completion set valid_until = now() + interval '10 years' where id = %L$$, tests.w('comp_op')),
  '42501', null, 'a completion cannot be changed');
select throws_ok(format($$delete from core.question_response where attempt_id = %L$$, tests.w('att2')),
  '42501', null, 'nor its answers deleted');

-- ---- Minimum reading time, retry delay and assisted review (P3-5) -------------------------------
select tests.login(tests.w('u_a1'));
select tests.set_w('course_timed', tests.must(api.create_induction_course(tests.key(), tests.w('v1'), 'TIMED', 'Timed')));
select tests.set_w('course_once', tests.must(api.create_induction_course(tests.key(), tests.w('v1'), 'ONCE', 'One attempt')));
select tests.set_w('course_wait', tests.must(api.create_induction_course(tests.key(), tests.w('v1'), 'WAIT', 'Retry delay')));
select tests.logout();
select tests.publish_course(tests.w('course_timed'), tests.core_content(60));
select tests.publish_course(tests.w('course_once'), tests.core_content(), 1, 0);
select tests.publish_course(tests.w('course_wait'), tests.core_content(), 3, 60);
select tests.login(tests.w('u_a1'));
select tests.must(api.issue_induction_link(tests.key(), tests.w('course_timed'), tests.w('p_op'), now() + interval '7 days'));
select tests.must(api.issue_induction_link(tests.key(), tests.w('course_once'), tests.w('p_op'), now() + interval '7 days'));
select tests.must(api.issue_induction_link(tests.key(), tests.w('course_wait'), tests.w('p_op'), now() + interval '7 days'));
select tests.login(tests.w('u_op'));
select tests.set_w('att_t', tests.must(api.start_induction(tests.key(), tests.w('course_timed'))));
select tests.must(api.module_progress(tests.key(), tests.w('att_t'), 'm-one', 'start'));
select is(api.module_progress(tests.key(), tests.w('att_t'), 'm-one', 'complete') ->> 'code', 'too_soon',
  'a module cannot be completed before its minimum reading time, measured on the server');
select is(tests.run_attempt(tests.w('course_once'), false) ->> 'passed', 'false', 'a one-attempt course is failed');
select is(api.start_induction(tests.key(), tests.w('course_once')) ->> 'code', 'assisted_review_required',
  'with no attempts left, an induction facilitator must go through it with the person (Q44)');
select is(tests.run_attempt(tests.w('course_wait'), false) ->> 'passed', 'false', 'a course with a retry delay is failed');
select is(api.start_induction(tests.key(), tests.w('course_wait')) ->> 'code', 'retry_not_yet', 'the next attempt waits for the delay');
select tests.logout();

-- ---- Facilitated completion (Q47) ----------------------------------------------------------------
select tests.login(tests.w('u_h'));
select is(api.record_facilitated_completion(tests.key(), (select id from core.course_version where course_id = tests.w('course_once')),
            tests.w('p_op'), 'assisted', 'Photo ID checked', 'Talked through each module', true) ->> 'code',
  'no_covering_appointment', 'only an appointed facilitator can record one');
select tests.login(tests.w('u_hes'));
select is(api.record_facilitated_completion(tests.key(), tests.w('cv1'), tests.w('p_hes'), 'assisted', 'Photo ID checked',
            'Talked through each module', true) ->> 'code',
  'separation_of_duties', 'a facilitator cannot record their own induction');
select throws_ok(format($$select api.record_facilitated_completion(%L, %L, %L, 'assisted', 'ID', '', true)$$,
                        tests.key(), (select id from core.course_version where course_id = tests.w('course_once')), tests.w('p_op')),
  '22023', null, 'how identity and understanding were checked must be recorded');
select is(api.record_facilitated_completion(tests.key(), (select id from core.course_version where course_id = tests.w('course_once')),
            tests.w('p_op'), 'assisted', 'Photo card checked against record', 'Asked to explain the evacuation route; correct', true) ->> 'ok',
  'true', 'after assisted review, a facilitator records the completion');
select tests.logout();
select is((select method || '/' || signature_kind from core.induction_completion c
            join core.course_version v on v.id = c.course_version_id where v.course_id = tests.w('course_once')),
  'assisted/acknowledged_to_facilitator', 'recorded as assisted, acknowledged to the facilitator');

-- ---- Invalidation is a separate record (Q45) ----------------------------------------------------------
select tests.login(tests.w('u_hes'));
select is(api.invalidate_completion(tests.key(), tests.w('comp_op'), 'breach_review', 'Serious site rules breach on 24/10') ->> 'ok',
  'true', 'the H&S authority can invalidate a completion');
select tests.logout();
select is((select valid_until > now() from core.induction_completion where id = tests.w('comp_op')), true,
  'the completion itself is unchanged');
select tests.login(tests.w('u_op'));
select is((select invalidated_for from api.induction_completion where id = tests.w('comp_op')), 'breach_review',
  'and the person can see it has been invalidated, and why');

-- ---- Who sees completions -------------------------------------------------------------------------
select tests.login(tests.w('u_nina'));
select is((select count(*)::int from api.induction_completion where person_id = tests.w('p_op')), 0,
  'another learner cannot see someone else''s completion');
select is((select count(*)::int from api.induction_attempt where person_id = tests.w('p_op')), 0, 'or their attempts');
select tests.login(tests.w('u_h'));
select ok((select count(*) from api.induction_completion where person_id = tests.w('p_op')) > 0,
  'an appointee at the venue can (the gate phase will need it)');
select tests.login(tests.w('u_b1'));
select is((select count(*)::int from api.induction_completion), 0, 'another customer cannot');
select tests.logout();

select * from finish();
rollback;
