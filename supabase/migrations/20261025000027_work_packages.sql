-- 0027 Work packages and activity screening (phase 4a, D-017): catalogue, state
--      machines, tables and the screening content validator
--
-- A work package describes a job; every change is an immutable revision. Screening runs
-- the venue's approved rules over the applicant's answers and stores which permit
-- classes are recommended and why. Recommendations are settled by the applicant
-- (accept), by an appointed authority (challenge decision), or replaced when the job
-- changes materially. Deferred specialist work becomes an external-reference hold.
-- Nothing here authorises work: "routed" records that the list of permits is settled.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

-- ---------------------------------------------------------------------------
-- Catalogue
-- ---------------------------------------------------------------------------
insert into core.authority_action (code, basis, delegable, description) values
  ('work_type.create',                  'tenant_admin',       false, 'Add a work type (Q50)'),
  ('permit_class.create_external',      'tenant_admin',       false, 'Add a deferred specialist class handled by external reference (CLAUDE.md §7)'),
  ('screening_set.draft',               'tenant_admin',       false, 'Start a draft version of the venue''s activity screening'),
  ('screening_set.save_draft',          'tenant_admin',       false, 'Edit a draft screening version'),
  ('screening_set.propose',             'tenant_admin',       false, 'Propose a screening version for approval'),
  ('screening_set.approve',             'appointment',        false, 'Approve a proposed screening version (Q55-Q56, technical authority)'),
  ('screening_set.reject',              'appointment',        false, 'Reject a proposed screening version'),
  ('screening_set.supersede',           'derived',            false, 'Mark the previous approved screening version superseded'),
  ('work_package.create',               'organisation_admin', false, 'Start a work package for your organisation (Q48)'),
  ('work_package.create_for_venue',     'tenant_admin',       false, 'Start a work package for an engaged organisation'),
  ('work_package.revise',               'organisation_admin', false, 'Change a work package (a new revision)'),
  ('work_package.revise_for_venue',     'tenant_admin',       false, 'Change a work package for the venue (a new revision)'),
  ('work_package.answer',               'organisation_admin', false, 'Answer the activity screening and select permit classes'),
  ('work_package.answer_for_venue',     'tenant_admin',       false, 'Answer the activity screening for the venue'),
  ('work_package.submit',               'organisation_admin', false, 'Submit a work package for screening'),
  ('work_package.submit_for_venue',     'tenant_admin',       false, 'Submit a work package for screening for the venue'),
  ('work_package.cancel',               'organisation_admin', false, 'Cancel a work package'),
  ('work_package.cancel_for_venue',     'tenant_admin',       false, 'Cancel a work package for the venue'),
  ('work_package.reopen',               'derived',            false, 'Return a work package to draft after a material change'),
  ('work_package.route',                'derived',            false, 'Record that a work package''s permit routing is settled'),
  ('screening.recommend',               'derived',            false, 'Record a permit class recommendation from screening'),
  ('screening.hold',                    'derived',            false, 'Record an external-reference hold from screening'),
  ('screening.supersede',               'derived',            false, 'Mark screening outcomes superseded by a material change'),
  ('screening.accept',                  'organisation_admin', false, 'Accept a permit class recommendation'),
  ('screening.challenge',               'organisation_admin', false, 'Challenge a permit class recommendation (Q58)'),
  ('screening.decide',                  'appointment',        true,  'Decide a challenge, or that no permit is required (Q59)'),
  ('external_reference.add_evidence',   'organisation_admin', false, 'Provide external evidence for deferred specialist work'),
  ('external_reference.decide',         'appointment',        true,  'Accept or refuse external evidence for deferred specialist work');

