-- 0058 The audit log records decisions, not record contents (phase 8d, D-022, 8d-1)
--
-- Until now every row event copied the whole row (and every changed value) into the append-only
-- log, so a record disposed of under a retention rule would have lived on there in full. From
-- this migration a row event records what CLAUDE.md §3 asks of the audit log: the action, the
-- actor and capacity (unchanged), the target and time, which columns changed (by name), the
-- reason the record gives, and a SHA-256 digest of the row keyed with a random value held per
-- record. While the record exists, its current content can be shown to match the last event;
-- once the record and its key are disposed of, the digest reveals nothing. The hash chain and
-- every other event are unchanged.
--
-- Recovery: pre-pilot, `supabase db reset` (events written before this migration keep the
-- contents they recorded; there is no pilot data). Afterwards, forward fix only: the log is never
-- rewritten.

-- One random key per audited record. Disposed of with the record (phase 8d), never otherwise.
create table audit.record_key (
  table_name  text not null,
  record_id   uuid not null,
  key         bytea not null check (length(key) = 32),
  created_at  timestamptz not null default clock_timestamp(),
  primary key (table_name, record_id)
);
alter table audit.record_key enable row level security;
alter table audit.record_key force row level security;

-- The columns whose value is a record's stated reason: kept in the log in clear, because they
-- are why a decision was made (History and permit packs read them from here).
create function audit.reason_columns() returns text[]
language sql immutable set search_path = '' as $$
  select array['reason', 'decision_reason', 'lift_reason', 'unlinked_reason', 'change_reason', 'cancel_reason', 'removal_reason'] $$;

create function audit.row_digest(p_key bytea, p_row jsonb) returns text
language sql immutable set search_path = '' as $$
  select encode(sha256(p_key || convert_to(p_row::text, 'UTF8')), 'hex') $$;

-- TG_ARGV[0] (columns once redacted) is still accepted, and now unnecessary: no value is kept.
create or replace function audit.capture_row() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_new    jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  v_old    jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  v_row    jsonb := coalesce(v_new, v_old);
  v_table  text := tg_table_schema || '.' || tg_table_name;
  v_id     uuid := case when jsonb_typeof(v_row -> 'id') = 'string' and (v_row ->> 'id') ~ '^[0-9a-f-]{36}$' then (v_row ->> 'id')::uuid end;
  v_cols   text[];
  v_reason text;
  v_key    bytea;
begin
  if tg_op = 'INSERT' then
    select array_agg(k order by k) into v_cols from jsonb_object_keys(v_new) k where jsonb_typeof(v_new -> k) <> 'null';
  elsif tg_op = 'UPDATE' then
    select array_agg(k order by k) into v_cols from jsonb_object_keys(v_new) k where (v_new -> k) is distinct from (v_old -> k);
  end if;
  if tg_op <> 'DELETE' then
    select v_new ->> c into v_reason
      from unnest(audit.reason_columns()) with ordinality u(c, o)
     where v_new ->> c is not null and (tg_op = 'INSERT' or c = any (coalesce(v_cols, '{}')))
     order by o limit 1;
  end if;
  if v_id is not null and tg_op <> 'DELETE' then
    select key into v_key from audit.record_key where table_name = v_table and record_id = v_id;
    if v_key is null then
      v_key := uuid_send(gen_random_uuid()) || uuid_send(gen_random_uuid());
      insert into audit.record_key (table_name, record_id, key) values (v_table, v_id, v_key);
    end if;
  end if;

  perform audit.record(
    'row.' || lower(tg_op),
    case when v_table = 'core.customer' then (v_row ->> 'id')::uuid
         else (v_row ->> 'customer_id')::uuid end,
    case when v_table = 'core.venue' then (v_row ->> 'id')::uuid
         else (v_row ->> 'venue_id')::uuid end,
    v_table,
    v_id,
    v_reason,
    jsonb_strip_nulls(jsonb_build_object(
      'columns', to_jsonb(coalesce(v_cols, '{}')),
      'digest', case when v_key is not null then audit.row_digest(v_key, v_new) end)));
  return null;
end $$;

-- Whether a record's current content is what its last audited event recorded. Null when the
-- record or its key no longer exists (disposed of), or it was last written before this migration.
create function audit.record_matches(p_table regclass, p_id uuid) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare v_row jsonb; v_key bytea; v_digest text; v_name text := p_table::text;
begin
  execute format('select to_jsonb(t) from %s t where t.id = $1', p_table) into v_row using p_id;
  select key into v_key from audit.record_key where table_name = v_name and record_id = p_id;
  select change ->> 'digest' into v_digest from audit.audit_event
   where target_table = v_name and target_id = p_id and action in ('row.insert', 'row.update') order by id desc limit 1;
  if v_row is null or v_key is null or v_digest is null then return null; end if;
  return audit.row_digest(v_key, v_row) = v_digest;
end $$;

revoke execute on function audit.reason_columns(), audit.row_digest(bytea, jsonb), audit.record_matches(regclass, uuid) from public;
