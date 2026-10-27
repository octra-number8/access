-- Hand-back and closure 6c (Q91-Q97, Q113-Q118, Q141, Q147, P6-10 to P6-12, invariants 3, 5,
-- 8, 9, 10): hand-back by the supervisor and close-out by an issuer, acceptance and
-- rejection, closure refused with duties outstanding, continuing controls transferred to an
-- owner, partial return of areas, cancelled and abandoned, the close-out snapshot, and
-- emergency work with its retrospective permit.
begin;
\ir _helpers.psql
\ir _phase4.psql
select tests.approve_screening();
\ir _phase5.psql
\ir _phase6.psql
\ir _phase6b.psql
select no_plan();

create temp table t_r (name text primary key, v jsonb);
grant all on t_r to authenticated;

-- ---- Set-up: rules, a hand-back acceptor, an emergency authority, live permits with controls ----
select tests.login(tests.w('u_tom'));
select tests.must(api.publish_control_rule(tests.key(), tests.w('st_hv'), 'isolation', '{"prove_by": "same_person_allowed", "return_witness": "not_required"}',
  now() - interval '1 minute', 'Electrical safety rules (test values)'));
select tests.set_w('tv_hb', tests.new_type('HB', 'Hand-back Acceptor',
  array['permit.hand_back_accept', 'permit.close_out_for_issuer', 'permit.cancel_issued', 'permit.flag_abandoned'], '{}'));
select tests.set_w('u_hana', (tests.root_ta('hana@a.test', 'Hana', tests.w('tv_hb'), array[tests.w('pc_wa'), tests.w('pc_wah'), tests.w('pc_hw')], tests.w('site')))[1]);
select tests.set_w('tv_ea', tests.new_type('EA', 'Emergency Authority', array['emergency.authorise'], '{}'));
select tests.set_w('u_eve', (tests.root_ta('eve@a.test', 'Eve', tests.w('tv_ea'), array[tests.w('pc_wa')], tests.w('site')))[1]);
select tests.set_w('p_eve', (select person_id from core.user_account where auth_user_id = tests.w('u_eve')));

select ok(array_to_string(core.validate_class_config(tests.w('v1'), tests.class_config('[{"key": "r", "name": "R", "kind": "review", "group": 1}]')
  - 'hand_back_declaration', true), ' ') like '%confirms at hand-back (Q113): there is no default%', 'a class must say what is confirmed at hand-back');
select ok(array_to_string(core.validate_class_config(tests.w('v1'), tests.class_config('[{"key": "r", "name": "R", "kind": "review", "group": 1}]')
  - 'hand_back_inspection', true), ' ') like '%inspected in person or may be accepted remotely (Q114)%', 'and how it is inspected');

select tests.set_w('cv_wah_c', tests.configure_class(tests.w('pc_wah'), tests.class_config(
  '[{"key": "rams", "name": "RAMS review", "kind": "review", "group": 1}]',
  '[{"key": "access", "text": "How will people reach the work?", "type": "choose_one",
     "options": [{"key": "mewp", "text": "MEWP"}, {"key": "scaffold", "text": "Scaffold"}]}]')
  || '{"physical_controls": [{"kind": "isolation"}, {"kind": "exclusion_zone"}]}'));
select tests.set_w('cv_hw_c', tests.configure_class(tests.w('pc_hw'), tests.class_config(
  '[{"key": "hw-review", "name": "Hot works review", "kind": "review", "group": 1}]')
  || '{"physical_controls": [{"kind": "fire_watch", "during_work": false, "post_work_minutes": 0}], "hand_back_inspection": "remote_allowed"}'));

-- Issues and accepts the job's permits, with the controls their classes need.
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
select tests.set_w('wp', tests.live_controlled_job('Rewire lamps'));
select tests.set_w('wa', tests.permit_of(tests.w('wp'), tests.w('pc_wa')));
select tests.set_w('wah', tests.permit_of(tests.w('wp'), tests.w('pc_wah')));
select tests.set_w('hw', tests.permit_of(tests.w('wp'), tests.w('pc_hw')));
select tests.set_w('iso', (select control_id from core.control_link where permit_id = tests.w('wah') and control_kind = 'isolation'));
select is(tests.status_of(tests.w('wa')) || '/' || tests.status_of(tests.w('wah')) || '/' || tests.status_of(tests.w('hw')), 'active/active/active',
  'a live job with its controls in place');