insert into core.derived_action (parent_action, child_action) values
  ('screening_set.approve',          'screening_set.supersede'),
  ('work_package.submit',            'screening.recommend'),
  ('work_package.submit',            'screening.hold'),
  ('work_package.submit',            'work_package.route'),
  ('work_package.submit_for_venue',  'screening.recommend'),
  ('work_package.submit_for_venue',  'screening.hold'),
  ('work_package.submit_for_venue',  'work_package.route'),
  ('work_package.revise',            'screening.supersede'),
  ('work_package.revise',            'work_package.reopen'),
  ('work_package.revise_for_venue',  'screening.supersede'),
  ('work_package.revise_for_venue',  'work_package.reopen'),
  ('screening.accept',               'work_package.route'),
  ('screening.decide',               'work_package.route'),
  ('external_reference.decide',      'work_package.route');

insert into core.state_machine (code, table_name) values
  ('screening_set_version',   'core.screening_set_version'),
  ('work_package',            'core.work_package'),
  ('screening_recommendation','core.screening_recommendation'),
  ('external_reference_hold', 'core.external_reference_hold');

insert into core.state_initial (machine, state, required_action) values
  ('screening_set_version',    'draft',       'screening_set.draft'),
  ('work_package',             'draft',       'work_package.create'),
  ('work_package',             'draft',       'work_package.create_for_venue'),
  ('screening_recommendation', 'recommended', 'screening.recommend'),
  ('screening_recommendation', 'accepted',    'screening.recommend'),
  ('external_reference_hold',  'open',        'screening.hold');

insert into core.state_transition (machine, from_state, to_state, required_action) values
  ('screening_set_version',    'draft',       'proposed',     'screening_set.propose'),
  ('screening_set_version',    'proposed',    'approved',     'screening_set.approve'),
  ('screening_set_version',    'proposed',    'rejected',     'screening_set.reject'),
  ('screening_set_version',    'approved',    'superseded',   'screening_set.supersede'),
  ('work_package',             'draft',       'screening',    'work_package.submit'),
  ('work_package',             'draft',       'screening',    'work_package.submit_for_venue'),
  ('work_package',             'screening',   'routed',       'work_package.route'),
  ('work_package',             'screening',   'draft',        'work_package.reopen'),
  ('work_package',             'routed',      'draft',        'work_package.reopen'),
  ('work_package',             'draft',       'cancelled',    'work_package.cancel'),
  ('work_package',             'draft',       'cancelled',    'work_package.cancel_for_venue'),
  ('work_package',             'screening',   'cancelled',    'work_package.cancel'),
  ('work_package',             'screening',   'cancelled',    'work_package.cancel_for_venue'),
  ('screening_recommendation', 'recommended', 'accepted',     'screening.accept'),
  ('screening_recommendation', 'recommended', 'challenged',   'screening.challenge'),
  ('screening_recommendation', 'challenged',  'upheld',       'screening.decide'),
  ('screening_recommendation', 'challenged',  'not_required', 'screening.decide'),
  ('screening_recommendation', 'recommended', 'superseded',   'screening.supersede'),
  ('screening_recommendation', 'accepted',    'superseded',   'screening.supersede'),
  ('screening_recommendation', 'challenged',  'superseded',   'screening.supersede'),
  ('screening_recommendation', 'upheld',      'superseded',   'screening.supersede'),
  ('screening_recommendation', 'not_required','superseded',   'screening.supersede'),
  ('external_reference_hold',  'open',        'accepted',     'external_reference.decide'),
  ('external_reference_hold',  'open',        'refused',      'external_reference.decide'),
  ('external_reference_hold',  'open',        'superseded',   'screening.supersede'),
  ('external_reference_hold',  'accepted',    'superseded',   'screening.supersede'),
  ('external_reference_hold',  'refused',     'superseded',   'screening.supersede');

