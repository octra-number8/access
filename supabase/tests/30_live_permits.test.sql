-- Live permits 6a (Q105-Q112, P6-2 to P6-7, invariants 4, 5, 6, 7, 9, 10, 11): stopping work
-- and who may lift it, re-acceptance, the database guards behind them, team changes,
-- extension, revalidation, material change and reissue, expiry while live, and tenant
-- separation.
begin;
\ir _helpers.psql
\ir _phase4.psql
select tests.approve_screening();
\ir _phase5.psql
\ir _phase6.psql
select no_plan();

create temp table t_r (name text primary key, v jsonb);
create temp table t_k (k text, ver integer);
grant all on t_r, t_k to authenticated;

select tests.set_w('wp', tests.live_job('Lamps today'));
select tests.set_w('wa', tests.permit_of(tests.w('wp'), tests.w('pc_wa')));
select tests.set_w('wah', tests.permit_of(tests.w('wp'), tests.w('pc_wah')));
select is(tests.status_of(tests.w('wa')) || '/' || tests.status_of(tests.w('wah')), 'active/active', 'the live job''s permits are active');

-- ---- Who may stop work (Q110, P6-2, invariant 9) ------------------------------------------------
select tests.login(tests.w('u_h'));
select is(api.stop_work(tests.key(), tests.w('wah'), 'unsafe_act', 'Looks unsafe') ->> 'code', 'no_covering_appointment',
  'someone with no part in the job and no appointment cannot stop it');
select tests.login(tests.w('u_a1'));
select is(api.stop_work(tests.key(), tests.w('wah'), 'unsafe_act', 'Looks unsafe') ->> 'code', 'no_covering_appointment',
  'nor can a tenant administrator, as an administrator (invariant 9)');
select tests.login(tests.w('u_platform'));
select is(api.stop_work(tests.key(), tests.w('wah'), 'unsafe_act', 'Looks unsafe') ->> 'ok', 'false', 'nor a platform administrator');
select tests.login(tests.w('u_b1'));
select is(api.stop_work(tests.key(), tests.w('wah'), 'unsafe_act', 'Looks unsafe') ->> 'code', 'not_found', 'nor anyone in another tenant');
select tests.login(tests.w('u_op'));
select is(api.stop_work(tests.key(), tests.w('wah'), 'unsafe_act', ' ') ->> 'code', 'invalid_content', 'a stop needs a reason');
select is(api.stop_work(tests.key(), tests.w('wah'), 'boredom', 'Lunch') ->> 'code', 'invalid_content', 'from the listed categories');

-- Someone on the team stops the child permit: the whole job stops.
select tests.login(tests.w('u_nia'));
select is(api.stop_work(tests.key(), tests.w('wah'), 'unsafe_act', 'MEWP outrigger on a cable cover') ->> 'code', 'no_covering_appointment',
  'an operative who is not on this team cannot stop it as a team member');
select tests.login(tests.w('u_op'));
insert into t_k values (tests.key(), null);
insert into t_r select 'stop', api.stop_work((select k from t_k), tests.w('wah'), 'unsafe_act', 'MEWP outrigger on a cable cover');
select is((select v ->> 'ok' from t_r where name = 'stop'), 'true', 'someone on the team stops the work');
select is(tests.status_of(tests.w('wah')) || '/' || tests.status_of(tests.w('wa')), 'suspended/suspended',
  'the permit is suspended, and so is its Work Approval (invariant 4)');
select is(tests.holding(tests.w('wah')), array['stop'], 'held by the stop');
select is(tests.holding(tests.w('wa')), array['job_stop'], 'and the Work Approval by a stop that comes from it');
select is((select origin_suspension_id from core.permit_suspension where permit_id = tests.w('wa') and kind = 'job_stop'),
  (select v ->> 'suspension_id' from t_r where name = 'stop')::uuid, 'which names the stop it came from');
select is((select c.action_code || ' from ' || pc.action_code from core.permit_suspension s join core.decision_context c on c.id = s.decision_context_id
             join core.decision_context pc on pc.id = c.parent_id where s.permit_id = tests.w('wa') and s.kind = 'job_stop'),
  'permit.suspend_with_job from permit.stop', 'as a derived decision of the stop');
select is(api.stop_work((select k from t_k), tests.w('wah'), 'unsafe_act', 'MEWP outrigger on a cable cover') ->> 'replayed', 'true',
  'repeating the same stop replays it (idempotency)');
select is((select count(*)::int from core.permit_suspension where permit_id = tests.w('wah')), 1, 'without a second suspension');

-- ---- Lifting (invariant 7, invariant 9) ---------------------------------------------------------
select tests.set_w('s_stop', (select (v ->> 'suspension_id')::uuid from t_r where name = 'stop'));
select tests.set_w('s_job', (select id from core.permit_suspension where permit_id = tests.w('wa') and kind = 'job_stop'));
select tests.login(tests.w('u_op'));
select is(api.lift_suspension(tests.key(), tests.w('s_stop'), 'Moved the MEWP') ->> 'code', 'separation_of_duties',
  'the supervisor cannot lift a stop on their own job');
