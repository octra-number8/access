-- Phase 3b: where the learner is up to (api.learner_course) and who may receive an
-- induction media file (api.induction_media_access).
begin;
\ir _helpers.psql
\ir _phase3.psql
select no_plan();

-- Two files at venue V1; only m_used appears in the published version.
select tests.login(tests.w('u_a1'));
select tests.set_w('m_used', gen_random_uuid());
select tests.set_w('m_unused', gen_random_uuid());
select tests.must(api.register_induction_media(tests.key(), tests.w('v1'), tests.w('m_used'), repeat('a', 64), 'image/png', 100, 'plan.png'));
select tests.must(api.register_induction_media(tests.key(), tests.w('v1'), tests.w('m_unused'), repeat('b', 64), 'image/png', 100, 'other.png'));
select tests.logout();
select tests.set_w('cv2', tests.publish_course(tests.w('course_core'),
  jsonb_set(tests.core_content(), '{modules,0,blocks}',
            tests.core_content() #> '{modules,0,blocks}'
            || jsonb_build_array(jsonb_build_object('type', 'image', 'media_id', tests.w('m_used'), 'alt', 'Site plan')))));

-- ---- Media access ----------------------------------------------------------------------
select tests.login(tests.w('u_a1'));
select is(api.induction_media_access(tests.w('m_unused')) ->> 'ok', 'true', 'the venue''s author may see any of its files');
select tests.login(tests.w('u_hes'));
select is(api.induction_media_access(tests.w('m_unused')) ->> 'ok', 'true', 'so may the H&S authority who publishes');

select tests.login(tests.w('u_op'));
select tests.must(api.claim_induction_link(tests.key(), tests.tok_op()));
select is(api.induction_media_access(tests.w('m_used'), tests.w('course_core')) ->> 'ok', 'true',
  'a learner with a current link receives a file the published version uses');
select ok(api.induction_media_access(tests.w('m_used'), tests.w('course_core')) ->> 'storage_path' is not null,
  'with the storage path for the server to sign');
select is(api.induction_media_access(tests.w('m_unused'), tests.w('course_core')) ->> 'code', 'not_found',
  'but not another file at the venue');
select is(api.induction_media_access(tests.w('m_used')) ->> 'code', 'not_found',
  'nor any file without naming the course they hold a link for');

select tests.login(tests.w('u_h'));
select is(api.induction_media_access(tests.w('m_used'), tests.w('course_core')) ->> 'code', 'not_found',
  'someone at the same customer without a link is refused');
select tests.login(tests.w('u_b1'));
select is(api.induction_media_access(tests.w('m_used'), tests.w('course_core')) ->> 'code', 'not_found',
  'another tenant is refused');
select is(api.induction_media_access(tests.w('m_used')) ->> 'code', 'not_found',
  'another tenant is refused without a course too');

-- ---- Learner state ---------------------------------------------------------------------
select tests.login(tests.w('u_op'));
create temp table t_s (name text primary key, v jsonb);
grant all on t_s to authenticated;
insert into t_s values ('before', api.learner_course(tests.w('course_core')));
select is((select v -> 'attempt' from t_s where name = 'before'), 'null'::jsonb, 'before starting there is no attempt');
select is((select (v ->> 'attempts_left')::int from t_s where name = 'before'), 2, 'and every attempt is left');
select is((select v ->> 'version_id' from t_s where name = 'before')::uuid, tests.w('cv2'), 'the current published version is served');
select ok((select (v -> 'content')::text not like '%"correct"%' from t_s where name = 'before'), 'without correct answers');
select is((select v #>> '{settings,pass_mark_percent}' from t_s where name = 'before'), '60', 'with the version''s settings');

select tests.set_w('att1', tests.must(api.start_induction(tests.key(), tests.w('course_core'))));
select tests.must(api.module_progress(tests.key(), tests.w('att1'), 'm-one', 'start'));
insert into t_s values ('started', api.learner_course(tests.w('course_core')));
select ok((select v #>> '{attempt,modules,m-one,started_at}' from t_s where name = 'started') is not null,
  'a started module is reported with its server start time, so a reload resumes the countdown');
select ok((select v #>> '{attempt,modules,m-one,completed_at}' from t_s where name = 'started') is null, 'and is not yet complete');
select ok((select v ->> 'server_now' from t_s where name = 'started') is not null, 'the server''s clock is included');

select tests.must(api.module_progress(tests.key(), tests.w('att1'), 'm-one', 'complete'));
select tests.must(api.answer_question(tests.key(), tests.w('att1'), 'q-a', array['anyone']));
insert into t_s values ('answered', api.learner_course(tests.w('course_core')));
select is((select v #> '{attempt,answered}' from t_s where name = 'answered'), '["q-a"]'::jsonb, 'answered questions are listed');
select is((select v #> '{attempt,wrong}' from t_s where name = 'answered'), 'null'::jsonb,
  'nothing is said about right or wrong before the attempt is finished');

select tests.must(api.module_progress(tests.key(), tests.w('att1'), 'm-two', 'start'));
select tests.must(api.module_progress(tests.key(), tests.w('att1'), 'm-two', 'complete'));
select tests.must(api.answer_question(tests.key(), tests.w('att1'), 'q-b', array['stop']));
select tests.must(api.answer_question(tests.key(), tests.w('att1'), 'q-c', array['false']));
select tests.must(api.finish_attempt(tests.key(), tests.w('att1'), tests.version('core.induction_attempt', tests.w('att1'))));
insert into t_s values ('failed', api.learner_course(tests.w('course_core')));
select is((select v #>> '{attempt,status}' from t_s where name = 'failed'), 'failed', 'the missed safety-critical question fails the attempt');
select is((select (v ->> 'attempts_left')::int from t_s where name = 'failed'), 1, 'one attempt is left');
select is((select jsonb_path_query_array(v, '$.attempt.wrong[*].question_key') from t_s where name = 'failed'), '["q-b"]'::jsonb,
  'the wrong answer is listed');
select is((select v #>> '{attempt,wrong,0,explanation}' from t_s where name = 'failed'), 'Stop and leave by the nearest exit.',
  'with its explanation');
select ok((select (v -> 'attempt')::text not like '%"correct"%' from t_s where name = 'failed'),
  'but the correct options are still not revealed');
select ok((select v ->> 'retry_from' from t_s where name = 'failed') is not null, 'and when a retry is allowed');

-- A revoked link ends access to the media and the course.
select tests.login(tests.w('u_a1'));
select tests.must(api.revoke_induction_link(tests.key(), tests.w('link_op'), tests.version('core.induction_link', tests.w('link_op'))));
select tests.login(tests.w('u_op'));
select is(api.induction_media_access(tests.w('m_used'), tests.w('course_core')) ->> 'code', 'not_found',
  'once the link is revoked the learner no longer receives the file');
select is(api.learner_course(tests.w('course_core')) ->> 'code', 'not_found', 'nor the course');

select * from finish();
rollback;
