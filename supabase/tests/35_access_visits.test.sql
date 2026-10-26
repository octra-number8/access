-- Access visits 7b (Q120-Q126, Q162, P7-7): purposes as venue configuration with no default,
-- the visit request, occupier consent, approval with conditions, the roster, attendance at the
-- gate, cancellation, and a linked work request that never turns a visit into a permit.
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

-- ---- Set-up: an access authority, an occupier's representative for Hall 2, a gate ---------------
select tests.set_w('tv_aa', tests.new_type('AA', 'Access Authority', array['access.approve', 'access.cancel_as_authority', 'venue_config.approve', 'gate.operate'], '{}'));
select tests.set_w('tv_oa', tests.new_type('OA', 'Occupier Access', array['access.consent_occupier'], '{}'));
select tests.set_w('u_axel', (tests.root_ta('axel@a.test', 'Axel', tests.w('tv_aa'), array[tests.w('pc_wa')], tests.w('site')))[1]);
select tests.set_w('u_opal', (tests.root_ta('opal@a.test', 'Opal', tests.w('tv_oa'), array[tests.w('pc_wa')], tests.w('hall2')))[1]);
select tests.login(tests.w('u_a1'));
select tests.set_w('north', tests.must(api.create_gate_point(tests.key(), tests.w('v1'), tests.w('hall1'), 'North gate')));
insert into t_r select 'card_nia', api.issue_card_pass(tests.key(), tests.w('p_nia'), tests.w('v1'));
insert into t_r select 'card_owen', api.issue_card_pass(tests.key(), tests.w('p_owen'), tests.w('v1'));

-- ---- Purposes have no default (Q121, Q162) ---------------------------------------------------------
select tests.login(tests.w('u_op'));
select is(api.request_access(tests.key(), tests.w('v1'), tests.w('org_o'), 'survey', 'Survey the lighting bar', array[tests.w('hall1')],
  now() - interval '1 hour', now() + interval '1 day', array[tests.w('p_nia')]) ->> 'code', 'not_configured',
  'no visit can be asked for until the venue defines its purposes');
select tests.login(tests.w('u_a1'));
select tests.set_w('pc1', (api.create_venue_config_draft(tests.key(), tests.w('v1'), 'access_purposes') ->> 'id')::uuid);
select ok(api.propose_venue_config(tests.key(), tests.w('pc1'), tests.version('core.venue_config_version', tests.w('pc1')))::text like '%at least one purpose%',
  'purposes must be defined');
select is(api.save_venue_config_draft(tests.key(), tests.w('pc1'), tests.version('core.venue_config_version', tests.w('pc1')),
  '{"purposes": [{"key": "survey", "name": "Escorted survey"}]}') ->> 'code', 'invalid_content',
  'each purpose states what it allows and prohibits, its inductions, escort and occupier consent');
select is(api.save_venue_config_draft(tests.key(), tests.w('pc1'), tests.version('core.venue_config_version', tests.w('pc1')),
  '{"purposes": [{"key": "survey", "name": "Escorted survey", "allows": " ", "prohibits": "Work", "induction_course_ids": [], "escort": "always",
    "occupier_consent": true}]}') ->> 'code', 'invalid_content', 'including, in words, what a visit allows (Q121)');
select tests.must(api.save_venue_config_draft(tests.key(), tests.w('pc1'), tests.version('core.venue_config_version', tests.w('pc1')),
  '{"purposes": [
     {"key": "survey", "name": "Escorted survey", "allows": "Looking and measuring", "prohibits": "Any work, tools or touching plant",
      "induction_course_ids": [], "escort": "always", "occupier_consent": true},
     {"key": "meeting", "name": "Meeting", "allows": "Meeting in the named room", "prohibits": "Entering work areas",
      "induction_course_ids": [], "escort": "never", "occupier_consent": false}]}', 'Visitor rules (test values)'));
select tests.must(api.propose_venue_config(tests.key(), tests.w('pc1'), tests.version('core.venue_config_version', tests.w('pc1'))));
select is(api.decide_venue_config(tests.key(), tests.w('pc1'), tests.version('core.venue_config_version', tests.w('pc1')), 'approve', 'Mine') ->> 'code',
  'separation_of_duties', 'the author cannot approve the purposes');
