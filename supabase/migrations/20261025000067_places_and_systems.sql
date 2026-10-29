-- 0067 Places and systems screens (S1b, D-026)
--
-- What the S1b screens need that the API did not have:
--   - Retiring an area (S1-8) is refused, with the reasons in words, while anything still depends
--     on it. Until now only appointments, delegations and child areas were checked (0008), so an
--     area could be retired under a live permit, an open control or a gate point.
--   - Retiring a system (S1-9), refused while an isolation or impairment on it is not closed, an
--     open job names it, or an appointment or delegation in force is scoped to it.
--   - Ending an ownership record from a date, with a reason (S1-9). A record citing an engagement
--     must cite that organisation's engagement at the same venue (it was not checked).
--   - A retired area or system cannot be newly referred to by a scope, a link, an ownership
--     record, a control or a gate point. Issued records keep what they named.
--   - Retiring a gate point: a gate point blocks retiring its area, and there was no way to retire one.
--   - A read for the screen.
--
-- The checks live in core.area_retire_blockers and core.system_retire_blockers. The API returns
-- them as a refusal in words; the triggers on retired_at refuse the same update if anything
-- reaches it another way.
--
-- Rollback / recovery: forward-only. To withdraw, restore core.area_retire_guard from 0008 and
-- api.venue_setup from 0066, drop the new functions and triggers, and leave the new
-- system_ownership columns (they hold recorded decisions).

-- Catalogue --------------------------------------------------------------------------------
insert into core.authority_action (code, basis, delegable, description) values
  ('system.retire',          'tenant_admin', false, 'Retire a building system that nothing still depends on (S1-9)'),
  ('system_ownership.end',   'tenant_admin', false, 'End a system ownership record from a date, with a reason (S1-9)'),
  ('gate_point.retire',      'tenant_admin', false, 'Retire a gate point, so entry is no longer checked there');

-- What still depends on an area, in words. Empty when it can be retired.
create function core.area_retire_blockers(p_area_id uuid) returns text[]
language plpgsql stable security definer set search_path = '' as $$
declare
  a core.area;
  out text[] := '{}';
  n integer;
  names text;
  open_permit constant text[] := array['closed', 'cancelled', 'refused'];
