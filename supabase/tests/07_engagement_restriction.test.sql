-- Engagement suspension and reinstatement (Q18, invariant 7).
begin;
\ir _helpers.psql
select no_plan();

-- ---- Who may restrict --------------------------------------------------------
select tests.login(tests.w('u_h'));
select is(api.suspend_engagement(tests.key(), tests.w('e1'), tests.version('core.engagement', tests.w('e1')), 'x') ->> 'code',
  'no_covering_appointment', 'a hall-scoped appointee cannot restrict a venue-wide engagement');
select tests.login(tests.w('u_op'));
select is(api.suspend_engagement(tests.key(), tests.w('e1'), tests.version('core.engagement', tests.w('e1')), 'x') ->> 'code',
  'no_covering_appointment', 'an operative cannot restrict an engagement');
select tests.login(tests.w('u_r'));
select is(api.suspend_engagement(tests.key(), tests.w('e1'), tests.version('core.engagement', tests.w('e1')),
            'Insurance certificate lapsed') ->> 'ok',
  'true', 'a venue-wide appointee can restrict the engagement');
select throws_ok(format($$select api.suspend_engagement(%L, %L, %s, 'again')$$,
                        tests.key(), tests.w('e1'), tests.version('core.engagement', tests.w('e1'))),
  'PT409', null, 'suspending an already suspended engagement is refused, not silently re-owned');
select tests.logout();
select is((select status from core.engagement where id = tests.w('e1')), 'suspended', 'the engagement is suspended');
select is((select suspension_reason from core.engagement where id = tests.w('e1')), 'Insurance certificate lapsed',
  'the reason is recorded');

-- ---- A suspension cannot be escaped administratively --------------------------
select tests.login(tests.w('u_a1'));
select throws_ok(format($$select api.end_engagement(%L, %L, %s, 'end it')$$,
                        tests.key(), tests.w('e1'), tests.version('core.engagement', tests.w('e1'))),
  '23514', null, 'a suspended engagement cannot be ended');
select throws_ok(format($$select api.create_engagement(%L, %L, %L, 'performing_contractor', now())$$,
                        tests.key(), tests.w('v1'), tests.w('org_o')),
  '23514', null, 'a fresh engagement cannot be created while one is suspended');
select tests.logout();

-- ---- Only the owner, an equivalent, or the owner's delegate may lift it -------
select tests.login(tests.w('u_h2'));
select is(api.reinstate_engagement(tests.key(), tests.w('e1'), tests.version('core.engagement', tests.w('e1')), 'x') ->> 'code',
  'no_covering_appointment', 'a different kind of appointee cannot lift the restriction');
select tests.logout();

-- H2 also becomes a root-type holder: an equivalent appointment.
select tests.login(tests.w('u_a1'));
select tests.set_w('ap_r2', tests.must(api.record_root_appointment(tests.key(), tests.w('v1'), tests.w('p_h2'), tests.w('p_d'),
  tests.w('tv_root'), array[tests.w('pc_hw')], jsonb_build_array(jsonb_build_object('area_id', tests.w('site'))),
  now() - interval '5 minutes', null, null, null, 'Letter of appointment DH-005')));
select tests.login(tests.w('u_a2'));
select tests.must(api.confirm_root_appointment(tests.key(), tests.w('ap_r2'), tests.version('core.appointment', tests.w('ap_r2'))));
select tests.login(tests.w('u_h2'));
select tests.must(api.acknowledge_appointment(tests.key(), tests.w('ap_r2'), tests.version('core.appointment', tests.w('ap_r2'))));
select is(api.reinstate_engagement(tests.key(), tests.w('e1'), tests.version('core.engagement', tests.w('e1')),
            'Certificate renewed and checked') ->> 'ok',
  'true', 'an equivalent appointment holder can lift the restriction');
select is((select acting_appointment_id from core.decision_context
            where action_code = 'engagement.reinstate' and target_id = tests.w('e1')),
  tests.w('ap_r2'), 'the equivalent appointment, not the other one, was used');
select tests.logout();
select is((select status from core.engagement where id = tests.w('e1')), 'active', 'the engagement is active again');
select is((select suspended_by_decision_context_id from core.engagement where id = tests.w('e1')), null,
  'the restriction owner is cleared on reinstatement');

-- People connected to the restricted organisation cannot lift its restriction.
select tests.login(tests.w('u_r'));
select tests.must(api.suspend_engagement(tests.key(), tests.w('e1'), tests.version('core.engagement', tests.w('e1')), 'Second restriction'));
select tests.login(tests.w('u_a1'));
select tests.set_w('rel_h2', tests.must(api.record_person_organisation(tests.key(), tests.w('p_h2'), tests.w('org_o'), 'subcontractor', now() - interval '1 day')));
select tests.login(tests.w('u_h2'));
select tests.must(api.accept_relationship(tests.key(), tests.w('rel_h2'),
  tests.version('core.person_organisation_relationship', tests.w('rel_h2'))));
