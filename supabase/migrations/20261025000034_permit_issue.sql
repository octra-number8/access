-- 0034 Permits: calendars, notice, exceptions, team, issue, acceptance and expiry
--      (phase 5b, D-018): catalogue, states, tables and configuration
--
-- Notice is measured against the venue's own calendar and each class's own notice rule;
-- neither has a default (P5-8). Late or clashing requests can be submitted but not
-- issued without a recorded exception decision, which may be a refusal (P5-9). Issue
-- freezes an immutable snapshot (invariant 5); acceptance by the named supervisor after
-- a recorded briefing makes a permit Active; expiry is a re-runnable service job that
-- only ever removes authority (invariant 10).
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

-- ---------------------------------------------------------------------------
-- Catalogue
-- ---------------------------------------------------------------------------
insert into core.authority_action (code, basis, delegable, description) values
  ('venue_calendar.publish',          'tenant_admin',       false, 'Publish the venue''s working calendar (Q85, Q86)'),
  ('restriction_window.create',       'tenant_admin',       false, 'Record a period when work in some areas is restricted'),
  ('restriction_window.end',          'tenant_admin',       false, 'End a restriction window'),
  ('permit.request_exception',        'organisation_admin', false, 'Ask for a late-notice or restriction exception (Q90)'),
  ('permit.request_exception_for_venue', 'tenant_admin',    false, 'Ask for an exception, for the venue'),
  ('permit.exception_decide',         'appointment',        true,  'Allow or refuse a late-notice or restriction exception (Q92)'),
  ('permit.set_team',                 'organisation_admin', false, 'Name the supervisor and team for a permit'),
  ('permit.set_team_for_venue',       'tenant_admin',       false, 'Name the supervisor and team, for the venue'),
  ('permit.issue',                    'appointment',        false, 'Issue a permit (Q98)'),
  ('permit.accept',                   'subject',            false, 'Accept an issued permit at the workface (Q100)'),
  ('permit.expire',                   'service',            false, 'Record that a permit''s window has ended');

alter table core.service_account drop constraint service_account_purpose_check;
alter table core.service_account add constraint service_account_purpose_check
  check (purpose in ('malware_scanner', 'notification_sender', 'permit_expiry'));
insert into core.service_action (purpose, action_code) values ('permit_expiry', 'permit.expire');

insert into core.state_transition (machine, from_state, to_state, required_action) values
  ('permit', 'approved_for_issue',         'issued_awaiting_acceptance', 'permit.issue'),
  ('permit', 'issued_awaiting_acceptance', 'active',                     'permit.accept'),
  ('permit', 'approved_for_issue',         'expired',                    'permit.expire'),
  ('permit', 'issued_awaiting_acceptance', 'expired',                    'permit.expire'),
  ('permit', 'active',                     'expired',                    'permit.expire');

-- ---------------------------------------------------------------------------
-- The venue's working calendar (Q85, Q86): immutable versions, each with an owner and
-- an effective date. No default calendar: until one is published, notice cannot be
-- measured and no permit can be submitted (P5-8).
-- ---------------------------------------------------------------------------
create table core.venue_calendar_version (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  venue_id             uuid not null,
  working_weekdays     integer[] not null check (cardinality(working_weekdays) > 0 and working_weekdays <@ array[1, 2, 3, 4, 5, 6, 7]),
  closures             date[] not null,
  cutoff_time          time not null,
  owner_person_id      uuid not null,
  effective_from       timestamptz not null,
  change_reason        text not null check (length(btrim(change_reason)) > 0),
  decision_context_id  uuid not null references core.decision_context,
  row_version          integer not null default 1,
  created_at           timestamptz not null default now(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, owner_person_id) references core.person (customer_id, id)
);
select core.attach_standard_triggers('core.venue_calendar_version', null);

