-- Permits 5b (Q84-Q104, P5-8 to P5-11): notice on the venue's calendar, exceptions and
-- restrictions (including refusal), the team and its evidence, issue with the four-eyes
-- rule and an immutable snapshot, acceptance at the workface, and expiry.
begin;
\ir _helpers.psql
\ir _phase4.psql
select tests.approve_screening();
\ir _phase5.psql
select no_plan();

create temp table t_r (name text primary key, v jsonb);
grant all on t_r to authenticated;

-- ---- Notice arithmetic (Q84-Q85; convention to be confirmed with the technical authority, N2) ----
select tests.logout();
-- Thursday 22 October 2026, 17:00 in London; the test calendar is Monday to Friday, cut-off 16:00.
select is(core.notice_start(tests.w('v1'), '{"amount": 1, "unit": "working_days"}', false, '2026-10-22 17:00'::timestamp at time zone 'Europe/London'),
  '2026-10-23 00:00'::timestamp at time zone 'Europe/London', 'one working day from Thursday is Friday');
select is(core.notice_start(tests.w('v1'), '{"amount": 1, "unit": "working_days"}', true, '2026-10-22 17:00'::timestamp at time zone 'Europe/London'),
  '2026-10-26 00:00'::timestamp at time zone 'Europe/London', 'after the cut-off it counts from Friday, so the weekend is skipped');
select is(core.notice_start(tests.w('v1'), '{"amount": 3, "unit": "calendar_days"}', false, '2026-10-22 17:00'::timestamp at time zone 'Europe/London'),
  '2026-10-25 00:00'::timestamp at time zone 'Europe/London', 'calendar days ignore the working week');
select is(core.notice_start(tests.w('v1'), '{"amount": 5, "unit": "hours"}', true, '2026-10-22 17:00'::timestamp at time zone 'Europe/London'),
  ('2026-10-22 17:00'::timestamp at time zone 'Europe/London') + interval '5 hours', 'hours are exact');
select is(core.notice_start(tests.w('v1'), '{"amount": 0, "unit": "working_days"}', true, '2026-10-22 17:00'::timestamp at time zone 'Europe/London'),
  '2026-10-22 17:00'::timestamp at time zone 'Europe/London', 'zero notice, chosen, means none');
select tests.login(tests.w('u_a1'));
select tests.must(api.publish_venue_calendar(tests.key(), tests.w('v1'), array[1, 2, 3, 4, 5], array['2026-10-23'::date], '16:00',
  now() - interval '20 days', 'Venue closed on 23 October'));
select tests.logout();
select is(core.notice_start(tests.w('v1'), '{"amount": 1, "unit": "working_days"}', false, '2026-10-22 17:00'::timestamp at time zone 'Europe/London'),
  '2026-10-26 00:00'::timestamp at time zone 'Europe/London', 'a closure date is not a working day');
select tests.login(tests.w('u_op'));
select is(api.publish_venue_calendar(tests.key(), tests.w('v1'), array[1], '{}', '16:00', now(), 'Mine') ->> 'code', 'not_tenant_admin',
  'only the venue publishes its calendar');
select tests.login(tests.w('u_a1'));
select is(api.publish_venue_calendar(tests.key(), tests.w('v1'), '{}', '{}', null, now(), 'No defaults') ->> 'code', 'invalid_content',
  'a calendar has no default working days or cut-off');

-- ---- An issuer, a second operative and a competency ---------------------------------------
select tests.login(tests.w('u_a1'));
select tests.set_w('t_is', tests.must(api.create_appointment_type(tests.key(), tests.w('v1'), 'IS', 'Permit Issuer')));
select tests.set_w('tv_is', tests.must(api.propose_appointment_type_version(tests.key(), tests.w('t_is'),
  array['permit.issue', 'permit.exception_decide'], array[tests.w('pc_wa'), tests.w('pc_wah'), tests.w('pc_hw')], '{}', '{}', true, false,
  tests.w('p_a1'), now() - interval '1 minute', 'Permit issue')));
