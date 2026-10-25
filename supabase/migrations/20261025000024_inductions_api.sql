-- 0024 Inductions API (phase 3a, D-016)
--
-- Pattern as before: target, authz.require, write; status only via core.transition.
-- Checks that are about content or timing (not authority) run before authz.require
-- and return a refusal value, so a refused or invalid request never consumes its
-- request key. Where such a check would reveal anything about a record, authority is
-- evaluated first.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

-- ---------------------------------------------------------------------------
-- Helpers (not executable by clients)
-- ---------------------------------------------------------------------------

create function core.refuse(p_action text, p_code text, p_reason text, p_missing text, p_resolvable_by text,
                            p_extra jsonb default '{}')
returns jsonb language sql immutable set search_path = '' as $$
  select authz.deny(p_action, p_code, p_reason, p_missing, p_resolvable_by, p_extra) $$;

-- Evaluates without recording; on refusal, records it (via require) and returns it.
create function core.authorised_or_refusal(p_action text, p_target jsonb, p_key text, p_request jsonb,
                                           p_appt uuid default null, p_deleg uuid default null)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare v jsonb := authz.evaluate(p_action, p_target, p_appt, p_deleg);
begin
  if (v ->> 'allowed')::boolean then return null; end if;
  return authz.require(p_action, p_target, p_key, p_request, p_appt, p_deleg);
end $$;

