-- People and authority (S1a, D-026): staff invitations link a login to a named person and grant
-- nothing; tenant administration can be ended, never by oneself; the screens' reads show each
-- role only what it may see, and offer only what the database would allow.
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
create temp table tok (name text primary key, token text) on commit drop;
grant all on tok to authenticated;

-- Staff invitations ----------------------------------------------------------------------------
select tests.login(tests.w('u_a1'));
select tests.set_w('p_sam', tests.must(api.create_person(tests.key(), tests.w('cust_a'), 'Sam', 'Steward')));
select tests.logout();

select is(tests.as_user(tests.w('u_r'), format('api.create_staff_invitation(%L, %L, %L, now() + interval ''7 days'')',
  tests.key(), tests.w('p_sam'), 'sam@a.test')) ->> 'ok', 'false', 'an appointee who is not a tenant administrator cannot invite staff');
select is(tests.as_user(tests.w('u_platform'), format('api.create_staff_invitation(%L, %L, %L, now() + interval ''7 days'')',
  tests.key(), tests.w('p_sam'), 'sam@a.test')) ->> 'ok', 'false', 'nor can a platform administrator (invariant 9)');
select is(tests.as_user(tests.w('u_b1'), format('api.create_staff_invitation(%L, %L, %L, now() + interval ''7 days'')',
  tests.key(), tests.w('p_sam'), 'sam@a.test')) ->> 'ok', 'false', 'nor another customer''s administrator');

select tests.set_w('k_sam', gen_random_uuid());
create function tests.invite(p_key text, p_person uuid, p_email text, p_expires interval default interval '7 days', p_user text default 'u_a1')
returns jsonb language sql as $$
  select tests.as_user(tests.w(p_user), format('api.create_staff_invitation(%L, %L, %L, %L)', p_key, p_person, p_email, now() + p_expires)) $$;
insert into tok select 'sam', tests.invite(tests.w('k_sam')::text, tests.w('p_sam'), ' Sam@A.test ') ->> 'token';
select ok((select token from tok where name = 'sam') is not null, 'a tenant administrator invites Sam to sign in');
select is(tests.invite(tests.w('k_sam')::text, tests.w('p_sam'), 'sam@a.test') ->> 'replayed', 'true', 'repeating the same request replays it');
select is((select count(*)::int from core.invitation where person_id = tests.w('p_sam')), 1, 'and makes one invitation');
select is((select invitee_email || '/' || kind || '/' || status from core.invitation where person_id = tests.w('p_sam')), 'sam@a.test/staff/pending',
  'for the address, normalised, as a staff invitation');
select throws_ok(format($$select tests.invite(%L, %L, 'sam2@a.test')$$, tests.key(), tests.w('p_sam')),
  'PT409', null, 'a second invitation is refused while one is pending');
select throws_ok(format($$select tests.invite(%L, %L, 'rae@elsewhere.test')$$, tests.key(), tests.w('p_r')),
  'PT409', 'this person already has a login', 'someone with a login cannot be invited');
select tests.login(tests.w('u_a1'));
select tests.set_w('p_tom', tests.must(api.create_person(tests.key(), tests.w('cust_a'), 'Tom', 'Taken')));
select tests.logout();
select throws_ok(format($$select tests.invite(%L, %L, 'root@a.test')$$, tests.key(), tests.w('p_tom')),
  'PT409', 'that email address already signs in as Rae Root here', 'an address already signing in as someone else is refused, with whom');
select throws_ok(format($$select tests.invite(%L, %L, 'tom@a.test', interval '-1 minute')$$, tests.key(), tests.w('p_tom')),
  '22023', null, 'an expiry in the past is refused');

-- The preview and the wrong account.
select tests.set_w('u_sam', tests.new_user('sam@a.test'));
select tests.set_w('u_eve', tests.new_user('eve@a.test'));
select is(tests.as_user(tests.w('u_sam'), format('api.invitation_preview(%L)', (select token from tok where name = 'sam'))) ->> 'person_name', 'Sam Steward',
  'the preview names the person the invitation is for');
