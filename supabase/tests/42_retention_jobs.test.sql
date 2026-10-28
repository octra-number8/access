-- Retention 8d(b) (8d-2, 8d-4, 8d-11, invariants 5, 8 and 10): a closed job is disposed of whole,
-- with its permits, decisions, snapshots, packs and pack files, corrections and the controls only it
-- used; never while a permit is unfinished or a control unresolved, never under a hold; a shared
-- venue asset (a custody item) stays. Induction links, invitations and passes as categories.
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
create function tests.job_rows(p_wp uuid) returns integer language sql stable security definer as $$
  select coalesce(sum(cardinality(ids)), 0)::int from core.job_disposal_rows(p_wp) $$;
grant execute on function tests.batch(text), tests.listed(text), tests.job_rows(uuid) to authenticated;

-- ---- Set-up: as the hand-back test, plus retention, hold, evidence and pass appointees ---------------------
select tests.login(tests.w('u_tom'));
select tests.must(api.publish_control_rule(tests.key(), tests.w('st_hv'), 'isolation', '{"prove_by": "same_person_allowed", "return_witness": "not_required"}',
  now() - interval '1 minute', 'Electrical safety rules (test values)'));
select tests.set_w('cv_wah_c', tests.configure_class(tests.w('pc_wah'), tests.class_config(
  '[{"key": "rams", "name": "RAMS review", "kind": "review", "group": 1}]',
  '[{"key": "access", "text": "How will people reach the work?", "type": "choose_one",
     "options": [{"key": "mewp", "text": "MEWP"}, {"key": "scaffold", "text": "Scaffold"}]}]')
  || '{"physical_controls": [{"kind": "isolation"}, {"kind": "exclusion_zone"}]}'));
select tests.set_w('cv_hw_c', tests.configure_class(tests.w('pc_hw'), tests.class_config(
  '[{"key": "hw-review", "name": "Hot works review", "kind": "review", "group": 1}]')
  || '{"physical_controls": [{"kind": "fire_watch", "during_work": false, "post_work_minutes": 0}], "hand_back_inspection": "remote_allowed"}'));
select tests.set_w('tv_hb', tests.new_type('HB', 'Hand-back Acceptor', array['permit.hand_back_accept'], '{}'));
select tests.set_w('u_hana', (tests.root_ta('hana@a.test', 'Hana', tests.w('tv_hb'), array[tests.w('pc_wa'), tests.w('pc_wah'), tests.w('pc_hw')], tests.w('site')))[1]);
select tests.set_w('tv_ra', tests.new_type('RA', 'Retention Approver', array['retention.approve'], '{}'));
select tests.set_w('tv_rd', tests.new_type('RD', 'Disposal Officer', array['retention.dispose'], '{}'));
select tests.set_w('tv_lh', tests.new_type('LH', 'Hold Officer', array['legal_hold.request'], '{}'));
select tests.set_w('tv_la', tests.new_type('LA', 'Hold Approver', array['legal_hold.approve'], '{}'));
select tests.set_w('tv_ev', tests.new_type('EV', 'Evidence Officer', array['evidence.export', 'record.correct'], '{}'));
select tests.set_w('tv_ps', tests.new_type('PS', 'Pass Officer', array['pass.revoke'], '{}'));
select tests.set_w('u_rita', (tests.root_ta('rita@a.test', 'Rita', tests.w('tv_ra'), array[tests.w('pc_wa')], tests.w('site')))[1]);
select tests.set_w('u_dora', (tests.root_ta('dora@a.test', 'Dora', tests.w('tv_rd'), array[tests.w('pc_wa')], tests.w('site')))[1]);
select tests.set_w('u_lena', (tests.root_ta('lena@a.test', 'Lena', tests.w('tv_lh'), array[tests.w('pc_wa')], tests.w('site')))[1]);
select tests.set_w('u_lars', (tests.root_ta('lars@a.test', 'Lars', tests.w('tv_la'), array[tests.w('pc_wa')], tests.w('site')))[1]);
select tests.set_w('u_evan', (tests.root_ta('evan@a.test', 'Evan', tests.w('tv_ev'), array[tests.w('pc_wa'), tests.w('pc_wah'), tests.w('pc_hw')], tests.w('site')))[1]);
select tests.set_w('u_pat', (tests.root_ta('pat@a.test', 'Pat', tests.w('tv_ps'), array[tests.w('pc_wa')], tests.w('site')))[1]);
select tests.set_w('u_run', tests.new_user('runner@octra.test'));
insert into core.service_account (auth_user_id, purpose) values (tests.w('u_run'), 'job_runner');
select tests.set_w('u_pb', tests.new_user('packs@octra.test'));
insert into core.service_account (auth_user_id, purpose) values (tests.w('u_pb'), 'pack_builder');

