-- Gate 7a (Q190-Q197, P7-2 to P7-6, P7-12, invariants 1, 3, 9, 11): entry rules with no
-- default, passes that cannot be copied, the evaluation in words with owners, what the
-- operator did, overrides and their fixed floor, permits only as notices, and separation.
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

-- ---- Set-up: gate points, an operator for Hall 1 and an access authority -------------------------
select tests.login(tests.w('u_a1'));
select tests.set_w('north', tests.must(api.create_gate_point(tests.key(), tests.w('v1'), tests.w('hall1'), 'North gate')));
select tests.set_w('h2door', tests.must(api.create_gate_point(tests.key(), tests.w('v1'), tests.w('hall2'), 'Hall 2 door')));
select is(api.create_gate_point(tests.key(), tests.w('v1'), tests.w('hall1'), 'North gate') ->> 'code', 'invalid_content', 'gate point names are unique');
select tests.set_w('tv_go', tests.new_type('GO', 'Gate Operator', array['gate.operate'], '{}'));
select tests.set_w('tv_aa', tests.new_type('AA', 'Access Authority', array['gate.override', 'entry_rule_version.approve', 'pass.revoke', 'gate.operate'], '{}'));
select tests.set_w('u_gail', (tests.root_ta('gail@a.test', 'Gail', tests.w('tv_go'), array[tests.w('pc_wa')], tests.w('hall1')))[1]);
select tests.set_w('u_axel', (tests.root_ta('axel@a.test', 'Axel', tests.w('tv_aa'), array[tests.w('pc_wa')], tests.w('site')))[1]);

-- A card for OP (an operative with an account) and for Owen (no account, 6b-2).
select tests.login(tests.w('u_a1'));
insert into t_r select 'card_op', api.issue_card_pass(tests.key(), tests.w('p_op'), tests.w('v1'));
insert into t_r select 'card_owen', api.issue_card_pass(tests.key(), tests.w('p_owen'), tests.w('v1'));
select is((select v ->> 'ok' from t_r where name = 'card_op'), 'true', 'the venue issues a printed pass');
select is(api.issue_card_pass(tests.key(), tests.w('p_op'), tests.w('v1')) ->> 'code', 'card_exists', 'one live card per person');
select tests.logout();
select is((select token_hash is not null and secret is null from core.person_pass where id = (select (v ->> 'pass_id')::uuid from t_r where name = 'card_op')),
  true, 'only the card token''s hash is kept');
select tests.login(tests.w('u_op'));
select throws_ok($$ select secret from core.person_pass $$, '42501', null, 'no one can read a pass''s secret');

