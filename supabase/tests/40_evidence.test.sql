-- Evidence and history 8c (Q211, Q213–Q217, P8-8 to P8-12, invariants 5 and 9, CLAUDE.md §8
-- scenario 5): permit packs built only from frozen evidence by an evidence.export appointee,
-- external redaction, omissions with reasons, immutable packs with matching hashes, a builder
-- that cannot change what a pack holds, release only after authorisation, report downloads
-- recorded, history without raw values, and corrections beside frozen records.
begin;
\ir _helpers.psql
\ir _phase2.psql
\ir _phase3.psql
\ir _phase4.psql
select tests.approve_screening();
\ir _phase5.psql
\ir _phase6.psql
\ir _phase6b.psql
select no_plan();

create temp table t_r (name text primary key, v jsonb);
grant all on t_r to authenticated;
create function tests.r(p_name text) returns jsonb language sql stable as $$ select v from t_r where name = p_name $$;
create function tests.pack(p_id uuid) returns core.export language sql stable security definer as $$ select * from core.export where id = p_id $$;
grant execute on function tests.r(text), tests.pack(uuid) to authenticated;
create function tests.exports() returns setof core.export language sql stable security definer as $$ select * from core.export where venue_id = tests.w('v1') $$;
create function tests.snapshots() returns setof core.issue_snapshot language sql stable security definer as $$ select * from core.issue_snapshot $$;
create function tests.person_of(p_user uuid) returns uuid language sql stable security definer as $$
  select person_id from core.user_account where auth_user_id = p_user $$;
create function tests.ref(p_wp uuid) returns text language sql stable security definer as $$ select reference from core.work_package where id = p_wp $$;
create function tests.downloads(p_id uuid) returns integer language sql stable security definer as $$
  select count(*)::int from audit.audit_event where action = 'export.downloaded' and target_id = p_id $$;
grant execute on function tests.exports(), tests.snapshots(), tests.person_of(uuid), tests.ref(uuid), tests.downloads(uuid) to authenticated;
-- As tests.approve_permit, with documents attached to the draft.
create function tests.approve_permit(p_permit uuid, p_answers jsonb, p_documents uuid[]) returns void language plpgsql as $$
declare s record;
begin
  perform tests.login(tests.w('u_op'));
  perform tests.must(api.save_permit_draft(tests.key(), p_permit, p_answers, now() - interval '1 hour', now() + interval '1 day', p_documents));
  perform tests.must(api.set_permit_team(tests.key(), p_permit, jsonb_build_array(
    jsonb_build_object('person_id', tests.w('p_op'), 'role', 'supervisor'), jsonb_build_object('person_id', tests.w('p_owen'), 'role', 'operative'))));
  perform tests.must(api.submit_permit(tests.key(), p_permit, tests.version('core.permit', p_permit)));
  for s in select ps.id, ps.kind from core.permit_step ps join core.permit p on p.current_version_id = ps.permit_version_id
            where p.id = p_permit order by ps.group_no, ps.step_key loop
    perform tests.login(case when s.kind = 'occupier' then tests.w('u_olga') else tests.w('u_pam') end);
    perform tests.must(api.decide_step(tests.key(), s.id, 'no_further_comments', 'Reviewed', 'Reviewed for the stated work'));
  end loop;
  perform tests.logout();
end $$;
grant execute on function tests.approve_permit(uuid, jsonb, uuid[]) to authenticated;

-- ---- Set-up: authorities, documents, and a job taken through issue, work and closure ----------------
select tests.set_w('tv_ev', tests.new_type('EV', 'Evidence Officer', array['evidence.export', 'record.correct'], '{}'));
select tests.set_w('u_evan', (tests.root_ta('evan@a.test', 'Evan', tests.w('tv_ev'), array[tests.w('pc_wa'), tests.w('pc_wah'), tests.w('pc_hw')], tests.w('site')))[1]);
select tests.set_w('u_hwo', (tests.root_ta('hwo@a.test', 'Hugo', tests.w('tv_ev'), array[tests.w('pc_hw')], tests.w('site')))[1]);
select tests.set_w('tv_hb', tests.new_type('HB', 'Hand-back Acceptor', array['permit.hand_back_accept'], '{}'));
select tests.set_w('u_hana', (tests.root_ta('hana@a.test', 'Hana', tests.w('tv_hb'), array[tests.w('pc_wa'), tests.w('pc_wah'), tests.w('pc_hw')], tests.w('site')))[1]);
select tests.set_w('u_pb', tests.new_user('packs@octra.test'));
insert into core.service_account (auth_user_id, purpose) values (tests.w('u_pb'), 'pack_builder');

-- The contractor's documents: insurance (clean), a worker's card (clean), a method note (not yet scanned).
select tests.set_w('dv_ins', ((tests.submit(tests.w('u_op'), 'organisation', tests.w('org_o'), null, tests.w('dt_ins'))) ->> 'id')::uuid);
select tests.set_w('dv_card', ((tests.submit(tests.w('u_op'), 'person', tests.w('org_o'), tests.w('p_owen'), tests.w('dt_card'))) ->> 'id')::uuid);
select tests.set_w('dv_pend', ((tests.submit(tests.w('u_op'), 'organisation', tests.w('org_o'), null, tests.w('dt_ins'))) ->> 'id')::uuid);
select tests.scan(tests.w('dv_ins')); select tests.scan(tests.w('dv_card'));

