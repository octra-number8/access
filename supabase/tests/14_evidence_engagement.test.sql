-- Evidence relevance (Q39) and engagement approval (Q31, P2-2): what this decision
-- needs, for its dates; never a blanket status.
begin;
\ir _helpers.psql
\ir _phase2.psql
select no_plan();

-- Performing contractors at V1 need reviewed public liability insurance.
select tests.login(tests.w('u_a1'));
select tests.set_w('er_ins', tests.must(api.create_evidence_requirement(tests.key(), tests.w('v1'), 'PL_INS',
  'Public liability insurance', 'engagement_capacity', 'performing_contractor', null, 'document_type', tests.w('dt_ins'), null)));
select tests.must(api.publish_evidence_requirement_version(tests.key(), tests.w('er_ins'), true, tests.w('p_a1'),
  now() - interval '1 minute', 'Required by the venue''s insurer'));
-- Exhibitors need something else, which must not appear for a contractor.
select tests.set_w('er_exh', tests.must(api.create_evidence_requirement(tests.key(), tests.w('v1'), 'EXH_INS',
  'Exhibitor insurance', 'engagement_capacity', 'exhibitor', null, 'document_type', tests.w('dt_ins'), null)));
select tests.must(api.publish_evidence_requirement_version(tests.key(), tests.w('er_exh'), true, tests.w('p_a1'),
  now() - interval '1 minute', 'Exhibitor terms'));
select throws_ok(format($$select api.create_evidence_requirement(%L, %L, 'BAD', 'Bad', 'engagement_capacity', 'promoter', null, 'document_type', %L, null)$$,
                        tests.key(), tests.w('v1'), tests.w('dt_card')),
  '23514', null, 'an engagement cannot require a person-level document');
select tests.logout();

-- ---- Missing --------------------------------------------------------------------
select tests.login(tests.w('u_cara'));
select is(jsonb_array_length(api.engagement_evidence(tests.w('e_c')) -> 'evidence'), 1,
  'only the requirement for this engagement''s capacity applies');
select is(api.engagement_evidence(tests.w('e_c')) -> 'evidence' -> 0 ->> 'state', 'missing', 'it is missing');
select is(api.engagement_evidence(tests.w('e_c')) -> 'evidence' -> 0 ->> 'resolvable_by', 'The organisation''s administrator',
  'and the contractor is told who can resolve it');
select tests.login(tests.w('u_b1'));
select is(api.engagement_evidence(tests.w('e_c')) ->> 'code', 'not_found', 'another customer cannot see it');
select tests.login(tests.w('u_r'));
create temp table t_a as select api.approve_engagement(tests.key(), tests.w('e_c'), tests.version('core.engagement', tests.w('e_c'))) as r;
grant select on t_a to authenticated;
select is((select r ->> 'code' from t_a), 'evidence_incomplete', 'approval is refused while required evidence is missing');
select tests.logout();
select is((select status from core.engagement where id = tests.w('e_c')), 'proposed', 'the engagement stays proposed');
select ok(exists (select 1 from audit.audit_event where action = 'authz.denied' and reason = 'evidence_incomplete'),
  'the refusal is audited');

-- ---- Each stage is reported for what it is -------------------------------------
create temp table t_v (name text primary key, id uuid);
grant select on t_v to authenticated;
insert into t_v values ('v1', ((tests.submit(tests.w('u_cara'), 'organisation', tests.w('org_c'), null, tests.w('dt_ins'),
                                             (now() + interval '30 days')::date)) ->> 'id')::uuid);
select tests.login(tests.w('u_cara'));
select is(api.engagement_evidence(tests.w('e_c')) -> 'evidence' -> 0 ->> 'state', 'scan_pending', 'then waiting for the scan');
select tests.logout();
select tests.scan((select id from t_v where name = 'v1'));
select tests.login(tests.w('u_cara'));
select is(api.engagement_evidence(tests.w('e_c')) -> 'evidence' -> 0 ->> 'state', 'not_reviewed', 'then waiting for review');
select tests.logout();
select tests.review((select id from t_v where name = 'v1'), tests.w('rc_ins'), 'more_information_required');
select tests.login(tests.w('u_cara'));
select is(api.engagement_evidence(tests.w('e_c')) -> 'evidence' -> 0 ->> 'state', 'more_information_required',
  'then returned for more information');
