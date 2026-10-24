-- 0003 Authority-action catalogue, state machine and generic row guards
--
-- The catalogue and transitions are product rules seeded here, never venue
-- configuration. Later phases add their own verbs and machines in their own
-- migrations (D-004).
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

-- Who may perform an action is decided by its basis:
--   appointment    an in-force appointment, or a delegation backed by one
--   tenant_admin   a current tenant administrator (master data only)
--   platform_admin an Octra platform administrator (customer bootstrap only)
--   subject        the person the record concerns
create table core.authority_action (
  code        text primary key,
  description text not null,
  basis       text not null check (basis in ('appointment', 'tenant_admin', 'platform_admin', 'subject')),
  delegable   boolean not null default false,
  check (not delegable or basis = 'appointment')
);

insert into core.authority_action (code, basis, delegable, description) values
  ('customer.create',               'platform_admin', false, 'Create a customer and its first tenant administrator'),
  ('break_glass.open',              'platform_admin', false, 'Open time-limited, audited support read access to a customer'),
  ('tenant_admin.grant',            'tenant_admin',   false, 'Make a person a tenant administrator'),
  ('venue.create',                  'tenant_admin',   false, 'Create a venue'),
  ('area_kind.create',              'tenant_admin',   false, 'Add an area kind to a venue'),
  ('area.create',                   'tenant_admin',   false, 'Add an area'),
  ('area.retire',                   'tenant_admin',   false, 'Retire an area'),
  ('system_type.create',            'tenant_admin',   false, 'Add a system type to a venue'),
  ('system.create',                 'tenant_admin',   false, 'Register a building system'),
  ('system.link_area',              'tenant_admin',   false, 'Record that a system serves an area'),
  ('system_ownership.record',       'tenant_admin',   false, 'Record which organisation owns, maintains or operates a system'),
  ('organisation.create',           'tenant_admin',   false, 'Create an organisation'),
  ('person.create',                 'tenant_admin',   false, 'Create a person'),
  ('user_account.link',             'tenant_admin',   false, 'Link a login to a person'),
  ('user_account.disable',          'tenant_admin',   false, 'Disable a person''s login'),
  ('person_organisation.record',    'tenant_admin',   false, 'Record a person''s relationship to an organisation'),
  ('engagement.create',             'tenant_admin',   false, 'Engage an organisation at a venue'),
  ('engagement.end',                'tenant_admin',   false, 'End an engagement'),
  ('permit_class.create',           'tenant_admin',   false, 'Add a permit class (stub)'),
  ('appointment_type.create',       'tenant_admin',   false, 'Create an appointment type'),
  ('appointment_type.publish',      'tenant_admin',   false, 'Publish a new appointment type version'),
  ('appointment.record_root',       'tenant_admin',   false, 'Record a root appointment made by the duty holder (D-002)'),
  ('appointment.confirm_root',      'tenant_admin',   false, 'Second-person confirmation of a root appointment (D-002)'),
  ('appointment.revoke_root',       'tenant_admin',   false, 'Record the duty holder''s revocation of a root appointment'),
  ('appointment.acknowledge',       'subject',        false, 'Appointee acknowledges their appointment (D-009)'),
  ('delegation.revoke',             'subject',        false, 'Delegator withdraws their delegation'),
  ('appointment.grant',             'appointment',    false, 'Make an appointment within one''s own scope'),
  ('appointment.revoke',            'appointment',    false, 'Revoke an appointment within one''s own scope'),
  ('delegation.grant',              'appointment',    false, 'Delegate actions from one''s own appointment'),
  ('engagement.suspend',            'appointment',    true,  'Restrict an engagement (Q18)'),
  ('engagement.reinstate',          'appointment',    true,  'Lift an engagement restriction (Q18, invariant 7)');

create table core.state_machine (
  code       text primary key,
  table_name text not null unique
);

create table core.state_initial (
  machine         text not null references core.state_machine,
  state           text not null,
  required_action text not null references core.authority_action,
  primary key (machine, state, required_action)
);

create table core.state_transition (
  machine         text not null references core.state_machine,
  from_state      text not null,
  to_state        text not null,
  required_action text not null references core.authority_action,
  primary key (machine, from_state, to_state, required_action),
  check (from_state <> to_state)
);

insert into core.state_machine (code, table_name) values
  ('venue',       'core.venue'),
  ('engagement',  'core.engagement'),
  ('appointment', 'core.appointment'),
  ('delegation',  'core.delegation');

insert into core.state_initial (machine, state, required_action) values
  ('venue',       'onboarding',              'venue.create'),
  ('engagement',  'active',                  'engagement.create'),
  ('appointment', 'pending_confirmation',    'appointment.record_root'),
  ('appointment', 'pending_acknowledgement', 'appointment.grant'),
  ('delegation',  'in_force',                'delegation.grant');