-- ---------------------------------------------------------------------------
-- Deferred specialist work is a permit class handled by external reference (P4-7).
-- Appointments are already scoped by permit class, so the authority for a specialist
-- area is expressed the same way as for any other class. Fixed at creation.
-- ---------------------------------------------------------------------------
alter table core.permit_class add column handling text not null default 'permit'
  check (handling in ('permit', 'external_reference'));

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------
create table core.work_type (
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
select core.attach_standard_triggers('core.work_type', 'label,retired_at');

-- One validated content document per version (questions and rules), as for course
-- versions. Approved versions are immutable; approval is the effective date.
create table core.screening_set_version (
  id                     uuid primary key default gen_random_uuid(),
  customer_id            uuid not null,
  venue_id               uuid not null,
  version_no             integer not null check (version_no > 0),
  status                 text not null,
  content                jsonb not null default '{"questions": [], "rules": []}',
  source_ref             text,
  authored_by_person_id  uuid not null,
  proposed_by_person_id  uuid,
  decided_by_person_id   uuid,
  decided_at             timestamptz,
  decision_reason        text,
  content_sha256         bytea,
  row_version            integer not null default 1,
  created_at             timestamptz not null default now(),
  created_by_user_id     uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, authored_by_person_id) references core.person (customer_id, id),
  foreign key (customer_id, proposed_by_person_id) references core.person (customer_id, id),
  foreign key (customer_id, decided_by_person_id) references core.person (customer_id, id),
  unique (venue_id, version_no),
  unique (customer_id, venue_id, id),
  check ((status = 'draft') = (content_sha256 is null))
);
create unique index screening_set_one_approved on core.screening_set_version (venue_id) where status = 'approved';
select core.attach_standard_triggers('core.screening_set_version',
  'status,content,source_ref,proposed_by_person_id,decided_by_person_id,decided_at,decision_reason,content_sha256',
  null, true);

create function core.screening_set_freeze() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status <> 'draft' and (new.content is distinct from old.content
                                or new.content_sha256 is distinct from old.content_sha256) then
    raise exception 'only a draft screening version can be changed; start a new version instead'
      using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger screening_set_freeze before update on core.screening_set_version
  for each row execute function core.screening_set_freeze();

-- ---------------------------------------------------------------------------
-- Work packages and their immutable revisions
-- ---------------------------------------------------------------------------
create table core.work_package (
  id                          uuid primary key default gen_random_uuid(),
  customer_id                 uuid not null,
  venue_id                    uuid not null,
  reference                   text not null,
  work_type_id                uuid not null,
  event_id                    uuid,
  event_phase_id              uuid,
  performing_engagement_id    uuid not null,
  performing_organisation_id  uuid not null,
  status                      text not null,
  current_revision_id         uuid,
  screened_revision_id        uuid,
  created_by_person_id        uuid not null,
  cancel_reason               text,
  row_version                 integer not null default 1,
  created_at                  timestamptz not null default now(),
  created_by_user_id          uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, venue_id, work_type_id) references core.work_type (customer_id, venue_id, id),
  foreign key (customer_id, venue_id, event_id) references core.event (customer_id, venue_id, id),
  foreign key (performing_engagement_id) references core.engagement (id),
  foreign key (customer_id, performing_organisation_id) references core.organisation (customer_id, id),
  foreign key (customer_id, created_by_person_id) references core.person (customer_id, id),
  foreign key (event_phase_id) references core.event_phase (id),
  unique (venue_id, reference),
  unique (customer_id, venue_id, id),
  check (event_phase_id is null or event_id is not null),
  check ((status = 'cancelled') = (cancel_reason is not null))
);
select core.attach_standard_triggers('core.work_package', 'status,current_revision_id,screened_revision_id,cancel_reason',
                                     null, true);