-- A key out, and a personal lock on.
select tests.login(tests.w('u_a1'));
select tests.set_w('key', tests.must(api.register_custody_item(tests.key(), tests.w('v1'), 'key', 'Plant room 1 key', 'K-PR1')));
select tests.set_w('key2', tests.must(api.register_custody_item(tests.key(), tests.w('v1'), 'pass', 'Hall 2 loading pass', 'P-H2', tests.w('hall2'))));
select tests.login(tests.w('u_tom'));
select tests.set_w('mv', (api.issue_custody_item(tests.key(), tests.w('key'), tests.w('wah'), tests.w('p_op')) ->> 'movement_id')::uuid);
select tests.set_w('mv2', (api.issue_custody_item(tests.key(), tests.w('key2'), tests.w('wah'), tests.w('p_op')) ->> 'movement_id')::uuid);
select tests.login(tests.w('u_op'));
select tests.set_w('lock', (api.isolation_lock_on(tests.key(), tests.w('iso'), tests.w('p_owen'), 'P-31') ->> 'lock_id')::uuid);

-- ---- Partial hand-back of areas (Q115, P6-12) ----------------------------------------------------------
select tests.login(tests.w('u_op'));
select ok(api.return_areas(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), array[tests.w('hall1'), tests.w('hall2')], 'Clear')::text
  like '%use hand-back instead%', 'returning every area is a hand-back, not a partial one');
select ok(api.return_areas(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), array[tests.w('hall2')], 'Clear')::text
  like '%key or pass for a returned area is still out%', 'an area is not returned while its key or pass is out');
select tests.login(tests.w('u_tom'));
select tests.must(api.return_custody_item(tests.key(), tests.w('mv2')));
select tests.login(tests.w('u_nia'));
select is(api.return_areas(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), array[tests.w('hall2')], 'Clear') ->> 'code', 'not_permit_part',
  'only the supervisor returns areas');
select tests.login(tests.w('u_op'));
insert into t_r select 'ret', api.return_areas(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), array[tests.w('hall2')], 'Hall 2 clear and swept');
select is((select v ->> 'ok' from t_r where name = 'ret'), 'true', 'the supervisor returns Hall 2 while work continues in Hall 1');
select ok(api.return_areas(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), array[tests.w('hall2')], 'Again')::text
  like '%still waiting for a decision%', 'one return of areas at a time');
select is(api.decide_area_return(tests.key(), (select (v ->> 'area_return_id')::uuid from t_r where name = 'ret'), 'accept', 'Seen') ->> 'code',
  'separation_of_duties', 'the supervisor cannot accept their own return');
select tests.login(tests.w('u_hana'));
select is(api.decide_area_return(tests.key(), (select (v ->> 'area_return_id')::uuid from t_r where name = 'ret'), 'accept', 'Walked Hall 2: clear') ->> 'ok', 'true',
  'the hand-back acceptor accepts it');
select is(api.permit_detail(tests.w('wah')) #> '{close_out,live_area_ids}', to_jsonb(array[tests.w('hall1')]), 'and the live scope narrows to Hall 1');
select is(tests.status_of(tests.w('wah')), 'active', 'with the permit still active');

-- ---- Hand-back (Q113, Q114) ---------------------------------------------------------------------------
select tests.login(tests.w('u_op'));
select is(api.hand_back_permit(tests.key(), tests.w('wa'), tests.version('core.permit', tests.w('wa')), true, null, 'Clear', true) ->> 'code', 'children_live',
  'the Work Approval is handed back after the permits under it');
select is(api.hand_back_permit(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')) - 1, true, null, 'Clear', true) ->> 'code', 'changed',
  'not from an out-of-date page (invariant 11)');
select is(api.hand_back_permit(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), false, ' ', 'Clear', true) ->> 'code', 'invalid_content',
  'incomplete work must say what remains');
select is(api.hand_back_permit(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), true, null, 'Clear', false) ->> 'code', 'invalid_content',
  'and everyone must be out');
select tests.login(tests.w('u_nia'));
select is(api.hand_back_permit(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), true, null, 'Clear', true) ->> 'code',
  'separation_of_duties', 'someone else from the contractor cannot hand it back for the supervisor');
select tests.login(tests.w('u_op'));
insert into t_r select 'hb', api.hand_back_permit(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), true, null, 'Lamps replaced, area swept', true);
select is((select v ->> 'ok' from t_r where name = 'hb'), 'true', 'the supervisor hands back the work-at-height permit');
select is(tests.status_of(tests.w('wah')), 'hand_back_pending', 'which waits for acceptance');
select is((select array_agg(x ->> 'duty' order by x ->> 'duty') from t_r, jsonb_array_elements(v -> 'duties') x where name = 'hb'),
  array['custody', 'exclusion_zone', 'isolation', 'lock'], 'the database lists what is still outstanding');
