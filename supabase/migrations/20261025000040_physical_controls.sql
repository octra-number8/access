-- 0040 Physical controls (phase 6b, D-019): catalogue, states, tables and rules
--
-- Technical readiness is its own decision (CLAUDE.md §1): an approved permit is not an
-- applied isolation. Each control is its own record with its own owner, lifecycle and
-- version, linked to the permits it protects rather than owned by them, so it can
-- outlive them (invariant 8, transfer in 6c). Every step is a recorded decision.
--
--   isolation      requested -> authorised -> applied -> proved -> removed -> returned
--                  (refused, withdrawn); personal lock roster for group isolation
--   impairment     requested -> authorised -> impaired -> tested -> restored
--                  (refused, withdrawn); overdue is computed, never a status
--   fire watch     arranged -> started -> ended, during and after hot work
--   exclusion zone set up -> removed
--   custody        keys, passes and certificates issued against a permit and returned
--
-- The rules for each system type (who may prove, whether return to service is
-- witnessed, maximum impairment, compensatory measures, notifications) and the controls
-- each class needs are configuration with no default (P6-8, P6-9): a class that has not
-- chosen its controls cannot be issued, and a system type with no rule cannot be
-- authorised.
--
-- A control that fails suspends every job relying on it; only the control's authority
-- can lift that, once the control is restored (invariant 7).
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

-- ---------------------------------------------------------------------------
-- Catalogue
-- ---------------------------------------------------------------------------
insert into core.authority_action (code, basis, delegable, description) values
  ('control_rule.publish',                'appointment',        false, 'Publish the isolation or impairment rules for a system type (P6-9)'),
  ('isolation.request',                   'organisation_admin', false, 'Ask for an isolation for a job (Q143)'),
  ('isolation.request_as_supervisor',     'permit_part',        false, 'Ask for an isolation, as a permit''s supervisor'),
  ('isolation.authorise',                 'appointment',        true,  'Authorise or refuse an isolation and its boundary (Q136, Q143)'),
  ('isolation.apply',                     'appointment',        true,  'Apply an isolation and record its certificate and locks (Q144)'),
  ('isolation.prove',                     'appointment',        true,  'Prove an isolation dead or at zero energy (Q144)'),
  ('isolation.remove',                    'appointment',        true,  'Remove an isolation (Q143)'),
  ('isolation.return',                    'appointment',        true,  'Return an isolated system to service (Q148)'),
  ('isolation.withdraw',                  'appointment',        true,  'Withdraw an isolation request that is no longer needed'),
  ('isolation.lock_on',                   'permit_part',        false, 'Record a personal lock put on an isolation (Q145)'),
  ('isolation.lock_off',                  'permit_part',        false, 'Record a personal lock taken off an isolation'),
  ('isolation.lock_off_on_behalf',        'appointment',        false, 'Remove a personal lock for a holder who is not there (Q146)'),
  ('impairment.request',                  'organisation_admin', false, 'Ask for a system to be impaired for a job (Q135)'),
  ('impairment.request_as_supervisor',    'permit_part',        false, 'Ask for an impairment, as a permit''s supervisor'),
  ('impairment.authorise',                'appointment',        true,  'Authorise or refuse an impairment (Q136)'),
  ('impairment.impair',                   'appointment',        true,  'Impair a system once its measures and notifications are recorded (Q137, Q138)'),
  ('impairment.test',                     'appointment',        true,  'Test a system''s reinstatement, with a witness (Q140)'),
  ('impairment.restore',                  'appointment',        true,  'Confirm an impaired system is back in service'),
  ('impairment.reauthorise',              'appointment',        false, 'Authorise an impairment to continue past its maximum (Q139, Q141)'),
  ('impairment.withdraw',                 'appointment',        true,  'Withdraw an impairment request that is no longer needed'),
  ('fire_watch.arrange',                  'permit_part',        false, 'Arrange a fire watch with a named watcher (Q130)'),
  ('fire_watch.start',                    'permit_part',        false, 'Record that a fire watch has started'),
  ('fire_watch.check',                    'permit_part',        false, 'Record a fire watch check and its findings'),
  ('fire_watch.end',                      'permit_part',        false, 'Record the final fire watch check (Q134)'),
  ('exclusion_zone.set_up',               'permit_part',        false, 'Record that an exclusion zone is set up'),
  ('exclusion_zone.remove',               'permit_part',        false, 'Record that an exclusion zone has been removed'),
  ('custody_item.register',               'tenant_admin',       false, 'Add a key, pass or certificate to the venue''s custody register (Q118)'),
  ('custody.issue',                       'appointment',        true,  'Issue a key, pass or certificate against a permit (Q118, Q160)'),
  ('custody.return',                      'appointment',        true,  'Record that a key, pass or certificate has been returned'),
  ('control.report_failure',              'permit_part',        false, 'Report that a physical control has failed, as someone on the team'),
  ('control.report_failure_as_authority', 'appointment',        true,  'Report that a physical control has failed, as a venue authority'),
  ('control.lift_failure',                'appointment',        true,  'Confirm a failed control is restored and lift the suspensions it caused');

