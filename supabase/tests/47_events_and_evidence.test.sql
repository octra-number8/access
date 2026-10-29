-- Events and evidence settings (S1c, D-026): events and their phases, document types, review
-- criteria and evidence requirements, as a tenant administrator sets them up from the screens.
-- A phase falls within its event; criteria have distinct codes; refusals are in words; nothing
-- gets a default, so a venue with no requirements asks for no evidence and says so (S1-10).
-- Administration grants no operational authority, and none of this is open to other customers,
-- the platform administrator or the venue's appointees.
begin;
\ir _helpers.psql
select no_plan();

create function tests.as_user(p_user uuid, p_call text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform tests.login(p_user);
  execute 'select ' || p_call into r;
  perform tests.logout();
  return r;
end $$;
create function tests.setup_item(p_key text) returns jsonb language sql as $$
  select i from jsonb_array_elements(tests.as_user(tests.w('u_a1'), format('api.venue_setup(%L)', tests.w('v1'))) -> 'items') i
   where i ->> 'key' = p_key $$;
create temp table t_r (name text primary key, v jsonb);
grant all on t_r to authenticated;

-- ---- Who may set up events ----------------------------------------------------------------------
select is(tests.as_user(tests.w('u_platform'), format($$api.create_event(%L, %L, 'X1', 'Expo', now() + interval '10 days', now() + interval '20 days')$$,
  tests.key(), tests.w('v1'))) ->> 'ok', 'false', 'a platform administrator cannot create an event (invariant 9)');
select is(tests.as_user(tests.w('u_r'), format($$api.create_event(%L, %L, 'X1', 'Expo', now() + interval '10 days', now() + interval '20 days')$$,
  tests.key(), tests.w('v1'))) ->> 'ok', 'false', 'nor can the root appointee, who is not a tenant administrator');
select is(tests.as_user(tests.w('u_b1'), format($$api.create_event(%L, %L, 'X1', 'Expo', now() + interval '10 days', now() + interval '20 days')$$,
  tests.key(), tests.w('v1'))) ->> 'ok', 'false', 'nor another customer''s administrator');
select is((select count(*)::int from core.event), 0, 'and no event was created');

-- ---- Events and phases --------------------------------------------------------------------------
select tests.login(tests.w('u_a1'));
select set_config('tests.ev_key', tests.key(), true);
select set_config('tests.ev_start', (now() + interval '10 days')::text, true);
select tests.set_w('ev', tests.must(api.create_event(current_setting('tests.ev_key'), tests.w('v1'), 'EXPO27', 'Expo 2027',
  current_setting('tests.ev_start')::timestamptz, current_setting('tests.ev_start')::timestamptz + interval '10 days')));
select is(api.create_event(current_setting('tests.ev_key'), tests.w('v1'), 'EXPO27', 'Expo 2027',
  current_setting('tests.ev_start')::timestamptz, current_setting('tests.ev_start')::timestamptz + interval '10 days') ->> 'replayed',
  'true', 'repeating the same request is a replay');
select is((select count(*)::int from core.event), 1, 'and creates nothing more');
select throws_ok(format($$select api.create_event(%L, %L, 'EXPO27', 'Another', now() + interval '1 day', now() + interval '2 days')$$, tests.key(), tests.w('v1')),
  '22023', 'that code is already used by another event at this venue', 'a code already used is refused in words');
select throws_ok(format($$select api.create_event(%L, %L, 'BACK', 'Backwards', now() + interval '2 days', now() + interval '1 day')$$, tests.key(), tests.w('v1')),
  '22023', 'an event must end after it starts', 'an event ending before it starts is refused in words');
select throws_ok(format($$select api.create_event(%L, %L, 'ZERO', 'No length', now() + interval '2 days', now() + interval '2 days')$$, tests.key(), tests.w('v1')),
  '22023', 'an event must end after it starts', 'as is one that ends when it starts');

select tests.set_w('ph_build', tests.must(api.add_event_phase(tests.key(), tests.w('ev'), 'build',
  current_setting('tests.ev_start')::timestamptz, current_setting('tests.ev_start')::timestamptz + interval '3 days')));
select tests.must(api.add_event_phase(tests.key(), tests.w('ev'), 'live',
  current_setting('tests.ev_start')::timestamptz + interval '3 days', current_setting('tests.ev_start')::timestamptz + interval '8 days'));
select throws_ok(format($$select api.add_event_phase(%L, %L, 'breakdown', %L::timestamptz, %L::timestamptz)$$, tests.key(), tests.w('ev'),
    current_setting('tests.ev_start')::timestamptz + interval '8 days', current_setting('tests.ev_start')::timestamptz + interval '12 days'),
  '22023', 'a phase must fall within its event''s dates', 'a phase running past its event is refused in words');
select throws_ok(format($$select api.add_event_phase(%L, %L, 'build', %L::timestamptz, %L::timestamptz)$$, tests.key(), tests.w('ev'),
    current_setting('tests.ev_start')::timestamptz - interval '1 day', current_setting('tests.ev_start')::timestamptz + interval '1 day'),
  '22023', 'a phase must fall within its event''s dates', 'as is one starting before it');
select throws_ok(format($$select api.add_event_phase(%L, %L, 'build', %L::timestamptz, %L::timestamptz)$$, tests.key(), tests.w('ev'),
    current_setting('tests.ev_start')::timestamptz + interval '2 days', current_setting('tests.ev_start')::timestamptz + interval '4 days'),
  '22023', 'this event already has a build phase at those times', 'two phases of the same kind cannot overlap, in words');
select throws_ok(format($$select api.add_event_phase(%L, %L, 'breakdown', %L::timestamptz, %L::timestamptz)$$, tests.key(), tests.w('ev'),
    current_setting('tests.ev_start')::timestamptz + interval '9 days', current_setting('tests.ev_start')::timestamptz + interval '9 days'),
  '22023', 'a phase must end after it starts', 'a phase with no length is refused');
select tests.must(api.add_event_phase(tests.key(), tests.w('ev'), 'breakdown',
  current_setting('tests.ev_start')::timestamptz + interval '8 days', current_setting('tests.ev_start')::timestamptz + interval '10 days'));
select tests.logout();

select is(tests.as_user(tests.w('u_platform'), format($$api.add_event_phase(%L, %L, 'live', %L::timestamptz, %L::timestamptz)$$, tests.key(), tests.w('ev'),
    current_setting('tests.ev_start')::timestamptz + interval '1 day', current_setting('tests.ev_start')::timestamptz + interval '2 days')) ->> 'ok',
  'false', 'a platform administrator cannot add a phase');
select is(tests.as_user(tests.w('u_b1'), format($$api.add_event_phase(%L, %L, 'live', %L::timestamptz, %L::timestamptz)$$, tests.key(), tests.w('ev'),
    current_setting('tests.ev_start')::timestamptz + interval '1 day', current_setting('tests.ev_start')::timestamptz + interval '2 days')) ->> 'ok',
  'false', 'nor another customer''s administrator');

-- The database holds the same rules whatever the path.
select throws_ok(format($$insert into core.event_phase (customer_id, venue_id, event_id, phase, valid_during)
                          select customer_id, venue_id, id, 'live', tstzrange(upper(valid_during), upper(valid_during) + interval '1 day')
                            from core.event where id = %L$$, tests.w('ev')),
  '23514', 'a phase must fall within its event''s dates', 'a phase outside its event is refused by the database');
select throws_ok(format($$insert into core.event (customer_id, venue_id, code, name, valid_during)
                          values (%L, %L, 'EMPTY', 'Empty', tstzrange(now(), now()))$$, tests.w('cust_a'), tests.w('v1')),
  '23514', null, 'and so is an event with no length');
select throws_ok(format($$update core.event_phase set valid_during = tstzrange(now(), now() + interval '1 day') where id = %L$$, tests.w('ph_build')),
  null, null, 'a phase cannot be moved once added');

-- ---- The events read ----------------------------------------------------------------------------
insert into t_r select 'ev_a1', tests.as_user(tests.w('u_a1'), format('api.events_overview(%L)', tests.w('v1')));
insert into t_r select 'ev_r', tests.as_user(tests.w('u_r'), format('api.events_overview(%L)', tests.w('v1')));
select is((select v ->> 'can_manage' from t_r where name = 'ev_a1') || '/' || (select v ->> 'can_manage' from t_r where name = 'ev_r'), 'true/false',
  'a tenant administrator can manage events; an appointee can see them but is offered nothing to change');
select is((select string_agg(p ->> 'phase', ',') from t_r, jsonb_array_elements(v -> 'events' -> 0 -> 'phases') p where name = 'ev_a1'),
  'build,live,breakdown', 'phases are listed in time order');
select is((select (v -> 'events' -> 0 ->> 'jobs') || '/' || (v -> 'events' -> 0 ->> 'courses') from t_r where name = 'ev_a1'), '0/0',
  'with how many jobs and courses refer to the event');
select is(tests.as_user(tests.w('u_b1'), format('api.events_overview(%L)', tests.w('v1'))) ->> 'ok', 'false', 'another customer''s administrator sees nothing');
select is(tests.as_user(tests.w('u_platform'), format('api.events_overview(%L)', tests.w('v1'))) ->> 'ok', 'false', 'nor does a platform administrator');
select is(tests.as_user(tests.w('u_op'), format('api.events_overview(%L)', tests.w('v1'))) ->> 'ok', 'false', 'nor does an operative');

-- ---- With nothing defined, nothing is asked for (S1-10) -----------------------------------------
select is(tests.setup_item('evidence') ->> 'state_words', 'None defined', 'the set-up page says no evidence requirements are defined');
select is((select count(*)::int from jsonb_array_elements(tests.as_user(tests.w('u_a1'), format('api.venue_setup(%L)', tests.w('v1'))) -> 'items') i
            where i ->> 'state' in ('not_set_up', 'draft', 'proposed', 'scheduled') and i ->> 'key' = 'evidence'), 0,
  'which is a recorded state, not a gap to fill');
select is(jsonb_array_length(tests.as_user(tests.w('u_a1'), format('api.engagement_evidence(%L)', tests.w('e1'))) -> 'evidence'), 0,
  'and an engagement is asked for no evidence');

-- ---- Document types and review criteria ----------------------------------------------------------
select is(tests.as_user(tests.w('u_platform'), format($$api.create_document_type(%L, %L, 'INS', 'Insurance', 'organisation')$$, tests.key(), tests.w('v1'))) ->> 'ok',
  'false', 'a platform administrator cannot add a document type');
select is(tests.as_user(tests.w('u_r'), format($$api.create_document_type(%L, %L, 'INS', 'Insurance', 'organisation')$$, tests.key(), tests.w('v1'))) ->> 'ok',
  'false', 'nor can an appointee');
select tests.login(tests.w('u_a1'));
select tests.set_w('dt_ins', tests.must(api.create_document_type(tests.key(), tests.w('v1'), 'INS', 'Public liability insurance', 'organisation')));
select tests.set_w('dt_cv', tests.must(api.create_document_type(tests.key(), tests.w('v1'), 'CV', 'Competence CV', 'person')));
select throws_ok(format($$select api.create_document_type(%L, %L, 'INS', 'Other', 'person')$$, tests.key(), tests.w('v1')),
  '22023', 'that code is already used by another document type at this venue', 'a document type code already used is refused in words');
select tests.logout();
select is(tests.setup_item('evidence') ->> 'pending',
  'No review criteria in force for: Competence CV, Public liability insurance. Their documents cannot be reviewed.',
  'the set-up page names document types whose documents cannot yet be reviewed');

select tests.login(tests.w('u_a1'));
select throws_ok(format($$select api.publish_review_criteria(%L, %L, '[{"code":"in_date","label":"In date"},{"code":"in_date","label":"Covers the venue"}]', %L, now(), 'First criteria')$$,
                        tests.key(), tests.w('dt_ins'), tests.w('p_a1')),
  '23514', 'each criterion needs its own code', 'two criteria with the same code are refused');
select throws_ok(format($$select api.publish_review_criteria(%L, %L, '[{"code":"in_date","label":"  "}]', %L, now(), 'First criteria')$$,
                        tests.key(), tests.w('dt_ins'), tests.w('p_a1')),
  '23514', 'each criterion needs a code and a label', 'a criterion with a blank label is refused');
select tests.must(api.publish_review_criteria(tests.key(), tests.w('dt_ins'),
  '[{"code":"in_date","label":"In date for the engagement"},{"code":"limit","label":"Limit at least the venue minimum"}]', tests.w('p_a1'), now(), 'First criteria'));
select tests.must(api.publish_review_criteria(tests.key(), tests.w('dt_ins'),
  '[{"code":"in_date","label":"In date for the engagement"}]', tests.w('p_a1'), now() + interval '30 days', 'Limit moved to the contract'));
select throws_ok(format($$select api.publish_review_criteria(%L, %L, '[{"code":"a","label":"A"}]', %L, now() + interval '29 days', 'Earlier')$$,
                        tests.key(), tests.w('dt_ins'), tests.w('p_a1')),
  '23514', 'a new version must take effect after the previous one', 'a version cannot take effect before the latest one');
select tests.logout();
select is(tests.as_user(tests.w('u_platform'), format($$api.publish_review_criteria(%L, %L, '[{"code":"a","label":"A"}]', %L, now() + interval '40 days', 'x')$$,
  tests.key(), tests.w('dt_cv'), tests.w('p_a1'))) ->> 'ok', 'false', 'a platform administrator cannot publish review criteria');
select is(tests.as_user(tests.w('u_r'), format($$api.publish_review_criteria(%L, %L, '[{"code":"a","label":"A"}]', %L, now() + interval '40 days', 'x')$$,
  tests.key(), tests.w('dt_cv'), tests.w('p_r'))) ->> 'ok', 'false', 'nor can an appointee');
select is(tests.as_user(tests.w('u_b1'), format($$api.publish_review_criteria(%L, %L, '[{"code":"a","label":"A"}]', %L, now() + interval '40 days', 'x')$$,
  tests.key(), tests.w('dt_cv'), tests.w('p_b1'))) ->> 'ok', 'false', 'nor another customer''s administrator');
select is(tests.setup_item('evidence') ->> 'pending',
  'No review criteria in force for: Competence CV. Their documents cannot be reviewed.', 'once criteria are in force the type drops off that list');

-- ---- Evidence requirements --------------------------------------------------------------------------
select tests.login(tests.w('u_a1'));
select tests.set_w('ct_ipaf', tests.must(api.create_competency_type(tests.key(), tests.w('v1'), 'IPAF', 'IPAF 3a/3b')));
select throws_ok(format($$select api.create_evidence_requirement(%L, %L, 'PC-IPAF', 'IPAF', 'engagement_capacity', 'performing_contractor', null, 'competency_type', null, %L)$$,
                        tests.key(), tests.w('v1'), tests.w('ct_ipaf')),
  '22023', 'organisations hold documents, not competencies: ask for a document type', 'an organisation cannot be asked for a competency, in words');
select throws_ok(format($$select api.create_evidence_requirement(%L, %L, 'PC-CV', 'CV', 'engagement_capacity', 'performing_contractor', null, 'document_type', %L, null)$$,
                        tests.key(), tests.w('v1'), tests.w('dt_cv')),
  '23514', null, 'nor for a person''s document');
select tests.set_w('rq_ins', tests.must(api.create_evidence_requirement(tests.key(), tests.w('v1'), 'PC-INS', 'Insurance for performing contractors',
  'engagement_capacity', 'performing_contractor', null, 'document_type', tests.w('dt_ins'), null)));
select tests.set_w('rq_ipaf', tests.must(api.create_evidence_requirement(tests.key(), tests.w('v1'), 'H-IPAF', 'IPAF for hot works issuers',
  'appointment_type', null, tests.w('t_hall'), 'competency_type', null, tests.w('ct_ipaf'))));
select throws_ok(format($$select api.create_evidence_requirement(%L, %L, 'PC-INS', 'Again', 'engagement_capacity', 'occupier', null, 'document_type', %L, null)$$,
                        tests.key(), tests.w('v1'), tests.w('dt_ins')),
  '22023', 'that code is already used by another evidence requirement at this venue', 'a requirement code already used is refused in words');
select tests.logout();
select is(jsonb_array_length(tests.as_user(tests.w('u_a1'), format('api.engagement_evidence(%L)', tests.w('e1'))) -> 'evidence'), 0,
  'a requirement with no published version asks for nothing');
select is(tests.setup_item('evidence') ->> 'state_words', 'None defined', 'and the set-up page still says none is defined');

select is(tests.as_user(tests.w('u_platform'), format($$api.publish_evidence_requirement_version(%L, %L, true, %L, now(), 'x')$$,
  tests.key(), tests.w('rq_ins'), tests.w('p_a1'))) ->> 'ok', 'false', 'a platform administrator cannot put a requirement in force');
select is(tests.as_user(tests.w('u_r'), format($$api.publish_evidence_requirement_version(%L, %L, true, %L, now(), 'x')$$,
  tests.key(), tests.w('rq_ins'), tests.w('p_r'))) ->> 'ok', 'false', 'nor can an appointee');
select tests.login(tests.w('u_a1'));
select tests.must(api.publish_evidence_requirement_version(tests.key(), tests.w('rq_ins'), true, tests.w('p_a1'), now(), 'Venue insurance policy'));
select tests.must(api.publish_evidence_requirement_version(tests.key(), tests.w('rq_ins'), false, tests.w('p_a1'), now() + interval '60 days', 'Covered by the landlord policy from then'));
select tests.must(api.publish_evidence_requirement_version(tests.key(), tests.w('rq_ipaf'), true, tests.w('p_a1'), now() + interval '7 days', 'From the next event'));
select tests.logout();
select is(tests.as_user(tests.w('u_a1'), format('api.engagement_evidence(%L)', tests.w('e1'))) -> 'evidence' -> 0 ->> 'state', 'missing',
  'once in force, an engagement of that capacity is asked for it');
select is(tests.setup_item('evidence') ->> 'detail', '1 in force', 'the set-up page counts requirements in force');
select ok(tests.setup_item('evidence') ->> 'pending' like '2 with a version taking effect later.%', 'and those with a version still to come');
select throws_ok(format($$update core.evidence_requirement_version set in_force = false where evidence_requirement_id = %L$$, tests.w('rq_ins')),
  null, null, 'a published version cannot be changed');

-- ---- The evidence read ----------------------------------------------------------------------------------
insert into t_r select 'es_a1', tests.as_user(tests.w('u_a1'), format('api.evidence_settings(%L)', tests.w('v1')));
insert into t_r select 'es_r', tests.as_user(tests.w('u_r'), format('api.evidence_settings(%L)', tests.w('v1')));
select is((select v ->> 'can_manage' from t_r where name = 'es_a1'), 'true', 'a tenant administrator can manage evidence settings');
select is((select v ->> 'can_manage' from t_r where name = 'es_r') || '/' || coalesce((select v ->> 'people' from t_r where name = 'es_r'), 'none'),
  'false/none', 'an appointee sees them but is offered nothing to change, and no list of people');
select ok((select v -> 'people' @> jsonb_build_array(jsonb_build_object('id', tests.w('p_a1'))) and v -> 'people' @> jsonb_build_array(jsonb_build_object('id', tests.w('p_r')))
             from t_r where name = 'es_a1'),
  'an administrator can name the venue''s administrators and appointees as owners');
select ok(not (select v -> 'people' @> jsonb_build_array(jsonb_build_object('id', tests.w('p_op'))) from t_r where name = 'es_a1'),
  'but not a contractor''s operative');
select is((select string_agg(c ->> 'state', ',' order by (c ->> 'version_no')::int) from t_r, jsonb_array_elements(v -> 'document_types') t, jsonb_array_elements(t -> 'criteria') c
            where name = 'es_a1' and t ->> 'code' = 'INS'), 'current,scheduled', 'each criteria version says whether it is current or still to come');
select is((select r ->> 'applies_to' || ' — ' || (r ->> 'requires') || ' — ' || (r ->> 'in_force') from t_r, jsonb_array_elements(v -> 'requirements') r
            where name = 'es_a1' and r ->> 'code' = 'PC-INS'),
  'Organisations engaged as performing contractor — Document: Public liability insurance — true', 'each requirement says who it applies to and what it asks for, in words');
select is((select r ->> 'applies_to' || ' — ' || (r ->> 'in_force') from t_r, jsonb_array_elements(v -> 'requirements') r
            where name = 'es_a1' and r ->> 'code' = 'H-IPAF'), 'People appointed as ' || (select name from core.appointment_type where id = tests.w('t_hall')) || ' — false',
  'and one taking effect later is not yet in force');
select is((select string_agg(x ->> 'state', ',' order by (x ->> 'version_no')::int) from t_r, jsonb_array_elements(v -> 'requirements') r, jsonb_array_elements(r -> 'versions') x
            where name = 'es_a1' and r ->> 'code' = 'PC-INS'), 'current,scheduled', 'with each of its versions');
select is(tests.as_user(tests.w('u_b1'), format('api.evidence_settings(%L)', tests.w('v1'))) ->> 'ok', 'false', 'another customer''s administrator sees nothing');
select is(tests.as_user(tests.w('u_platform'), format('api.evidence_settings(%L)', tests.w('v1'))) ->> 'ok', 'false', 'nor does a platform administrator');
select is(tests.as_user(tests.w('u_op'), format('api.evidence_settings(%L)', tests.w('v1'))) ->> 'ok', 'false', 'nor does an operative');

select * from finish();
rollback;
