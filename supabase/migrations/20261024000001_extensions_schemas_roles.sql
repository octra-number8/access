-- 0001 Extensions, schemas and default privileges
--
-- Recovery: pre-pilot, reset the local/development database (`supabase db reset`).
-- Once operational data exists, recover only by a forward fix migration.

create extension if not exists btree_gist with schema extensions;

create schema core;   -- all tables; never exposed to the Data API
create schema authz;  -- the single authorisation service (D-003)
create schema audit;  -- append-only audit log
create schema api;    -- the only schema exposed to clients

comment on schema core  is 'Octra Access tables. Not exposed to the Data API.';
comment on schema authz is 'Single authorisation service (D-003). Not exposed.';
comment on schema audit is 'Append-only audit log. Not exposed.';
comment on schema api   is 'Client surface: security-invoker views and security-definer RPCs only.';

revoke all on schema core, authz, audit, api from public;
revoke all on schema core, authz, audit, api from anon, authenticated;

-- Clients may resolve names in api, and read core tables only through RLS
-- (views in api are security_invoker). They never write any table directly.
grant usage on schema api to authenticated;
grant usage on schema core to authenticated;

-- Functions are executable by PUBLIC by default; reverse that everywhere we own.
alter default privileges for role postgres revoke execute on functions from public;
alter default privileges for role postgres in schema core, authz, audit, api
  revoke all on tables from public, anon, authenticated;
alter default privileges for role postgres in schema core, authz, audit, api
  revoke all on sequences from public, anon, authenticated;

-- Transaction-local context readers. Settings are written only by authz and core
-- functions via set_config(..., true), so they never outlive the transaction.
create function core.ctx(p_name text) returns text
language sql stable
set search_path = ''
as $$ select nullif(current_setting('octra.' || p_name, true), '') $$;

create function core.ctx_uuid(p_name text) returns uuid
language sql stable
set search_path = ''
as $$ select core.ctx(p_name)::uuid $$;
