-- 0068 Events and evidence settings screens (S1c, D-026)
--
-- What the S1c screens need that the API did not have:
--   - An event phase must fall within its event's dates (§8 said so; nothing checked it), and
--     neither an event nor a phase may be empty (equal start and end passed the existing checks).
--   - Review criteria: each criterion needs a code and a label that are not blank, and codes are
--     unique within a version. A reviewer records one result per code, so a repeated code made
--     the results ambiguous.
--   - Refusals in words, instead of a constraint error, for: an event or phase ending before it
--     starts, a phase outside its event or overlapping another of the same kind, a code already
--     used (events, document types, evidence requirements), and asking an organisation for a
--     competency.
--   - Reads for the two screens: api.events_overview and api.evidence_settings.
--   - The set-up page lists evidence requirements (S1-10). "None defined" is a recorded state of
--     its own, not an open item: a venue with no requirements asks for no evidence, and the page
--     makes that visible. Document types with no review criteria in force are listed as pending,
--     because their documents cannot be reviewed.
--
-- No new catalogue actions: creating and publishing these records is tenant administration that
-- already exists (0013, 0022).
--
-- Rollback / recovery: forward-only. To withdraw, restore api.create_event and
-- api.add_event_phase from 0024, the document type and evidence requirement functions from 0018,
-- core.setup_item from 0065 and api.venue_setup from 0067; drop the two reads, the triggers and the
-- check constraints. No recorded data changes.

-- Events --------------------------------------------------------------------------------------
alter table core.event add constraint event_not_empty check (not isempty(valid_during));
alter table core.event_phase add constraint event_phase_not_empty check (not isempty(valid_during));

create function core.event_phase_within_event() returns trigger
language plpgsql set search_path = '' as $$
begin
  if not exists (select 1 from core.event e where e.id = new.event_id and e.valid_during @> new.valid_during) then
    raise exception 'a phase must fall within its event''s dates' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger event_phase_within_event before insert on core.event_phase
  for each row execute function core.event_phase_within_event();

