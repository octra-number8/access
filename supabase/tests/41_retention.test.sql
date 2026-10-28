-- Retention, legal holds and disposal 8d(a) (Q218, Q221–Q224, P8-13, P8-14, D-022, invariants 9
-- and 10): an audit log that keeps no record contents (8d-1), a schedule with no default approved
-- by a retention appointee, listing that never disposes, holds requested and approved by different
-- people that never lapse, confirmation by someone other than the schedule's approver with every
-- record checked again, deletes only through a confirmed batch, files removed but records kept, and
-- corrections to live records (8c-5).
begin;
\ir _helpers.psql
\ir _phase2.psql
\ir _phase3.psql
\ir _phase4.psql
select tests.approve_screening();
\ir _phase5.psql
\ir _phase6.psql
\ir _phase6b.psql
select no_plan();

create temp table t_r (name text primary key, v jsonb);
grant all on t_r to authenticated;

-- Test-only: moves timestamps into the past with the table's own triggers switched off (as owner), so periods
-- can run out inside one transaction. Never available to clients.
create function tests.raw(p_sql text) returns void language plpgsql as $$
declare t text := substring(p_sql from 'update ([a-z_.]+) ');
begin
  execute format('alter table %s disable trigger user', t);
  execute p_sql;
  execute format('alter table %s enable trigger user', t);
end $$;
create function tests.batch(p_category text) returns uuid language sql stable security definer as $$
  select id from core.disposal_batch where venue_id = tests.w('v1') and category = p_category and status = 'proposed' $$;
create function tests.listed(p_category text) returns uuid[] language sql stable security definer as $$
  select coalesce(array_agg(root_id order by root_id), '{}') from core.disposal_item where batch_id = tests.batch(p_category) $$;
create function tests.exists_row(p_table regclass, p_id uuid) returns boolean language plpgsql stable as $$
declare n integer;
begin
  execute format('select count(*) from %s where id = $1', p_table) into n using p_id;
  return n > 0;
end $$;
create function tests.batches_at_v1() returns setof uuid language sql stable security definer as $$
  select id from core.disposal_batch where venue_id = tests.w('v1') $$;
grant execute on function tests.batch(text), tests.listed(text), tests.exists_row(regclass, uuid), tests.batches_at_v1() to authenticated;

-- ---- Set-up: retention, hold, correction and gate appointees; a runner ----------------------------------
select tests.set_w('tv_ra', tests.new_type('RA', 'Retention Approver', array['retention.approve', 'retention.dispose'], '{}'));
select tests.set_w('tv_rd', tests.new_type('RD', 'Disposal Officer', array['retention.dispose'], '{}'));
select tests.set_w('tv_lr', tests.new_type('LR', 'Hold Requester', array['legal_hold.request'], '{}'));
select tests.set_w('tv_la', tests.new_type('LA', 'Hold Approver', array['legal_hold.approve', 'legal_hold.request'], '{}'));
select tests.set_w('tv_cr', tests.new_type('CR', 'Records Officer', array['record.correct'], '{}'));
select tests.set_w('tv_aa', tests.new_type('AA', 'Access Authority', array['access.approve', 'venue_config.approve', 'gate.operate',
  'gate.download_manifest', 'gate.submit_fallback', 'gate.reconcile'], '{}'));
select tests.set_w('u_rita', (tests.root_ta('rita@a.test', 'Rita', tests.w('tv_ra'), array[tests.w('pc_wa')], tests.w('site')))[1]);
select tests.set_w('u_dora', (tests.root_ta('dora@a.test', 'Dora', tests.w('tv_rd'), array[tests.w('pc_wa')], tests.w('site')))[1]);
select tests.set_w('u_lena', (tests.root_ta('lena@a.test', 'Lena', tests.w('tv_lr'), array[tests.w('pc_wa')], tests.w('site')))[1]);
select tests.set_w('u_lars', (tests.root_ta('lars@a.test', 'Lars', tests.w('tv_la'), array[tests.w('pc_wa')], tests.w('site')))[1]);
select tests.set_w('u_cora', (tests.root_ta('cora@a.test', 'Cora', tests.w('tv_cr'), array[tests.w('pc_wa')], tests.w('site')))[1]);
select tests.set_w('u_axel', (tests.root_ta('axel@a.test', 'Axel', tests.w('tv_aa'), array[tests.w('pc_wa')], tests.w('site')))[1]);
select tests.set_w('u_run', tests.new_user('runner@octra.test'));
insert into core.service_account (auth_user_id, purpose) values (tests.w('u_run'), 'job_runner');
select tests.set_w('p_rita', (select person_id from core.user_account where auth_user_id = tests.w('u_rita')));
select tests.set_w('p_cora', (select person_id from core.user_account where auth_user_id = tests.w('u_cora')));

-- ---- 8d-1: the audit log records decisions, not record contents ----------------------------------------------
select tests.login(tests.w('u_a1'));
select tests.set_w('p_zed', tests.must(api.create_person(tests.key(), tests.w('cust_a'), 'Zebedee', 'Quarrington', p_email => 'zed@a.test')));
select tests.logout();
select ok((select change ? 'columns' and change ? 'digest' and not change ? 'new' and change::text not like '%Zebedee%' and change::text not like '%Quarrington%'
             from audit.audit_event where target_table = 'core.person' and target_id = tests.w('p_zed') and action = 'row.insert'),
  'a new record''s audit event names its columns and a digest, never its values');
select ok((select change -> 'columns' ? 'given_name' from audit.audit_event where target_table = 'core.person' and target_id = tests.w('p_zed') and action = 'row.insert'),
  'which columns were set is recorded');
select is((select count(*)::int from audit.audit_event where id > (select min(id) from audit.audit_event where target_id = tests.w('p_zed'))
             and change::text like '%zed@a.test%'), 0, 'nor is a contact detail copied anywhere in the log since');
select is(audit.record_matches('core.person', tests.w('p_zed')), true, 'while the record exists, its content can be shown to match the log');
select tests.raw(format($$update core.person set family_name = 'Tampered' where id = %L$$, tests.w('p_zed')));
select is(audit.record_matches('core.person', tests.w('p_zed')), false, 'and a change made outside Octra''s routes is detectable');
select tests.raw(format($$update core.person set family_name = 'Quarrington' where id = %L$$, tests.w('p_zed')));
select is((select count(*)::int from audit.audit_event e where e.decision_context_id is not null and e.action = 'row.insert'
             and e.target_table = 'core.person' and e.target_id = tests.w('p_zed') and e.chain_seq > 0), 1, 'the event still belongs to its decision');

