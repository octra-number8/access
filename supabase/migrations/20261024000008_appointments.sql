-- 0008 Appointments, scopes, evidence and delegations
--
-- Appointments are immutable once recorded; only lifecycle columns change, and
-- only inside core.transition(). Validity is derived at read time from status and
-- valid_during; nothing flips a stored flag when time passes.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

create table core.appointment (
  id                             uuid primary key default gen_random_uuid(),
  customer_id                    uuid not null,
  venue_id                       uuid not null,
  appointee_person_id            uuid not null,
  appointment_type_version_id    uuid not null,
  appointed_by_person_id         uuid not null,
  appointed_under_appointment_id uuid,
  is_root                        boolean not null,
  limitations_text               text,
  valid_during                   tstzrange not null check (not lower_inf(valid_during) and not isempty(valid_during)),
  review_due_on                  date,
  status                         text not null,
  recorded_by_person_id          uuid,      -- tenant admin who recorded a root appointment
  root_evidence_ref              text,      -- letter of appointment (D-002)
  confirmed_by_person_id         uuid,
  confirmed_at                   timestamptz,
  acknowledged_at                timestamptz,
  revoked_at                     timestamptz,
  revoked_by_person_id           uuid,
  revoked_reason                 text,
  revocation_evidence_ref        text,
  supersedes_id                  uuid references core.appointment,
  row_version                    integer not null default 1,
  created_at                     timestamptz not null default now(),
  created_by_user_id             uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, venue_id, appointment_type_version_id)
    references core.appointment_type_version (customer_id, venue_id, id),
  foreign key (customer_id, appointee_person_id) references core.person (customer_id, id),
  foreign key (customer_id, appointed_by_person_id) references core.person (customer_id, id),
  foreign key (customer_id, recorded_by_person_id) references core.person (customer_id, id),
  foreign key (customer_id, confirmed_by_person_id) references core.person (customer_id, id),
  foreign key (customer_id, revoked_by_person_id) references core.person (customer_id, id),
  unique (customer_id, venue_id, id),
  -- Separation-of-duties floor (D-007): nobody appoints themselves.
  check (appointee_person_id <> appointed_by_person_id),
  check (is_root = (appointed_under_appointment_id is null)),
  check (not is_root or (recorded_by_person_id is not null and root_evidence_ref is not null)),
  check (confirmed_by_person_id is null
         or (confirmed_by_person_id <> appointee_person_id
             and confirmed_by_person_id is distinct from recorded_by_person_id)),
  check ((status = 'revoked') = (revoked_at is not null))
);
alter table core.appointment
  add foreign key (customer_id, venue_id, appointed_under_appointment_id)
  references core.appointment (customer_id, venue_id, id);
select core.attach_standard_triggers('core.appointment',
  'status,confirmed_by_person_id,confirmed_at,acknowledged_at,revoked_at,revoked_by_person_id,revoked_reason,revocation_evidence_ref',
  'transition', true);

-- Restricted visibility: appointee, appointer and tenant administrators only.
create table core.appointment_evidence (
  id                      uuid primary key default gen_random_uuid(),
  customer_id             uuid not null,
  venue_id                uuid not null,
  appointment_id          uuid not null unique,
  competence_evidence_ref text not null check (length(btrim(competence_evidence_ref)) > 0),
  row_version             integer not null default 1,
  created_at              timestamptz not null default now(),
  created_by_user_id      uuid default auth.uid(),
  foreign key (customer_id, venue_id, appointment_id) references core.appointment (customer_id, venue_id, id)
);
select core.attach_standard_triggers('core.appointment_evidence', null);

create table core.appointment_permit_class (
  id                 uuid primary key default gen_random_uuid(),
  customer_id        uuid not null,
  venue_id           uuid not null,
  appointment_id     uuid not null,
  permit_class_id    uuid not null,
  row_version        integer not null default 1,
  created_at         timestamptz not null default now(),
  created_by_user_id uuid default auth.uid(),
  foreign key (customer_id, venue_id, appointment_id) references core.appointment (customer_id, venue_id, id),
  foreign key (customer_id, venue_id, permit_class_id) references core.permit_class (customer_id, venue_id, id),
  unique (appointment_id, permit_class_id)
);
select core.attach_standard_triggers('core.appointment_permit_class', null);

