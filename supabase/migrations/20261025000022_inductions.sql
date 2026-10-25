-- 0022 Inductions (phase 3a, D-015, D-016): catalogue, minimal events, courses with
--      versioned content, personal links, attempts, completions, invalidations
--
-- Content model follows OCTRA Induct (sections/modules -> blocks; questions with options,
-- explanations; declaration), stored per version as one validated document. Published
-- versions are immutable and carry a SHA-256 of their snapshot. Completions are
-- immutable; invalidation is a separate record (Q45).
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

-- ---------------------------------------------------------------------------
-- Catalogue
-- ---------------------------------------------------------------------------
alter table core.authority_action drop constraint authority_action_basis_check;
alter table core.authority_action add constraint authority_action_basis_check
  check (basis in ('appointment', 'tenant_admin', 'platform_admin', 'subject',
                   'organisation_admin', 'invitee', 'service', 'derived', 'link_holder'));

insert into core.authority_action (code, basis, delegable, description) values
  ('event.create',                    'tenant_admin',       false, 'Create an event at a venue'),
  ('event_phase.create',              'tenant_admin',       false, 'Add a build, live or breakdown phase to an event'),
  ('induction_media.upload',          'tenant_admin',       false, 'Upload media for induction content'),
  ('induction_course.create',         'tenant_admin',       false, 'Create an induction course'),
  ('course_version.create_draft',     'tenant_admin',       false, 'Start a draft version of a course'),
  ('course_version.save_draft',       'tenant_admin',       false, 'Edit a draft version''s content'),
  ('course_version.set_settings',     'tenant_admin',       false, 'Set a draft''s assessment and validity settings'),
  ('course_open_point.add',           'tenant_admin',       false, 'Record an open point that blocks publication'),
  ('course_open_point.resolve',       'tenant_admin',       false, 'Record how an open point was resolved'),
  ('course_version.submit',           'tenant_admin',       false, 'Submit a draft for review by the H&S authority'),
  ('induction_link.issue',            'tenant_admin',       false, 'Send a person a personal induction link'),
  ('induction_link.issue_for_person', 'organisation_admin', false, 'Send one of your people a personal induction link'),
  ('induction_link.revoke',           'tenant_admin',       false, 'Revoke a personal induction link'),
  ('induction_link.claim',            'link_holder',        false, 'Open a personal induction link'),
  ('course_version.publish',          'appointment',        false, 'Publish a reviewed induction version (Q44)'),
  ('course_version.return',           'appointment',        false, 'Return a submitted version to draft with reasons'),
  ('course_version.withdraw',         'appointment',        false, 'Withdraw a published version'),
  ('course_version.supersede',        'derived',            false, 'Mark the previous published version superseded'),
  ('induction.facilitate',            'appointment',        true,  'Record an assisted or facilitated completion (Q47)'),
  ('induction.invalidate',            'appointment',        true,  'Invalidate a completion (Q45)'),
  ('induction.start',                 'subject',            false, 'Start an induction attempt'),
  ('induction.progress',              'subject',            false, 'Record progress through a module'),
  ('induction.answer',                'subject',            false, 'Answer an induction question'),
  ('induction.finish',                'subject',            false, 'Finish an attempt and receive the result'),
  ('induction.complete',              'subject',            false, 'Make the declaration and complete the induction');

insert into core.derived_action (parent_action, child_action) values ('course_version.publish', 'course_version.supersede');

insert into core.state_machine (code, table_name) values
  ('course_version',    'core.course_version'),
  ('induction_attempt', 'core.induction_attempt'),
  ('induction_link',    'core.induction_link');

insert into core.state_initial (machine, state, required_action) values
  ('course_version',    'draft',       'course_version.create_draft'),
  ('induction_attempt', 'in_progress', 'induction.start'),
  ('induction_link',    'issued',      'induction_link.issue'),
  ('induction_link',    'issued',      'induction_link.issue_for_person');

insert into core.state_transition (machine, from_state, to_state, required_action) values
  ('course_version',    'draft',       'in_review',  'course_version.submit'),
  ('course_version',    'in_review',   'draft',      'course_version.return'),
  ('course_version',    'in_review',   'published',  'course_version.publish'),
  ('course_version',    'published',   'superseded', 'course_version.supersede'),
  ('course_version',    'published',   'withdrawn',  'course_version.withdraw'),
  ('induction_attempt', 'in_progress', 'passed',     'induction.finish'),
  ('induction_attempt', 'in_progress', 'failed',     'induction.finish'),
  ('induction_attempt', 'passed',      'completed',  'induction.complete'),
  ('induction_link',    'issued',      'revoked',    'induction_link.revoke');

