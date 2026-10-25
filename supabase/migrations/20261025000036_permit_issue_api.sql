-- 0036 Permits 5b API: calendars and notice, restriction windows, exceptions, team,
--      issue, acceptance and expiry (D-018)
--
-- Notice convention (to be confirmed by the technical authority with the Olympia/OES
-- source, N2): a request made after the cut-off counts from the next day; N working days'
-- notice means work may start at the beginning of the Nth working day after that day;
-- N calendar days likewise without the working-day test; N hours is exact. Zero means no
-- notice. A class may set longer notice for particular areas, system types or event
-- phases; the longest applicable notice counts.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

-- ---------------------------------------------------------------------------
-- Calendars and notice (Q84-Q90, P5-8)
-- ---------------------------------------------------------------------------
create function core.calendar_at(p_venue_id uuid, p_at timestamptz) returns core.venue_calendar_version
language sql stable security definer set search_path = '' as $$
  select * from core.venue_calendar_version where venue_id = p_venue_id and effective_from <= p_at
   order by effective_from desc, created_at desc limit 1 $$;

create function core.is_working_day(c core.venue_calendar_version, d date) returns boolean
language sql immutable set search_path = '' as $$
  select extract(isodow from d)::integer = any (c.working_weekdays) and not (d = any (c.closures)) $$;

-- The earliest start a single notice rule allows for a request made at p_from.
create function core.notice_start(p_venue_id uuid, p_rule jsonb, p_cutoff_applies boolean, p_from timestamptz)
returns timestamptz language plpgsql stable security definer set search_path = '' as $$
declare
  tz   text := (select timezone from core.venue where id = p_venue_id);
  c    core.venue_calendar_version := core.calendar_at(p_venue_id, p_from);
  n    integer := (p_rule ->> 'amount')::integer;
  d    date;
  k    integer := 0;
begin
  if n = 0 then return p_from; end if;
  if p_rule ->> 'unit' = 'hours' then return p_from + make_interval(hours => n); end if;
  d := (p_from at time zone tz)::date;
  if p_cutoff_applies and (p_from at time zone tz)::time > c.cutoff_time then d := d + 1; end if;
  if p_rule ->> 'unit' = 'calendar_days' then return ((d + n)::timestamp at time zone tz); end if;
  while k < n loop
    d := d + 1;
    if core.is_working_day(c, d) then k := k + 1; end if;
    if d > (p_from at time zone tz)::date + 3660 then
      raise exception 'the venue calendar has no working days to count notice against' using errcode = '22023';
    end if;
  end loop;
  return (d::timestamp at time zone tz);
end $$;