select is(tests.as_user(tests.w('u_sam'), format('api.invitation_preview(%L)', (select token from tok where name = 'sam'))) ->> 'customer_name', 'Customer A',
  'and the customer');
select is(tests.as_user(tests.w('u_eve'), format('api.accept_invitation(%L, %L, %L)', tests.key(), (select token from tok where name = 'sam'), tests.w('pn'))) ->> 'code',
  'invitation_wrong_account', 'another login cannot accept it');

-- Acceptance.
select is(tests.as_user(tests.w('u_sam'), format('api.accept_invitation(%L, %L, %L)', tests.key(), (select token from tok where name = 'sam'), tests.w('pn'))) ->> 'status',
  'accepted', 'Sam accepts');
select is((select person_id from core.user_account where auth_user_id = tests.w('u_sam')), tests.w('p_sam'), 'the login is linked to the named person');
select is((select count(*)::int from core.person where given_name = 'Sam'), 1, 'no second person is created');
select is((select email from core.person_contact where person_id = tests.w('p_sam')), 'sam@a.test', 'the address becomes the contact email');
select is((select count(*)::int from core.tenant_admin where person_id = tests.w('p_sam'))
          + (select count(*)::int from core.appointment where appointee_person_id = tests.w('p_sam'))
          + (select count(*)::int from core.person_organisation_relationship where person_id = tests.w('p_sam')), 0,
  'accepting grants nothing: no administration, appointment or relationship');
select is(tests.as_user(tests.w('u_sam'), format('api.accept_invitation(%L, %L, %L)', tests.key(), (select token from tok where name = 'sam'), tests.w('pn'))) ->> 'code',
  'invitation_not_pending', 'it cannot be used twice');

-- A login already linked here cannot take a second person.
select tests.login(tests.w('u_a1'));
select tests.set_w('p_zed', tests.must(api.create_person(tests.key(), tests.w('cust_a'), 'Zed', 'Zero')));
select tests.set_w('p_yan', tests.must(api.create_person(tests.key(), tests.w('cust_a'), 'Yan', 'Young')));
select tests.logout();
insert into tok select 'zed', tests.invite(tests.key(), tests.w('p_zed'), 'zed@a.test') ->> 'token';
select tests.set_w('u_zed', tests.new_user('zed@a.test'));
select tests.login(tests.w('u_a1'));
select tests.must(api.link_user_account(tests.key(), tests.w('p_yan'), tests.w('u_zed')));
select tests.logout();
select throws_ok(format($$select tests.as_user(%L, format('api.accept_invitation(%%L, %%L, %%L)', %L, %L, %L))$$,
  tests.w('u_zed'), tests.key(), (select token from tok where name = 'zed'), tests.w('pn')),
  'PT409', 'this login is already linked to someone here, so it cannot accept this invitation', 'a login already linked to another person here is refused');

-- Cancelling.
insert into tok select 'tom', tests.invite(tests.key(), tests.w('p_tom'), 'tom@a.test') ->> 'token';
select tests.set_w('inv_tom', (select id from core.invitation where person_id = tests.w('p_tom')));
select is(tests.as_user(tests.w('u_r'), format('api.cancel_invitation(%L, %L, 1)', tests.key(), tests.w('inv_tom'))) ->> 'ok', 'false',
  'an appointee cannot cancel a staff invitation');
select is(tests.as_user(tests.w('u_a2'), format('api.cancel_invitation(%L, %L, 1)', tests.key(), tests.w('inv_tom'))) ->> 'ok', 'true',
  'a tenant administrator can');
select tests.set_w('u_tom', tests.new_user('tom@a.test'));
select is(tests.as_user(tests.w('u_tom'), format('api.accept_invitation(%L, %L, %L)', tests.key(), (select token from tok where name = 'tom'), tests.w('pn'))) ->> 'code',
  'invitation_not_pending', 'a cancelled invitation cannot be accepted');
select is((select count(*)::int from core.user_account where auth_user_id = tests.w('u_tom')), 0, 'and links nothing');