-- ---- Records to keep or dispose of -------------------------------------------------------------------------------
-- Gate: a check for OP with no visit; a visit for Nia with her arrival and departure; a visit awaiting a decision.
select tests.login(tests.w('u_a1'));
select tests.set_w('north', tests.must(api.create_gate_point(tests.key(), tests.w('v1'), tests.w('hall1'), 'North gate')));
insert into t_r select 'card_op', api.issue_card_pass(tests.key(), tests.w('p_op'), tests.w('v1'));
insert into t_r select 'card_nia', api.issue_card_pass(tests.key(), tests.w('p_nia'), tests.w('v1'));
select tests.set_w('pc1', (api.create_venue_config_draft(tests.key(), tests.w('v1'), 'access_purposes') ->> 'id')::uuid);
select tests.must(api.save_venue_config_draft(tests.key(), tests.w('pc1'), tests.version('core.venue_config_version', tests.w('pc1')),
  '{"purposes": [{"key": "survey", "name": "Escorted survey", "allows": "Looking", "prohibits": "Work", "induction_course_ids": [],
    "escort": "never", "occupier_consent": false}]}', 'Test values'));
select tests.must(api.propose_venue_config(tests.key(), tests.w('pc1'), tests.version('core.venue_config_version', tests.w('pc1'))));
select tests.login(tests.w('u_axel'));
select tests.must(api.decide_venue_config(tests.key(), tests.w('pc1'), tests.version('core.venue_config_version', tests.w('pc1')), 'approve', 'Agreed'));
insert into t_r select 'ev_op', api.scan_entry(tests.key(), tests.w('north'), (select v ->> 'payload' from t_r where name = 'card_op'));
select tests.set_w('ev_op', (select (v ->> 'evaluation_id')::uuid from t_r where name = 'ev_op'));
select tests.login(tests.w('u_op'));
select tests.set_w('av1', tests.must(api.request_access(tests.key(), tests.w('v1'), tests.w('org_o'), 'survey', 'Survey the bar', array[tests.w('hall1')],
  now() - interval '1 hour', now() + interval '1 hour', array[tests.w('p_nia')])));
select tests.set_w('av3', tests.must(api.request_access(tests.key(), tests.w('v1'), tests.w('org_o'), 'survey', 'Another survey', array[tests.w('hall1')],
  now() - interval '1 hour', now() + interval '1 hour', array[tests.w('p_nia')])));
select tests.login(tests.w('u_axel'));
select tests.must(api.decide_access(tests.key(), tests.w('av1'), tests.version('core.access_authorisation', tests.w('av1')), 'approve', 'Fine', '{}'));
insert into t_r select 'nia1', api.scan_entry(tests.key(), tests.w('north'), (select v ->> 'payload' from t_r where name = 'card_nia'));
select tests.must(api.record_gate_action(tests.key(), (select (v ->> 'evaluation_id')::uuid from t_r where name = 'nia1'), 'in', 'photo_id', 'admitted'));
insert into t_r select 'nia2', api.scan_entry(tests.key(), tests.w('north'), (select v ->> 'payload' from t_r where name = 'card_nia'));
select tests.must(api.record_gate_action(tests.key(), (select (v ->> 'evaluation_id')::uuid from t_r where name = 'nia2'), 'out', 'photo_id', 'admitted'));
select tests.logout();
select tests.set_w('ev_nia1', (select (v ->> 'evaluation_id')::uuid from t_r where name = 'nia1'));
select tests.set_w('att_nia', (select id from core.visit_attendance where authorisation_id = tests.w('av1')));
select is((select count(*)::int from core.visit_attendance where authorisation_id = tests.w('av1') and left_at is not null), 1, 'Nia came and went on her visit');

-- Outage: a manifest and one fallback entry for a walk-in who was turned away.
select tests.login(tests.w('u_a1'));
select tests.set_w('op1', (api.create_venue_config_draft(tests.key(), tests.w('v1'), 'outage_procedure') ->> 'id')::uuid);
select tests.must(api.save_venue_config_draft(tests.key(), tests.w('op1'), tests.version('core.venue_config_version', tests.w('op1')),
  '{"instruction": "Control room leads.", "steps": ["Check photo ID"], "manifest_max_age_minutes": 60}', 'Test values'));
select tests.must(api.propose_venue_config(tests.key(), tests.w('op1'), tests.version('core.venue_config_version', tests.w('op1'))));
select tests.login(tests.w('u_axel'));
select tests.must(api.decide_venue_config(tests.key(), tests.w('op1'), tests.version('core.venue_config_version', tests.w('op1')), 'approve', 'Agreed'));
select tests.set_w('m1', (api.download_manifest(tests.key(), tests.w('north')) ->> 'manifest_id')::uuid);
select tests.must(api.submit_fallback_entries(tests.key(), tests.w('north'), tests.w('m1'), jsonb_build_array(jsonb_build_object(
  'client_entry_id', gen_random_uuid(), 'recorded_at', clock_timestamp(), 'name_given', 'Walk-in Visitor', 'purpose', 'Asked for a tour',
  'contacted', 'Nobody', 'direction', 'in', 'identity_method', 'photo_id', 'decision', 'refused'))));
select tests.logout();
select tests.login(tests.w('u_axel'));
select tests.set_w('m2', (api.download_manifest(tests.key(), tests.w('north')) ->> 'manifest_id')::uuid);
select tests.must(api.submit_fallback_entries(tests.key(), tests.w('north'), tests.w('m2'), jsonb_build_array(jsonb_build_object(
  'client_entry_id', gen_random_uuid(), 'recorded_at', clock_timestamp(), 'name_given', 'Sam Stranger', 'purpose', 'Delivery',
  'contacted', 'Control room', 'direction', 'in', 'identity_method', 'photo_id', 'decision', 'admitted'))));
select tests.logout();
select tests.set_w('fb1', (select id from core.manual_fallback_entry where name_given = 'Walk-in Visitor'));
select tests.set_w('fb2', (select id from core.manual_fallback_entry where name_given = 'Sam Stranger'));
select is((select count(*)::int from core.reconciliation_exception where fallback_entry_id = tests.w('fb2') and resolved_at is null), 1,
  'an unknown person let in raises an exception, still open');