select is(api.reinstate_engagement(tests.key(), tests.w('e1'), tests.version('core.engagement', tests.w('e1')), 'x') ->> 'code',
  'separation_of_duties', 'someone working for the restricted organisation cannot lift its restriction');
select tests.login(tests.w('u_r'));
select is(api.reinstate_engagement(tests.key(), tests.w('e1'), tests.version('core.engagement', tests.w('e1')), 'Resolved') ->> 'ok',
  'true', 'the restriction''s owner can lift it');
select throws_ok(format($$select api.reinstate_engagement(%L, %L, %s, 'again')$$,
                        tests.key(), tests.w('e1'), tests.version('core.engagement', tests.w('e1'))),
  'PT409', null, 'reinstating an engagement that is not suspended is refused');

-- A delegate of the owner may lift it; a delegate of someone else may not.
select tests.must(api.suspend_engagement(tests.key(), tests.w('e1'), tests.version('core.engagement', tests.w('e1')), 'Third restriction'));
select tests.set_w('d_owner', tests.must(api.grant_delegation(tests.key(), tests.w('ap_r'), tests.w('ap_f'),
  array['engagement.reinstate'], '{}', jsonb_build_array(jsonb_build_object('system_id', tests.w('fa1'))),
  now() - interval '1 minute', now() + interval '1 day', 'Cover', 'engagement', tests.w('e1'))));
select tests.logout();
select tests.login(tests.w('u_f'));
select is(api.reinstate_engagement(tests.key(), tests.w('e1'), tests.version('core.engagement', tests.w('e1')), 'x') ->> 'code',
  'no_covering_appointment', 'a delegation scoped to a system does not reach a venue-wide restriction');
select tests.logout();

-- A deputy with their own whole-site HALL appointment.
select tests.set_w('u_deputy', tests.new_user('deputy@a.test'));
select tests.login(tests.w('u_a1'));
select tests.set_w('p_deputy', tests.must(api.create_person(tests.key(), tests.w('cust_a'), 'Dee', 'Deputy')));
select tests.must(api.link_user_account(tests.key(), tests.w('p_deputy'), tests.w('u_deputy')));
select tests.login(tests.w('u_r'));
select tests.set_w('ap_deputy', tests.must(api.grant_appointment(tests.key(), tests.w('v1'), tests.w('p_deputy'), tests.w('tv_hall'),
  array[tests.w('pc_hw')], jsonb_build_array(jsonb_build_object('area_id', tests.w('site'))),
  now() - interval '10 minutes', now() + interval '1 day', null, null, 'Assessment record AR-20')));
select tests.login(tests.w('u_deputy'));
select tests.must(api.acknowledge_appointment(tests.key(), tests.w('ap_deputy'), tests.version('core.appointment', tests.w('ap_deputy'))));

-- A delegation from someone who does not own the restriction confers nothing.
select tests.login(tests.w('u_h2'));
select tests.must(api.grant_delegation(tests.key(), tests.w('ap_h2'), tests.w('ap_deputy'),
  array['engagement.reinstate'], '{}', jsonb_build_array(jsonb_build_object('area_id', tests.w('site'))),
  now() - interval '1 minute', now() + interval '1 day', 'Cover', 'engagement', tests.w('e1')));
select tests.login(tests.w('u_deputy'));
select is(api.reinstate_engagement(tests.key(), tests.w('e1'), tests.version('core.engagement', tests.w('e1')), 'x') ->> 'code',
  'no_covering_appointment', 'a delegate of someone other than the restriction''s owner cannot lift it');

-- A delegation from the owner does.
select tests.login(tests.w('u_r'));
select tests.set_w('d_from_owner', tests.must(api.grant_delegation(tests.key(), tests.w('ap_r'), tests.w('ap_deputy'),
  array['engagement.reinstate'], '{}', jsonb_build_array(jsonb_build_object('area_id', tests.w('site'))),
  now() - interval '1 minute', now() + interval '1 day', 'Cover while on leave', 'engagement', tests.w('e1'))));
select tests.login(tests.w('u_deputy'));
select is(api.reinstate_engagement(tests.key(), tests.w('e1'), tests.version('core.engagement', tests.w('e1')),
            'Lifted under delegation') ->> 'ok',
  'true', 'the owner''s delegate can lift it');
select tests.logout();
select is((select acting_delegation_id from core.decision_context
            where action_code = 'engagement.reinstate' and target_id = tests.w('e1')
            order by evaluated_at desc limit 1),
  tests.w('d_from_owner'), 'the decision records that it was taken under the owner''s delegation');
select is((select count(*)::int from core.status_history where record_id = tests.w('e1')), 8,
  'every state of the engagement is in its history');

select * from finish();
rollback;