insert into core.part_action (action_code, roles) values
  ('isolation.request_as_supervisor',  array['supervisor']),
  ('isolation.lock_on',                array['supervisor', 'operative']),
  ('isolation.lock_off',               array['supervisor', 'operative']),
  ('impairment.request_as_supervisor', array['supervisor']),
  ('fire_watch.arrange',               array['supervisor']),
  ('fire_watch.start',                 array['supervisor']),
  ('fire_watch.check',                 array['supervisor']),
  ('fire_watch.end',                   array['supervisor']),
  ('exclusion_zone.set_up',            array['supervisor']),
  ('exclusion_zone.remove',            array['supervisor']),
  ('control.report_failure',           array['supervisor', 'operative']);

insert into core.derived_action (parent_action, child_action) values
  ('control.report_failure',              'permit.suspend_with_job'),
  ('control.report_failure_as_authority', 'permit.suspend_with_job');

insert into core.state_machine (code, table_name) values
  ('isolation',      'core.isolation'),
  ('impairment',     'core.impairment'),
  ('fire_watch',     'core.fire_watch'),
  ('exclusion_zone', 'core.exclusion_zone');

insert into core.state_initial (machine, state, required_action) values
  ('isolation',      'requested', 'isolation.request'),
  ('isolation',      'requested', 'isolation.request_as_supervisor'),
  ('impairment',     'requested', 'impairment.request'),
  ('impairment',     'requested', 'impairment.request_as_supervisor'),
  ('fire_watch',     'arranged',  'fire_watch.arrange'),
  ('exclusion_zone', 'set_up',    'exclusion_zone.set_up');

insert into core.state_transition (machine, from_state, to_state, required_action) values
  ('isolation',      'requested',  'authorised', 'isolation.authorise'),
  ('isolation',      'requested',  'refused',    'isolation.authorise'),
  ('isolation',      'requested',  'withdrawn',  'isolation.withdraw'),
  ('isolation',      'authorised', 'withdrawn',  'isolation.withdraw'),
  ('isolation',      'authorised', 'applied',    'isolation.apply'),
  ('isolation',      'applied',    'proved',     'isolation.prove'),
  ('isolation',      'applied',    'removed',    'isolation.remove'),
  ('isolation',      'proved',     'removed',    'isolation.remove'),
  ('isolation',      'removed',    'returned',   'isolation.return'),
  ('impairment',     'requested',  'authorised', 'impairment.authorise'),
  ('impairment',     'requested',  'refused',    'impairment.authorise'),
  ('impairment',     'requested',  'withdrawn',  'impairment.withdraw'),
  ('impairment',     'authorised', 'withdrawn',  'impairment.withdraw'),
  ('impairment',     'authorised', 'impaired',   'impairment.impair'),
  ('impairment',     'impaired',   'tested',     'impairment.test'),
  ('impairment',     'tested',     'restored',   'impairment.restore'),
  ('fire_watch',     'arranged',   'started',    'fire_watch.start'),
  ('fire_watch',     'started',    'ended',      'fire_watch.end'),
  ('exclusion_zone', 'set_up',     'removed',    'exclusion_zone.remove');