select tests.login(tests.w('u_a1'));
select is(api.lift_suspension(tests.key(), tests.w('s_stop'), 'Admin override') ->> 'code', 'no_covering_appointment',
  'nor a tenant administrator (invariant 9)');
select tests.login(tests.w('u_platform'));
select is(api.lift_suspension(tests.key(), tests.w('s_stop'), 'Admin override') ->> 'ok', 'false', 'nor a platform administrator (invariant 9)');
select tests.login(tests.w('u_vic'));
select is(api.lift_suspension(tests.key(), tests.w('s_stop'), 'Seen it') ->> 'code', 'no_covering_appointment',
  'nor a venue authority without the lifting appointment');
select tests.login(tests.w('u_isla'));
select is(api.lift_suspension(tests.key(), tests.w('s_stop'), 'Seen it') ->> 'code', 'no_covering_appointment',
  'nor an issuer whose appointment covers only part of the job''s areas');
select tests.login(tests.w('u_ivy'));
select is(api.lift_suspension(tests.key(), tests.w('s_job'), 'Seen it') ->> 'code', 'not_this_route',
  'a stop that came from another permit is lifted at its origin');
select tests.login(tests.w('u_op'));
select is(tests.reaccept(tests.w('wa')) ->> 'code', 'still_suspended', 'nothing restarts before the lift');
select ok(tests.reaccept(tests.w('wa'))::text like '%Whoever can lift the stop on the job''s Work at height%',
  'and the refusal says who can lift it');
select tests.login(tests.w('u_ivy'));
select is(api.lift_suspension(tests.key(), tests.w('s_stop'), 'MEWP moved off the cable cover', array['Spotter at the outriggers']) ->> 'ok', 'true',
  'the issuer lifts the stop, with a condition');
select is(api.lift_suspension(tests.key(), tests.w('s_stop'), 'Again') ->> 'code', 'already_lifted', 'once');
select is(tests.status_of(tests.w('wah')) || '/' || tests.status_of(tests.w('wa')), 'suspended/suspended',
  'lifting does not restart work (P6-3)');
select is(tests.holding(tests.w('wa')) || tests.holding(tests.w('wah')), '{}'::text[], 'but nothing holds either permit now');

-- ---- Re-acceptance (P6-3) ---------------------------------------------------------------------
select is(tests.reaccept(tests.w('wah')) ->> 'code', 'parent_not_active', 'the child restarts only after its Work Approval');
select tests.login(tests.w('u_vic'));
select is(api.reaccept_permit(tests.key(), tests.w('wa'), tests.version('core.permit', tests.w('wa')), tests.conditions_of(tests.w('wa')),
  tests.open_lifts(tests.w('wa')), array[tests.w('p_op')], clock_timestamp()) ->> 'code', 'not_permit_part',
  'only the supervisor re-accepts, not even a venue authority');
select tests.login(tests.w('u_op'));
select is(api.reaccept_permit(tests.key(), tests.w('wa'), tests.version('core.permit', tests.w('wa')), tests.conditions_of(tests.w('wa')),
  tests.open_lifts(tests.w('wa')), array[tests.w('p_op')], (select created_at from core.permit_suspension_lift where suspension_id = tests.w('s_stop')) - interval '1 second') ->> 'code',
  'briefing_incomplete', 'the re-briefing must come after the lift');
select is(api.reaccept_permit(tests.key(), tests.w('wa'), tests.version('core.permit', tests.w('wa')), tests.conditions_of(tests.w('wa')),
  '{}', array[tests.w('p_op')], clock_timestamp()) ->> 'code', 'conditions_not_acknowledged',
  'and every condition set at the lift must be acknowledged');
select is(api.reaccept_permit(tests.key(), tests.w('wa'), tests.version('core.permit', tests.w('wa')) - 1, tests.conditions_of(tests.w('wa')),
  tests.open_lifts(tests.w('wa')), array[tests.w('p_op')], clock_timestamp()) ->> 'code', 'changed',
  'from a page that is out of date, re-acceptance is refused (invariant 11)');
select is(tests.reaccept(tests.w('wa')) ->> 'ok', 'true', 'the supervisor re-briefs and re-accepts the Work Approval');
select is(tests.reaccept(tests.w('wah')) ->> 'ok', 'true', 'then the work-at-height permit');
select is(tests.status_of(tests.w('wa')) || '/' || tests.status_of(tests.w('wah')), 'active/active', 'both active again');
select is((select acknowledged_lift_ids from core.permit_reacceptance where permit_id = tests.w('wah')),
  array[(select id from core.permit_suspension_lift where suspension_id = tests.w('s_stop'))], 'with the lift''s condition acknowledged');