-- ---------------------------------------------------------------------------
-- Minimal events (P3-3). Wider use arrives in phases 4-5.
-- ---------------------------------------------------------------------------
create table core.event (
  id                 uuid primary key default gen_random_uuid(),
  customer_id        uuid not null,
  venue_id           uuid not null,
  code               text not null check (code ~ '^[A-Za-z0-9_-]{1,40}$'),
  name               text not null check (length(btrim(name)) > 0),
  valid_during       tstzrange not null check (not lower_inf(valid_during) and not upper_inf(valid_during)),
  row_version        integer not null default 1,
  created_at         timestamptz not null default now(),
  created_by_user_id uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  unique (venue_id, code),
  unique (customer_id, venue_id, id)
);
select core.attach_standard_triggers('core.event', 'name');

create table core.event_phase (
  id                 uuid primary key default gen_random_uuid(),
  customer_id        uuid not null,
  venue_id           uuid not null,
  event_id           uuid not null,
  phase              text not null check (phase in ('build', 'live', 'breakdown')),
  valid_during       tstzrange not null check (not lower_inf(valid_during) and not upper_inf(valid_during)),
  row_version        integer not null default 1,
  created_at         timestamptz not null default now(),
  created_by_user_id uuid default auth.uid(),
  foreign key (customer_id, venue_id, event_id) references core.event (customer_id, venue_id, id),
  exclude using gist (event_id with =, phase with =, valid_during with &&)
);
select core.attach_standard_triggers('core.event_phase', null);

-- ---------------------------------------------------------------------------
-- Media for induction content
-- ---------------------------------------------------------------------------
create table core.induction_media (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  venue_id              uuid not null,
  storage_path          text not null unique check (storage_path ~ '^[0-9a-f-]{36}/media/[0-9a-f-]{36}$'),
  sha256                bytea not null check (length(sha256) = 32),
  media_type            text not null check (media_type in
                          ('image/jpeg', 'image/png', 'application/pdf', 'text/vtt', 'video/mp4')),
  size_bytes            bigint not null check (size_bytes > 0 and size_bytes <= case when media_type = 'video/mp4'
                                                                                    then 209715200 else 20971520 end),
  original_name         text,
  uploaded_by_person_id uuid not null,
  scan_status           text not null check (scan_status in ('pending', 'not_scanned', 'clean', 'infected', 'rejected')),
  row_version           integer not null default 1,
  created_at            timestamptz not null default now(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, uploaded_by_person_id) references core.person (customer_id, id),
  unique (customer_id, id)
);
select core.attach_standard_triggers('core.induction_media', 'scan_status');

-- ---------------------------------------------------------------------------
-- Courses and versions
-- ---------------------------------------------------------------------------
create table core.induction_course (
  id                 uuid primary key default gen_random_uuid(),
  customer_id        uuid not null,
  venue_id           uuid not null,
  event_id           uuid,
  code               text not null check (code ~ '^[A-Za-z0-9_-]{1,40}$'),
  title              text not null check (length(btrim(title)) > 0),
  audience           text,
  row_version        integer not null default 1,
  created_at         timestamptz not null default now(),
  created_by_user_id uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, venue_id, event_id) references core.event (customer_id, venue_id, id),
  unique (venue_id, code),
  unique (customer_id, venue_id, id)
);
select core.attach_standard_triggers('core.induction_course', 'title,audience');

