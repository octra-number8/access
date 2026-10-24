-- Invitations (Q26, Q27, Q32): token plus matching login, privacy notice at
-- collection, no automatic merging, cancellation, decline, expiry, delivery failure.
begin;
\ir _helpers.psql
\ir _phase2.psql
select no_plan();

-- ---- The fixture's organisation invitation produced the right records ----------
select is((select status from core.invitation where result_organisation_id = tests.w('org_c')), 'accepted',
  'an accepted organisation invitation is marked accepted');
select is((select legal_name from core.organisation where id = tests.w('org_c')), 'Cara Electrical Ltd',
  'the organisation is created from the acceptor''s details');
select is((select status from core.engagement where id = tests.w('e_c')), 'proposed',
  'accepting an invitation creates a proposed engagement, not an active one (P2-2)');
select is((select role from core.organisation_admin where organisation_id = tests.w('org_c') and person_id = tests.w('p_cara')),
  'accountable', 'the acceptor becomes the accountable administrator');
select is((select acceptance_method from core.person_organisation_relationship
            where organisation_id = tests.w('org_c') and person_id = tests.w('p_cara')),
  'self', 'the acceptor''s relationship is active by their own acceptance');
select ok(exists (select 1 from core.privacy_notice_shown where auth_user_id = tests.w('u_cara')
                   and privacy_notice_version_id = tests.w('pn')),
  'the privacy notice shown at collection is recorded (Q219)');
select ok((select count(*) from core.decision_context dc
            join core.decision_context p on p.id = dc.parent_id
           where p.action_code = 'invitation.accept' and p.actor_user_id = tests.w('u_cara')) = 2,
  'the engagement and relationship were created as derived decisions of the acceptance');

-- ---- Tokens never leak ---------------------------------------------------------
select hasnt_column('api', 'invitation', 'token_hash', 'the api view has no token hash');
select tests.login(tests.w('u_a1'));
select throws_ok($$select token_hash from core.invitation limit 1$$, '42501', null,
  'even the underlying table''s token hash is unreadable to clients');
select tests.logout();

-- ---- Who may accept -------------------------------------------------------------
create temp table t_tok (name text primary key, token text);
grant select on t_tok to authenticated;
insert into t_tok values ('dan', tests.invite_org('dan@dan.test', 'Dan', 'Duplicate'));
insert into t_tok values ('eve', tests.invite_org('eve@eve.test', 'Eve', 'Expired'));
insert into t_tok values ('gil', tests.invite_org('gil@gil.test', 'Gil', 'Decliner'));
insert into t_tok values ('hal', tests.invite_org('hal@hal.test', 'Hal', 'Cancelled'));
select tests.set_w('u_dan', tests.new_user('dan@dan.test'));
select tests.set_w('u_mallory', tests.new_user('mallory@elsewhere.test'));

select tests.login(tests.w('u_mallory'));
select is(api.invitation_preview((select token from t_tok where name = 'dan')) ->> 'code', 'not_found',
  'someone else cannot preview an invitation');
select is(api.accept_invitation(tests.key(), (select token from t_tok where name = 'dan'), tests.w('pn'), 'Mallory Ltd') ->> 'code',
  'invitation_wrong_account', 'someone signed in with a different email cannot accept it');
select is(api.accept_invitation(tests.key(), 'not-a-real-token', tests.w('pn'), 'Mallory Ltd') ->> 'code',
  'not_found', 'a made-up token is refused without saying anything about real invitations');
select tests.logout();

select tests.login(tests.w('u_dan'));
select is(api.invitation_preview((select token from t_tok where name = 'dan')) -> 'privacy_notice' ->> 'id',
  tests.w('pn')::text, 'the invitee is shown the current privacy notice before accepting');
select throws_ok(format($$select api.accept_invitation(%L, %L, null, 'Dan Ltd')$$, tests.key(), (select token from t_tok where name = 'dan')),
  '22023', null, 'accepting without the current privacy notice is refused');

-- ---- Q26: a matching registration number is not merged automatically -----------
select is(api.accept_invitation(tests.key(), (select token from t_tok where name = 'dan'), tests.w('pn'),
            'Orbit Electrical (trading as Dan)', null, '01234567', 'Dan', 'Duplicate') ->> 'status',
  'awaiting_match', 'an acceptance whose company number matches an existing organisation waits for a decision');
select is((select count(*)::int from api.organisation where id = tests.w('org_o')), 0,
  'the acceptor learns nothing about the existing organisation');
select is(api.accept_invitation(tests.key(), (select token from t_tok where name = 'dan'), tests.w('pn'), 'Again') ->> 'code',
  'invitation_not_pending', 'an invitation can only be accepted once');