-- One row per scope item (D-008). Exactly one of:
--   area_id         that area, and everything beneath it when include_descendants
--   system_id       that system, optionally only within restrict_to_area_id
--   system_type_id  every system of that type, optionally only within restrict_to_area_id
create table core.appointment_scope (
  id                  uuid primary key default gen_random_uuid(),
  customer_id         uuid not null,
  venue_id            uuid not null,
  appointment_id      uuid not null,
  area_id             uuid,
  include_descendants boolean not null default true,
  system_id           uuid,
  system_type_id      uuid,
  restrict_to_area_id uuid,
  row_version         integer not null default 1,
  created_at          timestamptz not null default now(),
  created_by_user_id  uuid default auth.uid(),
  foreign key (customer_id, venue_id, appointment_id) references core.appointment (customer_id, venue_id, id),
  foreign key (customer_id, venue_id, area_id) references core.area (customer_id, venue_id, id),
  foreign key (customer_id, venue_id, system_id) references core.system (customer_id, venue_id, id),
  foreign key (venue_id, system_type_id) references core.system_type (venue_id, id),
  foreign key (customer_id, venue_id, restrict_to_area_id) references core.area (customer_id, venue_id, id),
  check (num_nonnulls(area_id, system_id, system_type_id) = 1),
  check (area_id is null or restrict_to_area_id is null)
);
select core.attach_standard_triggers('core.appointment_scope', null);

create table core.delegation (
  id                       uuid primary key default gen_random_uuid(),
  customer_id              uuid not null,
  venue_id                 uuid not null,
  delegator_person_id      uuid not null,
  delegator_appointment_id uuid not null,
  delegate_person_id       uuid not null,
  delegate_appointment_id  uuid not null,
  action_codes             text[] not null check (cardinality(action_codes) > 0),
  permit_class_ids         uuid[] not null default '{}',
  target_type              text,
  target_id                uuid,
  valid_during             tstzrange not null check (not lower_inf(valid_during) and not upper_inf(valid_during)),
  reason                   text not null check (length(btrim(reason)) > 0),
  status                   text not null,
  revoked_at               timestamptz,
  revoked_by_person_id     uuid,
  revoked_reason           text,
  row_version              integer not null default 1,
  created_at               timestamptz not null default now(),
  created_by_user_id       uuid default auth.uid(),
  foreign key (customer_id, venue_id, delegator_appointment_id) references core.appointment (customer_id, venue_id, id),
  foreign key (customer_id, venue_id, delegate_appointment_id) references core.appointment (customer_id, venue_id, id),
  foreign key (customer_id, delegator_person_id) references core.person (customer_id, id),
  foreign key (customer_id, delegate_person_id) references core.person (customer_id, id),
  foreign key (customer_id, revoked_by_person_id) references core.person (customer_id, id),
  unique (customer_id, venue_id, id),
  check (delegator_person_id <> delegate_person_id),
  check (delegator_appointment_id <> delegate_appointment_id),
  check ((target_type is null) = (target_id is null)),
  check ((status = 'revoked') = (revoked_at is not null))
);
select core.attach_standard_triggers('core.delegation',
  'status,revoked_at,revoked_by_person_id,revoked_reason', 'transition', true);