-- Assessment and validity settings are required before submission and have no
-- defaults (CLAUDE.md §9, P3-5). Content is mutable only while the version is a draft.
create table core.course_version (
  id                           uuid primary key default gen_random_uuid(),
  customer_id                  uuid not null,
  venue_id                     uuid not null,
  course_id                    uuid not null,
  version_no                   integer not null check (version_no > 0),
  language                     text not null check (language ~ '^[a-z]{2}(-[A-Z]{2})?$'),
  status                       text not null,
  content                      jsonb not null default '{"modules": [], "questions": [], "declaration": []}',
  source_ref                   text,
  pass_mark_percent            integer check (pass_mark_percent between 1 and 100),
  all_critical_required        boolean,
  max_attempts                 integer check (max_attempts between 1 and 20),
  retry_delay_minutes          integer check (retry_delay_minutes between 0 and 10080),
  shuffle_options              boolean,
  validity_mode                text check (validity_mode in ('days_from_completion', 'fixed_date')),
  validity_days                integer check (validity_days between 1 and 3660),
  validity_until               timestamptz,
  signature_mode               text check (signature_mode in ('typed', 'typed_or_drawn')),
  authored_by_person_id        uuid not null,
  submitted_by_person_id       uuid,
  published_by_person_id       uuid,
  published_at                 timestamptz,
  return_reason                text,
  content_sha256               bytea,
  row_version                  integer not null default 1,
  created_at                   timestamptz not null default now(),
  created_by_user_id           uuid default auth.uid(),
  foreign key (customer_id, venue_id, course_id) references core.induction_course (customer_id, venue_id, id),
  foreign key (customer_id, authored_by_person_id) references core.person (customer_id, id),
  foreign key (customer_id, submitted_by_person_id) references core.person (customer_id, id),
  foreign key (customer_id, published_by_person_id) references core.person (customer_id, id),
  unique (course_id, version_no),
  unique (customer_id, venue_id, id),
  check ((validity_mode = 'days_from_completion') = (validity_days is not null) or validity_mode is null),
  check ((validity_mode = 'fixed_date') = (validity_until is not null) or validity_mode is null),
  check ((status in ('published', 'superseded', 'withdrawn')) = (content_sha256 is not null))
);
select core.attach_standard_triggers('core.course_version',
  'status,content,source_ref,pass_mark_percent,all_critical_required,max_attempts,retry_delay_minutes,shuffle_options,'
  || 'validity_mode,validity_days,validity_until,signature_mode,submitted_by_person_id,published_by_person_id,'
  || 'published_at,return_reason,content_sha256',
  null, true);

-- Content and settings change only while the version is a draft. After publication
-- only the status may move on (superseded, withdrawn).
create function core.course_version_freeze() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status <> 'draft' and (
       new.content is distinct from old.content or new.pass_mark_percent is distinct from old.pass_mark_percent
       or new.all_critical_required is distinct from old.all_critical_required
       or new.max_attempts is distinct from old.max_attempts or new.retry_delay_minutes is distinct from old.retry_delay_minutes
       or new.shuffle_options is distinct from old.shuffle_options or new.validity_mode is distinct from old.validity_mode
       or new.validity_days is distinct from old.validity_days or new.validity_until is distinct from old.validity_until
       or new.signature_mode is distinct from old.signature_mode or new.language is distinct from old.language
       or (old.content_sha256 is not null and new.content_sha256 is distinct from old.content_sha256)) then
    raise exception 'only a draft can be changed; start a new version instead' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger course_version_freeze before update on core.course_version
  for each row execute function core.course_version_freeze();

create table core.course_open_point (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  venue_id              uuid not null,
  course_version_id     uuid not null,
  text                  text not null check (length(btrim(text)) > 0),
  owner_text            text,
  resolved_at           timestamptz,
  resolution            text,
  resolved_by_person_id uuid,
  row_version           integer not null default 1,
  created_at            timestamptz not null default now(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, venue_id, course_version_id) references core.course_version (customer_id, venue_id, id),
  foreign key (customer_id, resolved_by_person_id) references core.person (customer_id, id),
  check ((resolved_at is null) = (resolution is null))
);
select core.attach_standard_triggers('core.course_open_point', 'resolved_at,resolution,resolved_by_person_id');

-- ---------------------------------------------------------------------------
-- Content validation. Structural checks apply to drafts; strict checks (captions,
-- alt text, explanations, released media) apply before submission and publication.
-- Returns plain-English problems; an empty array means valid.
-- ---------------------------------------------------------------------------
create function core.validate_course_content(p_customer_id uuid, p_content jsonb, p_strict boolean)
returns text[]
language plpgsql stable security definer
set search_path = ''
as $$
declare
  errs     text[] := '{}';
  m        jsonb;
  b        jsonb;
  q        jsonb;
  o        jsonb;
  d        jsonb;
  mkeys    text[] := '{}';
  qkeys    text[] := '{}';
  okeys    text[];
  ncorrect integer;
