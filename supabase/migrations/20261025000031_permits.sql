-- 0031 Permits (phase 5a, D-018): catalogue, state machines, class configuration, the
--      area occupation register, permits and their immutable versions, approval steps,
--      step decisions, conditions, external decisions and information requests
--
-- A routed job becomes one Work Approval with a child permit per required class (P5-2).
-- Each class is used only under an approved, versioned configuration (P5-5): its
-- questions, approval route and declarations. Steps are decided by appointees whose
-- appointment covers the class (where the step needs it) and every area of the job.
-- Every decision is an immutable row; the permit's state follows from them. Issue and
-- acceptance arrive in 5b.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

-- ---------------------------------------------------------------------------
-- Catalogue
-- ---------------------------------------------------------------------------
insert into core.authority_action (code, basis, delegable, description) values
  ('permit_class.create_work_approval',  'tenant_admin',       false, 'Add the venue''s Work Approval class (P5-2)'),
  ('permit_class_version.draft',         'tenant_admin',       false, 'Start a draft configuration for a permit class (P5-5)'),
  ('permit_class_version.save_draft',    'tenant_admin',       false, 'Edit a draft permit class configuration'),
  ('permit_class_version.propose',       'tenant_admin',       false, 'Propose a permit class configuration for approval'),
  ('permit_class_version.approve',       'appointment',        false, 'Approve a permit class configuration (technical authority)'),
  ('permit_class_version.reject',        'appointment',        false, 'Reject a permit class configuration'),
  ('permit_class_version.supersede',     'derived',            false, 'Mark the previous approved configuration superseded'),
  ('area_occupation.record',             'tenant_admin',       false, 'Record which organisation occupies an area (P5-6)'),
  ('work_package.require_class',         'appointment',        true,  'Require a permit class that screening missed (P5-12)'),
  ('permit.start',                       'organisation_admin', false, 'Start the permits a routed job needs'),
  ('permit.start_for_venue',             'tenant_admin',       false, 'Start the permits a routed job needs, for the venue'),
  ('permit.create',                      'derived',            false, 'Create a permit draft'),
  ('permit.cancel_unrequired',           'derived',            false, 'Cancel a permit for a class the job no longer needs'),
  ('permit.save_draft',                  'organisation_admin', false, 'Prepare a permit request'),
  ('permit.save_draft_for_venue',        'tenant_admin',       false, 'Prepare a permit request for the venue'),
  ('permit.submit',                      'organisation_admin', false, 'Submit a permit request with the declaration (Q68)'),
  ('permit.submit_for_venue',            'tenant_admin',       false, 'Submit a permit request for the venue'),
  ('permit.respond',                     'organisation_admin', false, 'Answer an information request and resubmit (Q70)'),
  ('permit.respond_for_venue',           'tenant_admin',       false, 'Answer an information request and resubmit, for the venue'),
  ('permit.cancel',                      'organisation_admin', false, 'Cancel a permit request'),
  ('permit.cancel_for_venue',            'tenant_admin',       false, 'Cancel a permit request for the venue'),
  ('permit_step.decide',                 'appointment',        true,  'Decide a review step of a permit (Q76)'),
  ('permit_step.decide_occupier',        'appointment',        true,  'Decide an occupier approval step (Q77)'),
  ('permit_step.decide_landlord',        'appointment',        true,  'Decide a landlord or operator approval step (Q77)'),
  ('permit_step.record_external',        'appointment',        true,  'Record an external decision for a permit step (Q82)'),
  ('permit.start_review',                'derived',            false, 'Record that review of a permit has started'),
  ('permit.request_information',         'derived',            false, 'Record that a permit needs more information'),
  ('permit.approve_for_issue',           'derived',            false, 'Record that every step of a permit is decided'),
  ('permit.refuse',                      'derived',            false, 'Record that a step refused a permit'),
  ('permit.reopen',                      'derived',            false, 'Return an approved permit to review when a step is reopened (Q83)'),
  ('permit.return_to_draft',             'derived',            false, 'Return a permit to draft after a material change to the job');