create table core.work_package_revision (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  venue_id              uuid not null,
  work_package_id       uuid not null,
  revision_no           integer not null check (revision_no > 0),
  change_kind           text not null check (change_kind in ('initial', 'administrative', 'material')),
  reason                text,
  title                 text not null check (length(btrim(title)) > 0),
  scope                 text not null check (length(btrim(scope)) > 0),
  method                text,
  planned_window        tstzrange not null check (not isempty(planned_window) and not lower_inf(planned_window)
                                                  and not upper_inf(planned_window)),
  contact_person_id     uuid not null,
  supervisor_person_id  uuid,
  author_person_id      uuid not null,
  decision_context_id   uuid not null references core.decision_context,
  row_version           integer not null default 1,
  created_at            timestamptz not null default now(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, venue_id, work_package_id) references core.work_package (customer_id, venue_id, id),
  foreign key (customer_id, contact_person_id) references core.person (customer_id, id),
  foreign key (customer_id, supervisor_person_id) references core.person (customer_id, id),
  foreign key (customer_id, author_person_id) references core.person (customer_id, id),
  unique (work_package_id, revision_no),
  unique (customer_id, venue_id, id),
  check ((change_kind = 'initial') = (revision_no = 1)),
  check (change_kind = 'initial' or length(btrim(coalesce(reason, ''))) > 0)
);
select core.attach_standard_triggers('core.work_package_revision', null);

alter table core.work_package
  add foreign key (customer_id, venue_id, current_revision_id) references core.work_package_revision (customer_id, venue_id, id),
  add foreign key (customer_id, venue_id, screened_revision_id) references core.work_package_revision (customer_id, venue_id, id);

create table core.work_package_area (
  id                  uuid primary key default gen_random_uuid(),
  customer_id         uuid not null,
  venue_id            uuid not null,
  revision_id         uuid not null,
  area_id             uuid not null,
  row_version         integer not null default 1,
  created_at          timestamptz not null default now(),
  created_by_user_id  uuid default auth.uid(),
  foreign key (customer_id, venue_id, revision_id) references core.work_package_revision (customer_id, venue_id, id),
  foreign key (area_id) references core.area (id),
  unique (revision_id, area_id)
);
select core.attach_standard_triggers('core.work_package_area', null);

create table core.work_package_system (
  id                  uuid primary key default gen_random_uuid(),
  customer_id         uuid not null,
  venue_id            uuid not null,
  revision_id         uuid not null,
  system_id           uuid not null,
  row_version         integer not null default 1,
  created_at          timestamptz not null default now(),
  created_by_user_id  uuid default auth.uid(),
  foreign key (customer_id, venue_id, revision_id) references core.work_package_revision (customer_id, venue_id, id),
  foreign key (system_id) references core.system (id),
  unique (revision_id, system_id)
);
select core.attach_standard_triggers('core.work_package_system', null);

create table core.work_package_party (
  id                  uuid primary key default gen_random_uuid(),
  customer_id         uuid not null,
  venue_id            uuid not null,
  revision_id         uuid not null,
  organisation_id     uuid not null,
  role                text not null check (role in ('commissioning', 'performing', 'principal_contractor',
                                                    'affected_occupier', 'landlord_operator')),
  row_version         integer not null default 1,
  created_at          timestamptz not null default now(),
  created_by_user_id  uuid default auth.uid(),
  foreign key (customer_id, venue_id, revision_id) references core.work_package_revision (customer_id, venue_id, id),
  foreign key (customer_id, organisation_id) references core.organisation (customer_id, id),
  unique (revision_id, organisation_id, role)
);
create unique index work_package_one_performer on core.work_package_party (revision_id) where role = 'performing';
select core.attach_standard_triggers('core.work_package_party', null);

-- ---------------------------------------------------------------------------
-- Screening: draft answers (editable), the submitted response (immutable), and the
-- outcome (recommendations and holds, each with its own lifecycle)
-- ---------------------------------------------------------------------------
create table core.screening_draft (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  venue_id              uuid not null,
  work_package_id       uuid not null unique,
  answers               jsonb not null default '{}' check (jsonb_typeof(answers) = 'object'),
  selected_class_ids    uuid[] not null default '{}',
  row_version           integer not null default 1,
  created_at            timestamptz not null default now(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, venue_id, work_package_id) references core.work_package (customer_id, venue_id, id)
);
select core.attach_standard_triggers('core.screening_draft', 'answers,selected_class_ids');