select is((select declaration from core.hand_back where permit_id = tests.w('wah')),
  '["The work area is left safe and tidy.", "Everyone has left the work area."]'::jsonb, 'with the class''s hand-back declaration recorded');
select is(api.stop_work(tests.key(), tests.w('wah'), 'other', 'Hm') ->> 'code', 'not_live', 'a permit waiting for hand-back has no work left to stop');

-- ---- Who accepts, and closure refused with duties outstanding (invariants 3, 8, 9) ---------------------
select is(api.decide_hand_back(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), 'accept', 'in_person', 'Done') ->> 'code',
  'separation_of_duties', 'the supervisor cannot accept their own hand-back');
select tests.login(tests.w('u_a1'));
select is(api.decide_hand_back(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), 'accept', 'in_person', 'Done') ->> 'code',
  'no_covering_appointment', 'nor a tenant administrator (invariant 9)');
select tests.login(tests.w('u_platform'));
select is(api.decide_hand_back(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), 'accept', 'in_person', 'Done') ->> 'ok', 'false',
  'nor a platform administrator: a super-admin cannot close a job (invariant 9)');
select tests.login(tests.w('u_hana'));
insert into t_r select 'acc1', api.decide_hand_back(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), 'accept', 'in_person', 'Looks done');
select is((select v ->> 'code' from t_r where name = 'acc1'), 'duties_outstanding', 'the acceptor cannot close it while duties are outstanding');
select is((select jsonb_array_length(v -> 'duties') from t_r where name = 'acc1'), 4, 'each one listed, with who resolves it');
select is(api.decide_hand_back(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), 'accept', 'remote', 'Looks done') ->> 'code',
  'inspection_in_person', 'this class''s hand-back is inspected in person');
-- Past the API: the closing write itself is refused.
select tests.logout();
create function tests.force_close(p_permit uuid) returns void language plpgsql security definer as $$
declare p core.permit; v jsonb; ctx uuid;
begin
  select * into p from core.permit where id = p_permit;
  v := authz.require('permit.hand_back_accept', core.live_target(p), gen_random_uuid()::text, '{}');
  if not (v ->> 'ok')::boolean then raise exception 'not authorised: %', v; end if;
  ctx := (v ->> 'decision_context_id')::uuid;
  insert into core.hand_back_decision (customer_id, venue_id, hand_back_id, outcome, inspection, reason, decider_person_id, decision_context_id)
  select p.customer_id, p.venue_id, h.id, 'accepted', 'in_person', 'Forced', (v ->> 'actor_person_id')::uuid, ctx
    from core.hand_back h where h.permit_id = p.id and not exists (select 1 from core.hand_back_decision d where d.hand_back_id = h.id);
  perform core.transition('core.permit', p.id, 'closed', p.row_version, ctx);
end $$;
create function tests.force_close_without_hand_back(p_permit uuid) returns void language plpgsql security definer as $$
declare p core.permit; v jsonb;
begin
  select * into p from core.permit where id = p_permit;
  v := authz.require('permit.hand_back_accept', core.live_target(p), gen_random_uuid()::text, '{}');
  perform core.transition('core.permit', p.id, 'closed', p.row_version, (v ->> 'decision_context_id')::uuid);
end $$;
grant execute on function tests.force_close(uuid), tests.force_close_without_hand_back(uuid) to authenticated;
select tests.login(tests.w('u_hana'));
select throws_ok($$ select tests.force_close(tests.w('wah')) $$, '23514', null,
  'the database refuses to close a permit with duties outstanding, whatever route is taken (invariant 8)');

-- Resolving the duties.
select tests.login(tests.w('u_tom'));
select tests.must(api.return_custody_item(tests.key(), tests.w('mv')));
select tests.login(tests.w('u_op'));
select tests.must(api.remove_exclusion_zone(tests.key(), (select id from core.exclusion_zone where permit_id = tests.w('wah')),
  tests.version('core.exclusion_zone', (select id from core.exclusion_zone where permit_id = tests.w('wah'))), 'Barriers down, area clear'));
-- The isolation must stay: the circuits are being rewired next week.
select tests.login(tests.w('u_ada'));
select is(api.transfer_control(tests.key(), 'isolation', tests.w('iso'), 'Circuits stay dead until the rewire next week', current_date + 7) ->> 'code',
  'locks_on', 'an isolation is not transferred with personal locks still on');
select tests.login(tests.w('u_op'));
select tests.must(api.isolation_lock_off(tests.key(), tests.w('lock')));
select is(api.transfer_control(tests.key(), 'isolation', tests.w('iso'), 'Mine now', current_date + 7) ->> 'code', 'separation_of_duties',
  'an isolation authority connected with the job cannot take it over');