-- Areas whose work is restricted for a period: an event phase, or explicit times.
create table core.restriction_window (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  venue_id             uuid not null,
  area_ids             uuid[] not null check (cardinality(area_ids) > 0),
  during               tstzrange not null check (not isempty(during) and not lower_inf(during) and not upper_inf(during)),
  event_phase_id       uuid,
  effect               text not null check (effect in ('no_work', 'decision_required')),
  reason               text not null check (length(btrim(reason)) > 0),
  owner_person_id      uuid not null,
  ended_at             timestamptz,
  row_version          integer not null default 1,
  created_at           timestamptz not null default now(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (event_phase_id) references core.event_phase (id),
  foreign key (customer_id, owner_person_id) references core.person (customer_id, id),
  unique (customer_id, venue_id, id)
);
select core.attach_standard_triggers('core.restriction_window', 'ended_at');

-- ---------------------------------------------------------------------------
-- Exceptions (Q90-Q96, P5-9): the applicant asks, an appointed authority decides.
-- ---------------------------------------------------------------------------
create table core.exception_request (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  venue_id              uuid not null,
  permit_version_id     uuid not null,
  kind                  text not null check (kind in ('late_notice', 'restriction_conflict')),
  restriction_window_id uuid,
  reason                text not null check (length(btrim(reason)) > 0),
  consequence_of_delay  text not null check (length(btrim(consequence_of_delay)) > 0),
  requested_by_person_id uuid not null,
  decision_context_id   uuid not null references core.decision_context,
  row_version           integer not null default 1,
  created_at            timestamptz not null default now(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, venue_id, permit_version_id) references core.permit_version (customer_id, venue_id, id),
  foreign key (customer_id, venue_id, restriction_window_id) references core.restriction_window (customer_id, venue_id, id),
  foreign key (customer_id, requested_by_person_id) references core.person (customer_id, id),
  unique (customer_id, venue_id, id),
  check ((kind = 'restriction_conflict') = (restriction_window_id is not null))
);
create unique index exception_request_one_per_kind on core.exception_request
  (permit_version_id, kind, coalesce(restriction_window_id, '00000000-0000-0000-0000-000000000000'));
select core.attach_standard_triggers('core.exception_request', null);

create table core.exception_decision (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  venue_id              uuid not null,
  exception_request_id  uuid not null unique,
  outcome               text not null check (outcome in ('allowed', 'refused')),
  conditions            text,
  reason                text not null check (length(btrim(reason)) > 0),
  decider_person_id     uuid not null,
  decision_context_id   uuid not null references core.decision_context,
  row_version           integer not null default 1,
  created_at            timestamptz not null default now(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, venue_id, exception_request_id) references core.exception_request (customer_id, venue_id, id),
  foreign key (customer_id, decider_person_id) references core.person (customer_id, id)
);
select core.attach_standard_triggers('core.exception_decision', null);

-- ---------------------------------------------------------------------------
-- The team (Q99): named before issue and frozen into the issue snapshot. Live changes
-- after issue are phase 6.
-- ---------------------------------------------------------------------------
create table core.permit_team_member (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  venue_id             uuid not null,
  permit_id            uuid not null,
  person_id            uuid not null,
  role                 text not null check (role in ('supervisor', 'operative')),
  added_by_person_id   uuid not null,
  removed_at           timestamptz,
  row_version          integer not null default 1,
  created_at           timestamptz not null default now(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, venue_id, permit_id) references core.permit (customer_id, venue_id, id),
  foreign key (customer_id, person_id) references core.person (customer_id, id),
  foreign key (customer_id, added_by_person_id) references core.person (customer_id, id)
);
create unique index permit_team_one_live on core.permit_team_member (permit_id, person_id) where removed_at is null;
create unique index permit_team_one_supervisor on core.permit_team_member (permit_id) where removed_at is null and role = 'supervisor';
select core.attach_standard_triggers('core.permit_team_member', 'removed_at');

-- ---------------------------------------------------------------------------
-- Issue snapshot (invariant 5) and acceptance (Q100-Q103)
-- ---------------------------------------------------------------------------
create table core.issue_snapshot (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  venue_id              uuid not null,
  permit_id             uuid not null,
  permit_version_id     uuid not null,
  content               jsonb not null,
  content_sha256        bytea not null check (length(content_sha256) = 32),
  issuer_person_id      uuid not null,
  issued_at             timestamptz not null default clock_timestamp(),
  decision_context_id   uuid not null references core.decision_context,
  row_version           integer not null default 1,
  created_at            timestamptz not null default now(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, venue_id, permit_id) references core.permit (customer_id, venue_id, id),
  foreign key (customer_id, venue_id, permit_version_id) references core.permit_version (customer_id, venue_id, id),
  foreign key (customer_id, issuer_person_id) references core.person (customer_id, id),
  unique (customer_id, venue_id, id)
);
select core.attach_standard_triggers('core.issue_snapshot', null);

create table core.permit_acceptance (
  id                     uuid primary key default gen_random_uuid(),
  customer_id            uuid not null,
  venue_id               uuid not null,
  issue_snapshot_id      uuid not null unique,
  supervisor_person_id   uuid not null,
  declaration            jsonb not null,
  declaration_sha256     bytea not null check (length(declaration_sha256) = 32),
  acknowledged_condition_ids uuid[] not null,
  briefed_person_ids     uuid[] not null check (cardinality(briefed_person_ids) > 0),
  briefed_at             timestamptz not null,
  accepted_at            timestamptz not null default clock_timestamp(),
  decision_context_id    uuid not null references core.decision_context,
  row_version            integer not null default 1,
  created_at             timestamptz not null default now(),
  created_by_user_id     uuid default auth.uid(),
  foreign key (customer_id, venue_id, issue_snapshot_id) references core.issue_snapshot (customer_id, venue_id, id),
  foreign key (customer_id, supervisor_person_id) references core.person (customer_id, id),
  check (briefed_at <= accepted_at)
);
select core.attach_standard_triggers('core.permit_acceptance', null);

alter table core.permit add column issue_snapshot_id uuid;
alter table core.permit add foreign key (customer_id, venue_id, issue_snapshot_id) references core.issue_snapshot (customer_id, venue_id, id);
drop trigger b_guard_update on core.permit;
create trigger b_guard_update before update on core.permit
  for each row execute function core.guard_update('status,current_version_id,issue_snapshot_id');

-- ---------------------------------------------------------------------------
-- Class configuration gains its notice rule and evidence (P5-5, P5-8). Neither has a
-- default: both must be present in an approved configuration, even if zero or empty.
--   notice:   {amount, unit: working_days|calendar_days|hours, cutoff_applies, restart_on_resubmission,
--              longer?: [{amount, unit, area_id | system_type_id | event_phase}]}
--   evidence: {induction_course_ids: [...], team_competency_type_ids: [...],
--              supervisor_competency_type_ids: [...]}
-- ---------------------------------------------------------------------------
create function core.notice_problems(p_venue_id uuid, n jsonb, p_label text) returns text[]
language sql stable security definer set search_path = '' as $$
  select array_remove(array[
    case when jsonb_typeof(n -> 'amount') is distinct from 'number' or (n ->> 'amount')::numeric < 0
              or (n ->> 'amount')::numeric <> floor((n ->> 'amount')::numeric)
         then p_label || ' needs a whole number of notice (zero is allowed, but must be chosen).' end,
    case when coalesce(n ->> 'unit', '') not in ('working_days', 'calendar_days', 'hours')
         then p_label || ' must be in working days, calendar days or hours.' end], null) $$;

create or replace function core.validate_class_config(p_venue_id uuid, p_content jsonb, p_strict boolean) returns text[]
language plpgsql stable security definer set search_path = '' as $$
declare
  errs   text[] := '{}';
  s      jsonb;
  keys   text[] := '{}';
  groups integer[] := '{}';
  n      jsonb := p_content -> 'notice';
  e      jsonb := p_content -> 'evidence';
  x      jsonb;
  kv     record;
begin
  if jsonb_typeof(p_content -> 'questions') is distinct from 'array' or jsonb_typeof(p_content -> 'route') is distinct from 'array'
     or jsonb_typeof(p_content -> 'submission_declaration') is distinct from 'array'
     or jsonb_typeof(p_content -> 'acceptance_declaration') is distinct from 'array' then
    return array['A class configuration needs questions, a route, and submission and acceptance declarations (lists).'];
  end if;
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
  if exists (select 1 from jsonb_array_elements(p_content -> 'submission_declaration') d
              where jsonb_typeof(d) <> 'string' or length(btrim(d #>> '{}')) = 0)
     or exists (select 1 from jsonb_array_elements(p_content -> 'acceptance_declaration') d
                 where jsonb_typeof(d) <> 'string' or length(btrim(d #>> '{}')) = 0) then
    errs := errs || text 'Every declaration item needs wording.';
  end if;
  if n is not null then
    errs := errs || core.notice_problems(p_venue_id, n, 'The notice rule');
    if jsonb_typeof(n -> 'cutoff_applies') is distinct from 'boolean' then
      errs := errs || text 'Choose whether the venue''s cut-off time applies to this notice.';
    end if;
    if jsonb_typeof(n -> 'restart_on_resubmission') is distinct from 'boolean' then
      errs := errs || text 'Choose whether a resubmitted request restarts the notice (Q88).';
    end if;
    for x in select * from jsonb_array_elements(coalesce(n -> 'longer', '[]')) loop
      errs := errs || core.notice_problems(p_venue_id, x, 'A longer notice rule');
      if (x ->> 'area_id') is null and (x ->> 'system_type_id') is null and coalesce(x ->> 'event_phase', '') not in ('build', 'live', 'breakdown') then
        errs := errs || text 'A longer notice rule applies to an area, a system type or an event phase.';
      end if;
    end loop;
  end if;
  if e is not null then
    for kv in select * from jsonb_each(e) loop
      if kv.key not in ('induction_course_ids', 'team_competency_type_ids', 'supervisor_competency_type_ids')
         or jsonb_typeof(kv.value) <> 'array' then
        errs := errs || text 'Evidence lists induction courses, team competencies and supervisor competencies.';
      end if;
    end loop;
    if exists (select 1 from jsonb_array_elements_text(coalesce(e -> 'induction_course_ids', '[]')) c
                where not exists (select 1 from core.induction_course k where k.id::text = c and k.venue_id = p_venue_id))
       or exists (select 1 from jsonb_array_elements_text(coalesce(e -> 'team_competency_type_ids', '[]') || coalesce(e -> 'supervisor_competency_type_ids', '[]')) c
                   where not exists (select 1 from core.competency_type k where k.id::text = c and k.venue_id = p_venue_id)) then
      errs := errs || text 'Evidence refers to an induction or competency that does not exist at this venue.';
    end if;
  end if;
  if p_strict then
    if jsonb_array_length(p_content -> 'route') = 0 then
      errs := errs || text 'A class needs at least one approval step.';
    end if;
    if not exists (select 1 from jsonb_array_elements(p_content -> 'route') r where r ->> 'kind' = 'review' and not r ? 'when') then
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
    if n is null then
      errs := errs || text 'Set the notice this class needs (P5-8): there is no default, but zero can be chosen.';
    end if;
    if e is null or not (e ? 'induction_course_ids' and e ? 'team_competency_type_ids' and e ? 'supervisor_competency_type_ids') then
      errs := errs || text 'State the inductions and competencies the team and supervisor need (they may be none, but must be stated).';
    end if;
  end if;
  return errs;
end $$;

-- ---------------------------------------------------------------------------
-- Invariant 4 at issue (P5-4): a Work Approval is issued only when every class the job
-- requires has a child at least approved for issue; a child is issued only after its
-- Work Approval. Enforced on the status write itself.
-- ---------------------------------------------------------------------------
create or replace function core.permit_dependency_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status is not distinct from old.status then
    return new;
  end if;
  if new.kind = 'work_approval' and new.status = 'approved_for_issue' and not core.wa_children_ready(new.id) then
    raise exception 'a Work Approval cannot be approved for issue while a permit the job requires is refused, cancelled, expired or missing'
      using errcode = 'check_violation';
  end if;
  if new.kind = 'work_approval' and new.status = 'issued_awaiting_acceptance'
     and exists (select 1 from core.wp_required_classes(new.work_package_id) rc
                  where not exists (select 1 from core.permit c
                                     where c.parent_permit_id = new.id and c.permit_class_id = rc
                                       and c.status in ('approved_for_issue', 'issued_awaiting_acceptance', 'active'))) then
    raise exception 'a Work Approval cannot be issued until every permit the job requires is approved for issue'
      using errcode = 'check_violation';
  end if;
  if new.kind = 'child' and new.status = 'issued_awaiting_acceptance'
     and (select status from core.permit where id = new.parent_permit_id) not in ('issued_awaiting_acceptance', 'active') then
    raise exception 'a permit cannot be issued before its Work Approval' using errcode = 'check_violation';
  end if;
  return new;
end $$;
