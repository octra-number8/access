-- Notifications and scheduled jobs 8a (Q206, Q207, Q210, P8-2 to P8-6, invariants 1, 9, 10):
-- notices written with their decision to people resolved from the record and appointments,
-- the critical class that cannot be switched off, personal choice for routine notices,
-- decisions due, chasing with no default, email delivery with retries, and the job runner.
begin;
\ir _helpers.psql
\ir _phase3.psql
\ir _phase4.psql
select tests.approve_screening();
\ir _phase5.psql
\ir _phase6.psql
\ir _phase6b.psql
select no_plan();

create temp table t_r (name text primary key, v jsonb);
grant all on t_r to authenticated;

-- Service accounts for the runner and the sender.
select tests.set_w('u_runner', tests.new_user('runner@octra.test'));
select tests.set_w('u_sender', tests.new_user('sender@octra.test'));
insert into core.service_account (auth_user_id, purpose) values (tests.w('u_runner'), 'job_runner'), (tests.w('u_sender'), 'notification_sender');

create function tests.notices(p_person uuid, p_event text) returns integer language sql stable security definer as $$
  select count(*)::int from core.notification where recipient_person_id = p_person and event = p_event $$;
grant execute on function tests.notices(uuid, text) to authenticated;

-- ---- A stop is critical, written with the decision, to the permit's owners (P8-2, P8-3) -------------
select tests.set_w('wp', tests.live_job('Lamps today'));
select tests.set_w('wah', tests.permit_of(tests.w('wp'), tests.w('pc_wah')));
select is(tests.notices(tests.w('p_op'), 'issued_awaiting_acceptance') >= 1, true,
  'the supervisor was told each permit was issued and awaits acceptance (routine)');
select tests.login(tests.w('u_platform'));
select is(api.stop_work(tests.key(), tests.w('wah'), 'weather', 'Wind') ->> 'ok', 'false', 'a platform administrator cannot stop work');
select is(tests.notices(tests.w('p_ivy'), 'work_stopped'), 0, 'and a refused decision notifies nobody');
select tests.login(tests.w('u_op'));
select tests.must(api.stop_work(tests.key(), tests.w('wah'), 'weather', 'Gusts over the limit'));
select is(tests.notices(tests.w('p_ivy'), 'work_stopped'), 2, 'the issuer is told, once for each permit stopped (the work at height and its Work Approval)');
select tests.logout();
select is(tests.notices(tests.w('p_op'), 'work_stopped'), 0, 'not the supervisor who stopped it: they know');
select is((select string_agg(distinct class, ',') from core.notification where recipient_person_id = tests.w('p_ivy') and event = 'work_stopped'), 'critical', 'as a critical notice');
select ok((select bool_and(body like '%Gusts over the limit%the venue''s direct route (control room, supervisor) still applies.') from core.notification where recipient_person_id = tests.w('p_ivy') and event = 'work_stopped'),
  'saying why, and that the direct route still applies');
-- '%Gusts over the limit%the venue''s direct route (control room, supervisor) still applies.', 'saying why, and that the direct route still applies');
select is((select string_agg(distinct d.channel || ':' || d.delivery_state, ',') from core.notification_delivery d join core.notification n on n.id = d.notification_id
            where n.recipient_person_id = tests.w('p_ivy') and n.event = 'work_stopped'), 'email:pending', 'and it is queued for email');

-- ---- Critical cannot be switched off; routine follows the person's choice (P8-3, P8-4, Q210) -----------------
select tests.login(tests.w('u_ivy'));
select tests.must(api.set_notification_preference('in_app'));
select is(api.set_notification_preference('sms') ->> 'code', 'invalid_content', 'only in Octra, email, or a daily email');
select tests.login(tests.w('u_op'));
select tests.must(api.set_notification_preference('digest'));
select tests.login(tests.w('u_ivy'));
select tests.set_w('wp2', tests.live_job('Second job'));
select tests.logout();
select is((select bool_and(d.channel = 'digest') from core.notification_delivery d join core.notification n on n.id = d.notification_id
            where n.recipient_person_id = tests.w('p_op') and n.event = 'issued_awaiting_acceptance' and n.created_at > now() - interval '0 s'
              and n.record_id in (select id from core.permit where work_package_id = tests.w('wp2'))), true,
  'routine notices to someone who chose a daily email wait for the digest');