create or replace function api.create_event(p_idempotency_key text, p_venue_id uuid, p_code text, p_name text,
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
  if p_starts is null or p_ends is null or p_ends <= p_starts then
    raise exception 'an event must end after it starts' using errcode = '22023';
  end if;
  if exists (select 1 from core.event e where e.venue_id = p_venue_id and e.code = p_code) then
    raise exception 'that code is already used by another event at this venue' using errcode = '22023';
  end if;
  insert into core.event (id, customer_id, venue_id, code, name, valid_during)
  values (v_id, v_customer, p_venue_id, p_code, p_name, tstzrange(p_starts, p_ends));
  return v;
end $$;

create or replace function api.add_event_phase(p_idempotency_key text, p_event_id uuid, p_phase text,
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
  if p_starts is null or p_ends is null or p_ends <= p_starts then
    raise exception 'a phase must end after it starts' using errcode = '22023';
  end if;
  if not e.valid_during @> tstzrange(p_starts, p_ends) then
    raise exception 'a phase must fall within its event''s dates' using errcode = '22023';
  end if;
  if exists (select 1 from core.event_phase p where p.event_id = e.id and p.phase = p_phase
                and p.valid_during && tstzrange(p_starts, p_ends)) then
    raise exception 'this event already has a % phase at those times', p_phase using errcode = '22023';
  end if;
  insert into core.event_phase (id, customer_id, venue_id, event_id, phase, valid_during)
  values (v_id, e.customer_id, e.venue_id, p_event_id, p_phase, tstzrange(p_starts, p_ends));
  return v;
end $$;

-- Evidence settings --------------------------------------------------------------------------
create function core.review_criteria_shape() returns trigger
language plpgsql set search_path = '' as $$
begin
  if exists (select 1 from jsonb_array_elements(new.criteria) c
              where jsonb_typeof(c) <> 'object'
                 or jsonb_typeof(c -> 'code') is distinct from 'string' or btrim(c ->> 'code') = ''
                 or jsonb_typeof(c -> 'label') is distinct from 'string' or btrim(c ->> 'label') = '') then
    raise exception 'each criterion needs a code and a label' using errcode = 'check_violation';
  end if;
  if (select count(distinct c ->> 'code') from jsonb_array_elements(new.criteria) c) <> jsonb_array_length(new.criteria) then
    raise exception 'each criterion needs its own code' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger review_criteria_shape before insert on core.review_criteria_version
  for each row execute function core.review_criteria_shape();

create or replace function api.create_document_type(p_idempotency_key text, p_venue_id uuid, p_code text, p_label text,
                                                    p_owner_level text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v_customer uuid := core.venue_customer(p_venue_id);
  v    jsonb;
begin
  v := authz.require('document_type.create',
         jsonb_build_object('customer_id', v_customer, 'venue_id', p_venue_id, 'record_id', v_id, 'target_type', 'document_type'),
         p_idempotency_key,
         jsonb_build_object('venue_id', p_venue_id, 'code', p_code, 'label', p_label, 'owner_level', p_owner_level));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  if exists (select 1 from core.document_type t where t.venue_id = p_venue_id and t.code = p_code) then
    raise exception 'that code is already used by another document type at this venue' using errcode = '22023';
  end if;
  insert into core.document_type (id, customer_id, venue_id, code, label, owner_level)
  values (v_id, v_customer, p_venue_id, p_code, p_label, p_owner_level);
  return v;
end $$;

create or replace function api.create_evidence_requirement(
  p_idempotency_key text, p_venue_id uuid, p_code text, p_label text, p_applies_to_kind text,
  p_capacity_code text, p_appointment_type_id uuid, p_requires_kind text, p_document_type_id uuid,
  p_competency_type_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v_customer uuid := core.venue_customer(p_venue_id);
  v    jsonb;
begin
  v := authz.require('evidence_requirement.create',
         jsonb_build_object('customer_id', v_customer, 'venue_id', p_venue_id, 'record_id', v_id,
                            'target_type', 'evidence_requirement'),
         p_idempotency_key,
         jsonb_build_object('venue_id', p_venue_id, 'code', p_code, 'label', p_label,
                            'applies_to_kind', p_applies_to_kind, 'capacity_code', p_capacity_code,
                            'appointment_type_id', p_appointment_type_id, 'requires_kind', p_requires_kind,
                            'document_type_id', p_document_type_id, 'competency_type_id', p_competency_type_id));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  if exists (select 1 from core.evidence_requirement r where r.venue_id = p_venue_id and r.code = p_code) then
    raise exception 'that code is already used by another evidence requirement at this venue' using errcode = '22023';
  end if;
  if p_applies_to_kind = 'engagement_capacity' and p_requires_kind = 'competency_type' then
    raise exception 'organisations hold documents, not competencies: ask for a document type' using errcode = '22023';
  end if;
  insert into core.evidence_requirement (id, customer_id, venue_id, code, label, applies_to_kind, capacity_code,
                                         appointment_type_id, requires_kind, document_type_id, competency_type_id)
  values (v_id, v_customer, p_venue_id, p_code, p_label, p_applies_to_kind, p_capacity_code, p_appointment_type_id,
          p_requires_kind, p_document_type_id, p_competency_type_id);
  return v;
end $$;

-- Reads ----------------------------------------------------------------------------------------
-- Where a version stands now: the latest already effective is current, later ones are
-- scheduled, earlier ones are superseded.
create function core.config_version_state(p_effective_from timestamptz, p_current_from timestamptz) returns text
language sql immutable set search_path = '' as $$
  select case when p_effective_from > now() then 'scheduled'
              when p_effective_from = p_current_from then 'current'
              else 'superseded' end
$$;

create function api.events_overview(p_venue_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  vn core.venue;
begin
  select * into vn from core.venue where id = p_venue_id;
  if vn.id is null or not core.setup_viewer(vn.id) then
    return jsonb_build_object('ok', false, 'reason', 'You are not an administrator or appointee at this venue.');
  end if;
  return jsonb_build_object('ok', true,
    'venue', jsonb_build_object('id', vn.id, 'name', vn.name, 'timezone', vn.timezone),
    'can_manage', vn.customer_id in (select authz.my_admin_customer_ids()),
    'events', (select coalesce(jsonb_agg(jsonb_build_object(
                 'id', e.id, 'code', e.code, 'name', e.name,
                 'starts', lower(e.valid_during), 'ends', upper(e.valid_during),
                 'ended', upper(e.valid_during) <= now(),
                 'phases', (select coalesce(jsonb_agg(jsonb_build_object(
                              'id', p.id, 'phase', p.phase, 'starts', lower(p.valid_during), 'ends', upper(p.valid_during))
                              order by lower(p.valid_during), p.phase), '[]')
                              from core.event_phase p where p.event_id = e.id),
                 'courses', (select count(*) from core.induction_course c where c.event_id = e.id),
                 'jobs', (select count(*) from core.work_package w where w.event_id = e.id))
               order by upper(e.valid_during) <= now(), lower(e.valid_during), e.name), '[]')
                 from core.event e where e.venue_id = vn.id));
end $$;

create function api.evidence_settings(p_venue_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  vn core.venue;
  admin boolean;
begin
  select * into vn from core.venue where id = p_venue_id;
  if vn.id is null or not core.setup_viewer(vn.id) then
    return jsonb_build_object('ok', false, 'reason', 'You are not an administrator or appointee at this venue.');
  end if;
  admin := vn.customer_id in (select authz.my_admin_customer_ids());
  return jsonb_build_object('ok', true,
    'venue', jsonb_build_object('id', vn.id, 'name', vn.name, 'timezone', vn.timezone),
    'can_manage', admin,
    'capacities', (select coalesce(jsonb_agg(jsonb_build_object('code', c.code, 'label', c.label) order by c.label), '[]')
                     from core.engagement_capacity c),
    'appointment_types', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name) order by t.name), '[]')
                            from core.appointment_type t where t.venue_id = vn.id and t.retired_at is null),
    'competency_types', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'code', t.code, 'label', t.label) order by t.label), '[]')
                           from core.competency_type t where t.venue_id = vn.id and t.retired_at is null),
    'document_types', (select coalesce(jsonb_agg(jsonb_build_object(
                         'id', t.id, 'code', t.code, 'label', t.label, 'owner_level', t.owner_level,
                         'criteria', (select coalesce(jsonb_agg(jsonb_build_object(
                                        'id', c.id, 'version_no', c.version_no, 'criteria', c.criteria,
                                        'owner', core.person_name(c.owner_person_id), 'effective_from', c.effective_from,
                                        'change_reason', c.change_reason,
                                        'state', core.config_version_state(c.effective_from, cur.effective_from))
                                        order by c.version_no desc), '[]')
                                        from core.review_criteria_version c
                                        left join lateral (select max(x.effective_from) effective_from from core.review_criteria_version x
                                                            where x.document_type_id = t.id and x.effective_from <= now()) cur on true
                                       where c.document_type_id = t.id))
                         order by t.label), '[]')
                         from core.document_type t where t.venue_id = vn.id and t.retired_at is null),
    'requirements', (select coalesce(jsonb_agg(jsonb_build_object(
                       'id', r.id, 'code', r.code, 'label', r.label,
                       'applies_to', case r.applies_to_kind
                                       when 'engagement_capacity' then 'Organisations engaged as ' || lower(cap.label)
                                       else 'People appointed as ' || apt.name end,
                       'requires', case r.requires_kind when 'document_type' then 'Document: ' || dt.label
                                                        else 'Competency: ' || ct.label end,
                       'in_force', coalesce((select v.in_force from core.evidence_requirement_version v
                                              where v.evidence_requirement_id = r.id and v.effective_from <= now()
                                              order by v.effective_from desc limit 1), false),
                       'versions', (select coalesce(jsonb_agg(jsonb_build_object(
                                      'version_no', v.version_no, 'in_force', v.in_force,
                                      'owner', core.person_name(v.owner_person_id), 'effective_from', v.effective_from,
                                      'change_reason', v.change_reason,
                                      'state', core.config_version_state(v.effective_from, cur.effective_from))
                                      order by v.version_no desc), '[]')
                                      from core.evidence_requirement_version v
                                      left join lateral (select max(x.effective_from) effective_from from core.evidence_requirement_version x
                                                          where x.evidence_requirement_id = r.id and x.effective_from <= now()) cur on true
                                     where v.evidence_requirement_id = r.id))
                       order by r.applies_to_kind, coalesce(cap.label, apt.name), r.label), '[]')
                       from core.evidence_requirement r
                       left join core.engagement_capacity cap on cap.code = r.capacity_code
                       left join core.appointment_type apt on apt.id = r.appointment_type_id
                       left join core.document_type dt on dt.id = r.document_type_id
                       left join core.competency_type ct on ct.id = r.competency_type_id
                      where r.venue_id = vn.id),
    -- Who can be named as the owner of a published version: the customer's current tenant
    -- administrators and the venue's appointees in force. Administrators only.
    'people', case when admin then
                (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', core.person_name(x.id))
                                           order by core.person_name(x.id)), '[]')
                   from (select ta.person_id id from core.tenant_admin ta
                          where ta.customer_id = vn.customer_id and ta.revoked_at is null and now() <@ ta.valid_during
                         union
                         select a.appointee_person_id from core.appointment a
                          where a.venue_id = vn.id and a.status = 'in_force' and now() <@ a.valid_during) x)
              else null end);
