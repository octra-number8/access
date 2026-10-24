-- 0015 Documents, review, competencies, verification and evidence requirements
--      (Q36–Q39, D-012)
--
-- Evidence is immutable: a change is a new version, and a review or verification
-- is its own record. Nothing here stores a person- or organisation-level status.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

create table core.document_type (
  id                 uuid primary key default gen_random_uuid(),
  customer_id        uuid not null,
  venue_id           uuid not null,
  code               text not null check (code ~ '^[A-Za-z0-9_-]{1,40}$'),
  label              text not null check (length(btrim(label)) > 0),
  owner_level        text not null check (owner_level in ('organisation', 'person')),
  retired_at         timestamptz,
  row_version        integer not null default 1,
  created_at         timestamptz not null default now(),
  created_by_user_id uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  unique (venue_id, code),
  unique (customer_id, venue_id, id)
);
select core.attach_standard_triggers('core.document_type', 'label,retired_at');

-- Declared criteria a reviewer applies (Q37). Safety-relevant: versioned.
create table core.review_criteria_version (
  id                 uuid primary key default gen_random_uuid(),
  customer_id        uuid not null,
  venue_id           uuid not null,
  document_type_id   uuid not null,
  version_no         integer not null check (version_no > 0),
  criteria           jsonb not null check (jsonb_typeof(criteria) = 'array' and jsonb_array_length(criteria) > 0),
  owner_person_id    uuid not null,
  effective_from     timestamptz not null,
  change_reason      text not null check (length(btrim(change_reason)) > 0),
  row_version        integer not null default 1,
  created_at         timestamptz not null default now(),
  created_by_user_id uuid default auth.uid(),
  foreign key (customer_id, venue_id, document_type_id) references core.document_type (customer_id, venue_id, id),
  foreign key (customer_id, owner_person_id) references core.person (customer_id, id),
  unique (document_type_id, version_no),
  unique (customer_id, venue_id, id)
);
select core.attach_standard_triggers('core.review_criteria_version', null);

create table core.document (
  id                           uuid primary key default gen_random_uuid(),
  customer_id                  uuid not null,
  venue_id                     uuid not null,
  document_type_id             uuid not null,
  owner_kind                   text not null check (owner_kind in ('organisation', 'person')),
  organisation_id              uuid,
  person_id                    uuid,
  -- For person documents submitted by an organisation administrator: that
  -- organisation sees it while the person remains active with it. Self-provided
  -- person documents are not shared with any organisation (Q30, Q220).
  provided_via_organisation_id uuid,
  title                        text not null check (length(btrim(title)) > 0),
  row_version                  integer not null default 1,
  created_at                   timestamptz not null default now(),
  created_by_user_id           uuid default auth.uid(),
  foreign key (customer_id, venue_id, document_type_id) references core.document_type (customer_id, venue_id, id),
  foreign key (customer_id, organisation_id) references core.organisation (customer_id, id),
  foreign key (customer_id, person_id) references core.person (customer_id, id),
  foreign key (customer_id, provided_via_organisation_id) references core.organisation (customer_id, id),
  check ((owner_kind = 'organisation') = (organisation_id is not null)),
  check ((owner_kind = 'person') = (person_id is not null)),
  check (owner_kind = 'person' or provided_via_organisation_id is null),
  unique (customer_id, id)
);
select core.attach_standard_triggers('core.document', null);

create function core.document_owner_level_matches() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (select owner_level from core.document_type where id = new.document_type_id) <> new.owner_kind then
    raise exception 'this document type belongs to a different owner level' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger document_owner_level_matches before insert on core.document
  for each row execute function core.document_owner_level_matches();

-- Platform file limits (P2-6): PDF, JPEG, PNG; at most 20 MB.
create table core.document_version (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  document_id           uuid not null,
  version_no            integer not null check (version_no > 0),
  storage_path          text not null unique check (storage_path ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}$'),
  sha256                bytea not null check (length(sha256) = 32),
  media_type            text not null check (media_type in ('application/pdf', 'image/jpeg', 'image/png')),
  size_bytes            bigint not null check (size_bytes between 1 and 20971520),
  issuer                text,
  reference             text,
  valid_from            date,
  expires_on            date,
  uploaded_by_person_id uuid not null,
  scan_status           text not null default 'pending' check (scan_status in ('pending', 'clean', 'infected')),
  scanned_at            timestamptz,
  scan_engine           text,
  scan_detail           text,
  row_version           integer not null default 1,
  created_at            timestamptz not null default now(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, document_id) references core.document (customer_id, id),
  foreign key (customer_id, uploaded_by_person_id) references core.person (customer_id, id),
  unique (document_id, version_no),
  unique (customer_id, id),
  check (expires_on is null or valid_from is null or expires_on >= valid_from),
  check ((scan_status = 'pending') = (scanned_at is null))
);
select core.attach_standard_triggers('core.document_version', 'scan_status,scanned_at,scan_engine,scan_detail');

