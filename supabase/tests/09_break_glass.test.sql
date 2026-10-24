-- D-009: platform administrators see no customer data without a break-glass grant;
-- the grant is reasoned, short-lived, read-only and visible to the customer.
begin;
\ir _helpers.psql
select no_plan();

select tests.login(tests.w('u_platform'));
select is((select count(*)::int from api.venue where customer_id = tests.w('cust_a')), 0,
  'without break-glass, a platform admin sees no customer venues');
select is((select count(*)::int from api.person where customer_id = tests.w('cust_a')), 0,
  'without break-glass, a platform admin sees no customer people');
select throws_ok(format($$select api.open_break_glass(%L, %L, 'Support ticket 4412: slow page', 9)$$, tests.key(), tests.w('cust_a')),
  '23514', null, 'break-glass access cannot exceed 8 hours');
select throws_ok(format($$select api.open_break_glass(%L, %L, 'because', 1)$$, tests.key(), tests.w('cust_a')),
  '23514', null, 'break-glass access needs a real reason');
select is(api.open_break_glass(tests.key(), tests.w('cust_a'), 'Support ticket 4412: slow page', 1) ->> 'ok',
  'true', 'a platform admin can open time-limited access with a reason');
select is((select count(*)::int from api.venue where customer_id = tests.w('cust_a')), 2,
  'with break-glass open, the platform admin can read the customer''s venues');
select ok((select count(*) from api.person where customer_id = tests.w('cust_a')) > 0,
  'and people');
select is((select count(*)::int from api.person_contact where customer_id = tests.w('cust_a')), 0,
  'but never contact details');
select is((select count(*)::int from api.venue where customer_id = tests.w('cust_b')), 0,
  'and only for the customer the grant names');
select is(api.create_area(tests.key(), tests.w('site'), tests.w('k_hall'), 'BG', 'Break-glass area') ->> 'ok',
  'false', 'break-glass is read-only');
select tests.logout();

select tests.login(tests.w('u_a1'));
select is(api.open_break_glass(tests.key(), tests.w('cust_a'), 'Trying to open it myself', 1) ->> 'code',
  'not_platform_admin', 'a tenant admin cannot open break-glass access');
select is((select count(*)::int from api.break_glass_grant), 1, 'the customer''s admin can see the grant');
select ok(exists (select 1 from api.audit_event
                   where target_table = 'core.break_glass_grant' and actor_kind = 'platform_admin'),
  'and the audit event recording it');
select tests.logout();

select tests.login(tests.w('u_b1'));
select is((select count(*)::int from api.break_glass_grant), 0, 'another customer cannot see it');
select tests.logout();

select * from finish();
rollback;