create function tests.live_controlled_job(p_title text) returns uuid language plpgsql as $$
declare wp uuid; wa uuid; wah uuid; hw uuid; iso uuid;
begin
  wp := tests.today_job(p_title, array[tests.w('pc_wah'), tests.w('pc_hw')]);
  wa := tests.permit_of(wp, tests.w('pc_wa')); wah := tests.permit_of(wp, tests.w('pc_wah')); hw := tests.permit_of(wp, tests.w('pc_hw'));
  perform tests.approve_permit(wa, '{}'); perform tests.approve_permit(wah, '{"access": ["mewp"]}'); perform tests.approve_permit(hw, '{}');
  perform tests.login(tests.w('u_op'));
  iso := (api.request_isolation(tests.key(), array[wah], tests.w('hv1'), 'HV1 feeder 3', 'Lamp circuits', now() - interval '1 hour', now() + interval '1 day') ->> 'isolation_id')::uuid;
  perform tests.must(api.set_up_exclusion_zone(tests.key(), wah, tests.w('hall1'), 'Barriers round the MEWP'));
  perform tests.must(api.arrange_fire_watch(tests.key(), hw, 'post', tests.w('p_owen')));
  perform tests.login(tests.w('u_ada'));
  perform tests.must(api.authorise_isolation(tests.key(), iso, tests.version('core.isolation', iso), 'authorise', 'Feeder 3 breaker'));
  perform tests.login(tests.w('u_al'));
  perform tests.must(api.apply_isolation(tests.key(), iso, tests.version('core.isolation', iso), 'IC-1', array['L-1'], null));
  perform tests.must(api.prove_isolation(tests.key(), iso, tests.version('core.isolation', iso), 'MFT-1', 'Prove-test-prove', true));
  perform tests.issue_and_accept(wa); perform tests.issue_and_accept(wah); perform tests.issue_and_accept(hw);
  return wp;
end $$;
grant execute on all functions in schema tests to authenticated;

-- Job 1: live with an isolation, an exclusion zone, a fire watch, a key out and a personal lock; then closed.
select tests.set_w('wp', tests.live_controlled_job('Rewire lamps'));
select tests.set_w('wa', tests.permit_of(tests.w('wp'), tests.w('pc_wa')));
select tests.set_w('wah', tests.permit_of(tests.w('wp'), tests.w('pc_wah')));
select tests.set_w('hw', tests.permit_of(tests.w('wp'), tests.w('pc_hw')));
select tests.set_w('iso', (select control_id from core.control_link where permit_id = tests.w('wah') and control_kind = 'isolation'));
select tests.login(tests.w('u_a1'));
select tests.set_w('key', tests.must(api.register_custody_item(tests.key(), tests.w('v1'), 'key', 'Plant room 1 key', 'K-PR1')));
select tests.login(tests.w('u_tom'));
select tests.set_w('mv', (api.issue_custody_item(tests.key(), tests.w('key'), tests.w('wah'), tests.w('p_op')) ->> 'movement_id')::uuid);
select tests.login(tests.w('u_op'));
select tests.set_w('lock', (api.isolation_lock_on(tests.key(), tests.w('iso'), tests.w('p_owen'), 'P-31') ->> 'lock_id')::uuid);

