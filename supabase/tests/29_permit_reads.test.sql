-- Phase 5c read functions (0037): who may read a permit's detail and the reviewer queue,
-- and that the detail carries names, never contact details.
begin;
\ir _helpers.psql
\ir _phase4.psql
select tests.approve_screening();
\ir _phase5.psql
select no_plan();

select tests.set_w('wp', tests.routed_job(p_areas => array[tests.w('hall1')], p_parties => '[]'::jsonb));
select tests.login(tests.w('u_op'));
select tests.must(api.start_permits(tests.key(), tests.w('wp')));
select tests.set_w('wah', tests.permit_of(tests.w('wp'), tests.w('pc_wah')));
select tests.must(api.save_permit_draft(tests.key(), tests.w('wah'), '{"access": ["mewp"]}',
  date_trunc('day', now()) + interval '7 days', date_trunc('day', now()) + interval '8 days'));
select tests.must(api.set_permit_team(tests.key(), tests.w('wah'), jsonb_build_array(jsonb_build_object('person_id', tests.w('p_op'), 'role', 'supervisor'))));
select tests.must(api.submit_permit(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah'))));

-- ---- Detail -----------------------------------------------------------------------------
select is(api.permit_detail(tests.w('wah')) ->> 'status', 'submitted', 'the applicant reads the permit');
select is((select jsonb_agg(s ->> 'name' order by s ->> 'name') from jsonb_array_elements(api.permit_detail(tests.w('wah')) -> 'steps') s),
  '["Final review", "RAMS review"]'::jsonb, 'with its steps by name');
select is(api.permit_detail(tests.w('wah')) #>> '{team,0,name}', 'Oli Operative', 'and its team by name');
select ok(api.permit_detail(tests.w('wah'))::text !~* '(op@a\.test|07000)', 'and never anyone''s contact details');
select tests.login(tests.w('u_pam'));
select is(api.permit_detail(tests.w('wah')) ->> 'ok', 'true', 'a reviewer at the venue reads it');
select tests.login(tests.w('u_h'));
select is(api.permit_detail(tests.w('wah')) ->> 'code', 'not_found', 'someone with no part in it cannot');
select tests.login(tests.w('u_b1'));
select is(api.permit_detail(tests.w('wah')) ->> 'code', 'not_found', 'nor can another tenant');

-- ---- The reviewer's queue ------------------------------------------------------------------
select tests.login(tests.w('u_pam'));
select is((select jsonb_agg(x ->> 'step_name') from jsonb_array_elements(api.open_permit_steps()) x where x ->> 'permit_id' = tests.w('wah')::text),
  '["RAMS review"]'::jsonb, 'the queue lists the open step only, not the one waiting for an earlier group');
select tests.login(tests.w('u_op'));
select is(jsonb_array_length(api.open_permit_steps()), 0, 'the applicant has no review queue');
select tests.login(tests.w('u_b1'));
select is(jsonb_array_length(api.open_permit_steps()), 0, 'nor does another tenant');

select tests.logout();
select * from finish();
rollback;