select is((select count(*)::int from core.reconciliation_exception where fallback_entry_id = tests.w('fb1') and resolved_at is null), 0,
  'a refusal raises no reconciliation exception');

-- Induction: OP completes the core course.
select tests.login(tests.w('u_op'));
select tests.must(api.claim_induction_link(tests.key(), tests.tok_op()));
select tests.set_w('att_op', tests.must(api.start_induction(tests.key(), tests.w('course_core'))));
select tests.must(api.module_progress(tests.key(), tests.w('att_op'), 'm-one', 'start'));
select tests.must(api.module_progress(tests.key(), tests.w('att_op'), 'm-one', 'complete'));
select tests.must(api.answer_question(tests.key(), tests.w('att_op'), 'q-a', array['anyone']));
select tests.must(api.module_progress(tests.key(), tests.w('att_op'), 'm-two', 'start'));
select tests.must(api.module_progress(tests.key(), tests.w('att_op'), 'm-two', 'complete'));
select tests.must(api.answer_question(tests.key(), tests.w('att_op'), 'q-b', array['stop', 'leave']));
select tests.must(api.answer_question(tests.key(), tests.w('att_op'), 'q-c', array['false']));
select tests.must(api.finish_attempt(tests.key(), tests.w('att_op'), tests.version('core.induction_attempt', tests.w('att_op'))));
select tests.set_w('comp_op', (api.complete_induction(tests.key(), tests.w('att_op'), tests.version('core.induction_attempt', tests.w('att_op')),
  array['d-1', 'd-2'], 'Oli Operative') ->> 'completion_id')::uuid);
select tests.logout();
select isnt(tests.w('comp_op'), null, 'OP completed the core induction');

-- Documents: insurance replaced by a second version; a current one-version document; an infected upload.
select tests.set_w('dv_old', ((tests.submit(tests.w('u_op'), 'organisation', tests.w('org_o'), null, tests.w('dt_ins'))) ->> 'id')::uuid);
select tests.scan(tests.w('dv_old'));
select tests.set_w('doc_ins', (select document_id from core.document_version where id = tests.w('dv_old')));
select tests.set_w('dv_new', ((tests.submit(tests.w('u_op'), 'organisation', tests.w('org_o'), null, tests.w('dt_ins'), null, tests.w('doc_ins'))) ->> 'id')::uuid);
select tests.scan(tests.w('dv_new'));
select tests.set_w('dv_card', ((tests.submit(tests.w('u_op'), 'person', tests.w('org_o'), tests.w('p_owen'), tests.w('dt_card'))) ->> 'id')::uuid);
select tests.scan(tests.w('dv_card'));
select tests.set_w('dv_exp', ((tests.submit(tests.w('u_op'), 'organisation', tests.w('org_o'), null, tests.w('dt_ins'), current_date - 60)) ->> 'id')::uuid);
select tests.scan(tests.w('dv_exp'));
select tests.set_w('dv_bad', ((tests.submit(tests.w('u_op'), 'organisation', tests.w('org_o'), null, tests.w('dt_ins'))) ->> 'id')::uuid);
select tests.scan(tests.w('dv_bad'), 'infected');
select is((select version_no from core.document_version where id = tests.w('dv_new')), 2, 'the insurance now has a second version');
select tests.set_w('dv_old2', ((tests.submit(tests.w('u_op'), 'organisation', tests.w('org_o'), null, tests.w('dt_ins'))) ->> 'id')::uuid);
select tests.scan(tests.w('dv_old2'));
select tests.submit(tests.w('u_op'), 'organisation', tests.w('org_o'), null, tests.w('dt_ins'), null, (select document_id from core.document_version where id = tests.w('dv_old2')));
select tests.set_w('dv_cardc', ((tests.submit(tests.w('u_op'), 'person', tests.w('org_o'), tests.w('p_owen'), tests.w('dt_card'))) ->> 'id')::uuid);
select tests.scan(tests.w('dv_cardc'));
select tests.login(tests.w('u_op'));
select tests.must(api.declare_competency(tests.key(), tests.w('p_owen'), tests.w('ct_ipaf'), 'IPAF', 'IP-777', null, tests.w('dv_cardc'), tests.w('org_o')));
select tests.logout();
select tests.submit(tests.w('u_op'), 'person', tests.w('org_o'), tests.w('p_owen'), tests.w('dt_card'), null, (select document_id from core.document_version where id = tests.w('dv_cardc')));

-- Notifications: one already read and not emailed; one whose email is still waiting.
select core.notify(tests.w('cust_a'), tests.w('v1'), array[tests.w('p_op')], 'routine', 'test', 'core.access_authorisation', tests.w('av3'), 'test:n1', 'Old notice', 'Body', null);
select core.notify(tests.w('cust_a'), tests.w('v1'), array[tests.w('p_op')], 'critical', 'test', null, null, 'test:n2', 'Waiting notice', 'Body', null);
select core.notify(tests.w('cust_a'), null, array[tests.w('p_op')], 'routine', 'test', null, null, 'test:n3', 'Customer-wide notice', 'Body', null);
select tests.set_w('n_cw', (select id from core.notification where dedupe_key = 'test:n3'));
select tests.set_w('n_old', (select id from core.notification where dedupe_key = 'test:n1'));
select tests.set_w('n_wait', (select id from core.notification where dedupe_key = 'test:n2'));
select is((select delivery_state from core.notification_delivery where notification_id = tests.w('n_wait')), 'pending', 'one notice''s email is still waiting');

-- Everything above happened ten days ago, except the core induction, which is still current.
select tests.raw(format($$update core.entry_eligibility_evaluation set evaluated_at = evaluated_at - interval '10 days' where venue_id = %L$$, tests.w('v1')));
select tests.raw(format($$update core.access_authorisation set valid_during = tstzrange(lower(valid_during) - interval '10 days', upper(valid_during) - interval '10 days')
                          where id in (%L, %L)$$, tests.w('av1'), tests.w('av3')));
select tests.raw(format($$update core.status_history set at = at - interval '10 days' where record_id in (%L, %L)$$, tests.w('av1'), tests.w('av3')));
select tests.raw(format($$update core.manual_fallback_entry set received_at = received_at - interval '10 days', recorded_at = recorded_at - interval '10 days' where id in (%L, %L)$$,
                        tests.w('fb1'), tests.w('fb2')));