select tests.login(tests.w('u_r'));
select tests.must(api.decide_appointment_type_version(tests.key(), tests.w('tv_is'), tests.version('core.appointment_type_version', tests.w('tv_is')), 'approve', 'Agreed'));
select tests.set_w('u_ivy', (tests.root_ta('ivy@a.test', 'Ivy', tests.w('tv_is'), array[tests.w('pc_wa'), tests.w('pc_wah'), tests.w('pc_hw')], tests.w('site')))[1]);
select tests.login(tests.w('u_a1'));
select tests.set_w('p_owen', tests.must(api.create_person(tests.key(), tests.w('cust_a'), 'Owen', 'Operative')));
select tests.set_w('rel_owen', tests.must(api.record_person_organisation(tests.key(), tests.w('p_owen'), tests.w('org_o'), 'employee', now() - interval '1 day')));
select tests.must(api.confirm_relationship_facilitated(tests.key(), tests.w('rel_owen'), tests.version('core.person_organisation_relationship', tests.w('rel_owen')),
  'Confirmed in person at the site office'));

-- A job for today: window from an hour ago to two days ahead.
select tests.logout();
create function tests.today_job(p_title text, p_selected uuid[]) returns uuid language plpgsql as $$
declare wp uuid;
begin
  wp := tests.new_job(jsonb_set(jsonb_set(tests.wp_input(p_areas => array[tests.w('hall1')], p_title => p_title, p_supervisor => tests.w('p_op')),
          '{window_from}', to_jsonb((now() - interval '1 hour')::text)), '{window_to}', to_jsonb((now() + interval '2 days')::text)));
  perform tests.must(tests.answer_and_submit(wp, tests.no_to_all(), p_selected));
  perform tests.login(tests.w('u_op'));
  perform tests.must(api.start_permits(tests.key(), wp));
  perform tests.logout();
  return wp;
end $$;
-- Prepares, teams, submits and has Pam approve one permit of a job.
create function tests.approve_permit(p_permit uuid, p_answers jsonb) returns void language plpgsql as $$
declare s record;
begin
  perform tests.login(tests.w('u_op'));
  perform tests.must(api.save_permit_draft(tests.key(), p_permit, p_answers,
    (select lower(r.planned_window) from core.work_package_revision r join core.permit p on p.id = p_permit
       join core.work_package w on w.id = p.work_package_id where r.id = w.current_revision_id),
    (select upper(r.planned_window) from core.work_package_revision r join core.permit p on p.id = p_permit
       join core.work_package w on w.id = p.work_package_id where r.id = w.current_revision_id)));
  perform tests.must(api.set_permit_team(tests.key(), p_permit, jsonb_build_array(
    jsonb_build_object('person_id', tests.w('p_op'), 'role', 'supervisor'), jsonb_build_object('person_id', tests.w('p_owen'), 'role', 'operative'))));
  perform tests.must(api.submit_permit(tests.key(), p_permit, tests.version('core.permit', p_permit)));
  perform tests.login(tests.w('u_pam'));
  for s in select ps.id, ps.step_key from core.permit_step ps join core.permit p on p.current_version_id = ps.permit_version_id
            where p.id = p_permit order by ps.group_no, ps.step_key loop
    perform tests.must(api.decide_step(tests.key(), s.id, 'conditions', 'Reviewed', 'Reviewed for the stated work in Hall 1',
      jsonb_build_array(jsonb_build_object('text', 'Barrier the work area (' || s.step_key || ')', 'acknowledge', true))));
  end loop;
  perform tests.logout();
end $$;
grant execute on all functions in schema tests to authenticated;

select tests.set_w('wp', tests.today_job('Lamps today', array[tests.w('pc_wah')]));
select tests.set_w('wa', tests.permit_of(tests.w('wp'), tests.w('pc_wa')));
select tests.set_w('wah', tests.permit_of(tests.w('wp'), tests.w('pc_wah')));