-- ---- No rules, no admission by default (P7-2) ---------------------------------------------------
select tests.login(tests.w('u_gail'));
insert into t_r select 'scan0', api.scan_entry(tests.key(), tests.w('north'), (select v ->> 'payload' from t_r where name = 'card_op'));
select is((select v #>> '{result,outcome}' from t_r where name = 'scan0'), 'check', 'with no approved entry rules, the answer is Check');
select is((select v #>> '{result,reasons,0,owner}' from t_r where name = 'scan0'), 'The venue''s access authority', 'with whom');

-- ---- Entry rules: drafted by the venue, approved by an access authority -----------------------------
select tests.login(tests.w('u_a1'));
select tests.set_w('er1', (api.create_entry_rule_draft(tests.key(), tests.w('v1')) ->> 'id')::uuid);
select is(api.save_entry_rule_draft(tests.key(), tests.w('er1'), tests.version('core.entry_rule_version', tests.w('er1')),
  '{"audiences": [{"key": "contractors", "name": "Contractors", "capacities": ["performing_contractor"]}]}') ->> 'code', 'invalid_content',
  'every setting of an audience must be stated');
select tests.must(api.save_entry_rule_draft(tests.key(), tests.w('er1'), tests.version('core.entry_rule_version', tests.w('er1')),
  jsonb_build_object('audiences', jsonb_build_array(jsonb_build_object('key', 'contractors', 'name', 'Contractor operatives',
    'capacities', '["performing_contractor"]'::jsonb, 'relationship_kinds', '["employee"]'::jsonb, 'event_phase', null,
    'induction_course_ids', jsonb_build_array(tests.w('course_core')), 'escort', 'never',
    'area_ids', jsonb_build_array(tests.w('hall1'), tests.w('hall2'))))), 'Venue access rules (test values)'));
select ok(api.propose_entry_rule_version(tests.key(), tests.w('er1'), tests.version('core.entry_rule_version', tests.w('er1')))::text
  like '%which refusals can never be overridden%', 'which refusals can never be overridden must be chosen');
select tests.must(api.save_entry_rule_draft(tests.key(), tests.w('er1'), tests.version('core.entry_rule_version', tests.w('er1')),
  (select content from core.entry_rule_version where id = tests.w('er1')) || '{"never_overridable": []}', 'Venue access rules (test values)'));
select tests.must(api.propose_entry_rule_version(tests.key(), tests.w('er1'), tests.version('core.entry_rule_version', tests.w('er1'))));
select is(api.decide_entry_rule_version(tests.key(), tests.w('er1'), tests.version('core.entry_rule_version', tests.w('er1')), 'approve', 'Mine') ->> 'code',
  'separation_of_duties', 'the venue''s administrator, who wrote them, cannot approve its own entry rules');
select tests.login(tests.w('u_axel'));
select is(api.decide_entry_rule_version(tests.key(), tests.w('er1'), tests.version('core.entry_rule_version', tests.w('er1')), 'approve', 'Agreed') ->> 'ok',
  'true', 'the access authority approves them');

-- ---- The evaluation (Q191) --------------------------------------------------------------------------
select tests.login(tests.w('u_gail'));
insert into t_r select 'scan1', api.scan_entry(tests.key(), tests.w('north'), (select v ->> 'payload' from t_r where name = 'card_op'));
select is((select v #>> '{result,outcome}' from t_r where name = 'scan1'), 'do_not_admit', 'without the required induction: Do not admit');
select is((select v #>> '{result,reasons,0,words}' || ' — ' || (v #>> '{result,reasons,0,owner}') from t_r where name = 'scan1'),
  'No valid induction: Exhibition Centre induction. — Oli Operative, by completing it', 'saying why and who can resolve it');
select is((select outcome from core.entry_eligibility_evaluation where id = (select (v ->> 'evaluation_id')::uuid from t_r where name = 'scan1')),
  'do_not_admit', 'and the evaluation shown is kept');
select is(api.record_gate_action(tests.key(), (select (v ->> 'evaluation_id')::uuid from t_r where name = 'scan1'), 'in', 'photo_id', 'admitted') ->> 'code',
  'not_admissible', 'the operator cannot admit on Do not admit');
select tests.must(api.record_gate_action(tests.key(), (select (v ->> 'evaluation_id')::uuid from t_r where name = 'scan1'), 'in', 'photo_id', 'refused',
  'Sent to complete the induction'));
select tests.login(tests.w('u_hes'));
select tests.must(api.record_facilitated_completion(tests.key(), tests.w('cv1'), tests.w('p_op'), 'assisted', 'Photo card checked', 'Explained the route; correct', true));
select tests.login(tests.w('u_gail'));
insert into t_r select 'scan2', api.scan_entry(tests.key(), tests.w('north'), (select v ->> 'payload' from t_r where name = 'card_op'));
select is((select v #>> '{result,outcome}' from t_r where name = 'scan2'), 'admit', 'with the induction complete: Admit');
select is((select v #>> '{result,areas}' from t_r where name = 'scan2'), '["Hall 1", "Hall 2"]', 'showing where they may go');
select is((select v #>> '{result,entry_only}' from t_r where name = 'scan2'), 'This is permission to be here, not permission to work.',
  'and that entry is not permission to work');
select ok((select v::text from t_r where name = 'scan2') !~* '(op@a\.test|07000|rams|method)', 'never contact details or RAMS (Q196)');
select is(api.record_gate_action(tests.key(), (select (v ->> 'evaluation_id')::uuid from t_r where name = 'scan2'), 'in', 'not_checked', 'admitted') ->> 'code',
  'identity_not_checked', 'identity is checked before admitting');
insert into t_r select 'act2', api.record_gate_action(tests.key(), (select (v ->> 'evaluation_id')::uuid from t_r where name = 'scan2'), 'in', 'photo_id', 'admitted');
select is((select v ->> 'ok' from t_r where name = 'act2'), 'true', 'the operator records what they did');
select is(api.record_gate_action(tests.key(), (select (v ->> 'evaluation_id')::uuid from t_r where name = 'scan2'), 'in', 'photo_id', 'admitted') ->> 'code',
  'already_recorded', 'once per scan');
select is(api.scan_entry(tests.key(), tests.w('north'), 'https://example.com/qr') ->> 'code', 'invalid_content', 'a code that is not an Octra pass is not read');
insert into t_r select 'unk', api.lookup_entry(tests.key(), tests.w('north'), 'C-999999');
select is((select v #>> '{result,reasons,0,code}' from t_r where name = 'unk'), 'pass_unknown', 'an unknown pass number: Do not admit');
select is(api.scan_entry(tests.key(), tests.w('h2door'), (select v ->> 'payload' from t_r where name = 'card_op')) ->> 'code',
  'no_covering_appointment', 'an operator appointed for Hall 1 cannot operate the Hall 2 door (P7-5)');

-- A result more than five minutes old is not acted on (invariant 11).
insert into t_r select 'scan3', api.lookup_entry(tests.key(), tests.w('north'), (select v ->> 'pass_number' from t_r where name = 'card_op'));
select tests.logout();
alter table core.entry_eligibility_evaluation disable trigger b_forbid_update;
update core.entry_eligibility_evaluation set evaluated_at = evaluated_at - interval '6 minutes' where id = (select (v ->> 'evaluation_id')::uuid from t_r where name = 'scan3');
alter table core.entry_eligibility_evaluation enable trigger b_forbid_update;
select tests.login(tests.w('u_gail'));
select is(api.record_gate_action(tests.key(), (select (v ->> 'evaluation_id')::uuid from t_r where name = 'scan3'), 'in', 'known_to_operator', 'admitted') ->> 'code',
  'stale', 'a stale result is scanned again, not acted on');

-- ---- Phone passes: a code that changes, and a copied code (P7-3, Q197) -------------------------------
select tests.login(tests.w('u_op'));
insert into t_r select 'phone', api.create_phone_pass(tests.key(), tests.w('v1'));
select is((select v ->> 'ok' from t_r where name = 'phone'), 'true', 'a person creates their own phone pass');
insert into t_r select 'code', api.phone_pass_code(tests.w('v1'));
select ok((select v ->> 'payload' from t_r where name = 'code') ~ '^OCTRA1:P:M-\d{6}:\d{6}$', 'which shows a changing code');
select tests.login(tests.w('u_nia'));
select is(api.phone_pass_code(tests.w('v1')) ->> 'code', 'not_found', 'only to its holder');
select tests.login(tests.w('u_gail'));
select is(api.scan_entry(tests.key(), tests.w('north'), (select v ->> 'payload' from t_r where name = 'code')) #>> '{result,outcome}', 'admit',
  'the current code admits');
insert into t_r select 'copy', api.scan_entry(tests.key(), tests.w('north'), 'OCTRA1:P:' || (select v ->> 'pass_number' from t_r where name = 'phone') || ':abcdef');
select is((select v #>> '{result,outcome}' from t_r where name = 'copy'), 'check', 'a code that does not verify is a Check, never an Admit');
select ok((select v::text from t_r where name = 'copy') like '%check identity and look the pass up by number%', 'with what to do');
select is(api.record_gate_action(tests.key(), (select (v ->> 'evaluation_id')::uuid from t_r where name = 'copy'), 'in', 'photo_id', 'admitted') ->> 'code',
  'check_first', 'admitting on a Check needs a note of who was checked with');

-- ---- The fixed floor and overrides (Q195, P7-6) ------------------------------------------------------
select tests.login(tests.w('u_gail'));
insert into t_r select 'owen1', api.scan_entry(tests.key(), tests.w('north'), (select v ->> 'payload' from t_r where name = 'card_owen'));
select is((select v #>> '{result,outcome}' from t_r where name = 'owen1'), 'do_not_admit', 'Owen has no induction: Do not admit');
select is(api.override_entry(tests.key(), tests.w('p_owen'), tests.w('north'), array['induction_missing'], 'Escorted to the induction room', 'Booked for 10:00',
  now() + interval '2 hours') ->> 'code', 'no_covering_appointment', 'an operator cannot override');
select tests.login(tests.w('u_op'));
select is(api.override_entry(tests.key(), tests.w('p_owen'), tests.w('north'), array['induction_missing'], 'Escorted', 'Booked',
  now() + interval '2 hours') ->> 'code', 'separation_of_duties', 'nor anyone from the person''s organisation');
select tests.login(tests.w('u_a1'));
select is(api.override_entry(tests.key(), tests.w('p_owen'), tests.w('north'), array['induction_missing'], 'Escorted', 'Booked',
  now() + interval '2 hours') ->> 'code', 'no_covering_appointment', 'nor a tenant administrator (invariant 9)');
select tests.login(tests.w('u_platform'));
select is(api.override_entry(tests.key(), tests.w('p_owen'), tests.w('north'), array['induction_missing'], 'Escorted', 'Booked',
  now() + interval '2 hours') ->> 'ok', 'false', 'nor a platform administrator (invariant 9)');
select tests.login(tests.w('u_axel'));
select is(api.override_entry(tests.key(), tests.w('p_owen'), tests.w('north'), array['induction_missing'], 'Escorted', 'Booked', null) ->> 'code',
  'invalid_content', 'an override is never open-ended');
select is(api.override_entry(tests.key(), tests.w('p_owen'), tests.w('north'), array['person_restricted'], 'Escorted', 'Booked',
  now() + interval '2 hours') ->> 'code', 'not_overridable', 'and never covers the fixed floor');
select is(api.override_entry(tests.key(), tests.w('p_owen'), tests.w('north'), array['induction_missing'], 'Escorted to the induction room', 'Booked for 10:00',
  now() + interval '2 hours', 'Vic from security') ->> 'ok', 'true', 'the access authority sets the refusal aside for two hours, with an escort');
select tests.login(tests.w('u_gail'));
insert into t_r select 'owen2', api.scan_entry(tests.key(), tests.w('north'), (select v ->> 'payload' from t_r where name = 'card_owen'));
select is((select v #>> '{result,outcome}' from t_r where name = 'owen2'), 'admit_with_escort', 'Owen may now enter with the escort');
select is((select v #>> '{result,overrides,0,purpose}' from t_r where name = 'owen2'), 'Escorted to the induction room', 'and the override is shown');
select is(api.record_gate_action(tests.key(), (select (v ->> 'evaluation_id')::uuid from t_r where name = 'owen2'), 'in', 'photo_id', 'admitted') ->> 'code',
  'escort_required', 'the escort is named when admitting');
select tests.must(api.record_gate_action(tests.key(), (select (v ->> 'evaluation_id')::uuid from t_r where name = 'owen2'), 'in', 'photo_id', 'admitted',
  null, 'Vic'));
select is((select override_ids from core.scan_event where evaluation_id = (select (v ->> 'evaluation_id')::uuid from t_r where name = 'owen2')),
  array[(select id from core.entry_override where person_id = tests.w('p_owen'))], 'the scan records the override relied on');
-- An override that has ended no longer applies (time cannot pass inside a test).
select tests.logout();
alter table core.entry_override disable trigger b_forbid_update;
update core.entry_override set valid_during = tstzrange(now() - interval '3 hours', now() - interval '1 hour') where person_id = tests.w('p_owen');
select tests.login(tests.w('u_gail'));
select is(api.scan_entry(tests.key(), tests.w('north'), (select v ->> 'payload' from t_r where name = 'card_owen')) #>> '{result,outcome}', 'do_not_admit',
  'once an override ends, the refusal stands again');
select tests.logout();
update core.entry_override set valid_during = tstzrange(now(), now() + interval '2 hours') where person_id = tests.w('p_owen');
alter table core.entry_override enable trigger b_forbid_update;
-- The override is for the North gate's area only.
select tests.login(tests.w('u_axel'));
select is(api.scan_entry(tests.key(), tests.w('h2door'), (select v ->> 'payload' from t_r where name = 'card_owen')) #>> '{result,outcome}', 'do_not_admit',
  'and does not reach another gate''s area');

-- The venue makes induction never overridable: the override no longer applies.
select tests.login(tests.w('u_a1'));
select tests.set_w('er2', (api.create_entry_rule_draft(tests.key(), tests.w('v1')) ->> 'id')::uuid);
select tests.must(api.save_entry_rule_draft(tests.key(), tests.w('er2'), tests.version('core.entry_rule_version', tests.w('er2')),
  (select content from core.entry_rule_version where id = tests.w('er2')) || '{"never_overridable": ["induction_missing"]}', 'Venue access rules rev. 2'));
select tests.must(api.propose_entry_rule_version(tests.key(), tests.w('er2'), tests.version('core.entry_rule_version', tests.w('er2'))));
select tests.login(tests.w('u_axel'));
select tests.must(api.decide_entry_rule_version(tests.key(), tests.w('er2'), tests.version('core.entry_rule_version', tests.w('er2')), 'approve', 'Induction is never waived'));
select is((select status from core.entry_rule_version where id = tests.w('er1')), 'superseded', 'the previous rules are superseded');
select tests.login(tests.w('u_gail'));
select is(api.scan_entry(tests.key(), tests.w('north'), (select v ->> 'payload' from t_r where name = 'card_owen')) #>> '{result,outcome}', 'do_not_admit',
  'an induction refusal is no longer set aside');
select tests.login(tests.w('u_axel'));
select is(api.override_entry(tests.key(), tests.w('p_owen'), tests.w('north'), array['induction_missing'], 'Again', 'Again', now() + interval '1 hour') ->> 'code',
  'not_overridable', 'nor can it be overridden again');

-- Restriction and revocation: Do not admit, whatever else is in place.
select tests.login(tests.w('u_a1'));
insert into t_r select 'card_nia', api.issue_card_pass(tests.key(), tests.w('p_nia'), tests.w('v1'));
select tests.login(tests.w('u_r'));
select tests.must(api.impose_restriction(tests.key(), tests.w('v1'), 'person', tests.w('p_nia'), 'Working outside the permitted area'));
select tests.login(tests.w('u_gail'));
insert into t_r select 'nia1', api.scan_entry(tests.key(), tests.w('north'), (select v ->> 'payload' from t_r where name = 'card_nia'));
select is((select v #>> '{result,outcome}' from t_r where name = 'nia1'), 'do_not_admit', 'a restricted person: Do not admit');
select ok((select v::text from t_r where name = 'nia1') like '%Restricted at this venue.%' and (select v::text from t_r where name = 'nia1') !~* 'outside the permitted',
  'shown as a fact, never its grounds (Q196)');
-- A record no longer active: Do not admit, and never overridable.
select tests.login(tests.w('u_a1'));
select tests.set_w('p_dee', tests.must(api.create_person(tests.key(), tests.w('cust_a'), 'Dee', 'Departed')));
insert into t_r select 'card_dee', api.issue_card_pass(tests.key(), tests.w('p_dee'), tests.w('v1'));
select tests.logout();
update core.person set deactivated_at = now() where id = tests.w('p_dee');
select tests.login(tests.w('u_gail'));
select is((api.scan_entry(tests.key(), tests.w('north'), (select v ->> 'payload' from t_r where name = 'card_dee')) -> 'result' -> 'reasons') @> '[{"code": "person_deactivated"}]',
  true, 'a person whose record is no longer active: Do not admit');
select tests.login(tests.w('u_axel'));
select is(api.override_entry(tests.key(), tests.w('p_dee'), tests.w('north'), array['person_deactivated'], 'Visit', 'Visit', now() + interval '1 hour') ->> 'code',
  'not_overridable', 'which no override reaches');
select is(api.revoke_pass(tests.key(), (select (v ->> 'pass_id')::uuid from t_r where name = 'card_op'), 'Lost') ->> 'ok', 'true', 'an access authority revokes a pass');
select tests.login(tests.w('u_gail'));
select is((api.scan_entry(tests.key(), tests.w('north'), (select v ->> 'payload' from t_r where name = 'card_op')) -> 'result' -> 'reasons') @> '[{"code": "pass_revoked"}]',
  true, 'a revoked pass gives Do not admit');

-- ---- Permits are notices, never a reason to admit (Q193, Q194, P7-12) ---------------------------------
select tests.set_w('wp', tests.live_job('Lamps today'));
select tests.login(tests.w('u_op'));
select tests.must(api.exclude_worker(tests.key(), (select id from core.permit_team_member where permit_id = tests.permit_of(tests.w('wp'), tests.w('pc_wah'))
  and person_id = tests.w('p_owen') and removed_at is null), 'Not trained on the MEWP'));
select tests.must(api.stop_work(tests.key(), tests.permit_of(tests.w('wp'), tests.w('pc_wah')), 'weather', 'Wind'));
select is(api.my_entry(tests.w('v1')) ->> 'outcome', 'admit', 'a stopped permit does not stop entry (Q193)');
select ok((api.my_entry(tests.w('v1')) -> 'notices')::text like '%Work at height work for WP-%is stopped: do not start it.%', 'it is a notice beside the result');
select tests.login(tests.w('u_axel'));
select ok((api.lookup_entry(tests.key(), tests.w('north'), (select v ->> 'pass_number' from t_r where name = 'card_owen')) #> '{result,notices}')::text
  like '%Not on the Work at height permit for WP-%: cannot join that task.%', 'someone removed from a permit''s team is told they cannot join it (Q194)');

-- ---- Separation -----------------------------------------------------------------------------------------
select tests.login(tests.w('u_platform'));
select is(api.scan_entry(tests.key(), tests.w('north'), (select v ->> 'payload' from t_r where name = 'card_owen')) ->> 'ok', 'false',
  'a platform administrator cannot operate a gate (invariant 9)');
select tests.login(tests.w('u_a1'));
select is(api.scan_entry(tests.key(), tests.w('north'), (select v ->> 'payload' from t_r where name = 'card_owen')) ->> 'code', 'no_covering_appointment',
  'nor a tenant administrator');
select tests.login(tests.w('u_op'));
select ok((select count(*) from api.entry_eligibility_evaluation) > 0 and not exists (select 1 from api.entry_eligibility_evaluation where person_id <> tests.w('p_op')),
  'a person sees their own gate records and nobody else''s');
select tests.login(tests.w('u_b1'));
select is((select count(*)::int from api.entry_eligibility_evaluation) + (select count(*)::int from api.scan_event) + (select count(*)::int from api.entry_override)
          + (select count(*)::int from api.person_pass) + (select count(*)::int from api.gate_point) + (select count(*)::int from api.entry_rule_version), 0,
  'another tenant sees none of it');
select is(api.scan_entry(tests.key(), tests.w('north'), (select v ->> 'payload' from t_r where name = 'card_owen')) ->> 'code', 'not_found', 'and cannot scan');

select tests.logout();
select * from finish();
rollback;
