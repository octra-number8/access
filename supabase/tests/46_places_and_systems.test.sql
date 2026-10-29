-- Places and systems (S1b, D-026): retiring an area or a system is refused, in words, while
-- anything still depends on it (S1-8, S1-9); retiring is one way; a retired area or system cannot
-- be newly referred to; ownership records end from a date with a reason; the screen's read shows
-- each role only what it may see. Administration grants no operational authority, and retiring
-- is an administrative act that never touches issued records.
begin;
\ir _helpers.psql
\ir _phase4.psql
select tests.approve_screening();
\ir _phase5.psql
\ir _phase6.psql
\ir _phase6b.psql
select no_plan();

create function tests.as_user(p_user uuid, p_call text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform tests.login(p_user);
  execute 'select ' || p_call into r;
  perform tests.logout();
  return r;
end $$;
create function tests.retire_area(p_user text, p_area uuid, p_key text default null, p_version integer default null) returns jsonb language sql as $$
  select tests.as_user(tests.w(p_user), format('api.retire_area(%L, %L, %s)', coalesce(p_key, tests.key()), p_area,
                                                coalesce(p_version, tests.version('core.area', p_area)))) $$;
create function tests.retire_system(p_user text, p_system uuid, p_key text default null, p_version integer default null) returns jsonb language sql as $$
  select tests.as_user(tests.w(p_user), format('api.retire_system(%L, %L, %s)', coalesce(p_key, tests.key()), p_system,
                                                coalesce(p_version, tests.version('core.system', p_system)))) $$;
create function tests.problems(p jsonb) returns text language sql immutable as $$
  select coalesce((select string_agg(x, ' | ') from jsonb_array_elements_text(p -> 'problems') x), '') $$;
create temp table t_r (name text primary key, v jsonb);
grant all on t_r to authenticated;

-- A little tree of areas with nothing else depending on them.
select tests.login(tests.w('u_a1'));
select tests.set_w('ra', tests.must(api.create_area(tests.key(), tests.w('site'), tests.w('k_hall'), 'RA', 'Annexe')));
select tests.set_w('ra1', tests.must(api.create_area(tests.key(), tests.w('ra'), tests.w('k_hall'), 'RA1', 'Annexe store')));
select tests.set_w('gp_area', tests.must(api.create_area(tests.key(), tests.w('site'), tests.w('k_hall'), 'GPA', 'Loading bay')));
select tests.set_w('stop_area', tests.must(api.create_area(tests.key(), tests.w('site'), tests.w('k_hall'), 'STA', 'Mezzanine')));
select tests.set_w('free', tests.must(api.create_area(tests.key(), tests.w('site'), tests.w('k_hall'), 'FREE', 'Spare room')));
select tests.set_w('sub', tests.must(api.create_area(tests.key(), tests.w('site'), tests.w('k_hall'), 'SUB', 'Substation')));
select tests.must(api.link_system_area(tests.key(), tests.w('hv1'), tests.w('sub')));
select tests.set_w('gp', tests.must(api.create_gate_point(tests.key(), tests.w('v1'), tests.w('gp_area'), 'Loading bay gate')));
select tests.set_w('spare', tests.must(api.create_system(tests.key(), tests.w('v1'), tests.w('st_hv'), 'HV9', 'Spare transformer')));
select tests.logout();

-- ---- Who may retire --------------------------------------------------------------------------------
select is(tests.retire_area('u_platform', tests.w('ra1')) ->> 'ok', 'false', 'a platform administrator cannot retire an area (invariant 9)');
select is(tests.retire_area('u_r', tests.w('ra1')) ->> 'ok', 'false', 'nor can the root appointee, who is not a tenant administrator');
select is(tests.retire_area('u_b1', tests.w('ra1')) ->> 'ok', 'false', 'nor another customer''s administrator');
select is(tests.retire_system('u_platform', tests.w('spare')) ->> 'ok', 'false', 'a platform administrator cannot retire a system');
select is(tests.retire_system('u_b1', tests.w('spare')) ->> 'ok', 'false', 'nor another customer''s administrator');
select is((select retired_at from core.area where id = tests.w('ra1')), null, 'and nothing was retired');

-- ---- Areas below (S1-8) ------------------------------------------------------------------------------
insert into t_r select 'ra', tests.retire_area('u_a1', tests.w('ra'));
select is((select v ->> 'code' from t_r where name = 'ra'), 'in_use', 'an area with a live area below it is refused');
select is(tests.problems((select v from t_r where name = 'ra')), '1 area below it that has not been retired (Annexe store)',
  'and the refusal says what, by name');
select ok((select v ->> 'reason' from t_r where name = 'ra') like 'Something still depends on this area%'
      and (select v ->> 'resolvable_by' from t_r where name = 'ra') is not null, 'with why, and who can resolve it (CLAUDE.md §6)');
select is(tests.retire_area('u_a1', tests.w('ra1'), 'key-ra1-0001', 1) ->> 'ok', 'true', 'the area below is retired first');
select is(tests.retire_area('u_a1', tests.w('ra1'), 'key-ra1-0001', 1) ->> 'replayed', 'true', 'repeating the same request replays it');
select throws_ok(format($$select tests.retire_area('u_a1', %L)$$, tests.w('ra1')), 'PT409', null, 'a second, new request is refused');
select is(tests.retire_area('u_a1', tests.w('ra')) ->> 'ok', 'true', 'then the area above can be retired');
select throws_ok(format($$select tests.retire_area('u_a1', %L, null, 7)$$, tests.w('free')),
  'PT409', null, 'a stale version is refused');

-- ---- Gate points, stops, jobs, occupations, appointments ---------------------------------------------
select is(tests.problems(tests.retire_area('u_a1', tests.w('gp_area'))), '1 gate point in it (Loading bay gate)', 'a gate point in the area blocks retiring it');
select is(tests.as_user(tests.w('u_platform'), format('api.retire_gate_point(%L, %L, %s)', tests.key(), tests.w('gp'), tests.version('core.gate_point', tests.w('gp')))) ->> 'ok',
  'false', 'a platform administrator cannot retire a gate point');
select is(tests.as_user(tests.w('u_a1'), format('api.retire_gate_point(%L, %L, %s)', 'key-gp-00001', tests.w('gp'), 1)) ->> 'ok', 'true',
  'a tenant administrator retires the gate point');
select is(tests.as_user(tests.w('u_a1'), format('api.retire_gate_point(%L, %L, %s)', 'key-gp-00001', tests.w('gp'), 1)) ->> 'replayed', 'true', 'repeating it replays');
select throws_ok(format($$update core.gate_point set retired_at = null where id = %L$$, tests.w('gp')), '23514', null, 'a gate point cannot be un-retired');
select is(tests.retire_area('u_a1', tests.w('gp_area')) ->> 'ok', 'true', 'and then its area can be retired');

select tests.login(tests.w('u_vic'));
select tests.must(api.stop_area(tests.key(), tests.w('stop_area'), 'weather', 'High wind on the mezzanine'));
select tests.logout();
select is(tests.problems(tests.retire_area('u_a1', tests.w('stop_area'))), '1 stop on it that has not been lifted', 'so does a stop not yet lifted');

select tests.set_w('wp_live', tests.live_job('Relamp Hall 2'));
insert into t_r select 'hall2', tests.retire_area('u_a1', tests.w('hall2'));
select ok(tests.problems((select v from t_r where name = 'hall2')) like '%1 open job that names it%', 'a live job blocks retiring its area');
select ok(tests.problems((select v from t_r where name = 'hall2')) like '%1 current occupation of it%', 'and so does a current occupation');
select ok(tests.problems((select v from t_r where name = 'hall2')) not like '%isolation%', 'a system serving it with nothing open does not');
select ok(tests.problems(tests.retire_area('u_a1', tests.w('hall1'))) like '%appointment%scoped to it%', 'an appointment in force scoped to it blocks it');

-- ---- Isolations on a system serving it, and retiring that system (S1-9) ------------------------------
select tests.login(tests.w('u_op'));
insert into t_r select 'iso', api.request_isolation(tests.key(), array[tests.permit_of(tests.w('wp_live'), tests.w('pc_wah'))], tests.w('hv1'),
  'HV1 feeder 3', 'Relamping', now() - interval '1 hour', now() + interval '1 day');
select tests.logout();
select is((select v ->> 'ok' from t_r where name = 'iso'), 'true', 'an isolation is requested on HV1');
select ok(tests.problems(tests.retire_area('u_a1', tests.w('sub'))) like '1 isolation on a system serving it that has not been returned',
  'an isolation not yet returned on a system serving the area blocks retiring the area');
insert into t_r select 'hv1', tests.retire_system('u_a1', tests.w('hv1'));
select is((select v ->> 'code' from t_r where name = 'hv1'), 'in_use', 'and retiring the system');
select ok(tests.problems((select v from t_r where name = 'hv1')) like '%1 isolation on it that has not been returned%', 'in words');
select ok(tests.problems((select v from t_r where name = 'hv1')) like '%appointment%scoped to it%', 'with the appointments scoped to it');
select ok(tests.problems(tests.retire_system('u_a1', tests.w('fa1'))) like '%appointment%scoped to it%', 'an appointment scoped to FA1 blocks retiring it');

-- ---- The database refuses the same update by any path ------------------------------------------------
select throws_ok(format($$update core.area set retired_at = now() where id = %L$$, tests.w('stop_area')),
  '23514', null, 'retiring an area in use directly is refused by the database');
select throws_ok(format($$update core.system set retired_at = now() where id = %L$$, tests.w('hv1')),
  '23514', null, 'and retiring a system in use');

-- ---- A retired system ----------------------------------------------------------------------------------
select tests.login(tests.w('u_a1'));
select tests.set_w('own_spare', tests.must(api.record_system_ownership(tests.key(), tests.w('spare'), tests.w('org_o'), 'maintainer',
  now() - interval '10 days')));
select tests.logout();
select is(tests.retire_system('u_a1', tests.w('spare'), 'key-spare-01', 1) ->> 'ok', 'true', 'a system nothing depends on is retired');
select is(tests.retire_system('u_a1', tests.w('spare'), 'key-spare-01', 1) ->> 'replayed', 'true', 'repeating the same request replays it');
select ok((select retired_at from core.system where id = tests.w('spare')) is not null, 'it is recorded as retired');
select throws_ok(format($$update core.system set retired_at = null where id = %L$$, tests.w('spare')),
  '23514', null, 'retiring cannot be undone');
select throws_ok(format($$update core.area set retired_at = null where id = %L$$, tests.w('ra')),
  '23514', null, 'nor for an area');
select tests.login(tests.w('u_a1'));
select throws_ok(format($$select api.link_system_area(%L, %L, %L)$$, tests.key(), tests.w('spare'), tests.w('hall2')),
  '23514', 'that system has been retired', 'a retired system cannot be linked to an area');
select throws_ok(format($$select api.record_system_ownership(%L, %L, %L, 'owner', now())$$, tests.key(), tests.w('spare'), tests.w('org_o')),
  '23514', 'that system has been retired', 'or given a new ownership record');
select throws_ok(format($$select api.link_system_area(%L, %L, %L)$$, tests.key(), tests.w('fa1'), tests.w('ra')),
  '23514', 'that area has been retired', 'a system cannot be linked to a retired area');
select throws_ok(format($$select api.create_gate_point(%L, %L, %L, 'Annexe gate')$$, tests.key(), tests.w('v1'), tests.w('ra')),
  '23514', 'that area has been retired', 'a gate point cannot be placed in a retired area');
select tests.logout();
select tests.login(tests.w('u_r'));
select throws_ok(format($$select api.grant_appointment(%L, %L, %L, %L, %L, %L::jsonb, now(), now() + interval '1 day')$$,
  tests.key(), tests.w('v1'), tests.w('p_h'), tests.w('tv_hall'), array[tests.w('pc_hw')], jsonb_build_array(jsonb_build_object('area_id', tests.w('ra')))),
  '23514', 'that area has been retired', 'and no appointment can be scoped to it');
select tests.logout();

-- ---- Ending ownership (S1-9) ---------------------------------------------------------------------------
select tests.login(tests.w('u_a1'));
select tests.set_w('own_fa', tests.must(api.record_system_ownership(tests.key(), tests.w('fa1'), tests.w('org_o'), 'maintainer',
  now() - interval '30 days', null, tests.w('e1'), 'Maintenance contract MC-7')));
select throws_ok(format($$select api.record_system_ownership(%L, %L, %L, 'owner', now(), null, %L)$$, tests.key(), tests.w('fa1'), tests.w('org_o2'), tests.w('e1')),
  '23514', 'that engagement is not this organisation''s engagement at this venue', 'an ownership record cannot cite another organisation''s engagement');
select tests.logout();
create function tests.end_own(p_user text, p_from timestamptz, p_reason text, p_key text default null, p_version integer default null) returns jsonb language sql as $$
  select tests.as_user(tests.w(p_user), format('api.end_system_ownership(%L, %L, %s, %L, %L)', coalesce(p_key, tests.key()), tests.w('own_fa'),
                                                coalesce(p_version, tests.version('core.system_ownership', tests.w('own_fa'))), p_from, p_reason)) $$;
create temp table t_at (at timestamptz);
insert into t_at values (now() + interval '7 days');
grant all on t_at to authenticated;
select is(tests.end_own('u_platform', now(), 'Contract ended') ->> 'ok', 'false', 'a platform administrator cannot end an ownership record');
select is(tests.end_own('u_r', now(), 'Contract ended') ->> 'ok', 'false', 'nor can an appointee who is not a tenant administrator');
select is(tests.end_own('u_b1', now(), 'Contract ended') ->> 'ok', 'false', 'nor another customer''s administrator');
select throws_ok($$select tests.end_own('u_a1', now(), '  ')$$, '22023', null, 'a reason is required');
select throws_ok($$select tests.end_own('u_a1', now() - interval '40 days', 'Contract ended')$$, '22023', null, 'the end must be after the start');
select is(tests.end_own('u_a1', (select at from t_at), 'Maintenance contract MC-7 ends', 'key-own-0001', 1) ->> 'ok', 'true',
  'a tenant administrator ends it from a date');
select is(tests.end_own('u_a1', (select at from t_at), 'Maintenance contract MC-7 ends', 'key-own-0001', 1) ->> 'replayed', 'true', 'repeating it replays');
select is((select end_reason || '/' || (ended_by_person_id = tests.w('p_a1'))::text from core.system_ownership where id = tests.w('own_fa')),
  'Maintenance contract MC-7 ends/true', 'with the reason and who ended it');
select throws_ok($$select tests.end_own('u_a1', now() + interval '1 day', 'Earlier after all')$$, 'PT409', null, 'it cannot be ended twice');
select throws_ok(format($$update core.system_ownership set ends_from = now() + interval '1 day' where id = %L$$, tests.w('own_fa')),
  '23514', null, 'an ending cannot be moved, even directly');
select throws_ok(format($$update core.system_ownership set responsibility = 'owner' where id = %L$$, tests.w('own_fa')),
  '42501', null, 'and the rest of the record cannot change');

-- ---- The screen's read ----------------------------------------------------------------------------------
insert into t_r select 'po_a1', tests.as_user(tests.w('u_a1'), format('api.places_overview(%L)', tests.w('v1')));
insert into t_r select 'po_r', tests.as_user(tests.w('u_r'), format('api.places_overview(%L)', tests.w('v1')));
select is((select v ->> 'can_manage' from t_r where name = 'po_a1'), 'true', 'a tenant administrator can manage places and systems');
select is((select v ->> 'can_manage' from t_r where name = 'po_r') || '/' || coalesce((select v ->> 'organisations' from t_r where name = 'po_r'), 'none'),
  'false/none', 'an appointee sees them but is offered nothing to change, and no list of organisations');
select is(tests.as_user(tests.w('u_b1'), format('api.places_overview(%L)', tests.w('v1'))) ->> 'ok', 'false', 'another customer''s administrator sees nothing');
select is(tests.as_user(tests.w('u_platform'), format('api.places_overview(%L)', tests.w('v1'))) ->> 'ok', 'false', 'nor does a platform administrator');
select is(tests.as_user(tests.w('u_nia'), format('api.places_overview(%L)', tests.w('v1'))) ->> 'ok', 'false', 'nor does an operative');
select is((select (a ->> 'retired_at') is not null from t_r, jsonb_array_elements(v -> 'areas') a where name = 'po_a1' and a ->> 'code' = 'RA'), true,
  'retired areas are shown as retired');
select is((select a ->> 'depth' from t_r, jsonb_array_elements(v -> 'areas') a where name = 'po_a1' and a ->> 'code' = 'RA1'), '2', 'with their depth in the tree');
select is((select string_agg(a ->> 'code', ',') from t_r, jsonb_array_elements(v -> 'areas') a where name = 'po_a1' and a ->> 'code' in ('HALL1', 'STAND1', 'HALL2')),
  'HALL1,STAND1,HALL2', 'listed in tree order, each area followed by those below it');
select is((select s -> 'areas' -> 0 ->> 'name' from t_r, jsonb_array_elements(v -> 'systems') s where name = 'po_a1' and s ->> 'code' = 'HV1'), 'Substation',
  'each system lists the areas it serves');
select is((select o ->> 'valid_to' is not null and (o ->> 'current')::boolean and o ->> 'end_reason' = 'Maintenance contract MC-7 ends'
             from t_r, jsonb_array_elements(v -> 'systems') s, jsonb_array_elements(s -> 'ownership') o
            where name = 'po_a1' and s ->> 'code' = 'FA1' and o ->> 'id' = tests.w('own_fa')::text), true,
  'an ownership record ending later is still current, and shows its end and reason');
select is((select o ->> 'engagement' from t_r, jsonb_array_elements(v -> 'systems') s, jsonb_array_elements(s -> 'ownership') o
            where name = 'po_a1' and s ->> 'code' = 'FA1' and o ->> 'id' = tests.w('own_fa')::text), 'Performing contractor', 'and the engagement it relies on');

select * from finish();
rollback;