select tests.login(tests.w('u_ada'));
select is(api.transfer_control(tests.key(), 'isolation', tests.w('iso'), 'Circuits stay dead', current_date - 1) ->> 'code', 'invalid_content',
  'a continuing control needs a review date, not in the past');
select is(api.transfer_control(tests.key(), 'isolation', tests.w('iso'), 'Circuits stay dead until the rewire next week', current_date + 7) ->> 'ok', 'true',
  'the isolation authority takes ownership of the continuing isolation (Q147)');
select is((select status from core.isolation where id = tests.w('iso')), 'proved', 'it stays in place');
select tests.logout();
select is((select count(*)::int from core.control_link where control_id = tests.w('iso')), 0, 'no longer linked to the permit');
select is((select count(*)::int from core.control_link_record where control_id = tests.w('iso') and unlinked_at is not null), 1, 'but the link is kept in the record');
select tests.login(tests.w('u_ada'));
select is((select x #>> '{continuing,owner}' from jsonb_array_elements(api.controls_desk() -> 'isolations') x where (x ->> 'id')::uuid = tests.w('iso')),
  'Ada Engineer', 'and the controls desk shows its owner');
select is(api.permit_detail(tests.w('wah')) #> '{close_out,duties}', '[]'::jsonb, 'nothing is outstanding now');
select tests.login(tests.w('u_hana'));

-- Rejected, then accepted.
select is(api.decide_hand_back(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), 'reject', 'in_person', 'Lamp 4 still loose') ->> 'ok', 'true',
  'the acceptor can reject a hand-back');
select is(tests.status_of(tests.w('wah')), 'active', 'and the permit goes back to where it was');
select tests.login(tests.w('u_op'));
select tests.must(api.hand_back_permit(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), true, null, 'Lamp 4 fixed, area swept', true));
select tests.login(tests.w('u_hana'));
select throws_ok($$ select tests.force_close_without_hand_back(tests.w('wah')) $$, '23514', 'a permit closes only through an accepted hand-back',
  'nothing outstanding is still not enough: a permit closes only through an accepted hand-back');
select is(api.decide_hand_back(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), 'accept', 'in_person', 'Walked the area: clear') ->> 'ok', 'true',
  'then accepts it');
select is(tests.status_of(tests.w('wah')), 'closed', 'and the permit is closed');
select is(api.decide_hand_back(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), 'accept', 'in_person', 'Again') ->> 'code', 'not_pending', 'once');
select is((select count(*)::int from core.close_out_snapshot where permit_id = tests.w('wah')), 1, 'closure freezes a close-out snapshot (invariant 5)');
select is((select encode(content_sha256, 'hex') from core.close_out_snapshot where permit_id = tests.w('wah')),
  (select encode(sha256(convert_to(content::text, 'UTF8')), 'hex') from core.close_out_snapshot where permit_id = tests.w('wah')), 'with its hash');
select ok((select content::text from core.close_out_snapshot where permit_id = tests.w('wah')) like '%Transferred to a continuing owner%'
      and (select jsonb_array_length(content -> 'hand_backs') from core.close_out_snapshot where permit_id = tests.w('wah')) = 2
      and (select jsonb_array_length(content -> 'area_returns') from core.close_out_snapshot where permit_id = tests.w('wah')) = 1,
  'recording the transferred isolation, both hand-backs and the returned area');
select throws_ok($$ update core.close_out_snapshot set content = '{}' $$, '42501', null, 'and it cannot be rewritten');

-- Hot works: the fire watch after the work, then a remote acceptance where the class allows it.
select tests.login(tests.w('u_op'));
select tests.must(api.hand_back_permit(tests.key(), tests.w('hw'), tests.version('core.permit', tests.w('hw')), true, null, 'Brackets welded, area cooling', true));
select ok(api.permit_detail(tests.w('hw'))::text like '%fire watch after the work (Owen Operative) has not finished%', 'the fire watch after the work is outstanding');
select tests.set_w('fw', (select id from core.fire_watch where permit_id = tests.w('hw')));
select tests.must(api.start_fire_watch(tests.key(), tests.w('fw'), tests.version('core.fire_watch', tests.w('fw'))));
select tests.must(api.end_fire_watch(tests.key(), tests.w('fw'), tests.version('core.fire_watch', tests.w('fw')), 'No hot spots'));
select tests.login(tests.w('u_hana'));
select is(api.decide_hand_back(tests.key(), tests.w('hw'), tests.version('core.permit', tests.w('hw')), 'accept', 'remote', 'Photos checked; watch completed') ->> 'ok',
  'true', 'remote acceptance where the class allows it');