-- ---- The database guards (invariants 4 and 7), whatever the API does ---------------------------------
-- Straight to the decision machinery, bypassing the API's own checks.
select tests.logout();
create function tests.force_restart(p_permit uuid) returns void language plpgsql security definer as $$
declare p core.permit; v jsonb; ctx uuid; snap core.issue_snapshot;
begin
  select * into p from core.permit where id = p_permit;
  select * into snap from core.issue_snapshot where id = p.issue_snapshot_id;
  v := authz.require('permit.reaccept', core.live_target(p), gen_random_uuid()::text, '{}');
  ctx := (v ->> 'decision_context_id')::uuid;
  insert into core.permit_reacceptance (customer_id, venue_id, permit_id, issue_snapshot_id, supervisor_person_id, declaration, declaration_sha256,
                                        acknowledged_condition_ids, acknowledged_lift_ids, briefed_person_ids, briefed_at, decision_context_id)
  values (p.customer_id, p.venue_id, p.id, snap.id, (v ->> 'actor_person_id')::uuid, '[]', sha256(''::bytea), '{}', '{}',
          array[(v ->> 'actor_person_id')::uuid], clock_timestamp(), ctx);
  perform core.transition('core.permit', p.id, 'active', p.row_version, ctx);
  perform core.check_live_now();
end $$;
grant execute on function tests.force_restart(uuid) to authenticated;
select tests.login(tests.w('u_op'));
select tests.must(api.stop_work(tests.key(), tests.w('wah'), 'change_in_conditions', 'Wind picking up'));
select tests.set_w('s_wind', (select id from core.permit_suspension where permit_id = tests.w('wah') and kind = 'stop' and reason = 'Wind picking up'));
select throws_ok($$ select tests.force_restart(tests.w('wa')) $$, '23514', 'a suspended permit becomes active only once every suspension is lifted',
  'the database refuses to restart a permit that a suspension still holds (invariant 7)');
select tests.login(tests.w('u_ivy'));
select tests.must(api.lift_suspension(tests.key(), tests.w('s_wind'), 'Wind dropped'));
select tests.login(tests.w('u_op'));
select throws_ok($$ select tests.force_restart(tests.w('wah')) $$, '23514', 'a permit cannot be active while its Work Approval is not active',
  'nor lets a child be active while its Work Approval is not (invariant 4)');
select tests.must(tests.reaccept(tests.w('wa')));
select tests.must(tests.reaccept(tests.w('wah')));
-- A Work Approval cannot be active while a permit on its job is held: try to restart it under a fresh child stop.
select tests.logout();
create function tests.force_child_stop_only(p_child uuid) returns void language plpgsql security definer as $$
declare p core.permit; v jsonb;
begin
  select * into p from core.permit where id = p_child;
  v := authz.require('permit.stop', core.live_target(p), gen_random_uuid()::text, '{}');
  if not (v ->> 'ok')::boolean then raise exception 'not authorised: %', v; end if;
  perform core.suspend_one(p.id, 'stop', 'other', 'Stopped without its job', null, null, (v ->> 'actor_person_id')::uuid);
  perform core.check_live_now();
end $$;
grant execute on function tests.force_child_stop_only(uuid) to authenticated;
select tests.login(tests.w('u_op'));
select throws_ok($$ select tests.force_child_stop_only(tests.w('wah')) $$, '23514', 'a Work Approval cannot be active while a permit on its job is suspended and not lifted',
  'and a child cannot be held while its Work Approval stays active (invariant 4)');
select tests.logout();
create function tests.raw_status(p_permit uuid, p_status text) returns void language plpgsql security definer as $$
begin
  update core.permit set status = p_status where id = p_permit;
end $$;
grant execute on function tests.raw_status(uuid, text) to authenticated;
select throws_ok($$ select tests.raw_status(tests.w('wa'), 'suspended') $$, '42501', null,
  'and a status cannot be written except through a decision');

-- ---- Others who may stop: the occupier, a venue authority, an area stop (P6-2) ------------------------
select tests.login(tests.w('u_orla'));
insert into t_r select 'party', api.stop_work(tests.key(), tests.w('wa'), 'instruction', 'Our stand opens to visitors early');
select is((select v ->> 'ok' from t_r where name = 'party'), 'true', 'the job''s occupier stops the work');
select is((select action_code from core.decision_context where id = (select v ->> 'decision_context_id' from t_r where name = 'party')::uuid),
  'permit.stop_as_party', 'as a party to the job');
select is(tests.holding(tests.w('wah')), array['job_stop'], 'and the child is held by it');
select tests.login(tests.w('u_ivy'));
select tests.must(api.lift_suspension(tests.key(), (select (v ->> 'suspension_id')::uuid from t_r where name = 'party'), 'Agreed with the occupier'));
select tests.must(tests.reaccept(tests.w('wa')));
select tests.must(tests.reaccept(tests.w('wah')));
select tests.login(tests.w('u_vic'));
select is(api.stop_work(tests.key(), tests.w('wah'), 'emergency', 'Fire alarm in Hall 2') ->> 'ok', 'true', 'a venue authority stops the work');
select tests.login(tests.w('u_ivy'));
select tests.must(api.lift_suspension(tests.key(), (select id from core.permit_suspension where permit_id = tests.w('wah') and reason = 'Fire alarm in Hall 2'), 'All clear'));
select tests.must(tests.reaccept(tests.w('wa')));
select tests.must(tests.reaccept(tests.w('wah')));

-- Area stop: everything touching HALL1 or inside it.
select tests.login(tests.w('u_ivy'));
select is(api.stop_area(tests.key(), tests.w('hall1'), 'emergency', 'Evacuation') ->> 'code', 'no_covering_appointment',
  'an issuer without the area-stop appointment cannot stop an area');