create table core.screening_response (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  venue_id              uuid not null,
  work_package_id       uuid not null,
  revision_id           uuid not null unique,
  set_version_id        uuid not null,
  answers               jsonb not null check (jsonb_typeof(answers) = 'object'),
  selected_class_ids    uuid[] not null,
  respondent_person_id  uuid not null,
  decision_context_id   uuid not null references core.decision_context,
  row_version           integer not null default 1,
  created_at            timestamptz not null default now(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, venue_id, work_package_id) references core.work_package (customer_id, venue_id, id),
  foreign key (customer_id, venue_id, revision_id) references core.work_package_revision (customer_id, venue_id, id),
  foreign key (customer_id, venue_id, set_version_id) references core.screening_set_version (customer_id, venue_id, id),
  foreign key (customer_id, respondent_person_id) references core.person (customer_id, id)
);
select core.attach_standard_triggers('core.screening_response', null);

create table core.screening_recommendation (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  venue_id              uuid not null,
  work_package_id       uuid not null,
  revision_id           uuid not null,
  permit_class_id       uuid not null,
  matched_rule_keys     text[] not null,
  applicant_selected    boolean not null,
  status                text not null,
  row_version           integer not null default 1,
  created_at            timestamptz not null default now(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, venue_id, work_package_id) references core.work_package (customer_id, venue_id, id),
  foreign key (customer_id, venue_id, revision_id) references core.work_package_revision (customer_id, venue_id, id),
  foreign key (permit_class_id) references core.permit_class (id),
  unique (revision_id, permit_class_id),
  unique (customer_id, venue_id, id),
  check (cardinality(matched_rule_keys) > 0 or applicant_selected)
);
select core.attach_standard_triggers('core.screening_recommendation', 'status', null, true);

create table core.screening_challenge (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  venue_id              uuid not null,
  recommendation_id     uuid not null unique,
  reason                text not null check (length(btrim(reason)) > 0),
  document_version_ids  uuid[] not null default '{}',
  raised_by_person_id   uuid not null,
  decision_context_id   uuid not null references core.decision_context,
  row_version           integer not null default 1,
  created_at            timestamptz not null default now(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, venue_id, recommendation_id) references core.screening_recommendation (customer_id, venue_id, id),
  foreign key (customer_id, raised_by_person_id) references core.person (customer_id, id),
  unique (customer_id, venue_id, id)
);
select core.attach_standard_triggers('core.screening_challenge', null);

create table core.challenge_decision (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  venue_id              uuid not null,
  challenge_id          uuid not null unique,
  outcome               text not null check (outcome in ('upheld', 'not_required')),
  reason                text not null check (length(btrim(reason)) > 0),
  decider_person_id     uuid not null,
  decision_context_id   uuid not null references core.decision_context,
  row_version           integer not null default 1,
  created_at            timestamptz not null default now(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, venue_id, challenge_id) references core.screening_challenge (customer_id, venue_id, id),
  foreign key (customer_id, decider_person_id) references core.person (customer_id, id)
);
select core.attach_standard_triggers('core.challenge_decision', null);

-- "No permit required" is always scoped, never "approved" or "safe" (CLAUDE.md §1, Q72).
create table core.no_permit_required_decision (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  venue_id              uuid not null,
  work_package_id       uuid not null,
  revision_id           uuid not null,
  recommendation_id     uuid unique,
  scope_wording         text not null check (length(btrim(scope_wording)) > 0
                                             and scope_wording !~* '(approv|certif|verif|guarant|complian|safe to)'),
  reason                text not null check (length(btrim(reason)) > 0),
  decider_person_id     uuid not null,
  decision_context_id   uuid not null references core.decision_context,
  row_version           integer not null default 1,
  created_at            timestamptz not null default now(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, venue_id, work_package_id) references core.work_package (customer_id, venue_id, id),
  foreign key (customer_id, venue_id, revision_id) references core.work_package_revision (customer_id, venue_id, id),
  foreign key (customer_id, venue_id, recommendation_id) references core.screening_recommendation (customer_id, venue_id, id),
  foreign key (customer_id, decider_person_id) references core.person (customer_id, id)
);
create unique index npr_one_whole_package on core.no_permit_required_decision (revision_id) where recommendation_id is null;
select core.attach_standard_triggers('core.no_permit_required_decision', null);