end $$;

-- Set-up page (S1-10) --------------------------------------------------------------------------
create or replace function core.setup_item(vn core.venue, p_key text, p_section text, p_name text, p_needed_for text,
                                           p_state text, p_detail text, p_in_force_from timestamptz, p_pending text,
                                           p_resolved_by text, p_action text, p_href text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'key', p_key, 'section', p_section, 'name', p_name, 'needed_for', p_needed_for, 'state', p_state,
    'state_words', case p_state when 'not_set_up' then 'Not set up' when 'draft' then 'Draft, not yet proposed'
                                when 'proposed' then 'Awaiting approval' when 'scheduled' then 'Published, not yet in force'
                                when 'in_force' then 'In force' when 'recorded' then 'Recorded'
                                when 'none_defined' then 'None defined' end,
    'detail', p_detail, 'in_force_from', p_in_force_from, 'pending', p_pending, 'resolved_by', p_resolved_by,
    'holders', case when p_action is null then null else core.setup_holders(vn, p_action) end,
    'holder_action', p_action, 'href', p_href)
$$;

-- What the venue asks for. Kept out of api.venue_setup's body so the patch below stays one line.
create function core.setup_evidence(vn core.venue) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  n_force integer;
  n_later integer;
  no_criteria text;
begin
  select count(*) filter (where (select v.in_force from core.evidence_requirement_version v
                                  where v.evidence_requirement_id = r.id and v.effective_from <= now()
                                  order by v.effective_from desc limit 1)),
         count(*) filter (where exists (select 1 from core.evidence_requirement_version v
                                         where v.evidence_requirement_id = r.id and v.effective_from > now()))
    into n_force, n_later
    from core.evidence_requirement r where r.venue_id = vn.id;
  select string_agg(t.label, ', ' order by t.label) into no_criteria
    from core.document_type t
   where t.venue_id = vn.id and t.retired_at is null
     and not exists (select 1 from core.review_criteria_version c where c.document_type_id = t.id and c.effective_from <= now());
  return core.setup_item(vn, 'evidence', 'Organisations and evidence', 'Evidence requirements',
    'Engagements and appointments are checked against them. With none defined, no evidence is asked for.',
    case when n_force > 0 then 'recorded' when n_later > 0 then 'scheduled' else 'none_defined' end,
    case when n_force > 0 then format('%s in force', n_force) else 'No evidence is asked of organisations or appointees' end,
    null,
    nullif(concat_ws(' ',
      case when n_later > 0 then format('%s with a version taking effect later.', n_later) end,
      case when no_criteria is not null then format('No review criteria in force for: %s. Their documents cannot be reviewed.', no_criteria) end), ''),
    'A tenant administrator defines them.', null, '/venue/evidence');
end $$;

do $$
declare
  d text;
  n text;
begin
  d := pg_get_functiondef('api.venue_setup(uuid)'::regprocedure);
  n := '  -- Work and permits ---';
  if position(n in d) = 0 then raise exception '0068: venue_setup anchor not found'; end if;
  d := replace(d, n, '  items := items || core.setup_evidence(vn);' || chr(10) || chr(10) || n);
  execute d;
end $$;

grant execute on function api.events_overview(uuid), api.evidence_settings(uuid) to authenticated;
revoke execute on function api.events_overview(uuid), api.evidence_settings(uuid) from anon;
revoke execute on function core.setup_evidence(core.venue), core.config_version_state(timestamptz, timestamptz)
from public, anon, authenticated;
