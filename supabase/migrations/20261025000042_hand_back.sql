-- 0042 Hand-back, closure and emergency work (phase 6c, D-019): catalogue, states,
--      tables and rules
--
-- Invariant 8: a permit closes only through an accepted hand-back, and the database
-- refuses the closing write while any duty is outstanding: a control not removed,
-- restored or transferred, a fire watch not finished, an exclusion zone in place, a key or
-- pass still out, a personal lock on, or (for a Work Approval) a child permit still open.
-- A control that must stay after the work is transferred to a named owner, never dropped:
-- its links to the permits end, and it lives on as a separately owned control.
--
-- Expired and suspended permits close out through the same hand-back (P6-10). Abandoned
-- is a flag that closes nothing. Emergency work starts on an appointed authority's
-- recorded decision and must be followed by a retrospective permit by a deadline the
-- venue sets (P6-11); missing it approves nothing.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

-- ---------------------------------------------------------------------------
-- Catalogue
-- ---------------------------------------------------------------------------
insert into core.authority_action (code, basis, delegable, description) values
  ('permit.hand_back_submit',             'permit_part',        false, 'Hand back a permit, as its supervisor (Q113)'),
  ('permit.close_out_for_issuer',         'appointment',        false, 'Start the close-out of a stopped or expired permit whose contractor has gone (Q116)'),
  ('permit.hand_back_accept',             'appointment',        true,  'Accept or reject a hand-back, or a return of areas (Q114)'),
  ('permit.return_areas',                 'permit_part',        false, 'Hand back some of a permit''s areas while work continues (Q115)'),
  ('permit.cancel_issued',                'appointment',        false, 'Cancel an issued permit before it is accepted (Q117)'),
  ('permit.flag_abandoned',               'appointment',        false, 'Flag a stopped or expired job as abandoned (Q117)'),
  ('isolation.transfer',                  'appointment',        false, 'Take ownership of an isolation that must stay after the work (Q147)'),
  ('impairment.transfer',                 'appointment',        false, 'Take ownership of an impairment that cannot be restored yet (Q141)'),
  ('emergency_config.publish',            'appointment',        false, 'Publish the venue''s emergency work categories and deadline (Q91, Q97)'),
  ('emergency.authorise',                 'appointment',        false, 'Authorise emergency or urgent make-safe work to start (Q92)'),
  ('emergency.link_retrospective',        'organisation_admin', false, 'Link the job that is the retrospective permit for emergency work (Q97)'),
  ('emergency.link_retrospective_for_venue', 'tenant_admin',    false, 'Link the retrospective job for emergency work, for the venue');

insert into core.part_action (action_code, roles) values
  ('permit.hand_back_submit', array['supervisor']),
  ('permit.return_areas',     array['supervisor']);

insert into core.state_transition (machine, from_state, to_state, required_action)
select 'permit', f, 'hand_back_pending', a
  from unnest(array['active', 'suspended', 'expired']) f cross join unnest(array['permit.hand_back_submit']) a
union all
select 'permit', f, 'hand_back_pending', 'permit.close_out_for_issuer' from unnest(array['suspended', 'expired']) f
union all
select 'permit', 'hand_back_pending', t, 'permit.hand_back_accept' from unnest(array['closed', 'active', 'suspended', 'expired']) t
union all
select 'permit', 'issued_awaiting_acceptance', 'cancelled', 'permit.cancel_issued';

