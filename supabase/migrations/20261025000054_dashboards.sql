-- 0054 Dashboards (phase 8b, D-021, Q204, Q205, Q208, P8-7)
--
-- Two reads, no new tables or actions. Each returns lists of actions with what is needed, who
-- owns it and when it is due: never a count, a percentage or a traffic light (CLAUDE.md §6,
-- D-005). Every item is built from the same functions the decisions themselves use (issue,
-- team, organisation and hand-back blockers, open steps, suspensions), so a dashboard can never
-- say something the decision would not.
--
--   api.venue_dashboard(venue): for the venue's side (its tenant administrators and anyone
--     holding an appointment there), five groups (Q204):
--       work      today's and tomorrow's work (venue time), and visits, which are entry only;
--       due       decisions due and missing prerequisites before a start time, with owners;
--       stopped   stopped work, area stops, control failures, impairments and fire watches;
--       closing   hand-backs due, continuing controls with their owner, outage exceptions,
--                 emergency work without its retrospective permit;
--       affecting restrictions and expiries that affect today's or tomorrow's work or visits
--                 (Q208), evaluated against that work: the fact, never the grounds.
--   api.organisation_dashboard(organisation): for the organisation's administrators, five
--     groups (Q205): jobs and visits due next (with what an approved permit still needs before issue); requests returned with exactly what was asked;
--     workers needing something for planned work; venue decisions outstanding; live permits.
--     The occupier and the venue's appointees are never named to the organisation (P5-6).
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only (drop the functions).

