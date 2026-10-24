-- Structural guarantees: RLS everywhere, no client writes, only api exposed for
-- execution, every privileged function pins its search_path.
begin;
\ir _helpers.psql
select no_plan();

select is((select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname in ('core', 'audit') and c.relkind = 'r'
              and not (c.relrowsecurity and c.relforcerowsecurity)),
  0, 'every core and audit table has RLS enabled and forced');

select is((select string_agg(n.nspname || '.' || c.relname, ', ') from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname in ('core', 'audit') and c.relkind = 'r'
              and has_table_privilege('authenticated', c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE')),
  null, 'authenticated cannot insert, update, delete or truncate any core or audit table');

select is((select string_agg(n.nspname || '.' || c.relname, ', ') from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname in ('core', 'audit', 'api') and c.relkind in ('r', 'v')
              and has_table_privilege('anon', c.oid, 'SELECT, INSERT, UPDATE, DELETE')),
  null, 'anon has no access to any table or view');

select is((select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'api' and c.relkind = 'r'),
  0, 'the api schema contains no tables');

select is((select string_agg(c.relname, ', ') from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'api' and c.relkind = 'v'
              and not coalesce('security_invoker=true' = any (c.reloptions), false)),
  null, 'every api view is security_invoker, so RLS applies to the caller');

select is((select string_agg(p.proname, ', ') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'api' and not p.prosecdef),
  null, 'every api function is security definer');

select is((select string_agg(n.nspname || '.' || p.proname, ', ') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('core', 'authz', 'audit', 'api') and p.prosecdef
              and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')),
  null, 'every security definer function pins search_path');

select is((select string_agg(n.nspname || '.' || p.proname, ', ') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('core', 'audit')
              and has_function_privilege('authenticated', p.oid, 'EXECUTE')),
  null, 'authenticated cannot execute any core or audit function');

select ok(not has_function_privilege('authenticated', 'authz.require(text,jsonb,text,jsonb,uuid,uuid)', 'EXECUTE'),
  'authenticated cannot call authz.require directly');
select ok(not has_function_privilege('authenticated', 'authz.evaluate(text,jsonb,uuid,uuid)', 'EXECUTE'),
  'authenticated cannot call authz.evaluate directly (api.check wraps it)');
select ok(not has_function_privilege('authenticated', 'authz.capacities(text,jsonb,uuid)', 'EXECUTE'),
  'authenticated cannot call authz.capacities directly');

select is((select string_agg(p.proname, ', ') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'api' and has_function_privilege('anon', p.oid, 'EXECUTE')),
  null, 'anon cannot execute any api function');

select is((select string_agg(c.relname, ', ') from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'core' and c.relkind = 'r'
              and not exists (select 1 from pg_trigger t where t.tgrelid = c.oid and t.tgname = 'a_forbid_delete')
              and not exists (select 1 from pg_trigger t where t.tgrelid = c.oid and t.tgname = 'forbid_change')),
  null, 'every core table refuses deletes');

select is((select string_agg(c.relname, ', ') from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'core' and c.relkind = 'r'
              and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'status' and not a.attisdropped)
              and not exists (select 1 from pg_trigger t where t.tgrelid = c.oid and t.tgname = 'd_guard_status')),
  null, 'every core table with a status column has the status guard');

-- Direct writes from a signed-in client fail at the privilege layer.
select tests.login(tests.w('u_a1'));
select throws_ok(format($$insert into core.area (customer_id, venue_id, parent_id, area_kind_id, code, name)
                          values (%L, %L, %L, %L, 'X', 'X')$$,
                        tests.w('cust_a'), tests.w('v1'), tests.w('site'), tests.w('k_hall')),
  '42501', null, 'a tenant admin cannot insert into a core table directly');
select throws_ok(format($$update core.engagement set status = 'ended' where id = %L$$, tests.w('e1')),
  '42501', null, 'a tenant admin cannot update a core table directly');
select throws_ok($$select authz.require('venue.create', '{}', 'key-00000001', '{}')$$,
  '42501', null, 'a client cannot call authz.require');
select tests.logout();

select * from finish();
rollback;