select tests.login(tests.w('u_vic'));
insert into t_r select 'area', api.stop_area(tests.key(), tests.w('site'), 'emergency', 'Evacuation of the site');
select is((select (v ->> 'suspended')::int from t_r where name = 'area'), 2, 'a venue authority stops the site: both permits');
select is(tests.holding(tests.w('wa')) || tests.holding(tests.w('wah')), array['area_stop', 'area_stop'], 'each held by the area stop');
select tests.login(tests.w('u_ivy'));
select is(api.lift_suspension(tests.key(), (select id from core.permit_suspension where permit_id = tests.w('wa') and kind = 'area_stop'), 'Fine') ->> 'code',
  'not_this_route', 'an area stop is not lifted permit by permit');
select is(api.lift_area_stop(tests.key(), (select v ->> 'area_stop_id' from t_r where name = 'area')::uuid, 'All clear') ->> 'code',
  'no_covering_appointment', 'nor by an issuer');
select tests.login(tests.w('u_vic'));
select is(api.lift_area_stop(tests.key(), (select v ->> 'area_stop_id' from t_r where name = 'area')::uuid, 'All clear', array['Re-check exits']) ->> 'ok',
  'true', 'the venue authority lifts it');
select is(tests.reaccept(tests.w('wa')) ->> 'ok', 'true', 'and the supervisor re-accepts, acknowledging its condition');
select tests.must(tests.reaccept(tests.w('wah')));

-- ---- The live team (Q106, Q107, P6-6) ---------------------------------------------------------------
select tests.login(tests.w('u_nia'));
select is(api.add_worker(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), tests.w('p_nia')) ->> 'code', 'not_permit_part',
  'only the supervisor adds people');
select tests.login(tests.w('u_op'));
select is(api.add_worker(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), tests.w('p_h')) ->> 'code', 'not_ready',
  'someone who does not work with the organisation cannot join');
select is(api.add_worker(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), tests.w('p_owen')) ->> 'code', 'already_on_team',
  'nor someone already on it');
-- Suspension after the page was loaded (invariant 11).
insert into t_k select tests.key(), tests.version('core.permit', tests.w('wah'));
select tests.must(api.stop_work(tests.key(), tests.w('wah'), 'other', 'Checking the harnesses'));
select is(api.add_worker(tests.key(), tests.w('wah'), (select ver from t_k where ver is not null), tests.w('p_nia')) ->> 'code', 'changed',
  'a change made on a page loaded before a stop is refused');
select tests.login(tests.w('u_ivy'));
select tests.must(api.lift_suspension(tests.key(), (select id from core.permit_suspension where permit_id = tests.w('wah') and reason = 'Checking the harnesses'), 'Checked'));
select tests.must(tests.reaccept(tests.w('wa')));
select tests.must(tests.reaccept(tests.w('wah')));
select tests.login(tests.w('u_op'));
insert into t_r select 'add', api.add_worker(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), tests.w('p_nia'));
select is((select v ->> 'approval_required' from t_r where name = 'add'), 'true', 'this class needs an issuer to approve additions');
select tests.set_w('m_nia', (select (v ->> 'member_id')::uuid from t_r where name = 'add'));
select is(api.brief_worker(tests.key(), tests.w('m_nia'), clock_timestamp()) ->> 'code', 'not_approved', 'so Nia cannot be briefed yet');
select is((select (x ->> 'counts')::boolean from jsonb_array_elements(api.permit_detail(tests.w('wah')) -> 'team_live') x
            where x ->> 'person_id' = tests.w('p_nia')::text), false, 'and does not count as part of the team');
select is(api.approve_worker(tests.key(), tests.w('m_nia')) ->> 'code', 'separation_of_duties', 'the supervisor cannot approve their own addition');
select tests.login(tests.w('u_ivy'));
select is(api.approve_worker(tests.key(), tests.w('m_nia')) ->> 'ok', 'true', 'the issuer approves it');
select tests.login(tests.w('u_op'));
select is(api.brief_worker(tests.key(), tests.w('m_nia'), clock_timestamp() + interval '1 hour') ->> 'code', 'briefing_incomplete',
  'a briefing cannot be in the future');
select is(api.brief_worker(tests.key(), tests.w('m_nia'), clock_timestamp()) ->> 'ok', 'true', 'the supervisor briefs Nia');
select is((select (x ->> 'counts')::boolean from jsonb_array_elements(api.permit_detail(tests.w('wah')) -> 'team_live') x
            where x ->> 'person_id' = tests.w('p_nia')::text), true, 'and now Nia counts');
select is(tests.status_of(tests.w('wah')), 'active', 'the permit stayed active throughout');
select tests.login(tests.w('u_nia'));
insert into t_r select 'nia_stop', api.stop_work(tests.key(), tests.w('wah'), 'unsafe_act', 'Harness lanyard frayed');
select is((select v ->> 'ok' from t_r where name = 'nia_stop'), 'true', 'once on the team, an operative can stop the work too');
select tests.login(tests.w('u_ivy'));
insert into t_k select 'lift-nia', null;
select tests.must(api.lift_suspension('lift-nia', (select (v ->> 'suspension_id')::uuid from t_r where name = 'nia_stop'), 'Lanyard replaced'));
select is(api.lift_suspension('lift-nia', (select (v ->> 'suspension_id')::uuid from t_r where name = 'nia_stop'), 'Lanyard replaced') ->> 'replayed', 'true',
  'repeating a lift replays it (idempotency)');