select tests.login(tests.w('u_axel'));
select is(api.decide_venue_config(tests.key(), tests.w('pc1'), tests.version('core.venue_config_version', tests.w('pc1')), 'approve', 'Agreed') ->> 'ok', 'true',
  'an appointed authority approves them');

-- ---- The request (Q125) ------------------------------------------------------------------------------
select tests.login(tests.w('u_op'));
select ok(api.request_access(tests.key(), tests.w('v1'), tests.w('org_o'), 'tour', 'Survey', array[tests.w('hall1')],
  now() - interval '1 hour', now() + interval '1 day', array[tests.w('p_nia')])::text like '%one of the venue''s purposes%', 'only the venue''s purposes');
select ok(api.request_access(tests.key(), tests.w('v1'), tests.w('org_o'), 'survey', 'Survey', array[tests.w('hall1')],
  now() - interval '1 hour', now() + interval '1 day', array[tests.w('p_h')])::text like '%must currently work with the organisation%',
  'only people who work with the organisation');
select tests.login(tests.w('u_orla'));
select is(api.request_access(tests.key(), tests.w('v1'), tests.w('org_o'), 'survey', 'Survey', array[tests.w('hall1')],
  now() - interval '1 hour', now() + interval '1 day', array[tests.w('p_nia')]) ->> 'code', 'not_organisation_admin',
  'only the organisation''s own administrator asks for its visits');
select tests.login(tests.w('u_op'));
insert into t_r select 'av1', api.request_access(tests.key(), tests.w('v1'), tests.w('org_o'), 'survey', 'Survey the lighting bar for next week''s job',
  array[tests.w('hall1'), tests.w('hall2')], now() - interval '1 hour', now() + interval '1 day', array[tests.w('p_nia')]);
select is((select v ->> 'ok' from t_r where name = 'av1'), 'true', 'the organisation asks for an escorted survey in Halls 1 and 2');
select tests.set_w('av1', (select (v ->> 'id')::uuid from t_r where name = 'av1'));

-- Before approval, the visit is no reason to enter.
select tests.login(tests.w('u_axel'));
select is(api.scan_entry(tests.key(), tests.w('north'), (select v ->> 'payload' from t_r where name = 'card_nia')) #>> '{result,visit}', null,
  'a visit not yet approved is no reason to enter');

-- ---- Occupier consent and approval (Q123, Q124) ------------------------------------------------------
select is(api.decide_access(tests.key(), tests.w('av1'), tests.version('core.access_authorisation', tests.w('av1')), 'approve', 'Fine',
  '{"escort": "Vic from security"}') ->> 'code', 'consent_pending', 'Hall 2''s occupier must consent first');
select is(api.consent_access(tests.key(), tests.w('av1'), tests.w('hall2'), tests.w('org_o2'), 'given', 'Fine') ->> 'code', 'no_covering_appointment',
  'only the occupier''s representative consents');
select tests.login(tests.w('u_opal'));
select is(api.consent_access(tests.key(), tests.w('av1'), tests.w('hall1'), tests.w('org_o2'), 'given', 'Fine') ->> 'code', 'no_covering_appointment',
  'only for an area the representative''s appointment covers');
select is(api.consent_access(tests.key(), tests.w('av1'), tests.w('hall2'), tests.w('org_o'), 'given', 'Fine') ->> 'code', 'not_needed',
  'and only for the organisation that occupies it');
select is(api.consent_access(tests.key(), tests.w('av1'), tests.w('hall2'), tests.w('org_o2'), 'given', 'Stand closed that morning') ->> 'ok', 'true',
  'the occupier''s representative consents for Hall 2');
select tests.login(tests.w('u_op'));
select is(api.decide_access(tests.key(), tests.w('av1'), tests.version('core.access_authorisation', tests.w('av1')), 'approve', 'Mine') ->> 'code',
  'separation_of_duties', 'the requesting organisation cannot approve its own visit');
select tests.login(tests.w('u_a1'));
select is(api.decide_access(tests.key(), tests.w('av1'), tests.version('core.access_authorisation', tests.w('av1')), 'approve', 'Admin') ->> 'code',
  'no_covering_appointment', 'nor a tenant administrator (invariant 9)');
select tests.login(tests.w('u_axel'));
select is(api.decide_access(tests.key(), tests.w('av1'), tests.version('core.access_authorisation', tests.w('av1')), 'approve', 'Fine', '{}') ->> 'code',
  'escort_needed', 'a purpose that is always escorted needs the escort named');
