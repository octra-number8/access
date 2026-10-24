-- Documents (Q36, Q37, P2-4, P2-5, P2-6, CLAUDE.md §5): immutable versions,
-- scan-before-release, scoped visibility, scoped review wording.
begin;
\ir _helpers.psql
\ir _phase2.psql
select no_plan();

-- ---- Submission ---------------------------------------------------------------
create temp table t_d (name text primary key, r jsonb);
grant select on t_d to authenticated;
insert into t_d values ('ins', tests.submit(tests.w('u_cara'), 'organisation', tests.w('org_c'), null, tests.w('dt_ins'),
                                            (now() + interval '1 year')::date));
select is((select r ->> 'ok' from t_d where name = 'ins'), 'true', 'an organisation administrator submits an organisation document');
select ok((select r ->> 'storage_path' from t_d where name = 'ins') ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}$',
  'stored under customer/document/version');
select tests.set_w('dv_ins', ((select r ->> 'id' from t_d where name = 'ins'))::uuid);
select tests.set_w('doc_ins', (select document_id from core.document_version where id = tests.w('dv_ins')));
select is((select scan_status from core.document_version where id = tests.w('dv_ins')), 'pending', 'it starts unscanned');

select is((tests.submit(tests.w('u_op'), 'organisation', tests.w('org_c'), null, tests.w('dt_ins'))) ->> 'code',
  'not_organisation_admin', 'someone outside the organisation cannot submit for it');
select tests.login(tests.w('u_cara'));
select throws_ok(format($$select api.submit_document(%L, gen_random_uuid(), gen_random_uuid(), 'organisation', %L, null, %L,
                          'Animated', %L, 'image/gif', 1000)$$, tests.key(), tests.w('org_c'), tests.w('dt_ins'), tests.sha()),
  '23514', null, 'only PDF, JPEG and PNG are accepted (P2-6)');
select throws_ok(format($$select api.submit_document(%L, gen_random_uuid(), gen_random_uuid(), 'organisation', %L, null, %L,
                          'Huge', %L, 'application/pdf', 30000000)$$, tests.key(), tests.w('org_c'), tests.w('dt_ins'), tests.sha()),
  '23514', null, 'files over 20 MB are refused (P2-6)');
select tests.logout();

-- ---- Nothing is released until scanned clean (P2-5) -----------------------------
select tests.login(tests.w('u_cara'));
select is(api.document_access(tests.w('dv_ins')) ->> 'code', 'scan_pending', 'an unscanned file is not released');
select throws_ok($$select storage_path from core.document_version limit 1$$, '42501', null,
  'clients cannot read storage paths from the table directly');
select tests.logout();
select tests.login(tests.w('u_r'));
select throws_ok(format($$select api.review_document(%L, %L, %L, 'reviewed_no_further_comments', '{"readable":true,"current":true,"relevant":true}', 'Insurance for the stated work')$$,
                        tests.key(), tests.w('dv_ins'), tests.w('rc_ins')),
  'PT409', null, 'an unscanned file cannot be reviewed');
select tests.login(tests.w('u_a1'));
select is(api.record_scan_result(tests.key(), tests.w('dv_ins'), 'clean', 'fake') ->> 'code', 'not_service',
  'only the scanner can record a scan result');
select tests.logout();
select tests.scan(tests.w('dv_ins'));
select tests.login(tests.w('u_scanner'));
select throws_ok(format($$select api.record_scan_result(%L, %L, 'infected', 'again')$$, tests.key(), tests.w('dv_ins')),
  '23514', null, 'a scan result is recorded once');
select tests.logout();

select tests.login(tests.w('u_cara'));
select is(api.document_access(tests.w('dv_ins')) ->> 'disposition', 'attachment', 'a clean file is released, as an attachment');
select tests.logout();
select ok(exists (select 1 from audit.audit_event where action = 'document.accessed' and target_id = tests.w('dv_ins')
                   and actor_user_id = tests.w('u_cara')),
  'every release is audited');

-- An infected file is never released.
insert into t_d values ('bad', tests.submit(tests.w('u_cara'), 'organisation', tests.w('org_c'), null, tests.w('dt_ins')));
select tests.scan(((select r ->> 'id' from t_d where name = 'bad'))::uuid, 'infected');
select tests.login(tests.w('u_cara'));
select is(api.document_access(((select r ->> 'id' from t_d where name = 'bad'))::uuid) ->> 'code', 'infected',
  'an infected file is never released');
select tests.logout();

-- ---- Who can see it --------------------------------------------------------------
select tests.login(tests.w('u_op'));
select is(api.document_access(tests.w('dv_ins')) ->> 'code', 'not_found', 'another organisation cannot reach it');
select is((select count(*)::int from api.document where id = tests.w('doc_ins')), 0, 'or see it');
select tests.login(tests.w('u_h'));
select is((select count(*)::int from api.document where id = tests.w('doc_ins')), 0,
  'an appointee who is not a document reviewer cannot see it');
select tests.login(tests.w('u_b1'));
select is(api.document_access(tests.w('dv_ins')) ->> 'code', 'not_found', 'another customer cannot reach it');
select tests.login(tests.w('u_r'));
select is((select count(*)::int from api.document where id = tests.w('doc_ins')), 1,
  'a document reviewer at the venue where the organisation is engaged can see it');
