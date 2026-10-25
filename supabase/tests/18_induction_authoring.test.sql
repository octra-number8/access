-- Induction authoring and publication (Q43, Q44, P3-4, P3-5, D-011, D-015).
begin;
\ir _helpers.psql
\ir _phase3.psql
select no_plan();

select is((select status from core.course_version where id = tests.w('cv1')), 'published', 'the fixture course is published');
select ok((select content_sha256 is not null from core.course_version where id = tests.w('cv1')), 'with a snapshot hash');
select is((select published_by_person_id from core.course_version where id = tests.w('cv1')), tests.w('p_hes'),
  'published by the venue H&S authority');

-- ---- Drafting -------------------------------------------------------------------------------
select tests.login(tests.w('u_a1'));
select tests.set_w('cv2', tests.must(api.create_course_draft(tests.key(), tests.w('course_core'), 'en-GB')));
select is((select pass_mark_percent from core.course_version where id = tests.w('cv2')), 60,
  'a new draft starts from the previous version''s settings, for review again');
select throws_ok(format($$select api.create_course_draft(%L, %L, 'en-GB')$$, tests.key(), tests.w('course_core')),
  'PT409', null, 'only one version can be in preparation at a time');
select is(api.save_course_draft(tests.key(), tests.w('cv2'), tests.version('core.course_version', tests.w('cv2')),
            '{"modules": [{"key": "Bad Key", "title": "x", "kind": "core", "min_seconds": 0, "blocks": []}], "questions": [], "declaration": []}') ->> 'code',
  'invalid_content', 'invalid content is refused');
select ok((api.save_course_draft(tests.key(), tests.w('cv2'), tests.version('core.course_version', tests.w('cv2')),
            '{"modules": [], "questions": [{"key": "q1", "placement": "final", "type": "single_choice", "stem": "?", "safety_critical": false,
               "options": [{"key": "a", "text": "A", "correct": true}, {"key": "b", "text": "B", "correct": true}]}], "declaration": []}') -> 'problems')::text
            like '%exactly one correct option%',
  'with each problem explained in plain words');
select is((select count(*)::int from core.decision_context where target_id = tests.w('cv2') and action_code = 'course_version.save_draft'), 0,
  'and a refused save records no decision');
select tests.must(api.save_course_draft(tests.key(), tests.w('cv2'), tests.version('core.course_version', tests.w('cv2')),
  tests.core_content() || jsonb_build_object('modules', (tests.core_content() -> 'modules') || jsonb_build_array(
    jsonb_build_object('key', 'm-video', 'title', 'Film', 'kind', 'role', 'min_seconds', 0,
      'blocks', jsonb_build_array(jsonb_build_object('type', 'video', 'media_id', null, 'caption_media_id', null, 'transcript', null)))))));

-- ---- Readiness ------------------------------------------------------------------------------
select tests.must(api.add_open_point(tests.key(), tests.w('cv2'), 'Assembly point location', 'The venue'));
create temp table t_sub as select api.submit_course_version(tests.key(), tests.w('cv2'), tests.version('core.course_version', tests.w('cv2'))) as r;
grant select on t_sub to authenticated;
select is((select r ->> 'code' from t_sub), 'not_ready', 'an unready version cannot be submitted');
select ok((select r -> 'problems' from t_sub)::text like '%needs a captions file%', 'a video needs captions (Q46)');
select ok((select r -> 'problems' from t_sub)::text like '%needs a transcript%', 'and a transcript');
select ok((select r -> 'problems' from t_sub)::text like '%unresolved open points%', 'unresolved open points block it');
select tests.must(api.save_course_draft(tests.key(), tests.w('cv2'), tests.version('core.course_version', tests.w('cv2')),
  tests.core_content() || jsonb_build_object('modules', (tests.core_content() -> 'modules') || jsonb_build_array(
    jsonb_build_object('key', 'm-image', 'title', 'Site plan', 'kind', 'area', 'min_seconds', 0,
      'blocks', jsonb_build_array(jsonb_build_object('type', 'image', 'media_id', null, 'alt', null)))))));
select ok((api.submit_course_version(tests.key(), tests.w('cv2'), tests.version('core.course_version', tests.w('cv2'))) -> 'problems')::text
            like '%needs alt text%', 'an image needs alt text or to be marked decorative');
select tests.must(api.save_course_draft(tests.key(), tests.w('cv2'), tests.version('core.course_version', tests.w('cv2')), tests.core_content()));
select tests.must(api.resolve_open_point(tests.key(), (select id from core.course_open_point where course_version_id = tests.w('cv2')),
  1, 'North car park, confirmed by the venue on 25/10'));
select tests.logout();

-- Settings have no defaults (CLAUDE.md §9).
select tests.login(tests.w('u_a1'));
select tests.set_w('course_two', tests.must(api.create_induction_course(tests.key(), tests.w('v1'), 'TWO', 'Second course')));
select tests.set_w('cv_two', tests.must(api.create_course_draft(tests.key(), tests.w('course_two'), 'en-GB')));
select tests.must(api.save_course_draft(tests.key(), tests.w('cv_two'), tests.version('core.course_version', tests.w('cv_two')), tests.core_content()));
select ok((api.submit_course_version(tests.key(), tests.w('cv_two'), tests.version('core.course_version', tests.w('cv_two'))) -> 'problems')::text
            like '%Settings not yet set: pass mark%', 'a new course has no settings until the venue sets them');