select tests.set_w('wp', tests.today_job('Lamps over the aisle', array[tests.w('pc_wah')]));
select tests.set_w('wa', tests.permit_of(tests.w('wp'), tests.w('pc_wa')));
select tests.set_w('wah', tests.permit_of(tests.w('wp'), tests.w('pc_wah')));
select tests.approve_permit(tests.w('wa'), '{}');
select tests.approve_permit(tests.w('wah'), '{"access": ["mewp"]}');

-- Nothing issued yet: no frozen evidence, so no pack.
select tests.login(tests.w('u_evan'));
select is(api.request_permit_pack(tests.key(), tests.w('wa'), 'Insurer claim', 'Acme Insurance', 'external') ->> 'code', 'invalid_content',
  'a job with nothing issued cannot be packed: there is no frozen evidence yet');
select ok((api.request_permit_pack(tests.key(), tests.w('wa'), 'Insurer claim', 'Acme Insurance', 'external') ->> 'missing') like '%Nothing on this job has been issued%',
  'and says why');

select tests.issue_and_accept(tests.w('wa'));
select tests.issue_and_accept(tests.w('wah'));
select tests.login(tests.w('u_op'));
select tests.must(api.hand_back_permit(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), true, null,
  'Area swept. Site lead on 07700 900123, lead@contractor.test', true));
select tests.login(tests.w('u_hana'));
select tests.must(api.decide_hand_back(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), 'accept', 'in_person', 'Walked the aisle: clear'));
select tests.login(tests.w('u_op'));
select tests.must(api.hand_back_permit(tests.key(), tests.w('wa'), tests.version('core.permit', tests.w('wa')), true, null, 'Job complete', true));
select tests.login(tests.w('u_hana'));
select tests.must(api.decide_hand_back(tests.key(), tests.w('wa'), tests.version('core.permit', tests.w('wa')), 'accept', 'in_person', 'Job complete'));
select tests.logout();
select is(tests.status_of(tests.w('wah')) || ',' || tests.status_of(tests.w('wa')), 'closed,closed', 'both permits are closed');

-- A second job whose work-at-height permit names the documents, issued and live.
select tests.set_w('wp2', tests.today_job('Rig the truss', array[tests.w('pc_wah')]));
select tests.set_w('wa2', tests.permit_of(tests.w('wp2'), tests.w('pc_wa')));
select tests.set_w('wah2', tests.permit_of(tests.w('wp2'), tests.w('pc_wah')));
select tests.approve_permit(tests.w('wa2'), '{}');
select tests.approve_permit(tests.w('wah2'), '{"access": ["mewp"]}', array[tests.w('dv_ins'), tests.w('dv_card'), tests.w('dv_pend')]);
select is((select document_version_ids from core.permit_version where id = (select current_version_id from core.permit where id = tests.w('wah2'))),
  array[tests.w('dv_ins'), tests.w('dv_card'), tests.w('dv_pend')], 'the second job''s permit names three documents');
select tests.issue_and_accept(tests.w('wa2'));
select tests.issue_and_accept(tests.w('wah2'));

-- Defect fix: a class version's recorded hash is the SHA-256 digest of its content.
select ok((select length(content_sha256) = 32 and content_sha256 = sha256(convert_to(content::text, 'UTF8'))
             from core.permit_class_version where id = tests.w('cv_wah6')), 'a permit class version records the SHA-256 digest of its content');

-- ---- Who may make a pack (P8-8, invariant 9) -----------------------------------------------------------
select tests.login(tests.w('u_platform'));
select is(api.request_permit_pack(tests.key(), tests.w('wa'), 'Claim', 'Acme Insurance', 'external') ->> 'code', 'not_found',
  'a platform administrator cannot make a pack (invariant 9)');
select tests.login(tests.w('u_a1'));
select is(api.request_permit_pack(tests.key(), tests.w('wa'), 'Claim', 'Acme Insurance', 'external') ->> 'code', 'no_covering_appointment',
  'nor can a tenant administrator: administration grants no operational authority');
select tests.login(tests.w('u_b1'));
select is(api.request_permit_pack(tests.key(), tests.w('wa'), 'Claim', 'Acme Insurance', 'external') ->> 'code', 'not_found',
  'nor another customer''s administrator (cross-tenant)');
select tests.login(tests.w('u_op'));
select is(api.request_permit_pack(tests.key(), tests.w('wa'), 'Claim', 'Acme Insurance', 'external') ->> 'ok', 'false',
  'nor the contractor');
select tests.login(tests.w('u_hwo'));
select is(api.request_permit_pack(tests.key(), tests.w('wa'), 'Claim', 'Acme Insurance', 'external') ->> 'code', 'no_covering_appointment',
  'nor an evidence officer whose appointment does not cover the job''s Work Approval class');
select tests.logout();
select is((select count(*)::int from tests.exports()), 0, 'no refused request left a pack behind');