select tests.raw(format($$update core.gate_manifest set made_at = made_at - interval '10 days' where id in (%L, %L)$$, tests.w('m1'), tests.w('m2')));
select tests.raw(format($$update core.notification set created_at = created_at - interval '10 days' where id in (%L, %L, %L)$$, tests.w('n_old'), tests.w('n_wait'), tests.w('n_cw')));
-- And one gate check made just now.
select tests.login(tests.w('u_axel'));
insert into t_r select 'ev_recent', api.scan_entry(tests.key(), tests.w('north'), (select v ->> 'payload' from t_r where name = 'card_op'));
select tests.logout();
select tests.set_w('ev_recent', (select (v ->> 'evaluation_id')::uuid from t_r where name = 'ev_recent'));
select tests.raw(format($$update core.document_version set submitted_at = submitted_at - interval '10 days', scanned_at = scanned_at - interval '10 days'
                          where customer_id = %L$$, tests.w('cust_a')));

-- ---- No schedule, no disposal (CLAUDE.md §9) ------------------------------------------------------------------------
select tests.login(tests.w('u_op'));
select is(api.run_retention_jobs() ->> 'allowed', 'false', 'only the job runner lists records');
select tests.login(tests.w('u_run'));
select tests.must(api.run_retention_jobs());
select is((select count(*)::int from tests.batches_at_v1()), 0, 'with no approved schedule nothing is listed, however old');
select tests.logout();

-- ---- The schedule (Q224, §16.2) ------------------------------------------------------------------------------------
select tests.login(tests.w('u_a1'));
select tests.set_w('rs1', (api.create_venue_config_draft(tests.key(), tests.w('v1'), 'retention') ->> 'id')::uuid);
select is((select content from core.venue_config_version where id = tests.w('rs1')), '{"rules": {}}'::jsonb, 'a first schedule starts empty: no default');
select ok(api.propose_venue_config(tests.key(), tests.w('rs1'), tests.version('core.venue_config_version', tests.w('rs1')))::text like '%at least one category%',
  'an empty schedule cannot be proposed');
select ok(api.save_venue_config_draft(tests.key(), tests.w('rs1'), tests.version('core.venue_config_version', tests.w('rs1')),
  '{"rules": {"everything": {"days": 30, "basis": "x"}}}')::text like '%not a category of record%', 'only the listed categories');
select ok(api.save_venue_config_draft(tests.key(), tests.w('rs1'), tests.version('core.venue_config_version', tests.w('rs1')),
  '{"rules": {"gate_scans": {"days": 0, "basis": "x"}}}')::text like '%1 to 36500%', 'a period of whole days from 1');
select ok(api.save_venue_config_draft(tests.key(), tests.w('rs1'), tests.version('core.venue_config_version', tests.w('rs1')),
  '{"rules": {"gate_scans": {"days": 5, "basis": " "}}}')::text like '%what the period is based on%', 'and what it is based on');
select tests.must(api.save_venue_config_draft(tests.key(), tests.w('rs1'), tests.version('core.venue_config_version', tests.w('rs1')),
  '{"rules": {"gate_scans": {"days": 5, "basis": "Test value"}, "visits": {"days": 5, "basis": "Test value"},
              "gate_outage": {"days": 5, "basis": "Test value"}, "inductions": {"days": 5, "basis": "Test value"},
              "notifications": {"days": 5, "basis": "Test value"}, "document_files": {"days": 5, "basis": "Test value"},
              "rejected_uploads": {"days": 5, "basis": "Test value"}}}', 'Test values, not advice'));
select tests.must(api.propose_venue_config(tests.key(), tests.w('rs1'), tests.version('core.venue_config_version', tests.w('rs1'))));
select tests.login(tests.w('u_run'));
select tests.must(api.run_retention_jobs());
select is((select count(*)::int from tests.batches_at_v1()), 0, 'a proposed schedule disposes of nothing until it is approved');
select tests.login(tests.w('u_a1'));
select is(api.decide_venue_config(tests.key(), tests.w('rs1'), tests.version('core.venue_config_version', tests.w('rs1')), 'approve', 'Mine') ->> 'code',
  'separation_of_duties', 'its author cannot approve the schedule');
select tests.login(tests.w('u_a2'));
select is(api.decide_venue_config(tests.key(), tests.w('rs1'), tests.version('core.venue_config_version', tests.w('rs1')), 'approve', 'Fine') ->> 'code',
  'no_covering_appointment', 'nor another tenant administrator (invariant 9)');
select tests.login(tests.w('u_axel'));
select is(api.decide_venue_config(tests.key(), tests.w('rs1'), tests.version('core.venue_config_version', tests.w('rs1')), 'approve', 'Agreed') ->> 'code',
  'no_covering_appointment', 'nor the general configuration approver: the schedule needs a retention appointee');
select tests.login(tests.w('u_platform'));
select is(api.decide_venue_config(tests.key(), tests.w('rs1'), tests.version('core.venue_config_version', tests.w('rs1')), 'approve', 'Agreed') ->> 'ok',
  'false', 'nor a platform administrator');
select tests.login(tests.w('u_rita'));
select is(api.decide_venue_config(tests.key(), tests.w('rs1'), tests.version('core.venue_config_version', tests.w('rs1')), 'approve', 'Agreed with the adviser') ->> 'ok',
  'true', 'a retention appointee approves it');
select tests.logout();

-- ---- Listing (§16.3): never disposes --------------------------------------------------------------------------------
select tests.login(tests.w('u_run'));
insert into t_r select 'run1', api.run_retention_jobs();
select tests.logout();
select is((select count(*)::int from core.disposal_batch where venue_id = tests.w('v1') and status = 'proposed'), 6, 'six categories have records past their period');
select is(tests.listed('gate_scans'), array[tests.w('ev_op')], 'gate checks: OP''s old one, not one made today nor those recorded against Nia''s visit');
select is(tests.listed('visits'), array[tests.w('av1')], 'visits: the finished one, not the one awaiting a decision');
select is(tests.listed('gate_outage'), array[tests.w('fb1')], 'outage records: the resolved fallback entry, not one with an open exception; the manifest waits');
select is(tests.listed('notifications'), array[tests.w('n_old')],
  'notifications: not one whose email is still waiting, nor a customer-wide one while another venue has no rule (8d-3)');