-- ---------------------------------------------------------------------------
-- Deferred specialist work (CLAUDE.md §7, P4-7)
-- ---------------------------------------------------------------------------
create table core.external_reference_hold (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  venue_id              uuid not null,
  work_package_id       uuid not null,
  revision_id           uuid not null,
  permit_class_id       uuid not null,
  matched_rule_keys     text[] not null check (cardinality(matched_rule_keys) > 0),
  status                text not null,
  row_version           integer not null default 1,
  created_at            timestamptz not null default now(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, venue_id, work_package_id) references core.work_package (customer_id, venue_id, id),
  foreign key (customer_id, venue_id, revision_id) references core.work_package_revision (customer_id, venue_id, id),
  foreign key (permit_class_id) references core.permit_class (id),
  unique (revision_id, permit_class_id),
  unique (customer_id, venue_id, id)
);
select core.attach_standard_triggers('core.external_reference_hold', 'status', null, true);

create table core.external_reference_evidence (
  id                     uuid primary key default gen_random_uuid(),
  customer_id            uuid not null,
  venue_id               uuid not null,
  hold_id                uuid not null,
  external_decider       text not null check (length(btrim(external_decider)) > 0),
  external_organisation  text not null check (length(btrim(external_organisation)) > 0),
  reference              text,
  scope                  text not null check (length(btrim(scope)) > 0),
  decided_on             date not null,
  conditions             text,
  document_version_ids   uuid[] not null default '{}',
  submitted_by_person_id uuid not null,
  decision_context_id    uuid not null references core.decision_context,
  row_version            integer not null default 1,
  created_at             timestamptz not null default now(),
  created_by_user_id     uuid default auth.uid(),
  foreign key (customer_id, venue_id, hold_id) references core.external_reference_hold (customer_id, venue_id, id),
  foreign key (customer_id, submitted_by_person_id) references core.person (customer_id, id)
);
select core.attach_standard_triggers('core.external_reference_evidence', null);

create table core.external_reference_decision (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  venue_id              uuid not null,
  hold_id               uuid not null unique,
  outcome               text not null check (outcome in ('accepted', 'refused')),
  reason                text not null check (length(btrim(reason)) > 0),
  decider_person_id     uuid not null,
  decision_context_id   uuid not null references core.decision_context,
  row_version           integer not null default 1,
  created_at            timestamptz not null default now(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, venue_id, hold_id) references core.external_reference_hold (customer_id, venue_id, id),
  foreign key (customer_id, decider_person_id) references core.person (customer_id, id)
);
select core.attach_standard_triggers('core.external_reference_decision', null);

-- ---------------------------------------------------------------------------
-- Screening content validation. Structural checks on every save; strict checks
-- (classes current, at least one question and rule) before proposal and approval.
-- Content:
--   questions: [{key, text, help?, type: yes_no|choose_one|choose_many,
--                options?: [{key, text}], show_if?: {question, answers: [..]}}]
--   rules:     [{key, all: [{question, answers: [..]}], permit_class_id, rationale}]
-- yes_no questions have the fixed answers "yes" and "no".
-- ---------------------------------------------------------------------------
create function core.screening_question_answers(q jsonb) returns text[]
language sql immutable set search_path = '' as $$
  select case when q ->> 'type' = 'yes_no' then array['yes', 'no']
              else coalesce((select array_agg(o ->> 'key') from jsonb_array_elements(q -> 'options') o), '{}') end $$;