-- An evidence officer at the other venue (cross-venue).
select tests.login(tests.w('u_a1'));
select tests.set_w('t_ev2', tests.must(api.create_appointment_type(tests.key(), tests.w('v2'), 'EV', 'Evidence Officer')));
-- No root appointee there yet, so the tenant administrator publishes the first version (D-002 set-up).
select tests.set_w('tv_ev2', tests.must(api.publish_appointment_type_version(tests.key(), tests.w('t_ev2'), array['evidence.export'], '{}', '{}', '{}',
  true, false, tests.w('p_a1'), now() - interval '1 minute', 'Evidence Officer')));
select tests.set_w('u_vera', tests.new_user('vera@a.test'));
select tests.login(tests.w('u_a1'));
select tests.set_w('p_vera', tests.must(api.create_person(tests.key(), tests.w('cust_a'), 'Vera', 'Authority', p_email => 'vera@a.test')));
select tests.must(api.link_user_account(tests.key(), tests.w('p_vera'), tests.w('u_vera')));
select tests.set_w('ap_vera', tests.must(api.record_root_appointment(tests.key(), tests.w('v2'), tests.w('p_vera'), tests.w('p_d'), tests.w('tv_ev2'), '{}',
  jsonb_build_array(jsonb_build_object('area_id', tests.w('site2'))), now() - interval '1 minute', null, null, null, 'Letter of appointment V2')));
select tests.login(tests.w('u_a2'));
select tests.must(api.confirm_root_appointment(tests.key(), tests.w('ap_vera'), tests.version('core.appointment', tests.w('ap_vera'))));
select tests.login(tests.w('u_vera'));
select tests.must(api.acknowledge_appointment(tests.key(), tests.w('ap_vera'), tests.version('core.appointment', tests.w('ap_vera'))));
select is(api.request_permit_pack(tests.key(), tests.w('wa'), 'Claim', 'Acme Insurance', 'external') ->> 'code', 'no_covering_appointment',
  'nor an evidence officer appointed at another venue (cross-venue)');

-- ---- Content checks before anything is made ------------------------------------------------------------
select tests.login(tests.w('u_evan'));
select is(api.request_permit_pack(tests.key(), tests.w('wa'), ' ', 'Acme Insurance', 'external') ->> 'code', 'invalid_content', 'a purpose is required');
select is(api.request_permit_pack(tests.key(), tests.w('wa'), 'Claim', '', 'external') ->> 'code', 'invalid_content', 'a recipient is required');
select is(api.request_permit_pack(tests.key(), tests.w('wa'), 'Claim', 'Acme Insurance', 'public') ->> 'code', 'invalid_content', 'the profile is external or internal');
select is(api.request_permit_pack(tests.key(), tests.w('wa'), 'Claim', 'Acme Insurance', 'external',
  jsonb_build_array(jsonb_build_object('item', 'answers:' || tests.w('wa'), 'reason', '  '))) ->> 'code', 'invalid_content',
  'an omission without a reason is refused (P8-9)');
select is(api.request_permit_pack(tests.key(), tests.w('wa'), 'Claim', 'Acme Insurance', 'external',
  jsonb_build_array(jsonb_build_object('item', 'answers:' || gen_random_uuid(), 'reason', 'Not relevant'))) ->> 'code', 'invalid_content',
  'and so is leaving out something the pack does not have');

-- ---- An external pack (Q213, Q214) ---------------------------------------------------------------------
insert into t_r select 'ext', api.request_permit_pack('pack-ext-0001', tests.w('wa'), 'Public liability claim, aisle incident', 'Acme Insurance', 'external',
  jsonb_build_array(jsonb_build_object('item', 'answers:' || tests.w('wa'), 'reason', 'Not relevant to the claim')));
select is(tests.r('ext') ->> 'ok', 'true', 'an evidence officer covering the job makes an external pack');
select tests.set_w('x_ext', (tests.r('ext') ->> 'id')::uuid);
select is((tests.pack(tests.w('x_ext'))).reference, 'PK-' || tests.ref(tests.w('wp')) || '-01', 'with a reference from the job');
select is((tests.pack(tests.w('x_ext'))).build_state, 'queued', 'queued for the builder');
select is((tests.pack(tests.w('x_ext'))).content_sha256, sha256(convert_to((tests.pack(tests.w('x_ext'))).content::text, 'UTF8')),
  'its content hash matches its content');
select is((select made_by_person_id from tests.exports() where id = tests.w('x_ext')), tests.person_of(tests.w('u_evan')),
  'and records who made it');
select is((select jsonb_array_length(content -> 'permits') from tests.exports() where id = tests.w('x_ext')), 2, 'both permits are in it');
select ok((select bool_and((p ->> 'closed')::boolean and p -> 'close_out' <> 'null' and jsonb_array_length(p -> 'issue_snapshots') = 1)
             from tests.exports(), jsonb_array_elements(content -> 'permits') p where id = tests.w('x_ext')),
  'each closed, with its issue snapshot and its close-out snapshot (Q119, Q211)');
select is((select string_agg(distinct s ->> 'sha256', ',') from tests.exports(), jsonb_array_elements(content -> 'permits') p,
                  jsonb_array_elements(p -> 'issue_snapshots') s where id = tests.w('x_ext') and (p ->> 'id')::uuid = tests.w('wah')),
  (select encode(content_sha256, 'hex') from tests.snapshots() where permit_id = tests.w('wah')), 'each snapshot with its own recorded hash');