-- A permit pack of the live job, built; and a correction to its Work Approval's issue record.
select tests.login(tests.w('u_evan'));
select tests.set_w('pk', (api.request_permit_pack(tests.key(), tests.w('wa'), 'Insurer', 'Acme Insurance', 'internal') ->> 'id')::uuid);
select tests.must(api.record_correction(tests.key(), 'issue_snapshot', (select id from core.issue_snapshot where permit_id = tests.w('wa')),
  'Supervisor', 'Owen', 'Oli', 'Typed wrongly', 'The team list'));
select tests.login(tests.w('u_pb'));
select tests.must(api.claim_pack_builds());
select tests.logout();
insert into t_r select 'pk', jsonb_build_object('sha', encode(content_sha256, 'hex'), 'path', customer_id::text || '/' || id::text || '.zip') from core.export where id = tests.w('pk');
select tests.login(tests.w('u_pb'));
select tests.must(api.record_pack_build(tests.w('pk'), true, jsonb_build_array(jsonb_build_object('name', 'pack.json', 'sha256', (select v ->> 'sha' from t_r where name = 'pk'))),
  repeat('a', 64), 1000, (select v ->> 'path' from t_r where name = 'pk')));
select tests.logout();
select is((select build_state from core.export where id = tests.w('pk')), 'ready', 'the job has a built permit pack');

-- Job 2: live, never closed.
select tests.set_w('wp2', tests.live_controlled_job('Brackets'));
-- An isolation asked for both jobs, then withdrawn: shared, so it stays with job 2.
select tests.login(tests.w('u_op'));
select tests.set_w('iso_sh', (api.request_isolation(tests.key(), array[tests.w('wah'), tests.permit_of(tests.w('wp2'), tests.w('pc_wah'))], tests.w('hv1'),
  'HV1 feeder 9', 'Shared feed', now() - interval '1 hour', now() + interval '1 day') ->> 'isolation_id')::uuid);
select tests.must(api.withdraw_isolation(tests.key(), tests.w('iso_sh'), tests.version('core.isolation', tests.w('iso_sh')), 'Not needed after all'));
select tests.logout();
select is((select count(distinct p.work_package_id)::int from core.control_link_record l join core.permit p on p.id = l.permit_id where l.control_id = tests.w('iso_sh')), 2,
  'one withdrawn isolation is linked to both jobs');

-- Closing job 1: duties resolved, permits handed back and accepted. The isolation is removed but
-- not yet returned to service.
select tests.login(tests.w('u_op'));
select tests.must(api.hand_back_permit(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), true, null, 'Lamps done', true));
select tests.login(tests.w('u_tom'));
select tests.must(api.return_custody_item(tests.key(), tests.w('mv')));
select tests.login(tests.w('u_op'));
select tests.must(api.remove_exclusion_zone(tests.key(), (select id from core.exclusion_zone where permit_id = tests.w('wah')),
  tests.version('core.exclusion_zone', (select id from core.exclusion_zone where permit_id = tests.w('wah'))), 'Barriers down'));
