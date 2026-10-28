-- 0065 Venue set-up status (P4, D-025)
--
-- Configuration with no silent default (CLAUDE.md §9) means a new venue is refused, one action
-- at a time, until each piece is set up. This read-only view lists every piece in one place, so
-- the venue sees what is missing before anyone is refused. Each item's state is computed from the
-- records themselves: nobody can tick an item, and there is no score or percentage. A state says
-- only that a record exists and what was decided about it, nothing about whether it is adequate.
--
-- Readable by the venue's tenant administrators and by anyone holding an appointment at the
-- venue (they are the people who approve most of it). Names shown are the venue's own
-- appointees for the approving action; the database still decides every action.
--
-- Rollback / recovery: forward-only and read-only. To withdraw, drop api.venue_setup and the
-- core.setup_* helpers; nothing else uses them.

create function core.setup_viewer(p_venue_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from core.venue v where v.id = p_venue_id and v.customer_id in (select authz.my_admin_customer_ids()))
      or p_venue_id in (select authz.my_appointee_venue_ids())
$$;

-- People at the venue whose current appointment allows the action at venue level, by name.
create function core.setup_holders(vn core.venue, p_action text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(n order by n), '[]')
    from (select core.person_name(p) n
            from unnest(core.action_holders(p_action, jsonb_build_object('customer_id', vn.customer_id, 'venue_id', vn.id,
                                                                         'target_type', 'venue_setup'))) p) x
$$;

-- One item. p_state is one of not_set_up, draft, proposed, scheduled, in_force, recorded.
create function core.setup_item(vn core.venue, p_key text, p_section text, p_name text, p_needed_for text,
                                p_state text, p_detail text, p_in_force_from timestamptz, p_pending text,
                                p_resolved_by text, p_action text, p_href text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'key', p_key, 'section', p_section, 'name', p_name, 'needed_for', p_needed_for, 'state', p_state,
    'state_words', case p_state when 'not_set_up' then 'Not set up' when 'draft' then 'Draft, not yet proposed'
                                when 'proposed' then 'Awaiting approval' when 'scheduled' then 'Published, not yet in force'
                                when 'in_force' then 'In force' when 'recorded' then 'Recorded' end,
    'detail', p_detail, 'in_force_from', p_in_force_from, 'pending', p_pending, 'resolved_by', p_resolved_by,
    'holders', case when p_action is null then null else core.setup_holders(vn, p_action) end,
    'holder_action', p_action, 'href', p_href)
$$;