select is((select p #>> '{issue_snapshots,0,content,version,answers}' from tests.exports(), jsonb_array_elements(content -> 'permits') p
            where id = tests.w('x_ext') and (p ->> 'id')::uuid = tests.w('wa')), '[Omitted by the exporter: Not relevant to the claim]',
  'the omitted answers are replaced by the reason');
select is((select content -> 'omissions' -> 0 ->> 'what' from tests.exports() where id = tests.w('x_ext')), 'Answers to the Work Approval questions',
  'and the omission is listed by what it is');
select ok((select content::text not like '%07700 900123%' and content::text not like '%lead@contractor.test%' from tests.exports() where id = tests.w('x_ext')),
  'an external pack holds no telephone number or email address, even from free text (Q214)');
select ok((select (content #>> '{redactions,phone_numbers}')::int >= 1 and (content #>> '{redactions,email_addresses}')::int >= 1
             from tests.exports() where id = tests.w('x_ext')), 'and says how many were removed');
select ok((select content::text like '%Area swept. Site lead on [phone number removed], [email address removed]%' from tests.exports() where id = tests.w('x_ext')),
  'the rest of the text is kept');
select ok((select content -> 'contacts' = 'null' from tests.exports() where id = tests.w('x_ext')), 'no contact details section');
select ok((select (content -> 'names' -> 'people') ? tests.person_of(tests.w('u_ivy'))::text
             from tests.exports() where id = tests.w('x_ext')), 'the issuer is named: who decided is never removed (P8-9)');
select ok((select exists (select 1 from jsonb_array_elements(content -> 'chronology') c
                          where c ->> 'action' = 'permit.issue' and c ->> 'capacity' = 'Permit Issuer' and c ->> 'who' like 'Ivy %'
                            and c ->> 'seq' is not null and c ->> 'hash' ~ '^[0-9a-f]{64}$')
             from tests.exports() where id = tests.w('x_ext')),
  'the chronology names each decision''s maker, the appointment it was made under, and its place in the audit chain');
select ok((select exists (select 1 from jsonb_array_elements(content -> 'chronology') c
                          where c ->> 'action' = 'permit.hand_back_accept' and c ->> 'reason' = 'Walked the aisle: clear')
             from tests.exports() where id = tests.w('x_ext')), 'with the reasons given');
select is((select jsonb_array_length(content #> '{verification,problems}') from tests.exports() where id = tests.w('x_ext')), 0,
  'and the audit chain verified, with no problems');
select ok(not ((select content::text from tests.exports() where id = tests.w('x_ext')) ~* '"(evaluation|change|request_hash)"'),
  'raw audit values are not in it');

-- Evidence files: the second job names an organisation document, a person's card and an unscanned file.
insert into t_r select 'ext2', api.request_permit_pack(tests.key(), tests.w('wa2'), 'Claim', 'Acme Insurance', 'external');
select tests.set_w('x_ext2', (tests.r('ext2') ->> 'id')::uuid);
select is((select f ->> 'included' from tests.exports(), jsonb_array_elements(content -> 'files') f where id = tests.w('x_ext2') and (f ->> 'version_id')::uuid = tests.w('dv_ins')),
  'true', 'the organisation''s insurance document goes in');
select ok((select f ->> 'included' = 'false' and f ->> 'omitted_reason' like 'A person''s own document%'
             from tests.exports(), jsonb_array_elements(content -> 'files') f where id = tests.w('x_ext2') and (f ->> 'version_id')::uuid = tests.w('dv_card')),
  'a worker''s own card is left out of an external pack, with the reason');
select ok((select f ->> 'included' = 'false' and f ->> 'omitted_reason' = 'Not released: still waiting for the malware check'
             from tests.exports(), jsonb_array_elements(content -> 'files') f where id = tests.w('x_ext2') and (f ->> 'version_id')::uuid = tests.w('dv_pend')),
  'a file that has not passed the malware check is never included');
select ok((select (content #>> '{job,reference}') is not null and (select bool_and(p ->> 'closed' = 'false') from jsonb_array_elements(content -> 'permits') p)
             from tests.exports() where id = tests.w('x_ext2')), 'a live job''s pack says its permits are not closed');

-- ---- An internal pack keeps the job's contact details ---------------------------------------------------
insert into t_r select 'int', api.request_permit_pack(tests.key(), tests.w('wa2'), 'Venue investigation', 'Venue safety team', 'internal',
  jsonb_build_array(jsonb_build_object('item', 'file:' || tests.w('dv_ins'), 'reason', 'Held by the insurer already')));
select tests.set_w('x_int', (tests.r('int') ->> 'id')::uuid);
select is((tests.pack(tests.w('x_int'))).reference, 'PK-' || tests.ref(tests.w('wp2')) || '-02', 'numbered within its job');
select ok((select exists (select 1 from jsonb_array_elements(content #> '{contacts,people}') c where c ->> 'role' = 'Job contact' and c ->> 'email' like '%@%')
             from tests.exports() where id = tests.w('x_int')), 'an internal pack keeps the job contact''s email address');
select is((select f ->> 'included' from tests.exports(), jsonb_array_elements(content -> 'files') f where id = tests.w('x_int') and (f ->> 'version_id')::uuid = tests.w('dv_card')),
  'true', 'and the worker''s card');
select is((select f ->> 'omitted_reason' from tests.exports(), jsonb_array_elements(content -> 'files') f where id = tests.w('x_int') and (f ->> 'version_id')::uuid = tests.w('dv_ins')),
  'Held by the insurer already', 'and leaves out what the exporter chose, with their reason');

-- ---- Idempotency ----------------------------------------------------------------------------------------
select is(api.request_permit_pack('pack-ext-0001', tests.w('wa'), 'Public liability claim, aisle incident', 'Acme Insurance', 'external',
  jsonb_build_array(jsonb_build_object('item', 'answers:' || tests.w('wa'), 'reason', 'Not relevant to the claim'))) ->> 'id',
  tests.w('x_ext')::text, 'repeating the request returns the same pack');
select is(api.request_permit_pack('pack-ext-0001', tests.w('wa'), 'Something else', 'Acme Insurance', 'external') ->> 'code', 'idempotency_key_reused',
  'the same key for a different request is refused');
select is((select count(*)::int from tests.exports() where work_package_id = tests.w('wp')), 1, 'and neither made another pack');

-- ---- Immutability (invariant 5) -------------------------------------------------------------------------
select tests.logout();
select throws_ok(format($$update core.export set purpose = 'Changed' where id = %L$$, tests.w('x_ext')), '42501', null,
  'a pack''s purpose cannot be changed');
select throws_ok(format($$update core.export set content = '{}' where id = %L$$, tests.w('x_ext')), '42501', null, 'nor its content');
select throws_ok(format($$delete from core.export where id = %L$$, tests.w('x_ext')), '42501', null, 'nor can a pack be deleted');

-- ---- Release before it is built --------------------------------------------------------------------------
select tests.login(tests.w('u_evan'));
select is(api.pack_access(tests.w('x_ext')) ->> 'code', 'not_ready', 'a pack still being built is not released');
select tests.login(tests.w('u_a1'));
select is(api.pack_access(tests.w('x_ext')) ->> 'code', 'not_found', 'a tenant administrator is never given a pack');

-- ---- The builder ------------------------------------------------------------------------------------------
select tests.login(tests.w('u_op'));
select is(api.claim_pack_builds() ->> 'allowed', 'false', 'only the pack builder service can claim packs to build');
select is(api.record_pack_build(tests.w('x_ext'), true, '[]', repeat('a', 64), 10, 'x') ->> 'allowed', 'false', 'or record one');
select tests.login(tests.w('u_pb'));
insert into t_r select 'claim', api.claim_pack_builds(10, 300);
select is(jsonb_array_length(tests.r('claim') -> 'packs'), 3, 'the builder claims the three queued packs');
select is(jsonb_array_length(api.claim_pack_builds(10, 300) -> 'packs'), 0, 'a claimed pack is not claimed twice while its lease runs');
select ok((select bool_and(sha256(convert_to(p ->> 'content_text', 'UTF8')) = (tests.pack((p ->> 'id')::uuid)).content_sha256)
             from jsonb_array_elements(tests.r('claim') -> 'packs') p), 'it is given each pack''s content exactly as hashed');
select is((select string_agg(f ->> 'version_id', ',') from jsonb_array_elements(tests.r('claim') -> 'packs') p, jsonb_array_elements(p -> 'files') f
            where (p ->> 'id')::uuid = tests.w('x_ext2')), tests.w('dv_ins')::text, 'and only the files the pack includes');
select is(api.record_pack_build(tests.w('x_ext'), true, jsonb_build_array(jsonb_build_object('name', 'pack.json', 'sha256', repeat('0', 64), 'bytes', 10)),
  repeat('a', 64), 1000, (select customer_id::text from tests.exports() where id = tests.w('x_ext')) || '/' || tests.w('x_ext') || '.zip') ->> 'code',
  'files_do_not_match', 'a pack whose content file is not the recorded content is refused');
select is(api.record_pack_build(tests.w('x_ext2'), true, jsonb_build_array(
    jsonb_build_object('name', 'pack.json', 'sha256', encode((tests.pack(tests.w('x_ext2'))).content_sha256, 'hex'), 'bytes', 10)),
  repeat('a', 64), 1000, (select customer_id::text from tests.exports() where id = tests.w('x_ext2')) || '/' || tests.w('x_ext2') || '.zip') ->> 'code',
  'files_do_not_match', 'and so is one missing an evidence file it names');
select is(api.record_pack_build(tests.w('x_ext'), true, jsonb_build_array(
    jsonb_build_object('name', 'pack.json', 'sha256', encode((tests.pack(tests.w('x_ext'))).content_sha256, 'hex'), 'bytes', 10),
    jsonb_build_object('name', 'pack.pdf', 'sha256', repeat('b', 64), 'bytes', 900)),
  repeat('c', 64), 1200, (select customer_id::text from tests.exports() where id = tests.w('x_ext')) || '/' || tests.w('x_ext') || '.zip') ->> 'build_state',
  'ready', 'a pack holding exactly its content is recorded as ready');
select is(encode((tests.pack(tests.w('x_ext'))).pack_sha256, 'hex'), repeat('c', 64), 'with the hash of the whole pack');
select is(api.record_pack_build(tests.w('x_ext'), true, '[]', repeat('d', 64), 1, 'x') ->> 'code', 'not_queued', 'and is never rebuilt');
select tests.logout();
select throws_ok(format($$update core.export set pack_sha256 = decode(repeat('e', 64), 'hex') where id = %L$$, tests.w('x_ext')), '42501',
  'a finished pack never changes: make a new one', 'nor changed afterwards, even its build record');

-- A pack the builder cannot finish fails after three attempts and is never released.
select tests.login(tests.w('u_pb'));
select is(api.record_pack_build(tests.w('x_int'), false, null, null, null, null, 'storage unavailable') ->> 'build_state', 'queued', 'a failed build is retried');
select ok(jsonb_array_length(api.claim_pack_builds(10, 300) -> 'packs') >= 1, 'it can be claimed again');
select is(api.record_pack_build(tests.w('x_int'), false, null, null, null, null, 'storage unavailable') ->> 'build_state', 'queued', 'twice');
select ok(jsonb_array_length(api.claim_pack_builds(10, 300) -> 'packs') >= 1, 'and a third time');
select is(api.record_pack_build(tests.w('x_int'), false, null, null, null, null, 'storage unavailable') ->> 'build_state', 'failed', 'then it has failed');
select tests.login(tests.w('u_evan'));
select is(api.pack_access(tests.w('x_int')) ->> 'code', 'not_ready', 'a failed pack is not released');

-- ---- Release (CLAUDE.md §5) ------------------------------------------------------------------------------
insert into t_r select 'acc', api.pack_access(tests.w('x_ext'));
select is(tests.r('acc') ->> 'storage_path', (select customer_id::text from tests.exports() where id = tests.w('x_ext')) || '/' || tests.w('x_ext') || '.zip',
  'an evidence officer covering the job is given the pack''s place in private storage');
select is(tests.r('acc') ->> 'file_name', (tests.pack(tests.w('x_ext'))).reference || '.zip', 'to download as its reference');
select is(tests.downloads(tests.w('x_ext')), 1, 'and the release is audited');
select tests.login(tests.w('u_hwo'));
select is(api.pack_access(tests.w('x_ext')) ->> 'code', 'not_found', 'one whose appointment does not cover the job is not');
select tests.login(tests.w('u_vera'));
select is(api.pack_access(tests.w('x_ext')) ->> 'code', 'not_found', 'nor is one at another venue');

-- ---- The permit page's evidence section ------------------------------------------------------------------
select tests.login(tests.w('u_evan'));
insert into t_r select 'ev_evan', api.permit_evidence(tests.w('wa'));
select ok((tests.r('ev_evan') ->> 'can_export')::boolean and jsonb_array_length(tests.r('ev_evan') -> 'packs') = 1,
  'an evidence officer sees the packs made and can make one');
select ok(tests.r('ev_evan') -> 'packs' -> 0 ->> 'pack_sha256' = repeat('c', 64) and tests.r('ev_evan') -> 'packs' -> 0 ->> 'recipient' = 'Acme Insurance',
  'each with its recipient and hashes');
select tests.login(tests.w('u_a1'));
insert into t_r select 'ev_a1', api.permit_evidence(tests.w('wa'));
select ok(not (tests.r('ev_a1') ->> 'can_export')::boolean and jsonb_array_length(tests.r('ev_a1') -> 'packs') = 1,
  'a tenant administrator sees which packs were made, but cannot make one');
select tests.login(tests.w('u_op'));
insert into t_r select 'ev_op', api.permit_evidence(tests.w('wa'));
select ok(not (tests.r('ev_op') ->> 'can_export')::boolean and tests.r('ev_op') -> 'packs' = '[]' and tests.r('ev_op') -> 'export_options' = 'null',
  'the contractor does not see packs, their recipients or purposes');
select tests.login(tests.w('u_b1'));
select is(api.permit_evidence(tests.w('wa')) ->> 'code', 'not_visible', 'another customer sees nothing');

-- ---- Report downloads are recorded (§6) ------------------------------------------------------------------
select tests.login(tests.w('u_a1'));
insert into t_r select 'rep', api.report_export('hand_backs', tests.w('v1'), current_date - 1, current_date + 1);
select is(tests.r('rep') ->> 'ok', 'true', 'a report download returns the report');
select ok((select kind = 'report_csv' and scope ->> 'report' = 'hand_backs' and made_by_person_id = tests.w('p_a1') and content is null
             from tests.exports() where id = (tests.r('rep') ->> 'export_id')::uuid), 'and is recorded as an export: which report, by whom, no content');
select tests.login(tests.w('u_b1'));
select is(api.report_export('hand_backs', tests.w('v1'), current_date - 1, current_date + 1) ->> 'ok', 'false', 'a refused report records nothing');
select is((select count(*)::int from tests.exports() where kind = 'report_csv'), 1, 'only the one download is recorded');

-- ---- Corrections (Q216, P8-12) ------------------------------------------------------------------------------
select tests.set_w('snap_wah', (select id from tests.snapshots() where permit_id = tests.w('wah')));
select tests.login(tests.w('u_a1'));
select is(api.record_correction(tests.key(), 'issue_snapshot', tests.w('snap_wah'), 'MEWP', 'MEWP', 'Scissor lift', 'x', 'y') ->> 'code',
  'no_covering_appointment', 'a tenant administrator cannot record a correction');
select tests.login(tests.w('u_op'));
select is(api.record_correction(tests.key(), 'issue_snapshot', tests.w('snap_wah'), 'MEWP', 'MEWP', 'Scissor lift', 'x', 'y') ->> 'code',
  'separation_of_duties', 'nor anyone connected with the job');
-- Ivy issued it; she is given evidence authority too, and still cannot correct her own record.
select tests.login(tests.w('u_a1'));
select tests.set_w('ap_ivy_ev', tests.must(api.record_root_appointment(tests.key(), tests.w('v1'), tests.person_of(tests.w('u_ivy')),
  tests.w('p_d'), tests.w('tv_ev'), array[tests.w('pc_wa'), tests.w('pc_wah')], jsonb_build_array(jsonb_build_object('area_id', tests.w('site'))),
  now() - interval '1 minute', null, null, null, 'Letter of appointment IVY-EV')));
select tests.login(tests.w('u_a2'));
select tests.must(api.confirm_root_appointment(tests.key(), tests.w('ap_ivy_ev'), tests.version('core.appointment', tests.w('ap_ivy_ev'))));
select tests.login(tests.w('u_ivy'));
select tests.must(api.acknowledge_appointment(tests.key(), tests.w('ap_ivy_ev'), tests.version('core.appointment', tests.w('ap_ivy_ev'))));
select is(api.record_correction(tests.key(), 'issue_snapshot', tests.w('snap_wah'), 'MEWP', 'MEWP', 'Scissor lift', 'x', 'y',
  p_acting_appointment_id => tests.w('ap_ivy_ev')) ->> 'code', 'separation_of_duties', 'the person who made the record cannot correct it alone (Q216)');
select tests.login(tests.w('u_evan'));
select is(api.record_correction(tests.key(), 'issue_snapshot', gen_random_uuid(), 'MEWP', 'MEWP', 'Scissor lift', 'x', 'y') ->> 'code', 'not_found',
  'an unknown record cannot be corrected');
select is(api.record_correction(tests.key(), 'issue_snapshot', tests.w('snap_wah'), 'Access equipment', 'MEWP', 'MEWP', 'Wrong', 'Delivery note') ->> 'code',
  'invalid_content', 'a correction must change something');
select is(api.record_correction(tests.key(), 'issue_snapshot', tests.w('snap_wah'), 'Access equipment', 'MEWP', 'Scissor lift', 'Wrong', ' ') ->> 'code',
  'invalid_content', 'and say what shows the correct value');
insert into t_r select 'snap_before', (select content from tests.snapshots() where id = tests.w('snap_wah'));
insert into t_r select 'corr', api.record_correction(tests.key(), 'issue_snapshot', tests.w('snap_wah'), 'Access equipment', 'MEWP',
  'Scissor lift (MEWP type 3a)', 'The supervisor recorded the wrong equipment type', 'Hire delivery note HD-4471');
select is(tests.r('corr') ->> 'ok', 'true', 'an evidence officer not connected with the job records the correction');
select is((select content from tests.snapshots() where id = tests.w('snap_wah')), tests.r('snap_before'), 'the issued record itself is unchanged (invariant 5)');
select is((select content_sha256 = sha256(convert_to(content::text, 'UTF8')) from tests.snapshots() where id = tests.w('snap_wah')), true,
  'and still matches its hash');
select tests.logout();
select throws_ok(format($$update core.correction set corrected = 'x' where id = %L$$, tests.r('corr') ->> 'id'), '42501', null, 'a correction is never changed');
select tests.login(tests.w('u_op'));
insert into t_r select 'ev_op2', api.permit_evidence(tests.w('wah'));
select ok((select c ->> 'label' = 'The permit as issued' and c ->> 'corrected' = 'Scissor lift (MEWP type 3a)' and c ->> 'by' like 'Evan %'
             from jsonb_array_elements(tests.r('ev_op2') -> 'corrections') c), 'the correction is shown beside the record, to anyone who can see it');
select is(tests.r('ev_op2') -> 'correctable', '[]', 'but only correction appointees are offered records to correct');
select tests.login(tests.w('u_evan'));
insert into t_r select 'ext3', api.request_permit_pack(tests.key(), tests.w('wah'), 'Claim, after correction', 'Acme Insurance', 'external');
select is((select c ->> 'corrected' from tests.exports(), jsonb_array_elements(content -> 'corrections') c where id = (tests.r('ext3') ->> 'id')::uuid),
  'Scissor lift (MEWP type 3a)', 'a later pack carries the correction');
select is((select (content -> 'corrections') from tests.exports() where id = tests.w('x_ext')), '[]', 'an earlier pack stays as it was handed over');

-- ---- History (Q217, P8-11) -------------------------------------------------------------------------------
select tests.login(tests.w('u_op'));
insert into t_r select 'h_wah', api.record_history('permit', tests.w('wah'));
select is(tests.r('h_wah') ->> 'ok', 'true', 'the contractor sees the history of its own permit');
select ok((select bool_or(e ->> 'action' = 'permit.issue' and e ->> 'who' like 'Ivy %' and e ->> 'capacity' = 'Permit Issuer'
                         and e -> 'changes' @> '[{"to": "issued_awaiting_acceptance"}]')
             from jsonb_array_elements(tests.r('h_wah') -> 'entries') e), 'with who decided, in which capacity, and the change of recorded state');
select ok((select bool_or(e ->> 'action' = 'record.correct') from jsonb_array_elements(tests.r('h_wah') -> 'entries') e), 'including the correction');
select ok((select bool_and(e ->> 'capacity' !~ '_' and e ->> 'capacity' is not null) from jsonb_array_elements(tests.r('h_wah') -> 'entries') e),
  'every capacity is worded, never a code');
select ok((select bool_or(e ->> 'action' = 'permit.hand_back_submit' and e ->> 'capacity' = 'someone named on the permit')
             from jsonb_array_elements(tests.r('h_wah') -> 'entries') e), 'a supervisor''s hand-back is in their capacity on the permit');
select ok((select bool_or(e ->> 'action' = 'permit.hand_back_accept' and e ->> 'reason' = 'Walked the aisle: clear')
             from jsonb_array_elements(tests.r('h_wah') -> 'entries') e), 'and the reasons given');
select ok(not (tests.r('h_wah')::text ~* '"(evaluation|change|old|new|request_hash)"'), 'never raw values');
select is((select count(*)::int from jsonb_array_elements(tests.r('h_wah') -> 'entries') e where e ->> 'action' = 'permit.issue'), 1,
  'a permit''s history holds its own decisions, not its job''s other permits');
insert into t_r select 'h_job', api.record_history('job', tests.w('wp'));
select is((select count(*)::int from jsonb_array_elements(tests.r('h_job') -> 'entries') e where e ->> 'action' = 'permit.issue'), 2,
  'a job''s history holds every permit''s decisions');
select ok((select bool_or(e ->> 'action' = 'evidence.export') from jsonb_array_elements(tests.r('h_job') -> 'entries') e),
  'and the packs made of it');
select tests.login(tests.w('u_b1'));
select is(api.record_history('permit', tests.w('wah')) ->> 'code', 'not_visible', 'another customer sees no history');
select tests.login(tests.w('u_platform'));
select is(api.record_history('job', tests.w('wp')) ->> 'code', 'not_visible', 'nor does a platform administrator');
select is(api.record_history('somewhere', tests.w('wp')) ->> 'code', 'not_visible', 'an unknown kind of record has no history');

-- A restriction's grounds are shown to the venue's side only (Q214, P5-6).
select tests.login(tests.w('u_op'));
select tests.must(api.appoint_deputy_admin(tests.key(), tests.w('org_o'), tests.w('p_nia')));
select tests.login(tests.w('u_r'));
select tests.must(api.impose_restriction(tests.key(), tests.w('v1'), 'person', tests.w('p_owen'), 'Grounds: a confidential site rules matter'));
select tests.login(tests.w('u_nia'));
insert into t_r select 'h_owen_nia', api.record_history('person', tests.w('p_owen'));
select ok((select bool_or(e ->> 'action' = 'person.restrict' and e -> 'reason' = 'null' and (e ->> 'grounds_withheld')::boolean)
             from jsonb_array_elements(tests.r('h_owen_nia') -> 'entries') e), 'the worker''s organisation sees that a restriction was recorded');
select ok(tests.r('h_owen_nia')::text not like '%confidential site rules%', 'but never its grounds');
select tests.login(tests.w('u_a1'));
insert into t_r select 'h_owen_a1', api.record_history('person', tests.w('p_owen'));
select ok((select bool_or(e ->> 'action' = 'person.restrict' and e ->> 'reason' = 'Grounds: a confidential site rules matter')
             from jsonb_array_elements(tests.r('h_owen_a1') -> 'entries') e), 'the venue''s side sees the grounds');
select ok((select bool_or(e ->> 'action' = 'organisation_admin.appoint_deputy' or e ->> 'action' like 'organisation%')
             from jsonb_array_elements(api.record_history('organisation', tests.w('org_o')) -> 'entries') e), 'an organisation has a history');
select tests.logout();

-- Fields named as contact or personal details are removed wherever they appear, at any depth, and
-- names are kept (no frozen record holds such a field today: this guards what later ones add).
select is(core.pack_scrub('{"name": "Ann Example", "phone": "0123", "detail": {"emergency_contacts": [{"x": 1}], "home_address": "1 Lane", "role": "supervisor"}}'),
  '{"name": "Ann Example", "phone": "[Removed: contact or personal detail]", "detail": {"emergency_contacts": "[Removed: contact or personal detail]", "home_address": "[Removed: contact or personal detail]", "role": "supervisor"}}'::jsonb,
  'contact and personal fields are removed by name at any depth, and names are kept');

-- A file uploaded while malware scanning is off is released as documents are (D-014), and says so.
update core.document_version set scan_status = 'not_scanned' where id = tests.w('dv_pend');
select ok((select (f ->> 'included')::boolean and f ->> 'scan_status' = 'not_scanned'
             from jsonb_array_elements(core.pack_files(tests.w('wp2'), 'external', '[]')) f where (f ->> 'version_id')::uuid = tests.w('dv_pend')),
  'a file recorded as not scanned while scanning was off goes into a pack, marked as not scanned');

select * from finish();
rollback;
