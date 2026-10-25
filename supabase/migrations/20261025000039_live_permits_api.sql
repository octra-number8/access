-- 0039 Live permits API (phase 6a, D-019)
--
-- Pattern as before: a repeated request is replayed first; readiness checks return a
-- refusal that says what is missing and who can resolve it; authority only from
-- authz.evaluate; status only through core.transition, with a derived decision for each
-- other permit a decision moves. Live checks run against the database at the moment of
-- the decision, never against what a page last showed (invariant 11): actions that depend
-- on what the caller saw take the permit's version and are refused if it has changed.
--
-- The checks issue relies on (organisation, team, restrictions, notice) are factored out
-- so re-acceptance, team additions and extensions run exactly the same checks against
-- their own window.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

-- ---------------------------------------------------------------------------
-- Shared checks, for any window
-- ---------------------------------------------------------------------------
create function core.permit_restrictions_during(p_permit_id uuid, p_window tstzrange) returns setof core.restriction_window
language sql stable security definer set search_path = '' as $$
  select w.* from core.restriction_window w, core.permit p
    join core.permit_version v on v.id = p.current_version_id
   where p.id = p_permit_id and w.venue_id = p.venue_id and w.ended_at is null and w.during && p_window
     and exists (select 1 from core.work_package_area x join core.area a on a.id = x.area_id
                  where x.revision_id = v.revision_id
                    and exists (select 1 from unnest(w.area_ids) wa join core.area b on b.id = wa
                                 where wa = any (a.path) or a.id = any (b.path))) $$;

create or replace function core.permit_restrictions(p_permit_id uuid) returns setof core.restriction_window
language sql stable security definer set search_path = '' as $$
  select * from core.permit_restrictions_during(p_permit_id,
    (select v.planned_window from core.permit p join core.permit_version v on v.id = p.current_version_id where p.id = p_permit_id)) $$;

-- The earliest start a class's notice rule (with its longer rules) allows for a request
-- made at p_from, for work in these areas and system types during p_window.
create function core.notice_earliest(p_venue_id uuid, n jsonb, p_from timestamptz, p_areas uuid[], p_types uuid[], p_window tstzrange)
returns timestamptz language plpgsql stable security definer set search_path = '' as $$
declare earliest timestamptz; r jsonb; x timestamptz;
begin
  earliest := core.notice_start(p_venue_id, n, (n ->> 'cutoff_applies')::boolean, p_from);
  for r in select * from jsonb_array_elements(coalesce(n -> 'longer', '[]')) loop
    if (r ->> 'area_id') is not null and not exists (select 1 from core.area a where a.id = any (p_areas) and (r ->> 'area_id')::uuid = any (a.path)) then continue; end if;
    if (r ->> 'system_type_id') is not null and not ((r ->> 'system_type_id')::uuid = any (p_types)) then continue; end if;
    if (r ->> 'event_phase') is not null and not exists (select 1 from core.event_phase ph where ph.venue_id = p_venue_id
                                                           and ph.phase = r ->> 'event_phase' and ph.valid_during && p_window) then continue; end if;
    x := core.notice_start(p_venue_id, r, (n ->> 'cutoff_applies')::boolean, p_from);
    if x > earliest then earliest := x; end if;
  end loop;
  return earliest;
end $$;

