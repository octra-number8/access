-- Critical notices about people without an Octra account (8a-2, D-023): the person's current
-- organisation administrators get a copy saying why; never for routine notices, people with an
-- account, administrators already addressed or excluded, revoked administrators or ended
-- relationships. Also: every foreign key in core stays deferrable (0061), so a confirmed disposal
-- can always defer them.
begin;
\ir _helpers.psql
\ir _phase2.psql
\ir _phase3.psql
\ir _phase4.psql
select tests.approve_screening();
\ir _phase5.psql
\ir _phase6.psql
select no_plan();

create function tests.raw(p_sql text) returns void language plpgsql as $$
declare t text := substring(p_sql from 'update ([a-z_.]+) ');
begin
  execute format('alter table %s disable trigger user', t);
  execute p_sql;
  execute format('alter table %s enable trigger user', t);
end $$;
create function tests.copies(p_key text) returns uuid[] language sql stable as $$
  select coalesce(array_agg(recipient_person_id order by recipient_person_id), '{}') from core.notification where dedupe_key like p_key || ':for:%' $$;
create function tests.send(p_key text, p_to uuid[], p_class text default 'critical', p_exclude uuid[] default '{}') returns integer language sql as $$
  select core.notify(tests.w('cust_a'), tests.w('v1'), p_to, p_class, 'work_stopped', 'core.permit', gen_random_uuid(), p_key,
                     'Work stopped', 'The work was stopped.', '/permits', p_exclude) $$;

-- Fixture: OP is the accountable administrator of O; Owen works for O and has no account; Nia
-- works for O and has one.
select is((select count(*)::int from core.user_account where person_id = tests.w('p_owen') and disabled_at is null), 0, 'Owen has no account');
select ok(exists (select 1 from core.organisation_admin where organisation_id = tests.w('org_o') and person_id = tests.w('p_op') and revoked_at is null),
  'OP administers O');

select is(tests.send('k1', array[tests.w('p_owen')]), 2, 'a critical notice to Owen is recorded for him and copied once');
select is(tests.copies('k1'), array[tests.w('p_op')], 'the copy goes to O''s administrator');
select is((select class from core.notification where dedupe_key = 'k1:for:' || tests.w('p_owen')), 'critical', 'the copy is itself critical');
select ok((select body from core.notification where dedupe_key = 'k1:for:' || tests.w('p_owen'))
            like 'Sent to you as an administrator of % because Owen Operative has no Octra account%The work was stopped.%direct route%',
  'it says why, then the notice, then the direct-route line');
select is((select channel || '/' || delivery_state from core.notification_delivery d join core.notification n on n.id = d.notification_id
            where n.dedupe_key = 'k1:for:' || tests.w('p_owen')), 'email/pending', 'and is emailed');
select is((select count(*)::int from core.notification where dedupe_key = 'k1' and recipient_person_id = tests.w('p_owen')), 1, 'Owen''s own notice is still recorded');

select is(tests.send('k2', array[tests.w('p_owen')], 'routine'), 1, 'a routine notice is not copied');
select is(tests.copies('k2'), '{}'::uuid[], 'so no administrator has one');
select is(tests.send('k3', array[tests.w('p_nia')]), 1, 'a critical notice to someone with an account is not copied');
select is(tests.send('k4', array[tests.w('p_owen'), tests.w('p_op')]), 2, 'an administrator already addressed gets no second copy');
select is(tests.copies('k4'), '{}'::uuid[], 'none at all');
select is(tests.send('k5', array[tests.w('p_owen')], 'critical', array[tests.w('p_op')]), 1, 'nor does an excluded administrator (the actor)');
select is(tests.send('k6', array[tests.w('p_owen')], 'critical', array[tests.w('p_owen')]), 0, 'an excluded person is not copied for either');

-- Nia without her account: copied too; a disabled account is no account.
update core.user_account set disabled_at = now() where person_id = tests.w('p_nia');
select is(tests.send('k7', array[tests.w('p_nia')]), 2, 'a disabled account counts as none');
update core.user_account set disabled_at = null where person_id = tests.w('p_nia');