begin
  if jsonb_typeof(p_content -> 'modules') <> 'array' or jsonb_typeof(p_content -> 'questions') <> 'array'
     or jsonb_typeof(p_content -> 'declaration') <> 'array' then
    return array['Content must have modules, questions and declaration lists.'];
  end if;
  if p_strict and jsonb_array_length(p_content -> 'modules') = 0 then
    errs := errs || text 'An induction needs at least one module.';
  end if;

  for m in select * from jsonb_array_elements(p_content -> 'modules') loop
    if coalesce(m ->> 'key', '') !~ '^[a-z0-9-]{1,60}$' then
      errs := errs || format('Module "%s" needs a key of lower-case letters, digits and hyphens.', m ->> 'title');
    elsif (m ->> 'key') = any (mkeys) then
      errs := errs || format('Module key "%s" is used twice.', m ->> 'key');
    end if;
    mkeys := mkeys || (m ->> 'key');
    if length(btrim(coalesce(m ->> 'title', ''))) = 0 then errs := errs || text 'Every module needs a title.'; end if;
    if coalesce(m ->> 'kind', '') not in ('core', 'role', 'area', 'event_phase') then
      errs := errs || format('Module "%s" must be core, role, area or event_phase.', m ->> 'key');
    end if;
    if jsonb_typeof(m -> 'min_seconds') <> 'number' or (m ->> 'min_seconds')::integer < 0 then
      errs := errs || format('Module "%s" needs a minimum time in seconds (0 or more).', m ->> 'key');
    end if;
    if jsonb_typeof(m -> 'blocks') <> 'array' then
      errs := errs || format('Module "%s" needs a list of blocks.', m ->> 'key');
      continue;
    end if;
    for b in select * from jsonb_array_elements(m -> 'blocks') loop
      case b ->> 'type'
        when 'rich_text', 'callout' then
          if length(btrim(coalesce(b ->> 'text', ''))) = 0 then
            errs := errs || format('A text block in "%s" is empty.', m ->> 'key');
          end if;
        when 'image' then
          if p_strict and not coalesce((b ->> 'decorative')::boolean, false) and length(btrim(coalesce(b ->> 'alt', ''))) = 0 then
            errs := errs || format('An image in "%s" needs alt text, or must be marked decorative.', m ->> 'key');
          end if;
        when 'video' then
          if p_strict and (b ->> 'caption_media_id') is null then
            errs := errs || format('A video in "%s" needs a captions file.', m ->> 'key');
          end if;
          if p_strict and length(btrim(coalesce(b ->> 'transcript', ''))) = 0 then
            errs := errs || format('A video in "%s" needs a transcript.', m ->> 'key');
          end if;
        when 'document' then null;
        else
          errs := errs || format('Module "%s" has a block of unknown type "%s".', m ->> 'key', b ->> 'type');
      end case;
      if (b ->> 'type') in ('image', 'video', 'document') then
        if (b ->> 'media_id') is null then
          if p_strict then errs := errs || format('A %s in "%s" has no file yet.', b ->> 'type', m ->> 'key'); end if;
        elsif not exists (select 1 from core.induction_media x where x.id = (b ->> 'media_id')::uuid
                                                                  and x.customer_id = p_customer_id) then
          errs := errs || format('A %s in "%s" refers to a file that does not exist.', b ->> 'type', m ->> 'key');
        elsif p_strict and exists (select 1 from core.induction_media x where x.id = (b ->> 'media_id')::uuid
                                                                        and x.scan_status not in ('clean', 'not_scanned')) then
          errs := errs || format('A %s in "%s" is waiting for or failed its malware check.', b ->> 'type', m ->> 'key');
        end if;
      end if;
    end loop;
  end loop;

  for q in select * from jsonb_array_elements(p_content -> 'questions') loop
    if coalesce(q ->> 'key', '') !~ '^[a-z0-9-]{1,60}$' or (q ->> 'key') = any (qkeys) then
      errs := errs || format('Question "%s" needs a unique key.', left(q ->> 'stem', 40));
    end if;
    qkeys := qkeys || (q ->> 'key');
    if length(btrim(coalesce(q ->> 'stem', ''))) = 0 then errs := errs || text 'Every question needs a question.'; end if;
    if coalesce(q ->> 'placement', '') not in ('module', 'final') then
      errs := errs || format('Question "%s" must be placed after a module or at the end.', q ->> 'key');
    elsif (q ->> 'placement') = 'module' and not ((q ->> 'module_key') = any (mkeys)) then
      errs := errs || format('Question "%s" is linked to a module that does not exist.', q ->> 'key');
    end if;
    if coalesce(q ->> 'type', '') not in ('single_choice', 'multiple_select', 'true_false') then
      errs := errs || format('Question "%s" must be single choice, multiple select or true/false.', q ->> 'key');
    end if;
    if jsonb_typeof(q -> 'safety_critical') <> 'boolean' then
      errs := errs || format('Question "%s" must say whether it is safety-critical.', q ->> 'key');
    end if;
    if p_strict and length(btrim(coalesce(q ->> 'explanation', ''))) = 0 then
      errs := errs || format('Question "%s" needs an explanation for people who answer it wrongly.', q ->> 'key');
    end if;
    if jsonb_typeof(q -> 'options') <> 'array' or jsonb_array_length(q -> 'options') < 2 then
      errs := errs || format('Question "%s" needs at least two options.', q ->> 'key');
      continue;
    end if;
    okeys := '{}'; ncorrect := 0;
    for o in select * from jsonb_array_elements(q -> 'options') loop
      if coalesce(o ->> 'key', '') = '' or (o ->> 'key') = any (okeys) or length(btrim(coalesce(o ->> 'text', ''))) = 0 then
        errs := errs || format('Question "%s" has an option without a unique key or text.', q ->> 'key');
      end if;
      okeys := okeys || (o ->> 'key');
      if jsonb_typeof(o -> 'correct') <> 'boolean' then
        errs := errs || format('Every option of question "%s" must say whether it is correct.', q ->> 'key');
      elsif (o ->> 'correct')::boolean then
        ncorrect := ncorrect + 1;
      end if;
    end loop;
    if (q ->> 'type') in ('single_choice', 'true_false') and ncorrect <> 1 then
      errs := errs || format('Question "%s" must have exactly one correct option.', q ->> 'key');
    elsif (q ->> 'type') = 'multiple_select' and ncorrect < 1 then
      errs := errs || format('Question "%s" must have at least one correct option.', q ->> 'key');
    end if;
    if (q ->> 'type') = 'true_false' and jsonb_array_length(q -> 'options') <> 2 then
      errs := errs || format('Question "%s" is true/false, so it needs exactly two options.', q ->> 'key');
    end if;
  end loop;

  if p_strict and jsonb_array_length(p_content -> 'declaration') = 0 then
    errs := errs || text 'An induction needs at least one declaration item.';
  end if;
  for d in select * from jsonb_array_elements(p_content -> 'declaration') loop
    if coalesce(d ->> 'key', '') = '' or length(btrim(coalesce(d ->> 'text', ''))) = 0 then
      errs := errs || text 'Every declaration item needs a key and wording.';
    end if;
  end loop;
  return errs;
