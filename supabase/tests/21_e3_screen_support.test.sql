-- Phase 3b-2: what the phase 2 screens read (0026).
begin;
\ir _helpers.psql
\ir _phase3.psql
select no_plan();

select tests.login(tests.w('u_platform'));
select is(api.am_platform_admin(), true, 'a platform administrator is told they are one');
select tests.login(tests.w('u_a1'));
select is(api.am_platform_admin(), false, 'a tenant administrator is not');
select tests.logout();
select ok(not has_function_privilege('anon', 'api.am_platform_admin()', 'execute'), 'nobody signed out can ask');

-- Appointment type versions show where they stand (D-011).
select tests.login(tests.w('u_a1'));
select is((select status from api.appointment_type_version
            where appointment_type_id = tests.w('t_hsa') order by version_no desc limit 1), 'approved',
  'a tenant administrator sees that a version was approved');
select ok((select decided_by_person_id is not null and decided_at is not null from api.appointment_type_version
            where appointment_type_id = tests.w('t_hsa') order by version_no desc limit 1),
  'and who decided it, and when');
select tests.login(tests.w('u_b1'));
select is((select count(*)::int from api.appointment_type_version where appointment_type_id = tests.w('t_hsa')), 0,
  'another tenant sees none of it');

-- What an accepting organisation entered is readable for resolving a duplicate (Q26); the token hash never is.
select has_column('api', 'invitation', 'acceptance_details', 'the invitation view includes what the acceptor entered');
select hasnt_column('api', 'invitation', 'token_hash', 'and never the token hash');

select * from finish();
rollback;
