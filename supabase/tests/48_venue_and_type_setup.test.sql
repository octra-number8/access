-- Venue creation and appointment types from the screens: who may create a venue, refusals in
-- words for a code already used or an unknown time zone, and a new venue starting with its root
-- area and nothing else. Creating a venue grants its creator no operational authority.
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

-- ---- Who may create a venue ----------------------------------------------------------------------
select is(tests.as_user(tests.w('u_platform'), format($$api.create_venue(%L, %L, 'NV', 'New venue', 'Europe/London')$$, tests.key(), tests.w('cust_a'))) ->> 'ok',
  'false', 'a platform administrator cannot create a customer''s venue (invariant 9)');
select is(tests.as_user(tests.w('u_b1'), format($$api.create_venue(%L, %L, 'NV', 'New venue', 'Europe/London')$$, tests.key(), tests.w('cust_a'))) ->> 'ok',
  'false', 'nor can another customer''s administrator');
select is(tests.as_user(tests.w('u_r'), format($$api.create_venue(%L, %L, 'NV', 'New venue', 'Europe/London')$$, tests.key(), tests.w('cust_a'))) ->> 'ok',
  'false', 'nor an appointee who is not a tenant administrator');
select is((select count(*)::int from core.venue where code = 'NV'), 0, 'and no venue was created');

-- ---- Creating one --------------------------------------------------------------------------------
select tests.login(tests.w('u_a1'));
select set_config('tests.nv_key', tests.key(), true);
select tests.set_w('nv', tests.must(api.create_venue(current_setting('tests.nv_key'), tests.w('cust_a'), 'NV', 'Riverside Hall', 'Europe/London')));
select is(api.create_venue(current_setting('tests.nv_key'), tests.w('cust_a'), 'NV', 'Riverside Hall', 'Europe/London') ->> 'replayed', 'true',
  'repeating the same request is a replay');
select is((select count(*)::int from core.venue where customer_id = tests.w('cust_a') and code = 'NV'), 1, 'and creates nothing more');
select throws_ok(format($$select api.create_venue(%L, %L, 'NV', 'Another', 'Europe/London')$$, tests.key(), tests.w('cust_a')),
  '22023', 'that code is already used by another of your venues', 'a venue code already used is refused in words');
select throws_ok(format($$select api.create_venue(%L, %L, 'NV2', 'Another', 'Mars/Olympus')$$, tests.key(), tests.w('cust_a')),
  '22023', 'choose a time zone from the list', 'an unknown time zone is refused in words');
select tests.logout();
select is((select string_agg(code || ':' || coalesce(parent_id::text, 'root'), ',') from core.area where venue_id = tests.w('nv')), 'SITE:root',
  'a new venue starts with its root area only');
select is((select count(*)::int from core.appointment where venue_id = tests.w('nv')), 0, 'and no appointments: its creator gains no authority there');
select is((select count(*)::int from jsonb_array_elements(tests.as_user(tests.w('u_a1'), format('api.venue_setup(%L)', tests.w('nv'))) -> 'items') i
            where i ->> 'key' = 'root_appointment' and i ->> 'state' = 'not_set_up'), 1,
  'its set-up page opens for the administrator, with the root appointment still to record');
select is(tests.as_user(tests.w('u_b1'), format('api.venue_setup(%L)', tests.w('nv'))) ->> 'ok', 'false', 'another customer''s administrator cannot see it');

-- ---- Appointment types ------------------------------------------------------------------------------
select tests.login(tests.w('u_a1'));
select tests.set_w('nt', tests.must(api.create_appointment_type(tests.key(), tests.w('nv'), 'AE', 'Authorising Engineer')));
select throws_ok(format($$select api.create_appointment_type(%L, %L, 'AE', 'Another')$$, tests.key(), tests.w('nv')),
  '22023', 'that code is already used by another appointment type at this venue', 'an appointment type code already used is refused in words');
select is(api.create_appointment_type(tests.key(), tests.w('v1'), 'AE', 'Authorising Engineer') ->> 'ok', 'true',
  'the same code can be used at another venue');