create table core.delegation_scope (
  id                  uuid primary key default gen_random_uuid(),
  customer_id         uuid not null,
  venue_id            uuid not null,
  delegation_id       uuid not null,
  area_id             uuid,
  include_descendants boolean not null default true,
  system_id           uuid,
  system_type_id      uuid,
  restrict_to_area_id uuid,
  row_version         integer not null default 1,
  created_at          timestamptz not null default now(),
  created_by_user_id  uuid default auth.uid(),
  foreign key (customer_id, venue_id, delegation_id) references core.delegation (customer_id, venue_id, id),
  foreign key (customer_id, venue_id, area_id) references core.area (customer_id, venue_id, id),
  foreign key (customer_id, venue_id, system_id) references core.system (customer_id, venue_id, id),
  foreign key (venue_id, system_type_id) references core.system_type (venue_id, id),
  foreign key (customer_id, venue_id, restrict_to_area_id) references core.area (customer_id, venue_id, id),
  check (num_nonnulls(area_id, system_id, system_type_id) = 1),
  check (area_id is null or restrict_to_area_id is null)
);
select core.attach_standard_triggers('core.delegation_scope', null);

-- Checked at commit, once the appointment and its child rows all exist.
create function core.appointment_complete() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_type core.appointment_type_version;
begin
  select * into v_type from core.appointment_type_version where id = new.appointment_type_version_id;
  if v_type.effective_from > now() or exists (
       select 1 from core.appointment_type_version later
        where later.appointment_type_id = v_type.appointment_type_id
          and later.effective_from > v_type.effective_from
          and later.effective_from <= now()) then
    raise exception 'an appointment must use the appointment type version currently in force'
      using errcode = 'check_violation';
  end if;
  if not exists (select 1 from core.appointment_scope where appointment_id = new.id) then
    raise exception 'an appointment needs at least one area or system scope' using errcode = 'check_violation';
  end if;
  if exists (select 1 from core.appointment_permit_class c
              where c.appointment_id = new.id and c.permit_class_id <> all (v_type.eligible_permit_class_ids)) then
    raise exception 'appointment names a permit class its type does not allow' using errcode = 'check_violation';
  end if;
  if exists (select 1 from core.appointment_scope s
               left join core.system sy on sy.id = s.system_id
              where s.appointment_id = new.id
                and coalesce(s.system_type_id, sy.system_type_id) is not null
                and coalesce(s.system_type_id, sy.system_type_id) <> all (v_type.eligible_system_type_ids)) then
    raise exception 'appointment names a system type its type does not allow' using errcode = 'check_violation';
  end if;
  if v_type.requires_competence_evidence
     and not exists (select 1 from core.appointment_evidence where appointment_id = new.id) then
    raise exception 'this appointment type requires a competence evidence reference' using errcode = 'check_violation';
  end if;
  if new.is_root and not v_type.is_root_eligible then
    raise exception 'this appointment type cannot be used for a root appointment' using errcode = 'check_violation';
  end if;
  return null;
end $$;
create constraint trigger appointment_complete
  after insert on core.appointment
  deferrable initially deferred
  for each row execute function core.appointment_complete();

create function core.delegation_complete() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (select 1 from core.delegation_scope where delegation_id = new.id) then
    raise exception 'a delegation needs at least one area or system scope' using errcode = 'check_violation';
  end if;
  return null;
end $$;
create constraint trigger delegation_complete
  after insert on core.delegation
  deferrable initially deferred
  for each row execute function core.delegation_complete();

-- Retiring an area that an in-force or pending scope relies on is refused.
create function core.area_retire_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.retired_at is not null and old.retired_at is null and exists (
       select 1 from core.appointment_scope s
         join core.appointment a on a.id = s.appointment_id
        where (s.area_id = new.id or s.restrict_to_area_id = new.id)
          and a.status <> 'revoked'
          and (upper_inf(a.valid_during) or upper(a.valid_during) > now())
     union all
       select 1 from core.delegation_scope s
         join core.delegation d on d.id = s.delegation_id
        where (s.area_id = new.id or s.restrict_to_area_id = new.id)
          and d.status <> 'revoked' and upper(d.valid_during) > now()
     union all
       select 1 from core.area c where c.parent_id = new.id and c.retired_at is null) then
    raise exception 'this area is still relied on by a current appointment, delegation or child area'
      using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger area_retire_guard before update of retired_at on core.area
  for each row execute function core.area_retire_guard();