select is(api.decide_access(tests.key(), tests.w('av1'), tests.version('core.access_authorisation', tests.w('av1')), 'approve', 'Survey agreed',
  '{"escort": "Vic from security", "no_photography": true}') ->> 'ok', 'true', 'the access authority approves it with conditions');
select is((select conditions ->> 'no_photography' from core.access_authorisation where id = tests.w('av1')), 'true', 'recorded with the visit');

-- ---- At the gate (Q125, Q126) --------------------------------------------------------------------------
insert into t_r select 'nia1', api.scan_entry(tests.key(), tests.w('north'), (select v ->> 'payload' from t_r where name = 'card_nia'));
select is((select v #>> '{result,outcome}' from t_r where name = 'nia1'), 'admit_with_escort', 'the approved visit admits Nia, escorted');
select is((select v #>> '{result,visit,reference}' from t_r where name = 'nia1'), (select reference from core.access_authorisation where id = tests.w('av1')),
  'naming the visit');
select ok((select v #>> '{result,notices}' from t_r where name = 'nia1') like '%Visit only: Looking and measuring. Not allowed: Any work, tools or touching plant.%',
  'and saying a visit allows no work (Q121)');
select tests.must(api.record_gate_action(tests.key(), (select (v ->> 'evaluation_id')::uuid from t_r where name = 'nia1'), 'in', 'photo_id', 'admitted', null, 'Vic'));
select is((select count(*)::int from core.visit_attendance where authorisation_id = tests.w('av1') and person_id = tests.w('p_nia') and left_at is null), 1,
  'her arrival is recorded against the visit');
insert into t_r select 'nia2', api.scan_entry(tests.key(), tests.w('north'), (select v ->> 'payload' from t_r where name = 'card_nia'));
select tests.must(api.record_gate_action(tests.key(), (select (v ->> 'evaluation_id')::uuid from t_r where name = 'nia2'), 'out', 'known_to_operator', 'admitted'));
select is((select count(*)::int from core.visit_attendance where authorisation_id = tests.w('av1') and left_at is not null), 1, 'and her departure');

-- ---- The roster (Q125) -----------------------------------------------------------------------------------
select tests.login(tests.w('u_op'));
select tests.must(api.change_access_roster(tests.key(), tests.w('av1'), array[tests.w('p_owen')], '{}', 'Owen holds the drawings'));
select tests.login(tests.w('u_axel'));
select is(api.scan_entry(tests.key(), tests.w('north'), (select v ->> 'payload' from t_r where name = 'card_owen')) #>> '{result,visit}', null,
  'someone added after approval is not on the visit until approved');
select tests.login(tests.w('u_op'));
select is(api.approve_roster_addition(tests.key(), (select id from core.access_roster_member where authorisation_id = tests.w('av1') and person_id = tests.w('p_owen'))) ->> 'code',
  'separation_of_duties', 'the organisation cannot approve its own addition');
select tests.login(tests.w('u_axel'));
select tests.must(api.approve_roster_addition(tests.key(), (select id from core.access_roster_member where authorisation_id = tests.w('av1') and person_id = tests.w('p_owen'))));
select is(api.scan_entry(tests.key(), tests.w('north'), (select v ->> 'payload' from t_r where name = 'card_owen')) #>> '{result,outcome}', 'admit_with_escort',
  'once approved, Owen may enter on the visit');
select tests.login(tests.w('u_op'));
select tests.must(api.change_access_roster(tests.key(), tests.w('av1'), '{}',
  array[(select id from core.access_roster_member where authorisation_id = tests.w('av1') and person_id = tests.w('p_nia') and removed_at is null)], 'Nia off sick'));
select tests.login(tests.w('u_axel'));
select is(api.scan_entry(tests.key(), tests.w('north'), (select v ->> 'payload' from t_r where name = 'card_nia')) #>> '{result,visit}', null,
  'removal takes effect at once');

-- ---- Cancellation, refusal and withdrawal ---------------------------------------------------------------
select is(api.cancel_access(tests.key(), tests.w('av1'), tests.version('core.access_authorisation', tests.w('av1')), 'Hall closed for an event') ->> 'ok', 'true',
  'the access authority cancels the visit');
select is(api.scan_entry(tests.key(), tests.w('north'), (select v ->> 'payload' from t_r where name = 'card_owen')) #>> '{result,visit}', null,
  'and it no longer admits anyone');
select tests.login(tests.w('u_op'));
insert into t_r select 'av2', api.request_access(tests.key(), tests.w('v1'), tests.w('org_o'), 'meeting', 'Pre-start meeting', array[tests.w('hall1')],
  now() - interval '1 hour', now() + interval '2 hours', array[tests.w('p_nia')]);
select tests.set_w('av2', (select (v ->> 'id')::uuid from t_r where name = 'av2'));
select tests.login(tests.w('u_axel'));
select is(api.decide_access(tests.key(), tests.w('av2'), tests.version('core.access_authorisation', tests.w('av2')), 'refuse', 'Use the site office instead') ->> 'ok',
  'true', 'a visit can be refused');
select is(api.scan_entry(tests.key(), tests.w('north'), (select v ->> 'payload' from t_r where name = 'card_nia')) #>> '{result,visit}', null, 'and admits nobody');
select tests.login(tests.w('u_op'));
insert into t_r select 'av3', api.request_access(tests.key(), tests.w('v1'), tests.w('org_o'), 'meeting', 'Kick-off meeting', array[tests.w('hall1')],
  now() - interval '1 hour', now() + interval '2 hours', array[tests.w('p_nia')]);
select tests.set_w('av3', (select (v ->> 'id')::uuid from t_r where name = 'av3'));
select tests.login(tests.w('u_axel'));
select is(api.decide_access(tests.key(), tests.w('av3'), tests.version('core.access_authorisation', tests.w('av3')), 'approve', 'Agreed') ->> 'ok', 'true',
  'a meeting needs no escort or consent');
select is(api.scan_entry(tests.key(), tests.w('north'), (select v ->> 'payload' from t_r where name = 'card_nia')) #>> '{result,outcome}', 'admit',
  'so its visitor is admitted unescorted');

-- ---- A visit never becomes a permit (Q122) ---------------------------------------------------------------
select tests.set_w('wp', tests.new_job(tests.wp_input(p_areas => array[tests.w('hall1')], p_title => 'Lighting bar repair', p_supervisor => tests.w('p_op'))));
select tests.login(tests.w('u_op'));
select is(api.link_work_request(tests.key(), tests.w('av1'), tests.w('wp')) ->> 'code', 'invalid_content', 'a cancelled visit has no work request linked');
select is(api.link_work_request(tests.key(), tests.w('av3'), tests.w('wp')) ->> 'ok', 'true', 'a job is linked to the approved visit');
select is(api.link_work_request(tests.key(), tests.w('av3'), tests.w('wp')) ->> 'code', 'invalid_content', 'once');
select is((select status from core.access_authorisation where id = tests.w('av3')) || '/' || (select count(*)::text from core.permit where work_package_id = tests.w('wp')),
  'approved/0', 'the visit is unchanged and no permit appears: the job follows the normal route');

-- ---- Withdrawal, and who sees visits ---------------------------------------------------------------------
select tests.login(tests.w('u_op'));
insert into t_r select 'av4', api.request_access(tests.key(), tests.w('v1'), tests.w('org_o'), 'meeting', 'Spare', array[tests.w('hall1')],
  now(), now() + interval '2 hours', array[tests.w('p_nia')]);
select is(api.cancel_access(tests.key(), (select (v ->> 'id')::uuid from t_r where name = 'av4'),
  tests.version('core.access_authorisation', (select (v ->> 'id')::uuid from t_r where name = 'av4')), 'Not needed') ->> 'ok', 'true',
  'the organisation withdraws a request');
select is((select status from core.access_authorisation where id = (select (v ->> 'id')::uuid from t_r where name = 'av4')), 'withdrawn', 'recorded as withdrawn');
select tests.login(tests.w('u_nia'));
select ok((select count(*) from api.access_authorisation) >= 1, 'someone on a visit''s roster sees it');
select tests.login(tests.w('u_orla'));
select is((select count(*)::int from api.access_authorisation), 0, 'another organisation does not');
select tests.login(tests.w('u_b1'));
select is((select count(*)::int from api.access_authorisation) + (select count(*)::int from api.access_roster_member) + (select count(*)::int from api.access_consent)
          + (select count(*)::int from api.visit_attendance) + (select count(*)::int from api.venue_config_version), 0, 'nor another tenant');

select tests.logout();
select * from finish();
rollback;