select tests.logout();

-- ---- Review (Q37, P2-4) ----------------------------------------------------------
select tests.login(tests.w('u_cara'));
select is(api.review_document(tests.key(), tests.w('dv_ins'), tests.w('rc_ins'), 'reviewed_no_further_comments',
            '{"readable":true,"current":true,"relevant":true}', 'Insurance for the stated work') ->> 'code',
  'separation_of_duties', 'the uploader cannot review their own document');
select tests.login(tests.w('u_ian'));
select is(api.review_document(tests.key(), tests.w('dv_ins'), tests.w('rc_ins'), 'reviewed_no_further_comments',
            '{"readable":true,"current":true,"relevant":true}', 'Insurance for the stated work') ->> 'code',
  'separation_of_duties', 'nor can anyone working with the owning organisation');
select tests.login(tests.w('u_r'));
select throws_ok(format($$select api.review_document(%L, %L, %L, 'reviewed_no_further_comments', '{"readable":true,"current":true}', 'Insurance for the stated work')$$,
                        tests.key(), tests.w('dv_ins'), tests.w('rc_ins')),
  '22023', null, 'every declared criterion needs a result');
select throws_ok(format($$select api.review_document(%L, %L, %L, 'reviewed_no_further_comments', '{"readable":true,"current":false,"relevant":true}', 'Insurance for the stated work')$$,
                        tests.key(), tests.w('dv_ins'), tests.w('rc_ins')),
  '22023', null, 'a document that fails a criterion cannot be "no further comments"');
select throws_ok(format($$select api.review_document(%L, %L, %L, 'reviewed_no_further_comments', '{"readable":true,"current":true,"relevant":true}', 'Approved for all work')$$,
                        tests.key(), tests.w('dv_ins'), tests.w('rc_ins')),
  '23514', null, 'review wording can never claim approval (CLAUDE.md §1)');
select throws_ok(format($$select api.review_document(%L, %L, %L, 'reviewed_no_further_comments', '{"readable":true,"current":true,"relevant":true}', 'Verified compliant')$$,
                        tests.key(), tests.w('dv_ins'), tests.w('rc_ins')),
  '23514', null, 'or verification or compliance');
select tests.logout();
select is((tests.review(tests.w('dv_ins'), tests.w('rc_ins'))) ->> 'ok', 'true',
  'a reviewer records a scoped decision against the declared criteria');
select is((select scope_wording from core.review_decision where document_version_id = tests.w('dv_ins')),
  'Public liability cover for electrical installation work at the Exhibition Centre', 'with its scope wording');

-- ---- Evidence is immutable --------------------------------------------------------
select throws_ok(format($$update core.review_decision set outcome = 'not_accepted' where document_version_id = %L$$, tests.w('dv_ins')),
  '42501', null, 'a review decision cannot be changed');
select throws_ok(format($$update core.document_version set sha256 = sha256('x') where id = %L$$, tests.w('dv_ins')),
  '42501', null, 'a document version cannot be changed');
insert into t_d values ('ins2', tests.submit(tests.w('u_cara'), 'organisation', tests.w('org_c'), null, null, null, tests.w('doc_ins')));
select is((select version_no from core.document_version where id = ((select r ->> 'id' from t_d where name = 'ins2'))::uuid), 2,
  'a change is a new version of the same document');
select is((select count(*)::int from core.review_decision where document_version_id = tests.w('dv_ins')), 1,
  'and the earlier version and its review remain');

-- ---- Person documents and changing employer (Q36, Q40) --------------------------
insert into t_d values ('card_via_c', tests.submit(tests.w('u_cara'), 'person', tests.w('org_c'), tests.w('p_ian'), tests.w('dt_card')));
insert into t_d values ('card_own', tests.submit(tests.w('u_ian'), 'person', null, tests.w('p_ian'), tests.w('dt_card')));
select tests.set_w('doc_card_via_c', (select document_id from core.document_version where id = ((select r ->> 'id' from t_d where name = 'card_via_c'))::uuid));
select tests.set_w('doc_card_own', (select document_id from core.document_version where id = ((select r ->> 'id' from t_d where name = 'card_own'))::uuid));
select tests.login(tests.w('u_cara'));
select is((select count(*)::int from api.document where id = tests.w('doc_card_via_c')), 1,
  'the organisation sees a person document it provided');
select is((select count(*)::int from api.document where id = tests.w('doc_card_own')), 0,
  'but not one the person provided themselves (no implicit sharing)');
select tests.login(tests.w('u_ian'));
select is((select count(*)::int from api.document where person_id = tests.w('p_ian')), 2, 'the person sees both');
select tests.must(api.end_own_relationship(tests.key(), tests.w('rel_ian'),
  tests.version('core.person_organisation_relationship', tests.w('rel_ian')), 'Changing employer'));
select tests.login(tests.w('u_cara'));
select is((select count(*)::int from api.document where id = tests.w('doc_card_via_c')), 0,
  'once the person leaves, the former organisation no longer sees their documents');
select tests.login(tests.w('u_ian'));
select is((select count(*)::int from api.document where person_id = tests.w('p_ian')), 2, 'the person still does');
select tests.logout();

select * from finish();
rollback;