begin
  select * into a from core.area where id = p_area_id;
  if a.id is null then return out; end if;

  select count(*), string_agg(c.name, ', ' order by c.name) into n, names
    from core.area c where c.parent_id = a.id and c.retired_at is null;
  if n > 0 then out := out || format('%s %s below it that %s not been retired (%s)', n,
                                     case when n = 1 then 'area' else 'areas' end, case when n = 1 then 'has' else 'have' end, names); end if;

  -- Jobs: one is open until it is cancelled, or its window has passed and none of its permits is still open.
  select count(*) into n
    from core.work_package w join core.work_package_area x on x.revision_id = w.current_revision_id
    join core.work_package_revision r on r.id = w.current_revision_id
   where x.area_id = a.id and w.status <> 'cancelled'
     and (upper(r.planned_window) > now()
          or exists (select 1 from core.permit p where p.work_package_id = w.id and p.status <> all (open_permit)));
  if n > 0 then out := out || format('%s open %s that %s it', n, case when n = 1 then 'job' else 'jobs' end,
                                     case when n = 1 then 'names' else 'name' end); end if;

  select count(*) into n
    from core.isolation i
   where i.status not in ('refused', 'withdrawn', 'returned')
     and exists (select 1 from core.system_area sa where sa.system_id = i.system_id and sa.area_id = a.id
                    and sa.valid_during @> now());
  if n > 0 then out := out || format('%s %s on a system serving it that %s not been returned', n,
                                     case when n = 1 then 'isolation' else 'isolations' end, case when n = 1 then 'has' else 'have' end); end if;

  select count(*) into n
    from core.impairment i
   where i.status not in ('refused', 'withdrawn', 'restored')
     and exists (select 1 from core.system_area sa where sa.system_id = i.system_id and sa.area_id = a.id
                    and sa.valid_during @> now());
  if n > 0 then out := out || format('%s %s on a system serving it that %s not been restored', n,
                                     case when n = 1 then 'impairment' else 'impairments' end, case when n = 1 then 'has' else 'have' end); end if;

  select count(*) into n
    from core.fire_watch f join core.permit p on p.id = f.permit_id
    join core.work_package w on w.id = p.work_package_id
    join core.work_package_area x on x.revision_id = w.current_revision_id
   where x.area_id = a.id and f.status <> 'ended';
  if n > 0 then out := out || format('%s fire %s for work in it that %s not ended', n,
                                     case when n = 1 then 'watch' else 'watches' end, case when n = 1 then 'has' else 'have' end); end if;

  select count(*) into n from core.exclusion_zone z where z.area_id = a.id and z.status <> 'removed';
  if n > 0 then out := out || format('%s exclusion %s in it that %s not been removed', n,
                                     case when n = 1 then 'zone' else 'zones' end, case when n = 1 then 'has' else 'have' end); end if;

  select count(*) into n from core.area_stop s
   where s.area_id = a.id and not exists (select 1 from core.area_stop_lift l where l.area_stop_id = s.id);
  if n > 0 then out := out || format('%s %s on it that %s not been lifted', n,
                                     case when n = 1 then 'stop' else 'stops' end, case when n = 1 then 'has' else 'have' end); end if;

  select count(*), string_agg(g.name, ', ' order by g.name) into n, names
    from core.gate_point g where g.area_id = a.id and g.retired_at is null;
  if n > 0 then out := out || format('%s gate %s in it (%s)', n, case when n = 1 then 'point' else 'points' end, names); end if;

  select count(*) into n from core.area_occupation o
   where o.area_id = a.id and o.ended_at is null and (upper_inf(o.valid_during) or upper(o.valid_during) > now());
  if n > 0 then out := out || format('%s current %s of it', n, case when n = 1 then 'occupation' else 'occupations' end); end if;

  select count(*) into n from core.access_authorisation v
   where a.id = any (v.area_ids) and v.status not in ('cancelled', 'refused', 'withdrawn') and upper(v.valid_during) > now();
  if n > 0 then out := out || format('%s access %s to it that %s not ended', n,
                                     case when n = 1 then 'visit' else 'visits' end, case when n = 1 then 'has' else 'have' end); end if;

  select count(*) into n from core.restriction_window rw
   where a.id = any (rw.area_ids) and rw.ended_at is null and upper(rw.during) > now();
  if n > 0 then out := out || format('%s restriction %s covering it that %s not ended', n,
                                     case when n = 1 then 'window' else 'windows' end, case when n = 1 then 'has' else 'have' end); end if;

  select count(*) into n from core.custody_item c where c.area_id = a.id and c.retired_at is null;
  if n > 0 then out := out || format('%s %s for it that %s not been retired', n,
                                     case when n = 1 then 'key or pass' else 'keys or passes' end, case when n = 1 then 'has' else 'have' end); end if;

  -- Appointments and delegations: any scope naming it, as 0008 already refused.
  select count(distinct ap.id) into n
    from core.appointment_scope s join core.appointment ap on ap.id = s.appointment_id
   where (s.area_id = a.id or s.restrict_to_area_id = a.id)
     and ap.status <> 'revoked' and (upper_inf(ap.valid_during) or upper(ap.valid_during) > now());
  if n > 0 then out := out || format('%s %s scoped to it', n, case when n = 1 then 'appointment' else 'appointments' end); end if;

  select count(distinct d.id) into n
    from core.delegation_scope s join core.delegation d on d.id = s.delegation_id
   where (s.area_id = a.id or s.restrict_to_area_id = a.id)
     and d.status <> 'revoked' and upper(d.valid_during) > now();
  if n > 0 then out := out || format('%s %s scoped to it', n, case when n = 1 then 'delegation' else 'delegations' end); end if;

  return out;
end $$;

create function core.system_retire_blockers(p_system_id uuid) returns text[]
language plpgsql stable security definer set search_path = '' as $$
declare
  out text[] := '{}';
  n integer;