select tests.must(api.isolation_lock_off(tests.key(), tests.w('lock')));
select tests.login(tests.w('u_ada'));
select tests.must(api.remove_isolation(tests.key(), tests.w('iso'), tests.version('core.isolation', tests.w('iso')), 'Locks off'));
select tests.login(tests.w('u_hana'));
select tests.must(api.decide_hand_back(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), 'accept', 'in_person', 'Clear'));
select tests.login(tests.w('u_op'));
select tests.must(api.hand_back_permit(tests.key(), tests.w('hw'), tests.version('core.permit', tests.w('hw')), true, null, 'Welded', true));
select tests.set_w('fw', (select id from core.fire_watch where permit_id = tests.w('hw')));
select tests.must(api.start_fire_watch(tests.key(), tests.w('fw'), tests.version('core.fire_watch', tests.w('fw'))));
select tests.must(api.end_fire_watch(tests.key(), tests.w('fw'), tests.version('core.fire_watch', tests.w('fw')), 'No hot spots'));
select tests.login(tests.w('u_hana'));
select tests.must(api.decide_hand_back(tests.key(), tests.w('hw'), tests.version('core.permit', tests.w('hw')), 'accept', 'in_person', 'Clear'));
select tests.login(tests.w('u_op'));
select tests.must(api.hand_back_permit(tests.key(), tests.w('wa'), tests.version('core.permit', tests.w('wa')), true, null, 'Job complete', true));
select tests.login(tests.w('u_hana'));
select tests.must(api.decide_hand_back(tests.key(), tests.w('wa'), tests.version('core.permit', tests.w('wa')), 'accept', 'in_person', 'Job complete'));
select tests.logout();
select is(tests.status_of(tests.w('wa')) || '/' || tests.status_of(tests.w('wah')) || '/' || tests.status_of(tests.w('hw')), 'closed/closed/closed', 'job 1 is closed');
select is((select status from core.isolation where id = tests.w('iso')), 'removed', 'its isolation is removed, not yet returned to service');

-- Passes: a revoked card with no gate checks naming it.
select tests.login(tests.w('u_a1'));
insert into t_r select 'card_nia', api.issue_card_pass(tests.key(), tests.w('p_nia'), tests.w('v1'));
select tests.login(tests.w('u_pat'));
select tests.must(api.revoke_pass(tests.key(), (select (v ->> 'pass_id')::uuid from t_r where name = 'card_nia'), 'Card lost'));
select tests.logout();
select tests.set_w('pass_nia', (select (v ->> 'pass_id')::uuid from t_r where name = 'card_nia'));

-- Job 4: a draft that was never routed, its planned window long past.
select tests.set_w('wp4', tests.new_job());
select tests.raw(format($$update core.work_package_revision set planned_window = tstzrange(now() - interval '30 days', now() - interval '20 days') where work_package_id = %L$$, tests.w('wp4')));
-- A live pass, and an induction link never used.
select tests.login(tests.w('u_a1'));
insert into t_r select 'card_owen', api.issue_card_pass(tests.key(), tests.w('p_owen'), tests.w('v1'));
insert into t_r select 'link_nia', api.issue_induction_link(tests.key(), tests.w('course_core'), tests.w('p_nia'), now() + interval '7 days');
select tests.logout();

-- Everything above happened ten days ago.
select tests.raw(format($$update core.status_history set at = at - interval '10 days' where customer_id = %L$$, tests.w('cust_a')));
select tests.raw(format($$update core.person_pass set revoked_at = revoked_at - interval '10 days' where id = %L$$, tests.w('pass_nia')));
select tests.raw(format($$update core.induction_link set claimed_at = now() - interval '10 days' where token_hash = %L$$, core.token_hash(tests.tok_op())));

-- ---- The schedule, with closed jobs and the new categories ---------------------------------------------------
select tests.login(tests.w('u_a1'));
select tests.set_w('rs1', (api.create_venue_config_draft(tests.key(), tests.w('v1'), 'retention') ->> 'id')::uuid);
select tests.must(api.save_venue_config_draft(tests.key(), tests.w('rs1'), tests.version('core.venue_config_version', tests.w('rs1')),
  '{"rules": {"closed_jobs": {"days": 5, "basis": "Test value"}, "induction_links": {"days": 5, "basis": "Test value"},
              "invitations": {"days": 5, "basis": "Test value"}, "passes": {"days": 5, "basis": "Test value"}}}', 'Test values, not advice'));