select tests.logout();

-- ---- Review and publication (P3-4) ----------------------------------------------------------
select tests.login(tests.w('u_a1'));
select tests.must(api.submit_course_version(tests.key(), tests.w('cv2'), tests.version('core.course_version', tests.w('cv2'))));
select is(api.decide_course_version(tests.key(), tests.w('cv2'), tests.version('core.course_version', tests.w('cv2')), 'publish') ->> 'code',
  'separation_of_duties', 'the author cannot publish their own version');
select tests.login(tests.w('u_h'));
select is(api.decide_course_version(tests.key(), tests.w('cv2'), tests.version('core.course_version', tests.w('cv2')), 'publish') ->> 'code',
  'no_covering_appointment', 'an appointee without the authority cannot publish');
select tests.login(tests.w('u_hes'));
select throws_ok(format($$select api.decide_course_version(%L, %L, %s, 'return', '')$$, tests.key(), tests.w('cv2'),
                        tests.version('core.course_version', tests.w('cv2'))),
  '22023', null, 'returning a version needs a reason');
select is(api.decide_course_version(tests.key(), tests.w('cv2'), tests.version('core.course_version', tests.w('cv2')), 'return',
            'Question q-a wording is unclear') ->> 'ok', 'true', 'the H&S authority can return it with reasons');
select tests.logout();
select is((select status || ': ' || return_reason from core.course_version where id = tests.w('cv2')), 'draft: Question q-a wording is unclear',
  'it is back in draft with the reason');
select tests.login(tests.w('u_a1'));
select tests.must(api.submit_course_version(tests.key(), tests.w('cv2'), tests.version('core.course_version', tests.w('cv2'))));
select tests.login(tests.w('u_hes'));
select is(api.decide_course_version(tests.key(), tests.w('cv2'), tests.version('core.course_version', tests.w('cv2')), 'publish') ->> 'ok',
  'true', 'the H&S authority publishes it');
select tests.logout();
select is((select status from core.course_version where id = tests.w('cv1')), 'superseded', 'the previous version is superseded');
select ok(exists (select 1 from core.decision_context where action_code = 'course_version.supersede' and target_id = tests.w('cv1')
                   and parent_id is not null), 'as a derived decision of the publication');

-- An author who also holds the authority still cannot publish their own work (P3-4).
select tests.login(tests.w('u_a1'));
select tests.must(api.grant_tenant_admin(tests.key(), tests.w('cust_a'), tests.w('p_hes')));
select tests.login(tests.w('u_hes'));
select tests.set_w('cv3', tests.must(api.create_course_draft(tests.key(), tests.w('course_core'), 'en-GB')));
select tests.must(api.submit_course_version(tests.key(), tests.w('cv3'), tests.version('core.course_version', tests.w('cv3'))));
select is(api.decide_course_version(tests.key(), tests.w('cv3'), tests.version('core.course_version', tests.w('cv3')), 'publish') ->> 'code',
  'separation_of_duties', 'the person who authored and submitted a version cannot publish it, even holding the authority');
select tests.logout();

-- ---- Published versions are immutable ---------------------------------------------------------
select throws_ok(format($$update core.course_version set content = '{}' where id = %L$$, tests.w('cv2')),
  '23514', 'only a draft can be changed; start a new version instead', 'published content cannot be changed, even directly');
select tests.login(tests.w('u_a1'));
select throws_ok(format($$select api.save_course_draft(%L, %L, %s, %L::jsonb)$$, tests.key(), tests.w('cv2'),
                        tests.version('core.course_version', tests.w('cv2')), tests.core_content()),
  'PT409', 'only a draft can be edited; start a new version instead', 'or through the API, even with identical content');

-- ---- Answers are never readable by learners or others -------------------------------------------
select tests.login(tests.w('u_op'));
select throws_ok($$select content from core.course_version limit 1$$, '42501', null, 'clients cannot read content (with answers) directly');
select is(api.course_content(tests.w('cv2')) ->> 'code', 'not_found', 'an operative cannot read the authoring content');
select tests.login(tests.w('u_hes'));
select is(api.course_content(tests.w('cv2')) ->> 'ok', 'true', 'the H&S authority can, to review it');
select tests.login(tests.w('u_b1'));
select is((select count(*)::int from api.course_version), 0, 'another customer sees no course versions');
select is((select count(*)::int from api.induction_course), 0, 'or courses');
select tests.logout();

-- ---- Events (P3-3) -------------------------------------------------------------------------------
select tests.login(tests.w('u_a1'));
select tests.set_w('ev', tests.must(api.create_event(tests.key(), tests.w('v1'), 'EXPO27', 'Expo 2027',
  now() + interval '30 days', now() + interval '40 days')));
select is(api.add_event_phase(tests.key(), tests.w('ev'), 'build', now() + interval '30 days', now() + interval '33 days') ->> 'ok',
  'true', 'an event has build, live and breakdown phases');
select throws_ok(format($$select api.add_event_phase(%L, %L, 'build', now() + interval '32 days', now() + interval '34 days')$$,
                        tests.key(), tests.w('ev')),
  '23P01', null, 'phases of the same kind cannot overlap');
select is(api.create_induction_course(tests.key(), tests.w('v1'), 'EXPO', 'Expo 2027 induction', 'Everyone on the Expo build', tests.w('ev')) ->> 'ok',
  'true', 'a course can belong to an event');
select tests.logout();

select * from finish();
rollback;
