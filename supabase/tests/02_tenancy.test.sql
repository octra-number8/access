-- Cross-tenant and cross-venue separation, for reads and writes.
begin;
\ir _helpers.psql
select no_plan();

-- Counts rows the current user can see, in every api view with a customer_id, that
-- belong to the given customer.
create function tests.visible_rows(p_customer uuid) returns table (view_name text, n bigint)
language plpgsql as $$
declare v record;
begin
  for v in select c.relname from pg_class c join pg_namespace s on s.oid = c.relnamespace
            where s.nspname = 'api' and c.relkind = 'v'
              and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'customer_id')
  loop
    view_name := v.relname;
    execute format('select count(*) from api.%I where customer_id = $1', v.relname) into n using p_customer;
    return next;
  end loop;
end $$;
grant execute on function tests.visible_rows(uuid) to authenticated;

-- ---- Cross-tenant reads ----------------------------------------------------
select tests.login(tests.w('u_b1'));
select is((select string_agg(view_name, ', ') from tests.visible_rows(tests.w('cust_a')) where n > 0),
  null, 'customer B''s admin sees no customer A rows in any api view');
select is((select count(*)::int from api.customer where id = tests.w('cust_a')), 0,
  'customer B''s admin cannot see customer A');
select ok((select count(*) from api.venue where id = tests.w('w1')) = 1,
  'customer B''s admin can see their own venue');
select tests.logout();

select tests.login(tests.w('u_a1'));
select ok((select count(*) from tests.visible_rows(tests.w('cust_a')) where n > 0) >= 15,
  'customer A''s admin does see customer A data (sanity check for the test above)');
select is((select string_agg(view_name, ', ') from tests.visible_rows(tests.w('cust_b')) where n > 0),
  null, 'customer A''s admin sees no customer B rows');
select tests.logout();

-- ---- Cross-tenant writes ---------------------------------------------------
select tests.login(tests.w('u_b1'));
select is(api.create_area(tests.key(), tests.w('site'), tests.w('k_hall'), 'INTRUDE', 'Intruder') ->> 'code',
  'not_found', 'customer B''s admin cannot add an area to customer A''s venue');
select is(api.create_person(tests.key(), tests.w('cust_a'), 'Ivy', 'Intruder') ->> 'code',
  'not_found', 'customer B''s admin cannot create a person in customer A');
select is(api.suspend_engagement(tests.key(), tests.w('e1'), 1, 'attempt') ->> 'code',
  'not_found', 'customer B''s admin cannot suspend customer A''s engagement');
select is(api.grant_appointment(tests.key(), tests.w('v1'), tests.w('p_h'), tests.w('tv_hall'), array[tests.w('pc_hw')],
            jsonb_build_array(jsonb_build_object('area_id', tests.w('hall2'))), now(), now() + interval '1 day',
            null, null, 'x') ->> 'code',
  'not_found', 'customer B''s admin cannot grant an appointment in customer A');
select tests.logout();

select is((select count(*)::int from core.area where code = 'INTRUDE'), 0, 'no intruding area was written');
select is((select count(*)::int from core.person where given_name = 'Ivy'), 0, 'no intruding person was written');
select is((select status from core.engagement where id = tests.w('e1')), 'active', 'engagement is untouched');
select ok((select count(*) from audit.audit_event
            where customer_id = tests.w('cust_a') and action = 'authz.denied' and actor_user_id = tests.w('u_b1')) >= 4,
  'the cross-tenant attempts are recorded in customer A''s audit trail');

-- ---- Cross-venue within one customer -------------------------------------
select tests.login(tests.w('u_h'));
select ok((select count(*) from api.area where venue_id = tests.w('v1')) > 0, 'a V1 appointee sees V1 areas');
select is((select count(*)::int from api.area where venue_id = tests.w('v2')), 0, 'a V1 appointee sees no V2 areas');
select is((select count(*)::int from api.venue where id = tests.w('v2')), 0, 'a V1 appointee cannot see venue V2');
select ok((select count(*) from api.organisation where id = tests.w('org_o')) = 1,
  'a V1 appointee sees organisations engaged at V1');
select is((select count(*)::int from api.organisation where id = tests.w('org_o2')), 0,
  'a V1 appointee does not see organisations not engaged at V1');
select ok((select count(*) from api.person where id = tests.w('p_op')) = 1,
  'a V1 appointee sees operatives of organisations engaged at V1');
select is((select count(*)::int from api.person_contact), 0,
  'a V1 appointee sees no one''s contact details');
select is((select count(*)::int from api.appointment_evidence where appointment_id = tests.w('ap_h2')), 0,
  'a V1 appointee cannot see another appointee''s competence evidence');
select is((select count(*)::int from api.appointment_evidence where appointment_id = tests.w('ap_h')), 1,
  'an appointee can see their own competence evidence');
select tests.logout();

select tests.login(tests.w('u_op'));
select ok((select count(*) from api.venue where id = tests.w('v1')) = 1, 'an engaged operative sees their venue');
select is((select count(*)::int from api.venue where id = tests.w('v2')), 0, 'an engaged operative cannot see other venues');
select is((select count(*)::int from api.organisation), 1, 'an operative sees only their own organisation');
select is((select count(*)::int from api.person_contact), 1, 'an operative sees only their own contact details');
select is((select count(*)::int from api.engagement where organisation_id = tests.w('org_o')), 1,
  'an operative sees their organisation''s engagement');
select is((select count(*)::int from api.audit_event where actor_user_id is distinct from tests.w('u_op')), 0,
  'an operative sees no audit events except their own');
select ok((select count(*) from api.audit_event) > 0, 'and does see their own (accepting their relationship)');
select tests.logout();

select tests.login(tests.w('u_a1'));
select is((select count(*)::int from api.venue where customer_id = tests.w('cust_a')), 2,
  'a tenant admin sees every venue of their customer');
select tests.logout();

select * from finish();
rollback;