select is((select inspection from core.hand_back_decision d join core.hand_back h on h.id = d.hand_back_id where h.permit_id = tests.w('hw')), 'remote',
  'recorded as remote');
-- The Work Approval last.
select tests.login(tests.w('u_op'));
select tests.must(api.hand_back_permit(tests.key(), tests.w('wa'), tests.version('core.permit', tests.w('wa')), true, null, 'Job complete', true));
select tests.login(tests.w('u_hana'));
select is(api.decide_hand_back(tests.key(), tests.w('wa'), tests.version('core.permit', tests.w('wa')), 'accept', 'in_person', 'Job complete') ->> 'ok', 'true',
  'with its permits closed, the Work Approval closes');
select tests.login(tests.w('u_ada'));
select is(api.remove_isolation(tests.key(), tests.w('iso'), tests.version('core.isolation', tests.w('iso')), 'Rewire done; locks off') ->> 'ok', 'true',
  'the continuing isolation is removed later by its owner');

-- ---- Close-out of a stopped and expired job (Q116, Q117, P6-10) ------------------------------------------
select tests.set_w('wp2', tests.live_controlled_job('Brackets'));
select tests.set_w('wa2', tests.permit_of(tests.w('wp2'), tests.w('pc_wa')));
select tests.set_w('hw2', tests.permit_of(tests.w('wp2'), tests.w('pc_hw')));
select tests.set_w('wah2', tests.permit_of(tests.w('wp2'), tests.w('pc_wah')));
select tests.logout();
select tests.set_w('iso2', (select control_id from core.control_link where permit_id = tests.w('wah2') and control_kind = 'isolation'));
select tests.login(tests.w('u_ada'));
select is(api.transfer_control(tests.key(), 'isolation', tests.w('iso2'), 'Keep it', current_date + 7) ->> 'code', 'permits_live',
  'an isolation is not transferred away from work that is still live');
select tests.login(tests.w('u_hana'));
select is(api.flag_abandoned(tests.key(), tests.w('wa2'), 'Gone') ->> 'code', 'not_stopped', 'an active job is not flagged abandoned');
select is(api.hand_back_permit(tests.key(), tests.w('wa2'), tests.version('core.permit', tests.w('wa2')), true, null, 'Clear', true) ->> 'code', 'not_handbackable',
  'an issuer does not start a close-out of an active permit: its supervisor hands it back');
select tests.login(tests.w('u_op'));
select tests.must(api.stop_work(tests.key(), tests.w('wa2'), 'other', 'Contractor left site'));
select tests.login(tests.w('u_hana'));
select is(api.flag_abandoned(tests.key(), tests.w('wa2'), 'Contractor has left and will not return') ->> 'ok', 'true', 'a stopped job is flagged abandoned');
select is(tests.status_of(tests.w('wa2')), 'suspended', 'which closes nothing');
insert into t_r select 'co', api.hand_back_permit(tests.key(), tests.w('hw2'), tests.version('core.permit', tests.w('hw2')), false, 'Bracket 3 not fixed',
  'Area left barriered', true);
select is((select v ->> 'ok' from t_r where name = 'co'), 'true', 'an issuer starts the close-out of a stopped permit whose contractor has gone');
select is((select route from core.hand_back where permit_id = tests.w('hw2')), 'issuer_close_out', 'recorded as a close-out by the issuer');
select is(api.decide_hand_back(tests.key(), tests.w('hw2'), tests.version('core.permit', tests.w('hw2')), 'accept', 'remote', 'Done') ->> 'code',
  'separation_of_duties', 'whoever started a close-out cannot also accept it');
-- The contractor's watcher completes the watch; another acceptor closes it.
select tests.login(tests.w('u_op'));
select tests.set_w('fw2', (select id from core.fire_watch where permit_id = tests.w('hw2')));
select tests.must(api.start_fire_watch(tests.key(), tests.w('fw2'), tests.version('core.fire_watch', tests.w('fw2'))));
select tests.must(api.end_fire_watch(tests.key(), tests.w('fw2'), tests.version('core.fire_watch', tests.w('fw2')), 'No hot spots'));
select tests.set_w('u_hal', (tests.root_ta('hal@a.test', 'Hal', tests.w('tv_hb'), array[tests.w('pc_wa'), tests.w('pc_wah'), tests.w('pc_hw')], tests.w('site')))[1]);
select tests.login(tests.w('u_hal'));
select is(api.decide_hand_back(tests.key(), tests.w('hw2'), tests.version('core.permit', tests.w('hw2')), 'accept', 'remote', 'Watch complete; photos') ->> 'ok', 'true',
  'a second acceptor closes it');