-- Tenant administrators ------------------------------------------------------------------------
select tests.set_w('ta_a2', (select id from core.tenant_admin where person_id = tests.w('p_a2')));
select tests.set_w('ta_a1', (select id from core.tenant_admin where person_id = tests.w('p_a1')));
select is(tests.as_user(tests.w('u_a1'), format('api.revoke_tenant_admin(%L, %L, 1, %L)', tests.key(), tests.w('ta_a1'), 'Leaving')) ->> 'code',
  'separation_of_duties', 'no one can end their own administration');
select is(tests.as_user(tests.w('u_r'), format('api.revoke_tenant_admin(%L, %L, 1, %L)', tests.key(), tests.w('ta_a2'), 'Leaving')) ->> 'ok', 'false',
  'an appointee cannot end anyone''s administration');
select is(tests.as_user(tests.w('u_platform'), format('api.revoke_tenant_admin(%L, %L, 1, %L)', tests.key(), tests.w('ta_a2'), 'Leaving')) ->> 'ok', 'false',
  'nor can a platform administrator');
select throws_ok(format($$select tests.as_user(%L, format('api.revoke_tenant_admin(%%L, %%L, 1, %%L)', %L, %L, ' '))$$,
  tests.w('u_a1'), tests.key(), tests.w('ta_a2')), '22023', null, 'a reason is required');
select throws_ok(format($$select tests.as_user(%L, format('api.revoke_tenant_admin(%%L, %%L, 7, %%L)', %L, %L, 'Leaving'))$$,
  tests.w('u_a1'), tests.key(), tests.w('ta_a2')), 'PT409', null, 'a stale version is refused');
select is(tests.as_user(tests.w('u_a1'), format('api.revoke_tenant_admin(%L, %L, 1, %L)', tests.key(), tests.w('ta_a2'), 'Left the company')) ->> 'ok', 'true',
  'one administrator ends another''s administration');
select ok((select revoked_at is not null from core.tenant_admin where id = tests.w('ta_a2')), 'it is ended');
select is(tests.as_user(tests.w('u_a2'), format('api.create_staff_invitation(%L, %L, %L, now() + interval ''7 days'')',
  tests.key(), tests.w('p_tom'), 'tom2@a.test')) ->> 'ok', 'false', 'and they can no longer administer');
-- The last administrator: only reachable when revocations race; simulate the other one ending first.
select tests.login(tests.w('u_a1'));
select tests.must(api.grant_tenant_admin(tests.key(), tests.w('cust_a'), tests.w('p_a2')));
select tests.logout();
select tests.set_w('ta_a2b', (select id from core.tenant_admin where person_id = tests.w('p_a2') and revoked_at is null));
create function tests.race() returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform tests.login(tests.w('u_a2'));
  -- A2 is authorised; before A2's revocation of A1 takes its lock, A1 has ended A2's own role.
  perform set_config('tests.race', 'on', true);
  r := api.revoke_tenant_admin(tests.key(), tests.w('ta_a1'), 1, 'Race');
  perform tests.logout();
  return r;
end $$;
create function tests.end_a2_first() returns trigger language plpgsql as $$
begin
  if current_setting('tests.race', true) = 'on' then
    perform set_config('tests.race', 'off', true);
    update core.tenant_admin set revoked_at = now() where id = tests.w('ta_a2b');
  end if;
  return null;
end $$;
create trigger race before insert on core.decision_context for each statement execute function tests.end_a2_first();
select throws_ok($$select tests.race()$$, 'PT409', 'this is the customer''s only tenant administrator: appoint another before ending this one',
  'the last current administrator cannot be ended, even when two revocations race');
drop trigger race on core.decision_context;
select tests.logout();
select ok((select revoked_at is null from core.tenant_admin where id = tests.w('ta_a1')), 'so A1 remains');

