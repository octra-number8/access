-- Offline gate 7d (Q198-Q203, P7-8 to P7-10): the outage procedure as venue configuration
-- with no default, the manifest, manual fallback entries uploaded on reconnection, and
-- reconciliation exceptions with owners, including a suspension after the last sync.
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

-- ---- Set-up: gate staff, entry rules, a live job with OP on its team ------------------------------
select tests.set_w('tv_go', tests.new_type('GO', 'Gate Operator', array['gate.operate', 'gate.download_manifest', 'gate.submit_fallback'], '{}'));
select tests.set_w('tv_aa', tests.new_type('AA', 'Access Administrator',
  array['gate.reconcile', 'gate.submit_fallback', 'gate.operate', 'venue_config.approve', 'entry_rule_version.approve'], '{}'));
select tests.set_w('tv_wr', tests.new_type('WR', 'Work Reconciler', array['gate.reconcile_work'], '{}'));
select tests.set_w('u_gail', (tests.root_ta('gail@a.test', 'Gail', tests.w('tv_go'), array[tests.w('pc_wa')], tests.w('site')))[1]);
select tests.set_w('u_axel', (tests.root_ta('axel@a.test', 'Axel', tests.w('tv_aa'), array[tests.w('pc_wa')], tests.w('site')))[1]);
select tests.set_w('u_wren', (tests.root_ta('wren@a.test', 'Wren', tests.w('tv_wr'), array[tests.w('pc_wa'), tests.w('pc_wah')], tests.w('site')))[1]);
select tests.login(tests.w('u_a1'));
select tests.set_w('north', tests.must(api.create_gate_point(tests.key(), tests.w('v1'), tests.w('hall1'), 'North gate')));
insert into t_r select 'card_op', api.issue_card_pass(tests.key(), tests.w('p_op'), tests.w('v1'));
insert into t_r select 'card_owen', api.issue_card_pass(tests.key(), tests.w('p_owen'), tests.w('v1'));
select tests.set_w('er1', (api.create_entry_rule_draft(tests.key(), tests.w('v1')) ->> 'id')::uuid);
select tests.must(api.save_entry_rule_draft(tests.key(), tests.w('er1'), tests.version('core.entry_rule_version', tests.w('er1')),
  jsonb_build_object('audiences', jsonb_build_array(jsonb_build_object('key', 'contractors', 'name', 'Contractors',
    'capacities', '["performing_contractor"]'::jsonb, 'relationship_kinds', '["employee"]'::jsonb, 'event_phase', null,
    'induction_course_ids', '[]'::jsonb, 'escort', 'never', 'area_ids', jsonb_build_array(tests.w('hall1'), tests.w('hall2')))),
    'never_overridable', '[]'::jsonb), 'Test values'));
select tests.must(api.propose_entry_rule_version(tests.key(), tests.w('er1'), tests.version('core.entry_rule_version', tests.w('er1'))));
select tests.login(tests.w('u_axel'));
select tests.must(api.decide_entry_rule_version(tests.key(), tests.w('er1'), tests.version('core.entry_rule_version', tests.w('er1')), 'approve', 'Agreed'));
select tests.set_w('wp', tests.live_job('Lamps today'));

-- ---- The outage procedure has no default (Q198, Q201, P7-10) -------------------------------------------
select tests.login(tests.w('u_gail'));
select is(api.download_manifest(tests.key(), tests.w('north')) ->> 'code', 'not_configured',
  'no manifest until the venue has an approved outage procedure saying how long one may be used');
select tests.login(tests.w('u_a1'));
select tests.set_w('op1', (api.create_venue_config_draft(tests.key(), tests.w('v1'), 'outage_procedure') ->> 'id')::uuid);
select tests.must(api.save_venue_config_draft(tests.key(), tests.w('op1'), tests.version('core.venue_config_version', tests.w('op1')),
  '{"instruction": "Control room leads. Admit only after the supervisor confirms.", "steps": ["Check photo ID", "Call the supervisor"]}'));
