-- D-014: with malware scanning held off, uploads are recorded honestly as not scanned,
-- are usable at once, are never labelled clean, and the scanner path stays dormant.
begin;
\ir _helpers.psql
\ir _phase2.psql
select no_plan();

-- The fixture turned scanning on for the other tests; this file uses the production setting.
insert into core.platform_setting (key, value, decision_ref) values ('malware_scanning', 'off', 'test: production setting (D-014)');
select is(core.malware_scanning(), 'off', 'scanning is off');
select is((select value from core.platform_setting where key = 'malware_scanning' order by effective_from desc, seq desc limit 1),
  'off', 'and the setting is readable');

-- ---- Uploads ---------------------------------------------------------------------------
create temp table t_u (name text primary key, r jsonb);
grant select on t_u to authenticated;
insert into t_u values ('ins', tests.submit(tests.w('u_cara'), 'organisation', tests.w('org_c'), null, tests.w('dt_ins'),
                                            (now() + interval '1 year')::date));
select is((select r ->> 'scan_status' from t_u where name = 'ins'), 'not_scanned', 'an upload is recorded as not scanned');
select is((select scanned_at from core.document_version where id = ((select r ->> 'id' from t_u where name = 'ins'))::uuid), null,
  'with no scan date: nothing claims it was checked');

select tests.login(tests.w('u_cara'));
select is(api.document_access(((select r ->> 'id' from t_u where name = 'ins'))::uuid) ->> 'disposition', 'attachment',
  'it is released at once, as an attachment only');
select is(api.document_access(((select r ->> 'id' from t_u where name = 'ins'))::uuid) ->> 'malware_scanned', 'false',
  'and the release says it was not malware-scanned');
select tests.logout();

-- ---- Nothing for the scanner to do ------------------------------------------------------
select tests.login(tests.w('u_scanner'));
select is(api.claim_scan_job() -> 'job', 'null'::jsonb, 'the scanner is offered no work');
select tests.logout();

-- ---- Review and evidence work on not-scanned files ---------------------------------------
select is((tests.review(((select r ->> 'id' from t_u where name = 'ins'))::uuid, tests.w('rc_ins'))) ->> 'ok', 'true',
  'a not-scanned file can be reviewed');
select tests.login(tests.w('u_a1'));
select tests.set_w('er', tests.must(api.create_evidence_requirement(tests.key(), tests.w('v1'), 'PL', 'Public liability',
  'engagement_capacity', 'performing_contractor', null, 'document_type', tests.w('dt_ins'), null)));
select tests.must(api.publish_evidence_requirement_version(tests.key(), tests.w('er'), true, tests.w('p_a1'), now() - interval '1 minute', 'x'));
select tests.login(tests.w('u_r'));
select is(api.approve_engagement(tests.key(), tests.w('e_c'), tests.version('core.engagement', tests.w('e_c'))) ->> 'ok', 'true',
  'reviewed, not-scanned evidence lets the engagement be approved');
select tests.logout();

-- ---- The other controls are unchanged ------------------------------------------------------
select tests.login(tests.w('u_op'));
select is(api.document_access(((select r ->> 'id' from t_u where name = 'ins'))::uuid) ->> 'code', 'not_found',
  'visibility rules still apply');
select tests.logout();
select throws_ok($$update core.platform_setting set value = 'off'$$, '42501', null, 'the setting cannot be edited, only superseded by migration');
select is((select count(*)::int from information_schema.role_routine_grants
            where grantee = 'authenticated' and routine_schema = 'api' and (routine_name ilike '%platform_setting%' or routine_name ilike '%scanning%')), 0,
  'there is no API to change it');

-- A file recorded while scanning was off can still be scanned once, later.
select tests.login(tests.w('u_scanner'));
select is(api.record_scan_result(tests.key(), ((select r ->> 'id' from t_u where name = 'ins'))::uuid, 'clean', 'clamav 1.4') ->> 'ok',
  'true', 'when scanning is switched on later, earlier files can be scanned');
select tests.logout();

select * from finish();
rollback;
