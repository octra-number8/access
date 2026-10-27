-- 0055 Reports (phase 8b, D-021, Q209, Q96)
--
-- One read, api.report(kind, venue, from, to, organisation), returning the columns and rows of
-- an on-screen report that the same screen downloads as CSV (P8-15: no scheduled emails). Each
-- reports what was recorded, in the venue's time, and none is a score. Reports follow record
-- visibility: the venue's side sees every row at its venue; an organisation's administrator
-- sees only rows about its own organisation, and never gate activity, which is about other
-- people. The period is whole venue days, at most 366.
--
--   approval_lead_times  each step decision: when the request was submitted, when decided, by whom
--   returns              each information request, exactly what was asked, and when answered
--   late_requests        late-notice and restriction-conflict requests and emergency work, by
--                        organisation, work type and stated cause (Q96)
--   hand_backs           each hand-back, its decision and how long it waited; duties still open
--   gate_activity        evaluations, scans, overrides, offline entries and exceptions by gate and day
--   visit_attendance     each visit's roster: who arrived and left, and who did not attend
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only (drop the function).

create function core.report_kinds() returns text[]
language sql immutable set search_path = '' as $$
  select array['approval_lead_times', 'returns', 'late_requests', 'hand_backs', 'gate_activity', 'visit_attendance'] $$;

create function core.local_text(p_at timestamptz, p_tz text) returns text
language sql immutable set search_path = '' as $$
  select to_char(p_at at time zone p_tz, 'YYYY-MM-DD HH24:MI') $$;

create function core.hours_between(p_from timestamptz, p_to timestamptz) returns numeric
language sql immutable set search_path = '' as $$
  select round((extract(epoch from (p_to - p_from)) / 3600)::numeric, 1) $$;