select ok(api.propose_venue_config(tests.key(), tests.w('op1'), tests.version('core.venue_config_version', tests.w('op1')))::text like '%there is no default%',
  'the manifest''s maximum age must be set (Q198)');
select is(api.save_venue_config_draft(tests.key(), tests.w('op1'), tests.version('core.venue_config_version', tests.w('op1')),
  '{"instruction": "x", "steps": ["y"], "manifest_max_age_minutes": 0}') ->> 'code', 'invalid_content', 'to a whole number of minutes from 1 to 1440');
select tests.must(api.save_venue_config_draft(tests.key(), tests.w('op1'), tests.version('core.venue_config_version', tests.w('op1')),
  '{"instruction": "Control room leads. Admit only after the supervisor confirms.", "steps": ["Check photo ID", "Call the supervisor"],
    "manifest_max_age_minutes": 60}', 'Outage procedure (test values)'));
select tests.must(api.propose_venue_config(tests.key(), tests.w('op1'), tests.version('core.venue_config_version', tests.w('op1'))));
select is(api.decide_venue_config(tests.key(), tests.w('op1'), tests.version('core.venue_config_version', tests.w('op1')), 'approve', 'Mine') ->> 'code',
  'separation_of_duties', 'its author cannot approve it');
select tests.login(tests.w('u_axel'));
select tests.must(api.decide_venue_config(tests.key(), tests.w('op1'), tests.version('core.venue_config_version', tests.w('op1')), 'approve', 'Agreed'));

-- ---- The manifest (Q198) ---------------------------------------------------------------------------------
select tests.login(tests.w('u_a1'));
select is(api.download_manifest(tests.key(), tests.w('north')) ->> 'code', 'no_covering_appointment', 'a tenant administrator cannot download one (invariant 9)');
select tests.login(tests.w('u_platform'));
select is(api.download_manifest(tests.key(), tests.w('north')) ->> 'ok', 'false', 'nor a platform administrator');
select tests.login(tests.w('u_op'));
select is(api.download_manifest(tests.key(), tests.w('north')) ->> 'ok', 'false', 'nor a contractor');
select tests.login(tests.w('u_gail'));
insert into t_r select 'm1', api.download_manifest(tests.key(), tests.w('north'));
select is((select v ->> 'ok' from t_r where name = 'm1'), 'true', 'a gate operator with the appointment downloads one');
select tests.set_w('m1', (select (v ->> 'manifest_id')::uuid from t_r where name = 'm1'));
select is((select (v ->> 'max_age_minutes')::int from t_r where name = 'm1'), 60, 'carrying the venue''s maximum age');
select is((select v ->> 'instruction' from t_r where name = 'm1'), 'Control room leads. Admit only after the supervisor confirms.',
  'and the instruction for the offline banner (Q199)');
select is((select e ->> 'outcome' from t_r, jsonb_array_elements(v -> 'entries') e where name = 'm1' and e ->> 'person_id' = tests.w('p_op')::text), 'admit',
  'OP is in it, as the live record judged him then');
select ok((select (e -> 'pass_numbers') ? (select pass_number from core.person_pass where person_id = tests.w('p_op') and revoked_at is null)
             from t_r, jsonb_array_elements(v -> 'entries') e where name = 'm1' and e ->> 'person_id' = tests.w('p_op')::text), 'with his pass number');
select ok((select v::text not like '%OCTRA1:%' and v::text not like '%token%' and v::text not like '%secret%' from t_r where name = 'm1'),
  'and no pass code, token or secret');

-- A suspension after the last sync (Q203).
select tests.login(tests.w('u_op'));
select tests.must(api.stop_work(tests.key(), tests.permit_of(tests.w('wp'), tests.w('pc_wah')), 'weather', 'Wind'));

-- ---- Fallback entries: checked before anything is kept (Q200) ---------------------------------------
select tests.login(tests.w('u_gail'));
select ok(api.submit_fallback_entries(tests.key(), tests.w('north'), tests.w('m1'), jsonb_build_array(jsonb_build_object(
  'client_entry_id', gen_random_uuid(), 'recorded_at', now() + interval '1 hour', 'name_given', 'X', 'purpose', 'Y', 'contacted', 'Z',
  'direction', 'in', 'identity_method', 'photo_id', 'decision', 'admitted')))::text like '%in the future%', 'an entry from the future is refused');
select ok(api.submit_fallback_entries(tests.key(), tests.w('north'), tests.w('m1'), jsonb_build_array(jsonb_build_object(
  'client_entry_id', gen_random_uuid(), 'recorded_at', clock_timestamp(), 'name_given', 'X', 'purpose', 'Y', 'contacted', 'Z',
  'direction', 'in', 'identity_method', 'not_checked', 'decision', 'admitted')))::text like '%without an identity check%',
  'nobody is let through without an identity check');
select ok(api.submit_fallback_entries(tests.key(), tests.w('north'), tests.w('m1'), jsonb_build_array(jsonb_build_object(
  'client_entry_id', gen_random_uuid(), 'recorded_at', clock_timestamp(), 'name_given', 'X', 'purpose', 'Y', 'contacted', ' ',
  'direction', 'in', 'identity_method', 'photo_id', 'decision', 'admitted')))::text like '%who was contacted%', 'who was contacted must be recorded');
select ok(api.submit_fallback_entries(tests.key(), tests.w('north'), tests.w('m1'), jsonb_build_array(jsonb_build_object(
  'client_entry_id', gen_random_uuid(), 'recorded_at', now() - interval '1 day', 'name_given', 'X', 'purpose', 'Y', 'contacted', 'Z',
  'direction', 'in', 'identity_method', 'photo_id', 'decision', 'admitted')))::text like '%earlier than the manifest%',
  'an entry cannot rely on a manifest made after it');
select ok(api.submit_fallback_entries(tests.key(), tests.w('north'), tests.w('m1'), jsonb_build_array(jsonb_build_object(
  'client_entry_id', gen_random_uuid(), 'recorded_at', clock_timestamp(), 'person_id', tests.w('p_b1'), 'name_given', 'X', 'purpose', 'Y', 'contacted', 'Z',
  'direction', 'in', 'identity_method', 'photo_id', 'decision', 'admitted')))::text like '%not known at this venue%', 'a person from another tenant is refused');
select tests.login(tests.w('u_a1'));
select tests.set_w('h2door', tests.must(api.create_gate_point(tests.key(), tests.w('v1'), tests.w('hall2'), 'Hall 2 door')));
select tests.login(tests.w('u_gail'));
select tests.set_w('m_h2', (api.download_manifest(tests.key(), tests.w('h2door')) ->> 'manifest_id')::uuid);
select ok(api.submit_fallback_entries(tests.key(), tests.w('north'), tests.w('m_h2'), jsonb_build_array(jsonb_build_object(
  'client_entry_id', gen_random_uuid(), 'recorded_at', clock_timestamp(), 'name_given', 'X', 'purpose', 'Y', 'contacted', 'Z',
  'direction', 'in', 'identity_method', 'photo_id', 'decision', 'admitted')))::text like '%not one made for this gate point%',
  'an entry relies only on a manifest made for its own gate');
select is((select count(*)::int from core.manual_fallback_entry), 0, 'and with any problem, nothing is kept: the device keeps them');

create temp table t_entries as select jsonb_build_array(
  jsonb_build_object('client_entry_id', gen_random_uuid(), 'recorded_at', clock_timestamp(), 'pass_number', (select v ->> 'pass_number' from t_r where name = 'card_op'),
    'name_given', 'Oli Operative', 'organisation_given', 'O Ltd', 'purpose', 'Lamps job', 'contacted', 'Supervisor by phone',
    'direction', 'in', 'identity_method', 'photo_id', 'decision', 'admitted'),
  jsonb_build_object('client_entry_id', gen_random_uuid(), 'recorded_at', clock_timestamp(), 'name_given', 'Sam Stranger', 'organisation_given', 'Unknown Ltd',
    'purpose', 'Delivery', 'contacted', 'Control room', 'direction', 'in', 'identity_method', 'photo_id', 'decision', 'admitted'),
  jsonb_build_object('client_entry_id', gen_random_uuid(), 'recorded_at', clock_timestamp(), 'person_id', tests.w('p_h'), 'name_given', 'Hal',
    'purpose', 'Visit', 'contacted', 'Control room', 'direction', 'in', 'identity_method', 'known_to_operator', 'decision', 'admitted'),
  jsonb_build_object('client_entry_id', gen_random_uuid(), 'recorded_at', clock_timestamp(), 'person_id', tests.w('p_owen'), 'name_given', 'Owen',
    'purpose', 'Lamps job', 'contacted', 'Control room', 'direction', 'in', 'identity_method', 'photo_id', 'decision', 'refused')) e;
grant select on t_entries to authenticated;

select tests.login(tests.w('u_platform'));
select is(api.submit_fallback_entries(tests.key(), tests.w('north'), tests.w('m1'), (select e from t_entries)) ->> 'ok', 'false',
  'a platform administrator cannot upload entries');
select tests.login(tests.w('u_gail'));
insert into t_r select 'up1', api.submit_fallback_entries(tests.key(), tests.w('north'), tests.w('m1'), (select e from t_entries));
select is((select (v ->> 'added')::int from t_r where name = 'up1'), 4, 'the operator uploads the four entries made offline');
select is((select manifest_usable from core.manual_fallback_entry where name_given = 'Oli Operative'), true, 'each records whether its manifest was within age');
select is(api.submit_fallback_entries(tests.key(), tests.w('north'), tests.w('m1'), (select e from t_entries)) #>> '{already_uploaded}', '4',
  'uploading them again adds nothing (idempotent per entry)');

-- ---- Reconciliation (Q202, Q203) ----------------------------------------------------------------------------
select is((select count(*)::int from core.reconciliation_exception where code = 'work_stopped' and person_id = tests.w('p_op')
             and permit_id = tests.permit_of(tests.w('wp'), tests.w('pc_wah'))), 1,
  'a suspension after the last sync is raised as a work exception for that permit (Q203)');
select is((select count(*)::int from core.reconciliation_exception where code = 'work_stopped' and person_id = tests.w('p_op')
             and permit_id = tests.permit_of(tests.w('wp'), tests.w('pc_wa'))), 1, 'and for its Work Approval, stopped with it');
select ok((select bool_and(owner like 'The permit''s issuer, %') from core.reconciliation_exception where code = 'work_stopped'), 'each owned by the permit''s issuer');
select is((select count(*)::int from core.reconciliation_exception where code = 'live_do_not_admit' and person_id = tests.w('p_op')), 0,
  'stopped work does not stop entry: OP''s admission itself was right (Q193)');
select is((select count(*)::int from core.reconciliation_exception where code = 'unknown_person'), 1, 'someone with no matching record is raised');
select is((select count(*)::int from core.reconciliation_exception where code = 'live_do_not_admit' and person_id = tests.w('p_h')), 1,
  'someone the live record refuses is raised, with the reasons');
select is((select count(*)::int from core.reconciliation_exception e join core.manual_fallback_entry f on f.id = e.fallback_entry_id
             where f.decision = 'refused'), 0, 'a refusal raises nothing');
select is((select count(*)::int from core.reconciliation_exception where resolved_at is null), 4, 'all four are open');
select tests.logout();
select is((select count(*)::int from core.notification where event = 'outage_exception' and recipient_person_id = tests.w('p_ivy')
             and record_id in (select id from core.reconciliation_exception where kind = 'work')), 2,
  'each work exception is a critical notice to the permit''s issuer (Q203)');
select is((select count(*)::int from core.notification n join core.user_account u on u.person_id = n.recipient_person_id
            where n.event = 'outage_exception' and u.auth_user_id = tests.w('u_axel')
              and n.record_id in (select id from core.reconciliation_exception where kind = 'entry')), 2,
  'and each entry exception to the access administrators for the gate');
select is((select count(*)::int from core.notification n join core.user_account u on u.person_id = n.recipient_person_id
            where n.event = 'outage_exception' and u.auth_user_id = tests.w('u_gail')), 0, 'never to the operator who made the entry');

-- An entry with no manifest, or an old one, still raises stopped work.
select tests.login(tests.w('u_gail'));
select is(api.submit_fallback_entries(tests.key(), tests.w('north'), null, jsonb_build_array(jsonb_build_object('client_entry_id', gen_random_uuid(),
  'recorded_at', clock_timestamp(), 'person_id', tests.w('p_op'), 'name_given', 'Oli', 'purpose', 'Lamps job', 'contacted', 'Supervisor',
  'direction', 'in', 'identity_method', 'photo_id', 'decision', 'admitted'))) #>> '{exceptions,0,code}', 'work_stopped',
  'with no manifest, every stopped permit is raised');
select is((select manifest_usable from core.manual_fallback_entry where manifest_id is null), false, 'and the entry is marked as made without a usable manifest');

-- What the manifest already showed is not raised again.
insert into t_r select 'm2', api.download_manifest(tests.key(), tests.w('north'));
select is(api.submit_fallback_entries(tests.key(), tests.w('north'), (select (v ->> 'manifest_id')::uuid from t_r where name = 'm2'),
  jsonb_build_array(jsonb_build_object('client_entry_id', gen_random_uuid(), 'recorded_at', clock_timestamp(), 'person_id', tests.w('p_op'),
  'name_given', 'Oli', 'purpose', 'Lamps job', 'contacted', 'Supervisor', 'direction', 'in', 'identity_method', 'photo_id', 'decision', 'admitted'))) -> 'exceptions',
  '[]'::jsonb, 'stopped work the newer manifest already showed is not raised again');

-- A pass revoked since the manifest.
select tests.login(tests.w('u_a1'));
select tests.must(api.revoke_pass(tests.key(), (select (v ->> 'pass_id')::uuid from t_r where name = 'card_owen'), 'Reported lost'));
select tests.login(tests.w('u_gail'));
select is(api.submit_fallback_entries(tests.key(), tests.w('north'), tests.w('m1'), jsonb_build_array(jsonb_build_object('client_entry_id', gen_random_uuid(),
  'recorded_at', clock_timestamp(), 'pass_number', (select v ->> 'pass_number' from t_r where name = 'card_owen'), 'name_given', 'Owen', 'purpose', 'Lamps job',
  'contacted', 'Supervisor', 'direction', 'in', 'identity_method', 'photo_id', 'decision', 'admitted'))) #>> '{exceptions,0,code}', 'pass_revoked',
  'letting someone in on a pass revoked since the manifest is raised');

-- ---- Resolution: by the owning authority, with a note, never the operator (Q202, invariant 10) -------------
select tests.set_w('x_h', (select id from core.reconciliation_exception where code = 'live_do_not_admit' and person_id = tests.w('p_h')));
select tests.set_w('x_w', (select id from core.reconciliation_exception where code = 'work_stopped' and fallback_entry_id =
  (select id from core.manual_fallback_entry where name_given = 'Oli Operative') and permit_id = tests.permit_of(tests.w('wp'), tests.w('pc_wah'))));
select tests.login(tests.w('u_gail'));
select is(api.resolve_reconciliation_exception(tests.key(), tests.w('x_h'), 'Fine') ->> 'code', 'separation_of_duties', 'the operator who made the entry cannot resolve it');
select tests.login(tests.w('u_a1'));
select is(api.resolve_reconciliation_exception(tests.key(), tests.w('x_h'), 'Fine') ->> 'code', 'no_covering_appointment', 'nor a tenant administrator');
select tests.login(tests.w('u_platform'));
select is(api.resolve_reconciliation_exception(tests.key(), tests.w('x_h'), 'Fine') ->> 'ok', 'false', 'nor a platform administrator');
select tests.login(tests.w('u_axel'));
select is(api.resolve_reconciliation_exception(tests.key(), tests.w('x_h'), '  ') ->> 'code', 'invalid_content', 'a note is required');
select is(api.resolve_reconciliation_exception(tests.key(), tests.w('x_w'), 'Seen') ->> 'code', 'no_covering_appointment',
  'an access administrator does not resolve a work exception');
select is(api.resolve_reconciliation_exception(tests.key(), tests.w('x_h'), 'Escorted off site at 10:40; control room informed') ->> 'ok', 'true',
  'the access administrator resolves the entry exception with a note');
select is(api.resolve_reconciliation_exception(tests.key(), tests.w('x_h'), 'Again') ->> 'code', 'already_resolved', 'once');
select tests.login(tests.w('u_wren'));
select is(api.resolve_reconciliation_exception(tests.key(), tests.w('x_w'), 'Spoke to the supervisor: no work at height started') ->> 'ok', 'true',
  'an appointee for the permit''s class and area resolves the work exception');

select tests.login(tests.w('u_b1'));
select is(api.resolve_reconciliation_exception(tests.key(), tests.w('x_h'), 'x') ->> 'code',
  'not_found', 'another tenant cannot even find an exception');
select tests.login(tests.w('u_op'));
select is(api.resolve_reconciliation_exception(tests.key(), tests.w('x_h'), 'x') ->> 'code', 'not_found',
  'nor can a contractor of the same venue, so its existence is not disclosed');

-- The operator who made an entry cannot resolve what it raised.
select tests.login(tests.w('u_axel'));
insert into t_r select 'up_ax', api.submit_fallback_entries(tests.key(), tests.w('north'), tests.w('m1'), jsonb_build_array(jsonb_build_object(
  'client_entry_id', gen_random_uuid(), 'recorded_at', clock_timestamp(), 'name_given', 'Pat Unknown', 'purpose', 'Delivery', 'contacted', 'Control room',
  'direction', 'in', 'identity_method', 'photo_id', 'decision', 'admitted')));
select is(api.resolve_reconciliation_exception(tests.key(), (select (v #>> '{exceptions,0,id}')::uuid from t_r where name = 'up_ax'), 'Fine') ->> 'code',
  'separation_of_duties', 'the operator who let them in cannot close the exception');

-- ---- Separation ------------------------------------------------------------------------------------------------
select tests.login(tests.w('u_op'));
select is((select count(*)::int from api.reconciliation_exception) + (select count(*)::int from api.manual_fallback_entry)
          + (select count(*)::int from api.gate_manifest), 0, 'a contractor sees no manifests, entries or exceptions, even about himself');
select tests.login(tests.w('u_b1'));
select is((select count(*)::int from api.reconciliation_exception) + (select count(*)::int from api.gate_manifest), 0, 'nor does another tenant');
select tests.login(tests.w('u_gail'));
select ok((select count(*)::int from api.reconciliation_exception) > 0, 'the venue''s gate staff do');
select throws_ok($$ insert into core.reconciliation_exception (customer_id, venue_id, fallback_entry_id, kind, code, words, owner)
                    select customer_id, venue_id, id, 'entry', 'x', 'x', 'x' from core.manual_fallback_entry limit 1 $$, '42501', null,
  'no one writes an exception directly');

select * from finish();
rollback;