-- The venue's side: its tenant administrators and anyone holding an appointment at it.
create function authz.venue_side(p_venue_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_venue_id in (select authz.my_appointee_venue_ids())
      or exists (select 1 from core.venue v where v.id = p_venue_id and v.customer_id in (select authz.my_admin_customer_ids())) $$;

-- Today and the following days, in the venue's time.
create function core.venue_days(p_venue_id uuid, p_days integer) returns tstzrange
language sql stable security definer set search_path = '' as $$
  select tstzrange(date_trunc('day', now() at time zone v.timezone) at time zone v.timezone,
                   (date_trunc('day', now() at time zone v.timezone) + make_interval(days => p_days)) at time zone v.timezone)
    from core.venue v where v.id = p_venue_id $$;

-- Names of the people who own an item. Nobody is a finding in itself: it is shown as such.
create function core.owner_names(p_people uuid[]) returns text
language sql stable security definer set search_path = '' as $$
  select coalesce((select string_agg(n, ', ' order by n) from (select distinct core.person_name(x) n from unnest(p_people) x where x is not null) s),
                  'Nobody currently holds an appointment for this') $$;

create function core.dash_item(p_kind text, p_title text, p_what text, p_who text, p_at timestamptz, p_at_label text,
                               p_link text, p_overdue boolean default false) returns jsonb
language sql immutable set search_path = '' as $$
  select jsonb_build_object('kind', p_kind, 'title', p_title, 'what', p_what, 'who', p_who, 'at', p_at, 'at_label', p_at_label,
                            'link', p_link, 'overdue', coalesce(p_overdue, false)) $$;

create function core.permit_start(p_permit_id uuid) returns timestamptz
language sql stable security definer set search_path = '' as $$
  select lower(v.planned_window) from core.permit p join core.permit_version v on v.id = p.current_version_id where p.id = p_permit_id $$;

-- Permits whose planned time (with any acknowledged extension) falls in a range.
create function core.permits_during(p_venue_id uuid, p_range tstzrange, p_statuses text[]) returns setof core.permit
language sql stable security definer set search_path = '' as $$
  select p.* from core.permit p join core.permit_version v on v.id = p.current_version_id
   where p.venue_id = p_venue_id and p.status = any (p_statuses)
     and tstzrange(lower(v.planned_window), greatest(lower(v.planned_window), core.permit_window_end(p.id))) && p_range $$;

-- ---------------------------------------------------------------------------
-- Venue dashboard (Q204)
-- ---------------------------------------------------------------------------
create function api.venue_dashboard(p_venue_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  vn core.venue; horizon tstzrange; tz text;
  work jsonb; visits jsonb; due jsonb := '[]'; stopped jsonb := '[]'; closing jsonb := '[]'; affecting jsonb := '[]';
  x record; pr core.permit; ac core.access_authorisation; b jsonb; k jsonb; live text[] := array['approved_for_issue', 'issued_awaiting_acceptance', 'active', 'suspended'];
begin
  select * into vn from core.venue where id = p_venue_id;
  if vn.id is null or not authz.venue_side(p_venue_id) then
    return core.refuse('dashboard.venue', 'not_visible', 'This dashboard is for the venue''s administrators and appointees.',
                       'An appointment at this venue, or tenant administration', 'The venue''s administrator');
  end if;
  tz := vn.timezone;
  horizon := core.venue_days(p_venue_id, 2);

  -- 1. Today's and tomorrow's work, by location and event phase.
  work := (select coalesce(jsonb_agg(core.permit_summary(p) || jsonb_build_object(
                     'starts_at', core.permit_start(p.id),
                     'event', (select e.name from core.event e where e.id = w.event_id),
                     'phase', (select ph.phase from core.event_phase ph where ph.id = w.event_phase_id))
                   order by core.permit_start(p.id), p.kind desc), '[]')
             from core.permits_during(p_venue_id, horizon, live) p join core.work_package w on w.id = p.work_package_id);
  visits := (select coalesce(jsonb_agg(jsonb_build_object(
                     'id', a.id, 'reference', a.reference, 'status', a.status,
                     'organisation', (select legal_name from core.organisation where id = a.organisation_id),
                     'purpose', core.visit_purpose(a) ->> 'name',
                     'areas', (select coalesce(jsonb_agg(ar.name order by ar.name), '[]') from core.area ar where ar.id = any (a.area_ids)),
                     'from', lower(a.valid_during), 'to', upper(a.valid_during),
                     'roster', (select count(*) from core.access_roster_member m where m.authorisation_id = a.id and m.removed_at is null))
                   order by lower(a.valid_during)), '[]')
               from core.access_authorisation a
              where a.venue_id = p_venue_id and a.status in ('requested', 'approved') and a.valid_during && horizon);

  -- 2. Decisions due and missing prerequisites, soonest start first.
  for x in select s.id as step_id, s.name, p.*, v.created_at as submitted_at
             from core.permit p join core.permit_version v on v.id = p.current_version_id join core.permit_step s on s.permit_version_id = v.id
            where p.venue_id = p_venue_id and p.status in ('submitted', 'under_review') and core.step_open(s.id) loop
    due := due || core.dash_item('decision', core.permit_label(x.id), format('Decide: %s (submitted %s)', x.name, core.venue_time(p_venue_id, x.submitted_at)),
             core.owner_names(core.action_holders(core.step_action((select kind from core.permit_step where id = x.step_id)),
                                                  core.step_target((select s from core.permit_step s where s.id = x.step_id), (select p from core.permit p where p.id = x.id), x.step_id))),
             core.permit_start(x.id), 'Starts', '/permits/' || x.id, core.permit_start(x.id) < now());
  end loop;
  for x in select * from core.chase_items(p_venue_id, 'rfi') loop
    due := due || (select core.dash_item('information', core.permit_label(p.id), 'Answer the information request: ' || f.message,
                     core.owner_names(x.owners), core.permit_start(p.id), 'Starts', x.link, core.permit_start(p.id) < now())
                     from core.rfi f join core.permit_version v on v.id = f.permit_version_id join core.permit p on p.id = v.permit_id where f.id = x.item_id);
  end loop;
  for pr in select p.* from core.permit p where p.venue_id = p_venue_id and p.status = 'approved_for_issue' loop
    b := core.issue_blockers(pr.id);
    if jsonb_array_length(b) = 0 then
      due := due || core.dash_item('issue', core.permit_label(pr.id), 'Ready to issue',
               core.owner_names(core.action_holders('permit.issue', core.permit_target(pr, pr.id, 'permit', null)
                 || (select core.revision_scope(v.revision_id) from core.permit_version v where v.id = pr.current_version_id)
                 || jsonb_build_object('permit_class_id', pr.permit_class_id, 'excluded_person_ids', core.issue_excluded(pr.id)))),
               core.permit_start(pr.id), 'Starts', '/permits/' || pr.id, core.permit_start(pr.id) < now());
    else
      for k in select * from jsonb_array_elements(b) loop
        due := due || core.dash_item('prerequisite', core.permit_label(pr.id), 'Missing before issue: ' || (k ->> 'problem'), k ->> 'who',
                 core.permit_start(pr.id), 'Starts', '/permits/' || pr.id, core.permit_start(pr.id) < now());
      end loop;
    end if;
  end loop;
  for x in select p.* from core.permit p where p.venue_id = p_venue_id and p.status = 'issued_awaiting_acceptance' loop
    due := due || core.dash_item('acceptance', core.permit_label(x.id), 'Accept the permit at the workface',
             core.owner_names(core.permit_supervisors(x.id)), core.permit_start(x.id), 'Starts', '/permits/' || x.id, core.permit_start(x.id) < now());
  end loop;
  for x in select w.id, w.reference, r.created_at, pc.name from core.screening_challenge r
             join core.screening_recommendation sr on sr.id = r.recommendation_id join core.work_package w on w.id = sr.work_package_id
             join core.permit_class pc on pc.id = sr.permit_class_id
            where w.venue_id = p_venue_id and sr.status = 'challenged' loop
    due := due || core.dash_item('screening', x.reference, format('Decide the challenge to the %s recommendation', x.name),
             core.owner_names(core.venue_action_appointees(p_venue_id, 'screening.decide')), x.created_at, 'Since', '/jobs/' || x.id);
  end loop;
  for x in select w.id, w.reference, h.created_at, pc.name from core.external_reference_hold h join core.work_package w on w.id = h.work_package_id
             join core.permit_class pc on pc.id = h.permit_class_id
            where w.venue_id = p_venue_id and h.status = 'open' and exists (select 1 from core.external_reference_evidence e where e.hold_id = h.id) loop
    due := due || core.dash_item('screening', x.reference, format('Decide the external evidence for %s', x.name),
             core.owner_names(core.venue_action_appointees(p_venue_id, 'external_reference.decide')), x.created_at, 'Since', '/jobs/' || x.id);
  end loop;
  for ac in select a.* from core.access_authorisation a where a.venue_id = p_venue_id and a.status = 'requested' loop
    due := due || core.dash_item('visit', ac.reference, 'Decide the visit request (entry only)',
             core.owner_names(core.action_holders('access.approve', core.access_target(ac, ac.id, core.access_people(ac)))), lower(ac.valid_during), 'Starts',
             '/visits/' || ac.id, lower(ac.valid_during) < now());
  end loop;

  -- 3. Stopped work, control failures, impairments and fire watches.
  for x in select p.id, s.kind, s.reason, s.created_at, core.suspension_owner(s) as who
             from core.permit p join core.permit_suspension s on s.permit_id = p.id
            where p.venue_id = p_venue_id and p.status = 'suspended' and core.suspension_holding(s.id) loop
    stopped := stopped || core.dash_item('stop', core.permit_label(x.id), 'Work stopped: ' || x.reason, x.who, x.created_at, 'Since', '/permits/' || x.id);
  end loop;
  for x in select z.*, a.name from core.area_stop z join core.area a on a.id = z.area_id
            where z.venue_id = p_venue_id and not exists (select 1 from core.area_stop_lift l where l.area_stop_id = z.id) loop
    stopped := stopped || core.dash_item('area_stop', x.name, 'All work stopped in this area: ' || x.reason, 'A venue authority for ' || x.name,
                 x.created_at, 'Since', '/live');
  end loop;
  for x in select f.*, y.name from core.control_failure f
             join lateral (select sy.name from core.isolation i join core.system sy on sy.id = i.system_id where f.control_kind = 'isolation' and i.id = f.control_id
                           union all
                           select sy.name from core.impairment i join core.system sy on sy.id = i.system_id where f.control_kind = 'impairment' and i.id = f.control_id) y on true
            where f.venue_id = p_venue_id and not exists (select 1 from core.control_failure_resolution r where r.failure_id = f.id) loop
    stopped := stopped || core.dash_item('control_failure', x.name, format('Control failure (%s): %s', x.control_kind, x.reason),
                 format('The %s authority for %s', x.control_kind, x.name), x.created_at, 'Since', '/controls', true);
  end loop;
  for x in select i.*, y.name, core.impairment_overdue_since(i) as overdue_since from core.impairment i join core.system y on y.id = i.system_id
            where i.venue_id = p_venue_id and i.status in ('impaired', 'tested') loop
    stopped := stopped || core.dash_item('impairment', x.name,
                 case when x.overdue_since is not null then format('Impairment past its approved time since %s: restore it, or decide what happens', core.venue_time(p_venue_id, x.overdue_since))
                      else format('Impaired (%s) until %s', x.status, core.venue_time(p_venue_id, upper(x.planned_window))) end,
                 core.owner_names(array[x.requested_by_person_id]
                   || coalesce((select array_agg(o.owner_person_id) from core.control_ownership o where o.control_kind = 'impairment' and o.control_id = x.id), '{}')),
                 coalesce(x.overdue_since, upper(x.planned_window)), case when x.overdue_since is not null then 'Overdue since' else 'Planned end' end,
                 '/controls', x.overdue_since is not null);
  end loop;
  for x in select w.*, core.fire_watch_overdue_since(w) as overdue_since from core.fire_watch w
            where w.venue_id = p_venue_id and w.status in ('arranged', 'started') loop
    stopped := stopped || core.dash_item('fire_watch', core.permit_label(x.permit_id),
                 case when x.overdue_since is not null then 'Fire watch not started, but the work has stopped or ended'
                      when x.status = 'started' then format('Fire watch %s the work in progress (at least %s minutes)', case x.phase when 'during' then 'during' else 'after' end, x.minimum_minutes)
                      else format('Fire watch %s the work arranged', case x.phase when 'during' then 'during' else 'after' end) end,
                 core.owner_names(array[x.watcher_person_id] || core.permit_supervisors(x.permit_id)),
                 coalesce(x.overdue_since, x.started_at, x.created_at), case when x.overdue_since is not null then 'Overdue since' when x.started_at is not null then 'Started' else 'Arranged' end,
                 '/permits/' || x.permit_id, x.overdue_since is not null);
  end loop;

  -- 4. Hand-backs due, continuing controls, outage exceptions, emergency work overdue.
  for x in select p.*, (select max(h.at) from core.status_history h where h.table_name = 'core.permit' and h.record_id = p.id and h.to_state = p.status) as since
             from core.permit p where p.venue_id = p_venue_id
              and (p.status = 'hand_back_pending' or (p.status = 'expired' and jsonb_array_length(core.hand_back_duties(p.id)) > 0)) loop
    b := core.hand_back_duties(x.id);
    if jsonb_array_length(b) = 0 then
      closing := closing || core.dash_item('hand_back', core.permit_label(x.id), 'Handed back: accept or reject it', 'A hand-back acceptor', x.since, 'Since', '/permits/' || x.id);
    else
      for k in select * from jsonb_array_elements(b) loop
        closing := closing || core.dash_item('hand_back', core.permit_label(x.id),
                     (case when x.status = 'expired' then 'Expired with a duty outstanding: ' else 'Cannot close yet: ' end) || (k ->> 'problem'),
                     k ->> 'who', x.since, 'Since', '/permits/' || x.id, true);
      end loop;
    end if;
  end loop;
  for x in select o.*, y.name, y.state from core.control_ownership o
             join lateral (select sy.name, i.status as state from core.isolation i join core.system sy on sy.id = i.system_id
                            where o.control_kind = 'isolation' and i.id = o.control_id and i.status in ('authorised', 'applied', 'proved')
                           union all
                           select sy.name, i.status from core.impairment i join core.system sy on sy.id = i.system_id
                            where o.control_kind = 'impairment' and i.id = o.control_id and i.status in ('authorised', 'impaired', 'tested')) y on true
            where o.venue_id = p_venue_id
              and o.id = (select o2.id from core.control_ownership o2 where o2.control_kind = o.control_kind and o2.control_id = o.control_id order by o2.created_at desc limit 1) loop
    closing := closing || core.dash_item('continuing_control', x.name, format('Continuing %s (%s), owned after its permit closed: %s', x.control_kind, x.state, x.reason),
                 core.owner_names(array[x.owner_person_id]), x.review_on::timestamptz, 'Review by', '/controls', x.review_on < (now() at time zone tz)::date);
  end loop;
  for x in select r.* from core.reconciliation_exception r where r.venue_id = p_venue_id and r.resolved_at is null loop
    closing := closing || core.dash_item('reconciliation', 'Outage exception', x.words, x.owner, x.created_at, 'Since', '/gate/reconcile', true);
  end loop;
  for x in select e.* from core.emergency_work e where e.venue_id = p_venue_id and (core.emergency_status(e) ->> 'overdue')::boolean loop
    closing := closing || core.dash_item('emergency', x.reference, 'Emergency work without its retrospective permit',
                 (select legal_name from core.organisation where id = x.organisation_id) || ', by linking and submitting its job',
                 x.deadline_at, 'Was due', '/emergency', true);
  end loop;

  -- 5. Restrictions and expiries affecting today's or tomorrow's work or visits (Q208).
  for x in select p.*, (select planned_window from core.permit_version where id = p.current_version_id) as win
             from core.permits_during(p_venue_id, horizon, live) p loop
    for k in select * from jsonb_array_elements(core.org_blockers(x.id, x.win) || core.team_blockers(x.id, x.win)) loop
      affecting := affecting || core.dash_item(k ->> 'check', core.permit_label(x.id), k ->> 'problem', k ->> 'who',
                     lower(x.win), 'Starts', '/permits/' || x.id, x.status in ('active', 'issued_awaiting_acceptance', 'suspended'));
    end loop;
  end loop;
  for x in select a.* from core.access_authorisation a where a.venue_id = p_venue_id and a.status in ('requested', 'approved') and a.valid_during && horizon loop
    if authz.organisation_restricted(x.organisation_id, p_venue_id) then
      affecting := affecting || core.dash_item('visit', x.reference, 'The visiting organisation is restricted at this venue',
                     'The authority that imposed the restriction', lower(x.valid_during), 'Starts', '/visits/' || x.id, true);
    end if;
    for k in select to_jsonb(core.person_name(m.person_id)) as n from core.access_roster_member m
              where m.authorisation_id = x.id and m.removed_at is null and authz.person_restricted(m.person_id, p_venue_id) loop
      affecting := affecting || core.dash_item('visit', x.reference, format('%s is restricted at this venue', k ->> 0),
                     'The authority that imposed the restriction', lower(x.valid_during), 'Starts', '/visits/' || x.id, true);
    end loop;
  end loop;

  return jsonb_build_object('ok', true, 'venue', vn.name, 'timezone', tz, 'from', lower(horizon), 'to', upper(horizon),
    'work', work, 'visits', visits,
    'due', (select coalesce(jsonb_agg(i order by (i ->> 'at')::timestamptz nulls last), '[]') from jsonb_array_elements(due) i),
    'stopped', (select coalesce(jsonb_agg(i order by (i ->> 'overdue')::boolean desc, (i ->> 'at')::timestamptz), '[]') from jsonb_array_elements(stopped) i),
    'closing', (select coalesce(jsonb_agg(i order by (i ->> 'overdue')::boolean desc, (i ->> 'at')::timestamptz), '[]') from jsonb_array_elements(closing) i),
    'affecting', (select coalesce(jsonb_agg(i order by (i ->> 'at')::timestamptz), '[]') from jsonb_array_elements(affecting) i));
end $$;

-- ---------------------------------------------------------------------------
-- Organisation dashboard (Q205)
-- ---------------------------------------------------------------------------
-- Who owns a venue decision, as told to the applicant: a role, never a name (P5-6).
create function core.step_owner_words(s core.permit_step) returns text
language sql stable security definer set search_path = '' as $$
  select case s.kind
    when 'occupier' then 'The affected occupier'
    when 'landlord_operator' then 'The landlord or operator'
    when 'external' then coalesce((select legal_name from core.organisation where id = s.party_organisation_id), 'An external party')
    else 'The venue''s reviewer' end $$;

create function api.organisation_dashboard(p_organisation_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  org core.organisation; jobs jsonb; visits jsonb; returned jsonb := '[]'; workers jsonb := '[]'; venue_decisions jsonb := '[]'; live jsonb;
  x record; k jsonb; b jsonb; win tstzrange;
  open_states text[] := array['draft', 'submitted', 'under_review', 'more_information_required', 'approved_for_issue', 'issued_awaiting_acceptance', 'active', 'suspended'];
begin
  select * into org from core.organisation where id = p_organisation_id;
  if org.id is null or p_organisation_id not in (select authz.my_admin_organisation_ids()) then
    return core.refuse('dashboard.organisation', 'not_visible', 'This dashboard is for the organisation''s administrators.',
                       'An administrator role for this organisation', 'The organisation''s accountable administrator');
  end if;

  -- 1. Jobs and visits due next, and the state of each permit they need.
  jobs := (select coalesce(jsonb_agg(jsonb_build_object(
                    'id', w.id, 'reference', w.reference, 'status', w.status, 'title', r.title,
                    'venue', (select name from core.venue where id = w.venue_id), 'timezone', (select timezone from core.venue where id = w.venue_id),
                    'from', lower(r.planned_window), 'to', upper(r.planned_window),
                    'permits', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'class_name', pc.name, 'kind', p.kind, 'status', p.status,
                                                                     'missing', case when p.status = 'approved_for_issue' then core.issue_blockers(p.id) else '[]' end)
                                                          order by p.kind desc, pc.name), '[]')
                                  from core.permit p join core.permit_class pc on pc.id = p.permit_class_id
                                 where p.work_package_id = w.id and p.status not in ('cancelled', 'closed')))
                  order by lower(r.planned_window)), '[]')
             from core.work_package w join core.work_package_revision r on r.id = w.current_revision_id
            where w.performing_organisation_id = p_organisation_id and w.status <> 'cancelled' and upper(r.planned_window) > now()
              and not exists (select 1 from core.permit p where p.work_package_id = w.id and p.kind = 'work_approval' and p.status = 'closed'));
  visits := (select coalesce(jsonb_agg(jsonb_build_object(
                     'id', a.id, 'reference', a.reference, 'status', a.status,
                     'venue', (select name from core.venue where id = a.venue_id), 'timezone', (select timezone from core.venue where id = a.venue_id),
                     'purpose', core.visit_purpose(a) ->> 'name', 'from', lower(a.valid_during), 'to', upper(a.valid_during),
                     'consents_waiting', exists (select 1 from core.consents_needed(a.id) n where not n.given and not n.refused),
                     'consents_refused', exists (select 1 from core.consents_needed(a.id) n where n.refused))
                   order by lower(a.valid_during)), '[]')
               from core.access_authorisation a
              where a.organisation_id = p_organisation_id and a.status in ('requested', 'approved') and upper(a.valid_during) > now());

  -- 2. Requests returned, with exactly what was asked.
  for x in select f.*, p.id as permit_id from core.rfi f join core.permit_version v on v.id = f.permit_version_id join core.permit p on p.id = v.permit_id
             join core.work_package w on w.id = p.work_package_id
            where w.performing_organisation_id = p_organisation_id and p.status = 'more_information_required' and p.current_version_id = f.permit_version_id
              and not exists (select 1 from core.rfi_response y where y.rfi_id = f.id) loop
    returned := returned || (core.dash_item('information', core.permit_label(x.permit_id), x.message, 'Your organisation: answer and resubmit',
                  x.created_at, 'Asked', '/permits/' || x.permit_id)
                  || jsonb_build_object('items', (select coalesce(jsonb_agg(i ->> 'text'), '[]') from jsonb_array_elements(x.items) i)));
  end loop;
  for x in select d.id, d.title, rd.outcome, rd.conditions, rd.scope_wording, rd.created_at
             from core.document d join lateral (select dv.id from core.document_version dv where dv.document_id = d.id order by dv.version_no desc limit 1) lv on true
             join core.review_decision rd on rd.document_version_id = lv.id
            where (d.organisation_id = p_organisation_id or d.provided_via_organisation_id = p_organisation_id)
              and rd.outcome in ('more_information_required', 'not_accepted') loop
    returned := returned || (core.dash_item('document', x.title,
                  case x.outcome when 'more_information_required' then 'More information required' else 'Not accepted' end
                    || coalesce(': ' || nullif(btrim(x.conditions), ''), ''),
                  'Your organisation: upload a new version', x.created_at, 'Reviewed', '/organisation/' || p_organisation_id)
                  || jsonb_build_object('items', '[]'::jsonb));
  end loop;

  -- 3. Workers needing an induction, evidence or a place on a team, only for planned work (Q208).
  for x in select p.*, v.planned_window as win from core.permit p join core.permit_version v on v.id = p.current_version_id
             join core.work_package w on w.id = p.work_package_id
            where w.performing_organisation_id = p_organisation_id and p.status = any (open_states) and upper(v.planned_window) > now() loop
    for k in select * from jsonb_array_elements(core.org_blockers(x.id, x.win) || core.team_blockers(x.id, x.win)) loop
      workers := workers || core.dash_item(k ->> 'check', core.permit_label(x.id), k ->> 'problem', k ->> 'who',
                   lower(x.win), 'Starts', '/permits/' || x.id, lower(x.win) < now());
    end loop;
  end loop;
  for x in select a.*, m.person_id from core.access_authorisation a join core.access_roster_member m on m.authorisation_id = a.id and m.removed_at is null
            where a.organisation_id = p_organisation_id and a.status in ('requested', 'approved') and upper(a.valid_during) > now()
              and authz.person_restricted(m.person_id, a.venue_id) loop
    workers := workers || core.dash_item('visit', x.reference, format('%s is restricted at this venue and will not be admitted', core.person_name(x.person_id)),
                 'The venue', lower(x.valid_during), 'Starts', '/visits/' || x.id);
  end loop;

  -- 4. Venue decisions outstanding, and who owns them (a role, never a name).
  for x in select s.*, p.id as permit_id from core.permit p join core.permit_step s on s.permit_version_id = p.current_version_id
             join core.work_package w on w.id = p.work_package_id
            where w.performing_organisation_id = p_organisation_id and p.status in ('submitted', 'under_review') and core.step_open(s.id) loop
    venue_decisions := venue_decisions || core.dash_item('decision', core.permit_label(x.permit_id), 'Waiting for: ' || x.name,
                         core.step_owner_words((select s from core.permit_step s where s.id = x.id)), core.permit_start(x.permit_id), 'Starts', '/permits/' || x.permit_id);
  end loop;
  for x in select p.id from core.permit p join core.work_package w on w.id = p.work_package_id
            where w.performing_organisation_id = p_organisation_id and p.status = 'approved_for_issue' loop
    b := core.issue_blockers(x.id);
    if jsonb_array_length(b) = 0 then
      venue_decisions := venue_decisions || core.dash_item('issue', core.permit_label(x.id), 'Approved: waiting to be issued',
                           'The venue''s permit issuer', core.permit_start(x.id), 'Starts', '/permits/' || x.id);
    end if;
  end loop;
  for x in select w.id, w.reference, pc.name, r.created_at from core.screening_challenge r
             join core.screening_recommendation sr on sr.id = r.recommendation_id join core.work_package w on w.id = sr.work_package_id
             join core.permit_class pc on pc.id = sr.permit_class_id
            where w.performing_organisation_id = p_organisation_id and sr.status = 'challenged' loop
    venue_decisions := venue_decisions || core.dash_item('screening', x.reference, format('Your challenge to the %s recommendation', x.name),
                         'The venue''s screening authority', x.created_at, 'Since', '/jobs/' || x.id);
  end loop;
  for x in select w.id, w.reference, pc.name, h.created_at from core.external_reference_hold h join core.work_package w on w.id = h.work_package_id
             join core.permit_class pc on pc.id = h.permit_class_id
            where w.performing_organisation_id = p_organisation_id and h.status = 'open' and exists (select 1 from core.external_reference_evidence e where e.hold_id = h.id) loop
    venue_decisions := venue_decisions || core.dash_item('screening', x.reference, format('Your external evidence for %s', x.name),
                         'The venue''s screening authority', x.created_at, 'Since', '/jobs/' || x.id);
  end loop;
  for x in select a.* from core.access_authorisation a where a.organisation_id = p_organisation_id and a.status = 'requested' loop
    venue_decisions := venue_decisions || core.dash_item('visit', x.reference,
                         case when exists (select 1 from core.consents_needed(x.id) n where not n.given and not n.refused)
                              then 'Visit request: waiting for an affected occupier''s consent, then the venue''s decision'
                              else 'Visit request: waiting for the venue''s decision' end,
                         'The venue''s access authority', lower(x.valid_during), 'Starts', '/visits/' || x.id);
  end loop;
  for x in select e.id, e.created_at, v.name from core.engagement e join core.venue v on v.id = e.venue_id
            where e.organisation_id = p_organisation_id and e.status = 'proposed' loop
    venue_decisions := venue_decisions || core.dash_item('engagement', x.name, 'Your engagement at this venue is waiting for approval',
                         'The venue''s compliance authority', x.created_at, 'Since', '/organisation/' || p_organisation_id);
  end loop;

  -- 5. Live permits, stopped work and hand-backs due.
  live := (select coalesce(jsonb_agg(core.permit_summary(p)
                    order by case p.status when 'suspended' then 0 when 'hand_back_pending' then 1 when 'expired' then 2
                                           when 'issued_awaiting_acceptance' then 3 else 4 end, core.permit_window_end(p.id)), '[]')
             from core.permit p join core.work_package w on w.id = p.work_package_id
            where w.performing_organisation_id = p_organisation_id
              and (p.status in ('issued_awaiting_acceptance', 'active', 'suspended', 'hand_back_pending')
                   or (p.status = 'expired' and jsonb_array_length(core.hand_back_duties(p.id)) > 0)));

  return jsonb_build_object('ok', true, 'organisation', org.legal_name,
    'jobs', jobs, 'visits', visits,
    'returned', (select coalesce(jsonb_agg(i order by (i ->> 'at')::timestamptz), '[]') from jsonb_array_elements(returned) i),
    'workers', (select coalesce(jsonb_agg(i order by (i ->> 'at')::timestamptz), '[]') from jsonb_array_elements(workers) i),
    'venue_decisions', (select coalesce(jsonb_agg(i order by (i ->> 'at')::timestamptz nulls last), '[]') from jsonb_array_elements(venue_decisions) i),
    'live', live);
end $$;

grant execute on function api.venue_dashboard(uuid), api.organisation_dashboard(uuid) to authenticated;
revoke execute on function api.venue_dashboard(uuid), api.organisation_dashboard(uuid) from anon, public;
