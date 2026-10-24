-- 0006 Organisations, people, logins, relationships, engagements, tenant admins,
--      system ownership
--
-- Identity is per customer for the pilot (D-006). Nothing is shared across tenants.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

create table core.organisation (
  id                 uuid primary key default gen_random_uuid(),
  customer_id        uuid not null references core.customer,
  legal_name         text not null check (length(btrim(legal_name)) > 0),
  trading_name       text,
  company_number     text,
  deactivated_at     timestamptz,
  row_version        integer not null default 1,
  created_at         timestamptz not null default now(),
  created_by_user_id uuid default auth.uid(),
  unique (customer_id, id)
);
create unique index organisation_company_number_uq
  on core.organisation (customer_id, company_number) where company_number is not null;
select core.attach_standard_triggers('core.organisation', 'legal_name,trading_name,deactivated_at');

create table core.person (
  id                 uuid primary key default gen_random_uuid(),
  customer_id        uuid not null references core.customer,
  given_name         text not null check (length(btrim(given_name)) > 0),
  family_name        text not null check (length(btrim(family_name)) > 0),
  preferred_name     text,
  preferred_language text,
  deactivated_at     timestamptz,
  row_version        integer not null default 1,
  created_at         timestamptz not null default now(),
  created_by_user_id uuid default auth.uid(),
  unique (customer_id, id)
);
select core.attach_standard_triggers('core.person',
  'given_name,family_name,preferred_name,preferred_language,deactivated_at');

-- Kept apart from person so RLS can withhold contact details (gate, peers, support).
create table core.person_contact (
  id                 uuid primary key default gen_random_uuid(),
  customer_id        uuid not null,
  person_id          uuid not null unique,
  email              text,
  phone              text,
  row_version        integer not null default 1,
  created_at         timestamptz not null default now(),
  created_by_user_id uuid default auth.uid(),
  foreign key (customer_id, person_id) references core.person (customer_id, id)
);
select core.attach_standard_triggers('core.person_contact', 'email,phone', null, false, 'email,phone');

-- A person is not a login. One login may link to people in several customers.
create table core.user_account (
  id                 uuid primary key default gen_random_uuid(),
  customer_id        uuid not null,
  person_id          uuid not null,
  auth_user_id       uuid not null references auth.users (id),
  disabled_at        timestamptz,
  row_version        integer not null default 1,
  created_at         timestamptz not null default now(),
  created_by_user_id uuid default auth.uid(),
  foreign key (customer_id, person_id) references core.person (customer_id, id)
);
create unique index user_account_login_per_customer_uq
  on core.user_account (auth_user_id, customer_id) where disabled_at is null;
create unique index user_account_person_uq
  on core.user_account (person_id) where disabled_at is null;
select core.attach_standard_triggers('core.user_account', 'disabled_at');

create table core.person_organisation_relationship (
  id                                   uuid primary key default gen_random_uuid(),
  customer_id                          uuid not null,
  person_id                            uuid not null,
  organisation_id                      uuid not null,
  kind                                 text not null check (kind in
                                         ('employee', 'agency', 'self_employed', 'volunteer',
                                          'subcontractor', 'exhibitor')),
  valid_during                         tstzrange not null check (not lower_inf(valid_during)),
  supervisor_person_id                 uuid,
  evidence_responsible_organisation_id uuid,
  revoked_at                           timestamptz,
  row_version                          integer not null default 1,
  created_at                           timestamptz not null default now(),
  created_by_user_id                   uuid default auth.uid(),
  foreign key (customer_id, person_id) references core.person (customer_id, id),
  foreign key (customer_id, organisation_id) references core.organisation (customer_id, id),
  foreign key (customer_id, supervisor_person_id) references core.person (customer_id, id),
  foreign key (customer_id, evidence_responsible_organisation_id) references core.organisation (customer_id, id),
  check (supervisor_person_id is distinct from person_id)
);
select core.attach_standard_triggers('core.person_organisation_relationship', 'revoked_at');