end $$;

-- ---------------------------------------------------------------------------
-- Personal induction links (P3-2)
-- ---------------------------------------------------------------------------
create table core.induction_link (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  venue_id             uuid not null,
  course_id            uuid not null,
  person_id            uuid not null,
  email                text not null check (email = lower(btrim(email)) and email like '%_@_%'),
  token_hash           bytea not null unique check (length(token_hash) = 32),
  expires_at           timestamptz not null,
  issued_by_person_id  uuid not null,
  via_organisation_id  uuid,
  status               text not null,
  revoked_at           timestamptz,
  claimed_at           timestamptz,
  row_version          integer not null default 1,
  created_at           timestamptz not null default now(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, venue_id, course_id) references core.induction_course (customer_id, venue_id, id),
  foreign key (customer_id, person_id) references core.person (customer_id, id),
  foreign key (customer_id, issued_by_person_id) references core.person (customer_id, id),
  foreign key (customer_id, via_organisation_id) references core.organisation (customer_id, id),
  check (expires_at > created_at),
  check ((status = 'revoked') = (revoked_at is not null))
);
select core.attach_standard_triggers('core.induction_link', 'status,revoked_at,claimed_at', null, true);

-- ---------------------------------------------------------------------------
-- Attempts, progress and responses
-- ---------------------------------------------------------------------------
create table core.induction_attempt (
  id                  uuid primary key default gen_random_uuid(),
  customer_id         uuid not null,
  venue_id            uuid not null,
  course_version_id   uuid not null,
  person_id           uuid not null,
  language            text not null,
  status              text not null,
  started_at          timestamptz not null default clock_timestamp(),
  finished_at         timestamptz,
  score_percent       integer check (score_percent between 0 and 100),
  critical_missed     integer check (critical_missed >= 0),
  row_version         integer not null default 1,
  created_at          timestamptz not null default now(),
  created_by_user_id  uuid default auth.uid(),
  foreign key (customer_id, venue_id, course_version_id) references core.course_version (customer_id, venue_id, id),
  foreign key (customer_id, person_id) references core.person (customer_id, id),
  unique (customer_id, id)
);
create unique index induction_attempt_one_open on core.induction_attempt (person_id, course_version_id)
  where status = 'in_progress';
