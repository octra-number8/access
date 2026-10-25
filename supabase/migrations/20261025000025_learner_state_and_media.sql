-- 0025 Learner state and induction media delivery (phase 3b)
--
-- api.learner_course now returns where the learner is up to (module timings, answers,
-- the last result with explanations, attempts left, when they may retry, and any
-- completion), so the journey resumes exactly where it stopped, as in OCTRA Induct.
-- api.induction_media_access releases a media file's storage path only when the file
-- is part of the course the learner holds a current link for, or the caller authors or
-- reviews inductions at the venue. The server then signs a short-lived URL.
--
-- core.validate_course_content is restated so its messages name sections by title and
-- read "The image in ..." rather than "A image in ..."; the checks are unchanged.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

create or replace function api.learner_course(p_course_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  c core.induction_course;
  cv core.course_version;
  me uuid;
  a core.induction_attempt;
  failed integer;
  last_failed timestamptz;
  comp core.induction_completion;
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
  select count(*), max(finished_at) into failed, last_failed from core.induction_attempt
   where person_id = me and course_version_id = cv.id and status = 'failed';
  select * into comp from core.induction_completion
   where person_id = me and course_version_id in (select id from core.course_version where course_id = p_course_id)
   order by completed_at desc limit 1;

  return jsonb_build_object(
    'ok', true, 'server_now', clock_timestamp(),
    'course_id', c.id, 'title', c.title, 'version_id', cv.id, 'version_no', cv.version_no, 'language', cv.language,
    'settings', jsonb_build_object('pass_mark_percent', cv.pass_mark_percent, 'all_critical_required', cv.all_critical_required,
                                   'max_attempts', cv.max_attempts, 'retry_delay_minutes', cv.retry_delay_minutes,
                                   'shuffle_options', cv.shuffle_options, 'signature_mode', cv.signature_mode),
    'learner', (select jsonb_build_object('given_name', p.given_name, 'family_name', p.family_name)
                  from core.person p where p.id = me),
    'content', core.learner_content(cv.content),
    'attempts_left', greatest(cv.max_attempts - failed, 0),
    'retry_from', case when last_failed is not null and a.status = 'failed'
                       then last_failed + make_interval(mins => cv.retry_delay_minutes) end,
    'attempt', case when a.id is null then null else jsonb_build_object(
      'id', a.id, 'status', a.status, 'row_version', a.row_version,
      'score_percent', a.score_percent, 'critical_missed', a.critical_missed,
      'modules', (select coalesce(jsonb_object_agg(module_key,
                    jsonb_build_object('started_at', started_at, 'completed_at', completed_at)), '{}')
                    from core.module_progress where attempt_id = a.id),
      'answered', (select coalesce(jsonb_agg(question_key), '[]') from core.question_response where attempt_id = a.id),
      'wrong', case when a.status in ('failed', 'passed') then (
        select coalesce(jsonb_agg(jsonb_build_object('question_key', q ->> 'key', 'stem', q ->> 'stem',
                                                     'explanation', q ->> 'explanation', 'module_key', q ->> 'module_key',
                                                     'safety_critical', (q ->> 'safety_critical')::boolean)), '[]')
          from jsonb_array_elements(cv.content -> 'questions') q
          join core.question_response x on x.attempt_id = a.id and x.question_key = q ->> 'key' and not x.correct) end)
    end,
    'completion', case when comp.id is null then null else jsonb_build_object(
      'id', comp.id, 'completed_at', comp.completed_at, 'valid_until', comp.valid_until, 'method', comp.method,
      'invalidated_for', (select reason_kind from core.completion_invalidation where completion_id = comp.id)) end);
end $$;

create function api.induction_media_access(p_media_id uuid, p_course_id uuid default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  m core.induction_media;
  me uuid;
  referenced boolean;
begin
  select * into m from core.induction_media where id = p_media_id;
  if m.id is not null and (m.customer_id in (select authz.my_admin_customer_ids())
                           or m.venue_id in (select authz.my_action_venue_ids('course_version.publish'))) then
    null;  -- authors and reviewers may see any media at their venue
  elsif m.id is not null and p_course_id is not null then
    me := authz.actor_person(m.customer_id);
    select exists (
      select 1 from core.course_version cv,
             jsonb_array_elements(cv.content -> 'modules') mm, jsonb_array_elements(mm -> 'blocks') b
       where cv.id = core.current_version(p_course_id)
         and (b ->> 'media_id' = p_media_id::text or b ->> 'caption_media_id' = p_media_id::text))
      into referenced;
    if me is null or not referenced or not core.has_valid_link(me, p_course_id) then
      m.id := null;
    end if;
  else
    m.id := null;
  end if;
  if m.id is null then
    return core.refuse('induction.start', 'not_found', 'The record does not exist or you do not have access to it.',
                       'Access to this file', 'Whoever sent you the link');
  end if;
  if m.scan_status not in ('clean', 'not_scanned') then
    return core.refuse('induction.start', 'scan_pending', 'This file is not available yet.', 'A released file', 'The venue');
  end if;
  return jsonb_build_object('ok', true, 'storage_path', m.storage_path, 'media_type', m.media_type);
end $$;

grant execute on function api.induction_media_access(uuid, uuid) to authenticated;
revoke execute on function api.induction_media_access(uuid, uuid) from anon, public;

do $m$
begin
  if to_regclass('storage.buckets') is null then
    raise notice 'storage schema absent: induction-media bucket not created';
    return;
  end if;
  -- Private; nobody reads it directly. Files are released only through api.induction_media_access.
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('induction-media', 'induction-media', false, 209715200,
          array['image/jpeg', 'image/png', 'application/pdf', 'text/vtt', 'video/mp4']);
end $m$;

create or replace function core.validate_course_content(p_customer_id uuid, p_content jsonb, p_strict boolean)
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
            errs := errs || format('A text block in "%s" is empty.', m ->> 'title');
          end if;
        when 'image' then
          if p_strict and not coalesce((b ->> 'decorative')::boolean, false) and length(btrim(coalesce(b ->> 'alt', ''))) = 0 then
            errs := errs || format('An image in "%s" needs alt text, or must be marked decorative.', m ->> 'title');
          end if;
        when 'video' then
          if p_strict and (b ->> 'caption_media_id') is null then
            errs := errs || format('A video in "%s" needs a captions file.', m ->> 'title');
          end if;
          if p_strict and length(btrim(coalesce(b ->> 'transcript', ''))) = 0 then
            errs := errs || format('A video in "%s" needs a transcript.', m ->> 'title');
          end if;
        when 'document' then null;
        else
          errs := errs || format('Module "%s" has a block of unknown type "%s".', m ->> 'key', b ->> 'type');
      end case;
      if (b ->> 'type') in ('image', 'video', 'document') then
        if (b ->> 'media_id') is null then
          if p_strict then errs := errs || format('The %s in "%s" has no file yet.', b ->> 'type', m ->> 'title'); end if;
        elsif not exists (select 1 from core.induction_media x where x.id = (b ->> 'media_id')::uuid
                                                                  and x.customer_id = p_customer_id) then
          errs := errs || format('The %s in "%s" refers to a file that does not exist.', b ->> 'type', m ->> 'title');
        elsif p_strict and exists (select 1 from core.induction_media x where x.id = (b ->> 'media_id')::uuid
                                                                        and x.scan_status not in ('clean', 'not_scanned')) then
          errs := errs || format('The %s in "%s" is waiting for or failed its malware check.', b ->> 'type', m ->> 'title');
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