begin
  select count(*) into n from core.isolation i
   where i.system_id = p_system_id and i.status not in ('refused', 'withdrawn', 'returned');
  if n > 0 then out := out || format('%s %s on it that %s not been returned', n,
                                     case when n = 1 then 'isolation' else 'isolations' end, case when n = 1 then 'has' else 'have' end); end if;

  select count(*) into n from core.impairment i
   where i.system_id = p_system_id and i.status not in ('refused', 'withdrawn', 'restored');
  if n > 0 then out := out || format('%s %s on it that %s not been restored', n,
                                     case when n = 1 then 'impairment' else 'impairments' end, case when n = 1 then 'has' else 'have' end); end if;

  select count(*) into n
    from core.work_package w join core.work_package_system x on x.revision_id = w.current_revision_id
    join core.work_package_revision r on r.id = w.current_revision_id
   where x.system_id = p_system_id and w.status <> 'cancelled'
     and (upper(r.planned_window) > now()
          or exists (select 1 from core.permit p where p.work_package_id = w.id and p.status not in ('closed', 'cancelled', 'refused')));
  if n > 0 then out := out || format('%s open %s that %s it', n, case when n = 1 then 'job' else 'jobs' end,
                                     case when n = 1 then 'names' else 'name' end); end if;

  select count(distinct ap.id) into n
    from core.appointment_scope s join core.appointment ap on ap.id = s.appointment_id
   where s.system_id = p_system_id and ap.status <> 'revoked' and (upper_inf(ap.valid_during) or upper(ap.valid_during) > now());
  if n > 0 then out := out || format('%s %s scoped to it', n, case when n = 1 then 'appointment' else 'appointments' end); end if;

  select count(distinct d.id) into n
    from core.delegation_scope s join core.delegation d on d.id = s.delegation_id
   where s.system_id = p_system_id and d.status <> 'revoked' and upper(d.valid_during) > now();
  if n > 0 then out := out || format('%s %s scoped to it', n, case when n = 1 then 'delegation' else 'delegations' end); end if;

  return out;
end $$;

-- The database refuses the update itself, whatever path reaches it.
create or replace function core.area_retire_guard() returns trigger
language plpgsql
set search_path = ''
as $$
declare b text[];
begin
  if new.retired_at is not null and old.retired_at is null then
    b := core.area_retire_blockers(new.id);
    if cardinality(b) > 0 then
      raise exception 'this area is still in use: %', array_to_string(b, '; ') using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $$;

create function core.system_retire_guard() returns trigger
language plpgsql
set search_path = ''
as $$
declare b text[];
begin
  if new.retired_at is not null and old.retired_at is null then
    b := core.system_retire_blockers(new.id);
    if cardinality(b) > 0 then
      raise exception 'this system is still in use: %', array_to_string(b, '; ') using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $$;
create trigger system_retire_guard before update of retired_at on core.system
  for each row execute function core.system_retire_guard();

-- Retiring is one way: nothing un-retires an area or a system.
create function core.forbid_unretire() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.retired_at is not null and new.retired_at is distinct from old.retired_at then
    raise exception '% is retired, and retiring cannot be undone: create a new one', tg_table_name using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger forbid_unretire before update of retired_at on core.area
  for each row execute function core.forbid_unretire();
create trigger forbid_unretire before update of retired_at on core.system
  for each row execute function core.forbid_unretire();

-- A retired area or system cannot be newly referred to.
create function core.refuse_retired_place() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  r jsonb := to_jsonb(new);
begin
  if exists (select 1 from core.area a where a.retired_at is not null
                and a.id in ((r ->> 'area_id')::uuid, (r ->> 'restrict_to_area_id')::uuid)) then
    raise exception 'that area has been retired' using errcode = 'check_violation';
  end if;
  if exists (select 1 from core.system s where s.retired_at is not null and s.id = (r ->> 'system_id')::uuid) then
    raise exception 'that system has been retired' using errcode = 'check_violation';
  end if;
  return new;
end $$;
do $$
declare t text;
begin
  foreach t in array array['appointment_scope', 'delegation_scope', 'system_area', 'system_ownership', 'isolation',
                           'impairment', 'gate_point', 'exclusion_zone', 'custody_item', 'area_occupation'] loop
    execute format('create trigger refuse_retired_place before insert on core.%I for each row execute function core.refuse_retired_place()', t);
  end loop;
end $$;