select is((select content #>> '{hand_backs,0,remaining_work}' from core.close_out_snapshot where permit_id = tests.w('hw2')), 'Bracket 3 not fixed',
  'with the unfinished work recorded');
-- The Work Approval's window ends while it is stopped: it expires, and still has to close out.
select tests.logout();
alter table core.permit_version disable trigger b_forbid_update;
update core.permit_version set planned_window = tstzrange(lower(planned_window), now() - interval '1 minute')
 where permit_id in (tests.w('wa2'), tests.w('wah2'));
alter table core.permit_version enable trigger b_forbid_update;
select tests.login(tests.w('u_exp'));
select is((api.expire_permits() ->> 'expired')::int, 2, 'the stopped permits expire when their windows end');
select tests.login(tests.w('u_hal'));
select ok((api.permit_detail(tests.w('wah2')) #> '{close_out,duties}')::text like '%isolation%', 'an expired permit''s controls are still outstanding (P6-10)');
select is(api.hand_back_permit(tests.key(), tests.w('wah2'), tests.version('core.permit', tests.w('wah2')), false, 'Not finished', 'Barriered', true) ->> 'ok', 'true',
  'an expired permit closes out through the same hand-back');
select tests.login(tests.w('u_ada'));
select tests.must(api.remove_isolation(tests.key(), tests.w('iso2'),
  tests.version('core.isolation', tests.w('iso2')), 'Removed, locks off'));
select tests.login(tests.w('u_op'));
select tests.must(api.remove_exclusion_zone(tests.key(), (select id from core.exclusion_zone where permit_id = tests.w('wah2')),
  tests.version('core.exclusion_zone', (select id from core.exclusion_zone where permit_id = tests.w('wah2'))), 'Barriers down'));
select tests.login(tests.w('u_hana'));
select is(api.decide_hand_back(tests.key(), tests.w('wah2'), tests.version('core.permit', tests.w('wah2')), 'accept', 'in_person', 'Checked') ->> 'ok', 'true',
  'and closes once its controls are removed');
select is(api.hand_back_permit(tests.key(), tests.w('wa2'), tests.version('core.permit', tests.w('wa2')), false, 'Abandoned', 'Barriered', true) ->> 'ok', 'true',
  'then the expired Work Approval');
select tests.login(tests.w('u_hal'));
select tests.must(api.decide_hand_back(tests.key(), tests.w('wa2'), tests.version('core.permit', tests.w('wa2')), 'accept', 'in_person', 'Closed out'));
select is(tests.status_of(tests.w('wa2')), 'closed', 'closed');
select is((select content #>> '{abandoned,0,reason}' from core.close_out_snapshot where permit_id = tests.w('wa2')), 'Contractor has left and will not return',
  'with the abandonment kept on the record');

-- ---- Cancelling an issued permit (Q117) ---------------------------------------------------------------
select tests.set_w('wp3', tests.today_job('Signs', array[tests.w('pc_hw')]));
select tests.approve_permit(tests.permit_of(tests.w('wp3'), tests.w('pc_wa')), '{}');
select tests.approve_permit(tests.permit_of(tests.w('wp3'), tests.w('pc_hw')), '{}');
select tests.login(tests.w('u_ivy'));
select tests.must(api.issue_permit(tests.key(), tests.permit_of(tests.w('wp3'), tests.w('pc_wa')), tests.version('core.permit', tests.permit_of(tests.w('wp3'), tests.w('pc_wa')))));
select tests.login(tests.w('u_hana'));
select ok(api.cancel_issued_permit(tests.key(), tests.permit_of(tests.w('wp3'), tests.w('pc_wa')), tests.version('core.permit', tests.permit_of(tests.w('wp3'), tests.w('pc_wa'))),
  'Event changed')::text like '%Hot works permit is approved for issue, not closed%', 'an issued Work Approval is not cancelled while a permit under it is open');
select tests.login(tests.w('u_op'));
select tests.must(api.cancel_permit(tests.key(), tests.permit_of(tests.w('wp3'), tests.w('pc_hw')), tests.version('core.permit', tests.permit_of(tests.w('wp3'), tests.w('pc_hw'))),
  'No longer needed'));
select is(api.cancel_issued_permit(tests.key(), tests.permit_of(tests.w('wp3'), tests.w('pc_wa')), tests.version('core.permit', tests.permit_of(tests.w('wp3'), tests.w('pc_wa'))),
  'Event changed') ->> 'code', 'separation_of_duties', 'the applicant cannot cancel an issued permit');
select tests.login(tests.w('u_hana'));
select is(api.cancel_issued_permit(tests.key(), tests.permit_of(tests.w('wp3'), tests.w('pc_wa')), tests.version('core.permit', tests.permit_of(tests.w('wp3'), tests.w('pc_wa'))),
  'Event changed') ->> 'ok', 'true', 'an appointed issuer cancels it before acceptance');
select is(api.cancel_issued_permit(tests.key(), tests.w('wa'), tests.version('core.permit', tests.w('wa')), 'Late') ->> 'code', 'not_cancellable',
  'once accepted, a permit is handed back, not cancelled');

-- ---- Emergency work (Q91, Q92, Q96, Q97, P6-11) -----------------------------------------------------------
select tests.login(tests.w('u_eve'));
select is(api.authorise_emergency(tests.key(), tests.w('v1'), 'Make safe', 'Exposed live cable', 'Public at risk', array[tests.w('hall1')], '{}',
  tests.w('org_o'), array[tests.w('p_op')], 'Area cordoned') ->> 'code', 'not_configured',
  'emergency work cannot be authorised until the venue has defined it (Q91, Q97)');
select tests.login(tests.w('u_tom'));
select is(api.publish_emergency_config(tests.key(), tests.w('v1'), '{}', 24, now(), 'Rules') ->> 'code', 'invalid_content', 'the definitions have no default');
select tests.must(api.publish_emergency_config(tests.key(), tests.w('v1'), array['Make safe a dangerous electrical fault', 'Contain a water leak'], 24,
  now() - interval '1 minute', 'Emergency procedure rev. 1 (test values)'));
select tests.login(tests.w('u_op'));
select is(api.authorise_emergency(tests.key(), tests.w('v1'), 'Contain a water leak', 'Burst pipe', 'Flooding the hall', array[tests.w('hall1')], '{}',
  tests.w('org_o'), array[tests.w('p_op')], 'Water off at the main') ->> 'code', 'no_covering_appointment', 'a contractor cannot authorise emergency work');
select tests.login(tests.w('u_a1'));
select is(api.authorise_emergency(tests.key(), tests.w('v1'), 'Contain a water leak', 'Burst pipe', 'Flooding the hall', array[tests.w('hall1')], '{}',
  tests.w('org_o'), array[tests.w('p_op')], 'Water off at the main') ->> 'code', 'no_covering_appointment', 'nor a tenant administrator (invariant 9)');
select tests.login(tests.w('u_eve'));
select is(api.authorise_emergency(tests.key(), tests.w('v1'), 'Anything urgent', 'Burst pipe', 'Flooding', array[tests.w('hall1')], '{}',
  tests.w('org_o'), array[tests.w('p_op')], 'Water off') ->> 'code', 'invalid_content', 'only the venue''s own categories');
select is(api.authorise_emergency(tests.key(), tests.w('v1'), 'Contain a water leak', 'Burst pipe', ' ', array[tests.w('hall1')], '{}',
  tests.w('org_o'), array[tests.w('p_op')], 'Water off') ->> 'code', 'invalid_content', 'and why it could not wait must be recorded (Q96)');
insert into t_r select 'em', api.authorise_emergency(tests.key(), tests.w('v1'), 'Contain a water leak', 'Burst pipe above stand 4', 'Water running onto live sockets',
  array[tests.w('hall1')], '{}', tests.w('org_o'), array[tests.w('p_op'), tests.w('p_owen')], 'Water off at the main; sockets isolated at DB-3');
select is((select v ->> 'ok' from t_r where name = 'em'), 'true', 'the emergency authority authorises the work to start');
select ok((select v ->> 'reference' from t_r where name = 'em') like 'EM-%', 'with a reference');
select tests.logout();
select is((select string_agg(distinct class, ',') from core.notification where event = 'emergency_authorised'
             and record_id = (select (v ->> 'id')::uuid from t_r where name = 'em')), 'critical', 'emergency work is a critical notice (P8-3)');
select is((select count(*)::int from core.notification where event = 'emergency_authorised' and recipient_person_id = tests.w('p_a1')), 1,
  'to the venue''s administrators');
select is((select count(*)::int from core.notification where event = 'emergency_authorised' and recipient_person_id = tests.w('p_eve')), 0,
  'not to the person who authorised it');
select tests.login(tests.w('u_eve'));
select is((select (x ->> 'overdue')::boolean from jsonb_array_elements(api.emergency_register() -> 'emergencies') x), false,
  'the retrospective permit is due within the venue''s deadline');
select tests.logout();
alter table core.emergency_work disable trigger b_guard_update;
update core.emergency_work set deadline_at = now() - interval '1 minute';   -- time cannot pass inside a test
alter table core.emergency_work enable trigger b_guard_update;
select tests.login(tests.w('u_op'));
select is((select (x ->> 'overdue')::boolean from jsonb_array_elements(api.emergency_register() -> 'emergencies') x), true,
  'past the deadline it is overdue, and nothing is approved by it (invariant 10)');
-- The retrospective permit: a normal job by the organisation that did the work.
select tests.set_w('wp5', tests.new_job(tests.wp_input(p_areas => array[tests.w('hall1')], p_title => 'Burst pipe repair (retrospective)', p_supervisor => tests.w('p_op'))));
select tests.login(tests.w('u_orla'));
select is(api.link_retrospective_job(tests.key(), (select (v ->> 'emergency_id')::uuid from t_r where name = 'em'), tests.w('wp5')) ->> 'code',
  'not_organisation_admin', 'only the organisation that did the work links its retrospective job');
select tests.login(tests.w('u_op'));
select is(api.link_retrospective_job(tests.key(), (select (v ->> 'emergency_id')::uuid from t_r where name = 'em'), tests.w('wp5')) ->> 'ok', 'true',
  'the contractor links the retrospective job');
select is(api.link_retrospective_job(tests.key(), (select (v ->> 'emergency_id')::uuid from t_r where name = 'em'), tests.w('wp5')) ->> 'code', 'already_linked', 'once');
select tests.must(tests.answer_and_submit(tests.w('wp5'), tests.no_to_all(), array[tests.w('pc_wah')]));
select tests.login(tests.w('u_op'));
select tests.must(api.start_permits(tests.key(), tests.w('wp5')));
select tests.logout();
select ok((select core.permit_people(tests.permit_of(tests.w('wp5'), tests.w('pc_wa')))) @> to_jsonb(array[tests.w('p_eve')]),
  'the emergency''s authoriser is connected with the retrospective permit, so cannot decide or issue it (invariant 3)');
select tests.login(tests.w('u_op'));
select tests.must(api.save_permit_draft(tests.key(), tests.permit_of(tests.w('wp5'), tests.w('pc_wa')), '{}',
  (select lower(r.planned_window) from core.work_package_revision r join core.work_package w on w.current_revision_id = r.id where w.id = tests.w('wp5')),
  (select upper(r.planned_window) from core.work_package_revision r join core.work_package w on w.current_revision_id = r.id where w.id = tests.w('wp5'))));
select tests.must(api.set_permit_team(tests.key(), tests.permit_of(tests.w('wp5'), tests.w('pc_wa')), jsonb_build_array(jsonb_build_object('person_id', tests.w('p_op'), 'role', 'supervisor'))));
select tests.must(api.submit_permit(tests.key(), tests.permit_of(tests.w('wp5'), tests.w('pc_wa')), tests.version('core.permit', tests.permit_of(tests.w('wp5'), tests.w('pc_wa')))));
select is((select (x ->> 'retrospective_submitted')::boolean and not (x ->> 'overdue')::boolean
             from jsonb_array_elements(api.emergency_register() -> 'emergencies') x), true, 'once submitted, the retrospective permit is in');
select is(api.permit_detail(tests.permit_of(tests.w('wp5'), tests.w('pc_wa'))) #>> '{close_out,emergency,reference}', (select v ->> 'reference' from t_r where name = 'em'),
  'and the permit shows the emergency work it follows (Q95)');

-- ---- Visibility --------------------------------------------------------------------------------------
select tests.login(tests.w('u_nia'));
select is((select count(*)::int from api.hand_back) + (select count(*)::int from api.close_out_snapshot) + (select count(*)::int from api.emergency_work)
          + (select count(*)::int from api.area_return) + (select count(*)::int from api.control_ownership), 0,
  'an operative with no part sees none of these records');
select is(jsonb_array_length(api.emergency_register() -> 'emergencies'), 0, 'nor the emergency register');
select tests.login(tests.w('u_b1'));
select is((select count(*)::int from api.hand_back) + (select count(*)::int from api.hand_back_decision) + (select count(*)::int from api.close_out_snapshot)
          + (select count(*)::int from api.emergency_work) + (select count(*)::int from api.emergency_config_version) + (select count(*)::int from api.permit_abandonment)
          + (select count(*)::int from api.control_link) + (select count(*)::int from api.control_ownership), 0, 'another tenant sees none of them');
select is(api.decide_hand_back(tests.key(), tests.w('wa2'), 1, 'reject', 'in_person', 'Mine') ->> 'code', 'not_found', 'and cannot act on them');

select tests.logout();
select * from finish();
rollback;