-- A deputy is copied while current; a revoked one is not.
select tests.login(tests.w('u_op'));
select tests.must(api.appoint_deputy_admin(tests.key(), tests.w('org_o'), tests.w('p_nia')));
select tests.logout();
select is(tests.send('k8', array[tests.w('p_owen')]), 3, 'the deputy is copied as well');
select is(tests.copies('k8'), (select array_agg(x order by x) from unnest(array[tests.w('p_op'), tests.w('p_nia')]) x), 'OP and the deputy');
update core.organisation_admin set revoked_at = now() where organisation_id = tests.w('org_o') and person_id = tests.w('p_nia');
select is(tests.copies('k8'), (select array_agg(x order by x) from unnest(array[tests.w('p_op'), tests.w('p_nia')]) x), '(earlier copies stay)');
select is(tests.send('k9', array[tests.w('p_owen')]), 2, 'a revoked deputy is not copied');
update core.person set deactivated_at = now() where id = tests.w('p_op');
select is(tests.send('k10', array[tests.w('p_owen')]), 1, 'a deactivated administrator is not copied');
update core.person set deactivated_at = null where id = tests.w('p_op');

-- A copy is not copied on: an administrator without an account gets the copy, and nobody above them.
select tests.login(tests.w('u_op'));
select tests.must(api.appoint_deputy_admin(tests.key(), tests.w('org_o'), tests.w('p_nia')));
select tests.logout();
update core.user_account set disabled_at = now() where person_id = tests.w('p_op');
select is(tests.copies('k12'), '{}'::uuid[], '(none yet)');
select is(tests.send('k12', array[tests.w('p_owen')]), 3, 'an administrator without an account still gets the copy, as does the deputy');
select is((select count(*)::int from core.notification where dedupe_key like 'k12:for:%:for:%'), 0, 'and it goes no further');
update core.user_account set disabled_at = null where person_id = tests.w('p_op');

-- Once Owen no longer works for O, O's administrators are not told about him.
select tests.raw(format($$update core.person_organisation_relationship set status = 'ended', ended_at = now() where person_id = %L and organisation_id = %L$$,
  tests.w('p_owen'), tests.w('org_o')));
select is(tests.send('k11', array[tests.w('p_owen')]), 1, 'an ended relationship means no copy');

-- A real source: a stop recorded against a permit whose supervisor has no account.
select tests.raw(format($$update core.person_organisation_relationship set status = 'active', ended_at = null where person_id = %L and organisation_id = %L$$,
  tests.w('p_owen'), tests.w('org_o')));
select tests.set_w('wp', tests.live_job('Copies'));
select tests.set_w('wa', tests.permit_of(tests.w('wp'), tests.w('pc_wa')));
select tests.raw(format($$update core.permit_team_member set removed_at = now() where permit_id = %L and person_id = %L$$, tests.w('wa'), tests.w('p_owen')));
select tests.raw(format($$update core.permit_team_member set person_id = %L where permit_id = %L and role = 'supervisor' and removed_at is null$$,
  tests.w('p_owen'), tests.w('wa')));
select tests.login(tests.w('u_ivy'));
select tests.must(api.stop_work(tests.key(), tests.w('wa'), 'unsafe_act', 'Ladder footing'));
select tests.logout();
select ok(exists (select 1 from core.notification where event = 'work_stopped' and recipient_person_id = tests.w('p_op')
                   and body like 'Sent to you as an administrator of %Owen Operative%'),
  'a work stop on Owen''s permit reaches O''s administrator');

-- ---- Every foreign key in core is deferrable (0061, 0062) -----------------------------------------------------
select is((select count(*)::int from pg_constraint where contype = 'f' and connamespace = 'core'::regnamespace and not condeferrable), 0,
  'every foreign key in core can be deferred by a confirmed disposal');
select is((select array_agg(conname::text) from pg_constraint where contype = 'f' and connamespace = 'core'::regnamespace and condeferred),
  array['decision_context_customer_id_fkey'], 'and none is deferred unless a transaction asks, except the decision context''s (phase 1, by design)');

select * from finish();
rollback;