insert into core.derived_action (parent_action, child_action)
select p, c from (values
  ('permit_class_version.approve', 'permit_class_version.supersede'),
  ('permit.start',                 'permit.create'),
  ('permit.start',                 'permit.cancel_unrequired'),
  ('permit.start_for_venue',       'permit.create'),
  ('permit.start_for_venue',       'permit.cancel_unrequired'),
  ('work_package.require_class',   'permit.create'),
  ('work_package.revise',          'permit.return_to_draft'),
  ('work_package.revise_for_venue','permit.return_to_draft')) x(p, c)
union all
select s, c from unnest(array['permit_step.decide', 'permit_step.decide_occupier', 'permit_step.decide_landlord',
                              'permit_step.record_external']) s
  cross join unnest(array['permit.start_review', 'permit.request_information', 'permit.approve_for_issue',
                          'permit.refuse', 'permit.reopen']) c;

insert into core.state_machine (code, table_name) values
  ('permit_class_version', 'core.permit_class_version'),
  ('permit',               'core.permit');

insert into core.state_initial (machine, state, required_action) values
  ('permit_class_version', 'draft', 'permit_class_version.draft'),
  ('permit',               'draft', 'permit.create');

insert into core.state_transition (machine, from_state, to_state, required_action)
select 'permit_class_version', f, t, a from (values
  ('draft', 'proposed', 'permit_class_version.propose'),
  ('proposed', 'approved', 'permit_class_version.approve'),
  ('proposed', 'rejected', 'permit_class_version.reject'),
  ('approved', 'superseded', 'permit_class_version.supersede')) x(f, t, a)
union all
select 'permit', f, t, a from (values
  ('draft', 'submitted', 'permit.submit'),
  ('draft', 'submitted', 'permit.submit_for_venue'),
  ('submitted', 'under_review', 'permit.start_review'),
  ('submitted', 'more_information_required', 'permit.request_information'),
  ('under_review', 'more_information_required', 'permit.request_information'),
  ('more_information_required', 'under_review', 'permit.respond'),
  ('more_information_required', 'under_review', 'permit.respond_for_venue'),
  ('submitted', 'approved_for_issue', 'permit.approve_for_issue'),
  ('under_review', 'approved_for_issue', 'permit.approve_for_issue'),
  ('submitted', 'refused', 'permit.refuse'),
  ('under_review', 'refused', 'permit.refuse'),
  ('approved_for_issue', 'under_review', 'permit.reopen')) x(f, t, a)
union all
select 'permit', f, 'cancelled', a
  from unnest(array['draft', 'submitted', 'under_review', 'more_information_required', 'approved_for_issue']) f
  cross join unnest(array['permit.cancel', 'permit.cancel_for_venue', 'permit.cancel_unrequired']) a
union all
select 'permit', f, 'draft', 'permit.return_to_draft'
  from unnest(array['submitted', 'under_review', 'more_information_required', 'approved_for_issue', 'refused']) f;

-- The Work Approval is a class of its own handling: the parent of every job's permits.
alter table core.permit_class drop constraint permit_class_handling_check;
alter table core.permit_class add constraint permit_class_handling_check
  check (handling in ('permit', 'external_reference', 'work_approval'));
create unique index permit_class_one_work_approval on core.permit_class (venue_id) where handling = 'work_approval';

-- ---------------------------------------------------------------------------
-- Class configuration (P5-5). Content:
--   questions:  screening question format (may be empty)
--   route:      [{key, name, kind: review|occupier|landlord_operator|external, group (1, 2, ...),
--                 when?: {system_type_id}}]   occupier / landlord_operator steps are
--                 instantiated once per party of that role on the job
--   submission_declaration, acceptance_declaration: [text, ...]
--   requires_physical_controls, override_prohibited: boolean (must be chosen)
-- ---------------------------------------------------------------------------
create table core.permit_class_version (
  id                     uuid primary key default gen_random_uuid(),
  customer_id            uuid not null,
  venue_id               uuid not null,
  permit_class_id        uuid not null,
  version_no             integer not null check (version_no > 0),
  status                 text not null,
  content                jsonb not null default '{"questions": [], "route": [], "submission_declaration": [], "acceptance_declaration": []}',
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
  foreign key (permit_class_id) references core.permit_class (id),
  foreign key (customer_id, authored_by_person_id) references core.person (customer_id, id),
  foreign key (customer_id, proposed_by_person_id) references core.person (customer_id, id),
  foreign key (customer_id, decided_by_person_id) references core.person (customer_id, id),
  unique (permit_class_id, version_no),
  unique (customer_id, venue_id, id),
  check ((status = 'draft') = (content_sha256 is null))
);
create unique index permit_class_version_one_approved on core.permit_class_version (permit_class_id) where status = 'approved';
select core.attach_standard_triggers('core.permit_class_version',
  'status,content,source_ref,proposed_by_person_id,decided_by_person_id,decided_at,decision_reason,content_sha256', null, true);