select tests.must(api.propose_venue_config(tests.key(), tests.w('rs1'), tests.version('core.venue_config_version', tests.w('rs1'))));
select tests.login(tests.w('u_rita'));
select tests.must(api.decide_venue_config(tests.key(), tests.w('rs1'), tests.version('core.venue_config_version', tests.w('rs1')), 'approve', 'Agreed'));
select tests.login(tests.w('u_run'));
select tests.must(api.run_retention_jobs());
select tests.logout();
select is(tests.batch('closed_jobs'), null, 'a closed job whose isolation is not yet returned to service is not listed (invariant 8)');
select ok(tests.listed('induction_links') @> array[(select id from core.induction_link where token_hash = core.token_hash(tests.tok_op()))],
  'a used induction link is listed');
select is(tests.listed('invitations'), array(select id from core.invitation where customer_id = tests.w('cust_a') and kind = 'organisation'),
  'the answered organisation invitation is listed; the person invitation, which has no venue, waits for every venue to have a rule (8d-3)');
select is(tests.listed('passes'), array[tests.w('pass_nia')], 'the revoked pass is listed; a live one is not');
select ok(not (tests.listed('induction_links') @> array[(select id from core.induction_link where person_id = tests.w('p_nia'))]), 'an unused link that can still be used is not');

-- Returned to service: now the job is finished.
select tests.login(tests.w('u_ada'));
select tests.must(api.return_isolation(tests.key(), tests.w('iso'), tests.version('core.isolation', tests.w('iso')), 'IR test passed', null));
select tests.logout();
select tests.raw(format($$update core.status_history set at = at - interval '10 days' where record_id = %L and to_state = 'returned'$$, tests.w('iso')));
select tests.login(tests.w('u_run'));
select tests.must(api.run_retention_jobs());
select tests.logout();
select is(tests.listed('closed_jobs'), array[tests.w('wp')], 'the closed job is listed; live jobs and a draft job are not');
select ok(tests.job_rows(tests.w('wp')) > 40, 'the job is made of many records across its tables');

-- Defence in depth: closure already requires these resolved (invariant 8); forced back here, each
-- alone keeps a closed job from being listed.
select tests.login(tests.w('u_dora'));
select tests.must(api.decide_disposal_batch(tests.key(), tests.batch('closed_jobs'), tests.version('core.disposal_batch', tests.batch('closed_jobs')), 'decline', 'Testing'));
select tests.logout();
create function tests.listable(p_wp uuid) returns boolean language sql stable security definer as $$
  select exists (select 1 from core.retention_candidates(tests.w('cust_a'), 'closed_jobs') c where c.root_id = p_wp) $$;
select is(tests.listable(tests.w('wp')), true, 'the closed job can be disposed of');
select tests.raw(format($$update core.permit set status = 'active' where id = %L$$, tests.w('hw')));
select is(tests.listable(tests.w('wp')), false, 'not while any permit on it is unfinished');
select tests.raw(format($$update core.permit set status = 'closed' where id = %L$$, tests.w('hw')));
select tests.raw(format($$update core.fire_watch set status = 'started' where id = %L$$, tests.w('fw')));
select is(tests.listable(tests.w('wp')), false, 'not while a fire watch is unfinished');
select tests.raw(format($$update core.fire_watch set status = 'ended' where id = %L$$, tests.w('fw')));
select tests.raw(format($$update core.exclusion_zone set status = 'in_place' where permit_id = %L$$, tests.w('wah')));
select is(tests.listable(tests.w('wp')), false, 'nor while an exclusion zone is in place');
select tests.raw(format($$update core.exclusion_zone set status = 'removed' where permit_id = %L$$, tests.w('wah')));
select tests.raw(format($$update core.custody_movement set returned_at = null, received_by_person_id = null, return_decision_context_id = null where id = %L$$, tests.w('mv')));
select is(tests.listable(tests.w('wp')), false, 'nor while a key is still out');
select tests.raw(format($$update core.custody_movement set returned_at = now(), received_by_person_id = %L,
                          return_decision_context_id = (select issue_decision_context_id from core.custody_movement where id = %L) where id = %L$$,
                        tests.w('p_op'), tests.w('mv'), tests.w('mv')));