-- Ending ownership ---------------------------------------------------------------------------
alter table core.system_ownership
  add column ends_from          timestamptz,
  add column end_reason         text,
  add column ended_by_person_id uuid,
  add constraint system_ownership_end_check
    check ((ends_from is null) = (end_reason is null) and (ends_from is null) = (ended_by_person_id is null)
           and (end_reason is null or length(btrim(end_reason)) > 0)
           and (ends_from is null or ends_from > lower(valid_during))),
  add constraint system_ownership_ended_by_fk foreign key (customer_id, ended_by_person_id) references core.person (customer_id, id)
    deferrable initially immediate;

drop trigger b_guard_update on core.system_ownership;
create trigger b_guard_update before update on core.system_ownership
  for each row execute function core.guard_update('revoked_at,ends_from,end_reason,ended_by_person_id');

-- An ending is recorded once; it is not moved or withdrawn.
create function core.ownership_end_once() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.ends_from is not null and (new.ends_from, new.end_reason, new.ended_by_person_id)
                                   is distinct from (old.ends_from, old.end_reason, old.ended_by_person_id) then
    raise exception 'this ownership record has already been ended' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger ownership_end_once before update on core.system_ownership
  for each row execute function core.ownership_end_once();

-- An ownership record that cites an engagement cites that organisation's engagement at this venue.
create function core.ownership_engagement_check() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.engagement_id is not null and not exists (
       select 1 from core.engagement e where e.id = new.engagement_id
          and e.organisation_id = new.organisation_id and e.venue_id = new.venue_id) then
    raise exception 'that engagement is not this organisation''s engagement at this venue' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger ownership_engagement_check before insert on core.system_ownership
  for each row execute function core.ownership_engagement_check();

-- The period an ownership record actually covers.
create function core.ownership_period(o core.system_ownership) returns tstzrange
language sql immutable set search_path = '' as $$
  select case when o.ends_from is null then o.valid_during else o.valid_during * tstzrange(null, o.ends_from) end $$;

-- API --------------------------------------------------------------------------------------
create or replace function api.retire_area(p_idempotency_key text, p_area_id uuid, p_expected_version integer)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_area core.area;
  t      jsonb;
  r      jsonb;
  b      text[];
  v      jsonb;