create function core.current_version(p_course_id uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select id from core.course_version where course_id = p_course_id and status = 'published'
   order by version_no desc limit 1 $$;

-- Content for learners: everything except which options are correct.
create function core.learner_content(p_content jsonb) returns jsonb
language sql immutable set search_path = '' as $$
  select jsonb_build_object(
    'modules', p_content -> 'modules',
    'declaration', p_content -> 'declaration',
    'questions', coalesce((
      select jsonb_agg((q - 'options') || jsonb_build_object('options',
               (select jsonb_agg(o - 'correct') from jsonb_array_elements(q -> 'options') o)))
        from jsonb_array_elements(p_content -> 'questions') q), '[]'::jsonb)) $$;

create function core.has_valid_link(p_person_id uuid, p_course_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from core.induction_link l
                  where l.person_id = p_person_id and l.course_id = p_course_id
                    and l.status = 'issued' and now() < l.expires_at) $$;

create function core.settings_missing(v core.course_version) returns text[]
language sql immutable set search_path = '' as $$
  select array_remove(array[
    case when v.pass_mark_percent is null then 'pass mark' end,
    case when v.all_critical_required is null then 'whether every safety-critical question must be correct' end,
    case when v.max_attempts is null then 'maximum attempts' end,
    case when v.retry_delay_minutes is null then 'retry delay' end,
    case when v.shuffle_options is null then 'whether options are shuffled' end,
    case when v.validity_mode is null then 'how long a completion stays valid' end,
    case when v.signature_mode is null then 'how the declaration is signed' end], null) $$;

-- ---------------------------------------------------------------------------
-- Events (P3-3)
-- ---------------------------------------------------------------------------

create function api.create_event(p_idempotency_key text, p_venue_id uuid, p_code text, p_name text,
                                 p_starts timestamptz, p_ends timestamptz)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid := gen_random_uuid();
  v_customer uuid := core.venue_customer(p_venue_id);
  v jsonb;
begin
  v := authz.require('event.create',
         jsonb_build_object('customer_id', v_customer, 'venue_id', p_venue_id, 'record_id', v_id, 'target_type', 'event'),
         p_idempotency_key, jsonb_build_object('venue_id', p_venue_id, 'code', p_code, 'name', p_name,
                                               'starts', p_starts, 'ends', p_ends));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.event (id, customer_id, venue_id, code, name, valid_during)
  values (v_id, v_customer, p_venue_id, p_code, p_name, tstzrange(p_starts, p_ends));
  return v;
end $$;

create function api.add_event_phase(p_idempotency_key text, p_event_id uuid, p_phase text,
                                    p_starts timestamptz, p_ends timestamptz)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid := gen_random_uuid();
  e core.event;
  v jsonb;
begin
  select * into e from core.event where id = p_event_id;
  v := authz.require('event_phase.create',
         jsonb_build_object('customer_id', e.customer_id, 'venue_id', e.venue_id, 'record_id', v_id, 'target_type', 'event_phase'),
         p_idempotency_key, jsonb_build_object('event_id', p_event_id, 'phase', p_phase, 'starts', p_starts, 'ends', p_ends));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.event_phase (id, customer_id, venue_id, event_id, phase, valid_during)
  values (v_id, e.customer_id, e.venue_id, p_event_id, p_phase, tstzrange(p_starts, p_ends));
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Media
-- ---------------------------------------------------------------------------

create function api.register_induction_media(p_idempotency_key text, p_venue_id uuid, p_media_id uuid, p_sha256_hex text,
                                             p_media_type text, p_size_bytes bigint, p_original_name text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_customer uuid := core.venue_customer(p_venue_id);
  v jsonb;
begin
  v := authz.require('induction_media.upload',
         jsonb_build_object('customer_id', v_customer, 'venue_id', p_venue_id, 'record_id', p_media_id,
                            'target_type', 'induction_media'),
         p_idempotency_key, jsonb_build_object('venue_id', p_venue_id, 'media_id', p_media_id, 'sha256', p_sha256_hex,
                                               'media_type', p_media_type, 'size_bytes', p_size_bytes,
                                               'original_name', p_original_name));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.induction_media (id, customer_id, venue_id, storage_path, sha256, media_type, size_bytes,
                                    original_name, uploaded_by_person_id, scan_status)
  values (p_media_id, v_customer, p_venue_id, v_customer || '/media/' || p_media_id, decode(p_sha256_hex, 'hex'),
          p_media_type, p_size_bytes, p_original_name, (v ->> 'actor_person_id')::uuid,
          case core.malware_scanning() when 'required' then 'pending' else 'not_scanned' end);
  return v || jsonb_build_object('storage_path', v_customer || '/media/' || p_media_id);
end $$;

-- ---------------------------------------------------------------------------
-- Courses and versions
-- ---------------------------------------------------------------------------

create function api.create_induction_course(p_idempotency_key text, p_venue_id uuid, p_code text, p_title text,
                                            p_audience text default null, p_event_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid := gen_random_uuid();
  v_customer uuid := core.venue_customer(p_venue_id);
  v jsonb;
begin
  v := authz.require('induction_course.create',
         jsonb_build_object('customer_id', v_customer, 'venue_id', p_venue_id, 'record_id', v_id, 'target_type', 'induction_course'),
         p_idempotency_key, jsonb_build_object('venue_id', p_venue_id, 'code', p_code, 'title', p_title,
                                               'audience', p_audience, 'event_id', p_event_id));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.induction_course (id, customer_id, venue_id, event_id, code, title, audience)
  values (v_id, v_customer, p_venue_id, p_event_id, p_code, p_title, p_audience);
  return v;
end $$;

-- A new draft starts from the latest version's content and settings, which the H&S
-- authority reviews again before it is published.
create function api.create_course_draft(p_idempotency_key text, p_course_id uuid, p_language text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid := gen_random_uuid();
  c core.induction_course;
  prev core.course_version;
  v jsonb;
begin
  select * into c from core.induction_course where id = p_course_id;
  v := authz.require('course_version.create_draft',
         jsonb_build_object('customer_id', c.customer_id, 'venue_id', c.venue_id, 'record_id', v_id, 'target_type', 'course_version'),
         p_idempotency_key, jsonb_build_object('course_id', p_course_id, 'language', p_language));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  if exists (select 1 from core.course_version where course_id = p_course_id and status in ('draft', 'in_review')) then
    raise exception 'this course already has a version being prepared' using errcode = 'PT409';
  end if;
  select * into prev from core.course_version where course_id = p_course_id order by version_no desc limit 1;
  insert into core.course_version (id, customer_id, venue_id, course_id, version_no, language, status, content,
                                   pass_mark_percent, all_critical_required, max_attempts, retry_delay_minutes,
                                   shuffle_options, validity_mode, validity_days, validity_until, signature_mode,
                                   authored_by_person_id)
  values (v_id, c.customer_id, c.venue_id, p_course_id, coalesce(prev.version_no, 0) + 1, p_language, 'draft',
          coalesce(prev.content, '{"modules": [], "questions": [], "declaration": []}'),
          prev.pass_mark_percent, prev.all_critical_required, prev.max_attempts, prev.retry_delay_minutes,
          prev.shuffle_options, prev.validity_mode, prev.validity_days, prev.validity_until, prev.signature_mode,
          (v ->> 'actor_person_id')::uuid);
  return v;
end $$;

create function api.save_course_draft(p_idempotency_key text, p_version_id uuid, p_expected_version integer,
                                      p_content jsonb, p_source_ref text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  cv core.course_version;
  t jsonb;
  r jsonb;
  problems text[];
  v jsonb;
begin
  select * into cv from core.course_version where id = p_version_id for update;
  t := jsonb_build_object('customer_id', cv.customer_id, 'venue_id', cv.venue_id, 'record_id', p_version_id,
                          'target_type', 'course_version');
  r := jsonb_build_object('version_id', p_version_id, 'expected_version', p_expected_version, 'content', p_content,
                          'source_ref', p_source_ref);
  v := core.authorised_or_refusal('course_version.save_draft', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  problems := core.validate_course_content(cv.customer_id, p_content, false);
  if cardinality(problems) > 0 then
    return core.refuse('course_version.save_draft', 'invalid_content', 'The content has problems.',
                       'Each problem listed', 'Whoever is editing the induction', jsonb_build_object('problems', to_jsonb(problems)));
  end if;
  v := authz.require('course_version.save_draft', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.check_version(cv.row_version, p_expected_version);
  if cv.status <> 'draft' then
    raise exception 'only a draft can be edited; start a new version instead' using errcode = 'PT409';
  end if;
  update core.course_version set content = p_content, source_ref = coalesce(p_source_ref, source_ref) where id = p_version_id;
  return v;
end $$;

create function api.set_course_settings(
  p_idempotency_key text, p_version_id uuid, p_expected_version integer, p_pass_mark_percent integer,
  p_all_critical_required boolean, p_max_attempts integer, p_retry_delay_minutes integer, p_shuffle_options boolean,
  p_validity_mode text, p_validity_days integer, p_validity_until timestamptz, p_signature_mode text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  cv core.course_version;
  v jsonb;
begin
  select * into cv from core.course_version where id = p_version_id for update;
  v := authz.require('course_version.set_settings',
         jsonb_build_object('customer_id', cv.customer_id, 'venue_id', cv.venue_id, 'record_id', p_version_id,
                            'target_type', 'course_version'),
         p_idempotency_key,
         jsonb_build_object('version_id', p_version_id, 'expected_version', p_expected_version,
                            'pass_mark_percent', p_pass_mark_percent, 'all_critical_required', p_all_critical_required,
                            'max_attempts', p_max_attempts, 'retry_delay_minutes', p_retry_delay_minutes,
                            'shuffle_options', p_shuffle_options, 'validity_mode', p_validity_mode,
                            'validity_days', p_validity_days, 'validity_until', p_validity_until,
                            'signature_mode', p_signature_mode));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.check_version(cv.row_version, p_expected_version);
  if cv.status <> 'draft' then
    raise exception 'only a draft can be edited; start a new version instead' using errcode = 'PT409';
  end if;
  update core.course_version
     set pass_mark_percent = p_pass_mark_percent, all_critical_required = p_all_critical_required,
         max_attempts = p_max_attempts, retry_delay_minutes = p_retry_delay_minutes, shuffle_options = p_shuffle_options,
         validity_mode = p_validity_mode, validity_days = p_validity_days, validity_until = p_validity_until,
         signature_mode = p_signature_mode
   where id = p_version_id;
  return v;
end $$;

create function api.add_open_point(p_idempotency_key text, p_version_id uuid, p_text text, p_owner_text text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid := gen_random_uuid();
  cv core.course_version;
  v jsonb;
begin
  select * into cv from core.course_version where id = p_version_id;
  v := authz.require('course_open_point.add',
         jsonb_build_object('customer_id', cv.customer_id, 'venue_id', cv.venue_id, 'record_id', v_id, 'target_type', 'course_open_point'),
         p_idempotency_key, jsonb_build_object('version_id', p_version_id, 'text', p_text, 'owner_text', p_owner_text));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  if cv.status <> 'draft' then
    raise exception 'open points are recorded against a draft' using errcode = 'PT409';
  end if;
  insert into core.course_open_point (id, customer_id, venue_id, course_version_id, text, owner_text)
  values (v_id, cv.customer_id, cv.venue_id, p_version_id, p_text, p_owner_text);
  return v;
end $$;

create function api.resolve_open_point(p_idempotency_key text, p_open_point_id uuid, p_expected_version integer,
                                       p_resolution text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  op core.course_open_point;
  v jsonb;
begin
  select * into op from core.course_open_point where id = p_open_point_id for update;
  v := authz.require('course_open_point.resolve',
         jsonb_build_object('customer_id', op.customer_id, 'venue_id', op.venue_id, 'record_id', p_open_point_id,
                            'target_type', 'course_open_point'),
         p_idempotency_key, jsonb_build_object('open_point_id', p_open_point_id, 'expected_version', p_expected_version,
                                               'resolution', p_resolution));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.check_version(op.row_version, p_expected_version);
  if length(btrim(coalesce(p_resolution, ''))) = 0 then
    raise exception 'say how the open point was resolved' using errcode = '22023';
  end if;
  update core.course_open_point set resolved_at = now(), resolution = p_resolution,
                                    resolved_by_person_id = (v ->> 'actor_person_id')::uuid
   where id = p_open_point_id;
  return v;
end $$;

-- What stops a version going forward, in plain words (shared by submit and publish).
create function core.publication_blockers(p_version_id uuid) returns text[]
language plpgsql stable security definer set search_path = '' as $$
declare
  cv core.course_version;
  b text[];
  missing text[];
begin
  select * into cv from core.course_version where id = p_version_id;
  b := core.validate_course_content(cv.customer_id, cv.content, true);
  missing := core.settings_missing(cv);
  if cardinality(missing) > 0 then
    b := b || ('Settings not yet set: ' || array_to_string(missing, ', ') || '.');
  end if;
  if cv.validity_mode = 'fixed_date' and cv.validity_until <= now() then
    b := b || text 'The fixed validity date has already passed.';
  end if;
  if exists (select 1 from core.course_open_point where course_version_id = p_version_id and resolved_at is null) then
    b := b || text 'There are unresolved open points.';
  end if;
  return b;
end $$;

create function api.submit_course_version(p_idempotency_key text, p_version_id uuid, p_expected_version integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  cv core.course_version;
  t jsonb;
  r jsonb;
  blockers text[];
  v jsonb;
begin
  select * into cv from core.course_version where id = p_version_id;
  t := jsonb_build_object('customer_id', cv.customer_id, 'venue_id', cv.venue_id, 'record_id', p_version_id,
                          'target_type', 'course_version');
  r := jsonb_build_object('version_id', p_version_id, 'expected_version', p_expected_version);
  v := core.authorised_or_refusal('course_version.submit', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  blockers := core.publication_blockers(p_version_id);
  if cardinality(blockers) > 0 then
    return core.refuse('course_version.submit', 'not_ready', 'This version is not ready for review.',
                       'Each item listed', 'Whoever is editing the induction', jsonb_build_object('problems', to_jsonb(blockers)));
  end if;
  v := authz.require('course_version.submit', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.course_version', p_version_id, 'in_review', p_expected_version,
                          (v ->> 'decision_context_id')::uuid,
                          jsonb_build_object('submitted_by_person_id', v ->> 'actor_person_id', 'return_reason', null));
  return v;
end $$;

-- Q44: the venue's H&S authority publishes; the author and submitter cannot.
create function api.decide_course_version(p_idempotency_key text, p_version_id uuid, p_expected_version integer,
                                          p_decision text, p_reason text default null,
                                          p_acting_appointment_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  cv core.course_version;
  prev uuid;
  ctx uuid;
  blockers text[];
  v jsonb;
begin
  if p_decision not in ('publish', 'return') then
    raise exception 'decision must be publish or return' using errcode = '22023';
  end if;
  select * into cv from core.course_version where id = p_version_id;
  v := authz.require('course_version.' || p_decision,
         jsonb_build_object('customer_id', cv.customer_id, 'venue_id', cv.venue_id, 'record_id', p_version_id,
                            'target_type', 'course_version',
                            'excluded_person_ids', jsonb_build_array(cv.authored_by_person_id, cv.submitted_by_person_id)),
         p_idempotency_key,
         jsonb_build_object('version_id', p_version_id, 'expected_version', p_expected_version,
                            'decision', p_decision, 'reason', p_reason),
         p_acting_appointment_id, null);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ctx := (v ->> 'decision_context_id')::uuid;

  if p_decision = 'return' then
    if length(btrim(coalesce(p_reason, ''))) = 0 then
      raise exception 'say why the version is being returned' using errcode = '22023';
    end if;
    perform core.transition('core.course_version', p_version_id, 'draft', p_expected_version, ctx,
                            jsonb_build_object('return_reason', p_reason));
    return v;
  end if;

  blockers := core.publication_blockers(p_version_id);
  if cardinality(blockers) > 0 then
    raise exception 'this version cannot be published: %', array_to_string(blockers, ' ') using errcode = '22023';
  end if;
  select id into prev from core.course_version where course_id = cv.course_id and status = 'published';
  perform core.transition('core.course_version', p_version_id, 'published', p_expected_version, ctx,
    jsonb_build_object('published_by_person_id', v ->> 'actor_person_id', 'published_at', now(),
      'content_sha256', encode(sha256(convert_to(jsonb_build_object(
        'content', cv.content, 'language', cv.language, 'pass_mark_percent', cv.pass_mark_percent,
        'all_critical_required', cv.all_critical_required, 'max_attempts', cv.max_attempts,
        'retry_delay_minutes', cv.retry_delay_minutes, 'shuffle_options', cv.shuffle_options,
        'validity_mode', cv.validity_mode, 'validity_days', cv.validity_days, 'validity_until', cv.validity_until,
        'signature_mode', cv.signature_mode)::text, 'UTF8')), 'hex')));
  if prev is not null then
    perform authz.derive('course_version.supersede', 'course_version', prev);
    perform core.transition('core.course_version', prev,
                            'superseded', (select row_version from core.course_version where id = prev),
                            core.ctx_uuid('decision_context_id'));
    perform authz.resume(ctx);
  end if;
  return v;
end $$;

create function api.withdraw_course_version(p_idempotency_key text, p_version_id uuid, p_expected_version integer,
                                            p_reason text, p_acting_appointment_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  cv core.course_version;
  v jsonb;
begin
  select * into cv from core.course_version where id = p_version_id;
  v := authz.require('course_version.withdraw',
         jsonb_build_object('customer_id', cv.customer_id, 'venue_id', cv.venue_id, 'record_id', p_version_id,
                            'target_type', 'course_version'),
         p_idempotency_key, jsonb_build_object('version_id', p_version_id, 'expected_version', p_expected_version,
                                               'reason', p_reason),
         p_acting_appointment_id, null);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  if length(btrim(coalesce(p_reason, ''))) = 0 then
    raise exception 'say why the version is being withdrawn' using errcode = '22023';
  end if;
  perform core.transition('core.course_version', p_version_id, 'withdrawn', p_expected_version,
                          (v ->> 'decision_context_id')::uuid, jsonb_build_object('return_reason', p_reason));
  return v;
end $$;

-- Full content (with correct answers) for those who author or review it.
create function api.course_content(p_version_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare cv core.course_version;
begin
  select * into cv from core.course_version where id = p_version_id;
  if cv.id is null or not (cv.customer_id in (select authz.my_admin_customer_ids())
                           or cv.venue_id in (select authz.my_action_venue_ids('course_version.publish'))) then
    return core.refuse('course_version.save_draft', 'not_found', 'The record does not exist or you do not have access to it.',
                       'Access to this induction', 'A tenant administrator for this customer');
  end if;
  return jsonb_build_object('ok', true, 'version_id', cv.id, 'status', cv.status, 'content', cv.content,
                            'problems', to_jsonb(core.publication_blockers(cv.id)));
end $$;

-- ---------------------------------------------------------------------------
-- Personal induction links (P3-2)
-- ---------------------------------------------------------------------------

create function api.issue_induction_link(p_idempotency_key text, p_course_id uuid, p_person_id uuid,
                                         p_expires_at timestamptz, p_via_organisation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid := gen_random_uuid();
  v_token text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  c core.induction_course;
  v_email text;
  v jsonb;
begin
  select * into c from core.induction_course where id = p_course_id;
  v := authz.require(case when p_via_organisation_id is null then 'induction_link.issue' else 'induction_link.issue_for_person' end,
         jsonb_build_object('customer_id', c.customer_id, 'venue_id', c.venue_id, 'record_id', v_id, 'target_type', 'induction_link')
         || case when p_via_organisation_id is null then '{}'::jsonb
                 else jsonb_build_object('organisation_id', p_via_organisation_id, 'person_id', p_person_id) end,
         p_idempotency_key, jsonb_build_object('course_id', p_course_id, 'person_id', p_person_id,
                                               'expires_at', p_expires_at, 'via_organisation_id', p_via_organisation_id));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  select lower(btrim(email)) into v_email from core.person_contact where person_id = p_person_id;
  if v_email is null then
    raise exception 'this person has no email address; record one, or use a facilitated induction' using errcode = '22023';
  end if;
  insert into core.induction_link (id, customer_id, venue_id, course_id, person_id, email, token_hash, expires_at,
                                   issued_by_person_id, via_organisation_id, status)
  values (v_id, c.customer_id, c.venue_id, p_course_id, p_person_id, v_email, core.token_hash(v_token), p_expires_at,
          (v ->> 'actor_person_id')::uuid, p_via_organisation_id, 'issued');
  return v || jsonb_build_object('token', v_token, 'email', v_email);
end $$;

create function api.revoke_induction_link(p_idempotency_key text, p_link_id uuid, p_expected_version integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  l core.induction_link;
  v jsonb;
begin
  select * into l from core.induction_link where id = p_link_id;
  v := authz.require('induction_link.revoke',
         jsonb_build_object('customer_id', l.customer_id, 'venue_id', l.venue_id, 'record_id', p_link_id,
                            'target_type', 'induction_link'),
         p_idempotency_key, jsonb_build_object('link_id', p_link_id, 'expected_version', p_expected_version));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.induction_link', p_link_id, 'revoked', p_expected_version,
                          (v ->> 'decision_context_id')::uuid, jsonb_build_object('revoked_at', now()));
  return v;
end $$;

-- Opening the link (after signing in by email code with the address it was sent to)
-- links the login to the person the link was issued to, if it is not linked yet.
create function api.claim_induction_link(p_idempotency_key text, p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  l core.induction_link;
  v jsonb;
begin
  select * into l from core.induction_link where token_hash = core.token_hash(p_token);
  v := authz.require('induction_link.claim',
         jsonb_build_object('customer_id', l.customer_id, 'venue_id', l.venue_id,
                            'record_id', coalesce(l.id, gen_random_uuid()), 'target_type', 'induction_link',
                            'token_hash', encode(core.token_hash(p_token), 'hex')),
         p_idempotency_key, jsonb_build_object('token_hash', encode(core.token_hash(p_token), 'hex')));
  if not (v ->> 'ok')::boolean then return v; end if;
  if not (v ->> 'replayed')::boolean then
    if not exists (select 1 from core.user_account where person_id = l.person_id and disabled_at is null) then
      insert into core.user_account (customer_id, person_id, auth_user_id) values (l.customer_id, l.person_id, auth.uid());
    elsif not exists (select 1 from core.user_account where person_id = l.person_id and auth_user_id = auth.uid()
                                                       and disabled_at is null) then
      raise exception 'this person already uses a different login; sign in with that one' using errcode = 'PT409';
    end if;
    update core.induction_link set claimed_at = coalesce(claimed_at, now()) where id = l.id;
  end if;
  return v || jsonb_build_object('course_id', l.course_id, 'person_id', l.person_id);
end $$;

-- ---------------------------------------------------------------------------
-- The learner journey (Induct's, on Access's model)
-- ---------------------------------------------------------------------------

-- What the learner sees: the current published version without the answers, and
-- where they are up to.
create function api.learner_course(p_course_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  c core.induction_course;
  cv core.course_version;
  me uuid;
  a core.induction_attempt;
begin
  select * into c from core.induction_course where id = p_course_id;
  me := authz.actor_person(c.customer_id);
  if c.id is null or me is null or not core.has_valid_link(me, p_course_id) then
    return core.refuse('induction.start', 'not_found', 'The record does not exist or you do not have access to it.',
                       'A current induction link for this course', 'Whoever sent you the link');
  end if;
  select * into cv from core.course_version where id = core.current_version(p_course_id);
  if cv.id is null then
    return core.refuse('induction.start', 'not_published', 'This induction is not available yet.',
                       'A published version', 'The venue');
  end if;
  select * into a from core.induction_attempt where person_id = me and course_version_id = cv.id
   order by started_at desc limit 1;
  return jsonb_build_object(
    'ok', true, 'course_id', c.id, 'title', c.title, 'version_id', cv.id, 'version_no', cv.version_no,
    'language', cv.language, 'shuffle_options', cv.shuffle_options, 'signature_mode', cv.signature_mode,
    'content', core.learner_content(cv.content),
    'attempt', case when a.id is null then null else jsonb_build_object(
      'id', a.id, 'status', a.status, 'row_version', a.row_version,
      'modules_completed', (select coalesce(jsonb_agg(module_key), '[]') from core.module_progress
                             where attempt_id = a.id and completed_at is not null),
      'answered', (select coalesce(jsonb_agg(question_key), '[]') from core.question_response where attempt_id = a.id))
    end);
end $$;

create function api.start_induction(p_idempotency_key text, p_course_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c core.induction_course;
  cv core.course_version;
  me uuid;
  v_id uuid := gen_random_uuid();
  open_id uuid;
  failed integer;
  last_failed timestamptz;
  t jsonb;
  v jsonb;
begin
  select * into c from core.induction_course where id = p_course_id;
  me := authz.actor_person(c.customer_id);
  t := jsonb_build_object('customer_id', c.customer_id, 'venue_id', c.venue_id, 'record_id', v_id,
                          'target_type', 'induction_attempt', 'subject_person_id', me);
  v := core.authorised_or_refusal('induction.start', t, p_idempotency_key, jsonb_build_object('course_id', p_course_id));
  if v is not null then return v; end if;
  if not core.has_valid_link(me, p_course_id) then
    return core.refuse('induction.start', 'no_link', 'You need a current induction link for this course.',
                       'A current induction link', 'The venue, or your organisation''s administrator');
  end if;
  select * into cv from core.course_version where id = core.current_version(p_course_id);
  if cv.id is null then
    return core.refuse('induction.start', 'not_published', 'This induction is not available yet.', 'A published version', 'The venue');
  end if;
  select id into open_id from core.induction_attempt where person_id = me and course_version_id = cv.id and status = 'in_progress';
  if open_id is not null then
    return jsonb_build_object('ok', true, 'id', open_id, 'resumed', true);
  end if;
  select count(*), max(finished_at) into failed, last_failed from core.induction_attempt
   where person_id = me and course_version_id = cv.id and status = 'failed';
  if failed >= cv.max_attempts then
    return core.refuse('induction.start', 'assisted_review_required',
      format('You have used all %s attempts. An induction facilitator will go through it with you.', cv.max_attempts),
      'An assisted induction', 'An induction facilitator at the venue');
  end if;
  if last_failed is not null and clock_timestamp() < last_failed + make_interval(mins => cv.retry_delay_minutes) then
    return core.refuse('induction.start', 'retry_not_yet',
      format('You can try again from %s.', to_char((last_failed + make_interval(mins => cv.retry_delay_minutes)) at time zone (select timezone from core.venue where id = c.venue_id), 'HH24:MI DD/MM/YYYY')),
      'Time to pass before the next attempt', 'Nobody: please try again later');
  end if;
  v := authz.require('induction.start', t, p_idempotency_key, jsonb_build_object('course_id', p_course_id));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.induction_attempt (id, customer_id, venue_id, course_version_id, person_id, language, status)
  values (v_id, cv.customer_id, cv.venue_id, cv.id, me, cv.language, 'in_progress');
  return v || jsonb_build_object('version_id', cv.id);
end $$;

-- Modules are taken in order; the minimum time is measured on the server.
create function core.attempt_target(p_attempt_id uuid, p_record_id uuid, p_type text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('customer_id', a.customer_id, 'venue_id', a.venue_id, 'record_id', p_record_id,
                            'target_type', p_type, 'subject_person_id', a.person_id)
    from core.induction_attempt a where a.id = p_attempt_id $$;

create function api.module_progress(p_idempotency_key text, p_attempt_id uuid, p_module_key text, p_event text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  a core.induction_attempt;
  v_content jsonb;
  m jsonb;
  pos integer;
  mp core.module_progress;
  t jsonb;
  r jsonb := jsonb_build_object('attempt_id', p_attempt_id, 'module_key', p_module_key, 'event', p_event);
  v jsonb;
begin
  if p_event not in ('start', 'complete') then
    raise exception 'event must be start or complete' using errcode = '22023';
  end if;
  select * into a from core.induction_attempt where id = p_attempt_id;
  t := core.attempt_target(p_attempt_id, coalesce(a.id, gen_random_uuid()), 'module_progress');
  v := core.authorised_or_refusal('induction.progress', coalesce(t, '{}'::jsonb), p_idempotency_key, r);
  if v is not null then return v; end if;
  if a.status <> 'in_progress' then
    return core.refuse('induction.progress', 'attempt_closed', 'This attempt has finished.', 'An open attempt', 'You');
  end if;
  select cv.content into v_content from core.course_version cv where cv.id = a.course_version_id;
  select x.m, x.ord into m, pos from jsonb_array_elements(v_content -> 'modules') with ordinality as x(m, ord)
   where x.m ->> 'key' = p_module_key;
  if m is null then
    return core.refuse('induction.progress', 'no_such_module', 'That module is not part of this induction.', 'A valid module', 'You');
  end if;
  if exists (select 1 from jsonb_array_elements(v_content -> 'modules') with ordinality as x(mm, ord)
              where x.ord < pos and not exists (select 1 from core.module_progress p where p.attempt_id = p_attempt_id
                                                   and p.module_key = x.mm ->> 'key' and p.completed_at is not null)) then
    return core.refuse('induction.progress', 'out_of_order', 'Please finish the earlier modules first.', 'The earlier modules', 'You');
  end if;
  select * into mp from core.module_progress where attempt_id = p_attempt_id and module_key = p_module_key;
  if p_event = 'start' and mp.id is not null then
    return jsonb_build_object('ok', true, 'id', mp.id, 'resumed', true);
  end if;
  if p_event = 'complete' then
    if mp.id is null then
      return core.refuse('induction.progress', 'not_started', 'This module has not been started.', 'Starting the module', 'You');
    end if;
    if mp.completed_at is not null then
      return jsonb_build_object('ok', true, 'id', mp.id, 'resumed', true);
    end if;
    if clock_timestamp() < mp.started_at + make_interval(secs => (m ->> 'min_seconds')::integer) then
      return core.refuse('induction.progress', 'too_soon',
        'Please take the time to read this module before moving on.', 'More time on this module', 'You');
    end if;
  end if;
  v := authz.require('induction.progress', t || jsonb_build_object('record_id', coalesce(mp.id, gen_random_uuid())),
                     p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  if p_event = 'start' then
    insert into core.module_progress (customer_id, attempt_id, module_key) values (a.customer_id, p_attempt_id, p_module_key)
    returning id into mp.id;
  else
    update core.module_progress set completed_at = clock_timestamp() where id = mp.id;
  end if;
  return v || jsonb_build_object('id', mp.id);
end $$;

create function api.answer_question(p_idempotency_key text, p_attempt_id uuid, p_question_key text, p_option_keys text[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  a core.induction_attempt;
  v_content jsonb;
  q jsonb;
  correct_keys text[];
  t jsonb;
  r jsonb := jsonb_build_object('attempt_id', p_attempt_id, 'question_key', p_question_key, 'option_keys', to_jsonb(p_option_keys));
  v jsonb;
  v_id uuid := gen_random_uuid();
begin
  select * into a from core.induction_attempt where id = p_attempt_id;
  t := core.attempt_target(p_attempt_id, v_id, 'question_response');
  v := core.authorised_or_refusal('induction.answer', coalesce(t, '{}'::jsonb), p_idempotency_key, r);
  if v is not null then return v; end if;
  if a.status <> 'in_progress' then
    return core.refuse('induction.answer', 'attempt_closed', 'This attempt has finished.', 'An open attempt', 'You');
  end if;
  select cv.content into v_content from core.course_version cv where cv.id = a.course_version_id;
  select x into q from jsonb_array_elements(v_content -> 'questions') x where x ->> 'key' = p_question_key;
  if q is null then
    return core.refuse('induction.answer', 'no_such_question', 'That question is not part of this induction.', 'A valid question', 'You');
  end if;
  if (q ->> 'placement') = 'module' and not exists (select 1 from core.module_progress p where p.attempt_id = p_attempt_id
                                                       and p.module_key = q ->> 'module_key' and p.completed_at is not null)
     or (q ->> 'placement') = 'final' and exists (select 1 from jsonb_array_elements(v_content -> 'modules') mm
                                                   where not exists (select 1 from core.module_progress p where p.attempt_id = p_attempt_id
                                                                       and p.module_key = mm ->> 'key' and p.completed_at is not null)) then
    return core.refuse('induction.answer', 'not_yet', 'Please read the module this question is about first.', 'The related module', 'You');
  end if;
  if exists (select 1 from core.question_response where attempt_id = p_attempt_id and question_key = p_question_key) then
    return core.refuse('induction.answer', 'already_answered', 'You have already answered this question.', 'Nothing', 'You');
  end if;
  if cardinality(coalesce(p_option_keys, '{}')) = 0
     or exists (select 1 from unnest(p_option_keys) k where not exists (select 1 from jsonb_array_elements(q -> 'options') o where o ->> 'key' = k))
     or ((q ->> 'type') in ('single_choice', 'true_false') and cardinality(p_option_keys) <> 1) then
    return core.refuse('induction.answer', 'invalid_answer', 'Choose an answer from the options given.', 'A valid answer', 'You');
  end if;
  select array_agg(o ->> 'key' order by o ->> 'key') into correct_keys
    from jsonb_array_elements(q -> 'options') o where (o ->> 'correct')::boolean;
  v := authz.require('induction.answer', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.question_response (id, customer_id, attempt_id, question_key, option_keys, correct)
  values (v_id, a.customer_id, p_attempt_id, p_question_key, p_option_keys,
          (select array_agg(k order by k) from unnest(p_option_keys) k) = correct_keys);
  return v;
end $$;

-- Scores the attempt. A missed safety-critical question fails it when the version
-- requires every safety-critical question to be correct (Q44). Wrong answers are
-- explained and point back to their module; correct options are not revealed.
create function api.finish_attempt(p_idempotency_key text, p_attempt_id uuid, p_expected_version integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  a core.induction_attempt;
  cv core.course_version;
  total numeric;
  got numeric;
  score integer;
  crit integer;
  passed boolean;
  wrong jsonb;
  failed_before integer;
  t jsonb;
  r jsonb := jsonb_build_object('attempt_id', p_attempt_id, 'expected_version', p_expected_version);
  v jsonb;
begin
  select * into a from core.induction_attempt where id = p_attempt_id;
  t := core.attempt_target(p_attempt_id, coalesce(a.id, gen_random_uuid()), 'induction_attempt');
  v := core.authorised_or_refusal('induction.finish', coalesce(t, '{}'::jsonb), p_idempotency_key, r);
  if v is not null then return v; end if;
  select * into cv from core.course_version where id = a.course_version_id;
  if exists (select 1 from jsonb_array_elements(cv.content -> 'modules') mm
              where not exists (select 1 from core.module_progress p where p.attempt_id = p_attempt_id
                                  and p.module_key = mm ->> 'key' and p.completed_at is not null))
     or exists (select 1 from jsonb_array_elements(cv.content -> 'questions') q
                 where not exists (select 1 from core.question_response x where x.attempt_id = p_attempt_id
                                     and x.question_key = q ->> 'key')) then
    return core.refuse('induction.finish', 'incomplete', 'Please finish every module and answer every question first.',
                       'The remaining modules or questions', 'You');
  end if;
  select coalesce(sum(coalesce((q ->> 'weight')::numeric, 1)), 0),
         coalesce(sum(coalesce((q ->> 'weight')::numeric, 1)) filter (where x.correct), 0),
         count(*) filter (where (q ->> 'safety_critical')::boolean and not x.correct)
    into total, got, crit
    from jsonb_array_elements(cv.content -> 'questions') q
    join core.question_response x on x.attempt_id = p_attempt_id and x.question_key = q ->> 'key';
  score := case when total = 0 then 100 else floor(got * 100 / total) end;
  passed := score >= cv.pass_mark_percent and not (cv.all_critical_required and crit > 0);
  select coalesce(jsonb_agg(jsonb_build_object('question_key', q ->> 'key', 'stem', q ->> 'stem',
                                               'explanation', q ->> 'explanation', 'module_key', q ->> 'module_key',
                                               'safety_critical', (q ->> 'safety_critical')::boolean)), '[]')
    into wrong
    from jsonb_array_elements(cv.content -> 'questions') q
    join core.question_response x on x.attempt_id = p_attempt_id and x.question_key = q ->> 'key' and not x.correct;

  v := authz.require('induction.finish', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.induction_attempt', p_attempt_id, case when passed then 'passed' else 'failed' end,
                          p_expected_version, (v ->> 'decision_context_id')::uuid,
                          jsonb_build_object('finished_at', clock_timestamp(), 'score_percent', score, 'critical_missed', crit));
  select count(*) into failed_before from core.induction_attempt
   where person_id = a.person_id and course_version_id = cv.id and status = 'failed';
  return v || jsonb_build_object('passed', passed, 'score_percent', score, 'pass_mark_percent', cv.pass_mark_percent,
                                 'critical_missed', crit, 'wrong', wrong,
                                 'attempts_left', greatest(cv.max_attempts - failed_before, 0),
                                 'retry_delay_minutes', cv.retry_delay_minutes);
end $$;

create function core.completion_valid_until(cv core.course_version, p_at timestamptz) returns timestamptz
language sql immutable set search_path = '' as $$
  select case cv.validity_mode when 'days_from_completion' then p_at + make_interval(days => cv.validity_days)
                               else cv.validity_until end $$;

-- The learner makes the declaration and the immutable completion is recorded.
create function api.complete_induction(p_idempotency_key text, p_attempt_id uuid, p_expected_version integer,
                                       p_confirmed_keys text[], p_typed_name text, p_drawn_signature boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  a core.induction_attempt;
  cv core.course_version;
  v_id uuid := gen_random_uuid();
  at timestamptz := clock_timestamp();
  t jsonb;
  r jsonb := jsonb_build_object('attempt_id', p_attempt_id, 'expected_version', p_expected_version,
                                'confirmed_keys', to_jsonb(p_confirmed_keys), 'typed_name', p_typed_name,
                                'drawn_signature', p_drawn_signature);
  v jsonb;
begin
  select * into a from core.induction_attempt where id = p_attempt_id;
  t := core.attempt_target(p_attempt_id, coalesce(a.id, gen_random_uuid()), 'induction_attempt');
  v := core.authorised_or_refusal('induction.complete', coalesce(t, '{}'::jsonb), p_idempotency_key, r);
  if v is not null then return v; end if;
  select * into cv from core.course_version where id = a.course_version_id;
  if a.status <> 'passed' then
    return core.refuse('induction.complete', 'not_passed', 'The declaration follows a passed attempt.', 'A passed attempt', 'You');
  end if;
  if exists (select 1 from jsonb_array_elements(cv.content -> 'declaration') d where not ((d ->> 'key') = any (coalesce(p_confirmed_keys, '{}')))) then
    return core.refuse('induction.complete', 'declaration_incomplete', 'Please confirm every statement in the declaration.',
                       'Each confirmation', 'You');
  end if;
  if length(btrim(coalesce(p_typed_name, ''))) = 0 then
    return core.refuse('induction.complete', 'name_required', 'Please type your full name to sign the declaration.',
                       'Your typed name', 'You');
  end if;
  if p_drawn_signature and cv.signature_mode <> 'typed_or_drawn' then
    return core.refuse('induction.complete', 'signature_mode', 'This induction is signed with your typed name.',
                       'A typed name', 'You');
  end if;
  if core.completion_valid_until(cv, at) <= at then
    return core.refuse('induction.complete', 'validity_passed', 'This induction''s validity date has passed.',
                       'A current version', 'The venue');
  end if;
  v := authz.require('induction.complete', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.induction_attempt', p_attempt_id, 'completed', p_expected_version,
                          (v ->> 'decision_context_id')::uuid);
  insert into core.induction_completion (id, customer_id, venue_id, course_version_id, person_id, language, method,
                                         attempt_id, declaration_sha256, signature_kind, typed_name, completed_at,
                                         valid_until, evidence_sha256, decision_context_id)
  values (v_id, a.customer_id, a.venue_id, cv.id, a.person_id, a.language, 'self', p_attempt_id,
          sha256(convert_to((cv.content -> 'declaration')::text, 'UTF8')),
          case when p_drawn_signature then 'drawn' else 'typed' end, p_typed_name, at,
          core.completion_valid_until(cv, at),
          sha256(convert_to(jsonb_build_object(
            'version_sha256', encode(cv.content_sha256, 'hex'), 'attempt', p_attempt_id, 'score', a.score_percent,
            'responses', (select jsonb_agg(jsonb_build_object('q', question_key, 'a', option_keys, 'c', correct) order by question_key)
                            from core.question_response where attempt_id = p_attempt_id),
            'declaration', cv.content -> 'declaration', 'name', p_typed_name, 'at', at)::text, 'UTF8')),
          (v ->> 'decision_context_id')::uuid);
  return v || jsonb_build_object('completion_id', v_id, 'valid_until', core.completion_valid_until(cv, at));
end $$;

-- Q47: a venue-appointed facilitator records an assisted or facilitated completion.
create function api.record_facilitated_completion(
  p_idempotency_key text, p_version_id uuid, p_person_id uuid, p_method text, p_identity_check text,
  p_understanding_check text, p_learner_acknowledged boolean, p_acting_appointment_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  cv core.course_version;
  v_id uuid := gen_random_uuid();
  at timestamptz := clock_timestamp();
  v jsonb;
begin
  select * into cv from core.course_version where id = p_version_id;
  v := authz.require('induction.facilitate',
         jsonb_build_object('customer_id', cv.customer_id, 'venue_id', cv.venue_id, 'record_id', v_id,
                            'target_type', 'induction_completion',
                            'excluded_person_ids', jsonb_build_array(p_person_id)),
         p_idempotency_key,
         jsonb_build_object('version_id', p_version_id, 'person_id', p_person_id, 'method', p_method,
                            'identity_check', p_identity_check, 'understanding_check', p_understanding_check,
                            'learner_acknowledged', p_learner_acknowledged),
         p_acting_appointment_id, null);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  if cv.id is distinct from core.current_version(cv.course_id) then
    raise exception 'facilitated completions use the current published version' using errcode = 'PT409';
  end if;
  if p_method not in ('assisted', 'facilitated') then
    raise exception 'method must be assisted or facilitated' using errcode = '22023';
  end if;
  if not coalesce(p_learner_acknowledged, false) then
    raise exception 'the person must acknowledge the briefing and declaration' using errcode = '22023';
  end if;
  if length(btrim(coalesce(p_identity_check, ''))) < 5 or length(btrim(coalesce(p_understanding_check, ''))) < 5 then
    raise exception 'record how identity and understanding were checked' using errcode = '22023';
  end if;
  insert into core.induction_completion (id, customer_id, venue_id, course_version_id, person_id, language, method,
                                         facilitator_person_id, identity_check, understanding_check,
                                         declaration_sha256, signature_kind, completed_at, valid_until,
                                         evidence_sha256, decision_context_id)
  values (v_id, cv.customer_id, cv.venue_id, cv.id, p_person_id, cv.language, p_method,
          (v ->> 'actor_person_id')::uuid, p_identity_check, p_understanding_check,
          sha256(convert_to((cv.content -> 'declaration')::text, 'UTF8')), 'acknowledged_to_facilitator', at,
          core.completion_valid_until(cv, at),
          sha256(convert_to(jsonb_build_object('version_sha256', encode(cv.content_sha256, 'hex'), 'person', p_person_id,
                                               'method', p_method, 'identity', p_identity_check,
                                               'understanding', p_understanding_check, 'at', at)::text, 'UTF8')),
          (v ->> 'decision_context_id')::uuid);
  return v || jsonb_build_object('valid_until', core.completion_valid_until(cv, at));
end $$;

create function api.invalidate_completion(p_idempotency_key text, p_completion_id uuid, p_reason_kind text,
                                          p_reason text, p_acting_appointment_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c core.induction_completion;
  v_id uuid := gen_random_uuid();
  v jsonb;
begin
  select * into c from core.induction_completion where id = p_completion_id;
  v := authz.require('induction.invalidate',
         jsonb_build_object('customer_id', c.customer_id, 'venue_id', c.venue_id, 'record_id', v_id,
                            'target_type', 'completion_invalidation',
                            'excluded_person_ids', jsonb_build_array(c.person_id)),
         p_idempotency_key, jsonb_build_object('completion_id', p_completion_id, 'reason_kind', p_reason_kind,
                                               'reason', p_reason),
         p_acting_appointment_id, null);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.completion_invalidation (id, customer_id, venue_id, completion_id, reason_kind, reason, decision_context_id)
  values (v_id, c.customer_id, c.venue_id, p_completion_id, p_reason_kind, p_reason, (v ->> 'decision_context_id')::uuid);
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------
create view api.event                   with (security_invoker = true) as select * from core.event;
create view api.event_phase             with (security_invoker = true) as select * from core.event_phase;
create view api.induction_course        with (security_invoker = true) as select * from core.induction_course;
create view api.course_version          with (security_invoker = true) as
  select id, customer_id, venue_id, course_id, version_no, language, status, source_ref, pass_mark_percent,
         all_critical_required, max_attempts, retry_delay_minutes, shuffle_options, validity_mode, validity_days,
         validity_until, signature_mode, authored_by_person_id, submitted_by_person_id, published_by_person_id,
         published_at, return_reason, encode(content_sha256, 'hex') as content_sha256, row_version, created_at
    from core.course_version;
create view api.course_open_point       with (security_invoker = true) as select * from core.course_open_point;
create view api.induction_media         with (security_invoker = true) as
  select id, customer_id, venue_id, media_type, size_bytes, original_name, scan_status, created_at from core.induction_media;
create view api.induction_link          with (security_invoker = true) as
  select id, customer_id, venue_id, course_id, person_id, email, expires_at, status, claimed_at, row_version, created_at
    from core.induction_link;
create view api.induction_attempt       with (security_invoker = true) as select * from core.induction_attempt;
create view api.induction_completion    with (security_invoker = true) as
  select c.id, c.customer_id, c.venue_id, c.course_version_id, c.person_id, c.language, c.method,
         c.facilitator_person_id, c.signature_kind, c.completed_at, c.valid_until,
         (select i.reason_kind from core.completion_invalidation i where i.completion_id = c.id) as invalidated_for
    from core.induction_completion c;
create view api.completion_invalidation with (security_invoker = true) as select * from core.completion_invalidation;

grant select on all tables in schema api to authenticated;
grant execute on all functions in schema api to authenticated;
revoke execute on all functions in schema api from anon, public;