select is((select count(*)::int from core.notification_delivery d join core.notification n on n.id = d.notification_id
            where n.recipient_person_id = tests.w('p_ivy') and n.class = 'routine'), 0,
  'and to someone who chose Octra only, they are not emailed at all');

-- ---- The inbox is the person's own -------------------------------------------------------------------------------
select tests.logout();
create temp table t_ivy as select id from core.notification where recipient_person_id = tests.w('p_ivy');
grant select on t_ivy to authenticated;
select tests.login(tests.w('u_op'));
select is((select count(*)::int from api.notification where recipient_person_id = tests.w('p_ivy')), 0, 'nobody sees another person''s notices');
select is((api.mark_notifications_read(array(select id from t_ivy))) ->> 'marked', '0', 'or marks them read');
select tests.login(tests.w('u_b1'));
select is((select count(*)::int from api.notification), 0, 'nor does another tenant');
select tests.login(tests.w('u_ivy'));
select ok((select count(*)::int from api.notification) > 0, 'the recipient sees them');
select is((api.mark_notifications_read(array(select id from api.notification))) ->> 'marked', (select count(*)::text from api.notification),
  'and marks them read');
select is((select status from core.permit where id = tests.w('wah')), 'suspended', 'reading a notice changes nothing on the record');

-- ---- Jobs only as the runner; re-running sends nothing twice (P8-6) ----------------------------------------------
select tests.login(tests.w('u_platform'));
select is(api.run_notification_jobs() ->> 'allowed', 'false', 'a platform administrator cannot run the jobs');
select tests.login(tests.w('u_a1'));
select is(api.run_notification_jobs() ->> 'allowed', 'false', 'nor a tenant administrator');
select tests.login(tests.w('u_sender'));
select is(api.run_notification_jobs() ->> 'allowed', 'false', 'nor the sender: each service does only its own work');

-- A job submitted for review: its reviewer is told a decision is due.
select tests.set_w('wp3', tests.today_job('Third job', array[tests.w('pc_wah')]));
select tests.login(tests.w('u_op'));
select tests.must(api.save_permit_draft(tests.key(), tests.permit_of(tests.w('wp3'), tests.w('pc_wa')), '{}', now() - interval '1 hour', now() + interval '1 day'));
select tests.must(api.set_permit_team(tests.key(), tests.permit_of(tests.w('wp3'), tests.w('pc_wa')),
  jsonb_build_array(jsonb_build_object('person_id', tests.w('p_op'), 'role', 'supervisor'))));
select tests.must(api.submit_permit(tests.key(), tests.permit_of(tests.w('wp3'), tests.w('pc_wa')),
  tests.version('core.permit', tests.permit_of(tests.w('wp3'), tests.w('pc_wa')))));
select tests.login(tests.w('u_runner'));
insert into t_r select 'run1', api.run_notification_jobs();
select ok((select (v ->> 'decisions_due')::int from t_r where name = 'run1') > 0, 'the runner tells the people who can decide the open steps');
select is(tests.notices(tests.w('p_pam'), 'decision_due') > 0, true, 'Pam, the appointed reviewer, among them');
select is(tests.notices(tests.w('p_op'), 'decision_due'), 0, 'never someone connected with the job (they cannot decide it)');
select is(tests.notices(tests.w('p_a1'), 'decision_due'), 0, 'nor a tenant administrator (invariant 9)');
select is(tests.notices(tests.w('p_ivy'), 'decision_due'), 0, 'nor an appointee whose appointment does not cover the decision (the issuer)');
select tests.logout();
select is((select bool_or(tests.w('p_pam') = any (core.action_holders(core.step_action(s.kind),
             core.step_target(s, p, s.id) || jsonb_build_object('excluded_person_ids', jsonb_build_array(tests.w('p_pam'))))))
             from core.permit p join core.permit_step s on s.permit_version_id = p.current_version_id
            where p.id = tests.permit_of(tests.w('wp3'), tests.w('pc_wa'))), false,
  'someone excluded from a decision (connected with the job) is never told it is theirs');
select tests.login(tests.w('u_runner'));
insert into t_r select 'run2', api.run_notification_jobs();
select is((select (v ->> 'decisions_due')::int + (v ->> 'reminders')::int + (v ->> 'escalations')::int from t_r where name = 'run2'), 0,
  'running the job again sends nothing twice');
