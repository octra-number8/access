-- 0007 Permit class stub and appointment types (venue configuration)
--
-- Appointment types are safety-relevant configuration: versioned, with an owner,
-- an effective date and a reason. Versions are immutable. Holding a type grants
-- nothing; only an appointment instance does.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

-- Minimal stub so appointments can name classes; full class configuration arrives
-- in build phase 5. No classes are seeded: the launch list is still Proposed (Q233).
create table core.permit_class (
  id                 uuid primary key default gen_random_uuid(),
  customer_id        uuid not null,
  venue_id           uuid not null,
  code               text not null check (code ~ '^[A-Za-z0-9_-]{1,40}$'),
  name               text not null check (length(btrim(name)) > 0),
  retired_at         timestamptz,
  row_version        integer not null default 1,
  created_at         timestamptz not null default now(),
  created_by_user_id uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  unique (customer_id, venue_id, id),
  unique (venue_id, code)
);
select core.attach_standard_triggers('core.permit_class', 'name,retired_at');

create table core.appointment_type (
  id                 uuid primary key default gen_random_uuid(),
  customer_id        uuid not null,
  venue_id           uuid not null,
  code               text not null check (code ~ '^[A-Za-z0-9_-]{1,40}$'),
  name               text not null check (length(btrim(name)) > 0),
  retired_at         timestamptz,
  row_version        integer not null default 1,
  created_at         timestamptz not null default now(),
  created_by_user_id uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  unique (customer_id, venue_id, id),
  unique (venue_id, code)
);
select core.attach_standard_triggers('core.appointment_type', 'name,retired_at');

create table core.appointment_type_version (
  id                           uuid primary key default gen_random_uuid(),
  customer_id                  uuid not null,
  venue_id                     uuid not null,
  appointment_type_id          uuid not null,
  version_no                   integer not null check (version_no > 0),
  allowed_action_codes         text[] not null check (cardinality(allowed_action_codes) > 0),
  eligible_permit_class_ids    uuid[] not null default '{}',
  eligible_system_type_ids     uuid[] not null default '{}',
  -- Which appointment types a holder of this type may appoint (e.g. an Authorised
  -- Person may appoint Competent Persons). Scope, classes and window may never widen.
  grantable_type_ids           uuid[] not null default '{}',
  is_root_eligible             boolean not null default false,
  requires_competence_evidence boolean not null,
  owner_person_id              uuid not null,
  effective_from               timestamptz not null,
  change_reason                text not null check (length(btrim(change_reason)) > 0),
  row_version                  integer not null default 1,
  created_at                   timestamptz not null default now(),
  created_by_user_id           uuid default auth.uid(),
  foreign key (customer_id, venue_id, appointment_type_id) references core.appointment_type (customer_id, venue_id, id),
  foreign key (customer_id, owner_person_id) references core.person (customer_id, id),
  unique (appointment_type_id, version_no),
  unique (customer_id, venue_id, id)
);

create function core.appointment_type_version_validate() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_bad text;
begin
  select string_agg(c, ', ') into v_bad
    from unnest(new.allowed_action_codes) c
   where not exists (select 1 from core.authority_action a where a.code = c and a.basis = 'appointment');
  if v_bad is not null then
    raise exception 'not an appointment-based action: %', v_bad using errcode = 'check_violation';
  end if;
  if exists (select 1 from unnest(new.eligible_permit_class_ids) x
              where not exists (select 1 from core.permit_class p where p.id = x and p.venue_id = new.venue_id)) then
    raise exception 'eligible permit classes must belong to this venue' using errcode = 'check_violation';
  end if;
  if exists (select 1 from unnest(new.eligible_system_type_ids) x
              where not exists (select 1 from core.system_type s where s.id = x and s.venue_id = new.venue_id)) then
    raise exception 'eligible system types must belong to this venue' using errcode = 'check_violation';
  end if;
  if exists (select 1 from unnest(new.grantable_type_ids) x
              where not exists (select 1 from core.appointment_type t where t.id = x and t.venue_id = new.venue_id)) then
    raise exception 'grantable appointment types must belong to this venue' using errcode = 'check_violation';
  end if;
  if exists (select 1 from core.appointment_type_version v
              where v.appointment_type_id = new.appointment_type_id
                and v.effective_from >= new.effective_from) then
    raise exception 'a new version must take effect after the previous one' using errcode = 'check_violation';
  end if;
  new.version_no := coalesce((select max(version_no) from core.appointment_type_version
                               where appointment_type_id = new.appointment_type_id), 0) + 1;
  return new;
end $$;
create trigger appointment_type_version_validate before insert on core.appointment_type_version
  for each row execute function core.appointment_type_version_validate();
select core.attach_standard_triggers('core.appointment_type_version', null);