-- ---------------------------------------------------------------------------
-- Rules per system type (P6-9): immutable versions with an owner and effective date.
--   isolation:  {prove_by: same_person_allowed | different_person, return_witness: required | not_required}
--   impairment: {max_duration_hours: h > 0, compensatory_measures: [text], notifications: [text]}
-- ---------------------------------------------------------------------------
create table core.system_control_rule (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  venue_id             uuid not null,
  system_type_id       uuid not null,
  kind                 text not null check (kind in ('isolation', 'impairment')),
  content              jsonb not null,
  owner_person_id      uuid not null,
  effective_from       timestamptz not null,
  change_reason        text not null check (length(btrim(change_reason)) > 0),
  decision_context_id  uuid not null references core.decision_context,
  row_version          integer not null default 1,
  created_at           timestamptz not null default clock_timestamp(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (venue_id, system_type_id) references core.system_type (venue_id, id),
  foreign key (customer_id, owner_person_id) references core.person (customer_id, id)
);
select core.attach_standard_triggers('core.system_control_rule', null);

create function core.control_rule_problems(p_kind text, c jsonb) returns text[]
language sql immutable set search_path = '' as $$
  select array_remove(case p_kind
    when 'isolation' then array[
      case when coalesce(c ->> 'prove_by', '') not in ('same_person_allowed', 'different_person')
           then 'Choose whether the person who applied an isolation may also prove it.' end,
      case when coalesce(c ->> 'return_witness', '') not in ('required', 'not_required')
           then 'Choose whether return to service needs a witness.' end]
    when 'impairment' then array[
      case when jsonb_typeof(c -> 'max_duration_hours') is distinct from 'number' or (c ->> 'max_duration_hours')::numeric <= 0
           then 'Set the maximum time a system may stay impaired before a fresh authorisation (Q139): there is no default.' end,
      case when jsonb_typeof(c -> 'compensatory_measures') is distinct from 'array'
                or exists (select 1 from jsonb_array_elements(coalesce(c -> 'compensatory_measures', '[]')) m
                            where jsonb_typeof(m) <> 'string' or length(btrim(m #>> '{}')) = 0)
           then 'List the compensatory measures needed while the system is impaired (Q138), or none, each with wording.' end,
      case when jsonb_typeof(c -> 'notifications') is distinct from 'array'
                or exists (select 1 from jsonb_array_elements(coalesce(c -> 'notifications', '[]')) m
                            where jsonb_typeof(m) <> 'string' or length(btrim(m #>> '{}')) = 0)
           then 'List who must be told before the system is impaired (Q137), or nobody, each with wording.' end]
    else array['A rule is for isolations or impairments.'] end, null) $$;

-- The rule in force now for a system's type.
create function core.control_rule(p_system_id uuid, p_kind text) returns core.system_control_rule
language sql stable security definer set search_path = '' as $$
  select r.* from core.system_control_rule r join core.system s on s.system_type_id = r.system_type_id and s.venue_id = r.venue_id
   where s.id = p_system_id and r.kind = p_kind and r.effective_from <= now()
   order by r.effective_from desc, r.created_at desc limit 1 $$;

-- ---------------------------------------------------------------------------
-- Isolations and impairments (system-owned controls)
-- ---------------------------------------------------------------------------
create table core.isolation (
  id                      uuid primary key default gen_random_uuid(),
  customer_id             uuid not null,
  venue_id                uuid not null,
  system_id               uuid not null,
  points                  text not null check (length(btrim(points)) > 0),
  reason                  text not null check (length(btrim(reason)) > 0),
  planned_window          tstzrange not null check (not isempty(planned_window) and not lower_inf(planned_window) and not upper_inf(planned_window)),
  status                  text not null,
  requested_by_person_id  uuid not null,
  rule_version_id         uuid references core.system_control_rule,
  row_version             integer not null default 1,
  created_at              timestamptz not null default clock_timestamp(),
  created_by_user_id      uuid default auth.uid(),
  foreign key (customer_id, venue_id, system_id) references core.system (customer_id, venue_id, id),
  foreign key (customer_id, requested_by_person_id) references core.person (customer_id, id),
  unique (customer_id, venue_id, id)
);
select core.attach_standard_triggers('core.isolation', 'status,rule_version_id', 'transition', true);

create table core.impairment (
  id                      uuid primary key default gen_random_uuid(),
  customer_id             uuid not null,
  venue_id                uuid not null,
  system_id               uuid not null,
  zones                   text not null check (length(btrim(zones)) > 0),
  reason                  text not null check (length(btrim(reason)) > 0),
  planned_window          tstzrange not null check (not isempty(planned_window) and not lower_inf(planned_window) and not upper_inf(planned_window)),
  status                  text not null,
  requested_by_person_id  uuid not null,
  rule_version_id         uuid references core.system_control_rule,
  max_hours               numeric check (max_hours > 0),
  impaired_at             timestamptz,
  row_version             integer not null default 1,
  created_at              timestamptz not null default clock_timestamp(),
  created_by_user_id      uuid default auth.uid(),
  foreign key (customer_id, venue_id, system_id) references core.system (customer_id, venue_id, id),
  foreign key (customer_id, requested_by_person_id) references core.person (customer_id, id),
  unique (customer_id, venue_id, id)
);
select core.attach_standard_triggers('core.impairment', 'status,rule_version_id,max_hours,impaired_at', null, true);

-- Which permits a system control protects.
create table core.control_link (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  venue_id             uuid not null,
  control_kind         text not null check (control_kind in ('isolation', 'impairment')),
  control_id           uuid not null,
  permit_id            uuid not null,
  linked_by_person_id  uuid not null,
  decision_context_id  uuid not null references core.decision_context,
  row_version          integer not null default 1,
  created_at           timestamptz not null default clock_timestamp(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, venue_id, permit_id) references core.permit (customer_id, venue_id, id),
  foreign key (customer_id, linked_by_person_id) references core.person (customer_id, id),
  unique (control_kind, control_id, permit_id)
);
create index control_link_permit on core.control_link (permit_id);
select core.attach_standard_triggers('core.control_link', null);

-- Every step of every control, with who took it and what they recorded.
create table core.control_event (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  venue_id             uuid not null,
  control_kind         text not null check (control_kind in ('isolation', 'impairment', 'fire_watch', 'exclusion_zone')),
  control_id           uuid not null,
  step                 text not null,
  person_id            uuid,
  content              jsonb not null default '{}',
  decision_context_id  uuid not null references core.decision_context,
  row_version          integer not null default 1,
  created_at           timestamptz not null default clock_timestamp(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, person_id) references core.person (customer_id, id)
);
create index control_event_control on core.control_event (control_kind, control_id);
select core.attach_standard_triggers('core.control_event', null);

-- Personal locks on a group isolation (Q145, Q146).
create table core.isolation_lock (
  id                     uuid primary key default gen_random_uuid(),
  customer_id            uuid not null,
  venue_id               uuid not null,
  isolation_id           uuid not null,
  person_id              uuid not null,
  lock_ref               text not null check (length(btrim(lock_ref)) > 0),
  on_at                  timestamptz not null default clock_timestamp(),
  on_recorded_by_person_id uuid not null,
  on_decision_context_id uuid not null references core.decision_context,
  off_at                 timestamptz,
  off_recorded_by_person_id uuid,
  off_on_behalf          boolean,
  off_reason             text,
  off_decision_context_id uuid references core.decision_context,
  row_version            integer not null default 1,
  created_at             timestamptz not null default clock_timestamp(),
  created_by_user_id     uuid default auth.uid(),
  foreign key (customer_id, venue_id, isolation_id) references core.isolation (customer_id, venue_id, id),
  foreign key (customer_id, person_id) references core.person (customer_id, id),
  foreign key (customer_id, on_recorded_by_person_id) references core.person (customer_id, id),
  foreign key (customer_id, off_recorded_by_person_id) references core.person (customer_id, id),
  check ((off_at is null) = (off_recorded_by_person_id is null) and (off_at is null) = (off_on_behalf is null)
         and (off_at is null) = (off_decision_context_id is null)),
  check (not coalesce(off_on_behalf, false) or length(btrim(coalesce(off_reason, ''))) > 0)
);
create unique index isolation_lock_one_on on core.isolation_lock (isolation_id, person_id) where off_at is null;
select core.attach_standard_triggers('core.isolation_lock', 'off_at,off_recorded_by_person_id,off_on_behalf,off_reason,off_decision_context_id');

create function core.lock_off_once() returns trigger
language plpgsql set search_path = '' as $$
begin
  if old.off_at is not null then
    raise exception 'a personal lock is taken off once' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger lock_off_once before update on core.isolation_lock for each row execute function core.lock_off_once();

-- ---------------------------------------------------------------------------
-- Fire watch and exclusion zones: part of one permit.
-- ---------------------------------------------------------------------------
create table core.fire_watch (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  venue_id             uuid not null,
  permit_id            uuid not null,
  phase                text not null check (phase in ('during', 'post')),
  watcher_person_id    uuid not null,
  status               text not null,
  minimum_minutes      integer not null check (minimum_minutes >= 0),
  started_at           timestamptz,
  ended_at             timestamptz,
  arranged_by_person_id uuid not null,
  row_version          integer not null default 1,
  created_at           timestamptz not null default clock_timestamp(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, venue_id, permit_id) references core.permit (customer_id, venue_id, id),
  foreign key (customer_id, watcher_person_id) references core.person (customer_id, id),
  foreign key (customer_id, arranged_by_person_id) references core.person (customer_id, id)
);
create unique index fire_watch_one_open on core.fire_watch (permit_id, phase) where status <> 'ended';
select core.attach_standard_triggers('core.fire_watch', 'status,started_at,ended_at', 'transition', true);

create table core.exclusion_zone (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  venue_id             uuid not null,
  permit_id            uuid not null,
  area_id              uuid references core.area,
  description          text not null check (length(btrim(description)) > 0),
  status               text not null,
  set_up_by_person_id  uuid not null,
  removed_at           timestamptz,
  row_version          integer not null default 1,
  created_at           timestamptz not null default clock_timestamp(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, venue_id, permit_id) references core.permit (customer_id, venue_id, id),
  foreign key (customer_id, set_up_by_person_id) references core.person (customer_id, id)
);
select core.attach_standard_triggers('core.exclusion_zone', 'status,removed_at', 'transition', true);

-- ---------------------------------------------------------------------------
-- Custody (Q118, Q160): the register, and each issue and return against a permit.
-- ---------------------------------------------------------------------------
create table core.custody_item (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  venue_id             uuid not null,
  kind                 text not null check (kind in ('key', 'pass', 'hatch_key', 'lock_box_key', 'certificate', 'other')),
  label                text not null check (length(btrim(label)) > 0),
  reference            text not null check (length(btrim(reference)) > 0),
  area_id              uuid references core.area,
  retired_at           timestamptz,
  row_version          integer not null default 1,
  created_at           timestamptz not null default clock_timestamp(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  unique (customer_id, venue_id, id),
  unique (venue_id, reference)
);
select core.attach_standard_triggers('core.custody_item', 'retired_at');

create table core.custody_movement (
  id                       uuid primary key default gen_random_uuid(),
  customer_id              uuid not null,
  venue_id                 uuid not null,
  item_id                  uuid not null,
  permit_id                uuid not null,
  holder_person_id         uuid not null,
  issued_by_person_id      uuid not null,
  issued_at                timestamptz not null default clock_timestamp(),
  issue_decision_context_id uuid not null references core.decision_context,
  returned_at              timestamptz,
  received_by_person_id    uuid,
  return_decision_context_id uuid references core.decision_context,
  row_version              integer not null default 1,
  created_at               timestamptz not null default clock_timestamp(),
  created_by_user_id       uuid default auth.uid(),
  foreign key (customer_id, venue_id, item_id) references core.custody_item (customer_id, venue_id, id),
  foreign key (customer_id, venue_id, permit_id) references core.permit (customer_id, venue_id, id),
  foreign key (customer_id, holder_person_id) references core.person (customer_id, id),
  foreign key (customer_id, issued_by_person_id) references core.person (customer_id, id),
  foreign key (customer_id, received_by_person_id) references core.person (customer_id, id),
  check ((returned_at is null) = (received_by_person_id is null) and (returned_at is null) = (return_decision_context_id is null))
);
create unique index custody_one_out on core.custody_movement (item_id) where returned_at is null;
select core.attach_standard_triggers('core.custody_movement', 'returned_at,received_by_person_id,return_decision_context_id');

create function core.custody_return_once() returns trigger
language plpgsql set search_path = '' as $$
begin
  if old.returned_at is not null then
    raise exception 'a custody item is returned once per issue' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger custody_return_once before update on core.custody_movement for each row execute function core.custody_return_once();

-- ---------------------------------------------------------------------------
-- Control failure (design §8.5): suspends every live job the control protects; lifted
-- only by the control's authority, once restored.
-- ---------------------------------------------------------------------------
create table core.control_failure (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  venue_id             uuid not null,
  control_kind         text not null check (control_kind in ('isolation', 'impairment')),
  control_id           uuid not null,
  reason               text not null check (length(btrim(reason)) > 0),
  reported_by_person_id uuid,
  decision_context_id  uuid not null references core.decision_context,
  row_version          integer not null default 1,
  created_at           timestamptz not null default clock_timestamp(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, reported_by_person_id) references core.person (customer_id, id),
  unique (customer_id, venue_id, id)
);
select core.attach_standard_triggers('core.control_failure', null);

create table core.control_failure_resolution (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  venue_id             uuid not null,
  failure_id           uuid not null unique,
  reason               text not null check (length(btrim(reason)) > 0),
  conditions           text[] not null default '{}',
  resolver_person_id   uuid not null,
  decision_context_id  uuid not null references core.decision_context,
  row_version          integer not null default 1,
  created_at           timestamptz not null default clock_timestamp(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, venue_id, failure_id) references core.control_failure (customer_id, venue_id, id),
  foreign key (customer_id, resolver_person_id) references core.person (customer_id, id)
);
select core.attach_standard_triggers('core.control_failure_resolution', null);

create function core.failure_open(p_kind text, p_control_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from core.control_failure f where f.control_kind = p_kind and f.control_id = p_control_id
                    and not exists (select 1 from core.control_failure_resolution r where r.failure_id = f.id)) $$;

-- Suspensions gain a kind for control failure.
alter table core.permit_suspension add column control_failure_id uuid;
alter table core.permit_suspension add foreign key (customer_id, venue_id, control_failure_id)
  references core.control_failure (customer_id, venue_id, id);
alter table core.permit_suspension drop constraint permit_suspension_kind_check;
alter table core.permit_suspension add constraint permit_suspension_kind_check
  check (kind in ('stop', 'job_stop', 'area_stop', 'material_change', 'supervisor_change', 'parent_ended', 'control_failure'));
alter table core.permit_suspension add check ((kind = 'control_failure') = (control_failure_id is not null));

-- A job stop now holds for as long as whatever it came from holds.
create or replace function core.suspension_holding(p_suspension_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select case s.kind
           when 'job_stop' then core.suspension_holding(s.origin_suspension_id)
           when 'area_stop' then not exists (select 1 from core.area_stop_lift l where l.area_stop_id = s.area_stop_id)
           when 'control_failure' then not exists (select 1 from core.control_failure_resolution r where r.failure_id = s.control_failure_id)
           when 'parent_ended' then true
           else not exists (select 1 from core.permit_suspension_lift l where l.suspension_id = s.id) end
    from core.permit_suspension s where s.id = p_suspension_id $$;

-- ---------------------------------------------------------------------------
-- Readiness (P6-8): the controls a class needs, in place now. Replaces P5-11.
--   physical_controls: [{kind: isolation} | {kind: impairment} | {kind: exclusion_zone}
--                       | {kind: fire_watch, during_work: bool, post_work_minutes: n >= 0}]
-- ---------------------------------------------------------------------------
create function core.impairment_overdue(i core.impairment) returns boolean
language sql stable set search_path = '' as $$
  select i.status = 'impaired' and now() > i.impaired_at + make_interval(secs => (i.max_hours * 3600)::double precision) $$;

create function core.permit_class_controls(p core.permit) returns jsonb
language sql stable security definer set search_path = '' as $$
  select c.content -> 'physical_controls'
    from core.permit_class_version c
   where c.id = coalesce((select v.class_version_id from core.permit_version v where v.id = p.current_version_id),
                         (core.current_class_version(p.permit_class_id)).id) $$;

create function core.control_blockers(p_permit_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare p core.permit; cfg jsonb; k jsonb; b jsonb := '[]'; x record; sysname text;
begin
  select * into p from core.permit where id = p_permit_id;
  cfg := core.permit_class_controls(p);
  if cfg is null then
    return jsonb_build_array(jsonb_build_object('check', 'controls', 'problem',
      'This class''s configuration has not chosen its physical controls (P6-8), so it cannot be issued.',
      'who', 'The venue, by approving a new configuration'));
  end if;
  for k in select * from jsonb_array_elements(cfg) loop
    if k ->> 'kind' = 'isolation' then
      if not exists (select 1 from core.control_link l where l.permit_id = p.id and l.control_kind = 'isolation') then
        b := b || jsonb_build_object('check', 'controls', 'problem', 'This class needs an isolation, and none is linked to this permit.',
                                     'who', 'The applicant or supervisor, by asking for one');
      end if;
      for x in select i.*, s.name as system_name from core.control_link l join core.isolation i on i.id = l.control_id join core.system s on s.id = i.system_id
                where l.permit_id = p.id and l.control_kind = 'isolation' loop
        if x.status <> 'proved' then
          b := b || jsonb_build_object('check', 'controls', 'problem', format('The isolation of %s is %s, not proved.', x.system_name, replace(x.status, '_', ' ')),
                                       'who', format('The isolation authority for %s', x.system_name));
        elsif core.failure_open('isolation', x.id) then
          b := b || jsonb_build_object('check', 'controls', 'problem', format('The isolation of %s has failed and is not restored.', x.system_name),
                                       'who', format('The isolation authority for %s', x.system_name));
        end if;
      end loop;
    elsif k ->> 'kind' = 'impairment' then
      if not exists (select 1 from core.control_link l where l.permit_id = p.id and l.control_kind = 'impairment') then
        b := b || jsonb_build_object('check', 'controls', 'problem', 'This class needs an impairment, and none is linked to this permit.',
                                     'who', 'The applicant or supervisor, by asking for one');
      end if;
      for x in select i.id, i.status, s.name as system_name, core.impairment_overdue(i) as overdue
                 from core.control_link l join core.impairment i on i.id = l.control_id join core.system s on s.id = i.system_id
                where l.permit_id = p.id and l.control_kind = 'impairment' loop
        if x.status <> 'impaired' then
          b := b || jsonb_build_object('check', 'controls', 'problem', format('The impairment of %s is %s, not in place.', x.system_name, x.status),
                                       'who', format('The impairment authority for %s', x.system_name));
        elsif x.overdue then
          b := b || jsonb_build_object('check', 'controls', 'problem',
                                       format('The impairment of %s has run past its approved maximum and needs a fresh authorisation.', x.system_name),
                                       'who', format('The impairment authority for %s', x.system_name));
        elsif core.failure_open('impairment', x.id) then
          b := b || jsonb_build_object('check', 'controls', 'problem', format('A compensatory measure for %s has failed and is not restored.', x.system_name),
                                       'who', format('The impairment authority for %s', x.system_name));
        end if;
      end loop;
    elsif k ->> 'kind' = 'fire_watch' then
      if (k ->> 'during_work')::boolean and not exists (select 1 from core.fire_watch w where w.permit_id = p.id and w.phase = 'during' and w.status <> 'ended') then
        b := b || jsonb_build_object('check', 'controls', 'problem', 'This class needs a fire watch during the work, with a named watcher, and none is arranged.',
                                     'who', 'The supervisor');
      end if;
      if not exists (select 1 from core.fire_watch w where w.permit_id = p.id and w.phase = 'post') then
        b := b || jsonb_build_object('check', 'controls', 'problem', 'This class needs a fire watch after the work, with a named watcher, and none is arranged.',
                                     'who', 'The supervisor');
      end if;
    elsif k ->> 'kind' = 'exclusion_zone' then
      if not exists (select 1 from core.exclusion_zone z where z.permit_id = p.id and z.status = 'set_up') then
        b := b || jsonb_build_object('check', 'controls', 'problem', 'This class needs an exclusion zone, and none is set up.', 'who', 'The supervisor');
      end if;
    end if;
  end loop;
  return b;
end $$;

-- Class configuration: the controls list replaces the yes/no flag (P6-8).
do $m$
declare d text;
  old_block constant text := $o$    if jsonb_typeof(p_content -> 'requires_physical_controls') is distinct from 'boolean' then
      errs := errs || text 'Choose whether this class requires physical controls (isolation, impairment or fire watch).';
    end if;$o$;
begin
  d := pg_get_functiondef('core.validate_class_config(uuid,jsonb,boolean)'::regprocedure);
  if position(old_block in d) = 0 or position(E'  return errs;\nend' in d) = 0 then
    raise exception 'core.validate_class_config no longer has the expected structure';
  end if;
  d := replace(d, old_block, $n$    if not p_content ? 'physical_controls' then
      errs := errs || text 'Choose the physical controls this class needs (isolation, impairment, fire watch, exclusion zone), or none (P6-8): there is no default.';
    end if;
    if p_content ? 'requires_physical_controls' then
      errs := errs || text 'The yes/no physical controls choice is replaced by the list of controls the class needs.';
    end if;$n$);
  d := replace(d, E'  return errs;\nend', $r$  if p_content ? 'physical_controls' and (jsonb_typeof(p_content -> 'physical_controls') is distinct from 'array'
       or exists (select 1 from jsonb_array_elements(case when jsonb_typeof(p_content -> 'physical_controls') = 'array'
                                                          then p_content -> 'physical_controls' else '[]' end) k
                   where coalesce(k ->> 'kind', '') not in ('isolation', 'impairment', 'fire_watch', 'exclusion_zone')
                      or (k ->> 'kind' = 'fire_watch' and (jsonb_typeof(k -> 'during_work') is distinct from 'boolean'
                          or jsonb_typeof(k -> 'post_work_minutes') is distinct from 'number'
                          or (k ->> 'post_work_minutes')::numeric < 0
                          or (k ->> 'post_work_minutes')::numeric <> floor((k ->> 'post_work_minutes')::numeric))))
       or (select count(*) from jsonb_array_elements(case when jsonb_typeof(p_content -> 'physical_controls') = 'array'
                                                          then p_content -> 'physical_controls' else '[]' end) k)
          <> (select count(distinct k ->> 'kind') from jsonb_array_elements(case when jsonb_typeof(p_content -> 'physical_controls') = 'array'
                                                          then p_content -> 'physical_controls' else '[]' end) k)) then
    errs := errs || text 'Physical controls are a list of isolation, impairment, fire watch (whether during the work, and the minutes after it) and exclusion zone, each once.';
  end if;
  return errs;
end$r$);
  execute d;
end $m$;

-- ---------------------------------------------------------------------------
-- Visibility and RLS: venue administrators and appointees, and anyone who can see a
-- permit the control protects.
-- ---------------------------------------------------------------------------
create or replace function authz.visible_work_package_ids() returns setof uuid
language sql stable security definer
set search_path = ''
as $$
  select wp.id from core.work_package wp
   where wp.customer_id in (select authz.my_admin_customer_ids())
      or exists (select 1 from unnest(array['screening.decide', 'external_reference.decide', 'work_package.require_class',
                                            'permit_step.decide', 'permit_step.decide_occupier', 'permit_step.decide_landlord',
                                            'permit_step.record_external', 'permit.issue', 'permit.exception_decide',
                                            'permit.stop_as_authority', 'permit.stop_area', 'permit.lift_area_stop',
                                            'permit.lift_suspension', 'permit.extend', 'permit.approve_worker',
                                            'permit.exclude_worker_as_authority', 'permit.change_supervisor',
                                            'isolation.authorise', 'isolation.apply', 'isolation.prove', 'isolation.remove',
                                            'impairment.authorise', 'impairment.impair', 'impairment.test', 'impairment.restore',
                                            'control.lift_failure', 'custody.issue']) a
                  where wp.venue_id in (select authz.my_action_venue_ids(a)))
      or exists (select 1 from core.permit p join core.permit_team_member m on m.permit_id = p.id
                  where p.work_package_id = wp.id and m.removed_at is null and m.person_id in (select authz.my_person_ids()))
      or wp.performing_organisation_id in (select authz.my_admin_organisation_ids())
      or exists (select 1 from core.work_package_revision r
                   join core.work_package_party p on p.revision_id = r.id
                  where r.work_package_id = wp.id
                    and p.organisation_id in (select authz.my_admin_organisation_ids()))
      or exists (select 1 from core.work_package_revision r
                  where r.work_package_id = wp.id
                    and (r.contact_person_id in (select authz.my_person_ids())
                         or r.supervisor_person_id in (select authz.my_person_ids())))
$$;

grant select on core.system_control_rule, core.isolation, core.impairment, core.control_link, core.control_event, core.isolation_lock,
                core.fire_watch, core.exclusion_zone, core.custody_item, core.custody_movement, core.control_failure,
                core.control_failure_resolution to authenticated;

create policy venue_scoped_read on core.system_control_rule for select to authenticated using (venue_id in (select authz.my_venue_ids()));
create policy isolation_read on core.isolation for select to authenticated
  using (customer_id in (select authz.my_admin_customer_ids()) or venue_id in (select authz.my_appointee_venue_ids())
         or id in (select l.control_id from core.control_link l where l.control_kind = 'isolation' and l.permit_id in (select authz.visible_permit_ids())));
create policy impairment_read on core.impairment for select to authenticated
  using (customer_id in (select authz.my_admin_customer_ids()) or venue_id in (select authz.my_appointee_venue_ids())
         or id in (select l.control_id from core.control_link l where l.control_kind = 'impairment' and l.permit_id in (select authz.visible_permit_ids())));
create policy control_link_read on core.control_link for select to authenticated
  using (customer_id in (select authz.my_admin_customer_ids()) or venue_id in (select authz.my_appointee_venue_ids())
         or permit_id in (select authz.visible_permit_ids()));
create policy fire_watch_read on core.fire_watch for select to authenticated
  using (customer_id in (select authz.my_admin_customer_ids()) or venue_id in (select authz.my_appointee_venue_ids())
         or permit_id in (select authz.visible_permit_ids()));
create policy exclusion_zone_read on core.exclusion_zone for select to authenticated
  using (customer_id in (select authz.my_admin_customer_ids()) or venue_id in (select authz.my_appointee_venue_ids())
         or permit_id in (select authz.visible_permit_ids()));
create policy control_event_read on core.control_event for select to authenticated
  using ((control_kind = 'isolation' and control_id in (select id from core.isolation))
         or (control_kind = 'impairment' and control_id in (select id from core.impairment))
         or (control_kind = 'fire_watch' and control_id in (select id from core.fire_watch))
         or (control_kind = 'exclusion_zone' and control_id in (select id from core.exclusion_zone)));
create policy isolation_lock_read on core.isolation_lock for select to authenticated
  using (isolation_id in (select id from core.isolation));
create policy custody_item_read on core.custody_item for select to authenticated
  using (customer_id in (select authz.my_admin_customer_ids()) or venue_id in (select authz.my_appointee_venue_ids())
         or id in (select m.item_id from core.custody_movement m where m.permit_id in (select authz.visible_permit_ids())));
create policy custody_movement_read on core.custody_movement for select to authenticated
  using (customer_id in (select authz.my_admin_customer_ids()) or venue_id in (select authz.my_appointee_venue_ids())
         or permit_id in (select authz.visible_permit_ids()));
create policy control_failure_read on core.control_failure for select to authenticated
  using ((control_kind = 'isolation' and control_id in (select id from core.isolation))
         or (control_kind = 'impairment' and control_id in (select id from core.impairment)));
create policy control_failure_resolution_read on core.control_failure_resolution for select to authenticated
  using (failure_id in (select id from core.control_failure));