create trigger permit_class_version_freeze before update on core.permit_class_version
  for each row execute function core.screening_set_freeze();

create function core.validate_class_config(p_venue_id uuid, p_content jsonb, p_strict boolean) returns text[]
language plpgsql stable security definer set search_path = '' as $$
declare
  errs   text[] := '{}';
  s      jsonb;
  keys   text[] := '{}';
  groups integer[] := '{}';
begin
  if jsonb_typeof(p_content -> 'questions') is distinct from 'array' or jsonb_typeof(p_content -> 'route') is distinct from 'array'
     or jsonb_typeof(p_content -> 'submission_declaration') is distinct from 'array'
     or jsonb_typeof(p_content -> 'acceptance_declaration') is distinct from 'array' then
    return array['A class configuration needs questions, a route, and submission and acceptance declarations (lists).'];
  end if;
  -- Questions use the screening format and its checks (rules are not used here).
  errs := core.validate_screening_content(p_venue_id, jsonb_build_object('questions', p_content -> 'questions', 'rules', '[]'::jsonb), false);
  for s in select * from jsonb_array_elements(p_content -> 'route') loop
    if coalesce(s ->> 'key', '') !~ '^[a-z0-9-]{1,60}$' or (s ->> 'key') = any (keys) then
      errs := errs || text 'Every approval step needs a unique key of lower-case letters, digits and hyphens.';
      continue;
    end if;
    keys := keys || (s ->> 'key');
    if length(btrim(coalesce(s ->> 'name', ''))) = 0 then
      errs := errs || format('Approval step "%s" needs a name.', s ->> 'key');
    end if;
    if coalesce(s ->> 'kind', '') not in ('review', 'occupier', 'landlord_operator', 'external') then
      errs := errs || format('Approval step "%s" must be a review, occupier, landlord or operator, or external step.', s ->> 'key');
    end if;
    if jsonb_typeof(s -> 'group') is distinct from 'number' or (s ->> 'group')::numeric < 1 or (s ->> 'group')::numeric <> floor((s ->> 'group')::numeric) then
      errs := errs || format('Approval step "%s" needs a group number (1, 2, ...): steps in the same group run in parallel, groups run in order.', s ->> 'key');
    else
      groups := groups || (s ->> 'group')::integer;
    end if;
    if s ? 'when' and ((s #>> '{when,system_type_id}') is null or (s #>> '{when,system_type_id}') !~ '^[0-9a-f-]{36}$'
                       or not exists (select 1 from core.system_type t where t.id = (s #>> '{when,system_type_id}')::uuid
                                                                       and t.venue_id = p_venue_id)) then
      errs := errs || format('Approval step "%s" applies only to a system type that does not exist at this venue.', s ->> 'key');
    end if;
  end loop;
  if cardinality(groups) > 0 and (select array_agg(distinct g order by g) from unnest(groups) g)
                                 <> (select array_agg(g) from generate_series(1, (select max(g) from unnest(groups) g)) g) then
    errs := errs || text 'Approval step groups must run 1, 2, 3 without gaps.';
  end if;
  if p_strict then
    if jsonb_array_length(p_content -> 'route') = 0 then
      errs := errs || text 'A class needs at least one approval step.';
    end if;
    if not exists (select 1 from jsonb_array_elements(p_content -> 'route') x where x ->> 'kind' = 'review' and not x ? 'when') then
      errs := errs || text 'A class needs at least one review step that always applies.';
    end if;
    if jsonb_array_length(p_content -> 'submission_declaration') = 0 then
      errs := errs || text 'Write the declaration the applicant makes on submission (Q68).';
    end if;
    if jsonb_array_length(p_content -> 'acceptance_declaration') = 0 then
      errs := errs || text 'Write the declaration the supervisor makes on acceptance (Q101).';
    end if;
    if jsonb_typeof(p_content -> 'requires_physical_controls') is distinct from 'boolean' then
      errs := errs || text 'Choose whether this class requires physical controls (isolation, impairment or fire watch).';
    end if;
    if jsonb_typeof(p_content -> 'override_prohibited') is distinct from 'boolean' then
      errs := errs || text 'Choose whether late-notice exceptions are prohibited for this class (Q93).';
    end if;
  end if;
  if exists (select 1 from jsonb_array_elements(p_content -> 'submission_declaration') d
              where jsonb_typeof(d) <> 'string' or length(btrim(d #>> '{}')) = 0)
     or exists (select 1 from jsonb_array_elements(p_content -> 'acceptance_declaration') d
                 where jsonb_typeof(d) <> 'string' or length(btrim(d #>> '{}')) = 0) then
    errs := errs || text 'Every declaration item needs wording.';
  end if;
  return errs;
end $$;

-- ---------------------------------------------------------------------------
-- Area occupation register (P5-6): which organisation occupies which area, when.
-- ---------------------------------------------------------------------------
create table core.area_occupation (
  id                  uuid primary key default gen_random_uuid(),
  customer_id         uuid not null,
  venue_id            uuid not null,
  area_id             uuid not null,
  organisation_id     uuid not null,
  valid_during        tstzrange not null check (not isempty(valid_during) and not lower_inf(valid_during)),
  evidence_ref        text,
  ended_at            timestamptz,
  row_version         integer not null default 1,
  created_at          timestamptz not null default now(),
  created_by_user_id  uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (area_id) references core.area (id),
  foreign key (customer_id, organisation_id) references core.organisation (customer_id, id)
);
select core.attach_standard_triggers('core.area_occupation', 'ended_at');

-- ---------------------------------------------------------------------------
-- A class screening missed, required by an appointed authority (P5-12)
-- ---------------------------------------------------------------------------
create table core.class_requirement (
  id                  uuid primary key default gen_random_uuid(),
  customer_id         uuid not null,
  venue_id            uuid not null,
  work_package_id     uuid not null,
  revision_id         uuid not null,
  permit_class_id     uuid not null,
  reason              text not null check (length(btrim(reason)) > 0),
  decider_person_id   uuid not null,
  decision_context_id uuid not null references core.decision_context,
  row_version         integer not null default 1,
  created_at          timestamptz not null default now(),
  created_by_user_id  uuid default auth.uid(),
  foreign key (customer_id, venue_id, work_package_id) references core.work_package (customer_id, venue_id, id),
  foreign key (customer_id, venue_id, revision_id) references core.work_package_revision (customer_id, venue_id, id),
  foreign key (permit_class_id) references core.permit_class (id),
  foreign key (customer_id, decider_person_id) references core.person (customer_id, id),
  unique (revision_id, permit_class_id)
);
select core.attach_standard_triggers('core.class_requirement', null);

-- ---------------------------------------------------------------------------
-- Permits, drafts and immutable versions
-- ---------------------------------------------------------------------------
create table core.permit (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  venue_id              uuid not null,
  work_package_id       uuid not null,
  kind                  text not null check (kind in ('work_approval', 'child')),
  permit_class_id       uuid not null,
  parent_permit_id      uuid,
  status                text not null,
  current_version_id    uuid,
  row_version           integer not null default 1,
  created_at            timestamptz not null default now(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, venue_id, work_package_id) references core.work_package (customer_id, venue_id, id),
  foreign key (permit_class_id) references core.permit_class (id),
  foreign key (parent_permit_id) references core.permit (id),
  unique (customer_id, venue_id, id),
  check ((kind = 'work_approval') = (parent_permit_id is null))
);
create unique index permit_one_live_per_class on core.permit (work_package_id, permit_class_id) where status <> 'cancelled';
select core.attach_standard_triggers('core.permit', 'status,current_version_id', null, true);

create table core.permit_draft (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  venue_id              uuid not null,
  permit_id             uuid not null unique,
  answers               jsonb not null default '{}' check (jsonb_typeof(answers) = 'object'),
  window_from           timestamptz,
  window_to             timestamptz,
  document_version_ids  uuid[] not null default '{}',
  row_version           integer not null default 1,
  created_at            timestamptz not null default now(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, venue_id, permit_id) references core.permit (customer_id, venue_id, id)
);
select core.attach_standard_triggers('core.permit_draft', 'answers,window_from,window_to,document_version_ids');

create table core.permit_version (
  id                     uuid primary key default gen_random_uuid(),
  customer_id            uuid not null,
  venue_id               uuid not null,
  permit_id              uuid not null,
  version_no             integer not null check (version_no > 0),
  revision_id            uuid not null,
  class_version_id       uuid not null,
  answers                jsonb not null,
  planned_window         tstzrange not null check (not isempty(planned_window) and not lower_inf(planned_window) and not upper_inf(planned_window)),
  document_version_ids   uuid[] not null,
  declaration            jsonb not null,
  declaration_sha256     bytea not null check (length(declaration_sha256) = 32),
  declared_by_person_id  uuid not null,
  responds_to_rfi_id     uuid,
  decision_context_id    uuid not null references core.decision_context,
  row_version            integer not null default 1,
  created_at             timestamptz not null default now(),
  created_by_user_id     uuid default auth.uid(),
  foreign key (customer_id, venue_id, permit_id) references core.permit (customer_id, venue_id, id),
  foreign key (customer_id, venue_id, revision_id) references core.work_package_revision (customer_id, venue_id, id),
  foreign key (customer_id, venue_id, class_version_id) references core.permit_class_version (customer_id, venue_id, id),
  foreign key (customer_id, declared_by_person_id) references core.person (customer_id, id),
  unique (permit_id, version_no),
  unique (customer_id, venue_id, id)
);
select core.attach_standard_triggers('core.permit_version', null);
alter table core.permit add foreign key (customer_id, venue_id, current_version_id) references core.permit_version (customer_id, venue_id, id);

-- ---------------------------------------------------------------------------
-- Approval steps (Q76-Q83). Steps are instantiated per version on submission; every
-- decision is a new immutable row and the latest one counts.
-- ---------------------------------------------------------------------------
create table core.permit_step (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  venue_id              uuid not null,
  permit_version_id     uuid not null,
  step_key              text not null,
  name                  text not null,
  kind                  text not null check (kind in ('review', 'occupier', 'landlord_operator', 'external')),
  group_no              integer not null check (group_no > 0),
  party_organisation_id uuid,
  area_ids              uuid[] not null check (cardinality(area_ids) > 0),
  system_ids            uuid[] not null,
  row_version           integer not null default 1,
  created_at            timestamptz not null default now(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, venue_id, permit_version_id) references core.permit_version (customer_id, venue_id, id),
  foreign key (customer_id, party_organisation_id) references core.organisation (customer_id, id),
  unique (permit_version_id, step_key, party_organisation_id),
  unique (customer_id, venue_id, id),
  check ((kind in ('occupier', 'landlord_operator')) = (party_organisation_id is not null))
);
select core.attach_standard_triggers('core.permit_step', null);

-- Q72: scope wording, never a bare "approved".
create table core.step_decision (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  venue_id              uuid not null,
  permit_step_id        uuid not null,
  outcome               text not null check (outcome in ('no_further_comments', 'conditions', 'more_information',
                                                         'refused', 'not_applicable', 'reopened')),
  reason                text not null check (length(btrim(reason)) > 0),
  scope_wording         text check (scope_wording is null or scope_wording !~* '(approv|certif|verif|guarant|complian|safe to)'),
  decider_person_id     uuid not null,
  decision_context_id   uuid not null references core.decision_context,
  row_version           integer not null default 1,
  created_at            timestamptz not null default clock_timestamp(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, venue_id, permit_step_id) references core.permit_step (customer_id, venue_id, id),
  foreign key (customer_id, decider_person_id) references core.person (customer_id, id),
  unique (customer_id, venue_id, id),
  check (outcome not in ('no_further_comments', 'conditions') or length(btrim(coalesce(scope_wording, ''))) > 0)
);
select core.attach_standard_triggers('core.step_decision', null);

create table core.permit_condition (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  venue_id              uuid not null,
  step_decision_id      uuid not null,
  text                  text not null check (length(btrim(text)) > 0),
  acknowledge_at_acceptance boolean not null,
  row_version           integer not null default 1,
  created_at            timestamptz not null default now(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, venue_id, step_decision_id) references core.step_decision (customer_id, venue_id, id)
);
select core.attach_standard_triggers('core.permit_condition', null);

create table core.external_decision (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  venue_id              uuid not null,
  step_decision_id      uuid not null unique,
  external_decider      text not null check (length(btrim(external_decider)) > 0),
  external_organisation text not null check (length(btrim(external_organisation)) > 0),
  reference             text,
  scope                 text not null check (length(btrim(scope)) > 0),
  decided_on            date not null,
  conditions            text,
  document_version_ids  uuid[] not null default '{}',
  row_version           integer not null default 1,
  created_at            timestamptz not null default now(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, venue_id, step_decision_id) references core.step_decision (customer_id, venue_id, id)
);
select core.attach_standard_triggers('core.external_decision', null);

-- Q70: items against answers, documents or the job, with one consolidated message.
create table core.rfi (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  venue_id              uuid not null,
  step_decision_id      uuid not null unique,
  permit_version_id     uuid not null,
  message               text not null check (length(btrim(message)) > 0),
  items                 jsonb not null check (jsonb_typeof(items) = 'array' and jsonb_array_length(items) > 0),
  row_version           integer not null default 1,
  created_at            timestamptz not null default now(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, venue_id, step_decision_id) references core.step_decision (customer_id, venue_id, id),
  foreign key (customer_id, venue_id, permit_version_id) references core.permit_version (customer_id, venue_id, id),
  unique (customer_id, venue_id, id)
);
select core.attach_standard_triggers('core.rfi', null);
alter table core.permit_version add foreign key (customer_id, venue_id, responds_to_rfi_id) references core.rfi (customer_id, venue_id, id);

create table core.rfi_response (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  venue_id              uuid not null,
  rfi_id                uuid not null unique,
  permit_version_id     uuid not null unique,
  responses             jsonb not null check (jsonb_typeof(responses) = 'array'),
  responder_person_id   uuid not null,
  row_version           integer not null default 1,
  created_at            timestamptz not null default now(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, venue_id, rfi_id) references core.rfi (customer_id, venue_id, id),
  foreign key (customer_id, venue_id, permit_version_id) references core.permit_version (customer_id, venue_id, id),
  foreign key (customer_id, responder_person_id) references core.person (customer_id, id)
);
select core.attach_standard_triggers('core.rfi_response', null);

-- ---------------------------------------------------------------------------
-- The classes a job needs: recommendations accepted or upheld on its screened revision,
-- plus any class an appointed authority required (P5-12). Work Approval excluded.
-- ---------------------------------------------------------------------------
create function core.wp_required_classes(p_wp_id uuid) returns setof uuid
language sql stable security definer set search_path = '' as $$
  select x.permit_class_id from core.screening_recommendation x
    join core.work_package wp on wp.id = x.work_package_id
   where wp.id = p_wp_id and x.revision_id = wp.screened_revision_id and x.status in ('accepted', 'upheld')
  union
  select r.permit_class_id from core.class_requirement r
    join core.work_package wp on wp.id = r.work_package_id
   where wp.id = p_wp_id and r.revision_id = wp.screened_revision_id $$;

-- ---------------------------------------------------------------------------
-- Invariant 4 (P5-4): a Work Approval cannot become approved for issue unless every
-- class the job requires has a child permit that is not cancelled, refused or expired.
-- Enforced here, not in the API. Issue-time rules (children approved before the parent
-- is issued; a child issued only after its parent) arrive with issue in 5b.
-- ---------------------------------------------------------------------------
create function core.wa_children_ready(p_wa_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select not exists (select 1 from core.permit wa, core.wp_required_classes(wa.work_package_id) rc
                      where wa.id = p_wa_id
                        and not exists (select 1 from core.permit c
                                         where c.parent_permit_id = wa.id and c.permit_class_id = rc
                                           and c.status not in ('cancelled', 'refused', 'expired'))) $$;

create function core.permit_dependency_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.kind = 'work_approval' and new.status = 'approved_for_issue' and new.status is distinct from old.status
     and not core.wa_children_ready(new.id) then
    raise exception 'a Work Approval cannot be approved for issue while a permit the job requires is refused, cancelled, expired or missing'
      using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger permit_dependency_guard before update of status on core.permit
  for each row execute function core.permit_dependency_guard();