begin
  select * into v_area from core.area where id = p_area_id for update;
  t := jsonb_build_object('customer_id', v_area.customer_id, 'venue_id', v_area.venue_id,
                          'record_id', p_area_id, 'target_type', 'area');
  r := jsonb_build_object('area_id', p_area_id, 'expected_version', p_expected_version);
  v := core.authorised_or_refusal('area.retire', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if v_area.parent_id is null then
    raise exception 'the venue''s root area cannot be retired' using errcode = 'check_violation';
  end if;
  if v_area.retired_at is null then
    b := core.area_retire_blockers(p_area_id);
    if cardinality(b) > 0 then
      return core.refuse('area.retire', 'in_use',
        'Something still depends on this area, so retiring it would leave live records pointing at a place that no longer exists.',
        'Each item listed to be closed, ended, moved or retired first', 'Whoever owns each item; for areas below it, you',
        jsonb_build_object('problems', to_jsonb(b)));
    end if;
  end if;
  v := authz.require('area.retire', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  perform core.check_version(v_area.row_version, p_expected_version);
  if v_area.retired_at is not null then
    raise exception 'this area has already been retired' using errcode = 'PT409';
  end if;
  update core.area set retired_at = now() where id = p_area_id;
  return v;
end $$;

create function api.retire_system(p_idempotency_key text, p_system_id uuid, p_expected_version integer)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  s core.system;
  t jsonb;
  r jsonb;
  b text[];
  v jsonb;
begin
  select * into s from core.system where id = p_system_id for update;
  t := jsonb_build_object('customer_id', s.customer_id, 'venue_id', s.venue_id, 'record_id', p_system_id, 'target_type', 'system');
  r := jsonb_build_object('system_id', p_system_id, 'expected_version', p_expected_version);
  v := core.authorised_or_refusal('system.retire', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if s.retired_at is null then
    b := core.system_retire_blockers(p_system_id);
    if cardinality(b) > 0 then
      return core.refuse('system.retire', 'in_use',
        'Something still depends on this system, so retiring it would leave live records pointing at a system that no longer exists.',
        'Each item listed to be closed, ended or moved first', 'Whoever owns each item',
        jsonb_build_object('problems', to_jsonb(b)));
    end if;
  end if;
  v := authz.require('system.retire', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  perform core.check_version(s.row_version, p_expected_version);
  if s.retired_at is not null then
    raise exception 'this system has already been retired' using errcode = 'PT409';
  end if;
  update core.system set retired_at = now() where id = p_system_id;
  return v;
end $$;

create function api.end_system_ownership(p_idempotency_key text, p_ownership_id uuid, p_expected_version integer,
                                         p_ends_from timestamptz, p_reason text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  o core.system_ownership;
  v jsonb;
begin
  select * into o from core.system_ownership where id = p_ownership_id for update;
  v := authz.require('system_ownership.end',
         jsonb_build_object('customer_id', o.customer_id, 'venue_id', o.venue_id, 'record_id', p_ownership_id,
                            'target_type', 'system_ownership'),
         p_idempotency_key,
         jsonb_build_object('ownership_id', p_ownership_id, 'expected_version', p_expected_version,
                            'ends_from', p_ends_from, 'reason', p_reason));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  perform core.check_version(o.row_version, p_expected_version);
  if length(btrim(coalesce(p_reason, ''))) = 0 then
    raise exception 'a reason is required to end an ownership record' using errcode = '22023';
  end if;
  if p_ends_from is null then
    raise exception 'say when the responsibility ends' using errcode = '22023';
  end if;
  if o.ends_from is not null or o.revoked_at is not null then
    raise exception 'this ownership record has already been ended' using errcode = 'PT409';
  end if;
  if p_ends_from <= lower(o.valid_during) then
    raise exception 'the end must be after the record starts' using errcode = '22023';
  end if;
  if not upper_inf(o.valid_during) and p_ends_from >= upper(o.valid_during) then
    raise exception 'this record already ends before that date' using errcode = '22023';
  end if;
  update core.system_ownership
     set ends_from = p_ends_from, end_reason = btrim(p_reason), ended_by_person_id = (v ->> 'actor_person_id')::uuid
   where id = o.id;
  return v;
end $$;

-- A gate point blocks retiring its area, so it needs a way to be retired itself. Scans at a
-- retired gate point are already refused (0046, 0051).
create function api.retire_gate_point(p_idempotency_key text, p_gate_point_id uuid, p_expected_version integer)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  g core.gate_point;
  v jsonb;
begin
  select * into g from core.gate_point where id = p_gate_point_id for update;
  v := authz.require('gate_point.retire',
         jsonb_build_object('customer_id', g.customer_id, 'venue_id', g.venue_id, 'record_id', p_gate_point_id, 'target_type', 'gate_point'),
         p_idempotency_key, jsonb_build_object('gate_point_id', p_gate_point_id, 'expected_version', p_expected_version));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  perform core.check_version(g.row_version, p_expected_version);
  if g.retired_at is not null then
    raise exception 'this gate point has already been retired' using errcode = 'PT409';
  end if;
  update core.gate_point set retired_at = now() where id = g.id;
  return v;
end $$;
create trigger forbid_unretire before update of retired_at on core.gate_point
  for each row execute function core.forbid_unretire();

-- Reads ------------------------------------------------------------------------------------
-- The places and systems of a venue, for its tenant administrators and appointees. Writes are
-- offered to tenant administrators; the database decides each one.
create function api.places_overview(p_venue_id uuid) returns jsonb
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
    'area_kinds', (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'code', k.code, 'label', k.label) order by k.label), '[]')
                     from core.area_kind k where k.venue_id = vn.id and k.retired_at is null),
    'areas', (select coalesce(jsonb_agg(jsonb_build_object(
                'id', a.id, 'row_version', a.row_version, 'code', a.code, 'name', a.name, 'parent_id', a.parent_id,
                'depth', cardinality(a.path) - 1, 'kind', k.label, 'retired_at', a.retired_at,
                'is_root', a.parent_id is null,
                'systems', (select coalesce(jsonb_agg(s.name order by s.name), '[]')
                              from core.system_area sa join core.system s on s.id = sa.system_id
                             where sa.area_id = a.id and sa.valid_during @> now() and s.retired_at is null))
              order by (select string_agg(lower(p.name), chr(1) order by i) from unnest(a.path) with ordinality u(pid, i)
                          join core.area p on p.id = u.pid)), '[]')
                from core.area a left join core.area_kind k on k.id = a.area_kind_id where a.venue_id = vn.id),
    'system_types', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'code', t.code, 'label', t.label) order by t.label), '[]')
                       from core.system_type t where t.venue_id = vn.id and t.retired_at is null),
    'systems', (select coalesce(jsonb_agg(jsonb_build_object(
                  'id', s.id, 'row_version', s.row_version, 'code', s.code, 'name', s.name, 'description', s.description,
                  'type', t.label, 'retired_at', s.retired_at,
                  'areas', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name) order by a.name), '[]')
                              from core.system_area sa join core.area a on a.id = sa.area_id
                             where sa.system_id = s.id and sa.valid_during @> now() and a.retired_at is null),
                  'ownership', (select coalesce(jsonb_agg(jsonb_build_object(
                      'id', o.id, 'row_version', o.row_version, 'responsibility', o.responsibility,
                      'organisation', coalesce(org.trading_name, org.legal_name),
                      'engagement', (select c.label from core.engagement e join core.engagement_capacity c on c.code = e.capacity_code
                                      where e.id = o.engagement_id),
                      'valid_from', lower(o.valid_during), 'valid_to', upper(core.ownership_period(o)),
                      'evidence_ref', o.evidence_ref, 'ends_from', o.ends_from, 'end_reason', o.end_reason,
                      'ended_by', core.person_name(o.ended_by_person_id),
                      'current', core.ownership_period(o) @> now() and o.revoked_at is null,
                      'ended', o.revoked_at is not null or (not upper_inf(core.ownership_period(o)) and upper(core.ownership_period(o)) <= now()))
                    order by lower(o.valid_during) desc), '[]')
                    from core.system_ownership o join core.organisation org on org.id = o.organisation_id where o.system_id = s.id))
                order by t.label, s.name), '[]')
                  from core.system s join core.system_type t on t.id = s.system_type_id where s.venue_id = vn.id),
    'organisations', case when vn.customer_id in (select authz.my_admin_customer_ids()) then
                       (select coalesce(jsonb_agg(jsonb_build_object(
                           'id', org.id, 'name', coalesce(org.trading_name, org.legal_name),
                           'engagements', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'capacity', c.label) order by c.label), '[]')
                                             from core.engagement e join core.engagement_capacity c on c.code = e.capacity_code
                                            where e.organisation_id = org.id and e.venue_id = vn.id and e.ended_at is null))
                         order by coalesce(org.trading_name, org.legal_name)), '[]')
                          from core.organisation org where org.customer_id = vn.customer_id and org.deactivated_at is null)
                     else null end);