create function api.report(p_kind text, p_venue_id uuid, p_from date, p_to date, p_organisation_id uuid default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  vn core.venue; tz text; period tstzrange; org uuid := p_organisation_id; cols jsonb; rows jsonb;
begin
  select * into vn from core.venue where id = p_venue_id;
  if vn.id is null then
    return core.refuse('report.read', 'not_visible', 'This venue does not exist or you cannot see its reports.', 'A venue you work with', 'The venue''s administrator');
  end if;
  if org is null and not authz.venue_side(p_venue_id) then
    return core.refuse('report.read', 'not_visible', 'Venue reports are for the venue''s administrators and appointees. An organisation''s administrator sees its own rows.',
                       'An appointment at this venue, tenant administration, or a choice of your organisation', 'The venue''s administrator');
  end if;
  if org is not null and not (org in (select authz.my_admin_organisation_ids())
                              and exists (select 1 from core.organisation o where o.id = org and o.customer_id = vn.customer_id))
     and not authz.venue_side(p_venue_id) then
    return core.refuse('report.read', 'not_visible', 'You can see reports only for an organisation you administer.',
                       'An administrator role for this organisation', 'The organisation''s accountable administrator');
  end if;
  if not (p_kind = any (core.report_kinds())) then
    return core.refuse('report.read', 'invalid_content', 'Choose one of the reports.', 'A report', 'You');
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 365 then
    return core.refuse('report.read', 'invalid_content', 'Choose a period of whole days, from no later than to, of at most 366 days.', 'A period', 'You');
  end if;
  if org is not null and p_kind = 'gate_activity' then
    return core.refuse('report.read', 'not_visible', 'Gate activity is about everyone at the venue, so it is shown only to the venue''s side.',
                       'An appointment at this venue, or tenant administration', 'The venue''s administrator');
  end if;
  tz := vn.timezone;
  period := tstzrange(p_from::timestamp at time zone tz, (p_to + 1)::timestamp at time zone tz);

  if p_kind = 'approval_lead_times' then
    cols := '[["decided_at","Decided"],["permit","Permit"],["organisation","Organisation"],["step","Step"],["outcome","Outcome"],["decided_by","Decided by"],["submitted_at","Request submitted"],["hours","Hours from submission"]]';
    rows := (select coalesce(jsonb_agg(jsonb_build_object(
                'decided_at', core.local_text(d.created_at, tz), 'permit', core.permit_label(p.id),
                'organisation', (select legal_name from core.organisation where id = w.performing_organisation_id),
                'step', s.name, 'outcome', replace(d.outcome, '_', ' '), 'decided_by', core.person_name(d.decider_person_id),
                'submitted_at', core.local_text(v.created_at, tz), 'hours', core.hours_between(v.created_at, d.created_at))
              order by d.created_at), '[]')
               from core.step_decision d join core.permit_step s on s.id = d.permit_step_id join core.permit_version v on v.id = s.permit_version_id
               join core.permit p on p.id = v.permit_id join core.work_package w on w.id = p.work_package_id
              where d.venue_id = p_venue_id and d.created_at <@ period and (org is null or w.performing_organisation_id = org));

  elsif p_kind = 'returns' then
    cols := '[["asked_at","Asked"],["permit","Permit"],["organisation","Organisation"],["asked_by","Asked by"],["message","Message"],["questions","What was asked"],["answered_at","Answered"],["answered_by","Answered by"],["hours","Hours to answer"]]';
    rows := (select coalesce(jsonb_agg(jsonb_build_object(
                'asked_at', core.local_text(f.created_at, tz), 'permit', core.permit_label(p.id),
                'organisation', (select legal_name from core.organisation where id = w.performing_organisation_id),
                'asked_by', (select core.person_name(d.decider_person_id) from core.step_decision d where d.id = f.step_decision_id),
                'message', f.message, 'questions', (select string_agg(i ->> 'text', '; ') from jsonb_array_elements(f.items) i),
                'answered_at', core.local_text(y.created_at, tz), 'answered_by', core.person_name(y.responder_person_id),
                'hours', core.hours_between(f.created_at, y.created_at))
              order by f.created_at), '[]')
               from core.rfi f join core.permit_version v on v.id = f.permit_version_id join core.permit p on p.id = v.permit_id
               join core.work_package w on w.id = p.work_package_id
               left join core.rfi_response y on y.rfi_id = f.id
              where f.venue_id = p_venue_id and f.created_at <@ period and (org is null or w.performing_organisation_id = org));

  elsif p_kind = 'late_requests' then
    cols := '[["at","Requested"],["route","Route"],["reference","Permit or reference"],["organisation","Organisation"],["work_type","Work type"],["cause","Stated cause"],["outcome","Outcome"],["decided_by","Decided or authorised by"]]';
    rows := (select coalesce(jsonb_agg(r order by r ->> 'at'), '[]') from (
               select jsonb_build_object(
                 'at', core.local_text(x.created_at, tz),
                 'route', case x.kind when 'late_notice' then 'Late notice' else 'Restriction conflict' end,
                 'reference', core.permit_label(p.id),
                 'organisation', (select legal_name from core.organisation where id = w.performing_organisation_id),
                 'work_type', (select label from core.work_type where id = w.work_type_id),
                 'cause', x.reason || coalesce(' (if delayed: ' || nullif(btrim(x.consequence_of_delay), '') || ')', ''),
                 'outcome', coalesce(d.outcome, 'not yet decided'), 'decided_by', core.person_name(d.decider_person_id)) r
                 from core.exception_request x join core.permit_version v on v.id = x.permit_version_id join core.permit p on p.id = v.permit_id
                 join core.work_package w on w.id = p.work_package_id
                 left join core.exception_decision d on d.exception_request_id = x.id
                where x.venue_id = p_venue_id and x.created_at <@ period and (org is null or w.performing_organisation_id = org)
               union all
               select jsonb_build_object(
                 'at', core.local_text(e.created_at, tz), 'route', 'Emergency (' || e.category || ')', 'reference', e.reference,
                 'organisation', (select legal_name from core.organisation where id = e.organisation_id),
                 'work_type', (select t.label from core.work_package w join core.work_type t on t.id = w.work_type_id where w.id = e.work_package_id),
                 'cause', e.why_could_not_wait,
                 'outcome', case when (core.emergency_status(e) ->> 'retrospective_submitted')::boolean then 'retrospective permit submitted'
                                 when (core.emergency_status(e) ->> 'overdue')::boolean then 'retrospective permit overdue'
                                 else 'retrospective permit due' end,
                 'decided_by', core.person_name(e.authorised_by_person_id))
                 from core.emergency_work e
                where e.venue_id = p_venue_id and e.created_at <@ period and (org is null or e.organisation_id = org)) s);

  elsif p_kind = 'hand_backs' then
    cols := '[["submitted_at","Handed back"],["permit","Permit"],["organisation","Organisation"],["route","Route"],["work_complete","Work complete"],["outcome","Outcome"],["decided_at","Decided"],["decided_by","Decided by"],["reason","Reason"],["hours","Hours waiting"],["outstanding","Duties outstanding now"]]';
    rows := (select coalesce(jsonb_agg(jsonb_build_object(
                'submitted_at', core.local_text(h.created_at, tz), 'permit', core.permit_label(p.id),
                'organisation', (select legal_name from core.organisation where id = w.performing_organisation_id),
                'route', replace(h.route, '_', ' '), 'work_complete', case when h.work_complete then 'yes' else 'no' end,
                'outcome', coalesce(d.outcome, 'waiting'), 'decided_at', core.local_text(d.created_at, tz),
                'decided_by', core.person_name(d.decider_person_id), 'reason', d.reason,
                'hours', core.hours_between(h.created_at, coalesce(d.created_at, now())),
                'outstanding', case when p.status in ('hand_back_pending', 'expired', 'suspended')
                                    then (select string_agg(x ->> 'problem', ' ') from jsonb_array_elements(core.hand_back_duties(p.id)) x) end)
              order by h.created_at), '[]')
               from core.hand_back h join core.permit p on p.id = h.permit_id join core.work_package w on w.id = p.work_package_id
               left join core.hand_back_decision d on d.hand_back_id = h.id
              where h.venue_id = p_venue_id and h.created_at <@ period and (org is null or w.performing_organisation_id = org));

  elsif p_kind = 'gate_activity' then
    cols := '[["day","Day"],["gate","Gate"],["admit","Admit"],["admit_with_escort","Admit with escort"],["check","Check with owner"],["do_not_admit","Do not admit"],["scans_in","Scanned in"],["scans_out","Scanned out"],["overrides","Overrides granted"],["offline_entries","Offline entries"],["exceptions","Outage exceptions"]]';
    rows := (select coalesce(jsonb_agg(jsonb_build_object('day', g.day, 'gate', g.gate,
                'admit', g.admit, 'admit_with_escort', g.escort, 'check', g.chk, 'do_not_admit', g.dna, 'scans_in', g.s_in, 'scans_out', g.s_out,
                'overrides', g.ovr, 'offline_entries', g.off, 'exceptions', g.exc) order by g.day, g.gate), '[]')
               from (select e.day, e.gate,
                            count(*) filter (where e.what = 'admit') as admit, count(*) filter (where e.what = 'admit_with_escort') as escort,
                            count(*) filter (where e.what = 'check') as chk, count(*) filter (where e.what = 'do_not_admit') as dna,
                            count(*) filter (where e.what = 'in') as s_in, count(*) filter (where e.what = 'out') as s_out,
                            count(*) filter (where e.what = 'override') as ovr, count(*) filter (where e.what = 'offline') as off,
                            count(*) filter (where e.what = 'exception') as exc
                       from (select to_char(x.evaluated_at at time zone tz, 'YYYY-MM-DD') as day, gp.name as gate, x.outcome as what
                               from core.entry_eligibility_evaluation x left join core.gate_point gp on gp.id = x.gate_point_id
                              where x.venue_id = p_venue_id and x.evaluated_at <@ period
                             union all
                             select to_char(x.created_at at time zone tz, 'YYYY-MM-DD'), gp.name, x.direction
                               from core.scan_event x left join core.gate_point gp on gp.id = x.gate_point_id
                              where x.venue_id = p_venue_id and x.created_at <@ period
                             union all
                             select to_char(x.created_at at time zone tz, 'YYYY-MM-DD'), null, 'override'
                               from core.entry_override x where x.venue_id = p_venue_id and x.created_at <@ period
                             union all
                             select to_char(x.recorded_at at time zone tz, 'YYYY-MM-DD'), gp.name, 'offline'
                               from core.manual_fallback_entry x left join core.gate_point gp on gp.id = x.gate_point_id
                              where x.venue_id = p_venue_id and x.recorded_at <@ period
                             union all
                             select to_char(x.created_at at time zone tz, 'YYYY-MM-DD'), gp.name, 'exception'
                               from core.reconciliation_exception x join core.manual_fallback_entry m on m.id = x.fallback_entry_id
                               left join core.gate_point gp on gp.id = m.gate_point_id
                              where x.venue_id = p_venue_id and x.created_at <@ period) e
                      group by e.day, e.gate) g);
    -- Overrides are granted for a person and area, not at a gate.
    rows := (select coalesce(jsonb_agg(case when r ->> 'gate' is null then r || '{"gate": "(not at a gate)"}' else r end), '[]') from jsonb_array_elements(rows) r);

  elsif p_kind = 'visit_attendance' then
    cols := '[["visit","Visit"],["organisation","Organisation"],["purpose","Purpose"],["from","From"],["to","To"],["person","Person"],["arrived_at","Arrived"],["left_at","Left"]]';
    rows := (select coalesce(jsonb_agg(r order by r ->> 'from', r ->> 'visit', r ->> 'person', r ->> 'arrived_at'), '[]') from (
               select jsonb_build_object('visit', a.reference, 'organisation', (select legal_name from core.organisation where id = a.organisation_id),
                        'purpose', core.visit_purpose(a) ->> 'name', 'from', core.local_text(lower(a.valid_during), tz), 'to', core.local_text(upper(a.valid_during), tz),
                        'person', core.person_name(m.person_id),
                        'arrived_at', coalesce(core.local_text(t.arrived_at, tz), 'did not attend'), 'left_at', core.local_text(t.left_at, tz)) r
                 from core.access_authorisation a join core.access_roster_member m on m.authorisation_id = a.id
                 left join core.visit_attendance t on t.authorisation_id = a.id and t.person_id = m.person_id
                where a.venue_id = p_venue_id and a.status in ('approved', 'cancelled') and a.valid_during && period
                  and (m.removed_at is null or t.id is not null)
                  and (org is null or a.organisation_id = org)) s);
  end if;

  return jsonb_build_object('ok', true, 'kind', p_kind, 'venue', vn.name, 'timezone', tz, 'from', p_from, 'to', p_to,
    'organisation', (select legal_name from core.organisation where id = org),
    'columns', (select jsonb_agg(jsonb_build_object('key', c ->> 0, 'label', c ->> 1)) from jsonb_array_elements(cols) c),
    'rows', rows);
end $$;

-- Which venues and organisations a person can report on, for the report screen's choices.
create function api.report_scopes() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'venues', (select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'name', v.name) order by v.name), '[]')
                 from core.venue v where authz.venue_side(v.id)),
    'organisations', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'name', o.legal_name,
                                        'venues', (select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'name', v.name) order by v.name), '[]')
                                                     from core.venue v where v.id in (select e.venue_id from core.engagement e where e.organisation_id = o.id)))
                                      order by o.legal_name), '[]')
                        from core.organisation o where o.id in (select authz.my_admin_organisation_ids()))) $$;

grant execute on function api.report(text, uuid, date, date, uuid), api.report_scopes() to authenticated;
revoke execute on function api.report(text, uuid, date, date, uuid), api.report_scopes() from anon, public;
