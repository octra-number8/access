-- Phase 4b read functions (0030): who may preview screening and read a job's detail,
-- and that the detail carries names only, never contact details.
begin;
\ir _helpers.psql
\ir _phase4.psql
select no_plan();
select tests.approve_screening();
select tests.set_w('wp', tests.new_job());
select tests.must(tests.answer_and_submit(tests.w('wp'), '{"hot": ["yes"], "isolate": ["no"], "height": ["no"], "confined": ["yes"]}'));

-- ---- Preview ---------------------------------------------------------------------------------
select tests.login(tests.w('u_a1'));
select is((select jsonb_agg(m ->> 'rule_key' order by m ->> 'rule_key')
             from jsonb_array_elements(api.preview_screening(tests.w('ss1'), '{"hot": ["yes"], "isolate": ["no"], "height": ["yes"], "height-kind": ["roof"], "confined": ["yes"]}') -> 'matches') m),
  '["r-confined", "r-hot", "r-roof"]'::jsonb, 'the preview runs the same rules as submission');
select is(jsonb_array_length(api.preview_screening(tests.w('ss1'), '{}') -> 'problems') > 0, true,
  'and lists what an applicant would still have to answer');
select tests.logout();
create temp table t_n as select count(*) n from core.decision_context;
select tests.login(tests.w('u_a1'));
select ok(api.preview_screening(tests.w('ss1'), '{"hot": ["yes"]}') ->> 'ok' = 'true', 'a preview as a tenant administrator');
select tests.logout();
select is((select count(*) from core.decision_context), (select n from t_n), 'previewing records no decision');
select tests.login(tests.w('u_b1'));
select is(api.preview_screening(tests.w('ss1'), '{}') ->> 'code', 'not_found', 'another tenant cannot preview the venue''s screening');

-- ---- Job detail ------------------------------------------------------------------------------
select tests.login(tests.w('u_op'));
select is(api.work_package_detail(tests.w('wp')) ->> 'performing_organisation', 'Orbit Electrical Ltd', 'the applicant reads the job');
select is(api.work_package_detail(tests.w('wp')) #>> '{revision,contact}', 'Oli Operative', 'with names, not ids');
select is((select count(*)::int from jsonb_array_elements(api.work_package_detail(tests.w('wp')) -> 'recommendations') r
            where jsonb_array_length(r -> 'reasons') > 0), 1, 'and every recommendation with its reasons');
select is((select count(*)::int from jsonb_array_elements(api.work_package_detail(tests.w('wp')) -> 'holds')), 1, 'and its holds');
select ok(api.work_package_detail(tests.w('wp'))::text !~* '(op@a\.test|07000|email|phone)',
  'and never anyone''s contact details');
select tests.login(tests.w('u_tara'));
select is(api.work_package_detail(tests.w('wp')) ->> 'ok', 'true', 'the screening authority reads it');
select tests.login(tests.w('u_h'));
select is(api.work_package_detail(tests.w('wp')) ->> 'code', 'not_found', 'someone with no part in it cannot');
select tests.login(tests.w('u_b1'));
select is(api.work_package_detail(tests.w('wp')) ->> 'code', 'not_found', 'nor can another tenant');

select tests.logout();
select * from finish();
rollback;
