-- Status changes only through authorised transitions; audit is append-only and
-- tamper-evident; idempotency; optimistic concurrency; immutable structure.
-- These run as the database owner (postgres, which bypasses RLS), to show the
-- controls hold below the API too.
begin;
\ir _helpers.psql
select no_plan();

-- ---- Status cannot be written directly ---------------------------------------
select throws_ok(format($$update core.engagement set status = 'suspended', suspended_by_decision_context_id = (select id from core.decision_context limit 1) where id = %L$$, tests.w('e1')),
  '42501', null, 'the database owner cannot change a status directly');
select throws_ok(format($$update core.appointment set status = 'revoked', revoked_at = now() where id = %L$$, tests.w('ap_h')),
  '42501', null, 'the database owner cannot revoke an appointment directly');
select throws_ok(format($$insert into core.venue (customer_id, code, name, timezone, status) values (%L, 'V9', 'Rogue', 'Europe/London', 'onboarding')$$,
                        tests.w('cust_a')),
  '42501', null, 'a stateful record cannot be inserted without an authorised decision');

create function tests.rogue_skip_transition(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update core.engagement set status = 'ended', ended_at = now() where id = p_id;
end $$;
select throws_ok(format($$select tests.rogue_skip_transition(%L)$$, tests.w('e1')),
  '42501', null, 'a security definer function that skips core.transition is refused');

-- Reusing a decision context does not work: one from another transaction fails the
-- transaction check, and one already used (here, the one that created e1 earlier in
-- this transaction) fails the single-use check.
create function tests.rogue_replay_context(p_id uuid, p_ctx uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform set_config('octra.decision_context_id', p_ctx::text, true);
  perform set_config('octra.transition', format('%s:active:ended:%s', p_id, p_ctx), true);
  update core.engagement set status = 'ended', ended_at = now(), end_reason = 'forged' where id = p_id;
end $$;
select throws_ok(format($$select tests.rogue_replay_context(%L, %L)$$, tests.w('e1'),
                        (select id from core.decision_context where target_id = tests.w('e1') limit 1)),
  '42501', null, 'a forged transition marker reusing a spent decision context is refused');
select is((select status from core.engagement where id = tests.w('e1')), 'active', 'the engagement is still active');

select throws_ok($$insert into core.decision_context (customer_id, actor_user_id, actor_kind, action_code, basis, target_type, target_id, evaluation, idempotency_key, request_hash)
                   select customer_id, actor_user_id, actor_kind, action_code, basis, target_type, gen_random_uuid(), evaluation, 'forged-key-1', request_hash
                     from core.decision_context limit 1$$,
  '42501', null, 'decision contexts cannot be written except by authz.require');

-- ---- Undefined transitions --------------------------------------------------
select tests.login(tests.w('u_a1'));
select tests.must(api.end_engagement(tests.key(), tests.w('e1'), tests.version('core.engagement', tests.w('e1')), 'Contract ended'));
select tests.login(tests.w('u_r'));
select throws_ok(format($$select api.suspend_engagement(%L, %L, %s, 'too late')$$,
                        tests.key(), tests.w('e1'), tests.version('core.engagement', tests.w('e1'))),
  '23514', null, 'an ended engagement cannot be suspended (no such transition)');
select tests.login(tests.w('u_h2'));
select throws_ok(format($$select api.acknowledge_appointment(%L, %L, %s)$$,
                        tests.key(), tests.w('ap_h2'), tests.version('core.appointment', tests.w('ap_h2'))),
  'PT409', null, 'an appointment already in force cannot be acknowledged again');
select tests.logout();

-- ---- Optimistic concurrency -------------------------------------------------
select tests.login(tests.w('u_a1'));
select tests.set_w('e2', tests.must(api.create_engagement(tests.key(), tests.w('v1'), tests.w('org_o2'), 'service_provider', now())));
select tests.login(tests.w('u_r'));
select throws_ok(format($$select api.suspend_engagement(%L, %L, %s, 'stale')$$,
                        tests.key(), tests.w('e2'), tests.version('core.engagement', tests.w('e2')) + 1),
  'PT409', null, 'a decision made against a stale version is refused');
select tests.logout();
select is((select status from core.engagement where id = tests.w('e2')), 'proposed', 'and nothing changed');
select is((select count(*)::int from core.decision_context where target_id = tests.w('e2') and action_code = 'engagement.suspend'), 0,
  'and the refused decision left no decision context behind');

-- ---- Idempotency --------------------------------------------------------------
select tests.login(tests.w('u_a1'));
create temp table t_idem as
  select api.create_area('idem-key-0001', tests.w('site'), tests.w('k_hall'), 'HALL9', 'Hall 9') as first,
         api.create_area('idem-key-0001', tests.w('site'), tests.w('k_hall'), 'HALL9', 'Hall 9') as second;
grant select on t_idem to authenticated;
select is((select second ->> 'replayed' from t_idem), 'true', 'repeating a request with the same key is a replay');
select is((select second ->> 'id' from t_idem), (select first ->> 'id' from t_idem), 'and returns the original record');
select is((select count(*)::int from api.area where code = 'HALL9'), 1, 'and creates nothing new');
select is(api.create_area('idem-key-0001', tests.w('site'), tests.w('k_hall'), 'HALL10', 'Hall 10') ->> 'code',
  'idempotency_key_reused', 'the same key with a different request is refused');
select tests.login(tests.w('u_a2'));
select is(api.create_area('idem-key-0001', tests.w('site'), tests.w('k_hall'), 'HALL11', 'Hall 11') ->> 'ok',
  'true', 'keys are per user, so another user''s identical key is independent');
select tests.logout();

-- ---- Structure is immutable; nothing is deleted ------------------------------
select throws_ok(format($$update core.area set parent_id = %L where id = %L$$, tests.w('hall2'), tests.w('stand1')),
  '42501', null, 'an area cannot be re-parented');
select throws_ok(format($$delete from core.area where id = %L$$, tests.w('plant1')),
  '42501', null, 'areas cannot be deleted');
select throws_ok(format($$update core.appointment set valid_during = tstzrange(now() - interval '10 years', null) where id = %L$$, tests.w('ap_h')),
  '42501', null, 'an appointment''s window cannot be widened in place');
select throws_ok(format($$delete from core.appointment_scope where appointment_id = %L$$, tests.w('ap_h')),
  '42501', null, 'an appointment''s scope cannot be removed');
select throws_ok($$update core.authority_action set basis = 'tenant_admin' where code = 'appointment.grant'$$,
  '42501', null, 'the authority catalogue cannot be edited');

select tests.login(tests.w('u_a1'));
select throws_ok(format($$select api.retire_area(%L, %L, %s)$$, tests.key(), tests.w('hall1'), tests.version('core.area', tests.w('hall1'))),
  '23514', null, 'an area an appointment relies on cannot be retired');
select throws_ok(format($$select api.retire_area(%L, %L, %s)$$, tests.key(), tests.w('site'), tests.version('core.area', tests.w('site'))),
  '23514', null, 'the venue root cannot be retired');
select is(api.retire_area(tests.key(), tests.w('plant1'), tests.version('core.area', tests.w('plant1'))) ->> 'ok',
  'true', 'an area nothing relies on can be retired');
select tests.logout();

-- ---- Audit is append-only and tamper-evident ---------------------------------
select throws_ok($$update audit.audit_event set reason = 'edited' where id = (select min(id) from audit.audit_event)$$,
  '42501', null, 'audit events cannot be updated, even by the database owner');
select throws_ok($$delete from audit.audit_event where id = (select min(id) from audit.audit_event)$$,
  '42501', null, 'audit events cannot be deleted');
select throws_ok($$truncate audit.audit_event$$, '42501', null, 'the audit log cannot be truncated');
select is((select count(*)::int from audit.verify_chain(tests.w('cust_a'))), 0, 'the audit chain verifies');

-- The table owner can still disable triggers. The hash chain is what detects that.
alter table audit.audit_event disable trigger audit_event_no_update_delete;
update audit.audit_event set reason = 'quietly edited'
 where id = (select min(id) from audit.audit_event where customer_id = tests.w('cust_a'));
alter table audit.audit_event enable trigger audit_event_no_update_delete;
select is((select problem from audit.verify_chain(tests.w('cust_a')) limit 1), 'hash mismatch',
  'a tampered audit event is detected by the hash chain');

select * from finish();
rollback;