select tests.must(tests.reaccept(tests.w('wa')));
select tests.must(tests.reaccept(tests.w('wah')));
-- Removal.
select tests.set_w('m_owen', (select id from core.permit_team_member where permit_id = tests.w('wah') and person_id = tests.w('p_owen') and removed_at is null));
select tests.login(tests.w('u_nia'));
select is(api.exclude_worker(tests.key(), tests.w('m_owen'), 'Not wearing a harness') ->> 'code', 'no_covering_appointment',
  'an operative cannot remove someone');
select tests.login(tests.w('u_op'));
select is(api.exclude_worker(tests.key(), (select id from core.permit_team_member where permit_id = tests.w('wah') and role = 'supervisor' and removed_at is null),
  'Going home') ->> 'code', 'is_supervisor', 'the supervisor is not removed this way');
select is(api.exclude_worker(tests.key(), tests.w('m_owen'), 'Not wearing a harness') ->> 'ok', 'true', 'the supervisor removes Owen');
select is(tests.status_of(tests.w('wah')), 'active', 'without suspending the permit (Q107)');
select is(api.exclude_worker(tests.key(), tests.w('m_owen'), 'Again') ->> 'code', 'not_on_team', 'once');
select is((select removal_reason from core.permit_team_member where id = tests.w('m_owen')), 'Not wearing a harness', 'the removal keeps its record');
select throws_ok($$ update core.permit_team_member set removal_reason = 'Changed' where id = tests.w('m_owen') $$, '42501', null,
  'which cannot be rewritten');

-- Supervisor change: an issuer's decision; suspended until the new supervisor re-accepts.
select tests.login(tests.w('u_op'));
select is(api.change_supervisor(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), tests.w('p_nia'), true, 'OP going home') ->> 'code',
  'separation_of_duties', 'the supervisor cannot hand the permit over alone');
select tests.login(tests.w('u_ivy'));
select is(api.change_supervisor(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), tests.w('p_h'), true, 'Swap') ->> 'code',
  'not_ready', 'the new supervisor must pass the same checks');
select is(api.change_supervisor(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), tests.w('p_nia'), true, 'OP going home') ->> 'ok',
  'true', 'the issuer makes Nia the supervisor');
select is(tests.status_of(tests.w('wah')) || '/' || tests.status_of(tests.w('wa')), 'suspended/active',
  'the permit is suspended until she accepts; the Work Approval carries on');
select is(tests.holding(tests.w('wah')), '{}'::text[], 'nothing else holds it');
select is(tests.reaccept(tests.w('wah')) ->> 'code', 'not_permit_part', 'the previous supervisor, now an operative, cannot re-accept');
select is(tests.reaccept(tests.w('wah'), tests.w('u_nia')) ->> 'ok', 'true', 'Nia re-accepts as the new supervisor');
select is((select supervisor_person_id from core.permit_reacceptance where permit_id = tests.w('wah') order by accepted_at desc limit 1), tests.w('p_nia'),
  'recorded against her');

-- ---- Extension (Q108, P6-5) -------------------------------------------------------------------------
select tests.logout();
select tests.set_w('snap_sha', (select md5(encode(content_sha256, 'hex'))::uuid from core.issue_snapshot where id = (select issue_snapshot_id from core.permit where id = tests.w('wah'))));
select tests.login(tests.w('u_nia'));
select is(api.extend_permit(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), tests.window_end(tests.w('wah')) + interval '2 hours',
  'Running late') ->> 'code', 'separation_of_duties', 'the supervisor cannot extend their own permit');
select tests.login(tests.w('u_ivy'));
select ok(api.extend_permit(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), tests.window_end(tests.w('wah')) + interval '30 hours',
  'Running late')::text like '%24 hours of extension in total%', 'an extension stays within the class''s total');
select ok(api.extend_permit(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), tests.window_end(tests.w('wah')) + interval '20 hours',
  'Running late')::text like '%extend the Work Approval first%', 'and a permit cannot run beyond its Work Approval');

select ok(api.extend_permit(tests.key(), tests.w('wa'), tests.version('core.permit', tests.w('wa')), tests.window_end(tests.w('wa')) + interval '30 hours',
  'Running late')::text like '%beyond its job''s planned dates%', 'nor beyond the job''s planned dates');
select tests.login(tests.w('u_ivy'));
insert into t_r select 'ext_wa', api.extend_permit(tests.key(), tests.w('wa'), tests.version('core.permit', tests.w('wa')),
  tests.window_end(tests.w('wa')) + interval '3 hours', 'Lamps arrived late');
select is((select v ->> 'ok' from t_r where name = 'ext_wa'), 'true', 'the issuer extends the Work Approval by three hours');
select tests.login(tests.w('u_op'));
select tests.must(api.acknowledge_extension(tests.key(), (select v ->> 'extension_id' from t_r where name = 'ext_wa')::uuid));
select tests.login(tests.w('u_ivy'));
insert into t_r select 'ext', api.extend_permit(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')),
  tests.window_end(tests.w('wah')) + interval '2 hours', 'Lamps arrived late');
