-- 0002 Append-only audit log with a per-customer hash chain
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only; the
-- audit table is never rewritten. A broken chain is investigated, not repaired.

create table audit.audit_event (
  id                    bigint generated always as identity primary key,
  chain_seq             bigint not null,
  occurred_at           timestamptz not null default clock_timestamp(),
  customer_id           uuid,          -- null = platform-level chain
  venue_id              uuid,
  actor_user_id         uuid,
  actor_person_id       uuid,
  actor_kind            text not null check (actor_kind in
                          ('user', 'tenant_admin', 'platform_admin', 'system')),
  acting_appointment_id uuid,
  acting_delegation_id  uuid,
  decision_context_id   uuid,
  action                text not null,
  target_table          text,
  target_id             uuid,
  reason                text,
  change                jsonb,
  prev_hash             bytea,
  hash                  bytea not null
);

create unique index audit_event_chain_uq
  on audit.audit_event ((coalesce(customer_id, '00000000-0000-0000-0000-000000000000'::uuid)), chain_seq);
create index audit_event_target_idx on audit.audit_event (target_table, target_id);

alter table audit.audit_event enable row level security;
alter table audit.audit_event force row level security;

-- Canonical hash input. jsonb text output is deterministic (normalised key order).
create function audit.row_hash(e audit.audit_event) returns bytea
language sql immutable
set search_path = ''
as $$
  select sha256(convert_to(jsonb_build_object(
    'prev',  encode(e.prev_hash, 'hex'),
    'seq',   e.chain_seq,
    'at',    to_char(e.occurred_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'),
    'cust',  e.customer_id,
    'venue', e.venue_id,
    'user',  e.actor_user_id,
    'person', e.actor_person_id,
    'kind',  e.actor_kind,
    'appt',  e.acting_appointment_id,
    'deleg', e.acting_delegation_id,
    'ctx',   e.decision_context_id,
    'action', e.action,
    'table', e.target_table,
    'target', e.target_id,
    'reason', e.reason,
    'change', e.change
  )::text, 'UTF8'))
$$;

-- Assigns chain position and hash under a per-chain lock, whoever inserts.
create function audit.chain_before_insert() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_chain uuid := coalesce(new.customer_id, '00000000-0000-0000-0000-000000000000'::uuid);
  v_prev  record;
begin
  perform pg_advisory_xact_lock(hashtextextended('octra.audit:' || v_chain::text, 0));
  select chain_seq, hash into v_prev
    from audit.audit_event
   where coalesce(customer_id, '00000000-0000-0000-0000-000000000000'::uuid) = v_chain
   order by chain_seq desc
   limit 1;
  new.occurred_at := clock_timestamp();
  new.chain_seq   := coalesce(v_prev.chain_seq, 0) + 1;
  new.prev_hash   := v_prev.hash;
  new.hash        := audit.row_hash(new);
  return new;
end $$;

create trigger audit_event_chain
  before insert on audit.audit_event
  for each row execute function audit.chain_before_insert();

create function audit.forbid_change() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'audit.audit_event is append-only (% refused)', tg_op
    using errcode = 'insufficient_privilege';
end $$;

create trigger audit_event_no_update_delete
  before update or delete on audit.audit_event
  for each row execute function audit.forbid_change();
create trigger audit_event_no_truncate
  before truncate on audit.audit_event
  for each statement execute function audit.forbid_change();

-- Writes one semantic event, taking actor and capacity from the transaction context
-- set by authz.require().
create function audit.record(
  p_action       text,
  p_customer_id  uuid,
  p_venue_id     uuid,
  p_target_table text,
  p_target_id    uuid,
  p_reason       text default null,
  p_change       jsonb default null
) returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into audit.audit_event (
    chain_seq, hash, customer_id, venue_id, actor_user_id, actor_person_id, actor_kind,
    acting_appointment_id, acting_delegation_id, decision_context_id,
    action, target_table, target_id, reason, change)
  values (
    0, '\x00', p_customer_id, p_venue_id, auth.uid(), core.ctx_uuid('actor_person_id'),
    coalesce(core.ctx('actor_kind'), case when auth.uid() is null then 'system' else 'user' end),
    core.ctx_uuid('acting_appointment_id'), core.ctx_uuid('acting_delegation_id'),
    core.ctx_uuid('decision_context_id'),
    p_action, p_target_table, p_target_id, p_reason, p_change);
end $$;

-- Generic row capture. TG_ARGV[0], if given, is a comma-separated list of columns
-- whose values are replaced by "[redacted]" (e.g. contact details), so a person can
-- later be pseudonymised without breaking the chain.
create function audit.capture_row() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_new    jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  v_old    jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  v_row    jsonb := coalesce(v_new, v_old);
  v_col    text;
  v_change jsonb;
  v_table  text := tg_table_schema || '.' || tg_table_name;
begin
  if tg_nargs > 0 then
    foreach v_col in array string_to_array(tg_argv[0], ',') loop
      if v_new ? v_col and v_new ->> v_col is not null then
        v_new := jsonb_set(v_new, array[v_col], '"[redacted]"');
      end if;
      if v_old ? v_col and v_old ->> v_col is not null then
        v_old := jsonb_set(v_old, array[v_col], '"[redacted]"');
      end if;
    end loop;
  end if;

  if tg_op = 'INSERT' then
    v_change := jsonb_build_object('new', v_new);
  elsif tg_op = 'DELETE' then
    v_change := jsonb_build_object('old', v_old);
  else
    select coalesce(jsonb_object_agg(k, jsonb_build_object('old', v_old -> k, 'new', v_new -> k)), '{}')
      into v_change
      from jsonb_object_keys(v_new) as k
     where (v_new -> k) is distinct from (v_old -> k);
    v_change := jsonb_build_object('changed', v_change);
  end if;

  perform audit.record(
    'row.' || lower(tg_op),
    case when v_table = 'core.customer' then (v_row ->> 'id')::uuid
         else (v_row ->> 'customer_id')::uuid end,
    case when v_table = 'core.venue' then (v_row ->> 'id')::uuid
         else (v_row ->> 'venue_id')::uuid end,
    v_table,
    (v_row ->> 'id')::uuid,
    null,
    v_change);
  return null;
end $$;

-- Walks one chain and returns every inconsistency found; no rows means intact.
create function audit.verify_chain(p_customer_id uuid)
returns table (chain_seq bigint, audit_event_id bigint, problem text)
language plpgsql stable security definer
set search_path = ''
as $$
declare
  e audit.audit_event;
  v_prev_hash bytea;
  v_expect bigint := 1;
begin
  for e in
    select * from audit.audit_event a
     where a.customer_id is not distinct from p_customer_id
     order by a.chain_seq
  loop
    if e.chain_seq <> v_expect then
      chain_seq := e.chain_seq; audit_event_id := e.id; problem := 'sequence gap'; return next;
    end if;
    if e.prev_hash is distinct from v_prev_hash then
      chain_seq := e.chain_seq; audit_event_id := e.id; problem := 'prev_hash mismatch'; return next;
    end if;
    if e.hash <> audit.row_hash(e) then
      chain_seq := e.chain_seq; audit_event_id := e.id; problem := 'hash mismatch'; return next;
    end if;
    v_prev_hash := e.hash;
    v_expect := e.chain_seq + 1;
  end loop;
end $$;