select throws_ok(format($$select api.publish_appointment_type_version(%L, %L, array['appointment.grant'], array[%L]::uuid[], '{}', '{}', true, false, %L, now(), 'First')$$,
                        tests.key(), tests.w('nt'), tests.w('pc_hw'), tests.w('p_a1')),
  '23514', 'eligible permit classes must belong to this venue', 'a type cannot be made eligible for another venue''s permit class');
select tests.logout();
select is(tests.as_user(tests.w('u_platform'), format($$api.create_appointment_type(%L, %L, 'GS', 'Gate supervisor')$$, tests.key(), tests.w('nv'))) ->> 'ok',
  'false', 'a platform administrator cannot create an appointment type');

-- ---- T-1: a root appointment must leave the venue able to approve appointment types ---------------
-- Both versions are published directly, which is allowed only until the venue has a root appointment.
select tests.login(tests.w('u_a1'));
select tests.set_w('nv_site', (select id from core.area where venue_id = tests.w('nv') and parent_id is null));
select tests.set_w('tv_noapp', tests.must(api.publish_appointment_type_version(tests.key(), tests.w('nt'), array['appointment.grant', 'appointment.revoke'],
  '{}', '{}', '{}', true, false, tests.w('p_a1'), now() - interval '1 day', 'Appoints, cannot approve types')));
select tests.set_w('nt_td', tests.must(api.create_appointment_type(tests.key(), tests.w('nv'), 'TD', 'Technical Director')));
select tests.set_w('tv_app', tests.must(api.publish_appointment_type_version(tests.key(), tests.w('nt_td'),
  array['appointment.grant', 'appointment_type.approve', 'appointment_type.reject'],
  '{}', '{}', '{}', true, false, tests.w('p_a1'), now() - interval '1 day', 'Duty holder''s technical director')));
select throws_ok(format($$select api.record_root_appointment(%L, %L, %L, %L, %L, '{}', %L::jsonb, now() - interval '1 hour', null, null, null, 'Letter DH-NV-1')$$,
                        tests.key(), tests.w('nv'), tests.w('p_r'), tests.w('p_d'), tests.w('tv_noapp'),
                        jsonb_build_array(jsonb_build_object('area_id', tests.w('nv_site')))),
  '23514', 'a root appointment''s type must allow approving appointment types, because no other root appointment in force here does; without it nobody could ever change this venue''s appointment types',
  'a root appointment whose type cannot approve appointment types is refused in words when no other root can (T-1)');
select ok((select count(*) = 0 from core.appointment where venue_id = tests.w('nv')), 'and nothing is recorded');
select tests.set_w('nv_root', tests.must(api.record_root_appointment(tests.key(), tests.w('nv'), tests.w('p_r'), tests.w('p_d'), tests.w('tv_app'), '{}',
  jsonb_build_array(jsonb_build_object('area_id', tests.w('nv_site'))), now() - interval '1 hour', null, null, null, 'Letter DH-NV-1')));
select tests.logout();
select is((select status from core.appointment where id = tests.w('nv_root')), 'pending_confirmation', 'one whose type can approve them is recorded');

-- Once that root appointment is in force, a second root appointment of the other type is accepted.
select tests.login(tests.w('u_a2'));
select tests.must(api.confirm_root_appointment(tests.key(), tests.w('nv_root'), tests.version('core.appointment', tests.w('nv_root'))));
select tests.login(tests.w('u_r'));
select tests.must(api.acknowledge_appointment(tests.key(), tests.w('nv_root'), tests.version('core.appointment', tests.w('nv_root'))));
select tests.login(tests.w('u_a1'));
select is(api.record_root_appointment(tests.key(), tests.w('nv'), tests.w('p_h'), tests.w('p_d'), tests.w('tv_noapp'), '{}',
  jsonb_build_array(jsonb_build_object('area_id', tests.w('nv_site'))), now() - interval '1 hour', null, null, null, 'Letter DH-NV-2') ->> 'ok', 'true',
  'a further root appointment of a type that cannot approve them is accepted while another root in force can');
select tests.logout();

select * from finish();
rollback;