-- Going live (venue) arrives with onboarding readiness (Q21); no venue transitions yet.
-- A suspended engagement cannot be ended: it must first be reinstated by the
-- restriction's owner, so ending cannot be used to escape a suspension.
insert into core.state_transition (machine, from_state, to_state, required_action) values
  ('engagement',  'active',                  'suspended',               'engagement.suspend'),
  ('engagement',  'suspended',               'active',                  'engagement.reinstate'),
  ('engagement',  'active',                  'ended',                   'engagement.end'),
  ('appointment', 'pending_confirmation',    'pending_acknowledgement', 'appointment.confirm_root'),
  ('appointment', 'pending_confirmation',    'revoked',                 'appointment.revoke_root'),
  ('appointment', 'pending_acknowledgement', 'in_force',                'appointment.acknowledge'),
  ('appointment', 'pending_acknowledgement', 'revoked',                 'appointment.revoke'),
  ('appointment', 'pending_acknowledgement', 'revoked',                 'appointment.revoke_root'),
  ('appointment', 'in_force',                'revoked',                 'appointment.revoke'),
  ('appointment', 'in_force',                'revoked',                 'appointment.revoke_root'),
  ('delegation',  'in_force',                'revoked',                 'delegation.revoke');

alter table core.authority_action enable row level security;
alter table core.authority_action force row level security;
alter table core.state_machine    enable row level security;
alter table core.state_machine    force row level security;
alter table core.state_initial    enable row level security;
alter table core.state_initial    force row level security;
alter table core.state_transition enable row level security;
alter table core.state_transition force row level security;

create trigger forbid_change before update or delete on core.authority_action
  for each row execute function audit.forbid_change();
create trigger forbid_change before update or delete on core.state_machine
  for each row execute function audit.forbid_change();
create trigger forbid_change before update or delete on core.state_initial
  for each row execute function audit.forbid_change();
create trigger forbid_change before update or delete on core.state_transition
  for each row execute function audit.forbid_change();

-- ---------------------------------------------------------------------------
-- Generic guards attached to every core table
-- ---------------------------------------------------------------------------

-- Nothing in core is ever deleted in phase 1; records are retired or revoked.
create function core.forbid_delete() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception '% rows cannot be deleted; retire or revoke instead', tg_table_name
    using errcode = 'insufficient_privilege';
end $$;

-- Append-only tables: no update either.
create function core.forbid_update() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception '% rows are immutable', tg_table_name
    using errcode = 'insufficient_privilege';
end $$;

-- TG_ARGV[0]: comma-separated columns that may change.
-- TG_ARGV[1]: 'transition' if those changes are only allowed inside core.transition()
--             for this record.
create function core.guard_update() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_allowed text[] := string_to_array(tg_argv[0], ',') || array['row_version'];
  v_new jsonb := to_jsonb(new);
  v_old jsonb := to_jsonb(old);
  v_bad text;
begin
  select string_agg(k, ', ') into v_bad
    from jsonb_object_keys(v_new) k
   where (v_new -> k) is distinct from (v_old -> k)
     and k <> all (v_allowed);
  if v_bad is not null then
    raise exception 'columns of % cannot be changed: %', tg_table_name, v_bad
      using errcode = 'insufficient_privilege';
  end if;
  if tg_nargs > 1 and tg_argv[1] = 'transition'
     and v_new is distinct from v_old
     and coalesce(core.ctx('transition'), '') not like (new.id::text || ':%') then
    raise exception 'lifecycle columns of % change only through core.transition()', tg_table_name
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;

create function core.bump_version() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.row_version := old.row_version + 1;
  return new;
end $$;

-- Status may be set or changed only under a decision context created in this
-- transaction for this record, and (for updates) only inside core.transition().
create function core.guard_status() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_machine text;
  v_ctx     uuid := core.ctx_uuid('decision_context_id');
  v_dc      record;
begin
  select code into v_machine from core.state_machine
   where table_name = tg_table_schema || '.' || tg_table_name;
  if v_machine is null then
    raise exception 'no state machine registered for %', tg_table_name;
  end if;
  if tg_op = 'UPDATE' and new.status = old.status then
    return new;
  end if;

  select action_code, target_id, xact_id into v_dc
    from core.decision_context where id = v_ctx;
  if v_ctx is null or not found
     or v_dc.xact_id <> pg_current_xact_id()
     or v_dc.target_id is distinct from new.id then
    raise exception 'status of % can change only through an authorised decision (core.transition)', tg_table_name
      using errcode = 'insufficient_privilege';
  end if;
  -- One decision authorises exactly one status write.
  if position(v_ctx::text in coalesce(core.ctx('consumed_contexts'), '')) > 0 then
    raise exception 'this decision has already been used to change a status'
      using errcode = 'insufficient_privilege';
  end if;
  perform set_config('octra.consumed_contexts',
                     coalesce(core.ctx('consumed_contexts'), '') || v_ctx::text || ',', true);

  if tg_op = 'INSERT' then
    if not exists (select 1 from core.state_initial
                    where machine = v_machine and state = new.status
                      and required_action = v_dc.action_code) then
      raise exception '% cannot start in state % via %', tg_table_name, new.status, v_dc.action_code
        using errcode = 'check_violation';
    end if;
  else
    if core.ctx('transition') is distinct from
         format('%s:%s:%s:%s', new.id, old.status, new.status, v_ctx) then
      raise exception 'status of % can change only through core.transition()', tg_table_name
        using errcode = 'insufficient_privilege';
    end if;
    if not exists (select 1 from core.state_transition
                    where machine = v_machine and from_state = old.status
                      and to_state = new.status and required_action = v_dc.action_code) then
      raise exception '% cannot move from % to % via %', tg_table_name, old.status, new.status, v_dc.action_code
        using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $$;