-- An item following the draft, proposed, approved pattern (screening, permit classes, entry
-- rules, venue configuration documents). The approved row is in force; a draft or proposed row
-- beside it is reported as pending.
create function core.setup_versioned(vn core.venue, p_key text, p_section text, p_name text, p_needed_for text,
                                     p_approved_no integer, p_approved_at timestamptz, p_approved_by uuid,
                                     p_pending_status text, p_pending_no integer,
                                     p_resolved_by text, p_action text, p_href text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select core.setup_item(vn, p_key, p_section, p_name, p_needed_for,
    case when p_approved_no is not null then 'in_force'
         when p_pending_status = 'proposed' then 'proposed'
         when p_pending_status = 'draft' then 'draft'
         else 'not_set_up' end,
    case when p_approved_no is not null then format('Version %s, approved by %s', p_approved_no, core.person_name(p_approved_by))
         when p_pending_no is not null then format('Version %s', p_pending_no) end,
    case when p_approved_no is not null then p_approved_at end,
    case when p_approved_no is not null and p_pending_status = 'proposed' then format('Version %s awaits approval.', p_pending_no)
         when p_approved_no is not null and p_pending_status = 'draft' then format('Version %s is being drafted.', p_pending_no) end,
    p_resolved_by, p_action, p_href)
$$;

-- A venue configuration document of one kind.
create function core.setup_config(vn core.venue, p_kind text, p_key text, p_section text, p_name text, p_needed_for text,
                                  p_resolved_by text, p_action text, p_href text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select core.setup_versioned(vn, p_key, p_section, p_name, p_needed_for, a.version_no, a.decided_at, a.decided_by_person_id,
                              p.status, p.version_no, p_resolved_by, p_action, p_href)
    from (select 1) one
    left join core.venue_config_version a on a.venue_id = vn.id and a.kind = p_kind and a.status = 'approved'
    left join lateral (select status, version_no from core.venue_config_version
                        where venue_id = vn.id and kind = p_kind and status in ('draft', 'proposed')
                        order by version_no desc limit 1) p on true
$$;

-- A record published in one step with an effective date (calendar, emergency contacts,
-- emergency work categories). The latest one already effective is in force; a later one is
-- scheduled.
create function core.setup_published(vn core.venue, p_key text, p_section text, p_name text, p_needed_for text,
                                     p_current_at timestamptz, p_current_by uuid, p_next_at timestamptz,
                                     p_resolved_by text, p_action text, p_href text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select core.setup_item(vn, p_key, p_section, p_name, p_needed_for,
    case when p_current_at is not null then 'in_force' when p_next_at is not null then 'scheduled' else 'not_set_up' end,
    case when p_current_by is not null then format('Owner: %s', core.person_name(p_current_by)) end,
    coalesce(p_current_at, p_next_at),
    case when p_current_at is not null and p_next_at is not null then 'A newer version is published and not yet in force.' end,
    p_resolved_by, p_action, p_href)
$$;

create function api.venue_setup(p_venue_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  vn core.venue;
  items jsonb := '[]';
  r record;
  n integer;
  admin_drafts constant text := 'A tenant administrator drafts it; someone appointed to approve it approves it.';
begin
  select * into vn from core.venue where id = p_venue_id;
  if vn.id is null or not core.setup_viewer(vn.id) then
    return jsonb_build_object('ok', false, 'code', 'not_found', 'reason', 'The record does not exist or you do not have access to it.');
  end if;

  -- Authority ------------------------------------------------------------------------------
  -- A venue may hold several root appointments (one per duty-holder appointment type).
  select string_agg(core.person_name(a.appointee_person_id), ', ' order by lower(a.valid_during))
           filter (where a.status = 'in_force' and now() <@ a.valid_during) as current,
         min(lower(a.valid_during)) filter (where a.status = 'in_force' and now() <@ a.valid_during) as since,
         min(lower(a.valid_during)) filter (where a.status = 'in_force' and lower(a.valid_during) > now()) as later,
         string_agg(format('%s: waiting for a second tenant administrator to confirm it', core.person_name(a.appointee_person_id)), '. ' order by a.created_at)
           filter (where a.status = 'pending_confirmation') as unconfirmed,
         string_agg(format('%s: waiting for the appointee to acknowledge it', core.person_name(a.appointee_person_id)), '. ' order by a.created_at)
           filter (where a.status = 'pending_acknowledgement') as unacknowledged
    into r
    from core.appointment a
   where a.venue_id = vn.id and a.is_root and a.status <> 'revoked' and (upper_inf(a.valid_during) or upper(a.valid_during) > now());
  items := items || core.setup_item(vn, 'root_appointment', 'Authority', 'Root appointment',
    'Every other appointment at the venue is made under one (D-002), and appointments are the only source of authority.',
    case when r.current is not null then 'in_force' when r.later is not null then 'scheduled'
         when coalesce(r.unconfirmed, r.unacknowledged) is not null then 'proposed' else 'not_set_up' end,
    case when r.current is not null then r.current else nullif(concat_ws('. ', r.unconfirmed, r.unacknowledged), '') end,
    coalesce(r.since, r.later),
    case when r.current is not null then nullif(concat_ws('. ', r.unconfirmed, r.unacknowledged), '') || '.' end,
    'A tenant administrator records the duty holder''s appointment; a second tenant administrator confirms it; the appointee acknowledges it.',
    null, null);

  select count(*) filter (where exists (select 1 from core.appointment_type_version v where v.appointment_type_id = t.id and v.status = 'approved' and v.effective_from <= now())) as in_force,
         count(*) filter (where exists (select 1 from core.appointment_type_version v where v.appointment_type_id = t.id and v.status = 'proposed')) as proposed
    into r from core.appointment_type t where t.venue_id = vn.id and t.retired_at is null;
  items := items || core.setup_item(vn, 'appointment_types', 'Authority', 'Appointment types',
    'Each appointment is of a type that says which actions it allows.',
    case when r.in_force > 0 then 'recorded' when r.proposed > 0 then 'proposed' else 'not_set_up' end,
    case when r.in_force > 0 then format('%s in force', r.in_force) end, null,
    case when r.proposed > 0 then format('%s awaiting approval.', r.proposed) end,
    'A tenant administrator proposes them; the root appointee approves them.', 'appointment_type.approve', '/venue');

  -- Places and systems ---------------------------------------------------------------------
  select count(*) into n from core.area a where a.venue_id = vn.id and a.parent_id is not null and a.retired_at is null;
  items := items || core.setup_item(vn, 'areas', 'Places and systems', 'Areas',
    'Jobs, appointments, gate points and stops are scoped to areas.',
    case when n > 0 then 'recorded' else 'not_set_up' end, case when n > 0 then format('%s below the venue', n) end, null, null,
    'A tenant administrator adds them. There is no screen for this yet.', null, null);

  select count(*) into n from core.system s where s.venue_id = vn.id and s.retired_at is null;
  items := items || core.setup_item(vn, 'systems', 'Places and systems', 'Building systems',
    'Isolations, impairments and system appointments refer to registered systems.',
    case when n > 0 then 'recorded' else 'not_set_up' end, case when n > 0 then format('%s registered', n) end, null, null,
    'A tenant administrator registers them. There is no screen for this yet.', null, null);

  -- Work and permits -----------------------------------------------------------------------
  select c.effective_from, c.owner_person_id into r from core.venue_calendar_version c
   where c.venue_id = vn.id and c.effective_from <= now() order by c.effective_from desc, c.created_at desc limit 1;
  items := items || core.setup_published(vn, 'calendar', 'Work and permits', 'Working calendar',
    'Notice periods are counted in the venue''s working days; no permit can be submitted without it.',
    r.effective_from, r.owner_person_id,
    (select min(c.effective_from) from core.venue_calendar_version c where c.venue_id = vn.id and c.effective_from > now()),
    'A tenant administrator publishes it.', null, '/venue/permits');

  select count(*) into n from core.work_type w where w.venue_id = vn.id and w.retired_at is null;
  items := items || core.setup_item(vn, 'work_types', 'Work and permits', 'Work types',
    'Every job is of a work type; none can be started without one.',
    case when n > 0 then 'recorded' else 'not_set_up' end, case when n > 0 then format('%s in use', n) end, null, null,
    'A tenant administrator adds them.', null, '/venue/screening');

  select a.version_no, a.decided_at, a.decided_by_person_id, p.status as p_status, p.version_no as p_no into r
    from (select 1) one
    left join core.screening_set_version a on a.venue_id = vn.id and a.status = 'approved'
    left join lateral (select status, version_no from core.screening_set_version where venue_id = vn.id and status in ('draft', 'proposed')
                        order by version_no desc limit 1) p on true;
  items := items || core.setup_versioned(vn, 'screening', 'Work and permits', 'Activity screening',
    'Jobs are screened against it to find the permits they need.',
    r.version_no, r.decided_at, r.decided_by_person_id, r.p_status, r.p_no, admin_drafts, 'screening_set.approve', '/venue/screening');

  n := 0;
  for r in
    select c.id, c.name, c.handling, a.version_no, a.decided_at, a.decided_by_person_id, p.status as p_status, p.version_no as p_no
      from core.permit_class c
      left join core.permit_class_version a on a.permit_class_id = c.id and a.status = 'approved'
      left join lateral (select status, version_no from core.permit_class_version where permit_class_id = c.id and status in ('draft', 'proposed')
                          order by version_no desc limit 1) p on true
     where c.venue_id = vn.id and c.retired_at is null and c.handling in ('work_approval', 'permit')
     order by c.handling = 'permit', c.name
  loop
    if r.handling = 'work_approval' then n := n + 1; end if;
    items := items || core.setup_versioned(vn, 'class:' || r.id, 'Work and permits',
      case when r.handling = 'permit' then 'Permit class: ' || r.name when r.name ilike '%work approval%' then r.name else 'Work Approval: ' || r.name end,
      case r.handling when 'work_approval' then 'Every job that needs any permit has a Work Approval; it cannot be used until its configuration is approved.'
                      else 'Jobs needing this permit cannot be submitted until its configuration is approved.' end,
      r.version_no, r.decided_at, r.decided_by_person_id, r.p_status, r.p_no, admin_drafts, 'permit_class_version.approve', '/venue/permits');
  end loop;
  if n = 0 then
    items := items || core.setup_item(vn, 'class:work_approval', 'Work and permits', 'Work Approval',
      'Every job that needs any permit has a Work Approval.', 'not_set_up', null, null, null,
      'A tenant administrator adds the class; someone appointed to approve permit classes approves its configuration.',
      'permit_class_version.approve', '/venue/permits');
  end if;

  for r in
    select t.id, t.label as name,
           (select max(c.effective_from) from core.system_control_rule c where c.system_type_id = t.id and c.kind = 'isolation' and c.effective_from <= now()) iso,
           (select max(c.effective_from) from core.system_control_rule c where c.system_type_id = t.id and c.kind = 'impairment' and c.effective_from <= now()) imp
      from core.system_type t
     where t.venue_id = vn.id and t.retired_at is null
       and exists (select 1 from core.system s where s.system_type_id = t.id and s.retired_at is null)
     order by t.label
  loop
    items := items || core.setup_item(vn, 'controls:' || r.id, 'Work and permits', 'Isolation and impairment rules: ' || r.name,
      'A system of this type cannot be isolated or impaired until the rules for that kind of control are published.',
      case when r.iso is not null or r.imp is not null then 'recorded' else 'not_set_up' end,
      case when r.iso is not null or r.imp is not null then
        concat_ws('; ', case when r.iso is not null then 'Isolation rules published' else 'No isolation rules' end,
                        case when r.imp is not null then 'impairment rules published' else 'no impairment rules' end) end,
      null, null, 'Someone appointed to publish control rules publishes them.', 'control_rule.publish', '/controls');
  end loop;

  select c.effective_from, c.owner_person_id into r from core.emergency_config_version c
   where c.venue_id = vn.id and c.effective_from <= now() order by c.effective_from desc, c.created_at desc limit 1;
  items := items || core.setup_published(vn, 'emergency_config', 'Work and permits', 'Emergency work categories',
    'Emergency and urgent make-safe work can be authorised only in the categories the venue publishes, with its deadline for the retrospective permit.',
    r.effective_from, r.owner_person_id,
    (select min(c.effective_from) from core.emergency_config_version c where c.venue_id = vn.id and c.effective_from > now()),
    'Someone appointed to publish them publishes them.', 'emergency_config.publish', '/controls');

  select c.effective_from, c.owner_person_id into r from core.venue_emergency_contacts c
   where c.venue_id = vn.id and c.effective_from <= now() order by c.effective_from desc, c.created_at desc limit 1;
  items := items || core.setup_published(vn, 'emergency_contacts', 'Work and permits', 'Emergency contacts',
    'Shown on every live permit (CLAUDE.md §6). Publish them before go-live (6d-1).',
    r.effective_from, r.owner_person_id,
    (select min(c.effective_from) from core.venue_emergency_contacts c where c.venue_id = vn.id and c.effective_from > now()),
    'A tenant administrator publishes them.', null, '/controls');

  -- Inductions -----------------------------------------------------------------------------
  n := 0;
  for r in
    select c.id, c.title,
           (select v.version_no from core.course_version v where v.course_id = c.id and v.status = 'published' order by v.version_no desc limit 1) pub_no,
           (select v.published_at from core.course_version v where v.course_id = c.id and v.status = 'published' order by v.version_no desc limit 1) pub_at,
           (select v.published_by_person_id from core.course_version v where v.course_id = c.id and v.status = 'published' order by v.version_no desc limit 1) pub_by,
           (select v.status from core.course_version v where v.course_id = c.id and v.status in ('draft', 'in_review') order by v.version_no desc limit 1) p_status,
           (select v.version_no from core.course_version v where v.course_id = c.id and v.status in ('draft', 'in_review') order by v.version_no desc limit 1) p_no
      from core.induction_course c where c.venue_id = vn.id order by c.title
  loop
    n := n + 1;
    items := items || core.setup_versioned(vn, 'course:' || r.id, 'Inductions', 'Induction: ' || r.title,
      'Entry rules and permits can require it; no one can complete it until a version is published.',
      r.pub_no, r.pub_at, r.pub_by, case r.p_status when 'in_review' then 'proposed' else r.p_status end, r.p_no,
      'An author drafts it and submits it; someone appointed to publish inductions publishes it.', 'course_version.publish', '/venue/inductions');
  end loop;
  if n = 0 then
    items := items || core.setup_item(vn, 'courses', 'Inductions', 'Induction courses',
      'Entry rules and permits can require inductions.', 'not_set_up', null, null, null,
      'A tenant administrator creates a course; someone appointed to publish inductions publishes it.', 'course_version.publish', '/venue/inductions');
  end if;

  -- Gate and visits ------------------------------------------------------------------------
  select a.version_no, a.decided_at, a.decided_by_person_id, p.status as p_status, p.version_no as p_no into r
    from (select 1) one
    left join core.entry_rule_version a on a.venue_id = vn.id and a.status = 'approved'
    left join lateral (select status, version_no from core.entry_rule_version where venue_id = vn.id and status in ('draft', 'proposed')
                        order by version_no desc limit 1) p on true;
  items := items || core.setup_versioned(vn, 'entry_rules', 'Gate and visits', 'Entry rules',
    'The gate cannot admit anyone until the venue''s entry rules are approved.',
    r.version_no, r.decided_at, r.decided_by_person_id, r.p_status, r.p_no, admin_drafts, 'entry_rule_version.approve', '/venue/entry');

  select count(*) into n from core.gate_point g where g.venue_id = vn.id and g.retired_at is null;
  items := items || core.setup_item(vn, 'gate_points', 'Gate and visits', 'Gate points',
    'Entry is checked, and gate staff are appointed, at gate points.',
    case when n > 0 then 'recorded' else 'not_set_up' end, case when n > 0 then format('%s in use', n) end, null, null,
    'A tenant administrator adds them.', null, '/venue/entry');

  items := items || core.setup_config(vn, 'outage_procedure', 'outage_procedure', 'Gate and visits', 'Outage procedure',
    'Gate staff follow it when Octra cannot be reached; manifests cannot be downloaded without its maximum age.',
    admin_drafts, 'venue_config.approve', '/venue/entry');
  items := items || core.setup_config(vn, 'access_purposes', 'access_purposes', 'Gate and visits', 'Access visit purposes',
    'Access visits can be requested only for a purpose the venue has approved.',
    admin_drafts, 'venue_config.approve', '/venue/entry');

  -- Notices and records --------------------------------------------------------------------
  items := items || core.setup_config(vn, 'chasing', 'chasing', 'Notices and records', 'Reminders and escalation',
    'Without it, nothing is chased; unresolved items stay unresolved and nobody is reminded.',
    admin_drafts, 'venue_config.approve', '/venue/chasing');
  items := items || core.setup_config(vn, 'retention', 'retention', 'Notices and records', 'Retention schedule',
    'Without it, records are kept and nothing is listed for disposal.',
    admin_drafts, 'retention.approve', '/venue/retention');

  return jsonb_build_object('ok', true, 'venue', jsonb_build_object('id', vn.id, 'name', vn.name, 'timezone', vn.timezone),
                            'items', items);
end $$;

grant execute on function api.venue_setup(uuid) to authenticated;
revoke execute on function api.venue_setup(uuid) from anon;
revoke execute on function core.setup_viewer(uuid), core.setup_holders(core.venue, text),
  core.setup_item(core.venue, text, text, text, text, text, text, timestamptz, text, text, text, text),
  core.setup_versioned(core.venue, text, text, text, text, integer, timestamptz, uuid, text, integer, text, text, text),
  core.setup_config(core.venue, text, text, text, text, text, text, text, text),
  core.setup_published(core.venue, text, text, text, text, timestamptz, uuid, timestamptz, text, text, text)
from public, anon, authenticated;