select tests.logout();
select is((select count(*)::int from core.job_run where job = 'notifications' and outcome = 'ok' and run_by_user_id = tests.w('u_runner')), 2, 'each run is logged');
select tests.login(tests.w('u_a1'));
select is((select count(*)::int from api.job_run), 0, 'job runs are for platform operations only');

-- ---- Chasing has no default (P8-5, Q207) ---------------------------------------------------------------------------
select is((select (v ->> 'reminders')::int from t_r where name = 'run1'), 0, 'with no chasing configured, nothing is chased');
select tests.set_w('ch1', (api.create_venue_config_draft(tests.key(), tests.w('v1'), 'chasing') ->> 'id')::uuid);
select ok(api.propose_venue_config(tests.key(), tests.w('ch1'), tests.version('core.venue_config_version', tests.w('ch1')))::text
  like '%at least one kind%', 'the venue chooses what to chase');
select is(api.save_venue_config_draft(tests.key(), tests.w('ch1'), tests.version('core.venue_config_version', tests.w('ch1')),
  '{"items": {"approval_step": {"remind_every_hours": 4}}}') ->> 'code', 'invalid_content', 'and must say whether, and when, to escalate');
select is(api.save_venue_config_draft(tests.key(), tests.w('ch1'), tests.version('core.venue_config_version', tests.w('ch1')),
  '{"items": {"approval_step": {"remind_every_hours": 4, "escalate_after_hours": 8, "escalate_to": {"person_ids": [], "appointment_type_ids": []}}}}') ->> 'code',
  'invalid_content', 'and to whom');
select tests.must(api.save_venue_config_draft(tests.key(), tests.w('ch1'), tests.version('core.venue_config_version', tests.w('ch1')),
  jsonb_build_object('items', jsonb_build_object(
    'approval_step', jsonb_build_object('remind_every_hours', 4, 'escalate_after_hours', 8,
                                        'escalate_to', jsonb_build_object('person_ids', jsonb_build_array(tests.w('p_ivy')), 'appointment_type_ids', '[]'::jsonb)),
    'hand_back', jsonb_build_object('remind_every_hours', 2, 'escalate_after_hours', null)))));
select tests.must(api.propose_venue_config(tests.key(), tests.w('ch1'), tests.version('core.venue_config_version', tests.w('ch1'))));
select is(api.decide_venue_config(tests.key(), tests.w('ch1'), tests.version('core.venue_config_version', tests.w('ch1')), 'approve', 'Mine') ->> 'code',
  'separation_of_duties', 'its author cannot approve it');
select tests.login(tests.w('u_pam'));
select is(api.decide_venue_config(tests.key(), tests.w('ch1'), tests.version('core.venue_config_version', tests.w('ch1')), 'approve', 'Agreed') ->> 'ok', 'false',
  'and nor can someone without the appointment');
select tests.set_w('tv_cfg', tests.new_type('CFG', 'Configuration Approver', array['venue_config.approve'], '{}'));
select tests.set_w('u_cora', (tests.root_ta('cora@a.test', 'Cora', tests.w('tv_cfg'), array[tests.w('pc_wa')], tests.w('site')))[1]);
select tests.login(tests.w('u_cora'));
select tests.must(api.decide_venue_config(tests.key(), tests.w('ch1'), tests.version('core.venue_config_version', tests.w('ch1')), 'approve', 'Agreed'));

select tests.login(tests.w('u_runner'));
insert into t_r select 'run_early', api.run_notification_jobs();
select is((select (v ->> 'reminders')::int + (v ->> 'escalations')::int from t_r where name = 'run_early'), 0,
  'nothing is chased or escalated before its time');

-- Nine hours later: two reminders due, and the escalation. The decision stays where it is.
select tests.logout();
alter table core.permit_version disable trigger user;
update core.permit_version set created_at = now() - interval '9 hours' where id = (select current_version_id from core.permit where id = tests.permit_of(tests.w('wp3'), tests.w('pc_wa')));
alter table core.permit_version enable trigger user;
select tests.login(tests.w('u_runner'));
insert into t_r select 'run3', api.run_notification_jobs();
select ok((select (v ->> 'reminders')::int from t_r where name = 'run3') > 0, 'the owners are reminded');
select is(tests.notices(tests.w('p_ivy'), 'escalation') > 0, true, 'and after the escalation time, the named contact is told');
select is(tests.status_of(tests.permit_of(tests.w('wp3'), tests.w('pc_wa'))), 'submitted', 'escalation changes nothing on the record (invariant 10)');
insert into t_r select 'run4', api.run_notification_jobs();
select is((select (v ->> 'reminders')::int + (v ->> 'escalations')::int from t_r where name = 'run4'), 0, 'and a re-run repeats nothing');

