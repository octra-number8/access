-- Malware scanner support (D-013): leased jobs, heartbeats, the rejected outcome,
-- fail-closed release, and the scanner's narrow storage access.
begin;
\ir _helpers.psql
\ir _phase2.psql
select no_plan();

create temp table t_s (name text primary key, id uuid);
grant select on t_s to authenticated;
insert into t_s values ('a', ((tests.submit(tests.w('u_cara'), 'organisation', tests.w('org_c'), null, tests.w('dt_ins'))) ->> 'id')::uuid);
insert into t_s values ('b', ((tests.submit(tests.w('u_cara'), 'organisation', tests.w('org_c'), null, tests.w('dt_ins'))) ->> 'id')::uuid);

create temp table t_path as
  select name, (select storage_path from core.document_version where id = t_s.id) as path from t_s;
grant select on t_path to authenticated;

-- ---- Only the scanner may claim work ------------------------------------------
select tests.login(tests.w('u_a1'));
select is(api.claim_scan_job() ->> 'code', 'not_service', 'a tenant administrator cannot claim scan jobs');
select tests.login(tests.w('u_notifier'));
select is(api.claim_scan_job() ->> 'code', 'not_service', 'nor can a different service account');

-- ---- Leases: one scanner per file, retried after expiry -------------------------
select tests.login(tests.w('u_scanner'));
create temp table t_job as select api.claim_scan_job(60) -> 'job' as j1;
grant select, update on t_job to authenticated;
select is((select j1 ->> 'version_id' from t_job), (select id::text from t_s where name = 'a'), 'the oldest pending file is claimed first');
select ok((select j1 ->> 'storage_path' from t_job) is not null, 'the scanner is told where the file is');
select is(api.claim_scan_job(60) -> 'job' ->> 'version_id', (select id::text from t_s where name = 'b'),
  'a leased file is not handed out again while the lease runs');
select is(api.claim_scan_job(60) -> 'job', 'null'::jsonb, 'with nothing else pending, there is no job');
select throws_ok($$select api.claim_scan_job(5)$$, '22023', null, 'leases have sensible bounds');
select tests.logout();

-- Simulate the scanner crashing: the lease expires and the file is offered again.
alter table core.scan_lease disable trigger b_guard_update;
update core.scan_lease set leased_until = now() - interval '1 second'
 where document_version_id = (select id from t_s where name = 'a');
alter table core.scan_lease enable trigger b_guard_update;
select tests.login(tests.w('u_scanner'));
select is(api.claim_scan_job(60) -> 'job' ->> 'attempts', '2', 'an expired lease is re-offered and counted');

-- ---- Storage access is limited to files still pending ------------------------
select ok(authz.scanner_may_read((select path from t_path where name = 'a')),
  'the scanner may read a file awaiting its scan');
select tests.logout();
select tests.login(tests.w('u_cara'));
select ok(not authz.scanner_may_read((select path from t_path where name = 'a')),
  'nobody else may, not even the uploader, directly from storage');
select tests.logout();
select tests.scan((select id from t_s where name = 'a'));
select tests.login(tests.w('u_scanner'));
select ok(not authz.scanner_may_read((select path from t_path where name = 'a')),
  'once scanned, the scanner can no longer read it');

-- ---- Rejected (S3) ----------------------------------------------------------------
select is(api.record_scan_result(tests.key(), (select id from t_s where name = 'b'), 'rejected', 'clamav 1.4',
            'declared application/pdf, content is not a PDF') ->> 'ok', 'true', 'a type mismatch is recorded as rejected');
select throws_ok(format($$select api.record_scan_result(%L, %L, 'unknown', 'x')$$, tests.key(), (select id from t_s where name = 'a')),
  '22023', null, 'no other outcome is accepted');
select tests.login(tests.w('u_cara'));
select is(api.document_access((select id from t_s where name = 'b')) ->> 'code', 'rejected', 'a rejected file is never released');
select ok(api.document_access((select id from t_s where name = 'b')) ->> 'reason' like '%not the type it claims%',
  'and the contractor is told it is a file problem, not a virus');
select tests.logout();

-- Evidence treats a rejected file as unusable.
select tests.login(tests.w('u_a1'));
select tests.set_w('er', tests.must(api.create_evidence_requirement(tests.key(), tests.w('v1'), 'PL', 'Public liability',
  'engagement_capacity', 'performing_contractor', null, 'document_type', tests.w('dt_ins'), null)));
select tests.must(api.publish_evidence_requirement_version(tests.key(), tests.w('er'), true, tests.w('p_a1'), now() - interval '1 minute', 'x'));
select tests.login(tests.w('u_cara'));
select is(api.engagement_evidence(tests.w('e_c')) -> 'evidence' -> 0 ->> 'state', 'not_accepted',
  'the latest submission being rejected makes the requirement unmet');
select is((api.engagement_evidence(tests.w('e_c')) -> 'evidence' -> 0 ->> 'blocking')::boolean, true, 'and blocking');
select tests.logout();

-- ---- Heartbeats -----------------------------------------------------------------------
select tests.login(tests.w('u_a1'));
select is(api.scanner_heartbeat('ClamAV 1.4', '27800', now(), 'scanning') ->> 'code', 'not_service',
  'only the scanner reports its health');
select tests.login(tests.w('u_scanner'));
select is(api.scanner_heartbeat('ClamAV 1.4.3', '27800', now() - interval '2 hours', 'scanning') ->> 'ok', 'true',
  'the scanner reports its health');
select tests.login(tests.w('u_platform'));
select is((select state from api.scanner_status), 'scanning', 'platform operations can see scanner health');
select is((select queue_depth from api.scanner_status), 0, 'including how many files are waiting');
select tests.login(tests.w('u_cara'));
select is((select count(*)::int from api.scanner_status), 0, 'customers cannot');
select tests.logout();

select * from finish();
rollback;