select core.attach_standard_triggers('core.induction_attempt', 'status,finished_at,score_percent,critical_missed',
                                     'transition', true);

create table core.module_progress (
  id                  uuid primary key default gen_random_uuid(),
  customer_id         uuid not null,
  attempt_id          uuid not null,
  module_key          text not null,
  started_at          timestamptz not null default clock_timestamp(),
  completed_at        timestamptz,
  row_version         integer not null default 1,
  created_at          timestamptz not null default now(),
  created_by_user_id  uuid default auth.uid(),
  foreign key (customer_id, attempt_id) references core.induction_attempt (customer_id, id),
  unique (attempt_id, module_key)
);
select core.attach_standard_triggers('core.module_progress', 'completed_at');

-- Insert-only.
create table core.question_response (
  id                  uuid primary key default gen_random_uuid(),
  customer_id         uuid not null,
  attempt_id          uuid not null,
  question_key        text not null,
  option_keys         text[] not null check (cardinality(option_keys) > 0),
  correct             boolean not null,
  answered_at         timestamptz not null default clock_timestamp(),
  row_version         integer not null default 1,
  created_at          timestamptz not null default now(),
  created_by_user_id  uuid default auth.uid(),
  foreign key (customer_id, attempt_id) references core.induction_attempt (customer_id, id),
  unique (attempt_id, question_key)
);
select core.attach_standard_triggers('core.question_response', null);

-- ---------------------------------------------------------------------------
-- Completions (immutable) and invalidations
-- ---------------------------------------------------------------------------
create table core.induction_completion (
  id                       uuid primary key default gen_random_uuid(),
  customer_id              uuid not null,
  venue_id                 uuid not null,
  course_version_id        uuid not null,
  person_id                uuid not null,
  language                 text not null,
  method                   text not null check (method in ('self', 'assisted', 'facilitated')),
  attempt_id               uuid,
  facilitator_person_id    uuid,
  identity_check           text,
  understanding_check      text,
  declaration_sha256       bytea not null check (length(declaration_sha256) = 32),
  signature_kind           text not null check (signature_kind in ('typed', 'drawn', 'acknowledged_to_facilitator')),
  typed_name               text,
  completed_at             timestamptz not null default clock_timestamp(),
  valid_until              timestamptz not null,
  evidence_sha256          bytea not null check (length(evidence_sha256) = 32),
  decision_context_id      uuid not null references core.decision_context,
  row_version              integer not null default 1,
  created_at               timestamptz not null default now(),
  created_by_user_id       uuid default auth.uid(),
  foreign key (customer_id, venue_id, course_version_id) references core.course_version (customer_id, venue_id, id),
  foreign key (customer_id, person_id) references core.person (customer_id, id),
  foreign key (customer_id, attempt_id) references core.induction_attempt (customer_id, id),
  foreign key (customer_id, facilitator_person_id) references core.person (customer_id, id),
  unique (customer_id, id),
  check (valid_until > completed_at),
  check ((method = 'self') = (attempt_id is not null and facilitator_person_id is null)),
  check (method = 'self' or (facilitator_person_id is not null and identity_check is not null
                             and understanding_check is not null and facilitator_person_id <> person_id)),
  check (signature_kind <> 'typed' or length(btrim(coalesce(typed_name, ''))) > 0)
);
select core.attach_standard_triggers('core.induction_completion', null);

create table core.completion_invalidation (
  id                  uuid primary key default gen_random_uuid(),
  customer_id         uuid not null,
  venue_id            uuid not null,
  completion_id       uuid not null unique,
  reason_kind         text not null check (reason_kind in ('content_change', 'venue_instruction', 'breach_review')),
  reason              text not null check (length(btrim(reason)) > 0),
  decision_context_id uuid not null references core.decision_context,
  row_version         integer not null default 1,
  created_at          timestamptz not null default now(),
  created_by_user_id  uuid default auth.uid(),
  foreign key (customer_id, completion_id) references core.induction_completion (customer_id, id)
);
select core.attach_standard_triggers('core.completion_invalidation', null);