-- Records every status set or change.
create function core.record_status() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.status = old.status then
    return null;
  end if;
  insert into core.status_history (customer_id, venue_id, table_name, record_id,
                                   from_state, to_state, decision_context_id)
  values (new.customer_id,
          case when tg_table_name = 'venue' then new.id else (to_jsonb(new) ->> 'venue_id')::uuid end,
          tg_table_schema || '.' || tg_table_name, new.id,
          case when tg_op = 'UPDATE' then old.status end, new.status,
          core.ctx_uuid('decision_context_id'));
  return null;
end $$;

-- Attaches the standard triggers to a core table.
--   p_mutable    columns that may change after insert (null = append-only)
--   p_lifecycle  'transition' if mutable columns change only inside core.transition()
--   p_stateful   attach status guard and history
--   p_redact     columns redacted in audit
create function core.attach_standard_triggers(
  p_table     regclass,
  p_mutable   text,
  p_lifecycle text default null,
  p_stateful  boolean default false,
  p_redact    text default null
) returns void
language plpgsql
set search_path = ''
as $$
begin
  execute format('alter table %s enable row level security', p_table);
  execute format('alter table %s force row level security', p_table);
  execute format('create trigger a_forbid_delete before delete on %s for each row execute function core.forbid_delete()', p_table);
  if p_mutable is null then
    execute format('create trigger b_forbid_update before update on %s for each row execute function core.forbid_update()', p_table);
  else
    execute format('create trigger b_guard_update before update on %s for each row execute function core.guard_update(%L%s)',
                   p_table, p_mutable, case when p_lifecycle is null then '' else format(', %L', p_lifecycle) end);
    execute format('create trigger c_bump_version before update on %s for each row execute function core.bump_version()', p_table);
  end if;
  if p_stateful then
    execute format('create trigger d_guard_status before insert or update of status on %s for each row execute function core.guard_status()', p_table);
    execute format('create trigger y_record_status after insert or update of status on %s for each row execute function core.record_status()', p_table);
  end if;
  if p_redact is null then
    execute format('create trigger z_audit after insert or update or delete on %s for each row execute function audit.capture_row()', p_table);
  else
    execute format('create trigger z_audit after insert or update or delete on %s for each row execute function audit.capture_row(%L)', p_table, p_redact);
  end if;
end $$;

-- The only path that changes a status. Lifecycle columns that accompany the
-- change are passed in p_set and applied in the same UPDATE.
create function core.transition(
  p_table               regclass,
  p_id                  uuid,
  p_to_state            text,
  p_expected_version    integer,
  p_decision_context_id uuid,
  p_set                 jsonb default '{}'
) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_from    text;
  v_version integer;
  v_assign  text := '';
  v_key     text;
begin
  if p_decision_context_id is distinct from core.ctx_uuid('decision_context_id') then
    raise exception 'transition must use the decision context authorised in this transaction'
      using errcode = 'insufficient_privilege';
  end if;
  execute format('select status, row_version from %s where id = $1 for update', p_table)
    into v_from, v_version using p_id;
  if v_from is null then
    raise exception 'record not found' using errcode = 'PT404';
  end if;
  if v_version <> p_expected_version then
    raise exception 'record has changed since you loaded it (version % expected, % current)',
      p_expected_version, v_version using errcode = 'PT409';
  end if;
  -- A same-state "transition" would pass the status guard as a no-op while still
  -- rewriting lifecycle columns (e.g. who owns a suspension), so refuse it.
  if v_from = p_to_state then
    raise exception 'record is already %', p_to_state using errcode = 'PT409';
  end if;
  for v_key in select jsonb_object_keys(p_set) loop
    v_assign := v_assign || format(', %1$I = (jsonb_populate_record(null::%2$s, $3)).%1$I', v_key, p_table);
  end loop;
  perform set_config('octra.transition',
                     format('%s:%s:%s:%s', p_id, v_from, p_to_state, p_decision_context_id), true);
  execute format('update %s set status = $1%s where id = $2', p_table, v_assign)
    using p_to_state, p_id, p_set;
  perform set_config('octra.transition', '', true);
end $$;