-- ---- The team (Q99) ---------------------------------------------------------------------------
select tests.login(tests.w('u_op'));
select is(api.set_permit_team(tests.key(), tests.w('wah'), jsonb_build_array(jsonb_build_object('person_id', tests.w('p_op'), 'role', 'operative'))) ->> 'code',
  'invalid_content', 'a team needs exactly one supervisor');
select is(api.set_permit_team(tests.key(), tests.w('wah'), jsonb_build_array(jsonb_build_object('person_id', tests.w('p_op'), 'role', 'supervisor'),
  jsonb_build_object('person_id', tests.w('p_h'), 'role', 'operative'))) ->> 'code', 'invalid_content',
  'and everyone on it must work with the performing organisation');

select tests.approve_permit(tests.w('wa'), '{}');
select tests.approve_permit(tests.w('wah'), '{"access": ["mewp"]}');
select is(tests.status_of(tests.w('wa')) || '/' || tests.status_of(tests.w('wah')), 'approved_for_issue/approved_for_issue', 'both are approved for issue');

-- ---- Who issues (Q98, P5-10, invariant 9) -------------------------------------------------------
select tests.login(tests.w('u_rex'));
select is(api.issue_permit(tests.key(), tests.w('wa'), tests.version('core.permit', tests.w('wa'))) ->> 'code', 'no_covering_appointment',
  'a reviewer without issue authority cannot issue');
select tests.login(tests.w('u_a1'));
select is(api.issue_permit(tests.key(), tests.w('wa'), tests.version('core.permit', tests.w('wa'))) ->> 'code', 'no_covering_appointment',
  'nor a tenant administrator (invariant 9)');
select tests.login(tests.w('u_platform'));
select is(api.issue_permit(tests.key(), tests.w('wa'), tests.version('core.permit', tests.w('wa'))) ->> 'ok', 'false', 'nor a platform administrator');
-- Pam is given issue authority too; having decided a step, she still cannot issue (four-eyes).
select tests.login(tests.w('u_a1'));
select tests.set_w('ap_pam_is', tests.must(api.record_root_appointment(tests.key(), tests.w('v1'), tests.w('p_pam'), tests.w('p_d'), tests.w('tv_is'),
  array[tests.w('pc_wa')], jsonb_build_array(jsonb_build_object('area_id', tests.w('site'))), now() - interval '1 minute', null, null, null, 'Issue letter')));
select tests.login(tests.w('u_a2'));
select tests.must(api.confirm_root_appointment(tests.key(), tests.w('ap_pam_is'), tests.version('core.appointment', tests.w('ap_pam_is'))));
select tests.login(tests.w('u_pam'));
select tests.must(api.acknowledge_appointment(tests.key(), tests.w('ap_pam_is'), tests.version('core.appointment', tests.w('ap_pam_is'))));
select is(api.issue_permit(tests.key(), tests.w('wa'), tests.version('core.permit', tests.w('wa')), tests.w('ap_pam_is')) ->> 'code', 'separation_of_duties',
  'someone who decided a step on the version cannot issue it, even holding issue authority (P5-10)');