select tests.logout();
select is((select count(*)::int from core.organisation where company_number = '01234567'), 1,
  'no duplicate organisation was created');

-- The existing organisation already has an accountable administrator (OP).
select tests.login(tests.w('u_a1'));
select tests.must(api.set_accountable_admin(tests.key(), tests.w('org_o'), tests.w('p_op')));
select is(api.resolve_invitation_match(tests.key(),
            (select id from core.invitation where invitee_email = 'dan@dan.test'),
            tests.version('core.invitation', (select id from core.invitation where invitee_email = 'dan@dan.test')),
            'linked') ->> 'organisation_id',
  tests.w('org_o')::text, 'a tenant administrator can link the acceptance to the existing organisation');
select tests.logout();
select is((select count(*)::int from core.organisation_admin
            where organisation_id = tests.w('org_o') and revoked_at is null and role = 'accountable'
              and person_id = tests.w('p_op')), 1,
  'linking does not displace the existing accountable administrator');
select is((select count(*)::int from core.engagement where organisation_id = tests.w('org_o') and status = 'proposed'), 1,
  'the linked organisation gets a proposed engagement');

-- ---- Expiry, decline, cancellation, delivery failure ---------------------------
-- Simulate time passing for one invitation (tests only).
alter table core.invitation disable trigger b_guard_update;
update core.invitation set created_at = now() - interval '10 days', expires_at = now() - interval '1 day'
 where invitee_email = 'eve@eve.test';
alter table core.invitation enable trigger b_guard_update;
select tests.set_w('u_eve', tests.new_user('eve@eve.test'));
select tests.login(tests.w('u_eve'));
select is(api.accept_invitation(tests.key(), (select token from t_tok where name = 'eve'), tests.w('pn'), 'Eve Ltd') ->> 'code',
  'invitation_expired', 'an expired invitation cannot be accepted');
select tests.logout();
select is((select status from core.invitation where invitee_email = 'eve@eve.test'), 'pending',
  'expiry is derived from the date; nothing rewrote the status');

select tests.set_w('inv_hal', (select id from core.invitation where invitee_email = 'hal@hal.test'));
select tests.set_w('inv_gil', (select id from core.invitation where invitee_email = 'gil@gil.test'));
select tests.set_w('inv_eve', (select id from core.invitation where invitee_email = 'eve@eve.test'));
select tests.set_w('u_gil', tests.new_user('gil@gil.test'));
select tests.login(tests.w('u_gil'));
select is(api.decline_invitation(tests.key(), (select token from t_tok where name = 'gil')) ->> 'ok', 'true',
  'the invitee can decline');
select tests.logout();
select is((select status from core.invitation where invitee_email = 'gil@gil.test'), 'declined', 'it is declined');

select tests.login(tests.w('u_cara'));
select is(api.cancel_invitation(tests.key(), tests.w('inv_hal'), 1) ->> 'code',
  'not_tenant_admin', 'a contractor administrator cannot cancel a venue''s organisation invitation');
select tests.login(tests.w('u_a1'));
select is(api.cancel_invitation(tests.key(), tests.w('inv_hal'),
            tests.version('core.invitation', tests.w('inv_hal'))) ->> 'ok',
  'true', 'the venue can cancel it');
select tests.set_w('u_hal', tests.new_user('hal@hal.test'));
select tests.login(tests.w('u_hal'));
select is(api.accept_invitation(tests.key(), (select token from t_tok where name = 'hal'), tests.w('pn'), 'Hal Ltd') ->> 'code',
  'invitation_not_pending', 'a cancelled invitation cannot be accepted');

select tests.login(tests.w('u_a1'));
select is(api.record_invitation_delivery_failure(tests.key(), tests.w('inv_gil'),
            'bounced') ->> 'code',
  'not_service', 'only the notification service can record a delivery failure');
select tests.login(tests.w('u_notifier'));
select is(api.record_invitation_delivery_failure(tests.key(), tests.w('inv_eve'),
            '550 mailbox unavailable') ->> 'ok',
  'true', 'the notification service records it');
select tests.logout();
select is((select status from core.invitation where invitee_email = 'eve@eve.test'), 'pending',
  'a delivery failure is recorded without changing the invitation''s state');

select tests.login(tests.w('u_b1'));
select is(api.create_organisation_invitation(tests.key(), tests.w('v1'), 'exhibitor', 'X', 'Y', 'x@y.test',
            tests.w('p_b1'), now() + interval '1 day', now()) ->> 'code',
  'not_found', 'another customer cannot invite to this venue');
select tests.logout();

select * from finish();
rollback;
