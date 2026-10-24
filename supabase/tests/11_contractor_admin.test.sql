-- Contractor administrators (Q28, P2-3) and relationships (P2-8, Q33, Q40).
begin;
\ir _helpers.psql
\ir _phase2.psql
select no_plan();

-- ---- What a contractor administrator sees ------------------------------------
select tests.login(tests.w('u_cara'));
select is((select count(*)::int from api.person where id = tests.w('p_ian')), 1, 'sees the people who joined them');
select is((select count(*)::int from api.person_contact where person_id = tests.w('p_ian')), 1,
  'and their contact details, as their organisation');
select is((select count(*)::int from api.person where id = tests.w('p_op')), 0, 'but not another organisation''s people');
select is((select count(*)::int from api.organisation where id = tests.w('org_o')), 0, 'or another organisation');
select is((select count(*)::int from api.engagement where id = tests.w('e_c')), 1, 'sees their own engagement');
select is(tests.can('test.area_action', tests.w('hall1')) ->> 'code', 'no_covering_appointment',
  'holds no operational authority (invariant 9)');
select is(api.approve_engagement(tests.key(), tests.w('e_c'), tests.version('core.engagement', tests.w('e_c'))) ->> 'code',
  'separation_of_duties', 'cannot approve their own organisation''s engagement');
select is(api.create_person_invitation(tests.key(), tests.w('org_o'), 'employee', 'Z', 'Z', 'z@z.test', now() + interval '1 day') ->> 'code',
  'not_organisation_admin', 'cannot invite people to another organisation');
select tests.logout();

-- ---- One accountable, at most one deputy (Q28) ----------------------------------
select tests.login(tests.w('u_cara'));
select is(api.appoint_deputy_admin(tests.key(), tests.w('org_c'), tests.w('p_op')) ->> 'code',
  'person_not_in_organisation', 'a deputy must work with the organisation');
select is(api.appoint_deputy_admin(tests.key(), tests.w('org_c'), tests.w('p_ian')) ->> 'ok', 'true',
  'the accountable administrator can name a deputy');
select tests.logout();

select tests.set_w('u_jo', tests.new_user('jo@cara.test'));
select tests.login(tests.w('u_cara'));
create temp table t_jo as select api.create_person_invitation(tests.key(), tests.w('org_c'), 'agency', 'Jo', 'Agency',
                                                              'jo@cara.test', now() + interval '1 day') ->> 'token' as token;
grant select on t_jo to authenticated;
select tests.login(tests.w('u_jo'));
select tests.set_w('p_jo', (api.accept_invitation(tests.key(), (select token from t_jo), tests.w('pn')) ->> 'person_id')::uuid);
select tests.login(tests.w('u_cara'));
select throws_ok(format($$select api.appoint_deputy_admin(%L, %L, %L)$$, tests.key(), tests.w('org_c'), tests.w('p_jo')),
  '23505', null, 'there can be only one deputy');
select tests.login(tests.w('u_ian'));
select is(api.appoint_deputy_admin(tests.key(), tests.w('org_c'), tests.w('p_jo')) ->> 'code', 'not_organisation_admin',
  'a deputy cannot name deputies');
select is(api.transfer_accountable_admin(tests.key(), tests.w('org_c'), tests.w('p_ian')) ->> 'code', 'not_organisation_admin',
  'a deputy cannot take the accountable role');
select is(api.create_person_invitation(tests.key(), tests.w('org_c'), 'employee', 'Kit', 'Kit', 'kit@cara.test',
            now() + interval '1 day') ->> 'ok', 'true', 'a deputy can invite people');
select tests.login(tests.w('u_cara'));
select is(api.transfer_accountable_admin(tests.key(), tests.w('org_c'), tests.w('p_ian')) ->> 'ok', 'true',
  'the accountable administrator can hand over the role');
select is(api.appoint_deputy_admin(tests.key(), tests.w('org_c'), tests.w('p_jo')) ->> 'code', 'not_organisation_admin',
  'and then no longer administers the organisation');
select tests.logout();
select is((select person_id from core.organisation_admin
            where organisation_id = tests.w('org_c') and role = 'accountable' and revoked_at is null),
  tests.w('p_ian'), 'there is exactly one accountable administrator, the new one');

-- ---- Relationships need the person's acceptance (P2-8) --------------------------
select tests.login(tests.w('u_a1'));
select tests.set_w('rel_op_c', tests.must(api.record_person_organisation(tests.key(), tests.w('p_op'), tests.w('org_c'),
  'subcontractor', now())));