select is(tests.listable(tests.w('wp')), true, 'and with all resolved again, it can');
-- A new schedule version, so the declined job is listed again.
select tests.login(tests.w('u_a1'));
select tests.set_w('rs2', (api.create_venue_config_draft(tests.key(), tests.w('v1'), 'retention') ->> 'id')::uuid);
select tests.must(api.save_venue_config_draft(tests.key(), tests.w('rs2'), tests.version('core.venue_config_version', tests.w('rs2')),
  (select content from core.venue_config_version where id = tests.w('rs1')), 'Test values, version 2'));
select tests.must(api.propose_venue_config(tests.key(), tests.w('rs2'), tests.version('core.venue_config_version', tests.w('rs2'))));
select tests.login(tests.w('u_rita'));
select tests.must(api.decide_venue_config(tests.key(), tests.w('rs2'), tests.version('core.venue_config_version', tests.w('rs2')), 'approve', 'Re-issued'));
select tests.login(tests.w('u_run'));
select tests.must(api.run_retention_jobs());
select tests.logout();
select is(tests.listed('closed_jobs'), array[tests.w('wp')], 'under the new schedule version the job is listed again');

-- ---- A hold on the job keeps it; lifting it lets disposal resume ------------------------------------------------
select tests.login(tests.w('u_lena'));
select tests.set_w('lh', tests.must(api.request_legal_hold(tests.key(), tests.w('v1'), 'Claim 9', 'Lamps job may be disputed', current_date + 30,
  p_work_package_id => tests.w('wp'))));
select tests.login(tests.w('u_lars'));
select tests.must(api.decide_legal_hold(tests.key(), tests.w('lh'), tests.version('core.legal_hold', tests.w('lh')), 'approve', 'Notified'));
select tests.login(tests.w('u_dora'));
insert into t_r select 'd1', api.decide_disposal_batch(tests.key(), tests.batch('closed_jobs'), tests.version('core.disposal_batch', tests.batch('closed_jobs')), 'confirm', 'Past period');
select tests.logout();
select is((select (v ->> 'disposed')::int || '/' || (v ->> 'kept')::int from t_r where name = 'd1'), '0/1', 'the hold on the job keeps it at confirmation');
select ok((select status from core.work_package where id = tests.w('wp')) is not null, 'and it is all still there');
select tests.login(tests.w('u_lars'));
select tests.must(api.lift_legal_hold(tests.key(), tests.w('lh'), tests.version('core.legal_hold', tests.w('lh')), 'Claim withdrawn'));
select tests.login(tests.w('u_run'));
select tests.must(api.run_retention_jobs());
select tests.logout();
select is(tests.listed('closed_jobs'), array[tests.w('wp')], 'listed again once the hold is lifted');

-- Snapshot of what is there before.
insert into t_r select 'before', jsonb_build_object(
  'status_history', (select count(*) from core.status_history where record_id in (tests.w('wa'), tests.w('wah'), tests.w('hw'))),
  'custody_item', (select count(*) from core.custody_item where id = tests.w('key')),
  'keys', (select count(*) from audit.record_key where record_id = tests.w('wa')));
select is((select (v ->> 'keys')::int from t_r where name = 'before'), 1, 'the Work Approval has an audit key');

select tests.login(tests.w('u_dora'));
insert into t_r select 'd2', api.decide_disposal_batch(tests.key(), tests.batch('closed_jobs'), tests.version('core.disposal_batch', tests.batch('closed_jobs')), 'confirm', 'Past period');
select tests.logout();
select is((select (v ->> 'disposed')::int from t_r where name = 'd2'), 1, 'the closed job is disposed of');
select is((select count(*)::int from core.work_package where id = tests.w('wp')), 0, 'the job is gone');
select is((select count(*)::int from core.permit where work_package_id = tests.w('wp')), 0, 'with its permits');
select is((select count(*)::int from core.issue_snapshot where permit_id in (tests.w('wa'), tests.w('wah'), tests.w('hw')))
        + (select count(*)::int from core.close_out_snapshot where permit_id in (tests.w('wa'), tests.w('wah'), tests.w('hw'))), 0, 'and their snapshots');