-- Reads ----------------------------------------------------------------------------------------
select is(tests.as_user(tests.w('u_a1'), format('api.authority_overview(%L)', tests.w('v1'))) ->> 'ok', 'true', 'a tenant administrator reads the authority overview');
select ok(jsonb_array_length(tests.as_user(tests.w('u_a1'), format('api.authority_overview(%L)', tests.w('v1'))) -> 'people') > 0, 'with the customer''s people');
select is(tests.as_user(tests.w('u_r'), format('api.authority_overview(%L)', tests.w('v1'))) -> 'people', 'null'::jsonb,
  'an appointee reads it without the people list');
select is(tests.as_user(tests.w('u_op'), format('api.authority_overview(%L)', tests.w('v1'))) ->> 'code', 'not_found', 'a contractor''s operative cannot');
select is(tests.as_user(tests.w('u_b1'), format('api.authority_overview(%L)', tests.w('v1'))) ->> 'code', 'not_found', 'nor another customer');
select is(tests.as_user(tests.w('u_platform'), format('api.authority_overview(%L)', tests.w('v1'))) ->> 'code', 'not_found', 'nor a platform administrator');

select is((select x ->> 'login' from jsonb_array_elements(tests.as_user(tests.w('u_a1'), format('api.authority_overview(%L)', tests.w('v1'))) -> 'people') x
            where x ->> 'id' = tests.w('p_sam')::text), 'active', 'Sam now has a login');
select is((select x -> 'invitation' ->> 'email' from jsonb_array_elements(tests.as_user(tests.w('u_a1'), format('api.authority_overview(%L)', tests.w('v1'))) -> 'people') x
            where x ->> 'id' = tests.w('p_zed')::text), 'zed@a.test', 'Zed''s pending invitation is shown');

-- Root appointments in the overview.
select tests.login(tests.w('u_a1'));
select tests.set_w('ap_root2', tests.must(api.record_root_appointment(tests.key(), tests.w('v1'), tests.w('p_h2'), tests.w('p_d'), tests.w('tv_root'), '{}',
  jsonb_build_array(jsonb_build_object('area_id', tests.w('hall2'))), now() - interval '1 hour', null, (now() + interval '1 year')::date, null, 'Letter DH-009')));
select tests.logout();
create function tests.appt(p_user uuid, p_id uuid) returns jsonb language sql as $$
  select x from jsonb_array_elements(tests.as_user(p_user, format('api.authority_overview(%L)', tests.w('v1'))) -> 'appointments') x where x ->> 'id' = p_id::text $$;
select is(tests.appt(tests.w('u_a1'), tests.w('ap_root2')) ->> 'state_words', 'Waiting for confirmation', 'a recorded root appointment waits for confirmation');
select is(tests.appt(tests.w('u_a1'), tests.w('ap_root2')) ->> 'can_confirm', 'false', 'the administrator who recorded it is not offered confirmation');
select is(tests.appt(tests.w('u_a2'), tests.w('ap_root2')) ->> 'can_confirm', 'true', 'the other administrator is');
select is(tests.appt(tests.w('u_a1'), tests.w('ap_root2')) -> 'scope', '["Hall 2 and everything below it"]'::jsonb, 'its scope is in words');
select is(tests.appt(tests.w('u_a1'), tests.w('ap_r')) ->> 'can_revoke_root', 'true', 'an administrator who is not the appointee is offered recording a root revocation');
select is(tests.appt(tests.w('u_r'), tests.w('ap_h')) ->> 'can_revoke', 'true', 'the root appointee is offered revoking Hal''s appointment');
select is(tests.appt(tests.w('u_h2'), tests.w('ap_h')) ->> 'can_revoke', 'false', 'Hana, whose type cannot revoke, is not');
select is(tests.appt(tests.w('u_h'), tests.w('ap_h')) ->> 'can_revoke', 'false', 'nor is Hal himself');
select is(tests.appt(tests.w('u_a1'), tests.w('ap_h')) ->> 'can_revoke', 'false', 'nor is a tenant administrator (invariant 9)');
select is(tests.appt(tests.w('u_a1'), tests.w('ap_h')) -> 'under' ->> 'appointee', 'Rae Root', 'it says under whose appointment it was made');

