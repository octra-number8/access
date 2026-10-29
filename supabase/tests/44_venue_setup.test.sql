-- Venue set-up status (P4, D-025): each item's state comes from the records alone; nothing can
-- be ticked; no score or percentage; readable only by the venue's tenant administrators and
-- its appointees; the names shown are the venue's own appointees for the approving action.
begin;
\ir _helpers.psql
\ir _phase2.psql
\ir _phase3.psql
\ir _phase4.psql
select no_plan();

create function tests.raw(p_sql text) returns void language plpgsql as $$
declare t text := substring(p_sql from 'update ([a-z_.]+) ');
begin
  execute format('alter table %s disable trigger user', t);
  execute p_sql;
  execute format('alter table %s enable trigger user', t);
end $$;

-- The item with this key, as the given user sees it.
create function tests.item(p_user uuid, p_venue uuid, p_key text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform tests.login(p_user);
  r := api.venue_setup(p_venue);
  perform tests.logout();
  return (select x from jsonb_array_elements(r -> 'items') x where x ->> 'key' = p_key);
end $$;
create function tests.setup(p_user uuid, p_venue uuid) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform tests.login(p_user);
  r := api.venue_setup(p_venue);
  perform tests.logout();
  return r;
end $$;
create function tests.state(p_venue uuid, p_key text) returns text language sql as $$
  select tests.item(tests.w('u_a1'), p_venue, p_key) ->> 'state' $$;

-- Who can read it -----------------------------------------------------------------------------
select is(tests.setup(tests.w('u_a1'), tests.w('v1')) ->> 'ok', 'true', 'a tenant administrator can read the venue''s set-up');
select is(tests.setup(tests.w('u_r'), tests.w('v1')) ->> 'ok', 'true', 'so can an appointee at the venue');
select is(tests.setup(tests.w('u_h'), tests.w('v1')) ->> 'ok', 'true', 'including one scoped to a single hall');
select is(tests.setup(tests.w('u_op'), tests.w('v1')) ->> 'code', 'not_found', 'a contractor''s operative cannot');
select is(tests.setup(tests.w('u_b1'), tests.w('v1')) ->> 'code', 'not_found', 'nor another customer''s administrator');
select is(tests.setup(tests.w('u_b1'), tests.w('w1')) ->> 'ok', 'true', '(who can read their own venue)');
select is(tests.setup(tests.w('u_platform'), tests.w('v1')) ->> 'code', 'not_found', 'nor a platform administrator (invariant 9; break-glass is the route)');
select is(tests.setup(tests.w('u_r'), tests.w('v2')) ->> 'code', 'not_found', 'an appointee at V1 cannot read V2');
select is(tests.setup(tests.w('u_a1'), gen_random_uuid()) ->> 'code', 'not_found', 'an unknown venue is not found');
select is((tests.setup(tests.w('u_op'), tests.w('v1')) -> 'items'), null, 'and a refusal carries no items');
select tests.raw(format('update core.appointment set valid_during = tstzrange(lower(valid_during), now() - interval ''1 second'') where id = %L', tests.w('ap_f')));
select is(tests.setup(tests.w('u_f'), tests.w('v1')) ->> 'code', 'not_found', 'an appointee whose appointment has ended cannot');
select tests.raw(format('update core.appointment set valid_during = tstzrange(lower(valid_during), now() + interval ''30 days'') where id = %L', tests.w('ap_f')));
select is(tests.setup(tests.w('u_f'), tests.w('v1')) ->> 'ok', 'true', '(and can again once it is current)');
select is((select count(*)::int from pg_proc where proname = 'venue_setup' and pronamespace = 'api'::regnamespace and provolatile = 's'), 1,
  'the read is declared stable: it changes nothing');
select ok(not has_function_privilege('anon', 'api.venue_setup(uuid)', 'execute'), 'anonymous callers cannot run it');
select ok(not has_function_privilege('authenticated', 'core.setup_item(core.venue, text, text, text, text, text, text, timestamptz, text, text, text, text)', 'execute'),
  'nor call its helpers directly');

-- An empty venue ------------------------------------------------------------------------------
select is((select count(*)::int from jsonb_array_elements(tests.setup(tests.w('u_a1'), tests.w('v2')) -> 'items') x
             where x ->> 'state' <> case x ->> 'key' when 'evidence' then 'none_defined' else 'not_set_up' end), 0,
  'on a venue with nothing set up, every item says Not set up, except evidence requirements, which say None defined (S1-10)');
select is((select array_agg(x ->> 'key' order by x ->> 'key') from jsonb_array_elements(tests.setup(tests.w('u_a1'), tests.w('v2')) -> 'items') x),
  array['access_purposes', 'appointment_types', 'areas', 'calendar', 'chasing', 'class:work_approval', 'courses', 'emergency_config',
        'emergency_contacts', 'entry_rules', 'evidence', 'gate_points', 'outage_procedure', 'retention', 'root_appointment', 'screening', 'systems', 'work_types'],
  'and lists every piece the venue must set up');
select is((select count(*)::int from jsonb_array_elements(tests.setup(tests.w('u_a1'), tests.w('v2')) -> 'items') x where x ->> 'state_words' = 'Not set up'), 17,
  'in words');
select is((select array_agg(distinct k order by k) from jsonb_array_elements(tests.setup(tests.w('u_a1'), tests.w('v1')) -> 'items') x, jsonb_object_keys(x) k),
  array['detail', 'holder_action', 'holders', 'href', 'in_force_from', 'key', 'name', 'needed_for', 'pending', 'resolved_by', 'section', 'state', 'state_words'],
  'an item carries words, dates, names and a link: no score, percentage or tick');
select is((select count(*)::int from jsonb_array_elements(tests.setup(tests.w('u_a1'), tests.w('v1')) -> 'items') x
            where x ->> 'needed_for' is null or x ->> 'resolved_by' is null), 0, 'every item says what it is needed for and who resolves it');

-- Authority -----------------------------------------------------------------------------------
select is(tests.state(tests.w('v1'), 'root_appointment'), 'in_force', 'V1''s root appointment is in force');
select ok(tests.item(tests.w('u_a1'), tests.w('v1'), 'root_appointment') ->> 'detail' like '%Rae Root%', 'naming the root appointee');
select is(tests.item(tests.w('u_a1'), tests.w('v1'), 'appointment_types') ->> 'detail',
  format('%s in force', (select count(*) from core.appointment_type where venue_id = tests.w('v1'))), 'appointment types are counted');

-- The ceremony at V2, step by step (D-002, D-009).
select tests.login(tests.w('u_a1'));
select tests.set_w('t2', tests.must(api.create_appointment_type(tests.key(), tests.w('v2'), 'ROOT', 'Authorising Engineer')));
select tests.set_w('tv2', tests.must(api.publish_appointment_type_version(tests.key(), tests.w('t2'), array['appointment.grant'], '{}', '{}', '{}',
  true, false, tests.w('p_a1'), now() - interval '1 day', 'Initial set-up')));
select tests.logout();
select is(tests.state(tests.w('v2'), 'appointment_types'), 'recorded', 'a published type is recorded');
select tests.login(tests.w('u_a1'));
select tests.set_w('ap2', tests.must(api.record_root_appointment(tests.key(), tests.w('v2'), tests.w('p_r'), tests.w('p_d'), tests.w('tv2'), '{}',
  jsonb_build_array(jsonb_build_object('area_id', tests.w('site2'))), now() - interval '1 hour', null, (now() + interval '1 year')::date, null, 'Letter DH-002')));
select tests.logout();
select is(tests.state(tests.w('v2'), 'root_appointment'), 'proposed', 'a recorded root appointment is not yet in force');
select is(tests.item(tests.w('u_a1'), tests.w('v2'), 'root_appointment') ->> 'detail', 'Rae Root: waiting for a second tenant administrator to confirm it',
  'and says who must act next');
select is(tests.item(tests.w('u_a1'), tests.w('v2'), 'root_appointment') ->> 'state_words', 'Awaiting approval', 'in words');
select tests.login(tests.w('u_a2'));
select tests.must(api.confirm_root_appointment(tests.key(), tests.w('ap2'), tests.version('core.appointment', tests.w('ap2'))));
select tests.logout();
select is(tests.item(tests.w('u_a1'), tests.w('v2'), 'root_appointment') ->> 'detail', 'Rae Root: waiting for the appointee to acknowledge it',
  'confirmed, it waits for the appointee');
select is(tests.state(tests.w('v2'), 'root_appointment'), 'proposed', '(still not in force)');
select is(tests.setup(tests.w('u_r'), tests.w('v2')) ->> 'ok', 'true', 'the appointee can read V2''s set-up before acknowledging, to see what is asked of them');
select tests.login(tests.w('u_r'));
select tests.must(api.acknowledge_appointment(tests.key(), tests.w('ap2'), tests.version('core.appointment', tests.w('ap2'))));
select tests.logout();
select is(tests.state(tests.w('v2'), 'root_appointment'), 'in_force', 'acknowledged, it is in force');
select is(tests.item(tests.w('u_a1'), tests.w('v2'), 'root_appointment') ->> 'pending', null, 'with nothing pending');

-- A revoked root appointment is not in force.
select tests.login(tests.w('u_a1'));
select tests.set_w('ap2b', tests.must(api.record_root_appointment(tests.key(), tests.w('v2'), tests.w('p_h'), tests.w('p_d'), tests.w('tv2'), '{}',
  jsonb_build_array(jsonb_build_object('area_id', tests.w('site2'))), now() - interval '1 hour', null, (now() + interval '1 year')::date, null, 'Letter DH-003')));
select tests.logout();
select is(tests.item(tests.w('u_a1'), tests.w('v2'), 'root_appointment') ->> 'pending', 'Hal Hall: waiting for a second tenant administrator to confirm it.',
  'a second root appointment in progress is reported as pending beside the one in force');
select tests.logout();
select tests.raw(format('update core.appointment set status = ''revoked'', revoked_at = now() where id = %L', tests.w('ap2')));
select is(tests.state(tests.w('v2'), 'root_appointment'), 'proposed', 'once the only root in force is revoked, the item is no longer in force');

-- Places and systems --------------------------------------------------------------------------
select is(tests.item(tests.w('u_a1'), tests.w('v1'), 'areas') ->> 'detail', '4 below the venue', 'V1''s areas are counted, not the venue itself');
select is(tests.item(tests.w('u_a1'), tests.w('v1'), 'systems') ->> 'detail', '2 registered', 'and its systems');
select is(tests.item(tests.w('u_a1'), tests.w('v1'), 'areas') ->> 'href', '/venue/places', 'areas link to their screen (S1b)');
select is(tests.item(tests.w('u_a1'), tests.w('v1'), 'systems') ->> 'href', '/venue/places#systems', 'and so do systems');

-- Work and permits ----------------------------------------------------------------------------
select is(tests.state(tests.w('v1'), 'calendar'), 'not_set_up', 'no calendar yet');
select tests.login(tests.w('u_a1'));
select tests.must(api.publish_venue_calendar(tests.key(), tests.w('v1'), array[1,2,3,4,5], '{}', '16:00', now() + interval '7 days', 'Next season'));
select tests.logout();
select is(tests.state(tests.w('v1'), 'calendar'), 'scheduled', 'a calendar effective next week is published but not in force');
select is(tests.item(tests.w('u_a1'), tests.w('v1'), 'calendar') ->> 'state_words', 'Published, not yet in force', 'in words');
select tests.login(tests.w('u_a1'));
select tests.must(api.publish_venue_calendar(tests.key(), tests.w('v1'), array[1,2,3,4,5], '{}', '16:00', now() - interval '1 day', 'This season'));
select tests.logout();
select is(tests.state(tests.w('v1'), 'calendar'), 'in_force', 'one effective yesterday is in force');
select is(tests.item(tests.w('u_a1'), tests.w('v1'), 'calendar') ->> 'pending', 'A newer version is published and not yet in force.', 'with the later one noted');
select is(tests.item(tests.w('u_a1'), tests.w('v1'), 'calendar') -> 'holders', 'null'::jsonb, 'a tenant administrator''s action names no appointees');

select is(tests.state(tests.w('v1'), 'work_types'), 'recorded', 'work types are recorded');
select is(tests.state(tests.w('v2'), 'work_types'), 'not_set_up', '(none at V2)');

select is(tests.state(tests.w('v1'), 'screening'), 'draft', 'a screening draft is a draft, not in force');
select is(tests.item(tests.w('u_a1'), tests.w('v1'), 'screening') ->> 'detail', 'Version 1', 'naming its version');
select tests.login(tests.w('u_a1'));
select tests.must(api.propose_screening_version(tests.key(), tests.w('ss1'), tests.version('core.screening_set_version', tests.w('ss1'))));
select tests.logout();
select is(tests.state(tests.w('v1'), 'screening'), 'proposed', 'proposed, it awaits approval');
select is(tests.item(tests.w('u_a1'), tests.w('v1'), 'screening') -> 'holders', jsonb_build_array(core.person_name(tests.w('p_tara'))),
  'naming the appointee whose appointment covers the whole venue, and not one scoped to a hall');
select tests.login(tests.w('u_tara'));
select tests.must(api.decide_screening_version(tests.key(), tests.w('ss1'), tests.version('core.screening_set_version', tests.w('ss1')), 'approve', 'Validated'));
select tests.logout();
select is(tests.state(tests.w('v1'), 'screening'), 'in_force', 'approved, it is in force');
select is(tests.item(tests.w('u_a1'), tests.w('v1'), 'screening') ->> 'detail', format('Version 1, approved by %s', core.person_name(tests.w('p_tara'))),
  'saying who approved it');
select is((tests.item(tests.w('u_a1'), tests.w('v1'), 'screening') ->> 'in_force_from')::timestamptz,
  (select decided_at from core.screening_set_version where id = tests.w('ss1')), 'and from when');
select tests.login(tests.w('u_a1'));
select tests.must(api.create_screening_draft(tests.key(), tests.w('v1')));
select tests.logout();
select is(tests.state(tests.w('v1'), 'screening'), 'in_force', 'a new draft does not take version 1 out of force');
select is(tests.item(tests.w('u_a1'), tests.w('v1'), 'screening') ->> 'pending', 'Version 2 is being drafted.', 'it is noted as pending');

select is(tests.state(tests.w('v1'), 'class:work_approval'), 'not_set_up', 'no Work Approval class yet');
select is(tests.state(tests.w('v1'), 'class:' || tests.w('pc_hw')), 'not_set_up', 'Hot works has no approved configuration');
select is(tests.item(tests.w('u_a1'), tests.w('v1'), 'class:' || tests.w('pc_hw')) ->> 'name', 'Permit class: Hot works', 'named as a permit class');
select is(tests.item(tests.w('u_a1'), tests.w('v1'), 'class:' || tests.w('pc_cs')), null,
  'a deferred specialist class handled by external reference is not listed as set-up work (CLAUDE.md §7)');

select is(tests.state(tests.w('v1'), 'controls:' || tests.w('st_fa')), 'not_set_up', 'the fire alarm type has no control rules');
select ok(tests.item(tests.w('u_a1'), tests.w('v1'), 'controls:' || tests.w('st_hv')) is not null, 'nor does high voltage, and it is listed');
select tests.login(tests.w('u_a1'));
select tests.set_w('st_none', tests.must(api.create_system_type(tests.key(), tests.w('v1'), 'LIFT', 'Lifts')));
select tests.logout();
select is(tests.item(tests.w('u_a1'), tests.w('v1'), 'controls:' || tests.w('st_none')), null, 'a system type with no registered systems is not listed');

select is(tests.state(tests.w('v1'), 'emergency_contacts'), 'not_set_up', 'no emergency contacts yet');
select tests.login(tests.w('u_a1'));
select tests.must(api.publish_emergency_contacts(tests.key(), tests.w('v1'),
  jsonb_build_array(jsonb_build_object('label', 'Control room', 'phone', '020 7000 0000')), 'Go-live'));
select tests.logout();
select is(tests.state(tests.w('v1'), 'emergency_contacts'), 'in_force', 'published, they are in force (6d-1)');
select is(tests.item(tests.w('u_a1'), tests.w('v1'), 'emergency_contacts') ->> 'detail', 'Owner: Ada Admin', 'with their owner');

-- Inductions ----------------------------------------------------------------------------------
select is(tests.state(tests.w('v1'), 'course:' || tests.w('course_core')), 'in_force', 'the published induction is in force');
select is(tests.item(tests.w('u_a1'), tests.w('v1'), 'courses'), null, 'and no "no courses" item is shown');
select tests.login(tests.w('u_a1'));
select tests.set_w('c2', tests.must(api.create_induction_course(tests.key(), tests.w('v1'), 'HALLS', 'Hall induction')));
select tests.logout();
select is(tests.state(tests.w('v1'), 'course:' || tests.w('c2')), 'not_set_up', 'a course with no version is not set up');

-- Gate and visits; notices and records ----------------------------------------------------------
select is(tests.state(tests.w('v1'), 'entry_rules'), 'not_set_up', 'no entry rules yet');
select is(tests.state(tests.w('v1'), 'gate_points'), 'not_set_up', 'no gate points yet');
select tests.login(tests.w('u_a1'));
select tests.must(api.create_gate_point(tests.key(), tests.w('v1'), tests.w('hall1'), 'North gate'));
select tests.logout();
select is(tests.item(tests.w('u_a1'), tests.w('v1'), 'gate_points') ->> 'detail', '1 in use', 'a gate point is counted');

select is(tests.state(tests.w('v1'), 'outage_procedure'), 'not_set_up', 'no outage procedure yet');
select tests.login(tests.w('u_a1'));
select tests.set_w('op1', tests.must(api.create_venue_config_draft(tests.key(), tests.w('v1'), 'outage_procedure')));
select tests.logout();
select is(tests.state(tests.w('v1'), 'outage_procedure'), 'draft', 'a draft outage procedure is a draft');
select is(tests.item(tests.w('u_a1'), tests.w('v1'), 'outage_procedure') -> 'holders', '[]'::jsonb,
  'no one at the venue can approve it yet, and the item shows that');
select is(tests.state(tests.w('v1'), 'access_purposes'), 'not_set_up', 'one kind of configuration does not set up another');
select is(tests.state(tests.w('v1'), 'chasing'), 'not_set_up', 'reminders not set up');
select is(tests.state(tests.w('v1'), 'retention'), 'not_set_up', 'retention not set up');
select is(tests.item(tests.w('u_a1'), tests.w('v1'), 'retention') ->> 'holder_action', 'retention.approve', 'retention names its own approving action');

-- Reading it left no trace and changed nothing -------------------------------------------------
select is((select count(*)::int from audit.audit_event where action = 'venue_setup'), 0, 'reading the set-up records no decision');

select * from finish();
rollback;