select is((select count(*)::int from core.isolation where id = tests.w('iso')) + (select count(*)::int from core.isolation_lock where isolation_id = tests.w('iso'))
        + (select count(*)::int from core.control_event where control_id = tests.w('iso')), 0, 'the isolation it alone used, with its locks and events');
select is((select count(*)::int from core.fire_watch where id = tests.w('fw')), 0, 'its fire watch');
select is((select count(*)::int from core.isolation where id = tests.w('iso_sh')), 1, 'an isolation shared with another job stays');
select is((select string_agg(distinct p.work_package_id::text, ',') from core.control_link_record l join core.permit p on p.id = l.permit_id where l.control_id = tests.w('iso_sh')),
  tests.w('wp2')::text, 'linked now only to the job that remains');
select is((select count(*)::int from core.export where id = tests.w('pk')) + (select count(*)::int from core.correction where work_package_id = tests.w('wp')), 0,
  'its pack and its correction');
select is((select bucket from core.file_disposal where export_id = tests.w('pk')), 'evidence-packs', 'the pack''s stored file is queued for removal');
select is((select count(*)::int from core.custody_item where id = tests.w('key')), 1, 'the venue''s key stays: it is not the job''s');
select is((select count(*)::int from core.status_history where record_id in (tests.w('wa'), tests.w('wah'), tests.w('hw'))),
  (select (v ->> 'status_history')::int from t_r where name = 'before'), 'the record of state changes (identifiers and states only) stays');
select is((select count(*)::int from audit.record_key where record_id = tests.w('wa')), 0, 'the audit keys went with the records');
select is(tests.job_rows(tests.w('wp')), 0, 'nothing of the job remains');
select ok((select count(*) from core.disposal_row where batch_id = (select id from core.disposal_batch where category = 'closed_jobs' and status = 'confirmed'
             and disposed_count = 1)) > 40, 'and the identifier of every row deleted is kept with the batch');
select ok(exists (select 1 from core.work_package where id = tests.w('wp2')), 'the live job is untouched');
select is((select count(*)::int from core.isolation i join core.control_link_record l on l.control_id = i.id join core.permit p on p.id = l.permit_id
            where p.work_package_id = tests.w('wp2')), 2, 'with its own isolation and the shared one');

-- Pack files are removed by the runner like any other.
select tests.login(tests.w('u_run'));
select is((select count(*)::int from jsonb_array_elements(api.claim_file_removals() -> 'files') f where f ->> 'bucket' = 'evidence-packs'), 1,
  'the runner claims the pack file to remove');
select tests.logout();

-- Passes, links and invitations.
select tests.login(tests.w('u_dora'));
select tests.must(api.decide_disposal_batch(tests.key(), tests.batch('passes'), tests.version('core.disposal_batch', tests.batch('passes')), 'confirm', 'Revoked'));
select tests.must(api.decide_disposal_batch(tests.key(), tests.batch('induction_links'), tests.version('core.disposal_batch', tests.batch('induction_links')), 'confirm', 'Used'));
select tests.must(api.decide_disposal_batch(tests.key(), tests.batch('invitations'), tests.version('core.disposal_batch', tests.batch('invitations')), 'confirm', 'Answered'));
select tests.logout();
select is((select count(*)::int from core.person_pass where id = tests.w('pass_nia')), 0, 'the revoked pass is gone');
select is((select count(*)::int from core.induction_link where token_hash = core.token_hash(tests.tok_op())), 0, 'the used induction link is gone');
select is((select string_agg(kind, ',') from core.invitation where customer_id = tests.w('cust_a')), 'person', 'the organisation invitation is gone; the person invitation stays');
select ok(exists (select 1 from core.organisation where legal_name = 'Cara Electrical Ltd'), 'what they created stays');

select * from finish();
rollback;