-- Your appointments.
select is((select x ->> 'state_words' from jsonb_array_elements(tests.as_user(tests.w('u_h2'), 'api.my_appointments()') -> 'appointments') x
            where x ->> 'id' = tests.w('ap_root2')::text), 'Waiting for confirmation', 'Hana sees the root appointment recorded for her');
select is((select count(*)::int from jsonb_array_elements(tests.as_user(tests.w('u_h'), 'api.my_appointments()') -> 'appointments') x
            where x ->> 'appointee_person_id' <> tests.w('p_h')::text), 0, 'a person sees only their own appointments');
select is((select x ->> 'can_grant' from jsonb_array_elements(tests.as_user(tests.w('u_r'), 'api.my_appointments()') -> 'appointments') x
            where x ->> 'id' = tests.w('ap_r')::text), 'true', 'Rae''s root appointment can grant');
select is((select x ->> 'can_grant' from jsonb_array_elements(tests.as_user(tests.w('u_h'), 'api.my_appointments()') -> 'appointments') x
            where x ->> 'id' = tests.w('ap_h')::text), 'false', 'Hal''s cannot');

-- Grant options.
select is(tests.as_user(tests.w('u_h'), format('api.grant_options(%L)', tests.w('ap_r'))) ->> 'code', 'not_found', 'no one can grant from someone else''s appointment');
select is(tests.as_user(tests.w('u_h2'), format('api.grant_options(%L)', tests.w('ap_root2'))) ->> 'code', 'not_found', 'nor from one not yet in force');
create function tests.opt(p_path text) returns jsonb language sql as $$
  select tests.as_user(tests.w('u_r'), format('api.grant_options(%L)', tests.w('ap_r'))) #> string_to_array(p_path, '.') $$;
select is((select array_agg(x ->> 'type' order by x ->> 'type') from jsonb_array_elements(tests.opt('types')) x),
  array['Fire Systems Authorised Person', 'Hall Authorised Person'], 'only the types Rae''s appointment may grant are offered');
select is((select x -> 'class_ids' from jsonb_array_elements(tests.opt('types')) x where x ->> 'type' = 'Hall Authorised Person'),
  jsonb_build_array(tests.w('pc_hw')), 'with the classes both the type and Rae''s appointment allow');
select ok(not exists (select 1 from jsonb_array_elements(tests.opt('people')) x where x ->> 'id' in (tests.w('p_r')::text, tests.w('p_d')::text)),
  'Rae herself, and people without a login, are not offered as appointees');
select ok(exists (select 1 from jsonb_array_elements(tests.opt('people')) x where x ->> 'id' = tests.w('p_sam')::text), 'Sam, now signed in, is');
select is((select x ->> 'with_below' from jsonb_array_elements(tests.opt('areas')) x where x ->> 'id' = tests.w('site')::text), 'true',
  'Rae may offer the whole site and everything below it');
select is((select array_agg(x ->> 'name' order by x ->> 'name') from jsonb_array_elements(
            tests.as_user(tests.w('u_h'), format('api.grant_options(%L)', tests.w('ap_h'))) -> 'areas') x), array['Hall 1', 'Stand 1'],
  'Hal''s options stop at his own scope');
select is(tests.as_user(tests.w('u_h'), format('api.grant_options(%L)', tests.w('ap_h'))) ->> 'can_grant', 'false', 'and say he cannot grant');
select is((select x -> 'scope_indexes' from jsonb_array_elements(tests.opt('delegates')) x where x ->> 'appointment_id' = tests.w('ap_h2')::text),
  '[0]'::jsonb, 'Rae can delegate to Hana only within the site scope both appointments cover');
select is((select x -> 'scope_indexes' from jsonb_array_elements(tests.opt('delegates')) x where x ->> 'appointment_id' = tests.w('ap_h')::text),
  '[]'::jsonb, 'and nothing to Hal, whose hall does not cover any whole item of Rae''s scope');
select ok(not exists (select 1 from jsonb_array_elements(tests.opt('delegable')) x where x ->> 'code' = 'appointment.grant'),
  'appointing is never offered as something to delegate');

select * from finish();
rollback;