-- ---------------------------------------------------------------------------
-- Class configuration gains the hand-back declaration and inspection (Q113, Q114),
-- neither with a default.
--   hand_back_declaration: [text, ...]   hand_back_inspection: in_person | remote_allowed
-- ---------------------------------------------------------------------------
do $m$
declare d text;
begin
  d := pg_get_functiondef('core.validate_class_config(uuid,jsonb,boolean)'::regprocedure);
  if position(E'  return errs;\nend' in d) = 0 then
    raise exception 'core.validate_class_config no longer has the expected structure';
  end if;
  d := replace(d, E'  return errs;\nend', $r$  -- Hand-back (phase 6c).
  if p_content ? 'hand_back_declaration' and (jsonb_typeof(p_content -> 'hand_back_declaration') is distinct from 'array'
       or exists (select 1 from jsonb_array_elements(case when jsonb_typeof(p_content -> 'hand_back_declaration') = 'array'
                                                          then p_content -> 'hand_back_declaration' else '[]' end) hd
                   where jsonb_typeof(hd) <> 'string' or length(btrim(hd #>> '{}')) = 0)) then
    errs := errs || text 'Every hand-back declaration item needs wording.';
  end if;
  if p_content ? 'hand_back_inspection' and coalesce(p_content ->> 'hand_back_inspection', '') not in ('in_person', 'remote_allowed') then
    errs := errs || text 'Hand-back is inspected in person, or may be accepted remotely.';
  end if;
  if p_strict then
    if jsonb_array_length(coalesce(case when jsonb_typeof(p_content -> 'hand_back_declaration') = 'array' then p_content -> 'hand_back_declaration' end, '[]')) = 0 then
      errs := errs || text 'Write what the supervisor confirms at hand-back (Q113): there is no default.';
    end if;
    if not p_content ? 'hand_back_inspection' then
      errs := errs || text 'Choose whether hand-back must be inspected in person or may be accepted remotely (Q114).';
    end if;
  end if;
  return errs;
end$r$);
  execute d;
end $m$;

-- ---------------------------------------------------------------------------
-- Links end when a control is transferred: core.control_link now shows only current
-- links; every link ever made stays in core.control_link_record.
-- ---------------------------------------------------------------------------
alter table core.control_link rename to control_link_record;
alter table core.control_link_record
  add column unlinked_at timestamptz,
  add column unlinked_reason text,
  add column unlink_decision_context_id uuid references core.decision_context,
  add check ((unlinked_at is null) = (unlink_decision_context_id is null) and (unlinked_at is null) = (unlinked_reason is null));
alter table core.control_link_record drop constraint control_link_control_kind_control_id_permit_id_key;
create unique index control_link_one_current on core.control_link_record (control_kind, control_id, permit_id) where unlinked_at is null;
drop trigger b_forbid_update on core.control_link_record;
create trigger b_guard_update before update on core.control_link_record
  for each row execute function core.guard_update('unlinked_at,unlinked_reason,unlink_decision_context_id');
create trigger c_bump_version before update on core.control_link_record for each row execute function core.bump_version();
create function core.unlink_once() returns trigger
language plpgsql set search_path = '' as $$
begin
  if old.unlinked_at is not null then
    raise exception 'a control link ends once' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger unlink_once before update on core.control_link_record for each row execute function core.unlink_once();
create view core.control_link as
  select id, customer_id, venue_id, control_kind, control_id, permit_id, linked_by_person_id, decision_context_id, row_version, created_at, created_by_user_id
    from core.control_link_record where unlinked_at is null;

-- Who owns a control that continues after the work (Q141, Q147).
create table core.control_ownership (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  venue_id             uuid not null,
  control_kind         text not null check (control_kind in ('isolation', 'impairment')),
  control_id           uuid not null,
  owner_person_id      uuid not null,
  reason               text not null check (length(btrim(reason)) > 0),
  review_on            date not null,
  decision_context_id  uuid not null references core.decision_context,
  row_version          integer not null default 1,
  created_at           timestamptz not null default clock_timestamp(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, owner_person_id) references core.person (customer_id, id)
);
select core.attach_standard_triggers('core.control_ownership', null);

-- ---------------------------------------------------------------------------
-- Hand-back (Q113-Q117)
-- ---------------------------------------------------------------------------
create table core.hand_back (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  venue_id              uuid not null,
  permit_id             uuid not null,
  from_status           text not null check (from_status in ('active', 'suspended', 'expired')),
  route                 text not null check (route in ('supervisor', 'issuer_close_out')),
  declaration           jsonb not null,
  declaration_sha256    bytea not null check (length(declaration_sha256) = 32),
  work_complete         boolean not null,
  remaining_work        text,
  area_state            text not null check (length(btrim(area_state)) > 0),
  all_workers_out       boolean not null check (all_workers_out),
  submitted_by_person_id uuid not null,
  decision_context_id   uuid not null references core.decision_context,
  row_version           integer not null default 1,
  created_at            timestamptz not null default clock_timestamp(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, venue_id, permit_id) references core.permit (customer_id, venue_id, id),
  foreign key (customer_id, submitted_by_person_id) references core.person (customer_id, id),
  unique (customer_id, venue_id, id),
  check (work_complete or length(btrim(coalesce(remaining_work, ''))) > 0)
);
select core.attach_standard_triggers('core.hand_back', null);

create table core.hand_back_decision (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  venue_id             uuid not null,
  hand_back_id         uuid not null unique,
  outcome              text not null check (outcome in ('accepted', 'rejected')),
  inspection           text not null check (inspection in ('in_person', 'remote')),
  reason               text not null check (length(btrim(reason)) > 0),
  decider_person_id    uuid not null,
  decision_context_id  uuid not null references core.decision_context,
  row_version          integer not null default 1,
  created_at           timestamptz not null default clock_timestamp(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, venue_id, hand_back_id) references core.hand_back (customer_id, venue_id, id),
  foreign key (customer_id, decider_person_id) references core.person (customer_id, id)
);
select core.attach_standard_triggers('core.hand_back_decision', null);

-- Partial hand-back of areas (Q115, P6-12): the supervisor returns areas, the acceptor
-- accepts or rejects; the live scope only ever narrows.
create table core.area_return (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  venue_id              uuid not null,
  permit_id             uuid not null,
  area_ids              uuid[] not null check (cardinality(area_ids) > 0),
  area_state            text not null check (length(btrim(area_state)) > 0),
  submitted_by_person_id uuid not null,
  decision_context_id   uuid not null references core.decision_context,
  outcome               text check (outcome in ('accepted', 'rejected')),
  decided_by_person_id  uuid,
  decision_reason       text,
  decided_at            timestamptz,
  decided_decision_context_id uuid references core.decision_context,
  row_version           integer not null default 1,
  created_at            timestamptz not null default clock_timestamp(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, venue_id, permit_id) references core.permit (customer_id, venue_id, id),
  foreign key (customer_id, submitted_by_person_id) references core.person (customer_id, id),
  foreign key (customer_id, decided_by_person_id) references core.person (customer_id, id),
  check ((outcome is null) = (decided_by_person_id is null) and (outcome is null) = (decided_at is null)
         and (outcome is null) = (decided_decision_context_id is null) and (outcome is null) = (decision_reason is null))
);
select core.attach_standard_triggers('core.area_return', 'outcome,decided_by_person_id,decision_reason,decided_at,decided_decision_context_id');
create function core.area_return_once() returns trigger
language plpgsql set search_path = '' as $$
begin
  if old.outcome is not null then
    raise exception 'a return of areas is decided once' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger area_return_once before update on core.area_return for each row execute function core.area_return_once();

-- Abandoned (Q117): a flag on a stopped or expired job. It closes nothing.
create table core.permit_abandonment (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  venue_id             uuid not null,
  permit_id            uuid not null,
  reason               text not null check (length(btrim(reason)) > 0),
  flagged_by_person_id uuid not null,
  decision_context_id  uuid not null references core.decision_context,
  row_version          integer not null default 1,
  created_at           timestamptz not null default clock_timestamp(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, venue_id, permit_id) references core.permit (customer_id, venue_id, id),
  foreign key (customer_id, flagged_by_person_id) references core.person (customer_id, id)
);
select core.attach_standard_triggers('core.permit_abandonment', null);

-- The close-out snapshot (invariant 5): everything the closure relied on, frozen.
create table core.close_out_snapshot (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  venue_id             uuid not null,
  permit_id            uuid not null unique,
  content              jsonb not null,
  content_sha256       bytea not null check (length(content_sha256) = 32),
  decision_context_id  uuid not null references core.decision_context,
  row_version          integer not null default 1,
  created_at           timestamptz not null default clock_timestamp(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, venue_id, permit_id) references core.permit (customer_id, venue_id, id)
);
select core.attach_standard_triggers('core.close_out_snapshot', null);

-- ---------------------------------------------------------------------------
-- Emergency work (Q91, Q92, Q94-Q97, P6-11)
-- ---------------------------------------------------------------------------
-- The venue's own definitions and deadline: immutable versions, no default.
create table core.emergency_config_version (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  venue_id             uuid not null,
  categories           text[] not null check (cardinality(categories) > 0),
  retrospective_hours  numeric not null check (retrospective_hours > 0),
  owner_person_id      uuid not null,
  effective_from       timestamptz not null,
  change_reason        text not null check (length(btrim(change_reason)) > 0),
  decision_context_id  uuid not null references core.decision_context,
  row_version          integer not null default 1,
  created_at           timestamptz not null default clock_timestamp(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, owner_person_id) references core.person (customer_id, id)
);
select core.attach_standard_triggers('core.emergency_config_version', null);

create table core.emergency_work (
  id                     uuid primary key default gen_random_uuid(),
  customer_id            uuid not null,
  venue_id               uuid not null,
  reference              text not null,
  config_version_id      uuid not null references core.emergency_config_version,
  category               text not null,
  description            text not null check (length(btrim(description)) > 0),
  why_could_not_wait     text not null check (length(btrim(why_could_not_wait)) > 0),
  area_ids               uuid[] not null check (cardinality(area_ids) > 0),
  system_ids             uuid[] not null,
  organisation_id        uuid not null,
  person_ids             uuid[] not null check (cardinality(person_ids) > 0),
  controls_applied       text not null check (length(btrim(controls_applied)) > 0),
  authorised_by_person_id uuid not null,
  deadline_at            timestamptz not null,
  decision_context_id    uuid not null references core.decision_context,
  work_package_id        uuid,
  linked_by_person_id    uuid,
  linked_at              timestamptz,
  link_decision_context_id uuid references core.decision_context,
  row_version            integer not null default 1,
  created_at             timestamptz not null default clock_timestamp(),
  created_by_user_id     uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, organisation_id) references core.organisation (customer_id, id),
  foreign key (customer_id, authorised_by_person_id) references core.person (customer_id, id),
  foreign key (customer_id, venue_id, work_package_id) references core.work_package (customer_id, venue_id, id),
  unique (venue_id, reference),
  check ((work_package_id is null) = (linked_at is null) and (work_package_id is null) = (link_decision_context_id is null)
         and (work_package_id is null) = (linked_by_person_id is null))
);
create unique index emergency_one_per_job on core.emergency_work (work_package_id) where work_package_id is not null;
select core.attach_standard_triggers('core.emergency_work', 'work_package_id,linked_by_person_id,linked_at,link_decision_context_id');
create function core.emergency_link_once() returns trigger
language plpgsql set search_path = '' as $$
begin
  if old.work_package_id is not null then
    raise exception 'emergency work is linked to its retrospective job once' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger emergency_link_once before update on core.emergency_work for each row execute function core.emergency_link_once();

-- Whether the retrospective permit is in, and if not, whether it is overdue (Q97). The
-- deadline approves nothing: overdue is shown with its owner.
create function core.emergency_status(e core.emergency_work) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'retrospective_submitted', exists (select 1 from core.permit p join core.permit_version v on v.permit_id = p.id
                                        where p.work_package_id = e.work_package_id),
    'overdue', now() > e.deadline_at and not exists (select 1 from core.permit p join core.permit_version v on v.permit_id = p.id
                                                       where p.work_package_id = e.work_package_id)) $$;

-- The emergency's authoriser is connected with the retrospective job: they cannot decide
-- its steps or issue it (invariant 3).
create or replace function core.permit_people(p_permit_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select core.work_package_people(p.work_package_id)
         || coalesce((select jsonb_agg(distinct v.declared_by_person_id) from core.permit_version v where v.permit_id = p.id), '[]')
         || coalesce((select jsonb_agg(e.authorised_by_person_id) from core.emergency_work e where e.work_package_id = p.work_package_id), '[]')
    from core.permit p where p.id = p_permit_id $$;

-- ---------------------------------------------------------------------------
-- Outstanding duties (invariant 8): computed from the records, never ticked off.
-- ---------------------------------------------------------------------------
create function core.hand_back_duties(p_permit_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare p core.permit; d jsonb := '[]'; x record; cfg jsonb;
begin
  select * into p from core.permit where id = p_permit_id;
  for x in select i.status, y.name from core.control_link l join core.isolation i on i.id = l.control_id join core.system y on y.id = i.system_id
            where l.permit_id = p.id and l.control_kind = 'isolation' and i.status in ('requested', 'authorised', 'applied', 'proved') loop
    d := d || jsonb_build_object('duty', 'isolation', 'problem',
      format('The isolation of %s is %s: remove it, withdraw it, or transfer it to an owner if it must stay.', x.name, x.status),
      'who', format('The isolation authority for %s', x.name));
  end loop;
  for x in select i.status, y.name from core.control_link l join core.impairment i on i.id = l.control_id join core.system y on y.id = i.system_id
            where l.permit_id = p.id and l.control_kind = 'impairment' and i.status in ('requested', 'authorised', 'impaired', 'tested') loop
    d := d || jsonb_build_object('duty', 'impairment', 'problem',
      format('The impairment of %s is %s: restore it, withdraw it, or transfer it to an owner if it cannot be restored yet.', x.name, x.status),
      'who', format('The impairment authority for %s', x.name));
  end loop;
  for x in select k.lock_ref, core.person_name(k.person_id) as name from core.control_link l join core.isolation_lock k on k.isolation_id = l.control_id
            where l.permit_id = p.id and l.control_kind = 'isolation' and k.off_at is null loop
    d := d || jsonb_build_object('duty', 'lock', 'problem', format('%s''s personal lock %s is still on.', x.name, x.lock_ref),
                                 'who', format('%s, or the isolation authority', x.name));
  end loop;
  for x in select w.phase, core.person_name(w.watcher_person_id) as name from core.fire_watch w where w.permit_id = p.id and w.status <> 'ended' loop
    d := d || jsonb_build_object('duty', 'fire_watch', 'problem', format('The fire watch %s the work (%s) has not finished.',
                                 case x.phase when 'during' then 'during' else 'after' end, x.name), 'who', 'The supervisor');
  end loop;
  cfg := (select k from jsonb_array_elements(coalesce(core.permit_class_controls(p), '[]')) k where k ->> 'kind' = 'fire_watch');
  if cfg is not null and core.last_accepted_at(p.id) is not null
     and not exists (select 1 from core.fire_watch w where w.permit_id = p.id and w.phase = 'post' and w.status = 'ended') then
    d := d || jsonb_build_object('duty', 'fire_watch', 'problem', 'The fire watch after the work has not been completed (Q134).', 'who', 'The supervisor');
  end if;
  for x in select z.description from core.exclusion_zone z where z.permit_id = p.id and z.status = 'set_up' loop
    d := d || jsonb_build_object('duty', 'exclusion_zone', 'problem', format('The exclusion zone (%s) is still in place.', x.description), 'who', 'The supervisor');
  end loop;
  for x in select c.label, c.reference, core.person_name(m.holder_person_id) as holder from core.custody_movement m join core.custody_item c on c.id = m.item_id
            where m.permit_id = p.id and m.returned_at is null loop
    d := d || jsonb_build_object('duty', 'custody', 'problem', format('%s (%s) is still out, held by %s.', x.label, x.reference, x.holder),
                                 'who', format('%s, returning it to the key controller', x.holder));
  end loop;
  if p.kind = 'work_approval' then
    for x in select pc.name, c.status from core.permit c join core.permit_class pc on pc.id = c.permit_class_id
              where c.parent_permit_id = p.id and c.status not in ('closed', 'cancelled', 'refused')
                and not (c.status = 'expired' and core.last_accepted_at(c.id) is null and jsonb_array_length(core.hand_back_duties_own(c.id)) = 0) loop
      d := d || jsonb_build_object('duty', 'child', 'problem', format('The %s permit is %s, not closed.', x.name, replace(x.status, '_', ' ')),
                                   'who', 'Its supervisor and the hand-back acceptor');
    end loop;
  end if;
  return d;
end $$;

-- A permit's own duties, without its children (used to tell whether an expired child
-- that never started has anything left to close).
create function core.hand_back_duties_own(p_permit_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(core.hand_back_duties(p_permit_id)) x where x ->> 'duty' <> 'child' $$;

-- The closing write itself is refused while anything is outstanding, whoever asks.
create function core.closure_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare d jsonb;
begin
  if new.status = 'closed' and old.status is distinct from 'closed' then
    d := core.hand_back_duties(new.id);
    if jsonb_array_length(d) > 0 then
      raise exception 'a permit cannot close while duties are outstanding: %', d ->> 0 using errcode = 'check_violation';
    end if;
    if not exists (select 1 from core.hand_back h join core.hand_back_decision x on x.hand_back_id = h.id
                    where h.permit_id = new.id and x.outcome = 'accepted' and x.decision_context_id = core.ctx_uuid('decision_context_id')) then
      raise exception 'a permit closes only through an accepted hand-back' using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $$;
create trigger closure_guard before update of status on core.permit for each row execute function core.closure_guard();

-- ---------------------------------------------------------------------------
-- Visibility and RLS
-- ---------------------------------------------------------------------------
create or replace function authz.visible_work_package_ids() returns setof uuid
language sql stable security definer
set search_path = ''
as $$
  select wp.id from core.work_package wp
   where wp.customer_id in (select authz.my_admin_customer_ids())
      or exists (select 1 from unnest(array['screening.decide', 'external_reference.decide', 'work_package.require_class',
                                            'permit_step.decide', 'permit_step.decide_occupier', 'permit_step.decide_landlord',
                                            'permit_step.record_external', 'permit.issue', 'permit.exception_decide',
                                            'permit.stop_as_authority', 'permit.stop_area', 'permit.lift_area_stop',
                                            'permit.lift_suspension', 'permit.extend', 'permit.approve_worker',
                                            'permit.exclude_worker_as_authority', 'permit.change_supervisor',
                                            'isolation.authorise', 'isolation.apply', 'isolation.prove', 'isolation.remove',
                                            'impairment.authorise', 'impairment.impair', 'impairment.test', 'impairment.restore',
                                            'control.lift_failure', 'custody.issue', 'permit.hand_back_accept', 'permit.close_out_for_issuer',
                                            'permit.cancel_issued', 'permit.flag_abandoned', 'emergency.authorise']) a
                  where wp.venue_id in (select authz.my_action_venue_ids(a)))
      or exists (select 1 from core.permit p join core.permit_team_member m on m.permit_id = p.id
                  where p.work_package_id = wp.id and m.removed_at is null and m.person_id in (select authz.my_person_ids()))
      or wp.performing_organisation_id in (select authz.my_admin_organisation_ids())
      or exists (select 1 from core.work_package_revision r
                   join core.work_package_party p on p.revision_id = r.id
                  where r.work_package_id = wp.id
                    and p.organisation_id in (select authz.my_admin_organisation_ids()))
      or exists (select 1 from core.work_package_revision r
                  where r.work_package_id = wp.id
                    and (r.contact_person_id in (select authz.my_person_ids())
                         or r.supervisor_person_id in (select authz.my_person_ids())))
$$;

grant select on core.control_ownership, core.hand_back, core.hand_back_decision, core.area_return, core.permit_abandonment,
                core.close_out_snapshot, core.emergency_config_version, core.emergency_work to authenticated;

create policy control_ownership_read on core.control_ownership for select to authenticated
  using ((control_kind = 'isolation' and control_id in (select id from core.isolation))
         or (control_kind = 'impairment' and control_id in (select id from core.impairment)));
create policy hand_back_read on core.hand_back for select to authenticated using (permit_id in (select authz.visible_permit_ids()));
create policy hand_back_decision_read on core.hand_back_decision for select to authenticated
  using (hand_back_id in (select id from core.hand_back));
create policy area_return_read on core.area_return for select to authenticated using (permit_id in (select authz.visible_permit_ids()));
create policy abandonment_read on core.permit_abandonment for select to authenticated using (permit_id in (select authz.visible_permit_ids()));
create policy close_out_read on core.close_out_snapshot for select to authenticated using (permit_id in (select authz.visible_permit_ids()));
create policy venue_scoped_read on core.emergency_config_version for select to authenticated using (venue_id in (select authz.my_venue_ids()));
-- Emergency records: the venue, and the organisation that did the work.
create policy emergency_read on core.emergency_work for select to authenticated
  using (customer_id in (select authz.my_admin_customer_ids()) or venue_id in (select authz.my_appointee_venue_ids())
         or organisation_id in (select authz.my_admin_organisation_ids()));