select is((select v ->> 'ok' from t_r where name = 'ext'), 'true', 'the issuer extends by two hours');
select is(tests.window_end(tests.w('wah')), (select previous_end from core.permit_extension where id = (select v ->> 'extension_id' from t_r where name = 'ext')::uuid),
  'which does not count until the supervisor acknowledges it');
select is(api.extend_permit(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), tests.window_end(tests.w('wah')) + interval '3 hours',
  'More') ->> 'code', 'extension_pending', 'one extension at a time');
select tests.login(tests.w('u_op'));
select is(api.acknowledge_extension(tests.key(), (select v ->> 'extension_id' from t_r where name = 'ext')::uuid) ->> 'code', 'not_permit_part',
  'only the supervisor acknowledges it');
select tests.login(tests.w('u_nia'));
select is(api.acknowledge_extension(tests.key(), (select v ->> 'extension_id' from t_r where name = 'ext')::uuid) ->> 'ok', 'true', 'the supervisor does');
select is(tests.window_end(tests.w('wah')), (select new_end from core.permit_extension where id = (select v ->> 'extension_id' from t_r where name = 'ext')::uuid),
  'and the permit now runs to the new end');
select tests.login(tests.w('u_ivy'));
select ok(api.extend_permit(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), tests.window_end(tests.w('wah')) + interval '1 hour',
  'More')::text like '%allows 1 extension(s), and they have been used%', 'the class allows one extension');
select is((select md5(encode(content_sha256, 'hex'))::uuid from core.issue_snapshot where id = (select issue_snapshot_id from core.permit where id = tests.w('wah'))),
  tests.w('snap_sha'), 'the issue snapshot is unchanged: the extension is an addendum (invariant 5)');
select is((select content ->> 'issue_snapshot_id' from core.permit_extension where id = (select v ->> 'extension_id' from t_r where name = 'ext')::uuid),
  (select issue_snapshot_id::text from core.permit where id = tests.w('wah')), 'that names the snapshot it extends');
select throws_ok($$ update core.permit_extension set new_end = new_end + interval '1 day' $$, '42501', null, 'and cannot be rewritten');

