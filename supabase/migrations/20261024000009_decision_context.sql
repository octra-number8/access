-- 0009 Decision context (acting capacity and idempotency) and status history
--
-- Every write through the API creates exactly one decision_context, written only by
-- authz.require(). It records who acted, in which capacity, what was checked, and
-- the idempotency key that makes a retried request return the original outcome.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

create table core.decision_context (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  venue_id              uuid,
  actor_user_id         uuid not null references auth.users (id),
  actor_person_id       uuid,
  actor_kind            text not null check (actor_kind in ('user', 'tenant_admin', 'platform_admin')),
  action_code           text not null references core.authority_action,
  basis                 text not null,
  target_type           text not null,
  target_id             uuid not null,
  acting_appointment_id uuid references core.appointment,
  acting_delegation_id  uuid references core.delegation,
  evaluated_at          timestamptz not null default clock_timestamp(),
  evaluation            jsonb not null,
  idempotency_key       text not null check (length(idempotency_key) between 8 and 200),
  request_hash          bytea not null,
  xact_id               xid8 not null default pg_current_xact_id(),
  row_version           integer not null default 1,
  created_at            timestamptz not null default now(),
  created_by_user_id    uuid default auth.uid(),
  -- The customer may be created in the same transaction (customer.create).
  foreign key (customer_id) references core.customer deferrable initially deferred,
  unique (actor_user_id, action_code, idempotency_key),
  check (num_nonnulls(acting_appointment_id, acting_delegation_id) <= 1)
);
create index decision_context_target_idx on core.decision_context (target_id);
select core.attach_standard_triggers('core.decision_context', null);

create function core.decision_context_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if core.ctx('authz_writing') is distinct from new.id::text then
    raise exception 'decision contexts are written only by authz.require()'
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;
create trigger decision_context_guard before insert on core.decision_context
  for each row execute function core.decision_context_guard();

alter table core.engagement
  add foreign key (suspended_by_decision_context_id) references core.decision_context;

create table core.status_history (
  id                  bigint generated always as identity primary key,
  customer_id         uuid not null,
  venue_id            uuid,
  table_name          text not null,
  record_id           uuid not null,
  from_state          text,
  to_state            text not null,
  decision_context_id uuid not null references core.decision_context,
  at                  timestamptz not null default clock_timestamp()
);
create index status_history_record_idx on core.status_history (record_id, id);
alter table core.status_history enable row level security;
alter table core.status_history force row level security;
create trigger a_forbid_delete before delete on core.status_history
  for each row execute function core.forbid_delete();
create trigger b_forbid_update before update on core.status_history
  for each row execute function core.forbid_update();
