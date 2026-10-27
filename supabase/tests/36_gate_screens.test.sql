-- Reads for the gate and visit screens (7c): which occupier consents a visit waits for (the
-- occupier named only to the venue's side, P5-6), and who can override at a gate (names only,
-- only to those who work that venue's gates).
begin;
\ir _helpers.psql
\ir _phase3.psql
\ir _phase4.psql
select tests.approve_screening();
\ir _phase5.psql
\ir _phase6.psql
\ir _phase6b.psql
select no_plan();

select tests.set_w('tv_aa', tests.new_type('AA', 'Access Authority', array['access.approve', 'venue_config.approve', 'gate.operate'], '{}'));
select tests.set_w('tv_go', tests.new_type('GO', 'Gate Override', array['gate.override'], '{}'));
select tests.set_w('u_axel', (tests.root_ta('axel@a.test', 'Axel', tests.w('tv_aa'), array[tests.w('pc_wa')], tests.w('site')))[1]);
create temp table t_gina as select tests.root_ta('gina@a.test', 'Gina', tests.w('tv_go'), array[tests.w('pc_wa')], tests.w('hall1')) x;
select tests.set_w('u_gina', (select x[1] from t_gina));
select tests.set_w('p_gina', (select x[2] from t_gina));
select tests.set_w('u_gus', (tests.root_ta('gus@a.test', 'Gus', tests.w('tv_go'), array[tests.w('pc_wa')], tests.w('hall2')))[1]);
select tests.login(tests.w('u_a1'));
select tests.set_w('north', tests.must(api.create_gate_point(tests.key(), tests.w('v1'), tests.w('hall1'), 'North gate')));
select tests.set_w('pc1', (api.create_venue_config_draft(tests.key(), tests.w('v1'), 'access_purposes') ->> 'id')::uuid);
select tests.must(api.save_venue_config_draft(tests.key(), tests.w('pc1'), tests.version('core.venue_config_version', tests.w('pc1')),
  '{"purposes": [{"key": "survey", "name": "Escorted survey", "allows": "Looking", "prohibits": "Work", "induction_course_ids": [], "escort": "always",
    "occupier_consent": true}]}'));
select tests.must(api.propose_venue_config(tests.key(), tests.w('pc1'), tests.version('core.venue_config_version', tests.w('pc1'))));
select tests.login(tests.w('u_axel'));
select tests.must(api.decide_venue_config(tests.key(), tests.w('pc1'), tests.version('core.venue_config_version', tests.w('pc1')), 'approve', 'Agreed'));
select tests.login(tests.w('u_op'));
select tests.set_w('av1', (api.request_access(tests.key(), tests.w('v1'), tests.w('org_o'), 'survey', 'Survey', array[tests.w('hall1'), tests.w('hall2')],
  now() - interval '1 hour', now() + interval '1 day', array[tests.w('p_nia')]) ->> 'id')::uuid);

-- ---- Consents a visit waits for ------------------------------------------------------------------------
select tests.login(tests.w('u_axel'));
select is(api.access_consents_needed(tests.w('av1')), jsonb_build_array(jsonb_build_object('area_id', tests.w('hall2'), 'area', 'Hall 2',
  'organisation_id', tests.w('org_o2'), 'organisation', 'Other Rigging Ltd', 'state', 'waiting')),
  'the venue''s side sees which occupier must consent for Hall 2');
-- (u_op, the requester, also holds a venue appointment, so is on the venue's side; Nia is not.)
select tests.login(tests.w('u_nia'));
select is(api.access_consents_needed(tests.w('av1')) -> 0 ->> 'organisation', null, 'a contractor on the visit is not told who occupies it (P5-6)');
select is(api.access_consents_needed(tests.w('av1')) -> 0 ->> 'organisation_id', null, 'by name or by record');
select is(api.access_consents_needed(tests.w('av1')) -> 0 ->> 'state', 'waiting', 'only the area and that consent is waiting');
select tests.login(tests.w('u_orla'));
select is(api.access_consents_needed(tests.w('av1')), '[]'::jsonb, 'another organisation, even the occupier, sees nothing of the visit');
select tests.login(tests.w('u_b1'));
select is(api.access_consents_needed(tests.w('av1')), '[]'::jsonb, 'nor does another tenant');

-- ---- Who can override at a gate --------------------------------------------------------------------------
select tests.login(tests.w('u_axel'));
select is(api.gate_override_holders(tests.w('north')), '["Gina Authority"]'::jsonb,
  'the operator is told who can override at the North gate: only appointees covering its area');
select tests.login(tests.w('u_gina'));
select is(api.gate_override_holders(tests.w('north')), '["Gina Authority"]'::jsonb, 'as is the override authority');
select tests.login(tests.w('u_op'));
select is(api.gate_override_holders(tests.w('north')), '[]'::jsonb, 'a contractor is not');
select tests.login(tests.w('u_b1'));
select is(api.gate_override_holders(tests.w('north')), '[]'::jsonb, 'nor another tenant');
select tests.login(tests.w('u_r'));
select tests.must(api.impose_restriction(tests.key(), tests.w('v1'), 'person', tests.w('p_gina'), 'Under investigation'));
select tests.login(tests.w('u_axel'));
select is(api.gate_override_holders(tests.w('north')), '[]'::jsonb, 'a restricted authority is not offered as someone who can override');

select * from finish();
rollback;
