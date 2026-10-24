-- 0004 Customer, venue, platform administration and break-glass access
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

create function core.is_valid_timezone(p_tz text) returns boolean
language plpgsql immutable
set search_path = ''
as $$
begin
  perform now() at time zone p_tz;
  return true;
exception when others then
  return false;
end $$;

create table core.customer (
  id                 uuid primary key default gen_random_uuid(),
  name               text not null check (length(btrim(name)) > 0),
  closed_at          timestamptz,
  row_version        integer not null default 1,
  created_at         timestamptz not null default now(),
  created_by_user_id uuid default auth.uid()
);
select core.attach_standard_triggers('core.customer', 'name,closed_at');

create table core.venue (
  id                 uuid primary key default gen_random_uuid(),
  customer_id        uuid not null references core.customer,
  code               text not null check (code ~ '^[A-Za-z0-9_-]{1,40}$'),
  name               text not null check (length(btrim(name)) > 0),
  timezone           text not null check (core.is_valid_timezone(timezone)),
  status             text not null,
  row_version        integer not null default 1,
  created_at         timestamptz not null default now(),
  created_by_user_id uuid default auth.uid(),
  unique (customer_id, code),
  unique (customer_id, id)
);
select core.attach_standard_triggers('core.venue', 'name,timezone,status', null, true);

-- Inserted only by an operator running SQL against the database (runbook), never
-- through the API. Grants no operational authority (invariant 9).
create table core.platform_admin (
  id                 uuid primary key default gen_random_uuid(),
  auth_user_id       uuid not null references auth.users (id),
  granted_at         timestamptz not null default now(),
  revoked_at         timestamptz,
  row_version        integer not null default 1,
  created_at         timestamptz not null default now(),
  created_by_user_id uuid default auth.uid()
);
create unique index platform_admin_current_uq on core.platform_admin (auth_user_id) where revoked_at is null;
select core.attach_standard_triggers('core.platform_admin', 'revoked_at');

-- D-009: platform administrators see no customer data unless a break-glass grant is
-- open. Read-only, reasoned, short-lived, and visible to the customer through audit.
create table core.break_glass_grant (
  id                      uuid primary key default gen_random_uuid(),
  customer_id             uuid not null references core.customer,
  platform_admin_user_id  uuid not null references auth.users (id),
  reason                  text not null check (length(btrim(reason)) >= 10),
  valid_during            tstzrange not null check (
                            not lower_inf(valid_during) and not upper_inf(valid_during)
                            and upper(valid_during) - lower(valid_during) <= interval '8 hours'),
  row_version             integer not null default 1,
  created_at              timestamptz not null default now(),
  created_by_user_id      uuid default auth.uid()
);
select core.attach_standard_triggers('core.break_glass_grant', null);