select tests.logout();

insert into t_v values ('v2', ((tests.submit(tests.w('u_cara'), 'organisation', tests.w('org_c'), null, null,
                                             (now() + interval '30 days')::date,
                                             (select document_id from core.document_version where id = (select id from t_v where name = 'v1')))) ->> 'id')::uuid);
select tests.scan((select id from t_v where name = 'v2'));
select tests.review((select id from t_v where name = 'v2'), tests.w('rc_ins'));
select tests.login(tests.w('u_cara'));
select is(api.engagement_evidence(tests.w('e_c')) -> 'evidence' -> 0 ->> 'state', 'expires_within_window',
  'a reviewed certificate that expires during the 90-day engagement is flagged');
select is((api.engagement_evidence(tests.w('e_c')) -> 'evidence' -> 0 ->> 'blocking')::boolean, false, 'but does not block');
select tests.logout();

-- ---- Approval ----------------------------------------------------------------------
select tests.login(tests.w('u_a1'));
select is(api.approve_engagement(tests.key(), tests.w('e_c'), tests.version('core.engagement', tests.w('e_c'))) ->> 'code',
  'no_covering_appointment', 'a tenant administrator cannot approve an engagement');
select tests.login(tests.w('u_r'));
select is(api.approve_engagement(tests.key(), tests.w('e_c'), tests.version('core.engagement', tests.w('e_c'))) ->> 'ok',
  'true', 'an appointed authority approves it once the evidence is in place');
select tests.logout();
select is((select status from core.engagement where id = tests.w('e_c')), 'active', 'the engagement is active');

-- ---- An unrelated expired certificate produces nothing ----------------------------
select tests.submit(tests.w('u_ian'), 'person', null, tests.w('p_ian'), tests.w('dt_card'), (now() - interval '1 year')::date);
select tests.login(tests.w('u_cara'));
select is(jsonb_array_length(api.engagement_evidence(tests.w('e_c')) -> 'evidence'), 1,
  'an expired personal card no decision needs adds no warning to the engagement');
select tests.logout();
select is((select count(*)::int from information_schema.columns
            where table_schema = 'core' and table_name in ('person', 'organisation')
              and column_name ~ '(status|rag|compliance|score)'), 0,
  'there is no person- or organisation-level status column to turn red');

-- ---- Expired before the engagement starts blocks ----------------------------------
select tests.login(tests.w('u_a1'));
select tests.set_w('e_c2', tests.must(api.create_engagement(tests.key(), tests.w('v1'), tests.w('org_c'),
  'performing_contractor', now() + interval '60 days', now() + interval '120 days')));
select tests.login(tests.w('u_r'));
select is(api.approve_engagement(tests.key(), tests.w('e_c2'), tests.version('core.engagement', tests.w('e_c2'))) -> 'evidence' -> 0 ->> 'state',
  'expired', 'insurance that will have expired before a later engagement starts blocks that engagement');
select tests.logout();

-- ---- Withdrawing a requirement takes it out of later decisions --------------------
select tests.login(tests.w('u_a1'));
select tests.must(api.publish_evidence_requirement_version(tests.key(), tests.w('er_ins'), false, tests.w('p_a1'),
  now(), 'Superseded by venue-wide cover'));
select tests.login(tests.w('u_r'));
select is(api.approve_engagement(tests.key(), tests.w('e_c2'), tests.version('core.engagement', tests.w('e_c2'))) ->> 'ok',
  'true', 'with the requirement withdrawn, the later engagement can be approved');
select tests.logout();

-- ---- Withdrawal of a proposed engagement -----------------------------------------
select tests.login(tests.w('u_a1'));
select tests.set_w('e_c3', tests.must(api.create_engagement(tests.key(), tests.w('v1'), tests.w('org_c'), 'exhibitor', now())));
select is(api.withdraw_engagement(tests.key(), tests.w('e_c3'), tests.version('core.engagement', tests.w('e_c3')),
            'Exhibitor withdrew') ->> 'ok', 'true', 'a proposed engagement that will not start can be withdrawn');
select tests.logout();

select * from finish();
rollback;