create function core.scan_once() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.scan_status is distinct from old.scan_status and old.scan_status <> 'pending' then
    raise exception 'a scan result is recorded once' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger scan_once before update on core.document_version
  for each row execute function core.scan_once();

-- Q37: the reviewer decides against declared criteria, for a stated scope.
-- The wording may never claim approval, certification, verification or compliance.
create table core.review_decision (
  id                         uuid primary key default gen_random_uuid(),
  customer_id                uuid not null,
  venue_id                   uuid not null,
  document_version_id        uuid not null,
  review_criteria_version_id uuid not null,
  reviewer_person_id         uuid not null,
  decision_context_id        uuid not null references core.decision_context,
  outcome                    text not null check (outcome in
                               ('reviewed_no_further_comments', 'more_information_required', 'not_accepted')),
  criteria_results           jsonb not null check (jsonb_typeof(criteria_results) = 'object'),
  conditions                 text,
  scope_wording              text not null check (length(btrim(scope_wording)) > 0
                               and scope_wording !~* '(approv|certif|verif|guarant|complian|safe to)'),
  row_version                integer not null default 1,
  created_at                 timestamptz not null default now(),
  created_by_user_id         uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, document_version_id) references core.document_version (customer_id, id),
  foreign key (customer_id, venue_id, review_criteria_version_id) references core.review_criteria_version (customer_id, venue_id, id),
  foreign key (customer_id, reviewer_person_id) references core.person (customer_id, id)
);
select core.attach_standard_triggers('core.review_decision', null);

create table core.competency_type (
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
  unique (customer_id, venue_id, id)
);
select core.attach_standard_triggers('core.competency_type', 'label,retired_at');

-- A declaration. Changing it means declaring again; the earlier one remains.
create table core.competency (
  id                           uuid primary key default gen_random_uuid(),
  customer_id                  uuid not null,
  venue_id                     uuid not null,
  person_id                    uuid not null,
  competency_type_id           uuid not null,
  issuer                       text not null check (length(btrim(issuer)) > 0),
  number                       text,
  expires_on                   date,
  document_version_id          uuid,
  declared_by_person_id        uuid not null,
  declared_via_organisation_id uuid,
  row_version                  integer not null default 1,
  created_at                   timestamptz not null default now(),
  created_by_user_id           uuid default auth.uid(),
  foreign key (customer_id, venue_id, competency_type_id) references core.competency_type (customer_id, venue_id, id),
  foreign key (customer_id, person_id) references core.person (customer_id, id),
  foreign key (customer_id, document_version_id) references core.document_version (customer_id, id),
  foreign key (customer_id, declared_by_person_id) references core.person (customer_id, id),
  foreign key (customer_id, declared_via_organisation_id) references core.organisation (customer_id, id),
  unique (customer_id, id)
);
select core.attach_standard_triggers('core.competency', null);

-- Q38: verification is a separate act with its method and source recorded.
create table core.competency_verification (
  id                  uuid primary key default gen_random_uuid(),
  customer_id         uuid not null,
  venue_id            uuid not null,
  competency_id       uuid not null,
  verifier_person_id  uuid not null,
  decision_context_id uuid not null references core.decision_context,
  method              text not null check (method in ('issuer_register', 'original_seen', 'issuer_confirmation')),
  source_checked      text not null check (length(btrim(source_checked)) > 0),
  holder_match        boolean not null,
  scope               text not null check (length(btrim(scope)) > 0),
  valid_until         date,
  outcome             text not null check (outcome in ('verified', 'not_verified')),
  notes               text,
  row_version         integer not null default 1,
  created_at          timestamptz not null default now(),
  created_by_user_id  uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, competency_id) references core.competency (customer_id, id),
  foreign key (customer_id, verifier_person_id) references core.person (customer_id, id),
  check (outcome <> 'verified' or holder_match)
);
select core.attach_standard_triggers('core.competency_verification', null);