select tests.logout();
select is((select status from core.person_organisation_relationship where id = tests.w('rel_op_c')), 'invited',
  'a recorded relationship waits for the person');
select tests.login(tests.w('u_ian'));
select is((select count(*)::int from api.person_contact where person_id = tests.w('p_op')), 0,
  'and gives the organisation nothing until the person accepts');
select is(api.accept_relationship(tests.key(), tests.w('rel_op_c'), tests.version('core.person_organisation_relationship', tests.w('rel_op_c'))) ->> 'code',
  'not_subject', 'an organisation cannot accept on the person''s behalf');
select tests.login(tests.w('u_op'));
select is(api.decline_relationship(tests.key(), tests.w('rel_op_c'), tests.version('core.person_organisation_relationship', tests.w('rel_op_c'))) ->> 'ok',
  'true', 'the person can decline');
select tests.logout();

-- Facilitated acceptance for someone without a login (Q33, Q34).
select tests.login(tests.w('u_a1'));
select tests.set_w('p_nolog', tests.must(api.create_person(tests.key(), tests.w('cust_a'), 'Nell', 'Nologin')));
select tests.set_w('rel_nolog', tests.must(api.record_person_organisation(tests.key(), tests.w('p_nolog'), tests.w('org_c'),
  'employee', now())));
select throws_ok(format($$select api.confirm_relationship_facilitated(%L, %L, %s, 'ok')$$, tests.key(), tests.w('rel_nolog'),
                        tests.version('core.person_organisation_relationship', tests.w('rel_nolog'))),
  '22023', null, 'a facilitated acceptance must say how it was obtained');
select is(api.confirm_relationship_facilitated(tests.key(), tests.w('rel_nolog'),
            tests.version('core.person_organisation_relationship', tests.w('rel_nolog')),
            'Confirmed in person at the site office with a supervisor present') ->> 'ok',
  'true', 'a tenant administrator can record a facilitated acceptance');
select tests.login(tests.w('u_ian'));
select is(api.confirm_relationship_facilitated(tests.key(), tests.w('rel_nolog'), 1, 'Confirmed by our office manager') ->> 'code',
  'not_tenant_admin', 'the organisation itself cannot record one');
select tests.logout();
select is((select acceptance_method from core.person_organisation_relationship where id = tests.w('rel_nolog')),
  'facilitated', 'the method is recorded');

-- ---- People maintain their own details (Q33) ----------------------------------
select tests.login(tests.w('u_jo'));
select is(api.update_own_person(tests.key(), tests.w('p_jo'), tests.version('core.person', tests.w('p_jo')),
            'Joanna', 'Agency', 'Jo', 'en', 'jo@cara.test', '07111 111111') ->> 'ok',
  'true', 'a person can update their own details');
select is(api.update_own_person(tests.key(), tests.w('p_ian'), tests.version('core.person', tests.w('p_ian')),
            'Hacked', 'Name', null, null, null, null) ->> 'code',
  'not_subject', 'but not someone else''s');
select tests.logout();

-- ---- Changing employer (Q40) -----------------------------------------------------
select tests.login(tests.w('u_jo'));
select is(api.end_own_relationship(tests.key(), (select id from core.person_organisation_relationship
                                                   where person_id = tests.w('p_jo') and organisation_id = tests.w('org_c')),
            tests.version('core.person_organisation_relationship', (select id from core.person_organisation_relationship
                                                   where person_id = tests.w('p_jo') and organisation_id = tests.w('org_c'))),
            'Moved to another firm') ->> 'ok',
  'true', 'a person can end their own relationship');
select tests.login(tests.w('u_ian'));
select is((select count(*)::int from api.person_contact where person_id = tests.w('p_jo')), 0,
  'the former organisation loses sight of their contact details');
select tests.logout();

-- Ending the accountable administrator's relationship ends their role.
select tests.login(tests.w('u_a1'));
select tests.must(api.end_relationship_by_admin(tests.key(), tests.w('rel_ian'),
  tests.version('core.person_organisation_relationship', tests.w('rel_ian')), 'Left the organisation'));
select tests.logout();
select is((select count(*)::int from core.organisation_admin where person_id = tests.w('p_ian') and revoked_at is null), 0,
  'ending a relationship ends any administrator role it supported');

select * from finish();
rollback;