-- Order (P5-4) and the pre-issue checks (Q99).
select tests.login(tests.w('u_ivy'));
select ok(api.issue_permit(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')))::text like '%Work Approval has not been issued%',
  'a child permit cannot be issued before its Work Approval');
select tests.logout();
create temp table t_k (k text, ver integer);
grant all on t_k to authenticated;
insert into t_k values (tests.key(), tests.version('core.permit', tests.w('wa')));
select tests.login(tests.w('u_ivy'));
insert into t_r select 'issue', api.issue_permit((select k from t_k), tests.w('wa'), (select ver from t_k));
select is((select v ->> 'ok' from t_r where name = 'issue'), 'true', 'the issuer issues the Work Approval');
select is(tests.status_of(tests.w('wa')), 'issued_awaiting_acceptance', 'which now waits for acceptance');
select is(api.issue_permit((select k from t_k), tests.w('wa'), (select ver from t_k)) ->> 'replayed', 'true',
  'repeating the same issue request replays it rather than issuing twice');
select is((select count(*)::int from core.issue_snapshot where permit_id = tests.w('wa')), 1, 'so there is one snapshot');
select tests.logout();
select ok((select content ? 'team' and content ? 'steps' and content ? 'notice' and content ? 'class_version' and content_sha256 is not null
             from core.issue_snapshot where permit_id = tests.w('wa')), 'the snapshot freezes the team, decisions, notice and class version (invariant 5)');
select is((select jsonb_array_length(content -> 'team')) , 2, 'with both team members') from core.issue_snapshot where permit_id = tests.w('wa');
select throws_ok(format($$update core.issue_snapshot set content = '{}' where permit_id = %L$$, tests.w('wa')), null, null,
  'and can never be edited');
select tests.login(tests.w('u_ivy'));
select tests.must(api.issue_permit(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah'))));
select is(tests.status_of(tests.w('wah')), 'issued_awaiting_acceptance', 'then the child permit is issued');
select tests.login(tests.w('u_op'));
select is(api.set_permit_team(tests.key(), tests.w('wah'), jsonb_build_array(jsonb_build_object('person_id', tests.w('p_op'), 'role', 'supervisor'))) ->> 'code',
  'not_open', 'the team is frozen once the permit is issued');
select is(api.revise_work_package(tests.key(), tests.w('wp'), tests.version('core.work_package', tests.w('wp')),
  tests.wp_input(p_areas => array[tests.w('hall2')], p_title => 'Lamps today', p_supervisor => tests.w('p_op')), 'Move to Hall 2') ->> 'code',
  'permits_issued', 'a material change is refused while the job has issued permits (phase 6 suspends them)');

-- ---- Acceptance (Q100-Q103) ---------------------------------------------------------------------
select tests.logout();
create temp table t_c as select array_agg((k ->> 'id')::uuid) ids from core.issue_snapshot s, jsonb_array_elements(s.content -> 'steps') st,
  jsonb_array_elements(st #> '{decision,conditions}') k where s.permit_id = tests.w('wa');
grant select on t_c to authenticated;
select tests.login(tests.w('u_op'));
select is(api.accept_permit(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')),
  (select array_agg((k ->> 'id')::uuid) from core.issue_snapshot s, jsonb_array_elements(s.content -> 'steps') st,
     jsonb_array_elements(st #> '{decision,conditions}') k where s.permit_id = tests.w('wah')),
  array[tests.w('p_op'), tests.w('p_owen')], clock_timestamp()) ->> 'code', 'parent_not_active', 'a child permit is accepted only after its Work Approval');
select is(api.accept_permit(tests.key(), tests.w('wa'), tests.version('core.permit', tests.w('wa')), '{}',
  array[tests.w('p_op'), tests.w('p_owen')], clock_timestamp()) ->> 'code', 'conditions_not_acknowledged', 'every condition marked for acceptance must be acknowledged');
select is(api.accept_permit(tests.key(), tests.w('wa'), tests.version('core.permit', tests.w('wa')), (select ids from t_c),
  '{}', clock_timestamp()) ->> 'code', 'briefing_incomplete', 'the workface briefing must be recorded');
select is(api.accept_permit(tests.key(), tests.w('wa'), tests.version('core.permit', tests.w('wa')), (select ids from t_c),
  array[tests.w('p_h')], clock_timestamp()) ->> 'code', 'briefing_incomplete', 'with people from the team only');
select is(api.accept_permit(tests.key(), tests.w('wa'), tests.version('core.permit', tests.w('wa')), (select ids from t_c),
  array[tests.w('p_op')], clock_timestamp() + interval '1 hour') ->> 'code', 'briefing_incomplete', 'and not in the future');
select tests.login(tests.w('u_a1'));
select is(api.accept_permit(tests.key(), tests.w('wa'), tests.version('core.permit', tests.w('wa')), (select ids from t_c),
  array[tests.w('p_op')], clock_timestamp()) ->> 'code', 'not_subject', 'only the named supervisor accepts, never an administrator');
select tests.login(tests.w('u_op'));
insert into t_r select 'accept', api.accept_permit(tests.key(), tests.w('wa'), tests.version('core.permit', tests.w('wa')), (select ids from t_c),
  array[tests.w('p_op'), tests.w('p_owen')], clock_timestamp());
select is((select v ->> 'ok' from t_r where name = 'accept'), 'true', 'the supervisor accepts after the briefing');
select is(tests.status_of(tests.w('wa')), 'active', 'and the Work Approval is active');
select is((select briefed_person_ids from core.permit_acceptance a join core.issue_snapshot s on s.id = a.issue_snapshot_id where s.permit_id = tests.w('wa')),
  array[tests.w('p_op'), tests.w('p_owen')], 'with the briefing recorded');
select tests.must(api.accept_permit(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')),
  (select array_agg((k ->> 'id')::uuid) from core.issue_snapshot s, jsonb_array_elements(s.content -> 'steps') st,
     jsonb_array_elements(st #> '{decision,conditions}') k where s.permit_id = tests.w('wah')),
  array[tests.w('p_op')], clock_timestamp()));
select is(tests.status_of(tests.w('wah')), 'active', 'then the child permit');

-- ---- Notice, exceptions and restrictions (P5-8, P5-9, scenario 4) --------------------------------
-- Hot works now needs three working days' notice; a job for today cannot meet it.
select tests.set_w('cv_hw2', tests.configure_class(tests.w('pc_hw'), jsonb_set(tests.class_config(
  '[{"key": "hw-review", "name": "Hot works review", "kind": "review", "group": 1}]'), '{notice,amount}', '3')));
select tests.set_w('wp2', tests.today_job('Brackets today', array[tests.w('pc_hw')]));
select tests.approve_permit(tests.permit_of(tests.w('wp2'), tests.w('pc_wa')), '{}');
select tests.approve_permit(tests.permit_of(tests.w('wp2'), tests.w('pc_hw')), '{}');
select tests.login(tests.w('u_ivy'));
select tests.must(api.issue_permit(tests.key(), tests.permit_of(tests.w('wp2'), tests.w('pc_wa')),
  tests.version('core.permit', tests.permit_of(tests.w('wp2'), tests.w('pc_wa')))));
select ok(api.issue_permit(tests.key(), tests.permit_of(tests.w('wp2'), tests.w('pc_hw')),
  tests.version('core.permit', tests.permit_of(tests.w('wp2'), tests.w('pc_hw'))))::text like '%less notice than the class needs%',
  'a late request cannot be issued without an exception (Q90)');
select tests.login(tests.w('u_op'));
select is(api.request_exception(tests.key(), tests.permit_of(tests.w('wp2'), tests.w('pc_hw')), 'late_notice', 'Bracket failed', '') ->> 'code',
  'invalid_content', 'an exception needs the consequence of waiting (Q94)');
select tests.must(api.request_exception(tests.key(), tests.permit_of(tests.w('wp2'), tests.w('pc_hw')), 'late_notice',
  'A lighting bracket failed overnight', 'The stand cannot open safely without it'));
select tests.login(tests.w('u_a1'));
select is(api.decide_exception(tests.key(), (select id from core.exception_request where kind = 'late_notice'), 'allowed', 'Fine') ->> 'code',
  'no_covering_appointment', 'a tenant administrator cannot allow an exception');
select tests.login(tests.w('u_ivy'));
select tests.must(api.decide_exception(tests.key(), (select id from core.exception_request where kind = 'late_notice'), 'allowed',
  'Genuine failure, reduced scope', 'Brackets on stand 1 only'));
select is(api.issue_permit(tests.key(), tests.permit_of(tests.w('wp2'), tests.w('pc_hw')),
  tests.version('core.permit', tests.permit_of(tests.w('wp2'), tests.w('pc_hw')))) ->> 'ok', 'true',
  'with the exception allowed, it can be issued');

-- A clash with an event restriction, refused.
select tests.login(tests.w('u_a1'));
select tests.set_w('rw', tests.must(api.create_restriction_window(tests.key(), tests.w('v1'), array[tests.w('hall1')], 'decision_required',
  'Exhibitor build: Hall 1 open to the public', now() - interval '2 hours', now() + interval '3 days')));
select tests.set_w('wp3', tests.today_job('Lamps during build', array[tests.w('pc_wah')]));
select tests.approve_permit(tests.permit_of(tests.w('wp3'), tests.w('pc_wa')), '{}');
select tests.login(tests.w('u_ivy'));
select ok(api.issue_permit(tests.key(), tests.permit_of(tests.w('wp3'), tests.w('pc_wa')),
  tests.version('core.permit', tests.permit_of(tests.w('wp3'), tests.w('pc_wa'))))::text like '%clashes with a restriction%',
  'a request that clashes with a restriction cannot be issued without a decision');
select tests.login(tests.w('u_op'));
select tests.must(api.request_exception(tests.key(), tests.permit_of(tests.w('wp3'), tests.w('pc_wa')), 'restriction_conflict',
  'Lamps are failing over stands', 'Stands in the dark during the build', tests.w('rw')));
select tests.login(tests.w('u_ivy'));
select tests.must(api.decide_exception(tests.key(), (select id from core.exception_request where kind = 'restriction_conflict'), 'refused',
  'Do it after the build closes at 22:00'));
select ok(api.issue_permit(tests.key(), tests.permit_of(tests.w('wp3'), tests.w('pc_wa')),
  tests.version('core.permit', tests.permit_of(tests.w('wp3'), tests.w('pc_wa'))))::text like '%clashes with a restriction%',
  'a refused exception leaves it unissuable (scenario 4)');
select tests.login(tests.w('u_a1'));
select tests.must(api.create_restriction_window(tests.key(), tests.w('v1'), array[tests.w('site')], 'no_work', 'Show open: no work anywhere',
  now() - interval '1 hour', now() + interval '3 days'));
select tests.login(tests.w('u_op'));
select is(api.request_exception(tests.key(), tests.permit_of(tests.w('wp3'), tests.w('pc_wa')), 'restriction_conflict', 'Urgent', 'Dark stands',
  (select id from core.restriction_window where effect = 'no_work')) ->> 'code', 'no_work',
  'a no-work restriction cannot be excepted, and it covers areas inside the restricted one');

-- Override prohibited (Q93), physical controls (P5-11) and competence (Q99).
select tests.set_w('cv_hw3', tests.configure_class(tests.w('pc_hw'), jsonb_set(jsonb_set(tests.class_config(
  '[{"key": "hw-review", "name": "Hot works review", "kind": "review", "group": 1}]'), '{notice,amount}', '3'), '{override_prohibited}', 'true')));
select tests.set_w('wp4', tests.today_job('More brackets', array[tests.w('pc_hw')]));
select tests.approve_permit(tests.permit_of(tests.w('wp4'), tests.w('pc_hw')), '{}');
select tests.login(tests.w('u_op'));
select is(api.request_exception(tests.key(), tests.permit_of(tests.w('wp4'), tests.w('pc_hw')), 'late_notice', 'Failed', 'Dark') ->> 'code',
  'override_prohibited', 'no exception at all where the class prohibits it (Q93)');
select tests.login(tests.w('u_a1'));
select tests.set_w('ct', tests.must(api.create_competency_type(tests.key(), tests.w('v1'), 'IPAF', 'IPAF 3a/3b')));
select tests.set_w('cv_wah3', tests.configure_class(tests.w('pc_wah'), jsonb_set(jsonb_set(tests.class_config(
  '[{"key": "rams", "name": "RAMS review", "kind": "review", "group": 1}]',
  '[{"key": "access", "text": "How will people reach the work?", "type": "choose_one", "options": [{"key": "mewp", "text": "MEWP"}, {"key": "scaffold", "text": "Scaffold"}]}]'),
  '{evidence,team_competency_type_ids}', jsonb_build_array(tests.w('ct'))), '{requires_physical_controls}', 'true')));
select tests.set_w('wp5', tests.today_job('High lamps', array[tests.w('pc_wah')]));
select tests.approve_permit(tests.permit_of(tests.w('wp5'), tests.w('pc_wah')), '{"access": ["mewp"]}');
select tests.login(tests.w('u_ivy'));
insert into t_r select 'b5', api.issue_blockers(tests.permit_of(tests.w('wp5'), tests.w('pc_wah')));
select ok((select v::text from t_r where name = 'b5') like '%Oli Operative has no checked IPAF 3a/3b%'
      and (select v::text from t_r where name = 'b5') like '%Owen Operative has no checked IPAF 3a/3b%',
  'every team member needs the class''s checked competency for the dates (Q99)');
select ok((select v::text from t_r where name = 'b5') like '%needs physical controls%',
  'and a class that needs physical controls cannot be issued yet (P5-11)');

-- ---- Issued on the day, not before (Q102, P5-10) ---------------------------------------------------
select tests.set_w('wp7', tests.new_job(tests.wp_input(p_areas => array[tests.w('hall1')], p_title => 'Next week', p_supervisor => tests.w('p_op'))));
select tests.must(tests.answer_and_submit(tests.w('wp7'), tests.no_to_all(), array[tests.w('pc_wah')]));
select tests.login(tests.w('u_op'));
select tests.must(api.start_permits(tests.key(), tests.w('wp7')));
select tests.approve_permit(tests.permit_of(tests.w('wp7'), tests.w('pc_wa')), '{}');
select tests.login(tests.w('u_ivy'));
select ok(api.issue_blockers(tests.permit_of(tests.w('wp7'), tests.w('pc_wa')))::text like '%A permit is issued on the day%',
  'a permit approved in advance is not issued before the start of its first day');

-- ---- Expiry (invariant 10) -----------------------------------------------------------------------
select tests.login(tests.w('u_op'));
select is(api.expire_permits() ->> 'code', 'not_service', 'only the expiry service can expire permits');
select tests.logout();
select tests.set_w('u_exp', tests.new_user('expiry@octra.test'));
insert into core.service_account (auth_user_id, purpose) values (tests.w('u_exp'), 'permit_expiry');
-- A job whose dates have passed: its approved Work Approval expires; running again changes nothing.
select tests.set_w('wp6', tests.new_job(jsonb_set(jsonb_set(tests.wp_input(p_areas => array[tests.w('hall1')], p_title => 'Last week',
  p_supervisor => tests.w('p_op')), '{window_from}', to_jsonb((now() - interval '3 days')::text)), '{window_to}', to_jsonb((now() - interval '2 days')::text))));
select tests.must(tests.answer_and_submit(tests.w('wp6'), tests.no_to_all(), array[tests.w('pc_wah')]));
select tests.login(tests.w('u_op'));
select tests.must(api.start_permits(tests.key(), tests.w('wp6')));
select tests.approve_permit(tests.permit_of(tests.w('wp6'), tests.w('pc_wa')), '{}');
select tests.login(tests.w('u_ivy'));
select ok(api.issue_permit(tests.key(), tests.permit_of(tests.w('wp6'), tests.w('pc_wa')),
  tests.version('core.permit', tests.permit_of(tests.w('wp6'), tests.w('pc_wa'))))::text like '%window has ended%',
  'a permit whose window has ended cannot be issued');
select tests.login(tests.w('u_exp'));
select is((api.expire_permits() ->> 'expired')::int, 1, 'the expiry job expires the permit whose window ended');
select is(tests.status_of(tests.permit_of(tests.w('wp6'), tests.w('pc_wa'))), 'expired', 'which is recorded as expired');
select is((api.expire_permits() ->> 'expired')::int, 0, 'running it again changes nothing');
select is(tests.status_of(tests.w('wa')), 'active', 'and permits still in their window are untouched');

select tests.logout();
select * from finish();
rollback;