create or replace function core.permit_notice(p_permit_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  p core.permit; v core.permit_version; d core.permit_draft; cv core.permit_class_version;
  n jsonb; from_at timestamptz; win tstzrange; areas uuid[]; types uuid[]; earliest timestamptz;
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
  earliest := core.notice_earliest(p.venue_id, n, from_at, areas, types, win);
  -- Work cannot start before the request exists, so a window that opened earlier starts,
  -- for notice, when the request was made.
  return jsonb_build_object('known', true, 'measured_from', from_at, 'earliest_start', earliest,
                            'compliant', greatest(lower(win), from_at) >= earliest, 'window_from', lower(win));
end $$;

-- One person's fitness to be on the team for a window (Q99, Q106).
create function core.person_blockers(p_permit_id uuid, p_person_id uuid, p_role text, p_window tstzrange) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare p core.permit; v core.permit_version; wp core.work_package; cv core.permit_class_version; b jsonb := '[]'; nm text; c text;
begin
  select * into p from core.permit where id = p_permit_id;
  select * into v from core.permit_version where id = p.current_version_id;
  select * into wp from core.work_package where id = p.work_package_id;
  select * into cv from core.permit_class_version where id = v.class_version_id;
  nm := core.person_name(p_person_id);
  if not exists (select 1 from core.person_organisation_relationship x where x.person_id = p_person_id
                   and x.organisation_id = wp.performing_organisation_id and x.status = 'active' and now() <@ x.valid_during) then
    b := b || jsonb_build_object('check', 'team', 'problem', format('%s no longer works with the performing organisation.', nm), 'who', 'The applicant');
  end if;
  if authz.person_restricted(p_person_id, p.venue_id) then
    b := b || jsonb_build_object('check', 'team', 'problem', format('%s is restricted at this venue.', nm), 'who', 'The authority that imposed the restriction');
  end if;
  for c in select jsonb_array_elements_text(coalesce(cv.content #> '{evidence,induction_course_ids}', '[]')) loop
    if not exists (select 1 from core.induction_completion ic join core.course_version k on k.id = ic.course_version_id
                    where ic.person_id = p_person_id and k.course_id = c::uuid and ic.valid_until >= upper(p_window)
                      and not exists (select 1 from core.completion_invalidation i where i.completion_id = ic.id)) then
      b := b || jsonb_build_object('check', 'induction', 'problem',
        format('%s has no valid %s induction for the permit''s dates.', nm, (select title from core.induction_course where id = c::uuid)),
        'who', format('%s, by completing it', nm));
    end if;
  end loop;
  for c in select jsonb_array_elements_text(coalesce(cv.content #> '{evidence,team_competency_type_ids}', '[]')
                                          || case when p_role = 'supervisor' then coalesce(cv.content #> '{evidence,supervisor_competency_type_ids}', '[]') else '[]' end) loop
    if not exists (select 1 from core.competency k
                    join lateral (select * from core.competency_verification cvx where cvx.competency_id = k.id
                                   order by cvx.created_at desc limit 1) last on true
                    where k.person_id = p_person_id and k.competency_type_id = c::uuid and last.outcome = 'verified'
                      and (last.valid_until is null or last.valid_until >= upper(p_window)::date)
                      and (k.expires_on is null or k.expires_on >= upper(p_window)::date)) then
      b := b || jsonb_build_object('check', 'competency', 'problem',
        format('%s has no checked %s valid for the permit''s dates.', nm, (select label from core.competency_type where id = c::uuid)),
        'who', 'The organisation, then the venue''s competency checker');
    end if;
  end loop;
  return b;
end $$;

-- The whole team: a supervisor, and everyone who counts fit for the window.
create function core.team_blockers(p_permit_id uuid, p_window tstzrange) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare b jsonb := '[]'; m core.permit_team_member;
begin
  if not exists (select 1 from core.permit_team_member t where t.permit_id = p_permit_id and t.role = 'supervisor' and core.member_counts(t)) then
    b := b || jsonb_build_object('check', 'team', 'problem', 'No supervisor is named.', 'who', 'The applicant');
  end if;
  for m in select * from core.permit_team_member t where t.permit_id = p_permit_id and core.member_counts(t) loop
    b := b || core.person_blockers(p_permit_id, m.person_id, m.role, p_window);
  end loop;
  return b;
end $$;

-- The performing organisation's engagement and evidence for a window.
create function core.org_blockers(p_permit_id uuid, p_window tstzrange) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare p core.permit; wp core.work_package; e core.engagement; ev jsonb;
begin
  select * into p from core.permit where id = p_permit_id;
  select * into wp from core.work_package where id = p.work_package_id;
  select * into e from core.engagement where id = wp.performing_engagement_id;
  if e.status <> 'active' or not (now() <@ e.valid_during) or authz.organisation_restricted(wp.performing_organisation_id, p.venue_id) then
    return jsonb_build_array(jsonb_build_object('check', 'organisation',
      'problem', 'The performing organisation''s engagement is not active, or it is restricted at this venue.',
      'who', 'The venue''s compliance authority'));
  end if;
  ev := authz.evidence_lines(p.venue_id, 'engagement', e.capacity_code, wp.performing_organisation_id, null, p_window);
  if authz.evidence_blocking(ev) then
    return jsonb_build_array(jsonb_build_object('check', 'evidence', 'problem', 'The organisation''s evidence is not in place for the permit''s dates.',
                                                'who', 'The organisation and the venue''s document reviewers'));
  end if;
  return '[]';
end $$;

-- Restriction windows touching the work during a window (scenario 4).
create function core.restriction_blockers(p_permit_id uuid, p_window tstzrange) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare b jsonb := '[]'; w core.restriction_window; vid uuid := (select current_version_id from core.permit where id = p_permit_id);
begin
  for w in select * from core.permit_restrictions_during(p_permit_id, p_window) loop
    if w.effect = 'no_work' then
      b := b || jsonb_build_object('check', 'restriction', 'problem', format('No work is allowed there then: %s.', w.reason), 'who', 'The venue');
    elsif not core.exception_allowed(vid, 'restriction_conflict', w.id) then
      b := b || jsonb_build_object('check', 'restriction', 'problem', format('The request clashes with a restriction (%s) and no exception is allowed.', w.reason),
                                   'who', 'The venue''s exception authority');
    end if;
  end loop;
  return b;
end $$;

-- Issue (Q98-Q102), now built from the shared checks. Same checks, same wording.
create or replace function core.issue_blockers(p_permit_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  p core.permit; v core.permit_version; wp core.work_package; cv core.permit_class_version;
  tz text; notice jsonb; b jsonb := '[]'; first_day timestamptz; parent_status text;
begin
  select * into p from core.permit where id = p_permit_id;
  select * into v from core.permit_version where id = p.current_version_id;
  select * into wp from core.work_package where id = p.work_package_id;
  select * into cv from core.permit_class_version where id = v.class_version_id;
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
  b := b || core.restriction_blockers(p.id, v.planned_window);
  -- Physical controls (P5-11).
  if (cv.content ->> 'requires_physical_controls')::boolean then
    b := b || jsonb_build_object('check', 'controls', 'problem',
      'This class needs physical controls (isolation, impairment or fire watch), which cannot be recorded yet, so it cannot be issued.',
      'who', 'Nobody until live controls are available');
  end if;
  -- The organisation and the team (Q99).
  b := b || core.org_blockers(p.id, v.planned_window) || core.team_blockers(p.id, v.planned_window);
  return b;
end $$;

-- What stops a live permit continuing (or restarting) for a window: the time, the
-- organisation, the team and restrictions. Physical controls join in phase 6b.
create function core.live_blockers(p_permit_id uuid, p_window tstzrange) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare b jsonb := '[]';
begin
  if isempty(p_window) or upper(p_window) <= now() then
    return jsonb_build_array(jsonb_build_object('check', 'window', 'problem', 'The permit''s window has ended.', 'who', 'Nobody: the work must be handed back'));
  end if;
  return b || core.org_blockers(p_permit_id, p_window) || core.team_blockers(p_permit_id, p_window)
           || core.restriction_blockers(p_permit_id, p_window);
end $$;

-- ---------------------------------------------------------------------------
-- Live helpers
-- ---------------------------------------------------------------------------
-- The target for a decision about a live permit: its job, class, areas and systems.
create function core.live_target(p core.permit, p_excluded jsonb default '[]') returns jsonb
language sql stable security definer set search_path = '' as $$
  select core.permit_target(p, p.id, 'permit', null)
         || core.revision_scope((select revision_id from core.permit_version where id = p.current_version_id))
         || jsonb_build_object('permit_class_id', p.permit_class_id, 'permit_id', p.id, 'excluded_person_ids', p_excluded) $$;

create function core.class_content(p core.permit) returns jsonb
language sql stable security definer set search_path = '' as $$
  select c.content from core.permit_version v join core.permit_class_version c on c.id = v.class_version_id
   where v.id = p.current_version_id $$;

create function core.is_live(p_status text) returns boolean
language sql immutable set search_path = '' as $$
  select p_status in ('issued_awaiting_acceptance', 'active', 'suspended') $$;

-- Who can lift a suspension, in words (CLAUDE.md §6).
create function core.suspension_owner(s core.permit_suspension) returns text
language sql stable security definer set search_path = '' as $$
  select case s.kind
    when 'stop' then 'An issuer for this permit''s class and area'
    when 'job_stop' then format('Whoever can lift the stop on the job''s %s',
                                (select pc.name from core.permit_suspension o join core.permit x on x.id = o.permit_id
                                   join core.permit_class pc on pc.id = x.permit_class_id where o.id = s.origin_suspension_id))
    when 'area_stop' then format('A venue authority for %s',
                                 (select a.name from core.area_stop z join core.area a on a.id = z.area_id where z.id = s.area_stop_id))
    when 'material_change' then 'Nobody: the job changed, so the permit must be submitted again and reissued'
    when 'supervisor_change' then 'Lifted by the change; the new supervisor re-accepts'
    when 'parent_ended' then 'Nobody: the Work Approval''s window has ended, so this permit must be handed back'
  end $$;

-- When the permit was last accepted or re-accepted at the workface.
create function core.last_accepted_at(p_permit_id uuid) returns timestamptz
language sql stable security definer set search_path = '' as $$
  select greatest((select max(a.accepted_at) from core.permit_acceptance a join core.permit p on p.issue_snapshot_id = a.issue_snapshot_id
                    where p.id = p_permit_id),
                  (select max(r.accepted_at) from core.permit_reacceptance r join core.permit p on p.issue_snapshot_id = r.issue_snapshot_id
                    where p.id = p_permit_id)) $$;

-- Lifts since the permit was last accepted: their conditions must be acknowledged at
-- re-acceptance, and the briefing must come after them.
create function core.permit_open_lifts(p_permit_id uuid) returns table (id uuid, conditions text[], created_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select l.id, l.conditions, l.created_at from core.permit_suspension s
    join core.permit_suspension_lift l on l.suspension_id = coalesce(s.origin_suspension_id, s.id)
   where s.permit_id = p_permit_id and l.created_at > coalesce(core.last_accepted_at(p_permit_id), '-infinity')
  union
  select l.id, l.conditions, l.created_at from core.permit_suspension s
    join core.area_stop_lift l on l.area_stop_id = s.area_stop_id
   where s.permit_id = p_permit_id and l.created_at > coalesce(core.last_accepted_at(p_permit_id), '-infinity') $$;

-- Revalidation due (Q112, P6-7): shown, never a silent status change.
create function core.revalidation_status(p_permit_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare p core.permit; cfg jsonb; last timestamptz; due timestamptz;
begin
  select * into p from core.permit where id = p_permit_id;
  cfg := core.class_content(p) -> 'revalidation';
  if cfg is null then return jsonb_build_object('chosen', false, 'required', false); end if;
  if cfg ->> 'mode' <> 'interval' then return jsonb_build_object('chosen', true, 'required', false); end if;
  last := greatest(core.last_accepted_at(p.id),
                   (select max(r.created_at) from core.permit_revalidation r where r.permit_id = p.id and r.issue_snapshot_id = p.issue_snapshot_id));
  due := last + make_interval(secs => ((cfg ->> 'every_hours')::numeric * 3600)::double precision);
  return jsonb_build_object('chosen', true, 'required', true, 'every_hours', (cfg ->> 'every_hours')::numeric, 'last_at', last, 'due_at', due,
                            'overdue', p.status = 'active' and due is not null and now() > due);
end $$;

-- Suspends one permit with a suspension of the given kind, under the current decision.
create function core.suspend_one(p_permit_id uuid, p_kind text, p_category text, p_reason text, p_origin uuid, p_area_stop uuid,
                                 p_actor uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare q core.permit; s_id uuid := gen_random_uuid();
begin
  select * into q from core.permit where id = p_permit_id for update;
  insert into core.permit_suspension (id, customer_id, venue_id, permit_id, kind, category, reason, origin_suspension_id, area_stop_id,
                                      stopped_by_person_id, decision_context_id)
  values (s_id, q.customer_id, q.venue_id, q.id, p_kind, p_category, p_reason, p_origin, p_area_stop, p_actor, core.ctx_uuid('decision_context_id'));
  if q.status <> 'suspended' then
    perform core.transition('core.permit', q.id, 'suspended', q.row_version, core.ctx_uuid('decision_context_id'));
  end if;
  return s_id;
end $$;

-- Stop-work for the whole job (Q110): the stopped permit, then every other live permit on
-- the job through a derived decision whose suspension is lifted with this one.
create function core.stop_job(p core.permit, p_category text, p_reason text, p_ctx uuid, p_actor uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare s_id uuid; q record;
begin
  s_id := core.suspend_one(p.id, 'stop', p_category, p_reason, null, null, p_actor);
  for q in select id from core.permit where work_package_id = p.work_package_id and id <> p.id and core.is_live(status) order by kind desc, id loop
    perform authz.derive('permit.suspend_with_job', 'permit', q.id);
    perform core.suspend_one(q.id, 'job_stop', null, p_reason, s_id, null, p_actor);
    perform authz.resume(p_ctx);
  end loop;
  return s_id;
end $$;

-- A version check that refuses (rather than fails) when the permit has changed since the
-- caller loaded it, for example because it was stopped (invariant 11).
create function core.stale(p_action text, p core.permit, p_expected_version integer) returns jsonb
language sql stable set search_path = '' as $$
  select case when p.row_version is distinct from p_expected_version then
    core.refuse(p_action, 'changed', 'This permit has changed since you opened it, for example it may have been stopped. Reload it and check its status.',
                'The permit''s current status', 'You, by reloading') end $$;

-- ---------------------------------------------------------------------------
-- Stopping work (Q109, Q110, P6-2)
-- ---------------------------------------------------------------------------
create function api.stop_work(p_idempotency_key text, p_permit_id uuid, p_category text, p_reason text,
                              p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p core.permit; v_action text; me uuid; party uuid; t jsonb; r jsonb; v jsonb; ctx uuid; s_id uuid;
begin
  set constraints core.live_dependency_check deferred;
  select * into p from core.permit where id = p_permit_id;
  me := authz.actor_person(p.customer_id);
  party := (select x.organisation_id from core.work_package_party x
             where x.revision_id = (select revision_id from core.permit_version where id = p.current_version_id)
               and x.role in ('affected_occupier', 'landlord_operator')
               and x.organisation_id in (select authz.my_admin_organisation_ids()) order by x.organisation_id limit 1);
  v_action := case when exists (select 1 from core.permit_team_member m where m.permit_id = p.id and m.person_id = me and m.removed_at is null)
                     then 'permit.stop'
                   when party is not null then 'permit.stop_as_party'
                   else 'permit.stop_as_authority' end;
  t := core.live_target(p) || case when party is not null then jsonb_build_object('organisation_id', party) else '{}' end;
  r := jsonb_build_object('permit_id', p_permit_id, 'category', p_category, 'reason', p_reason);
  v := core.authorised_or_refusal(v_action, t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if not core.is_live(p.status) then
    return core.refuse(v_action, 'not_live', 'Only an issued permit can be stopped: this one has no work authorised to stop.',
                       'An issued or active permit', 'Nobody');
  end if;
  if coalesce(p_category, '') not in ('unsafe_act', 'change_in_conditions', 'control_failure', 'emergency', 'weather', 'instruction', 'other')
     or length(btrim(coalesce(p_reason, ''))) = 0 then
    return core.refuse(v_action, 'invalid_content', 'Say why the work is being stopped.', 'A reason', 'You');
  end if;
  v := authz.require(v_action, t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ctx := (v ->> 'decision_context_id')::uuid;
  s_id := core.stop_job(p, p_category, p_reason, ctx, (v ->> 'actor_person_id')::uuid);
  perform core.check_live_now();
  return v || jsonb_build_object('suspension_id', s_id);
end $$;

-- An area stop: every live permit on a job touching the area or a sub-area.
create function api.stop_area(p_idempotency_key text, p_area_id uuid, p_category text, p_reason text,
                              p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare a core.area; t jsonb; r jsonb; v jsonb; ctx uuid; z_id uuid := gen_random_uuid(); q record; n integer := 0;
begin
  set constraints core.live_dependency_check deferred;
  select * into a from core.area where id = p_area_id;
  t := jsonb_build_object('customer_id', a.customer_id, 'venue_id', a.venue_id, 'record_id', z_id, 'target_type', 'area_stop',
                          'area_id', a.id, 'area_ids', jsonb_build_array(a.id), 'system_ids', '[]'::jsonb);
  r := jsonb_build_object('area_id', p_area_id, 'category', p_category, 'reason', p_reason);
  v := core.authorised_or_refusal('permit.stop_area', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if coalesce(p_category, '') not in ('unsafe_act', 'change_in_conditions', 'control_failure', 'emergency', 'weather', 'instruction', 'other')
     or length(btrim(coalesce(p_reason, ''))) = 0 then
    return core.refuse('permit.stop_area', 'invalid_content', 'Say why work in the area is being stopped.', 'A reason', 'You');
  end if;
  v := authz.require('permit.stop_area', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ctx := (v ->> 'decision_context_id')::uuid;
  insert into core.area_stop (id, customer_id, venue_id, area_id, category, reason, stopped_by_person_id, decision_context_id)
  values (z_id, a.customer_id, a.venue_id, a.id, p_category, p_reason, (v ->> 'actor_person_id')::uuid, ctx);
  for q in select distinct p.id, p.kind from core.permit p
             join core.permit_version pv on pv.id = p.current_version_id
             join core.work_package_area x on x.revision_id = pv.revision_id
             join core.area b on b.id = x.area_id
            where p.venue_id = a.venue_id and core.is_live(p.status) and a.id = any (b.path)
            order by p.kind desc, p.id loop
    perform authz.derive('permit.suspend_with_job', 'permit', q.id);
    perform core.suspend_one(q.id, 'area_stop', null, p_reason, null, z_id, (v ->> 'actor_person_id')::uuid);
    perform authz.resume(ctx);
    n := n + 1;
  end loop;
  perform core.check_live_now();
  return v || jsonb_build_object('area_stop_id', z_id, 'suspended', n);
end $$;

create function api.lift_area_stop(p_idempotency_key text, p_area_stop_id uuid, p_reason text, p_conditions text[] default '{}',
                                   p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare z core.area_stop; t jsonb; r jsonb; v jsonb;
begin
  select * into z from core.area_stop where id = p_area_stop_id;
  t := jsonb_build_object('customer_id', z.customer_id, 'venue_id', z.venue_id, 'record_id', z.id, 'target_type', 'area_stop',
                          'area_id', z.area_id, 'area_ids', jsonb_build_array(z.area_id), 'system_ids', '[]'::jsonb);
  r := jsonb_build_object('area_stop_id', p_area_stop_id, 'reason', p_reason, 'conditions', to_jsonb(p_conditions));
  v := core.authorised_or_refusal('permit.lift_area_stop', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if exists (select 1 from core.area_stop_lift where area_stop_id = z.id) then
    return core.refuse('permit.lift_area_stop', 'already_lifted', 'This area stop has already been lifted.', 'An area stop in force', 'Nobody');
  end if;
  if length(btrim(coalesce(p_reason, ''))) = 0 or exists (select 1 from unnest(coalesce(p_conditions, '{}')) c where length(btrim(c)) = 0) then
    return core.refuse('permit.lift_area_stop', 'invalid_content', 'Say why the stop can be lifted, and give each condition wording.', 'A reason', 'You');
  end if;
  v := authz.require('permit.lift_area_stop', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.area_stop_lift (customer_id, venue_id, area_stop_id, reason, conditions, lifter_person_id, decision_context_id)
  values (z.customer_id, z.venue_id, z.id, p_reason, coalesce(p_conditions, '{}'), (v ->> 'actor_person_id')::uuid, (v ->> 'decision_context_id')::uuid);
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Lifting a suspension (invariant 7): only an issuer appointment for the permit's class
-- and area, never anyone connected with the job. Lifting does not restart work.
-- ---------------------------------------------------------------------------
create function api.lift_suspension(p_idempotency_key text, p_suspension_id uuid, p_reason text, p_conditions text[] default '{}',
                                    p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s core.permit_suspension; p core.permit; t jsonb; r jsonb; v jsonb;
begin
  select * into s from core.permit_suspension where id = p_suspension_id;
  select * into p from core.permit where id = s.permit_id;
  t := core.live_target(p, core.permit_people(p.id));
  r := jsonb_build_object('suspension_id', p_suspension_id, 'reason', p_reason, 'conditions', to_jsonb(p_conditions));
  v := core.authorised_or_refusal('permit.lift_suspension', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if not core.suspension_holding(s.id) then
    return core.refuse('permit.lift_suspension', 'already_lifted', 'This suspension has already been lifted or resolved.', 'A suspension in force', 'Nobody');
  end if;
  if s.kind <> 'stop' then
    return core.refuse('permit.lift_suspension', 'not_this_route',
      case s.kind when 'job_stop' then 'This permit was stopped because work on another permit of the job was stopped. Lift that stop instead.'
                  when 'area_stop' then 'This permit was stopped by an area stop. Lifting the area stop lifts it.'
                  when 'material_change' then 'The job changed materially, so this permit must be submitted again and reissued; it cannot be lifted.'
                  else 'This suspension cannot be lifted here.' end,
      'The route for this kind of suspension', core.suspension_owner(s));
  end if;
  if length(btrim(coalesce(p_reason, ''))) = 0 or exists (select 1 from unnest(coalesce(p_conditions, '{}')) c where length(btrim(c)) = 0) then
    return core.refuse('permit.lift_suspension', 'invalid_content', 'Say why the suspension can be lifted, and give each condition wording.', 'A reason', 'You');
  end if;
  v := authz.require('permit.lift_suspension', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.permit_suspension_lift (customer_id, venue_id, suspension_id, via, reason, conditions, lifter_person_id, decision_context_id)
  values (s.customer_id, s.venue_id, s.id, 'lift', p_reason, coalesce(p_conditions, '{}'), (v ->> 'actor_person_id')::uuid,
          (v ->> 'decision_context_id')::uuid);
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Re-acceptance at the workface (P6-3): every suspension lifted, the checks re-run now,
-- the team re-briefed after the lift, new conditions acknowledged.
-- ---------------------------------------------------------------------------
create function api.reaccept_permit(p_idempotency_key text, p_permit_id uuid, p_expected_version integer,
                                    p_acknowledged_condition_ids uuid[], p_acknowledged_lift_ids uuid[],
                                    p_briefed_person_ids uuid[], p_briefed_at timestamptz)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  p core.permit; snap core.issue_snapshot; t jsonb; r jsonb; v jsonb; ctx uuid; held jsonb; blockers jsonb;
  required uuid[]; lifts uuid[]; team uuid[]; since timestamptz; decl jsonb; sup uuid;
begin
  set constraints core.live_dependency_check deferred;
  select * into p from core.permit where id = p_permit_id;
  select * into snap from core.issue_snapshot where id = p.issue_snapshot_id;
  t := core.live_target(p);
  r := jsonb_build_object('permit_id', p_permit_id, 'expected_version', p_expected_version, 'acknowledged', p_acknowledged_condition_ids,
                          'lifts', p_acknowledged_lift_ids, 'briefed', p_briefed_person_ids, 'briefed_at', p_briefed_at);
  v := core.authorised_or_refusal('permit.reaccept', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  v := core.stale('permit.reaccept', p, p_expected_version);
  if v is not null then return v; end if;
  if p.status <> 'suspended' then
    return core.refuse('permit.reaccept', 'not_suspended', 'Only a suspended permit is re-accepted.', 'A suspended permit', 'Nobody');
  end if;
  held := (select jsonb_agg(jsonb_build_object('suspension_id', s.id, 'kind', s.kind, 'reason', s.reason, 'who', core.suspension_owner(s)) order by s.created_at)
             from core.permit_suspension s where s.permit_id = p.id and core.suspension_holding(s.id));
  if held is not null then
    return core.refuse('permit.reaccept', 'still_suspended', 'This permit cannot restart: a suspension has not been lifted.',
                       'Each suspension listed lifted by its owner', 'As listed for each suspension', jsonb_build_object('suspensions', held));
  end if;
  if p.kind = 'child' and (select status from core.permit where id = p.parent_permit_id) <> 'active' then
    return core.refuse('permit.reaccept', 'parent_not_active', 'The job''s Work Approval must be re-accepted first.', 'An active Work Approval',
                       'The Work Approval''s supervisor');
  end if;
  if p.kind = 'work_approval' and exists (select 1 from core.permit c where c.parent_permit_id = p.id and core.permit_holding(c.id)) then
    return core.refuse('permit.reaccept', 'child_suspended', 'A permit on this job is still suspended, so the Work Approval cannot restart (invariant 4).',
                       'The other permit''s suspension lifted', 'The owner of that suspension');
  end if;
  blockers := core.live_blockers(p.id, tstzrange(least(now(), core.permit_window_end(p.id)), core.permit_window_end(p.id)));
  if jsonb_array_length(blockers) > 0 then
    return core.refuse('permit.reaccept', 'not_ready', 'This permit cannot restart yet.', 'Each item listed', 'As listed for each item',
                       jsonb_build_object('blockers', blockers));
  end if;
  required := array(select (k ->> 'id')::uuid from jsonb_array_elements(snap.content -> 'steps') st,
                    jsonb_array_elements(coalesce(st #> '{decision,conditions}', '[]')) k where (k ->> 'acknowledge')::boolean);
  lifts := array(select l.id from core.permit_open_lifts(p.id) l where cardinality(l.conditions) > 0);
  if not (required <@ coalesce(p_acknowledged_condition_ids, '{}')) or not (lifts <@ coalesce(p_acknowledged_lift_ids, '{}')) then
    return core.refuse('permit.reaccept', 'conditions_not_acknowledged',
                       'Acknowledge every condition marked for acceptance, and every condition set when the suspension was lifted.',
                       'Each condition acknowledged', 'You');
  end if;
  team := array(select m.person_id from core.permit_team_member m where m.permit_id = p.id and core.member_counts(m));
  since := greatest((select max(l.created_at) from core.permit_open_lifts(p.id) l),
                    (select max(s.created_at) from core.permit_suspension s where s.permit_id = p.id));
  if cardinality(coalesce(p_briefed_person_ids, '{}')) = 0 or not (p_briefed_person_ids <@ team) or p_briefed_at is null
     or p_briefed_at > clock_timestamp() or p_briefed_at < since then
    return core.refuse('permit.reaccept', 'briefing_incomplete',
      'Record the re-briefing: who from the team was briefed, and when (after the suspension was lifted, not in the future).',
      'A briefing record', 'You');
  end if;
  v := authz.require('permit.reaccept', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ctx := (v ->> 'decision_context_id')::uuid;
  sup := (v ->> 'actor_person_id')::uuid;
  decl := snap.content #> '{class_version,acceptance_declaration}';
  insert into core.permit_reacceptance (customer_id, venue_id, permit_id, issue_snapshot_id, supervisor_person_id, declaration, declaration_sha256,
                                        acknowledged_condition_ids, acknowledged_lift_ids, briefed_person_ids, briefed_at, decision_context_id)
  values (p.customer_id, p.venue_id, p.id, snap.id, sup, decl, sha256(convert_to(decl::text, 'UTF8')),
          coalesce(p_acknowledged_condition_ids, '{}'), coalesce(p_acknowledged_lift_ids, '{}'), p_briefed_person_ids, p_briefed_at, ctx);
  perform core.transition('core.permit', p.id, 'active', p_expected_version, ctx);
  perform core.check_live_now();
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- The live team (Q106, Q107, P6-6)
-- ---------------------------------------------------------------------------
create function api.add_worker(p_idempotency_key text, p_permit_id uuid, p_expected_version integer, p_person_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p core.permit; t jsonb; r jsonb; v jsonb; rule text; blockers jsonb; m_id uuid := gen_random_uuid();
begin
  select * into p from core.permit where id = p_permit_id;
  t := core.live_target(p);
  r := jsonb_build_object('permit_id', p_permit_id, 'expected_version', p_expected_version, 'person_id', p_person_id);
  v := core.authorised_or_refusal('permit.add_worker', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  v := core.stale('permit.add_worker', p, p_expected_version);
  if v is not null then return v; end if;
  if not core.is_live(p.status) then
    return core.refuse('permit.add_worker', 'not_live', 'People are added this way only after issue; before issue, change the team on the request.',
                       'An issued permit', 'The applicant');
  end if;
  rule := core.class_content(p) ->> 'worker_add';
  if rule is null then
    return core.refuse('permit.add_worker', 'not_configured',
      'This class''s configuration does not say who approves people added after issue, so nobody can be added yet.',
      'A configuration that chooses this (P6-6)', 'The venue, by approving a new configuration');
  end if;
  if exists (select 1 from core.permit_team_member m where m.permit_id = p.id and m.person_id = p_person_id and m.removed_at is null) then
    return core.refuse('permit.add_worker', 'already_on_team', 'This person is already on the team.', 'Someone not on the team', 'You');
  end if;
  blockers := core.person_blockers(p.id, p_person_id, 'operative', tstzrange(least(now(), core.permit_window_end(p.id)), core.permit_window_end(p.id)));
  if jsonb_array_length(blockers) > 0 then
    return core.refuse('permit.add_worker', 'not_ready', 'This person cannot join the team yet.', 'Each item listed', 'As listed for each item',
                       jsonb_build_object('blockers', blockers));
  end if;
  v := authz.require('permit.add_worker', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.permit_team_member (id, customer_id, venue_id, permit_id, person_id, role, added_by_person_id, added_live, approval_required)
  values (m_id, p.customer_id, p.venue_id, p.id, p_person_id, 'operative', (v ->> 'actor_person_id')::uuid, true, rule = 'issuer_approval');
  return v || jsonb_build_object('member_id', m_id, 'approval_required', rule = 'issuer_approval');
end $$;

create function api.approve_worker(p_idempotency_key text, p_member_id uuid,
                                   p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare m core.permit_team_member; p core.permit; t jsonb; r jsonb; v jsonb; blockers jsonb;
begin
  select * into m from core.permit_team_member where id = p_member_id;
  select * into p from core.permit where id = m.permit_id;
  t := core.live_target(p, core.permit_people(p.id));
  r := jsonb_build_object('member_id', p_member_id);
  v := core.authorised_or_refusal('permit.approve_worker', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if not m.approval_required or m.approved_at is not null or m.removed_at is not null or not core.is_live(p.status) then
    return core.refuse('permit.approve_worker', 'not_pending', 'This addition is not waiting for approval.', 'An addition waiting for approval', 'Nobody');
  end if;
  blockers := core.person_blockers(p.id, m.person_id, m.role, tstzrange(least(now(), core.permit_window_end(p.id)), core.permit_window_end(p.id)));
  if jsonb_array_length(blockers) > 0 then
    return core.refuse('permit.approve_worker', 'not_ready', 'This person cannot join the team yet.', 'Each item listed', 'As listed for each item',
                       jsonb_build_object('blockers', blockers));
  end if;
  v := authz.require('permit.approve_worker', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  update core.permit_team_member set approved_at = clock_timestamp(), approved_by_person_id = (v ->> 'actor_person_id')::uuid where id = m.id;
  return v;
end $$;

create function api.brief_worker(p_idempotency_key text, p_member_id uuid, p_briefed_at timestamptz)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare m core.permit_team_member; p core.permit; t jsonb; r jsonb; v jsonb; blockers jsonb;
begin
  select * into m from core.permit_team_member where id = p_member_id;
  select * into p from core.permit where id = m.permit_id;
  t := core.live_target(p);
  r := jsonb_build_object('member_id', p_member_id, 'briefed_at', p_briefed_at);
  v := core.authorised_or_refusal('permit.brief_worker', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if not m.added_live or m.briefed_at is not null or m.removed_at is not null or not core.is_live(p.status) then
    return core.refuse('permit.brief_worker', 'not_pending', 'This person is not waiting to be briefed.', 'Someone added and not yet briefed', 'Nobody');
  end if;
  if m.approval_required and m.approved_at is null then
    return core.refuse('permit.brief_worker', 'not_approved', 'This addition has not been approved yet.', 'Approval of the addition', 'The permit issuer');
  end if;
  if p_briefed_at is null or p_briefed_at > clock_timestamp() or p_briefed_at < m.created_at then
    return core.refuse('permit.brief_worker', 'briefing_incomplete', 'Record when the briefing happened: after they were added, not in the future.',
                       'A briefing time', 'You');
  end if;
  blockers := core.person_blockers(p.id, m.person_id, m.role, tstzrange(least(now(), core.permit_window_end(p.id)), core.permit_window_end(p.id)));
  if jsonb_array_length(blockers) > 0 then
    return core.refuse('permit.brief_worker', 'not_ready', 'This person cannot join the team yet.', 'Each item listed', 'As listed for each item',
                       jsonb_build_object('blockers', blockers));
  end if;
  v := authz.require('permit.brief_worker', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  update core.permit_team_member set briefed_at = p_briefed_at, briefed_by_person_id = (v ->> 'actor_person_id')::uuid where id = m.id;
  return v;
end $$;

-- Excluding someone (Q107) does not suspend the permit; the supervisor changes only
-- through api.change_supervisor.
create function api.exclude_worker(p_idempotency_key text, p_member_id uuid, p_reason text,
                                   p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare m core.permit_team_member; p core.permit; v_action text; t jsonb; r jsonb; v jsonb;
begin
  select * into m from core.permit_team_member where id = p_member_id;
  select * into p from core.permit where id = m.permit_id;
  v_action := case when exists (select 1 from core.permit_team_member s where s.permit_id = p.id and s.role = 'supervisor' and s.removed_at is null
                                   and s.person_id = authz.actor_person(p.customer_id))
                   then 'permit.exclude_worker' else 'permit.exclude_worker_as_authority' end;
  t := core.live_target(p);
  r := jsonb_build_object('member_id', p_member_id, 'reason', p_reason);
  v := core.authorised_or_refusal(v_action, t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if m.removed_at is not null or not core.is_live(p.status) then
    return core.refuse(v_action, 'not_on_team', 'This person is not on the live team.', 'A live team member', 'Nobody');
  end if;
  if m.role = 'supervisor' then
    return core.refuse(v_action, 'is_supervisor', 'The supervisor cannot be removed this way: an issuer changes the supervisor.',
                       'A supervisor change', 'The permit issuer');
  end if;
  if length(btrim(coalesce(p_reason, ''))) = 0 then
    return core.refuse(v_action, 'invalid_content', 'Say why this person is being removed.', 'A reason', 'You');
  end if;
  v := authz.require(v_action, t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  update core.permit_team_member set removed_at = clock_timestamp(), removed_by_person_id = (v ->> 'actor_person_id')::uuid, removal_reason = p_reason
   where id = m.id;
  return v;
end $$;

-- A supervisor change (P6-6): an issuer's decision; the permit is suspended until the new
-- supervisor re-accepts, so there is never a live permit without an accepted supervisor.
create function api.change_supervisor(p_idempotency_key text, p_permit_id uuid, p_expected_version integer, p_person_id uuid,
                                      p_keep_previous_as_operative boolean, p_reason text,
                                      p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p core.permit; old_sup core.permit_team_member; t jsonb; r jsonb; v jsonb; ctx uuid; blockers jsonb; s_id uuid; actor uuid;
begin
  set constraints core.live_dependency_check deferred;
  select * into p from core.permit where id = p_permit_id;
  select * into old_sup from core.permit_team_member where permit_id = p.id and role = 'supervisor' and removed_at is null;
  t := core.live_target(p, core.permit_people(p.id));
  r := jsonb_build_object('permit_id', p_permit_id, 'expected_version', p_expected_version, 'person_id', p_person_id,
                          'keep', p_keep_previous_as_operative, 'reason', p_reason);
  v := core.authorised_or_refusal('permit.change_supervisor', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  v := core.stale('permit.change_supervisor', p, p_expected_version);
  if v is not null then return v; end if;
  if not core.is_live(p.status) then
    return core.refuse('permit.change_supervisor', 'not_live', 'The supervisor changes this way only after issue; before issue, change the team on the request.',
                       'An issued permit', 'The applicant');
  end if;
  if p_person_id is not distinct from old_sup.person_id then
    return core.refuse('permit.change_supervisor', 'no_change', 'This person is already the supervisor.', 'A different person', 'You');
  end if;
  if length(btrim(coalesce(p_reason, ''))) = 0 then
    return core.refuse('permit.change_supervisor', 'invalid_content', 'Say why the supervisor is changing.', 'A reason', 'You');
  end if;
  blockers := core.person_blockers(p.id, p_person_id, 'supervisor', tstzrange(least(now(), core.permit_window_end(p.id)), core.permit_window_end(p.id)));
  if jsonb_array_length(blockers) > 0 then
    return core.refuse('permit.change_supervisor', 'not_ready', 'This person cannot supervise this permit.', 'Each item listed', 'As listed for each item',
                       jsonb_build_object('blockers', blockers));
  end if;
  v := authz.require('permit.change_supervisor', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ctx := (v ->> 'decision_context_id')::uuid;
  actor := (v ->> 'actor_person_id')::uuid;
  update core.permit_team_member set removed_at = clock_timestamp(), removed_by_person_id = actor,
                                     removal_reason = 'Supervisor changed: ' || p_reason
   where permit_id = p.id and removed_at is null and (id = old_sup.id or person_id = p_person_id);
  insert into core.permit_team_member (customer_id, venue_id, permit_id, person_id, role, added_by_person_id)
  values (p.customer_id, p.venue_id, p.id, p_person_id, 'supervisor', actor);
  if p_keep_previous_as_operative and old_sup.id is not null then
    insert into core.permit_team_member (customer_id, venue_id, permit_id, person_id, role, added_by_person_id)
    values (p.customer_id, p.venue_id, p.id, old_sup.person_id, 'operative', actor);
  end if;
  s_id := core.suspend_one(p.id, 'supervisor_change', null, 'Supervisor changed: ' || p_reason, null, null, actor);
  insert into core.permit_suspension_lift (customer_id, venue_id, suspension_id, via, reason, lifter_person_id, decision_context_id)
  values (p.customer_id, p.venue_id, s_id, 'supervisor_change', 'The new supervisor re-accepts', actor, ctx);
  perform core.check_live_now();
  return v || jsonb_build_object('suspension_id', s_id);
end $$;

-- ---------------------------------------------------------------------------
-- Extension (Q108, P6-5)
-- ---------------------------------------------------------------------------
create function api.extend_permit(p_idempotency_key text, p_permit_id uuid, p_expected_version integer, p_new_end timestamptz, p_reason text,
                                  p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  p core.permit; pv core.permit_version; cfg jsonb; cur_end timestamptz; job_end timestamptz; t jsonb; r jsonb; v jsonb; b jsonb;
  used integer; earliest timestamptz; content jsonb; e_id uuid := gen_random_uuid(); areas uuid[]; types uuid[];
begin
  select * into p from core.permit where id = p_permit_id;
  select * into pv from core.permit_version where id = p.current_version_id;
  t := core.live_target(p, core.permit_people(p.id));
  r := jsonb_build_object('permit_id', p_permit_id, 'expected_version', p_expected_version, 'new_end', p_new_end, 'reason', p_reason);
  v := core.authorised_or_refusal('permit.extend', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  v := core.stale('permit.extend', p, p_expected_version);
  if v is not null then return v; end if;
  cur_end := core.permit_window_end(p.id);
  if p.status not in ('active', 'suspended') or now() >= cur_end then
    return core.refuse('permit.extend', 'not_live', 'Only a live permit whose window has not ended can be extended (time passing never creates approval).',
                       'A live permit before the end of its window', 'Nobody: a new permit is needed');
  end if;
  if exists (select 1 from core.permit_suspension s where s.permit_id = p.id and s.kind in ('material_change', 'parent_ended') and core.suspension_holding(s.id)) then
    return core.refuse('permit.extend', 'reissue_pending', 'This permit must be submitted again and reissued, so it cannot be extended.',
                       'A reissued permit', 'The applicant');
  end if;
  cfg := core.class_content(p) -> 'extension';
  if cfg is null then
    return core.refuse('permit.extend', 'not_configured', 'This class''s configuration does not set extension limits, so it cannot be extended.',
                       'A configuration that sets them (P6-5)', 'The venue, by approving a new configuration');
  end if;
  if exists (select 1 from core.permit_extension e where e.issue_snapshot_id = p.issue_snapshot_id and e.acknowledged_at is null) then
    return core.refuse('permit.extend', 'extension_pending', 'An extension is waiting for the supervisor to acknowledge it.', 'The pending extension acknowledged',
                       'The permit''s supervisor');
  end if;
  used := (select count(*) from core.permit_extension e where e.issue_snapshot_id = p.issue_snapshot_id);
  job_end := (select upper(rv.planned_window) from core.work_package_revision rv join core.work_package w on w.current_revision_id = rv.id
               where w.id = p.work_package_id);
  b := '[]';
  if p_new_end is null or p_new_end <= cur_end then
    b := b || jsonb_build_object('check', 'window', 'problem', 'The new end must be later than the current end.', 'who', 'You');
  end if;
  if p_new_end > job_end then
    b := b || jsonb_build_object('check', 'window', 'problem', 'A permit cannot run beyond its job''s planned dates; change the job first.', 'who', 'The applicant');
  end if;
  if p.kind = 'child' and p_new_end > core.permit_window_end(p.parent_permit_id) then
    b := b || jsonb_build_object('check', 'parent', 'problem', 'A permit cannot run beyond its Work Approval; extend the Work Approval first.', 'who', 'The permit issuer');
  end if;
  if used >= (cfg ->> 'max_count')::integer then
    b := b || jsonb_build_object('check', 'limit', 'problem', format('This class allows %s extension(s), and they have been used.', cfg ->> 'max_count'),
                                 'who', 'Nobody: a new permit is needed');
  end if;
  if p_new_end is not null and extract(epoch from (p_new_end - upper(pv.planned_window))) / 3600 > (cfg ->> 'max_total_hours')::numeric then
    b := b || jsonb_build_object('check', 'limit', 'problem', format('This class allows %s hours of extension in total.', cfg ->> 'max_total_hours'),
                                 'who', 'Nobody: a new permit is needed');
  end if;
  if length(btrim(coalesce(p_reason, ''))) = 0 then
    b := b || jsonb_build_object('check', 'reason', 'problem', 'Say why the permit is being extended.', 'who', 'You');
  end if;
  if jsonb_array_length(b) = 0 then
    -- Notice for the extended time, measured from now, with no exception route (P6-5).
    areas := array(select area_id from core.work_package_area where revision_id = pv.revision_id);
    types := array(select y.system_type_id from core.work_package_system s join core.system y on y.id = s.system_id where s.revision_id = pv.revision_id);
    if core.calendar_at(p.venue_id, now()) is null then
      b := b || jsonb_build_object('check', 'notice', 'problem', 'The venue has no working calendar for today, so notice cannot be measured.', 'who', 'The venue');
    else
      earliest := core.notice_earliest(p.venue_id, core.class_content(p) -> 'notice', now(), areas, types, tstzrange(cur_end, p_new_end));
      if earliest > cur_end then
        b := b || jsonb_build_object('check', 'notice', 'problem',
          format('An extension needs the class''s notice before the extra time starts (earliest %s); extensions have no late-notice exception.',
                 to_char(earliest at time zone (select timezone from core.venue where id = p.venue_id), 'DD/MM/YYYY HH24:MI')),
          'who', 'Nobody: plan the extension earlier, or hand the work back');
      end if;
    end if;
    b := b || core.live_blockers(p.id, tstzrange(cur_end, p_new_end));
  end if;
  if jsonb_array_length(b) > 0 then
    return core.refuse('permit.extend', 'not_ready', 'This permit cannot be extended as asked.', 'Each item listed', 'As listed for each item',
                       jsonb_build_object('blockers', b));
  end if;
  v := authz.require('permit.extend', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  content := jsonb_build_object('permit_id', p.id, 'issue_snapshot_id', p.issue_snapshot_id, 'class_version_id', pv.class_version_id,
                                'previous_end', cur_end, 'new_end', p_new_end, 'reason', p_reason, 'extension_no', used + 1,
                                'limits', cfg, 'checks', jsonb_build_array('window', 'parent', 'limit', 'notice', 'organisation', 'evidence', 'team',
                                                                           'induction', 'competency', 'restriction'),
                                'extender', jsonb_build_object('person_id', v ->> 'actor_person_id', 'appointment_id', v -> 'acting_appointment_id',
                                                               'delegation_id', v -> 'acting_delegation_id'),
                                'extended_at', clock_timestamp());
  insert into core.permit_extension (id, customer_id, venue_id, permit_id, issue_snapshot_id, previous_end, new_end, reason, content, content_sha256,
                                     extender_person_id, decision_context_id)
  values (e_id, p.customer_id, p.venue_id, p.id, p.issue_snapshot_id, cur_end, p_new_end, p_reason, content,
          sha256(convert_to(content::text, 'UTF8')), (v ->> 'actor_person_id')::uuid, (v ->> 'decision_context_id')::uuid);
  return v || jsonb_build_object('extension_id', e_id);
end $$;

-- The extended time counts only once the supervisor has acknowledged it, before the
-- current window ends.
create function api.acknowledge_extension(p_idempotency_key text, p_extension_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e core.permit_extension; p core.permit; t jsonb; r jsonb; v jsonb;
begin
  select * into e from core.permit_extension where id = p_extension_id;
  select * into p from core.permit where id = e.permit_id;
  t := core.live_target(p);
  r := jsonb_build_object('extension_id', p_extension_id);
  v := core.authorised_or_refusal('permit.acknowledge_extension', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if e.acknowledged_at is not null or e.issue_snapshot_id is distinct from p.issue_snapshot_id or p.status not in ('active', 'suspended') then
    return core.refuse('permit.acknowledge_extension', 'not_pending', 'This extension is not waiting for acknowledgement.', 'A pending extension', 'Nobody');
  end if;
  if now() >= e.previous_end then
    return core.refuse('permit.acknowledge_extension', 'window_ended', 'The permit''s window ended before the extension was acknowledged.',
                       'A new permit', 'The applicant');
  end if;
  v := authz.require('permit.acknowledge_extension', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  update core.permit_extension set acknowledged_at = clock_timestamp(), acknowledged_by_person_id = (v ->> 'actor_person_id')::uuid,
                                   ack_decision_context_id = (v ->> 'decision_context_id')::uuid
   where id = e.id;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Revalidation (Q112, P6-7)
-- ---------------------------------------------------------------------------
create function api.revalidate_permit(p_idempotency_key text, p_permit_id uuid, p_expected_version integer, p_conditions_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p core.permit; t jsonb; r jsonb; v jsonb;
  stmt constant text := 'The work, its conditions and its controls are as accepted, and the team is as recorded.';
begin
  select * into p from core.permit where id = p_permit_id;
  t := core.live_target(p);
  r := jsonb_build_object('permit_id', p_permit_id, 'expected_version', p_expected_version, 'note', p_conditions_note);
  v := core.authorised_or_refusal('permit.revalidate', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  v := core.stale('permit.revalidate', p, p_expected_version);
  if v is not null then return v; end if;
  if p.status <> 'active' then
    return core.refuse('permit.revalidate', 'not_active', 'Only an active permit is revalidated. If something has changed, stop the work instead.',
                       'An active permit', 'Nobody');
  end if;
  if not coalesce((core.revalidation_status(p.id) ->> 'required')::boolean, false) then
    return core.refuse('permit.revalidate', 'not_required', 'This class does not use periodic revalidation.', 'A class that requires it', 'Nobody');
  end if;
  v := authz.require('permit.revalidate', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.permit_revalidation (customer_id, venue_id, permit_id, issue_snapshot_id, supervisor_person_id, statement, conditions_note, decision_context_id)
  values (p.customer_id, p.venue_id, p.id, p.issue_snapshot_id, (v ->> 'actor_person_id')::uuid, stmt, nullif(btrim(coalesce(p_conditions_note, '')), ''),
          (v ->> 'decision_context_id')::uuid);
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Material change (invariant 6, P6-4): live permits are suspended for reissue; permits
-- not yet issued go back to draft as before.
-- ---------------------------------------------------------------------------
create or replace function api.revise_work_package(p_idempotency_key text, p_work_package_id uuid, p_expected_version integer,
                                        p_input jsonb, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  wp core.work_package; v_action text; v_kind text; t jsonb; r jsonb; v jsonb; ctx uuid; rev uuid;
  problems text[]; x record;
begin
  set constraints core.live_dependency_check deferred;
  select * into wp from core.work_package where id = p_work_package_id;
  v_action := core.wp_action('work_package.revise', p_work_package_id, wp.customer_id);
  t := core.wp_target(wp, p_work_package_id, 'work_package', coalesce(core.wp_actor_org(p_work_package_id), wp.performing_organisation_id));
  r := jsonb_build_object('work_package_id', p_work_package_id, 'expected_version', p_expected_version,
                          'input', p_input, 'reason', p_reason);
  v := core.authorised_or_refusal(v_action, t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if wp.status = 'cancelled' then
    return core.refuse(v_action, 'not_ready', 'This job has been cancelled.', 'A job that is not cancelled', 'Nobody: start a new job');
  end if;
  problems := core.revision_problems(wp.venue_id, wp.performing_organisation_id, p_input);
  if length(btrim(coalesce(p_reason, ''))) = 0 then problems := problems || text 'Say why the job is changing.'; end if;
  if cardinality(problems) > 0 then
    return core.refuse(v_action, 'invalid_content', 'The change has problems.', 'Each item listed', 'You',
                       jsonb_build_object('problems', to_jsonb(problems)));
  end if;
  v_kind := core.change_kind(core.revision_facts(wp.current_revision_id), core.input_facts(wp.performing_organisation_id, p_input));
  if v_kind is null then
    return core.refuse(v_action, 'no_change', 'Nothing in the job has changed.', 'A change', 'You');
  end if;
  v := authz.require(v_action, t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ctx := (v ->> 'decision_context_id')::uuid;
  if wp.row_version <> p_expected_version then
    raise exception 'this job changed since you opened it' using errcode = 'PT409';
  end if;
  rev := core.insert_revision(wp, (select max(revision_no) + 1 from core.work_package_revision where work_package_id = wp.id),
                              v_kind, p_reason, p_input, (v ->> 'actor_person_id')::uuid, ctx);

  if v_kind = 'material' then
    -- Live permits are suspended: the authorisation they were issued on no longer applies.
    for x in select id from core.permit where work_package_id = wp.id and core.is_live(status) order by kind desc, id loop
      if not exists (select 1 from core.permit_suspension s where s.permit_id = x.id and s.kind = 'material_change' and core.suspension_holding(s.id)) then
        perform authz.derive('permit.suspend_for_change', 'permit', x.id);
        perform core.suspend_one(x.id, 'material_change', null, 'The job changed: ' || p_reason, null, null, (v ->> 'actor_person_id')::uuid);
        perform authz.resume(ctx);
      end if;
    end loop;
  end if;
  if v_kind = 'material' and wp.status in ('screening', 'routed') then
    for x in select id, 'core.screening_recommendation' tbl, row_version from core.screening_recommendation
              where work_package_id = wp.id and status <> 'superseded'
             union all
             select id, 'core.external_reference_hold', row_version from core.external_reference_hold
              where work_package_id = wp.id and status <> 'superseded' loop
      perform authz.derive('screening.supersede', 'screening_outcome', x.id);
      perform core.transition(x.tbl::regclass, x.id, 'superseded', x.row_version, core.ctx_uuid('decision_context_id'));
      perform authz.resume(ctx);
    end loop;
    -- Permits not yet issued go back to draft; their next version needs the full route (invariant 6).
    for x in select id, 'core.permit' tbl, row_version from core.permit
              where work_package_id = wp.id and status in ('submitted', 'under_review', 'more_information_required', 'approved_for_issue', 'refused') loop
      perform authz.derive('permit.return_to_draft', 'permit', x.id);
      perform core.transition('core.permit', x.id, 'draft', x.row_version, core.ctx_uuid('decision_context_id'));
      perform authz.resume(ctx);
    end loop;
    perform authz.derive('work_package.reopen', 'work_package', wp.id);
    perform core.transition('core.work_package', wp.id, 'draft', wp.row_version, core.ctx_uuid('decision_context_id'),
                            jsonb_build_object('current_revision_id', rev, 'screened_revision_id', null));
    perform authz.resume(ctx);
  else
    update core.work_package set current_revision_id = rev where id = wp.id;
  end if;
  perform core.check_live_now();
  return v || jsonb_build_object('revision_id', rev, 'change_kind', v_kind);
end $$;

-- Reissue (P6-4): a permit suspended only by a material change is prepared and submitted
-- again like a draft; submitting it resolves the material-change suspension.
do $m$
declare d text;
begin
  d := pg_get_functiondef('api.save_permit_draft(text,uuid,jsonb,timestamptz,timestamptz,uuid[])'::regprocedure);
  if position('  if p.status not in (''draft'', ''more_information_required'') then' in d) = 0 then
    raise exception 'api.save_permit_draft no longer has the expected structure';
  end if;
  execute replace(d, '  if p.status not in (''draft'', ''more_information_required'') then',
                     '  if p.status not in (''draft'', ''more_information_required'') and not core.reissue_pending(p.id) then');

  d := pg_get_functiondef('api.submit_permit(text,uuid,integer)'::regprocedure);
  if position('  if p.status <> ''draft'' then' in d) = 0 then
    raise exception 'api.submit_permit no longer has the expected structure';
  end if;
  execute replace(d, '  if p.status <> ''draft'' then', $r$  if p.status = 'suspended' and not core.reissue_pending(p.id) then
    return core.refuse(v_action, 'suspended',
      'This permit is suspended. It can be submitted again only when a material change to the job is all that holds it; any other stop must be lifted first.',
      'Every other suspension lifted', 'The owner of each suspension');
  end if;
  if p.status <> 'draft' and not core.reissue_pending(p.id) then$r$);

  -- After issue, the team changes on the live permit.
  d := pg_get_functiondef('api.set_permit_team(text,uuid,jsonb)'::regprocedure);
  if position('Changes after issue are not yet available.' in d) = 0 then
    raise exception 'api.set_permit_team no longer has the expected structure';
  end if;
  execute replace(d, 'Changes after issue are not yet available.', 'After issue, the supervisor adds or removes people on the live permit.');

  -- A reissue's snapshot records the snapshot it replaces.
  d := pg_get_functiondef('api.issue_permit(text,uuid,integer,uuid,uuid)'::regprocedure);
  if position('    ''issued_at'', clock_timestamp());' in d) = 0 then
    raise exception 'api.issue_permit no longer has the expected structure';
  end if;
  execute replace(d, '    ''issued_at'', clock_timestamp());', '    ''issued_at'', clock_timestamp(), ''previous_snapshot_id'', p.issue_snapshot_id);');

  -- Acceptance briefs the team as it stands now (additions count once briefed).
  d := pg_get_functiondef('api.accept_permit(text,uuid,integer,uuid[],uuid[],timestamptz)'::regprocedure);
  if position('  team := array(select (x ->> ''person_id'')::uuid from jsonb_array_elements(s.content -> ''team'') x);' in d) = 0 then
    raise exception 'api.accept_permit no longer has the expected structure';
  end if;
  execute replace(d, '  team := array(select (x ->> ''person_id'')::uuid from jsonb_array_elements(s.content -> ''team'') x);',
                     '  team := array(select m.person_id from core.permit_team_member m where m.permit_id = p.id and core.member_counts(m));');
end $m$;

-- ---------------------------------------------------------------------------
-- Expiry (invariant 10), now with extensions and suspended permits. When a Work Approval
-- ends, its active permits are suspended: they cannot continue without it.
-- ---------------------------------------------------------------------------
create or replace function api.expire_permits() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare x record; q core.permit; c record; v jsonb; n integer := 0;
begin
  set constraints core.live_dependency_check deferred;
  -- Only the expiry service, whether or not anything is due.
  v := authz.evaluate('permit.expire', jsonb_build_object('record_id', gen_random_uuid(), 'target_type', 'permit'));
  if not (v ->> 'allowed')::boolean then return v; end if;
  for x in select p.id from core.permit p
            where p.status in ('approved_for_issue', 'issued_awaiting_acceptance', 'active', 'suspended') and core.permit_window_end(p.id) <= now()
            order by p.kind desc, p.id loop
    select * into q from core.permit where id = x.id for update;
    continue when q.status not in ('approved_for_issue', 'issued_awaiting_acceptance', 'active', 'suspended');
    v := authz.require('permit.expire',
           jsonb_build_object('customer_id', q.customer_id, 'venue_id', q.venue_id, 'record_id', q.id, 'target_type', 'permit'),
           'expire:' || q.id || ':' || q.status, jsonb_build_object('permit_id', q.id, 'from', q.status));
    if not (v ->> 'ok')::boolean then return v; end if;
    if not (v ->> 'replayed')::boolean then
      perform core.transition('core.permit', q.id, 'expired', q.row_version, (v ->> 'decision_context_id')::uuid);
      n := n + 1;
      for c in select id from core.permit where parent_permit_id = q.id and status = 'active' loop
        perform authz.derive('permit.suspend_with_job', 'permit', c.id);
        perform core.suspend_one(c.id, 'parent_ended', null, 'The Work Approval''s window ended', null, null, null);
        perform authz.resume((v ->> 'decision_context_id')::uuid);
      end loop;
    end if;
  end loop;
  perform core.check_live_now();
  return jsonb_build_object('ok', true, 'expired', n);
end $$;

-- ---------------------------------------------------------------------------
-- Reads: the live state of a permit, added to api.permit_detail.
-- ---------------------------------------------------------------------------
create function core.permit_live(p_permit_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'window_end', core.permit_window_end(p.id),
    'held', core.permit_holding(p.id),
    'reissue_pending', coalesce(core.reissue_pending(p.id), false),
    'last_accepted_at', core.last_accepted_at(p.id),
    'suspensions', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', s.id, 'kind', s.kind, 'category', s.category, 'reason', s.reason, 'by', core.person_name(s.stopped_by_person_id), 'at', s.created_at,
        'holding', core.suspension_holding(s.id), 'who_lifts', core.suspension_owner(s),
        'lift', coalesce(
          (select jsonb_build_object('id', l.id, 'via', l.via, 'reason', l.reason, 'conditions', to_jsonb(l.conditions),
                                     'by', core.person_name(l.lifter_person_id), 'at', l.created_at)
             from core.permit_suspension_lift l where l.suspension_id = coalesce(s.origin_suspension_id, s.id)),
          (select jsonb_build_object('id', l.id, 'via', 'area', 'reason', l.reason, 'conditions', to_jsonb(l.conditions),
                                     'by', core.person_name(l.lifter_person_id), 'at', l.created_at)
             from core.area_stop_lift l where l.area_stop_id = s.area_stop_id)))
        order by s.created_at desc), '[]')
      from core.permit_suspension s where s.permit_id = p.id),
    'open_lifts', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'conditions', to_jsonb(l.conditions), 'at', l.created_at)
                                             order by l.created_at), '[]') from core.permit_open_lifts(p.id) l),
    'team_live', (select coalesce(jsonb_agg(jsonb_build_object(
        'member_id', m.id, 'person_id', m.person_id, 'name', core.person_name(m.person_id), 'role', m.role,
        'added_live', m.added_live, 'approval_required', m.approval_required, 'approved_at', m.approved_at,
        'briefed_at', m.briefed_at, 'counts', core.member_counts(m), 'added_at', m.created_at,
        'removed_at', m.removed_at, 'removal_reason', m.removal_reason, 'removed_by', core.person_name(m.removed_by_person_id))
        order by m.removed_at nulls first, m.role desc, m.created_at), '[]')
      from core.permit_team_member m where m.permit_id = p.id and p.issue_snapshot_id is not null),
    'extensions', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', e.id, 'previous_end', e.previous_end, 'new_end', e.new_end, 'reason', e.reason, 'by', core.person_name(e.extender_person_id),
        'at', e.created_at, 'acknowledged_at', e.acknowledged_at, 'sha256', encode(e.content_sha256, 'hex')) order by e.created_at), '[]')
      from core.permit_extension e where e.permit_id = p.id and e.issue_snapshot_id = p.issue_snapshot_id),
    'extension_rule', core.class_content(p) -> 'extension',
    'worker_add_rule', core.class_content(p) ->> 'worker_add',
    'revalidation', core.revalidation_status(p.id),
    'reacceptances', (select coalesce(jsonb_agg(jsonb_build_object('at', r.accepted_at, 'by', core.person_name(r.supervisor_person_id),
                                                                   'briefed', (select jsonb_agg(core.person_name(x)) from unnest(r.briefed_person_ids) x))
                                                order by r.accepted_at), '[]')
      from core.permit_reacceptance r where r.permit_id = p.id))
  from core.permit p where p.id = p_permit_id $$;

do $m$
declare d text;
begin
  d := pg_get_functiondef('api.permit_detail(uuid)'::regprocedure);
  if position('where a.issue_snapshot_id = p.issue_snapshot_id));' in d) = 0 then
    raise exception 'api.permit_detail no longer has the expected structure';
  end if;
  execute replace(d, 'where a.issue_snapshot_id = p.issue_snapshot_id));',
                     'where a.issue_snapshot_id = p.issue_snapshot_id)) || core.permit_live(p.id);');
end $m$;

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------
create or replace view api.permit_team_member with (security_invoker = true) as select * from core.permit_team_member;
create view api.area_stop              with (security_invoker = true) as select * from core.area_stop;
create view api.area_stop_lift         with (security_invoker = true) as select * from core.area_stop_lift;
create view api.permit_suspension      with (security_invoker = true) as select * from core.permit_suspension;
create view api.permit_suspension_lift with (security_invoker = true) as select * from core.permit_suspension_lift;
create view api.permit_reacceptance    with (security_invoker = true) as
  select id, customer_id, venue_id, permit_id, issue_snapshot_id, supervisor_person_id, declaration, acknowledged_condition_ids,
         acknowledged_lift_ids, briefed_person_ids, briefed_at, accepted_at
    from core.permit_reacceptance;
create view api.permit_extension       with (security_invoker = true) as
  select id, customer_id, venue_id, permit_id, issue_snapshot_id, previous_end, new_end, reason, content,
         encode(content_sha256, 'hex') as content_sha256, extender_person_id, acknowledged_at, acknowledged_by_person_id, created_at
    from core.permit_extension;
create view api.permit_revalidation    with (security_invoker = true) as select * from core.permit_revalidation;

grant select on all tables in schema api to authenticated;
grant execute on all functions in schema api to authenticated;
revoke execute on all functions in schema api from anon, public;