create function core.validate_screening_content(p_venue_id uuid, p_content jsonb, p_strict boolean)
returns text[]
language plpgsql stable security definer
set search_path = ''
as $$
declare
  errs   text[] := '{}';
  q      jsonb;
  r      jsonb;
  c      jsonb;
  qkeys  text[] := '{}';
  rkeys  text[] := '{}';
  qmap   jsonb := '{}';
  okeys  text[];
  a      text;
begin
  if jsonb_typeof(p_content -> 'questions') is distinct from 'array' or jsonb_typeof(p_content -> 'rules') is distinct from 'array' then
    return array['Screening content must have a list of questions and a list of rules.'];
  end if;
  if p_strict and jsonb_array_length(p_content -> 'questions') = 0 then
    errs := errs || text 'Screening needs at least one question.';
  end if;
  if p_strict and jsonb_array_length(p_content -> 'rules') = 0 then
    errs := errs || text 'Screening needs at least one rule.';
  end if;

  for q in select * from jsonb_array_elements(p_content -> 'questions') loop
    if coalesce(q ->> 'key', '') !~ '^[a-z0-9-]{1,60}$' or (q ->> 'key') = any (qkeys) then
      errs := errs || format('Question "%s" needs a unique key of lower-case letters, digits and hyphens.', left(q ->> 'text', 40));
      continue;
    end if;
    if length(btrim(coalesce(q ->> 'text', ''))) = 0 then
      errs := errs || format('Question "%s" has no wording.', q ->> 'key');
    end if;
    if coalesce(q ->> 'type', '') not in ('yes_no', 'choose_one', 'choose_many') then
      errs := errs || format('Question "%s" must be yes/no, choose one or choose many.', q ->> 'key');
    elsif q ->> 'type' <> 'yes_no' then
      if jsonb_typeof(q -> 'options') is distinct from 'array' or jsonb_array_length(q -> 'options') < 2 then
        errs := errs || format('Question "%s" needs at least two options.', q ->> 'key');
      else
        okeys := '{}';
        for c in select * from jsonb_array_elements(q -> 'options') loop
          if coalesce(c ->> 'key', '') !~ '^[a-z0-9-]{1,60}$' or (c ->> 'key') = any (okeys)
             or length(btrim(coalesce(c ->> 'text', ''))) = 0 then
            errs := errs || format('Question "%s" has an option without a unique key or wording.', q ->> 'key');
          end if;
          okeys := okeys || (c ->> 'key');
        end loop;
      end if;
    end if;
    if q ? 'show_if' then
      if not ((q #>> '{show_if,question}') = any (qkeys)) then
        errs := errs || format('Question "%s" can only depend on an earlier question.', q ->> 'key');
      elsif jsonb_typeof(q #> '{show_if,answers}') is distinct from 'array' or jsonb_array_length(q #> '{show_if,answers}') = 0
            or exists (select 1 from jsonb_array_elements_text(q #> '{show_if,answers}') x
                        where not (x = any (core.screening_question_answers(qmap -> (q #>> '{show_if,question}'))))) then
        errs := errs || format('Question "%s" depends on answers that the earlier question does not offer.', q ->> 'key');
      end if;
    end if;
    qkeys := qkeys || (q ->> 'key');
    qmap := qmap || jsonb_build_object(q ->> 'key', q);
  end loop;

  for r in select * from jsonb_array_elements(p_content -> 'rules') loop
    if coalesce(r ->> 'key', '') !~ '^[a-z0-9-]{1,60}$' or (r ->> 'key') = any (rkeys) then
      errs := errs || text 'Every rule needs a unique key of lower-case letters, digits and hyphens.';
      continue;
    end if;
    rkeys := rkeys || (r ->> 'key');
    if length(btrim(coalesce(r ->> 'rationale', ''))) = 0 then
      errs := errs || format('Rule "%s" needs a plain-English reason to show the applicant.', r ->> 'key');
    end if;
    if jsonb_typeof(r -> 'all') is distinct from 'array' or jsonb_array_length(r -> 'all') = 0 then
      errs := errs || format('Rule "%s" needs at least one condition.', r ->> 'key');
    else
      for c in select * from jsonb_array_elements(r -> 'all') loop
        if not ((c ->> 'question') = any (qkeys)) then
          errs := errs || format('Rule "%s" refers to a question that does not exist.', r ->> 'key');
        elsif jsonb_typeof(c -> 'answers') is distinct from 'array' or jsonb_array_length(c -> 'answers') = 0 then
          errs := errs || format('Rule "%s" needs the answers that trigger it.', r ->> 'key');
        else
          for a in select * from jsonb_array_elements_text(c -> 'answers') loop
            if not (a = any (core.screening_question_answers(qmap -> (c ->> 'question')))) then
              errs := errs || format('Rule "%s" uses an answer that question "%s" does not offer.', r ->> 'key', c ->> 'question');
            end if;
          end loop;
        end if;
      end loop;
    end if;
    if (r ->> 'permit_class_id') is null
       or (r ->> 'permit_class_id') !~ '^[0-9a-f-]{36}$'
       or not exists (select 1 from core.permit_class pc where pc.id = (r ->> 'permit_class_id')::uuid
                                                         and pc.venue_id = p_venue_id
                                                         and (not p_strict or pc.retired_at is null)) then
      errs := errs || format('Rule "%s" must name a permit class at this venue%s.', r ->> 'key',
                             case when p_strict then ' that is not retired' else '' end);
    end if;
  end loop;
  return errs;
end $$;

-- Evaluates approved content against answers: one row per matched rule.
create function core.screening_matches(p_content jsonb, p_answers jsonb)
returns table (rule_key text, permit_class_id uuid)
language sql immutable set search_path = '' as $$
  select r ->> 'key', (r ->> 'permit_class_id')::uuid
    from jsonb_array_elements(p_content -> 'rules') r
   where not exists (
     select 1 from jsonb_array_elements(r -> 'all') c
      where not exists (
        select 1 from jsonb_array_elements_text(coalesce(p_answers -> (c ->> 'question'), '[]')) given
         where given in (select jsonb_array_elements_text(c -> 'answers')))) $$;

-- Problems with a set of answers: every question that is shown must be answered with
-- offered answers (one for yes/no and choose-one); questions not shown must be blank.
create function core.screening_answer_problems(p_content jsonb, p_answers jsonb) returns text[]
language plpgsql immutable set search_path = '' as $$
declare
  errs  text[] := '{}';
  q     jsonb;
  given jsonb;
  shown boolean;
  dep   jsonb;
begin
  for q in select * from jsonb_array_elements(p_content -> 'questions') loop
    given := p_answers -> (q ->> 'key');
    shown := true;
    if q ? 'show_if' then
      dep := p_answers -> (q #>> '{show_if,question}');
      shown := dep is not null and exists (
        select 1 from jsonb_array_elements_text(dep) x
         where x in (select jsonb_array_elements_text(q #> '{show_if,answers}')));
    end if;
    if not shown then
      if given is not null then
        errs := errs || format('"%s" does not apply to your earlier answers; leave it blank.', q ->> 'text');
      end if;
      continue;
    end if;
    if given is null or jsonb_typeof(given) <> 'array' or jsonb_array_length(given) = 0 then
      errs := errs || format('Answer "%s".', q ->> 'text');
    elsif q ->> 'type' in ('yes_no', 'choose_one') and jsonb_array_length(given) <> 1 then
      errs := errs || format('Choose one answer for "%s".', q ->> 'text');
    elsif exists (select 1 from jsonb_array_elements_text(given) x where not (x = any (core.screening_question_answers(q)))) then
      errs := errs || format('"%s" has an answer it does not offer.', q ->> 'text');
    end if;
  end loop;
  if exists (select 1 from jsonb_object_keys(p_answers) k
              where k not in (select q2 ->> 'key' from jsonb_array_elements(p_content -> 'questions') q2)) then
    errs := errs || text 'Some answers are for questions this screening does not ask.';
  end if;
  return errs;
end $$;