select is(tests.listed('document_files'), (select array_agg(x order by x) from unnest(array[tests.w('dv_old'), tests.w('dv_old2')]) x),
  'files: the replaced versions, never a current one (even long expired) nor one a competency relies on');
select is(tests.listed('rejected_uploads'), array[tests.w('dv_bad')], 'and the infected upload');
select is(tests.batch('inductions'), null, 'a current induction is never listed');
select ok(tests.exists_row('core.entry_eligibility_evaluation', tests.w('ev_op')) and tests.exists_row('core.access_authorisation', tests.w('av1')),
  'listing deletes nothing');
select is((select count(*)::int from core.notification n where n.event = 'disposal_listed' and n.recipient_person_id = tests.w('p_rita')), 0,
  'the schedule''s approver is not asked to confirm');
select ok((select count(*) from core.notification n join core.user_account ua on ua.person_id = n.recipient_person_id
            where n.event = 'disposal_listed' and ua.auth_user_id = tests.w('u_dora')) = 6, 'disposal appointees are told of each batch');
select tests.login(tests.w('u_run'));
select tests.must(api.run_retention_jobs());
select is((select count(*)::int from tests.batches_at_v1()), 6, 'running the job again lists nothing more');
select tests.logout();

-- ---- Legal holds (Q223, §16.4) ------------------------------------------------------------------------------------
select tests.login(tests.w('u_a1'));
select is(api.request_legal_hold(tests.key(), tests.w('v1'), 'Claim 42', 'Possible claim', current_date + 30, p_person_id => tests.w('p_nia')) ->> 'code',
  'no_covering_appointment', 'a tenant administrator cannot ask for a hold');
select tests.login(tests.w('u_lena'));
select ok(api.request_legal_hold(tests.key(), tests.w('v1'), 'Claim 42', 'Possible claim', current_date) ::text like '%review date after today%',
  'a hold needs a review date after today');
select ok(api.request_legal_hold(tests.key(), tests.w('v1'), 'Claim 42', 'Possible claim', current_date + 30, p_person_id => tests.w('p_b1'))::text
  like '%not one of this customer%', 'and a scope within the customer');
select tests.set_w('lh1', tests.must(api.request_legal_hold(tests.key(), tests.w('v1'), 'Claim 42', 'Nia''s visit may be disputed', current_date + 30,
  p_person_id => tests.w('p_nia'))));
select is(api.decide_legal_hold(tests.key(), tests.w('lh1'), tests.version('core.legal_hold', tests.w('lh1')), 'approve', 'Fine') ->> 'code',
  'separation_of_duties', 'the requester cannot approve it');
select tests.login(tests.w('u_lars'));
select tests.set_w('lh2', tests.must(api.request_legal_hold(tests.key(), tests.w('v1'), 'Incident 7', 'Whole venue', current_date + 30)));
select is(api.decide_legal_hold(tests.key(), tests.w('lh2'), tests.version('core.legal_hold', tests.w('lh2')), 'approve', 'Mine') ->> 'code',
  'separation_of_duties', 'nor can an approver approve a hold they asked for');
select tests.login(tests.w('u_platform'));
select is(api.decide_legal_hold(tests.key(), tests.w('lh1'), tests.version('core.legal_hold', tests.w('lh1')), 'approve', 'Fine') ->> 'ok', 'false',
  'nor a platform administrator');
select tests.login(tests.w('u_lars'));
select is(api.decide_legal_hold(tests.key(), tests.w('lh1'), tests.version('core.legal_hold', tests.w('lh1')), 'approve', 'Claim notified by solicitor') ->> 'ok',
  'true', 'a hold approver approves it');
select tests.logout();
select is((select status from core.legal_hold where id = tests.w('lh1')), 'active', 'it is in force');
select is((select reason from audit.audit_event where target_table = 'core.legal_hold' and target_id = tests.w('lh1') and action = 'row.update'
             order by id desc limit 1), 'Claim notified by solicitor', 'the decision''s reason is kept in the audit log, in words');

-- ---- Confirmation (§16.3, invariant 9) --------------------------------------------------------------------------------
select tests.login(tests.w('u_rita'));
select is(api.decide_disposal_batch(tests.key(), tests.batch('gate_scans'), tests.version('core.disposal_batch', tests.batch('gate_scans')), 'confirm', 'Fine') ->> 'code',
  'separation_of_duties', 'the schedule''s approver cannot confirm a batch under it');
select tests.login(tests.w('u_a1'));
select is(api.decide_disposal_batch(tests.key(), tests.batch('gate_scans'), tests.version('core.disposal_batch', tests.batch('gate_scans')), 'confirm', 'Fine') ->> 'code',
  'no_covering_appointment', 'nor a tenant administrator');
select tests.login(tests.w('u_platform'));
select is(api.decide_disposal_batch(tests.key(), tests.batch('gate_scans'), tests.version('core.disposal_batch', tests.batch('gate_scans')), 'confirm', 'Fine') ->> 'ok',
  'false', 'nor a platform administrator');
select tests.login(tests.w('u_b1'));
select is(api.decide_disposal_batch(tests.key(), tests.batch('gate_scans'), tests.version('core.disposal_batch', tests.batch('gate_scans')), 'confirm', 'Fine') ->> 'ok',
  'false', 'nor another customer (cross-tenant)');
select is(api.retention_overview(tests.w('v1')) ->> 'code', 'not_found', 'who cannot see the schedule either');
select tests.login(tests.w('u_op'));
select is(api.retention_overview(tests.w('v1')) ->> 'code', 'not_found', 'nor can a contractor');
select is(api.legal_holds(tests.w('v1')) ->> 'code', 'not_found', 'or the venue''s holds');
select tests.login(tests.w('u_dora'));
select is(api.decide_disposal_batch(tests.key(), tests.batch('gate_scans'), tests.version('core.disposal_batch', tests.batch('gate_scans')), 'confirm', ' ') ->> 'code',
  'invalid_content', 'a confirmation needs a reason');