-- ---- Revalidation (Q112, P6-7) ----------------------------------------------------------------------
select is((api.permit_detail(tests.w('wah')) #>> '{revalidation,every_hours}')::numeric, 4::numeric, 'this class needs revalidation every four hours');
select is((api.permit_detail(tests.w('wah')) #>> '{revalidation,due_at}')::timestamptz,
  (api.permit_detail(tests.w('wah')) #>> '{revalidation,last_at}')::timestamptz + interval '4 hours', 'due four hours after the last acceptance');
select is((api.permit_detail(tests.w('wah')) #>> '{revalidation,overdue}')::boolean, false, 'not yet overdue');
select tests.login(tests.w('u_op'));
select is(api.revalidate_permit(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah'))) ->> 'code', 'not_permit_part',
  'only the supervisor revalidates');
select is(api.revalidate_permit(tests.key(), tests.w('wa'), tests.version('core.permit', tests.w('wa'))) ->> 'code', 'not_required',
  'a class without revalidation has nothing to revalidate');
select tests.login(tests.w('u_nia'));
select is(api.revalidate_permit(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), 'Wind 12 mph, inside the limit') ->> 'ok', 'true',
  'the supervisor revalidates, noting the conditions');

-- ---- Material change and reissue (invariant 6, P6-4) ---------------------------------------------------
select tests.logout();
select tests.set_w('snap_wah_1', (select issue_snapshot_id from core.permit where id = tests.w('wah')));
select tests.login(tests.w('u_op'));
insert into t_r select 'revise', api.revise_work_package(tests.key(), tests.w('wp'), tests.version('core.work_package', tests.w('wp')),
  jsonb_set(jsonb_set(tests.wp_input(p_areas => array[tests.w('hall1')], p_title => 'Lamps today', p_supervisor => tests.w('p_op')),
    '{window_from}', to_jsonb((select lower(planned_window) from core.work_package_revision r join core.work_package w on w.current_revision_id = r.id
                               where w.id = tests.w('wp'))::text)),
    '{window_to}', to_jsonb((select upper(planned_window) from core.work_package_revision r join core.work_package w on w.current_revision_id = r.id
                             where w.id = tests.w('wp'))::text)), 'Hall 2 no longer needed');
select is((select v ->> 'change_kind' from t_r where name = 'revise'), 'material', 'the job changes materially while its permits are live');
select is(tests.status_of(tests.w('wa')) || '/' || tests.status_of(tests.w('wah')), 'suspended/suspended', 'both permits are suspended');
select is(tests.holding(tests.w('wa')) || tests.holding(tests.w('wah')), array['material_change', 'material_change'], 'for the material change');
select is((select c.action_code from core.permit_suspension s join core.decision_context c on c.id = s.decision_context_id
            where s.permit_id = tests.w('wa') and s.kind = 'material_change'), 'permit.suspend_for_change', 'as derived decisions of the change');
select tests.login(tests.w('u_ivy'));
select is(api.lift_suspension(tests.key(), (select id from core.permit_suspension where permit_id = tests.w('wah') and kind = 'material_change'), 'Fine') ->> 'code',
  'not_this_route', 'a material change cannot be lifted');
select is(tests.reaccept(tests.w('wa'), tests.w('u_op')) ->> 'code', 'still_suspended', 'nor worked under: the permit must be reissued');
select ok(tests.reaccept(tests.w('wa'), tests.w('u_op'))::text like '%must be submitted again and reissued%', 'which the refusal says');
-- A stop on top of the change must be lifted before the permit can be submitted again.
select tests.login(tests.w('u_vic'));
select tests.must(api.stop_work(tests.key(), tests.w('wah'), 'other', 'Hold everything while we replan'));
select tests.must(tests.answer_and_submit(tests.w('wp'), tests.no_to_all(), array[tests.w('pc_wah')]));
select tests.login(tests.w('u_op'));
select is(api.save_permit_draft(tests.key(), tests.w('wah'), '{"access": ["scaffold"]}', now() - interval '1 hour', now() + interval '1 day') ->> 'code',
  'not_draft', 'a permit held by anything other than the change cannot be prepared again');
select is(api.submit_permit(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah'))) ->> 'code', 'suspended',
  'nor submitted again');
select is(api.save_permit_draft(tests.key(), tests.w('wa'), '{}', now() - interval '1 hour', now() + interval '1 day') ->> 'code', 'not_draft',
  'and the stop holds the Work Approval too');
select throws_ok($$ select tests.raw_status(tests.w('wah'), 'submitted') $$, '42501', null, 'nor can its status be written directly');
select is(api.set_permit_team(tests.key(), tests.w('wah'), jsonb_build_array(jsonb_build_object('person_id', tests.w('p_op'), 'role', 'supervisor'),
  jsonb_build_object('person_id', tests.w('p_owen'), 'role', 'operative'))) ->> 'code', 'not_open', 'the team is not changed wholesale on a live permit');
select tests.login(tests.w('u_ivy'));
select tests.must(api.lift_suspension(tests.key(), (select id from core.permit_suspension where permit_id = tests.w('wah') and reason = 'Hold everything while we replan'),
  'Replanned'));
select tests.login(tests.w('u_op'));
select tests.must(api.save_permit_draft(tests.key(), tests.w('wa'), '{}', now() - interval '1 hour', now() + interval '1 day'));
select tests.must(api.save_permit_draft(tests.key(), tests.w('wah'), '{"access": ["scaffold"]}', now() - interval '1 hour', now() + interval '1 day'));
select is(api.submit_permit(tests.key(), tests.w('wa'), tests.version('core.permit', tests.w('wa'))) ->> 'ok', 'true', 'the Work Approval is submitted again');
select tests.must(api.set_permit_team(tests.key(), tests.w('wa'), jsonb_build_array(jsonb_build_object('person_id', tests.w('p_op'), 'role', 'supervisor'),
  jsonb_build_object('person_id', tests.w('p_owen'), 'role', 'operative'))));
select is(api.submit_permit(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah'))) ->> 'ok', 'true', 'and the work-at-height permit');
select tests.must(api.set_permit_team(tests.key(), tests.w('wah'), jsonb_build_array(jsonb_build_object('person_id', tests.w('p_op'), 'role', 'supervisor'),
  jsonb_build_object('person_id', tests.w('p_owen'), 'role', 'operative'))));
select is(tests.holding(tests.w('wa')) || tests.holding(tests.w('wah')), '{}'::text[], 'which resolves the material-change suspensions');
select is((select via from core.permit_suspension_lift l join core.permit_suspension s on s.id = l.suspension_id
            where s.permit_id = tests.w('wah') and s.kind = 'material_change'), 'reissue', 'recorded as resolved by reissue');
select is((select version_no from core.permit_version where id = (select current_version_id from core.permit where id = tests.w('wah'))), 2,
  'as a new version');
select is((api.permit_detail(tests.w('wah')) #>> '{steps,0,previous,outcome}'), 'conditions', 'whose reviewers see the previous decisions (P5-7)');
select tests.logout();
create function tests.decide_all(p_permit uuid) returns void language plpgsql as $$
declare s record;
begin
  for s in select ps.id, ps.kind from core.permit_step ps join core.permit p on p.current_version_id = ps.permit_version_id
            where p.id = p_permit order by ps.group_no, ps.step_key loop
    perform tests.login(case when s.kind = 'occupier' then tests.w('u_olga') else tests.w('u_pam') end);
    perform tests.must(api.decide_step(tests.key(), s.id, 'no_further_comments', 'Re-reviewed for Hall 1 only', 'Hall 1 only', '[]'));
  end loop;
  perform tests.logout();
end $$;
grant execute on function tests.decide_all(uuid) to authenticated;
select tests.decide_all(tests.w('wa'));
select tests.decide_all(tests.w('wah'));
select is(tests.status_of(tests.w('wa')) || '/' || tests.status_of(tests.w('wah')), 'approved_for_issue/approved_for_issue', 'both approved again');
select tests.issue_and_accept(tests.w('wa'));
select tests.issue_and_accept(tests.w('wah'));
select is(tests.status_of(tests.w('wa')) || '/' || tests.status_of(tests.w('wah')), 'active/active', 'reissued and accepted: active again');
select isnt((select issue_snapshot_id from core.permit where id = tests.w('wah')), tests.w('snap_wah_1'), 'under a new issue snapshot');
select is((select content ->> 'previous_snapshot_id' from core.issue_snapshot where id = (select issue_snapshot_id from core.permit where id = tests.w('wah'))),
  tests.w('snap_wah_1')::text, 'that names the one it replaces');
select is((select md5(encode(content_sha256, 'hex'))::uuid from core.issue_snapshot where id = tests.w('snap_wah_1')), tests.w('snap_sha'),
  'which is unchanged (invariant 5)');
select is(tests.window_end(tests.w('wah')), (select upper(planned_window) from core.permit_version where id = (select current_version_id from core.permit where id = tests.w('wah'))),
  'an extension of the old issue does not carry over');

-- ---- Expiry while live (invariant 10) ------------------------------------------------------------------
-- Time cannot pass inside a test, so the Work Approval's window is moved into the past directly.
select tests.logout();
alter table core.permit_version disable trigger b_forbid_update;
update core.permit_version set planned_window = tstzrange(lower(planned_window), now() - interval '1 minute')
 where id = (select current_version_id from core.permit where id = tests.w('wa'));
alter table core.permit_version enable trigger b_forbid_update;
select tests.login(tests.w('u_exp'));
select is((api.expire_permits() ->> 'expired')::int, 1, 'the Work Approval''s window ends and it expires');
select is(tests.status_of(tests.w('wa')) || '/' || tests.status_of(tests.w('wah')), 'expired/suspended',
  'its active child is suspended: it cannot continue without its Work Approval');
select is(tests.holding(tests.w('wah')), array['parent_ended'], 'held until it is handed back');
select is((api.expire_permits() ->> 'expired')::int, 0, 'running the job again changes nothing');
select ok(tests.reaccept(tests.w('wah')) ->> 'code' in ('still_suspended', 'parent_not_active'), 'and nothing restarts it');
select tests.login(tests.w('u_ivy'));
select is(api.extend_permit(tests.key(), tests.w('wa'), tests.version('core.permit', tests.w('wa')), now() + interval '1 hour', 'Revive') ->> 'code', 'not_live',
  'an expired permit cannot be extended back to life');

-- ---- Reads and separation -------------------------------------------------------------------------
select tests.login(tests.w('u_op'));
select ok(jsonb_array_length(api.permit_detail(tests.w('wah')) -> 'suspensions') >= 5, 'the permit''s detail lists its suspensions');
select ok((select bool_and(x ? 'who_lifts') from jsonb_array_elements(api.permit_detail(tests.w('wah')) -> 'suspensions') x),
  'each with who can lift it');
select ok(api.permit_detail(tests.w('wah'))::text !~* '(op@a\.test|07000|nia@a\.test)', 'and never anyone''s contact details');
select tests.login(tests.w('u_h'));
select is((select count(*)::int from api.permit_suspension), 0, 'someone with no part in it sees no suspensions');
select is((select count(*)::int from api.permit_team_member where permit_id = tests.w('wah')), 0, 'nor the team');
select tests.login(tests.w('u_b1'));
select is((select count(*)::int from api.permit_suspension) + (select count(*)::int from api.area_stop)
          + (select count(*)::int from api.permit_extension) + (select count(*)::int from api.permit_reacceptance)
          + (select count(*)::int from api.permit_revalidation) + (select count(*)::int from api.permit_suspension_lift)
          + (select count(*)::int from api.area_stop_lift), 0, 'another tenant sees none of the live records');
select is(api.lift_area_stop(tests.key(), (select (v ->> 'area_stop_id')::uuid from t_r where name = 'area'), 'Mine now') ->> 'code', 'not_found',
  'and cannot act on them');

-- ---- Configuration has no default (P6-5 to P6-7) -------------------------------------------------------
select tests.logout();
select ok(core.validate_class_config(tests.w('v1'), tests.class_config('[{"key": "r", "name": "Review", "kind": "review", "group": 1}]') - 'extension', true)
  @> array['Set how many times, and for how many hours in total, a permit of this class can be extended (P6-5): there is no default.'],
  'a configuration must set extension limits');
select ok(core.validate_class_config(tests.w('v1'), tests.class_config('[{"key": "r", "name": "Review", "kind": "review", "group": 1}]') - 'worker_add', true)
  @> array['Choose who approves people added to the team after issue (P6-6): there is no default.'], 'who approves additions');
select ok(core.validate_class_config(tests.w('v1'), tests.class_config('[{"key": "r", "name": "Review", "kind": "review", "group": 1}]') - 'revalidation', true)
  @> array['Choose whether a live permit of this class must be revalidated, and how often (P6-7): there is no default.'], 'and revalidation');
select ok(cardinality(core.validate_class_config(tests.w('v1'), tests.class_config('[{"key": "r", "name": "Review", "kind": "review", "group": 1}]')
  || '{"revalidation": {"mode": "interval", "every_hours": 0}}', true)) > 0, 'revalidation every zero hours is not a choice');

select tests.logout();
select * from finish();
rollback;