end $$;

-- The set-up page (P4) now links areas and systems to their screen.
do $$
declare
  d text;
  n text;
begin
  d := pg_get_functiondef('api.venue_setup(uuid)'::regprocedure);
  n := $s$'A tenant administrator adds them. There is no screen for this yet.', null, null);$s$;
  if position(n in d) = 0 then raise exception '0067: venue_setup areas anchor not found'; end if;
  d := replace(d, n, $s$'A tenant administrator adds them.', null, '/venue/places');$s$);
  n := $s$'A tenant administrator registers them. There is no screen for this yet.', null, null);$s$;
  if position(n in d) = 0 then raise exception '0067: venue_setup systems anchor not found'; end if;
  d := replace(d, n, $s$'A tenant administrator registers them.', null, '/venue/places#systems');$s$);
  execute d;
end $$;

grant execute on function api.retire_system(text, uuid, integer), api.retire_gate_point(text, uuid, integer),
  api.end_system_ownership(text, uuid, integer, timestamptz, text), api.places_overview(uuid) to authenticated;
revoke execute on function api.retire_system(text, uuid, integer), api.retire_gate_point(text, uuid, integer),
  api.end_system_ownership(text, uuid, integer, timestamptz, text), api.places_overview(uuid) from anon;
revoke execute on function core.area_retire_blockers(uuid), core.system_retire_blockers(uuid)
from public, anon, authenticated;