-- ---- A restriction affecting live work is critical, told without its grounds ------------------------------------------
select tests.login(tests.w('u_r'));
select tests.must(api.impose_restriction(tests.key(), tests.w('v1'), 'person', tests.w('p_owen'), 'Confidential HR matter'));
select tests.logout();
select is((select d.channel from core.notification_delivery d join core.notification n on n.id = d.notification_id
            where n.recipient_person_id = tests.w('p_ivy') and n.event = 'restriction_live_work' limit 1), 'email',
  'a critical notice is emailed even to someone who chose Octra only');
select ok((select bool_and(body not like '%Confidential HR matter%') from core.notification where event = 'restriction_live_work'),
  'a restriction is told as a fact, never its grounds');
select is(tests.notices(tests.w('p_r'), 'restriction_live_work'), 0, 'and not to the person who imposed it');

-- ---- Email: claimed by the sender, retried, then failed (P8-6) -------------------------------------------------------
select tests.login(tests.w('u_runner'));
select is(api.claim_email_batch(10) ->> 'allowed', 'false', 'only the sender claims email');
select tests.login(tests.w('u_sender'));
insert into t_r select 'mail1', api.claim_email_batch(50);
select ok((select jsonb_array_length(v -> 'emails') from t_r where name = 'mail1') > 0, 'the sender claims what is due');
select ok((select bool_and(e ->> 'to' like '%@%') from t_r, jsonb_array_elements(v -> 'emails') e where name = 'mail1'), 'with each recipient''s address');
select ok((select bool_and(e ->> 'subject' like '[Critical]%') from t_r, jsonb_array_elements(v -> 'emails') e where name = 'mail1' and e ->> 'class' = 'critical'),
  'critical subjects say so');
select is(jsonb_array_length(api.claim_email_batch(50) -> 'emails'), 0, 'a claimed email is not claimed twice while leased');
create temp table t_mail as select (e #>> '{delivery_ids,0}')::uuid id, row_number() over () n from t_r, jsonb_array_elements(v -> 'emails') e where name = 'mail1';
grant select on t_mail to authenticated;
select tests.set_w('d_fail', (select id from t_mail where n = 1));
select tests.must(api.record_email_result(array(select id from t_mail where n > 1), true));
select tests.logout();
select is((select count(*)::int from core.notification_delivery where delivery_state = 'sent' and id in (select id from t_mail)), (select count(*)::int - 1 from t_mail),
  'sent ones are recorded as sent');
select tests.login(tests.w('u_sender'));
select tests.must(api.record_email_result(array[tests.w('d_fail')], false, 'SMTP 451 try later'));
select tests.logout();
select is((select delivery_state || ':' || (next_attempt_at > now())::text from core.notification_delivery where id = tests.w('d_fail')), 'pending:true',
  'a failure is retried later');
select tests.logout();
update core.notification_delivery set attempts = 5 where id = tests.w('d_fail');
select tests.login(tests.w('u_sender'));
select tests.must(api.record_email_result(array[tests.w('d_fail')], false, 'SMTP 550 no such user'));
select tests.logout();
select is((select delivery_state from core.notification_delivery where id = tests.w('d_fail')), 'failed', 'and after five attempts it stays failed, for operations to see');
select is((select count(*)::int from core.notification where id = (select notification_id from core.notification_delivery where id = tests.w('d_fail'))), 1,
  'the notice itself stays in the inbox');

-- ---- Nobody writes notices directly ---------------------------------------------------------------------------------
select tests.login(tests.w('u_op'));
select throws_ok($$ insert into core.notification (customer_id, recipient_person_id, class, event, dedupe_key, subject, body)
                    values (gen_random_uuid(), gen_random_uuid(), 'critical', 'x', 'x', 'x', 'x') $$, '42501', null, 'no one writes a notification directly');
select throws_ok($$ select core.notify(null, null, null, 'critical', 'x', null, null, 'x', 'x', 'x', null) $$, '42501', null, 'or calls the outbox');

select * from finish();
rollback;
