-- Reads for the live screens 6d (CLAUDE.md §6): venue emergency contacts on the live permit,
-- the team member's own live permits, and the venue authority's live board.
begin;
\ir _helpers.psql
\ir _phase4.psql
select tests.approve_screening();
\ir _phase5.psql
\ir _phase6.psql
select no_plan();

select tests.set_w('wp', tests.live_job('Lamps today'));
select tests.set_w('wa', tests.permit_of(tests.w('wp'), tests.w('pc_wa')));
select tests.set_w('wah', tests.permit_of(tests.w('wp'), tests.w('pc_wah')));

-- ---- Emergency contacts ------------------------------------------------------------------------
select tests.login(tests.w('u_op'));
select is(api.permit_detail(tests.w('wah')) -> 'emergency_contacts', 'null'::jsonb, 'until the venue publishes them, there are no emergency contacts (no default)');
select is(api.publish_emergency_contacts(tests.key(), tests.w('v1'), '[{"label": "Control room", "phone": "020 7000 0000"}]', 'Mine') ->> 'code',
  'not_tenant_admin', 'only the venue publishes its emergency contacts');
select tests.login(tests.w('u_a1'));
select is(api.publish_emergency_contacts(tests.key(), tests.w('v1'), '[{"label": "Control room", "phone": "call me"}]', 'Test') ->> 'code',
  'invalid_content', 'each needs a phone number');
select tests.must(api.publish_emergency_contacts(tests.key(), tests.w('v1'),
  '[{"label": "Control room", "phone": "020 7000 0000"}, {"label": "First aid", "phone": "020 7000 0001"}]', 'Venue operations manual (test values)'));
select tests.login(tests.w('u_op'));
select is(api.permit_detail(tests.w('wah')) #>> '{emergency_contacts,0,label}', 'Control room', 'the live permit shows the venue''s emergency contacts');

-- ---- The team member's own live permits ---------------------------------------------------------------
select is((select jsonb_agg(x ->> 'class_name' order by x ->> 'class_name') from jsonb_array_elements(api.my_live_permits() -> 'permits') x),
  '["Work Approval", "Work at height"]'::jsonb, 'the supervisor sees the permits they are on');
select tests.login(tests.w('u_nia'));
select is(jsonb_array_length(api.my_live_permits() -> 'permits'), 0, 'someone not on the team sees none');

-- ---- The live board ------------------------------------------------------------------------------------
select tests.login(tests.w('u_op'));
select tests.must(api.stop_work(tests.key(), tests.w('wah'), 'unsafe_act', 'Cable cover'));
select tests.login(tests.w('u_ivy'));
select is((select x #>> '{holding,0,who}' from jsonb_array_elements(api.live_board() -> 'permits') x where (x ->> 'id')::uuid = tests.w('wah')),
  'An issuer for this permit''s class and area', 'the board shows what holds each permit and who can lift it');
select is((select x ->> 'status' from jsonb_array_elements(api.live_board() -> 'permits') x where (x ->> 'id')::uuid = tests.w('wa')), 'suspended',
  'with each permit''s recorded state');
select tests.login(tests.w('u_vic'));
select tests.must(api.stop_area(tests.key(), tests.w('hall2'), 'emergency', 'Alarm'));
select is((select x ->> 'area' from jsonb_array_elements(api.live_board() -> 'area_stops') x), 'Hall 2', 'and area stops in force');
select tests.login(tests.w('u_op'));
select is(jsonb_array_length(api.live_board() -> 'permits'), 0, 'a contractor has no live board');
select tests.login(tests.w('u_b1'));
select is(jsonb_array_length(api.live_board() -> 'permits') + jsonb_array_length(api.live_board() -> 'area_stops')
          + jsonb_array_length(api.my_live_permits() -> 'permits'), 0, 'nor does another tenant');
select is((select count(*)::int from api.venue_emergency_contacts), 0, 'who sees none of the venue''s contacts');

select tests.logout();
select * from finish();
rollback;