select tests.set_w('b_scan', tests.batch('gate_scans'));
insert into t_r select 'd_scan', api.decide_disposal_batch(tests.key(), tests.w('b_scan'), tests.version('core.disposal_batch', tests.w('b_scan')), 'confirm', 'Past the venue''s period');
select is((select (v ->> 'disposed')::int from t_r where name = 'd_scan'), 1, 'a disposal appointee confirms the gate checks');
select tests.logout();
select is(tests.exists_row('core.entry_eligibility_evaluation', tests.w('ev_op')), false, 'OP''s gate check is gone');
select is(tests.exists_row('core.entry_eligibility_evaluation', tests.w('ev_nia1')), true, 'Nia''s, recorded against her visit, is kept');
select is((select count(*)::int from core.disposal_row where batch_id = tests.w('b_scan') and table_name = 'core.entry_eligibility_evaluation'
             and record_id = tests.w('ev_op')), 1, 'the deleted row''s identifier is kept with the batch');
select is((select count(*)::int from audit.record_key where record_id = tests.w('ev_op')), 0, 'its audit key went with it');
select ok((select bool_and(change::text not like '%' || tests.w('p_op')::text || '%') from audit.audit_event
            where target_id = tests.w('ev_op') and action in ('row.insert', 'row.delete')), 'and the log holds none of its content');
select is((select status || '/' || disposed_count || '/' || kept_count from core.disposal_batch where id = tests.w('b_scan')), 'confirmed/1/0', 'the batch records what was done');
select is(api.decide_disposal_batch(tests.key(), tests.w('b_scan'), 1, 'confirm', 'Again') ->> 'ok', 'false', 'a decided batch cannot be decided again');

-- A hold approved after listing keeps Nia's visit at confirmation.
select tests.login(tests.w('u_dora'));
select tests.set_w('b_vis', tests.batch('visits'));
insert into t_r select 'd_vis', api.decide_disposal_batch(tests.key(), tests.w('b_vis'), tests.version('core.disposal_batch', tests.w('b_vis')), 'confirm', 'Past the period');
select tests.logout();
select is((select (v ->> 'disposed')::int || '/' || (v ->> 'kept')::int from t_r where name = 'd_vis'), '0/1', 'the visit is kept at confirmation');
select ok((select kept_reason from core.disposal_item where batch_id = tests.w('b_vis')) like 'A legal hold now covers it: LH-%', 'because a hold now covers it');
select ok(tests.exists_row('core.access_authorisation', tests.w('av1')) and tests.exists_row('core.visit_attendance', tests.w('att_nia')), 'and it is all still there');

-- Nothing deletes a core row any other way, even as the database owner.
select throws_ok(format($$delete from core.notification where id = %L$$, tests.w('n_old')), '42501', null,
  'a direct delete of a core row still fails');
select throws_ok(format($$delete from audit.record_key where record_id = %L$$, tests.w('n_old')), '42501', null, 'so does deleting an audit key');
select throws_ok($$delete from core.disposal_row$$, '42501', null, 'and the record of what was disposed of cannot be deleted');

-- Files: removed from storage, the record kept, never released again. One of the two listed is named
-- by a permit after listing, so it is kept at confirmation.
select tests.set_w('wp_d', tests.today_job('Check the bar', array[tests.w('pc_wah')]));
select tests.set_w('wa_d', tests.permit_of(tests.w('wp_d'), tests.w('pc_wa')));
select tests.login(tests.w('u_op'));
select tests.must(api.save_permit_draft(tests.key(), tests.w('wa_d'), '{}', now() - interval '1 hour', now() + interval '1 day', array[tests.w('dv_old2')]));
select tests.must(api.set_permit_team(tests.key(), tests.w('wa_d'), jsonb_build_array(jsonb_build_object('person_id', tests.w('p_op'), 'role', 'supervisor'))));
select tests.must(api.submit_permit(tests.key(), tests.w('wa_d'), tests.version('core.permit', tests.w('wa_d'))));
select tests.login(tests.w('u_dora'));
insert into t_r select 'd_files', api.decide_disposal_batch(tests.key(), tests.batch('document_files'), tests.version('core.disposal_batch', tests.batch('document_files')), 'confirm', 'Replaced');
select tests.logout();
select is((select (v ->> 'disposed')::int || '/' || (v ->> 'kept')::int from t_r where name = 'd_files'), '1/1', 'one file is disposed of, one kept');
select is((select kept_reason from core.disposal_item where root_id = tests.w('dv_old2')), 'It can no longer be disposed of: its state changed after it was listed.',
  'the one a permit now names is kept, and the batch says why');
select tests.login(tests.w('u_dora'));
select tests.must(api.decide_disposal_batch(tests.key(), tests.batch('rejected_uploads'), tests.version('core.disposal_batch', tests.batch('rejected_uploads')), 'confirm', 'Infected'));
select tests.logout();
select ok(tests.exists_row('core.document_version', tests.w('dv_old')), 'the replaced version''s record stays');
select tests.login(tests.w('u_op'));
select is(api.document_access(tests.w('dv_old')) ->> 'code', 'disposed', 'its file is never released again');
select ok(api.document_access(tests.w('dv_old')) ->> 'reason' like 'This file was removed under the venue''s retention schedule on %', 'and the reason says why');
select is(api.document_access(tests.w('dv_new')) ->> 'ok', 'true', 'the current version still is');
select is(api.claim_file_removals() ->> 'allowed', 'false', 'only the job runner removes files');
select tests.login(tests.w('u_run'));
insert into t_r select 'claim', api.claim_file_removals();
select is((select jsonb_array_length(v -> 'files') from t_r where name = 'claim'), 2, 'the runner claims both files to remove');
select is(jsonb_array_length(api.claim_file_removals() -> 'files'), 0, 'a claimed file is not handed out twice');
select tests.must(api.record_file_removal(((select v -> 'files' -> 0 ->> 'id' from t_r where name = 'claim'))::uuid, true));
select tests.must(api.record_file_removal(((select v -> 'files' -> 1 ->> 'id' from t_r where name = 'claim'))::uuid, false, 'storage unavailable'));
select tests.logout();
select is((select count(*)::int from core.file_disposal where document_version_id in (tests.w('dv_old'), tests.w('dv_bad')) and removed_at is not null), 1,
  'one removal is recorded');
select is((select count(*)::int from core.file_disposal where document_version_id in (tests.w('dv_old'), tests.w('dv_bad')) and removed_at is null
             and last_error = 'storage unavailable'), 1, 'the other waits to be retried, with its error');

-- Notifications: the schedule changes after listing, so the notice is kept at confirmation.
select tests.login(tests.w('u_a1'));
select tests.set_w('rs2', (api.create_venue_config_draft(tests.key(), tests.w('v1'), 'retention') ->> 'id')::uuid);
select tests.must(api.save_venue_config_draft(tests.key(), tests.w('rs2'), tests.version('core.venue_config_version', tests.w('rs2')),
  jsonb_set((select content from core.venue_config_version where id = tests.w('rs1')), '{rules,notifications,days}', '60'), 'Test values, version 2'));
