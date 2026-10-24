-- 0005 Area hierarchy and building systems (D-008)
--
-- An area's parent and venue never change: re-parenting would silently widen or
-- narrow every appointment scoped to it. Restructure by retiring and creating.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

create table core.area_kind (
  id                 uuid primary key default gen_random_uuid(),
  customer_id        uuid not null,
  venue_id           uuid not null,
  code               text not null check (code ~ '^[A-Za-z0-9_-]{1,40}$'),
  label              text not null check (length(btrim(label)) > 0),
  retired_at         timestamptz,
  row_version        integer not null default 1,
  created_at         timestamptz not null default now(),
  created_by_user_id uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  unique (venue_id, code),
  unique (venue_id, id)
);
select core.attach_standard_triggers('core.area_kind', 'label,retired_at');

create table core.area (
  id                 uuid primary key default gen_random_uuid(),
  customer_id        uuid not null,
  venue_id           uuid not null,
  parent_id          uuid,
  area_kind_id       uuid,
  code               text not null check (code ~ '^[A-Za-z0-9_-]{1,40}$'),
  name               text not null check (length(btrim(name)) > 0),
  path               uuid[] not null,   -- ancestors from the root, ending with this area
  retired_at         timestamptz,
  row_version        integer not null default 1,
  created_at         timestamptz not null default now(),
  created_by_user_id uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, venue_id, parent_id) references core.area (customer_id, venue_id, id),
  foreign key (venue_id, area_kind_id) references core.area_kind (venue_id, id),
  unique (customer_id, venue_id, id),
  unique (venue_id, code),
  -- The venue's root area is created with the venue and has no kind.
  check ((parent_id is null) = (area_kind_id is null))
);
create unique index area_one_root_per_venue on core.area (venue_id) where parent_id is null;
create index area_path_gin on core.area using gin (path);

create function core.area_set_path() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_parent core.area;
begin
  if new.parent_id is null then
    new.path := array[new.id];
  else
    select * into v_parent from core.area where id = new.parent_id;
    if v_parent.retired_at is not null then
      raise exception 'cannot add an area under a retired area' using errcode = 'check_violation';
    end if;
    new.path := v_parent.path || new.id;
  end if;
  return new;
end $$;

create trigger area_set_path before insert on core.area
  for each row execute function core.area_set_path();
select core.attach_standard_triggers('core.area', 'name,retired_at');

create table core.system_type (
  id                 uuid primary key default gen_random_uuid(),
  customer_id        uuid not null,
  venue_id           uuid not null,
  code               text not null check (code ~ '^[A-Za-z0-9_-]{1,40}$'),
  label              text not null check (length(btrim(label)) > 0),
  retired_at         timestamptz,
  row_version        integer not null default 1,
  created_at         timestamptz not null default now(),
  created_by_user_id uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  unique (venue_id, code),
  unique (venue_id, id)
);
select core.attach_standard_triggers('core.system_type', 'label,retired_at');

create table core.system (
  id                 uuid primary key default gen_random_uuid(),
  customer_id        uuid not null,
  venue_id           uuid not null,
  system_type_id     uuid not null,
  code               text not null check (code ~ '^[A-Za-z0-9_-]{1,40}$'),
  name               text not null check (length(btrim(name)) > 0),
  description        text,
  retired_at         timestamptz,
  row_version        integer not null default 1,
  created_at         timestamptz not null default now(),
  created_by_user_id uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (venue_id, system_type_id) references core.system_type (venue_id, id),
  unique (customer_id, venue_id, id),
  unique (venue_id, code)
);
select core.attach_standard_triggers('core.system', 'name,description,retired_at');

-- Which areas a system serves. Append-only in phase 1.
create table core.system_area (
  id                 uuid primary key default gen_random_uuid(),
  customer_id        uuid not null,
  venue_id           uuid not null,
  system_id          uuid not null,
  area_id            uuid not null,
  valid_during       tstzrange not null default tstzrange(now(), null),
  row_version        integer not null default 1,
  created_at         timestamptz not null default now(),
  created_by_user_id uuid default auth.uid(),
  foreign key (customer_id, venue_id, system_id) references core.system (customer_id, venue_id, id),
  foreign key (customer_id, venue_id, area_id) references core.area (customer_id, venue_id, id),
  exclude using gist (system_id with =, area_id with =, valid_during with &&)
);
select core.attach_standard_triggers('core.system_area', null);