-- Notice for a permit's current version (or for a draft, as if submitted now: Q87).
create function core.permit_notice(p_permit_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  p core.permit; v core.permit_version; d core.permit_draft; cv core.permit_class_version;
  n jsonb; from_at timestamptz; win tstzrange; areas uuid[]; types uuid[]; earliest timestamptz; r jsonb; x timestamptz;
begin
  select * into p from core.permit where id = p_permit_id;
  select * into v from core.permit_version where id = p.current_version_id;
  select * into d from core.permit_draft where permit_id = p.id;
  cv := case when v.id is not null then (select c from core.permit_class_version c where c.id = v.class_version_id)
             else core.current_class_version(p.permit_class_id) end;
  n := cv.content -> 'notice';
  if n is null then return jsonb_build_object('known', false, 'problem', 'This class''s configuration has no notice rule.'); end if;
  if v.id is null or p.status = 'draft' then
    from_at := now(); win := tstzrange(d.window_from, d.window_to);
    areas := array(select area_id from core.work_package_area a join core.work_package w on w.current_revision_id = a.revision_id where w.id = p.work_package_id);
  else
    from_at := case when (n ->> 'restart_on_resubmission')::boolean then v.created_at
                    else (select created_at from core.permit_version where permit_id = p.id and version_no = 1) end;
    win := v.planned_window;
    areas := array(select area_id from core.work_package_area where revision_id = v.revision_id);
  end if;
  if core.calendar_at(p.venue_id, from_at) is null then
    return jsonb_build_object('known', false, 'problem', 'The venue has no working calendar for that date, so notice cannot be measured.');
  end if;
  types := array(select y.system_type_id from core.work_package_system s join core.system y on y.id = s.system_id
                  where s.revision_id = coalesce(v.revision_id, (select current_revision_id from core.work_package where id = p.work_package_id)));
  earliest := core.notice_start(p.venue_id, n, (n ->> 'cutoff_applies')::boolean, from_at);
  for r in select * from jsonb_array_elements(coalesce(n -> 'longer', '[]')) loop
    if (r ->> 'area_id') is not null and not exists (select 1 from core.area a where a.id = any (areas) and (r ->> 'area_id')::uuid = any (a.path)) then continue; end if;
    if (r ->> 'system_type_id') is not null and not ((r ->> 'system_type_id')::uuid = any (types)) then continue; end if;
    if (r ->> 'event_phase') is not null and not exists (select 1 from core.event_phase ph where ph.venue_id = p.venue_id
                                                           and ph.phase = r ->> 'event_phase' and ph.valid_during && win) then continue; end if;
    x := core.notice_start(p.venue_id, r, (n ->> 'cutoff_applies')::boolean, from_at);
    if x > earliest then earliest := x; end if;
  end loop;
  -- Work cannot start before the request exists, so a window that opened earlier starts,
  -- for notice, when the request was made.
  return jsonb_build_object('known', true, 'measured_from', from_at, 'earliest_start', earliest,
                            'compliant', greatest(lower(win), from_at) >= earliest, 'window_from', lower(win));
end $$;

-- Restriction windows that touch a permit: overlapping in time, and on an area the job
-- covers, inside or containing it.
create function core.permit_restrictions(p_permit_id uuid) returns setof core.restriction_window
language sql stable security definer set search_path = '' as $$
  select w.* from core.restriction_window w, core.permit p
    join core.permit_version v on v.id = p.current_version_id
   where p.id = p_permit_id and w.venue_id = p.venue_id and w.ended_at is null and w.during && v.planned_window
     and exists (select 1 from core.work_package_area x join core.area a on a.id = x.area_id
                  where x.revision_id = v.revision_id
                    and exists (select 1 from unnest(w.area_ids) wa join core.area b on b.id = wa
                                 where wa = any (a.path) or a.id = any (b.path))) $$;

create function core.exception_allowed(p_version_id uuid, p_kind text, p_window_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from core.exception_request r join core.exception_decision d on d.exception_request_id = r.id
                  where r.permit_version_id = p_version_id and r.kind = p_kind
                    and r.restriction_window_id is not distinct from p_window_id and d.outcome = 'allowed') $$;

-- Submission now also needs the venue's calendar and the class's notice rule (P5-8).
create or replace function core.permit_draft_problems(p_permit_id uuid) returns text[]
language plpgsql stable security definer set search_path = '' as $$
declare
  p core.permit; wp core.work_package; rev core.work_package_revision; d core.permit_draft;
  cv core.permit_class_version; errs text[] := '{}';
begin
  select * into p from core.permit where id = p_permit_id;
  select * into wp from core.work_package where id = p.work_package_id;
  select * into rev from core.work_package_revision where id = wp.current_revision_id;
  select * into d from core.permit_draft where permit_id = p_permit_id;
  cv := core.current_class_version(p.permit_class_id);
  if wp.status <> 'routed' then
    errs := errs || text 'The job is not routed: it changed, or its screening is not settled. Settle the job first.';
  end if;
  if cv.id is null then
    errs := errs || text 'This permit class has no approved configuration at this venue, so it cannot be requested yet.';
  else
    errs := errs || core.screening_answer_problems(jsonb_build_object('questions', cv.content -> 'questions'), d.answers);
    if cv.content -> 'notice' is null then
      errs := errs || text 'This class''s approved configuration has no notice rule; the venue must approve one first.';
    end if;
  end if;
  if core.calendar_at(p.venue_id, now()) is null then
    errs := errs || text 'The venue has not published a working calendar, so notice cannot be measured yet.';
  end if;
  if d.window_from is null or d.window_to is null or d.window_to <= d.window_from then
    errs := errs || text 'Give the start and end of the permit''s window.';
  elsif not (tstzrange(d.window_from, d.window_to) <@ rev.planned_window) then
    errs := errs || text 'The permit''s window must sit within the job''s planned dates.';
  end if;
  return errs;
end $$;

create function api.publish_venue_calendar(p_idempotency_key text, p_venue_id uuid, p_working_weekdays integer[], p_closures date[],
                                           p_cutoff_time time, p_effective_from timestamptz, p_change_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_id uuid := gen_random_uuid(); v_customer uuid := core.venue_customer(p_venue_id); v jsonb; t jsonb; r jsonb;
begin
  t := jsonb_build_object('customer_id', v_customer, 'venue_id', p_venue_id, 'record_id', v_id, 'target_type', 'venue_calendar_version');
  r := jsonb_build_object('venue_id', p_venue_id, 'weekdays', p_working_weekdays, 'closures', p_closures, 'cutoff', p_cutoff_time,
                          'from', p_effective_from, 'reason', p_change_reason);
  v := core.authorised_or_refusal('venue_calendar.publish', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if p_working_weekdays is null or cardinality(p_working_weekdays) = 0 or p_cutoff_time is null or p_effective_from is null
     or p_closures is null or length(btrim(coalesce(p_change_reason, ''))) = 0 then
    return core.refuse('venue_calendar.publish', 'invalid_content',
      'A calendar needs its working days, closure dates (which may be none), cut-off time, effective date and a reason. None has a default.',
      'Every part of the calendar', 'You');
  end if;
  v := authz.require('venue_calendar.publish', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.venue_calendar_version (id, customer_id, venue_id, working_weekdays, closures, cutoff_time, owner_person_id,
                                           effective_from, change_reason, decision_context_id)
  values (v_id, v_customer, p_venue_id, p_working_weekdays, p_closures, p_cutoff_time, (v ->> 'actor_person_id')::uuid,
          p_effective_from, p_change_reason, (v ->> 'decision_context_id')::uuid);
  return v;
end $$;

-- What notice a permit needs and whether it is met (Q87), for anyone who can see it.
create function api.permit_notice(p_permit_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_permit_id not in (select authz.visible_permit_ids()) then
    return core.refuse('permit.submit', 'not_found', 'The record does not exist or you do not have access to it.', 'Access', 'The job''s organisation');
  end if;
  return jsonb_build_object('ok', true) || core.permit_notice(p_permit_id);
end $$;

-- ---------------------------------------------------------------------------
-- Restriction windows (event and area clashes, scenario 4)
-- ---------------------------------------------------------------------------
create function api.create_restriction_window(p_idempotency_key text, p_venue_id uuid, p_area_ids uuid[], p_effect text, p_reason text,
                                              p_from timestamptz default null, p_to timestamptz default null,
                                              p_event_phase_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_id uuid := gen_random_uuid(); v_customer uuid := core.venue_customer(p_venue_id); v jsonb; t jsonb; r jsonb; during tstzrange;
begin
  t := jsonb_build_object('customer_id', v_customer, 'venue_id', p_venue_id, 'record_id', v_id, 'target_type', 'restriction_window');
  r := jsonb_build_object('venue_id', p_venue_id, 'areas', p_area_ids, 'effect', p_effect, 'reason', p_reason,
                          'from', p_from, 'to', p_to, 'event_phase_id', p_event_phase_id);
  v := core.authorised_or_refusal('restriction_window.create', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  during := case when p_event_phase_id is not null
                 then (select valid_during from core.event_phase where id = p_event_phase_id and venue_id = p_venue_id)
                 else tstzrange(p_from, p_to) end;
  if during is null or upper_inf(during) or lower_inf(during) or isempty(during) or p_effect not in ('no_work', 'decision_required')
     or cardinality(coalesce(p_area_ids, '{}')) = 0
     or exists (select 1 from unnest(p_area_ids) a where not exists (select 1 from core.area x where x.id = a and x.venue_id = p_venue_id))
     or length(btrim(coalesce(p_reason, ''))) = 0 then
    return core.refuse('restriction_window.create', 'invalid_content',
      'A restriction needs areas at this venue, a start and end (or an event phase), whether work is barred or needs a decision, and a reason.',
      'Every part of the restriction', 'You');
  end if;
  v := authz.require('restriction_window.create', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.restriction_window (id, customer_id, venue_id, area_ids, during, event_phase_id, effect, reason, owner_person_id)
  values (v_id, v_customer, p_venue_id, p_area_ids, during, p_event_phase_id, p_effect, p_reason, (v ->> 'actor_person_id')::uuid);
  return v;
end $$;

create function api.end_restriction_window(p_idempotency_key text, p_window_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare w core.restriction_window; v jsonb;
begin
  select * into w from core.restriction_window where id = p_window_id;
  v := authz.require('restriction_window.end',
         jsonb_build_object('customer_id', w.customer_id, 'venue_id', w.venue_id, 'record_id', p_window_id, 'target_type', 'restriction_window'),
         p_idempotency_key, jsonb_build_object('window_id', p_window_id));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  update core.restriction_window set ended_at = now() where id = p_window_id and ended_at is null;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Exceptions (Q90-Q96, P5-9)
-- ---------------------------------------------------------------------------
create function api.request_exception(p_idempotency_key text, p_permit_id uuid, p_kind text, p_reason text, p_consequence text,
                                      p_restriction_window_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  p core.permit; wp core.work_package; cv core.permit_class_version; v_action text; t jsonb; r jsonb; v jsonb;
  v_id uuid := gen_random_uuid(); notice jsonb; w core.restriction_window;
begin
  select * into p from core.permit where id = p_permit_id;
  select * into wp from core.work_package where id = p.work_package_id;
  v_action := core.wp_action('permit.request_exception', p.work_package_id, p.customer_id);
  t := core.permit_target(p, v_id, 'exception_request', coalesce(core.wp_actor_org(p.work_package_id), wp.performing_organisation_id));
  r := jsonb_build_object('permit_id', p_permit_id, 'kind', p_kind, 'reason', p_reason, 'consequence', p_consequence,
                          'window_id', p_restriction_window_id);
  v := core.authorised_or_refusal(v_action, t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if p.status not in ('submitted', 'under_review', 'more_information_required', 'approved_for_issue') then
    return core.refuse(v_action, 'not_open', 'An exception can be asked for only on a submitted request that is not yet issued.',
                       'A submitted request', 'You');
  end if;
  if length(btrim(coalesce(p_reason, ''))) = 0 or length(btrim(coalesce(p_consequence, ''))) = 0 then
    return core.refuse(v_action, 'invalid_content', 'Give the reason and the consequence of waiting (Q94).', 'A reason and consequence', 'You');
  end if;
  select c.* into cv from core.permit_class_version c join core.permit_version pv on pv.class_version_id = c.id where pv.id = p.current_version_id;
  if p_kind = 'late_notice' then
    notice := core.permit_notice(p.id);
    if (notice ->> 'compliant')::boolean then
      return core.refuse(v_action, 'not_needed', 'This request meets its notice, so no exception is needed.', 'Nothing', 'Nobody');
    end if;
    if (cv.content ->> 'override_prohibited')::boolean then
      return core.refuse(v_action, 'override_prohibited',
        'Late-notice exceptions are not allowed for this permit class (Q93). The work has to move to a date that meets the notice.',
        'Dates that meet the notice', 'You, by changing the job''s dates');
    end if;
  elsif p_kind = 'restriction_conflict' then
    select * into w from core.permit_restrictions(p.id) x where x.id = p_restriction_window_id;
    if w.id is null then
      return core.refuse(v_action, 'not_needed', 'That restriction does not affect this request.', 'A restriction that applies', 'Nobody');
    end if;
    if w.effect = 'no_work' then
      return core.refuse(v_action, 'no_work', 'No work is allowed in that area at that time: this restriction cannot be excepted.',
                         'Dates or areas outside the restriction', 'You, by changing the job; or the venue, by ending the restriction');
    end if;
  else
    raise exception 'kind must be late_notice or restriction_conflict' using errcode = '22023';
  end if;
  v := authz.require(v_action, t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.exception_request (id, customer_id, venue_id, permit_version_id, kind, restriction_window_id, reason,
                                      consequence_of_delay, requested_by_person_id, decision_context_id)
  values (v_id, p.customer_id, p.venue_id, p.current_version_id, p_kind, case when p_kind = 'restriction_conflict' then p_restriction_window_id end,
          p_reason, p_consequence, (v ->> 'actor_person_id')::uuid, (v ->> 'decision_context_id')::uuid);
  return v;
end $$;

create function api.decide_exception(p_idempotency_key text, p_request_id uuid, p_outcome text, p_reason text,
                                     p_conditions text default null,
                                     p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare q core.exception_request; p core.permit; v_id uuid := gen_random_uuid(); t jsonb; r jsonb; v jsonb;
begin
  if p_outcome not in ('allowed', 'refused') then
    raise exception 'outcome must be allowed or refused' using errcode = '22023';
  end if;
  select * into q from core.exception_request where id = p_request_id;
  select p2.* into p from core.permit p2 join core.permit_version pv on pv.permit_id = p2.id where pv.id = q.permit_version_id;
  t := core.permit_target(p, v_id, 'exception_decision', null)
       || (select core.revision_scope(pv.revision_id) from core.permit_version pv where pv.id = q.permit_version_id)
       || jsonb_build_object('permit_class_id', p.permit_class_id, 'excluded_person_ids', core.permit_people(p.id));
  r := jsonb_build_object('request_id', p_request_id, 'outcome', p_outcome, 'reason', p_reason, 'conditions', p_conditions);
  v := core.authorised_or_refusal('permit.exception_decide', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if exists (select 1 from core.exception_decision where exception_request_id = p_request_id) then
    return core.refuse('permit.exception_decide', 'not_open', 'This exception has already been decided.', 'An open request', 'Nobody');
  end if;
  if length(btrim(coalesce(p_reason, ''))) = 0 then
    return core.refuse('permit.exception_decide', 'invalid_content', 'Give the reason for the decision.', 'A reason', 'You');
  end if;
  v := authz.require('permit.exception_decide', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.exception_decision (id, customer_id, venue_id, exception_request_id, outcome, conditions, reason,
                                       decider_person_id, decision_context_id)
  values (v_id, q.customer_id, q.venue_id, q.id, p_outcome, nullif(btrim(coalesce(p_conditions, '')), ''), p_reason,
          (v ->> 'actor_person_id')::uuid, (v ->> 'decision_context_id')::uuid);
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- The team (Q99): one supervisor, everyone working with the performing organisation.
-- Editable until issue; frozen in the snapshot.
-- ---------------------------------------------------------------------------
create function api.set_permit_team(p_idempotency_key text, p_permit_id uuid, p_members jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p core.permit; wp core.work_package; v_action text; t jsonb; r jsonb; v jsonb; m jsonb; problems text[] := '{}';
begin
  select * into p from core.permit where id = p_permit_id;
  select * into wp from core.work_package where id = p.work_package_id;
  v_action := core.wp_action('permit.set_team', p.work_package_id, p.customer_id);
  t := core.permit_target(p, p_permit_id, 'permit', coalesce(core.wp_actor_org(p.work_package_id), wp.performing_organisation_id));
  r := jsonb_build_object('permit_id', p_permit_id, 'members', p_members);
  v := core.authorised_or_refusal(v_action, t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if p.status not in ('draft', 'submitted', 'under_review', 'more_information_required', 'approved_for_issue') then
    return core.refuse(v_action, 'not_open', 'The team can be changed only before the permit is issued. Changes after issue are not yet available.',
                       'A permit not yet issued', 'The permit issuer');
  end if;
  if jsonb_typeof(p_members) is distinct from 'array'
     or (select count(*) from jsonb_array_elements(p_members) x where x ->> 'role' = 'supervisor') <> 1
     or exists (select 1 from jsonb_array_elements(p_members) x where coalesce(x ->> 'role', '') not in ('supervisor', 'operative')) then
    problems := problems || text 'Name exactly one supervisor; everyone else is an operative.';
  end if;
  for m in select * from jsonb_array_elements(case when jsonb_typeof(p_members) = 'array' then p_members else '[]' end) loop
    if coalesce(m ->> 'person_id', '') !~ '^[0-9a-f-]{36}$'
       or not exists (select 1 from core.person_organisation_relationship x
                       where x.person_id = (m ->> 'person_id')::uuid and x.organisation_id = wp.performing_organisation_id
                         and x.status = 'active' and now() <@ x.valid_during) then
      problems := problems || text 'Everyone on the team must currently work with the performing organisation.';
      exit;
    end if;
  end loop;
  if (select count(*) from jsonb_array_elements(case when jsonb_typeof(p_members) = 'array' then p_members else '[]' end) x)
     <> (select count(distinct x ->> 'person_id') from jsonb_array_elements(case when jsonb_typeof(p_members) = 'array' then p_members else '[]' end) x) then
    problems := problems || text 'Each person can be named once.';
  end if;
  if cardinality(problems) > 0 then
    return core.refuse(v_action, 'invalid_content', 'The team has problems.', 'Each item listed', 'You', jsonb_build_object('problems', to_jsonb(problems)));
  end if;
  v := authz.require(v_action, t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  update core.permit_team_member set removed_at = now() where permit_id = p.id and removed_at is null;
  insert into core.permit_team_member (customer_id, venue_id, permit_id, person_id, role, added_by_person_id)
  select p.customer_id, p.venue_id, p.id, (x ->> 'person_id')::uuid, x ->> 'role', (v ->> 'actor_person_id')::uuid
    from jsonb_array_elements(p_members) x;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Issue (Q98, Q99, Q102, P5-10, P5-11)
-- ---------------------------------------------------------------------------
-- Every reason a permit cannot be issued now, each with who can resolve it. Empty means
-- it may be issued, subject to the issuer's own authority.
create function core.issue_blockers(p_permit_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  p core.permit; v core.permit_version; wp core.work_package; cv core.permit_class_version; e core.engagement;
  tz text; notice jsonb; w core.restriction_window; b jsonb := '[]'; m record; c text; first_day timestamptz;
  ev jsonb; parent_status text;
begin
  select * into p from core.permit where id = p_permit_id;
  select * into v from core.permit_version where id = p.current_version_id;
  select * into wp from core.work_package where id = p.work_package_id;
  select * into cv from core.permit_class_version where id = v.class_version_id;
  select * into e from core.engagement where id = wp.performing_engagement_id;
  tz := (select timezone from core.venue where id = p.venue_id);

  -- The request itself.
  if p.status <> 'approved_for_issue' then
    b := b || jsonb_build_object('check', 'approval', 'problem', 'The request is not approved for issue.', 'who', 'The reviewers of its approval steps');
  end if;
  if wp.status <> 'routed' or v.revision_id <> wp.current_revision_id then
    b := b || jsonb_build_object('check', 'job', 'problem', 'The job has changed since this request was approved.', 'who', 'The applicant');
  end if;
  if p.kind = 'child' then
    parent_status := (select status from core.permit where id = p.parent_permit_id);
    if parent_status not in ('issued_awaiting_acceptance', 'active') then
      b := b || jsonb_build_object('check', 'parent', 'problem', 'The job''s Work Approval has not been issued yet.', 'who', 'The permit issuer');
    end if;
  elsif exists (select 1 from core.wp_required_classes(wp.id) rc
                 where not exists (select 1 from core.permit x where x.parent_permit_id = p.id and x.permit_class_id = rc
                                     and x.status in ('approved_for_issue', 'issued_awaiting_acceptance', 'active'))) then
    b := b || jsonb_build_object('check', 'children', 'problem', 'Not every permit the job requires is approved for issue.', 'who', 'The applicant and the reviewers');
  end if;
  -- When (Q102): not before the start of the window's first day, venue time; not after it ends.
  first_day := (date_trunc('day', lower(v.planned_window) at time zone tz) at time zone tz);
  if now() < first_day then
    b := b || jsonb_build_object('check', 'window', 'problem', format('A permit is issued on the day: not before %s.',
                                  to_char(first_day at time zone tz, 'DD/MM/YYYY')), 'who', 'Nobody: wait for the day');
  elsif now() >= upper(v.planned_window) then
    b := b || jsonb_build_object('check', 'window', 'problem', 'The permit''s window has ended.', 'who', 'The applicant, with new dates');
  end if;
  -- Notice (P5-8) and restrictions (scenario 4).
  notice := core.permit_notice(p.id);
  if not coalesce((notice ->> 'known')::boolean, false) then
    b := b || jsonb_build_object('check', 'notice', 'problem', notice ->> 'problem', 'who', 'The venue');
  elsif not (notice ->> 'compliant')::boolean and not core.exception_allowed(v.id, 'late_notice', null) then
    b := b || jsonb_build_object('check', 'notice', 'problem',
      format('The request gave less notice than the class needs (earliest start %s) and no late-notice exception is allowed.',
             to_char((notice ->> 'earliest_start')::timestamptz at time zone tz, 'DD/MM/YYYY HH24:MI')),
      'who', case when (cv.content ->> 'override_prohibited')::boolean then 'Nobody: this class allows no exception; change the dates'
                  else 'The venue''s exception authority' end);
  end if;
  for w in select * from core.permit_restrictions(p.id) loop
    if w.effect = 'no_work' then
      b := b || jsonb_build_object('check', 'restriction', 'problem', format('No work is allowed there then: %s.', w.reason), 'who', 'The venue');
    elsif not core.exception_allowed(v.id, 'restriction_conflict', w.id) then
      b := b || jsonb_build_object('check', 'restriction', 'problem', format('The request clashes with a restriction (%s) and no exception is allowed.', w.reason),
                                   'who', 'The venue''s exception authority');
    end if;
  end loop;
  -- Physical controls (P5-11).
  if (cv.content ->> 'requires_physical_controls')::boolean then
    b := b || jsonb_build_object('check', 'controls', 'problem',
      'This class needs physical controls (isolation, impairment or fire watch), which cannot be recorded yet, so it cannot be issued.',
      'who', 'Nobody until live controls are available');
  end if;
  -- The organisation.
  if e.status <> 'active' or not (now() <@ e.valid_during) or authz.organisation_restricted(wp.performing_organisation_id, p.venue_id) then
    b := b || jsonb_build_object('check', 'organisation', 'problem', 'The performing organisation''s engagement is not active, or it is restricted at this venue.',
                                 'who', 'The venue''s compliance authority');
  else
    ev := authz.evidence_lines(p.venue_id, 'engagement', e.capacity_code, wp.performing_organisation_id, null, v.planned_window);
    if authz.evidence_blocking(ev) then
      b := b || jsonb_build_object('check', 'evidence', 'problem', 'The organisation''s evidence is not in place for the permit''s dates.',
                                   'who', 'The organisation and the venue''s document reviewers');
    end if;
  end if;
  -- The team (Q99).
  if not exists (select 1 from core.permit_team_member where permit_id = p.id and removed_at is null and role = 'supervisor') then
    b := b || jsonb_build_object('check', 'team', 'problem', 'No supervisor is named.', 'who', 'The applicant');
  end if;
  for m in select t.person_id, t.role, core.person_name(t.person_id) as name from core.permit_team_member t
            where t.permit_id = p.id and t.removed_at is null loop
    if not exists (select 1 from core.person_organisation_relationship x where x.person_id = m.person_id
                     and x.organisation_id = wp.performing_organisation_id and x.status = 'active' and now() <@ x.valid_during) then
      b := b || jsonb_build_object('check', 'team', 'problem', format('%s no longer works with the performing organisation.', m.name), 'who', 'The applicant');
    end if;
    if authz.person_restricted(m.person_id, p.venue_id) then
      b := b || jsonb_build_object('check', 'team', 'problem', format('%s is restricted at this venue.', m.name), 'who', 'The authority that imposed the restriction');
    end if;
    for c in select jsonb_array_elements_text(coalesce(cv.content #> '{evidence,induction_course_ids}', '[]')) loop
      if not exists (select 1 from core.induction_completion ic join core.course_version k on k.id = ic.course_version_id
                      where ic.person_id = m.person_id and k.course_id = c::uuid and ic.valid_until >= upper(v.planned_window)
                        and not exists (select 1 from core.completion_invalidation i where i.completion_id = ic.id)) then
        b := b || jsonb_build_object('check', 'induction', 'problem',
          format('%s has no valid %s induction for the permit''s dates.', m.name, (select title from core.induction_course where id = c::uuid)),
          'who', format('%s, by completing it', m.name));
      end if;
    end loop;
    for c in select jsonb_array_elements_text(coalesce(cv.content #> '{evidence,team_competency_type_ids}', '[]')
                                            || case when m.role = 'supervisor' then coalesce(cv.content #> '{evidence,supervisor_competency_type_ids}', '[]') else '[]' end) loop
      if not exists (select 1 from core.competency k
                      join lateral (select * from core.competency_verification cvx where cvx.competency_id = k.id
                                     order by cvx.created_at desc limit 1) last on true
                      where k.person_id = m.person_id and k.competency_type_id = c::uuid and last.outcome = 'verified'
                        and (last.valid_until is null or last.valid_until >= upper(v.planned_window)::date)
                        and (k.expires_on is null or k.expires_on >= upper(v.planned_window)::date)) then
        b := b || jsonb_build_object('check', 'competency', 'problem',
          format('%s has no checked %s valid for the permit''s dates.', m.name, (select label from core.competency_type where id = c::uuid)),
          'who', 'The organisation, then the venue''s competency checker');
      end if;
    end loop;
  end loop;
  return b;
end $$;

create function api.issue_blockers(p_permit_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_permit_id not in (select authz.visible_permit_ids()) then
    return core.refuse('permit.issue', 'not_found', 'The record does not exist or you do not have access to it.', 'Access', 'The venue');
  end if;
  return jsonb_build_object('ok', true, 'blockers', core.issue_blockers(p_permit_id), 'notice', core.permit_notice(p_permit_id));
end $$;

-- Four-eyes (P5-10): everyone connected with the job, every declarer, and everyone who
-- decided a step on the version being issued.
create function core.issue_excluded(p_permit_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select core.permit_people(p.id)
         || coalesce((select jsonb_agg(distinct d.decider_person_id) from core.permit_step s
                        join core.step_decision d on d.permit_step_id = s.id where s.permit_version_id = p.current_version_id), '[]')
    from core.permit p where p.id = p_permit_id $$;

create function api.issue_permit(p_idempotency_key text, p_permit_id uuid, p_expected_version integer,
                                 p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  p core.permit; v core.permit_version; t jsonb; r jsonb; v_ok jsonb; blockers jsonb; ctx uuid; snap jsonb; snap_id uuid := gen_random_uuid();
begin
  select * into p from core.permit where id = p_permit_id;
  select * into v from core.permit_version where id = p.current_version_id;
  t := core.permit_target(p, p_permit_id, 'permit', null)
       || core.revision_scope(v.revision_id)
       || jsonb_build_object('permit_class_id', p.permit_class_id, 'excluded_person_ids', core.issue_excluded(p.id));
  r := jsonb_build_object('permit_id', p_permit_id, 'expected_version', p_expected_version);
  v_ok := core.authorised_or_refusal('permit.issue', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v_ok is not null then return v_ok; end if;
  blockers := core.issue_blockers(p_permit_id);
  if jsonb_array_length(blockers) > 0 then
    return core.refuse('permit.issue', 'not_ready', 'This permit cannot be issued yet.', 'Each item listed', 'As listed for each item',
                       jsonb_build_object('blockers', blockers));
  end if;
  v_ok := authz.require('permit.issue', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v_ok ->> 'ok')::boolean or (v_ok ->> 'replayed')::boolean then return v_ok; end if;
  ctx := (v_ok ->> 'decision_context_id')::uuid;

  -- Invariant 5: everything the issue relied on, frozen.
  snap := jsonb_build_object(
    'permit', jsonb_build_object('id', p.id, 'kind', p.kind, 'class', (select jsonb_build_object('id', id, 'code', code, 'name', name)
                                                                         from core.permit_class where id = p.permit_class_id),
                                 'parent_permit_id', p.parent_permit_id),
    'version', jsonb_build_object('id', v.id, 'no', v.version_no, 'answers', v.answers, 'window_from', lower(v.planned_window),
                                  'window_to', upper(v.planned_window), 'declaration', v.declaration,
                                  'declared_by', v.declared_by_person_id, 'documents', to_jsonb(v.document_version_ids)),
    'class_version', (select jsonb_build_object('id', c.id, 'no', c.version_no, 'sha256', encode(c.content_sha256, 'hex'),
                                                'acceptance_declaration', c.content -> 'acceptance_declaration')
                        from core.permit_class_version c where c.id = v.class_version_id),
    'job', (select jsonb_build_object('id', w.id, 'reference', w.reference, 'revision_id', r2.id, 'title', r2.title, 'scope', r2.scope,
                                      'method', r2.method, 'performing_organisation_id', w.performing_organisation_id,
                                      'areas', (select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name)) from core.work_package_area x
                                                  join core.area a on a.id = x.area_id where x.revision_id = r2.id))
              from core.work_package w join core.work_package_revision r2 on r2.id = v.revision_id where w.id = p.work_package_id),
    'steps', (select coalesce(jsonb_agg(jsonb_build_object('key', s.step_key, 'name', s.name, 'kind', s.kind,
                'decision', (select jsonb_build_object('id', d.id, 'outcome', d.outcome, 'reason', d.reason, 'scope_wording', d.scope_wording,
                                                       'decider', d.decider_person_id, 'at', d.created_at,
                                                       'conditions', (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'text', k.text,
                                                                        'acknowledge', k.acknowledge_at_acceptance)), '[]')
                                                                        from core.permit_condition k where k.step_decision_id = d.id))
                               from core.step_decision d where d.id = (core.latest_decision(s.id)).id)) order by s.group_no, s.step_key), '[]')
                from core.permit_step s where s.permit_version_id = v.id),
    'exceptions', (select coalesce(jsonb_agg(jsonb_build_object('kind', q.kind, 'reason', q.reason, 'outcome', d.outcome,
                                                                'conditions', d.conditions, 'decider', d.decider_person_id)), '[]')
                     from core.exception_request q join core.exception_decision d on d.exception_request_id = q.id
                    where q.permit_version_id = v.id),
    'notice', core.permit_notice(p.id),
    'calendar_version_id', (core.calendar_at(p.venue_id, now())).id,
    'team', (select coalesce(jsonb_agg(jsonb_build_object('person_id', t2.person_id, 'name', core.person_name(t2.person_id), 'role', t2.role,
               'inductions', (select coalesce(jsonb_agg(ic.id), '[]') from core.induction_completion ic join core.course_version k on k.id = ic.course_version_id
                               where ic.person_id = t2.person_id
                                 and k.course_id::text in (select jsonb_array_elements_text(coalesce((select content #> '{evidence,induction_course_ids}'
                                                                                                        from core.permit_class_version where id = v.class_version_id), '[]')))
                                 and ic.valid_until >= upper(v.planned_window)))
             order by t2.role desc, t2.person_id), '[]')
               from core.permit_team_member t2 where t2.permit_id = p.id and t2.removed_at is null),
    'issuer', jsonb_build_object('person_id', v_ok ->> 'actor_person_id', 'appointment_id', v_ok -> 'acting_appointment_id',
                                 'delegation_id', v_ok -> 'acting_delegation_id'),
    'issued_at', clock_timestamp());
  insert into core.issue_snapshot (id, customer_id, venue_id, permit_id, permit_version_id, content, content_sha256, issuer_person_id, decision_context_id)
  values (snap_id, p.customer_id, p.venue_id, p.id, v.id, snap, sha256(convert_to(snap::text, 'UTF8')), (v_ok ->> 'actor_person_id')::uuid, ctx);
  perform core.transition('core.permit', p.id, 'issued_awaiting_acceptance', p_expected_version, ctx,
                          jsonb_build_object('issue_snapshot_id', snap_id));
  return v_ok || jsonb_build_object('issue_snapshot_id', snap_id);
end $$;

-- ---------------------------------------------------------------------------
-- Acceptance at the workface (Q100, Q101, Q103): the named supervisor only, online.
-- ---------------------------------------------------------------------------
create function api.accept_permit(p_idempotency_key text, p_permit_id uuid, p_expected_version integer,
                                  p_acknowledged_condition_ids uuid[], p_briefed_person_ids uuid[], p_briefed_at timestamptz)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  p core.permit; s core.issue_snapshot; sup uuid; t jsonb; r jsonb; v jsonb; ctx uuid; required uuid[]; team uuid[]; decl jsonb;
begin
  select * into p from core.permit where id = p_permit_id;
  select * into s from core.issue_snapshot where id = p.issue_snapshot_id;
  sup := (select (x ->> 'person_id')::uuid from jsonb_array_elements(s.content -> 'team') x where x ->> 'role' = 'supervisor');
  t := core.permit_target(p, p_permit_id, 'permit', null) || jsonb_build_object('subject_person_id', sup);
  r := jsonb_build_object('permit_id', p_permit_id, 'expected_version', p_expected_version, 'acknowledged', p_acknowledged_condition_ids,
                          'briefed', p_briefed_person_ids, 'briefed_at', p_briefed_at);
  v := core.authorised_or_refusal('permit.accept', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if p.status <> 'issued_awaiting_acceptance' then
    return core.refuse('permit.accept', 'not_issued', 'Only an issued permit waiting for acceptance can be accepted.', 'An issued permit', 'The permit issuer');
  end if;
  if now() >= ((s.content #>> '{version,window_to}')::timestamptz) then
    return core.refuse('permit.accept', 'window_ended', 'The permit''s window has ended.', 'A permit for the current dates', 'The applicant');
  end if;
  if p.kind = 'child' and (select status from core.permit where id = p.parent_permit_id) <> 'active' then
    return core.refuse('permit.accept', 'parent_not_active', 'The job''s Work Approval must be accepted first.', 'An active Work Approval',
                       'The Work Approval''s supervisor');
  end if;
  required := array(select (k ->> 'id')::uuid from jsonb_array_elements(s.content -> 'steps') st,
                    jsonb_array_elements(coalesce(st #> '{decision,conditions}', '[]')) k where (k ->> 'acknowledge')::boolean);
  team := array(select (x ->> 'person_id')::uuid from jsonb_array_elements(s.content -> 'team') x);
  if not (required <@ coalesce(p_acknowledged_condition_ids, '{}')) then
    return core.refuse('permit.accept', 'conditions_not_acknowledged', 'Acknowledge every condition marked for acceptance.',
                       'Each condition acknowledged', 'You');
  end if;
  if cardinality(coalesce(p_briefed_person_ids, '{}')) = 0 or not (p_briefed_person_ids <@ team) or p_briefed_at is null
     or p_briefed_at > clock_timestamp() or p_briefed_at < s.issued_at then
    return core.refuse('permit.accept', 'briefing_incomplete',
      'Record the workface briefing (Q103): who from the team was briefed, and when (after issue, not in the future).',
      'A briefing record', 'You');
  end if;
  v := authz.require('permit.accept', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ctx := (v ->> 'decision_context_id')::uuid;
  decl := s.content #> '{class_version,acceptance_declaration}';
  insert into core.permit_acceptance (customer_id, venue_id, issue_snapshot_id, supervisor_person_id, declaration, declaration_sha256,
                                      acknowledged_condition_ids, briefed_person_ids, briefed_at, decision_context_id)
  values (p.customer_id, p.venue_id, s.id, sup, decl, sha256(convert_to(decl::text, 'UTF8')),
          coalesce(p_acknowledged_condition_ids, '{}'), p_briefed_person_ids, p_briefed_at, ctx);
  perform core.transition('core.permit', p.id, 'active', p_expected_version, ctx);
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Expiry (invariant 10): re-runnable; removes authority, never grants it.
-- ---------------------------------------------------------------------------
create function api.expire_permits() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare x record; v jsonb; n integer := 0;
begin
  -- Only the expiry service, whether or not anything is due.
  v := authz.evaluate('permit.expire', jsonb_build_object('record_id', gen_random_uuid(), 'target_type', 'permit'));
  if not (v ->> 'allowed')::boolean then return v; end if;
  for x in select p.id, p.customer_id, p.venue_id, p.row_version, p.status from core.permit p
             join core.permit_version pv on pv.id = p.current_version_id
            where p.status in ('approved_for_issue', 'issued_awaiting_acceptance', 'active') and upper(pv.planned_window) <= now()
            order by p.id loop
    v := authz.require('permit.expire',
           jsonb_build_object('customer_id', x.customer_id, 'venue_id', x.venue_id, 'record_id', x.id, 'target_type', 'permit'),
           'expire:' || x.id || ':' || x.status, jsonb_build_object('permit_id', x.id, 'from', x.status));
    if not (v ->> 'ok')::boolean then return v; end if;
    if not (v ->> 'replayed')::boolean then
      perform core.transition('core.permit', x.id, 'expired', x.row_version, (v ->> 'decision_context_id')::uuid);
      n := n + 1;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'expired', n);
end $$;

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------
create view api.venue_calendar_version with (security_invoker = true) as select * from core.venue_calendar_version;
create view api.restriction_window     with (security_invoker = true) as
  select id, customer_id, venue_id, area_ids, lower(during) as starts_at, upper(during) as ends_at, event_phase_id, effect, reason,
         owner_person_id, ended_at, row_version, created_at
    from core.restriction_window;
create view api.exception_request      with (security_invoker = true) as select * from core.exception_request;
create view api.exception_decision     with (security_invoker = true) as select * from core.exception_decision;
create view api.permit_team_member     with (security_invoker = true) as select * from core.permit_team_member;
create view api.issue_snapshot         with (security_invoker = true) as
  select id, customer_id, venue_id, permit_id, permit_version_id, content, encode(content_sha256, 'hex') as content_sha256,
         issuer_person_id, issued_at
    from core.issue_snapshot;
create view api.permit_acceptance      with (security_invoker = true) as
  select id, customer_id, venue_id, issue_snapshot_id, supervisor_person_id, declaration, acknowledged_condition_ids,
         briefed_person_ids, briefed_at, accepted_at
    from core.permit_acceptance;
create or replace view api.permit with (security_invoker = true) as select * from core.permit;

grant select on all tables in schema api to authenticated;
grant execute on all functions in schema api to authenticated;
revoke execute on all functions in schema api from anon, public;