-- Engagement capacity drives product behaviour, so it is product-seeded, not venue config.
create table core.engagement_capacity (
  code  text primary key,
  label text not null
);
insert into core.engagement_capacity (code, label) values
  ('occupier',              'Occupier'),
  ('performing_contractor', 'Performing contractor'),
  ('principal_contractor',  'Principal contractor'),
  ('service_provider',      'Service provider'),
  ('promoter',              'Promoter'),
  ('exhibitor',             'Exhibitor');
alter table core.engagement_capacity enable row level security;
alter table core.engagement_capacity force row level security;
create trigger forbid_change before update or delete on core.engagement_capacity
  for each row execute function audit.forbid_change();

create table core.engagement (
  id                              uuid primary key default gen_random_uuid(),
  customer_id                     uuid not null,
  venue_id                        uuid not null,
  organisation_id                 uuid not null,
  capacity_code                   text not null references core.engagement_capacity,
  valid_during                    tstzrange not null check (not lower_inf(valid_during)),
  engaged_via_organisation_id     uuid,
  accountable_admin_person_id     uuid,
  status                          text not null,
  suspended_by_decision_context_id uuid,
  suspension_reason               text,
  ended_at                        timestamptz,
  end_reason                      text,
  row_version                     integer not null default 1,
  created_at                      timestamptz not null default now(),
  created_by_user_id              uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, organisation_id) references core.organisation (customer_id, id),
  foreign key (customer_id, engaged_via_organisation_id) references core.organisation (customer_id, id),
  foreign key (customer_id, accountable_admin_person_id) references core.person (customer_id, id),
  check (engaged_via_organisation_id is distinct from organisation_id),
  check ((status = 'suspended') = (suspended_by_decision_context_id is not null))
);
select core.attach_standard_triggers('core.engagement',
  'status,suspended_by_decision_context_id,suspension_reason,ended_at,end_reason', 'transition', true);

-- A new engagement must not sidestep a suspension of the same organisation at the venue.
create function core.engagement_not_while_suspended() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if exists (select 1 from core.engagement
              where organisation_id = new.organisation_id
                and venue_id = new.venue_id
                and status = 'suspended') then
    raise exception 'this organisation has a suspended engagement at this venue; it must be reinstated by the restriction''s owner first'
      using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger engagement_not_while_suspended before insert on core.engagement
  for each row execute function core.engagement_not_while_suspended();

-- Administration only; grants no operational authority (invariant 9).
create table core.tenant_admin (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  person_id            uuid not null,
  valid_during         tstzrange not null default tstzrange(now(), null),
  granted_by_person_id uuid,
  revoked_at           timestamptz,
  row_version          integer not null default 1,
  created_at           timestamptz not null default now(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, person_id) references core.person (customer_id, id),
  foreign key (customer_id, granted_by_person_id) references core.person (customer_id, id)
);
create unique index tenant_admin_current_uq on core.tenant_admin (customer_id, person_id) where revoked_at is null;
select core.attach_standard_triggers('core.tenant_admin', 'revoked_at');

-- A register of responsibility. It routes decisions later (Q9) but grants nothing.
create table core.system_ownership (
  id                 uuid primary key default gen_random_uuid(),
  customer_id        uuid not null,
  venue_id           uuid not null,
  system_id          uuid not null,
  organisation_id    uuid not null,
  engagement_id      uuid references core.engagement,
  responsibility     text not null check (responsibility in ('owner', 'maintainer', 'operator', 'monitoring')),
  valid_during       tstzrange not null check (not lower_inf(valid_during)),
  evidence_ref       text,
  revoked_at         timestamptz,
  row_version        integer not null default 1,
  created_at         timestamptz not null default now(),
  created_by_user_id uuid default auth.uid(),
  foreign key (customer_id, venue_id, system_id) references core.system (customer_id, venue_id, id),
  foreign key (customer_id, organisation_id) references core.organisation (customer_id, id)
);
select core.attach_standard_triggers('core.system_ownership', 'revoked_at');