select tests.must(api.propose_venue_config(tests.key(), tests.w('rs2'), tests.version('core.venue_config_version', tests.w('rs2'))));
select tests.login(tests.w('u_rita'));
select tests.must(api.decide_venue_config(tests.key(), tests.w('rs2'), tests.version('core.venue_config_version', tests.w('rs2')), 'approve', 'Longer for notices'));
select tests.login(tests.w('u_dora'));
insert into t_r select 'd_not', api.decide_disposal_batch(tests.key(), tests.batch('notifications'), tests.version('core.disposal_batch', tests.batch('notifications')), 'confirm', 'Past period');
select tests.logout();
select is((select (v ->> 'disposed')::int || '/' || (v ->> 'kept')::int from t_r where name = 'd_not'), '0/1', 'the notice is kept');
select is((select kept_reason from core.disposal_item where root_id = tests.w('n_old')), 'Under the schedule in force now it is not yet past its period.',
  'because the schedule in force now keeps it longer');

-- Outage records.
select tests.login(tests.w('u_dora'));
select tests.must(api.decide_disposal_batch(tests.key(), tests.batch('gate_outage'), tests.version('core.disposal_batch', tests.batch('gate_outage')), 'confirm', 'Past period'));
select tests.logout();
select ok(tests.exists_row('core.notification', tests.w('n_old')) and tests.exists_row('core.notification', tests.w('n_wait')), 'both notices are still there');
select ok(not tests.exists_row('core.manual_fallback_entry', tests.w('fb1')) and tests.exists_row('core.gate_manifest', tests.w('m1')),
  'the fallback entry is gone; its manifest stays until it is listed in turn');
select tests.login(tests.w('u_run'));
insert into t_r select 'run_m', api.run_retention_jobs();
select tests.logout();
select is(tests.batch('gate_outage'), null, 'the manifest lists Nia, so the hold on her keeps it back too');
select ok((select (v ->> 'held_back')::int from t_r where name = 'run_m') >= 1, 'and the run counts what holds kept back');
create function tests.hold_check(p_category text) returns core.retention_hold_check language sql stable security definer as $$
  select * from core.retention_hold_check where venue_id = tests.w('v1') and category = p_category $$;
create function tests.kept_back(p_category text) returns jsonb language sql stable as $$
  select c -> 'kept_back' from jsonb_array_elements(api.retention_overview(tests.w('v1')) -> 'categories') c where c ->> 'code' = p_category $$;
grant execute on function tests.hold_check(text), tests.kept_back(text) to authenticated;
select is((tests.hold_check('gate_outage')).held_count, 1, '8d-12: the run records, per category, how many records holds kept back');
select is((tests.hold_check('gate_outage')).held_back, jsonb_build_array(jsonb_build_object('hold_id', tests.w('lh1'),
            'reference', (select reference from core.legal_hold where id = tests.w('lh1')), 'matter', 'Claim 42', 'count', 1)),
  'and which holds, with how many each');
select is((tests.hold_check('visits')).held_count, 1, 'Nia''s visit is kept back too');
select is((tests.hold_check('notifications')).held_count, 0, 'a category whose records no hold covers records none');
insert into t_r select 'hc_visits', to_jsonb((tests.hold_check('visits')).changed_at);
select tests.login(tests.w('u_dora'));
select is(tests.kept_back('visits') ->> 'count', '1', 'the retention page shows it to the disposal officer');
select is(tests.kept_back('visits') -> 'holds' -> 0 ->> 'matter', 'Claim 42', 'with the hold''s matter');
select is(tests.kept_back('notifications'), 'null'::jsonb, 'and nothing for a category with nothing kept back');
select tests.login(tests.w('u_a1'));
select is((select count(*)::int from jsonb_array_elements(api.retention_overview(tests.w('v2')) -> 'categories') c where c -> 'kept_back' <> 'null'::jsonb), 0,
  'another venue of the customer shows nothing kept back by V1''s holds');
select tests.login(tests.w('u_op'));
select is(api.retention_overview(tests.w('v1')) ->> 'code', 'not_found', 'a contractor sees none of it');
select tests.logout();

-- Inductions: once OP's completion has expired, it is listed with its attempt.
select tests.raw(format($$update core.induction_completion set completed_at = now() - interval '20 days', valid_until = now() - interval '10 days' where id = %L$$, tests.w('comp_op')));
select tests.login(tests.w('u_run'));
select tests.must(api.run_retention_jobs());
select tests.logout();
select is(tests.listed('inductions'), array[tests.w('comp_op')], 'an expired induction is listed');
select tests.login(tests.w('u_dora'));
select tests.must(api.decide_disposal_batch(tests.key(), tests.batch('inductions'), tests.version('core.disposal_batch', tests.batch('inductions')), 'confirm', 'Expired'));
select tests.logout();
select ok(not tests.exists_row('core.induction_completion', tests.w('comp_op')) and not tests.exists_row('core.induction_attempt', tests.w('att_op')),
  'the completion and its attempt are gone');
select is((select count(*)::int from core.question_response where attempt_id = tests.w('att_op')), 0, 'with its answers');

-- ---- Holds never lapse (invariant 10); lifting lets disposal resume ------------------------------------------------------
select tests.raw(format($$update core.legal_hold set review_on = current_date - 1 where id = %L$$, tests.w('lh1')));
select tests.login(tests.w('u_run'));
insert into t_r select 'run_r', api.run_retention_jobs();
select tests.logout();
select is((select count(*)::int from core.notification where event = 'legal_hold_review' and record_id = tests.w('lh1')), 2,
  'a hold at its review date tells its requester and approver');
select is((select status from core.legal_hold where id = tests.w('lh1')), 'active', 'and stays in force');
select is(tests.batch('visits'), null, 'it still keeps Nia''s visit from being listed');
select is(to_jsonb((tests.hold_check('visits')).changed_at), (select v from t_r where name = 'hc_visits'),
  'a run that finds the same picture writes nothing (the job runs every minute)');