-- Q39: what a specific decision needs. Engagements need organisation-held evidence;
-- appointments need the appointee's evidence.
create table core.evidence_requirement (
  id                  uuid primary key default gen_random_uuid(),
  customer_id         uuid not null,
  venue_id            uuid not null,
  code                text not null check (code ~ '^[A-Za-z0-9_-]{1,40}$'),
  label               text not null check (length(btrim(label)) > 0),
  applies_to_kind     text not null check (applies_to_kind in ('engagement_capacity', 'appointment_type')),
  capacity_code       text references core.engagement_capacity,
  appointment_type_id uuid,
  requires_kind       text not null check (requires_kind in ('document_type', 'competency_type')),
  document_type_id    uuid,
  competency_type_id  uuid,
  row_version         integer not null default 1,
  created_at          timestamptz not null default now(),
  created_by_user_id  uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, venue_id, appointment_type_id) references core.appointment_type (customer_id, venue_id, id),
  foreign key (customer_id, venue_id, document_type_id) references core.document_type (customer_id, venue_id, id),
  foreign key (customer_id, venue_id, competency_type_id) references core.competency_type (customer_id, venue_id, id),
  check ((applies_to_kind = 'engagement_capacity') = (capacity_code is not null)),
  check ((applies_to_kind = 'appointment_type') = (appointment_type_id is not null)),
  check ((requires_kind = 'document_type') = (document_type_id is not null)),
  check ((requires_kind = 'competency_type') = (competency_type_id is not null)),
  -- Organisations hold documents, not competencies.
  check (not (applies_to_kind = 'engagement_capacity' and requires_kind = 'competency_type')),
  unique (venue_id, code),
  unique (customer_id, venue_id, id)
);
select core.attach_standard_triggers('core.evidence_requirement', null);

create function core.evidence_requirement_holder_matches() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_level    text;
  v_expected text := case new.applies_to_kind when 'engagement_capacity' then 'organisation' else 'person' end;
begin
  if new.document_type_id is not null then
    select owner_level into v_level from core.document_type where id = new.document_type_id;
    if v_level <> v_expected then
      raise exception 'engagements need organisation documents; appointments need the appointee''s documents'
        using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $$;
create trigger evidence_requirement_holder_matches before insert on core.evidence_requirement
  for each row execute function core.evidence_requirement_holder_matches();

-- Whether a requirement is in force is itself versioned, with owner and date.
create table core.evidence_requirement_version (
  id                      uuid primary key default gen_random_uuid(),
  customer_id             uuid not null,
  venue_id                uuid not null,
  evidence_requirement_id uuid not null,
  version_no              integer not null check (version_no > 0),
  in_force                boolean not null,
  owner_person_id         uuid not null,
  effective_from          timestamptz not null,
  change_reason           text not null check (length(btrim(change_reason)) > 0),
  row_version             integer not null default 1,
  created_at              timestamptz not null default now(),
  created_by_user_id      uuid default auth.uid(),
  foreign key (customer_id, venue_id, evidence_requirement_id) references core.evidence_requirement (customer_id, venue_id, id),
  foreign key (customer_id, owner_person_id) references core.person (customer_id, id),
  unique (evidence_requirement_id, version_no)
);
select core.attach_standard_triggers('core.evidence_requirement_version', null);

-- Version numbering for the two versioned configurations above.
create function core.next_config_version() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_parent_col text := tg_argv[0];
  v_parent     uuid := (to_jsonb(new) ->> v_parent_col)::uuid;
  v_latest     record;
begin
  execute format('select max(version_no) as v, max(effective_from) as e from %I.%I where %I = $1',
                 tg_table_schema, tg_table_name, v_parent_col)
    into v_latest using v_parent;
  if v_latest.e is not null and new.effective_from <= v_latest.e then
    raise exception 'a new version must take effect after the previous one' using errcode = 'check_violation';
  end if;
  new.version_no := coalesce(v_latest.v, 0) + 1;
  return new;
end $$;
create trigger next_config_version before insert on core.review_criteria_version
  for each row execute function core.next_config_version('document_type_id');
create trigger next_config_version before insert on core.evidence_requirement_version
  for each row execute function core.next_config_version('evidence_requirement_id');
create trigger next_config_version before insert on core.privacy_notice_version
  for each row execute function core.next_config_version('customer_id');