select tests.login(tests.w('u_lars'));
select ok(api.renew_legal_hold(tests.key(), tests.w('lh1'), current_date, 'Still open')::text like '%review date after today%', 'a renewal needs a later date');
select tests.must(api.renew_legal_hold(tests.key(), tests.w('lh1'), current_date + 60, 'Claim still open'));
select is(api.lift_legal_hold(tests.key(), tests.w('lh1'), tests.version('core.legal_hold', tests.w('lh1')), ' ') ->> 'code', 'invalid_content', 'lifting needs a reason');
select tests.must(api.lift_legal_hold(tests.key(), tests.w('lh1'), tests.version('core.legal_hold', tests.w('lh1')), 'Claim withdrawn'));
select tests.login(tests.w('u_run'));
select tests.must(api.run_retention_jobs());
select tests.logout();
select is(tests.listed('visits'), array[tests.w('av1')], 'once the hold is lifted, the visit is listed again');
select is((tests.hold_check('visits')).held_count, 0, 'and nothing is recorded as kept back any more');
select is((tests.hold_check('visits')).held_back, '[]'::jsonb, 'by any hold');
select tests.login(tests.w('u_dora'));
select is(tests.kept_back('visits'), 'null'::jsonb, 'so the page no longer shows it');
select tests.logout();
select tests.login(tests.w('u_dora'));
select tests.must(api.decide_disposal_batch(tests.key(), tests.batch('visits'), tests.version('core.disposal_batch', tests.batch('visits')), 'confirm', 'Past the period'));
select tests.logout();
select ok(not tests.exists_row('core.access_authorisation', tests.w('av1')) and not tests.exists_row('core.visit_attendance', tests.w('att_nia'))
          and not tests.exists_row('core.entry_eligibility_evaluation', tests.w('ev_nia1')),
  'the visit goes with its attendance and the gate checks recorded against it');
select ok(tests.exists_row('core.access_authorisation', tests.w('av3')), 'the visit awaiting a decision stays');
select is(tests.listed('gate_outage'), array[tests.w('m1')], 'with the hold lifted and nothing naming it, the manifest is listed');

-- A declined batch is not listed again under the same schedule.
select tests.login(tests.w('u_dora'));
select tests.must(api.decide_disposal_batch(tests.key(), tests.batch('gate_outage'), tests.version('core.disposal_batch', tests.batch('gate_outage')), 'decline',
  'Keep while the outage review is open'));
select tests.login(tests.w('u_run'));
select tests.must(api.run_retention_jobs());
select tests.logout();
select is(tests.batch('gate_outage'), null, 'a declined record is not listed again under the same schedule');
select ok(tests.exists_row('core.gate_manifest', tests.w('m1')), 'and stays');
select is((select string_agg(distinct kept_reason, ',') from core.disposal_item i join core.disposal_batch b on b.id = i.batch_id
            where b.status = 'declined' and b.venue_id = tests.w('v1')), 'The batch was declined: Keep while the outage review is open', 'with the reason recorded');

-- ---- Corrections to live records (8c-5, §16.5) ---------------------------------------------------------------------------
select tests.login(tests.w('u_a2'));
select is(api.correct_record(tests.key(), tests.w('v1'), 'person', tests.w('p_owen'), 'family_name', 'Operativo', 'Misspelt', 'Passport seen') ->> 'code',
  'no_covering_appointment', 'a tenant administrator cannot record a correction');
select tests.login(tests.w('u_cora'));
select is(api.correct_record(tests.key(), tests.w('v1'), 'person', tests.w('p_cora'), 'family_name', 'Other', 'Mine', 'Me') ->> 'code',
  'separation_of_duties', 'nobody corrects their own details');
select ok(api.correct_record(tests.key(), tests.w('v1'), 'person', tests.w('p_owen'), 'family_name', 'Operative', 'x', 'y')::text like '%same as what the record says%',
  'a correction must change something');
select ok(api.correct_record(tests.key(), tests.w('v1'), 'person', tests.w('p_owen'), 'deactivated_at', 'x', 'x', 'y')::text like '%cannot be corrected here%',
  'only the listed details');
select tests.must(api.correct_record(tests.key(), tests.w('v1'), 'person', tests.w('p_owen'), 'family_name', 'Operativo', 'Misspelt at invitation', 'Passport seen at the gate'));
select tests.must(api.correct_record(tests.key(), tests.w('v1'), 'organisation', tests.w('org_o'), 'company_number', '09876543', 'Typo', 'Companies House'));
select ok(api.correct_record(tests.key(), tests.w('v1'), 'document_version', tests.w('dv_new'), 'expires_on', '31/12/2027', 'x', 'y')::text like '%YYYY-MM-DD%',
  'dates are given unambiguously');
select tests.must(api.correct_record(tests.key(), tests.w('v1'), 'document_version', tests.w('dv_new'), 'expires_on', '2027-12-31', 'Certificate says so', 'The certificate'));
select tests.logout();
select is((select family_name from core.person where id = tests.w('p_owen')), 'Operativo', 'a person''s detail is corrected');
select is((select company_number from core.organisation where id = tests.w('org_o')), '09876543', 'and an organisation''s');
select is((select expires_on from core.document_version where id = tests.w('dv_new')), null::date,
  'an evidence file''s recorded details are never changed: the reviewer relied on them as submitted (8d-6)');
select is((select string_agg(was || '>' || corrected, ',' order by created_at) from core.correction
             where target_id in (tests.w('p_owen'), tests.w('org_o'), tests.w('dv_new'))),
  'Operative>Operativo,' || coalesce((select was from core.correction where target_id = tests.w('org_o')), '?') || '>09876543,(blank)>2027-12-31',
  'each correction keeps what the record said and the correct value');
select ok((select change -> 'columns' ? 'family_name' and change::text not like '%Operativ%' from audit.audit_event
            where target_table = 'core.person' and target_id = tests.w('p_owen') and action = 'row.update' order by id desc limit 1),
  'the log records which detail changed, not its old or new value');
select tests.login(tests.w('u_op'));
select is(jsonb_array_length(api.record_corrections('organisation', tests.w('org_o')) -> 'corrections'), 1, 'the organisation sees its correction');
select is(api.record_corrections('organisation', tests.w('org_o'), tests.w('v1')) ->> 'can_correct', 'false', 'but cannot correct');
select tests.login(tests.w('u_b1'));
select is(api.record_corrections('organisation', tests.w('org_o')) ->> 'code', 'not_found', 'another customer sees nothing');
select tests.logout();

select * from finish();
rollback;
