-- 0038 Live permits (phase 6a, D-019): catalogue, states, tables and the rules that keep
--      a live job consistent
--
-- Stopping work is deliberately wide (P6-2): anyone on the team, the job's occupier or
-- landlord, or a venue authority. Every stop is a suspension record that names, by its
-- kind, the only authority that can lift it (invariant 7). A permit leaves Suspended for
-- Active only after every suspension is lifted and the supervisor re-accepts at the
-- workface (P6-3); for Submitted only when a material change needs a reissue and nothing
-- else holds it (P6-4). Who is on the team after issue, extensions and revalidation are
-- each recorded decisions with their own history.
--
-- Invariant 4 while live, as a constraint trigger checked when each decision completes:
--   a child permit is Active only while its Work Approval is Active;
--   a Work Approval is Active only while no permit on its job has an unlifted suspension.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

-- ---------------------------------------------------------------------------
-- Catalogue
-- ---------------------------------------------------------------------------
alter table core.authority_action drop constraint authority_action_basis_check;
alter table core.authority_action add constraint authority_action_basis_check
  check (basis in ('appointment', 'tenant_admin', 'platform_admin', 'subject',
                   'organisation_admin', 'invitee', 'service', 'derived', 'link_holder', 'permit_part'));

insert into core.authority_action (code, basis, delegable, description) values
  ('permit.stop',                        'permit_part',        false, 'Stop work on a permit, as someone on its team (Q110)'),
  ('permit.stop_as_party',               'organisation_admin', false, 'Stop work on a permit, for the job''s occupier or landlord'),
  ('permit.stop_as_authority',           'appointment',        true,  'Stop work on a permit, as a venue authority'),
  ('permit.stop_area',                   'appointment',        true,  'Stop all work in an area'),
  ('permit.lift_area_stop',              'appointment',        true,  'Lift a stop on an area'),
  ('permit.lift_suspension',             'appointment',        true,  'Lift the suspension of a permit (invariant 7)'),
  ('permit.reaccept',                    'permit_part',        false, 'Re-brief the team and re-accept a suspended permit'),
  ('permit.suspend_with_job',            'derived',            false, 'Suspend a permit because work on its job or area was stopped'),
  ('permit.suspend_for_change',          'derived',            false, 'Suspend a live permit because its job changed materially'),
  ('permit.extend',                      'appointment',        false, 'Extend a live permit (Q108)'),
  ('permit.acknowledge_extension',       'permit_part',        false, 'Acknowledge an extension, as the supervisor'),
  ('permit.add_worker',                  'permit_part',        false, 'Add someone to a live permit''s team (Q106)'),
  ('permit.approve_worker',              'appointment',        true,  'Approve an addition to a live permit''s team'),
  ('permit.brief_worker',                'permit_part',        false, 'Record that an added team member has been briefed'),
  ('permit.exclude_worker',              'permit_part',        false, 'Remove someone from a live permit''s team, as the supervisor (Q107)'),
  ('permit.exclude_worker_as_authority', 'appointment',        true,  'Remove someone from a live permit''s team, as a venue authority'),
  ('permit.change_supervisor',           'appointment',        false, 'Change a live permit''s supervisor'),
  ('permit.revalidate',                  'permit_part',        false, 'Confirm a live permit''s work, conditions and controls are unchanged (Q112)');

-- Which team roles each permit-part action needs: resolved by authz.evaluate from the
-- live team, never from a job title.
create table core.part_action (
  action_code text primary key references core.authority_action,
  roles       text[] not null check (cardinality(roles) > 0 and roles <@ array['supervisor', 'operative'])
);
insert into core.part_action (action_code, roles) values
  ('permit.stop',                  array['supervisor', 'operative']),
  ('permit.reaccept',              array['supervisor']),
  ('permit.acknowledge_extension', array['supervisor']),
  ('permit.add_worker',            array['supervisor']),
  ('permit.brief_worker',          array['supervisor']),
  ('permit.exclude_worker',        array['supervisor']),
  ('permit.revalidate',            array['supervisor']);
alter table core.part_action enable row level security;
alter table core.part_action force row level security;
create trigger forbid_change before update or delete on core.part_action
  for each row execute function audit.forbid_change();

insert into core.derived_action (parent_action, child_action) values
  ('permit.stop',                 'permit.suspend_with_job'),
  ('permit.stop_as_party',        'permit.suspend_with_job'),
  ('permit.stop_as_authority',    'permit.suspend_with_job'),
  ('permit.stop_area',            'permit.suspend_with_job'),
  ('permit.expire',               'permit.suspend_with_job'),
  ('work_package.revise',         'permit.suspend_for_change'),
  ('work_package.revise_for_venue', 'permit.suspend_for_change');

insert into core.state_transition (machine, from_state, to_state, required_action)
select 'permit', f, 'suspended', a
  from unnest(array['issued_awaiting_acceptance', 'active']) f
  cross join unnest(array['permit.stop', 'permit.stop_as_party', 'permit.stop_as_authority', 'permit.suspend_with_job',
                          'permit.suspend_for_change', 'permit.change_supervisor']) a
union all
select 'permit', 'suspended', t, a from (values
  ('active',    'permit.reaccept'),
  ('submitted', 'permit.submit'),
  ('submitted', 'permit.submit_for_venue'),
  ('expired',   'permit.expire')) x(t, a);

-- ---------------------------------------------------------------------------
-- Area stops (Q110): a venue authority stops all work in an area and its sub-areas.
-- ---------------------------------------------------------------------------
create table core.area_stop (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  venue_id             uuid not null,
  area_id              uuid not null,
  category             text not null check (category in ('unsafe_act', 'change_in_conditions', 'control_failure', 'emergency',
                                                         'weather', 'instruction', 'other')),
  reason               text not null check (length(btrim(reason)) > 0),
  stopped_by_person_id uuid not null,
  decision_context_id  uuid not null references core.decision_context,
  row_version          integer not null default 1,
  created_at           timestamptz not null default clock_timestamp(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (area_id) references core.area (id),
  foreign key (customer_id, stopped_by_person_id) references core.person (customer_id, id),
  unique (customer_id, venue_id, id)
);
select core.attach_standard_triggers('core.area_stop', null);

create table core.area_stop_lift (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  venue_id             uuid not null,
  area_stop_id         uuid not null unique,
  reason               text not null check (length(btrim(reason)) > 0),
  conditions           text[] not null default '{}',
  lifter_person_id     uuid not null,
  decision_context_id  uuid not null references core.decision_context,
  row_version          integer not null default 1,
  created_at           timestamptz not null default clock_timestamp(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, venue_id, area_stop_id) references core.area_stop (customer_id, venue_id, id),
  foreign key (customer_id, lifter_person_id) references core.person (customer_id, id)
);
select core.attach_standard_triggers('core.area_stop_lift', null);

-- ---------------------------------------------------------------------------
-- Suspensions (invariant 7). The kind decides who may lift it:
--   stop               an issuer for the permit's class and area (permit.lift_suspension)
--   job_stop           lifted with the stop it came from, on another permit of the job
--   area_stop          lifted with the area stop (permit.lift_area_stop)
--   material_change    never lifted: resolved only by submitting the permit again (reissue)
--   supervisor_change  lifted by the change itself; the new supervisor must re-accept
--   parent_ended       the Work Approval's window ended; resolved by hand-back (phase 6c)
-- ---------------------------------------------------------------------------
create table core.permit_suspension (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  venue_id              uuid not null,
  permit_id             uuid not null,
  kind                  text not null check (kind in ('stop', 'job_stop', 'area_stop', 'material_change', 'supervisor_change', 'parent_ended')),
  category              text check (category in ('unsafe_act', 'change_in_conditions', 'control_failure', 'emergency',
                                                 'weather', 'instruction', 'other')),
  reason                text not null check (length(btrim(reason)) > 0),
  origin_suspension_id  uuid,
  area_stop_id          uuid,
  stopped_by_person_id  uuid,
  decision_context_id   uuid not null references core.decision_context,
  row_version           integer not null default 1,
  created_at            timestamptz not null default clock_timestamp(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, venue_id, permit_id) references core.permit (customer_id, venue_id, id),
  foreign key (customer_id, venue_id, area_stop_id) references core.area_stop (customer_id, venue_id, id),
  foreign key (customer_id, stopped_by_person_id) references core.person (customer_id, id),
  unique (customer_id, venue_id, id),
  check ((kind = 'stop') = (category is not null)),
  check ((kind = 'job_stop') = (origin_suspension_id is not null)),
  check ((kind = 'area_stop') = (area_stop_id is not null))
);
alter table core.permit_suspension add foreign key (customer_id, venue_id, origin_suspension_id)
  references core.permit_suspension (customer_id, venue_id, id);
create index permit_suspension_permit on core.permit_suspension (permit_id);
select core.attach_standard_triggers('core.permit_suspension', null);

create table core.permit_suspension_lift (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  venue_id             uuid not null,
  suspension_id        uuid not null unique,
  via                  text not null check (via in ('lift', 'reissue', 'supervisor_change')),
  reason               text not null check (length(btrim(reason)) > 0),
  conditions           text[] not null default '{}',
  lifter_person_id     uuid not null,
  decision_context_id  uuid not null references core.decision_context,
  row_version          integer not null default 1,
  created_at           timestamptz not null default clock_timestamp(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, venue_id, suspension_id) references core.permit_suspension (customer_id, venue_id, id),
  foreign key (customer_id, lifter_person_id) references core.person (customer_id, id)
);
select core.attach_standard_triggers('core.permit_suspension_lift', null);

-- Re-acceptance at the workface after a suspension (P6-3).
create table core.permit_reacceptance (
  id                         uuid primary key default gen_random_uuid(),
  customer_id                uuid not null,
  venue_id                   uuid not null,
  permit_id                  uuid not null,
  issue_snapshot_id          uuid not null,
  supervisor_person_id       uuid not null,
  declaration                jsonb not null,
  declaration_sha256         bytea not null check (length(declaration_sha256) = 32),
  acknowledged_condition_ids uuid[] not null,
  acknowledged_lift_ids      uuid[] not null,
  briefed_person_ids         uuid[] not null check (cardinality(briefed_person_ids) > 0),
  briefed_at                 timestamptz not null,
  accepted_at                timestamptz not null default clock_timestamp(),
  decision_context_id        uuid not null references core.decision_context,
  row_version                integer not null default 1,
  created_at                 timestamptz not null default now(),
  created_by_user_id         uuid default auth.uid(),
  foreign key (customer_id, venue_id, permit_id) references core.permit (customer_id, venue_id, id),
  foreign key (customer_id, venue_id, issue_snapshot_id) references core.issue_snapshot (customer_id, venue_id, id),
  foreign key (customer_id, supervisor_person_id) references core.person (customer_id, id),
  check (briefed_at <= accepted_at)
);
select core.attach_standard_triggers('core.permit_reacceptance', null);

-- ---------------------------------------------------------------------------
-- The live team (Q106, Q107). Additions after issue count only once briefed (and
-- approved, where the class requires it); removals keep their record. Each of these
-- facts is set once.
-- ---------------------------------------------------------------------------
alter table core.permit_team_member
  add column added_live            boolean not null default false,
  add column approval_required     boolean not null default false,
  add column approved_at           timestamptz,
  add column approved_by_person_id uuid,
  add column briefed_at            timestamptz,
  add column briefed_by_person_id  uuid,
  add column removed_by_person_id  uuid,
  add column removal_reason        text,
  add foreign key (customer_id, approved_by_person_id) references core.person (customer_id, id),
  add foreign key (customer_id, briefed_by_person_id) references core.person (customer_id, id),
  add foreign key (customer_id, removed_by_person_id) references core.person (customer_id, id),
  add check (added_live or not approval_required),
  add check (approved_at is null or approval_required);
drop trigger b_guard_update on core.permit_team_member;
create trigger b_guard_update before update on core.permit_team_member
  for each row execute function core.guard_update('removed_at,approved_at,approved_by_person_id,briefed_at,briefed_by_person_id,removed_by_person_id,removal_reason');

create function core.team_member_set_once() returns trigger
language plpgsql set search_path = '' as $$
begin
  if (old.removed_at is not null and new.removed_at is distinct from old.removed_at)
     or (old.approved_at is not null and new.approved_at is distinct from old.approved_at)
     or (old.briefed_at is not null and new.briefed_at is distinct from old.briefed_at)
     or (old.removed_by_person_id is not null and new.removed_by_person_id is distinct from old.removed_by_person_id)
     or (old.removal_reason is not null and new.removal_reason is distinct from old.removal_reason) then
    raise exception 'a team member''s approval, briefing and removal are recorded once' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger team_member_set_once before update on core.permit_team_member
  for each row execute function core.team_member_set_once();

-- Whether a team member counts as part of the team now.
create function core.member_counts(m core.permit_team_member) returns boolean
language sql immutable set search_path = '' as $$
  select m.removed_at is null
     and (not m.added_live or (m.briefed_at is not null and (not m.approval_required or m.approved_at is not null))) $$;

-- ---------------------------------------------------------------------------
-- Extensions (Q108, P6-5): an addendum to the issue snapshot, never a change to it. The
-- extended time counts only once the supervisor has acknowledged it.
-- ---------------------------------------------------------------------------
create table core.permit_extension (
  id                        uuid primary key default gen_random_uuid(),
  customer_id               uuid not null,
  venue_id                  uuid not null,
  permit_id                 uuid not null,
  issue_snapshot_id         uuid not null,
  previous_end              timestamptz not null,
  new_end                   timestamptz not null check (new_end > previous_end),
  reason                    text not null check (length(btrim(reason)) > 0),
  content                   jsonb not null,
  content_sha256            bytea not null check (length(content_sha256) = 32),
  extender_person_id        uuid not null,
  decision_context_id       uuid not null references core.decision_context,
  acknowledged_at           timestamptz,
  acknowledged_by_person_id uuid,
  ack_decision_context_id   uuid references core.decision_context,
  row_version               integer not null default 1,
  created_at                timestamptz not null default clock_timestamp(),
  created_by_user_id        uuid default auth.uid(),
  foreign key (customer_id, venue_id, permit_id) references core.permit (customer_id, venue_id, id),
  foreign key (customer_id, venue_id, issue_snapshot_id) references core.issue_snapshot (customer_id, venue_id, id),
  foreign key (customer_id, extender_person_id) references core.person (customer_id, id),
  foreign key (customer_id, acknowledged_by_person_id) references core.person (customer_id, id),
  check ((acknowledged_at is null) = (acknowledged_by_person_id is null) and (acknowledged_at is null) = (ack_decision_context_id is null))
);
create unique index permit_extension_one_pending on core.permit_extension (issue_snapshot_id) where acknowledged_at is null;
select core.attach_standard_triggers('core.permit_extension', 'acknowledged_at,acknowledged_by_person_id,ack_decision_context_id');

create function core.extension_ack_once() returns trigger
language plpgsql set search_path = '' as $$
begin
  if old.acknowledged_at is not null then
    raise exception 'an extension is acknowledged once' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger extension_ack_once before update on core.permit_extension
  for each row execute function core.extension_ack_once();

-- Revalidation (Q112, P6-7): the supervisor confirms nothing has changed.
create table core.permit_revalidation (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  venue_id             uuid not null,
  permit_id            uuid not null,
  issue_snapshot_id    uuid not null,
  supervisor_person_id uuid not null,
  statement            text not null,
  conditions_note      text,
  decision_context_id  uuid not null references core.decision_context,
  row_version          integer not null default 1,
  created_at           timestamptz not null default clock_timestamp(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, venue_id, permit_id) references core.permit (customer_id, venue_id, id),
  foreign key (customer_id, venue_id, issue_snapshot_id) references core.issue_snapshot (customer_id, venue_id, id),
  foreign key (customer_id, supervisor_person_id) references core.person (customer_id, id)
);
select core.attach_standard_triggers('core.permit_revalidation', null);

-- ---------------------------------------------------------------------------
-- Rules
-- ---------------------------------------------------------------------------
-- Whether a suspension still holds the permit.
create function core.suspension_holding(p_suspension_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select case s.kind
           when 'job_stop' then not exists (select 1 from core.permit_suspension_lift l where l.suspension_id = s.origin_suspension_id)
           when 'area_stop' then not exists (select 1 from core.area_stop_lift l where l.area_stop_id = s.area_stop_id)
           when 'parent_ended' then true
           else not exists (select 1 from core.permit_suspension_lift l where l.suspension_id = s.id) end
    from core.permit_suspension s where s.id = p_suspension_id $$;

create function core.permit_holding(p_permit_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from core.permit_suspension s where s.permit_id = p_permit_id and core.suspension_holding(s.id)) $$;

-- A suspended permit can be submitted again (P6-4) when a material change holds it and
-- nothing else does.
create function core.reissue_pending(p_permit_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p.status = 'suspended'
     and exists (select 1 from core.permit_suspension s where s.permit_id = p.id and s.kind = 'material_change' and core.suspension_holding(s.id))
     and not exists (select 1 from core.permit_suspension s where s.permit_id = p.id and s.kind <> 'material_change' and core.suspension_holding(s.id))
    from core.permit p where p.id = p_permit_id $$;

-- When the authority to work ends: the issued window, or the latest acknowledged extension.
create function core.permit_window_end(p_permit_id uuid) returns timestamptz
language sql stable security definer set search_path = '' as $$
  select coalesce((select max(e.new_end) from core.permit_extension e
                    where e.permit_id = p.id and e.issue_snapshot_id = p.issue_snapshot_id and e.acknowledged_at is not null),
                  upper(v.planned_window))
    from core.permit p join core.permit_version v on v.id = p.current_version_id where p.id = p_permit_id $$;

-- Invariant 4 while live.
create function core.live_dependency_problem(p_permit_id uuid) returns text
language sql stable security definer set search_path = '' as $$
  select case
           when p.kind = 'child' and p.status = 'active'
                and (select status from core.permit where id = p.parent_permit_id) <> 'active'
             then 'a permit cannot be active while its Work Approval is not active'
           when p.kind = 'work_approval' and p.status = 'active'
                and exists (select 1 from core.permit c where c.parent_permit_id = p.id and core.permit_holding(c.id))
             then 'a Work Approval cannot be active while a permit on its job is suspended and not lifted'
         end
    from core.permit p where p.id = p_permit_id $$;

create function core.live_dependency_check() returns trigger
language plpgsql security definer set search_path = '' as $$
declare p core.permit; x uuid; problem text;
begin
  select * into p from core.permit
   where id = case tg_table_name when 'permit' then new.id else (to_jsonb(new) ->> 'permit_id')::uuid end;
  for x in select p.id union select p.parent_permit_id where p.parent_permit_id is not null
           union select c.id from core.permit c where c.parent_permit_id = p.id loop
    problem := core.live_dependency_problem(x);
    if problem is not null then
      raise exception '%', problem using errcode = 'check_violation';
    end if;
  end loop;
  return null;
end $$;
create constraint trigger live_dependency_check after insert or update of status on core.permit
  deferrable initially deferred for each row execute function core.live_dependency_check();
create constraint trigger live_dependency_check after insert on core.permit_suspension
  deferrable initially deferred for each row execute function core.live_dependency_check();

-- Leaving Suspended (invariant 7, P6-3, P6-4): to Active only with nothing holding and a
-- re-acceptance recorded by this decision; to Submitted only for a reissue.
create function core.suspension_exit_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if old.status = 'suspended' and new.status = 'active' then
    if core.permit_holding(new.id) then
      raise exception 'a suspended permit becomes active only once every suspension is lifted' using errcode = 'check_violation';
    end if;
    if not exists (select 1 from core.permit_reacceptance r
                    where r.permit_id = new.id and r.decision_context_id = core.ctx_uuid('decision_context_id')) then
      raise exception 'a suspended permit becomes active only through a re-acceptance at the workface' using errcode = 'check_violation';
    end if;
  elsif old.status = 'suspended' and new.status = 'submitted' and not core.reissue_pending(new.id) then
    raise exception 'a suspended permit can be submitted again only when a material change is all that holds it'
      using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger suspension_exit_guard before update of status on core.permit
  for each row execute function core.suspension_exit_guard();

-- Submitting again resolves the material-change suspensions, recorded against the submitter.
create function core.resolve_by_reissue() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if old.status = 'suspended' and new.status = 'submitted' then
    insert into core.permit_suspension_lift (customer_id, venue_id, suspension_id, via, reason, lifter_person_id, decision_context_id)
    select s.customer_id, s.venue_id, s.id, 'reissue', 'Submitted again as version ' ||
             (select version_no from core.permit_version where id = new.current_version_id),
           (select actor_person_id from core.decision_context where id = core.ctx_uuid('decision_context_id')),
           core.ctx_uuid('decision_context_id')
      from core.permit_suspension s
     where s.permit_id = new.id and s.kind = 'material_change' and core.suspension_holding(s.id);
  end if;
  return null;
end $$;
create trigger resolve_by_reissue after update of status on core.permit
  for each row execute function core.resolve_by_reissue();

-- Runs the live dependency checks now, so a caller gets the refusal from the decision
-- that caused it; later statements in the transaction are checked at commit again.
create function core.check_live_now() returns void
language plpgsql security definer set search_path = '' as $$
begin
  set constraints core.live_dependency_check immediate;
  set constraints core.live_dependency_check deferred;
end $$;

-- ---------------------------------------------------------------------------
-- Class configuration gains extension, worker-addition and revalidation rules (P6-5 to
-- P6-7). None has a default: an approved configuration must choose each.
--   extension:    {max_count: n >= 0, max_total_hours: h >= 0}   (0 = not extendable, chosen)
--   worker_add:   'supervisor' | 'issuer_approval'
--   revalidation: {mode: 'none'} | {mode: 'interval', every_hours: h > 0}
-- ---------------------------------------------------------------------------
do $m$
declare d text;
begin
  d := pg_get_functiondef('core.validate_class_config(uuid,jsonb,boolean)'::regprocedure);
  if position(E'  return errs;\nend' in d) = 0 then
    raise exception 'core.validate_class_config no longer has the expected structure';
  end if;
  d := replace(d, E'  return errs;\nend', $r$  -- Live rules (phase 6a).
  if p_content ? 'extension' and (jsonb_typeof(p_content #> '{extension,max_count}') is distinct from 'number'
       or (p_content #>> '{extension,max_count}')::numeric < 0
       or (p_content #>> '{extension,max_count}')::numeric <> floor((p_content #>> '{extension,max_count}')::numeric)
       or jsonb_typeof(p_content #> '{extension,max_total_hours}') is distinct from 'number'
       or (p_content #>> '{extension,max_total_hours}')::numeric < 0) then
    errs := errs || text 'Extensions need a whole number of times and a total number of hours (zero for none, but chosen).';
  end if;
  if p_content ? 'worker_add' and coalesce(p_content ->> 'worker_add', '') not in ('supervisor', 'issuer_approval') then
    errs := errs || text 'Choose whether the supervisor can add people after issue, or an issuer must approve each addition.';
  end if;
  if p_content ? 'revalidation' and not (
       p_content #>> '{revalidation,mode}' = 'none'
       or (p_content #>> '{revalidation,mode}' = 'interval' and jsonb_typeof(p_content #> '{revalidation,every_hours}') = 'number'
           and (p_content #>> '{revalidation,every_hours}')::numeric > 0)) then
    errs := errs || text 'Revalidation is either none, or every so many hours (more than zero).';
  end if;
  if p_strict then
    if not p_content ? 'extension' then
      errs := errs || text 'Set how many times, and for how many hours in total, a permit of this class can be extended (P6-5): there is no default.';
    end if;
    if not p_content ? 'worker_add' then
      errs := errs || text 'Choose who approves people added to the team after issue (P6-6): there is no default.';
    end if;
    if not p_content ? 'revalidation' then
      errs := errs || text 'Choose whether a live permit of this class must be revalidated, and how often (P6-7): there is no default.';
    end if;
  end if;
  return errs;
end$r$);
  execute d;
end $m$;

-- ---------------------------------------------------------------------------
-- The permit-part basis in authz.evaluate (P6-2): the actor must be on the permit's live
-- team in one of the roles the action needs.
-- ---------------------------------------------------------------------------
do $m$
declare d text;
begin
  d := pg_get_functiondef('authz.evaluate(text,jsonb,uuid,uuid)'::regprocedure);
  if position('  if v_action.basis = ''tenant_admin'' then' in d) = 0 then
    raise exception 'authz.evaluate no longer has the expected structure';
  end if;
  d := replace(d, '  if v_action.basis = ''tenant_admin'' then', $r$  if v_action.basis = 'permit_part' then
    if not exists (select 1 from core.permit_team_member m join core.part_action pa on pa.action_code = p_action
                    join core.permit p on p.id = m.permit_id
                   where m.permit_id = (p_target ->> 'permit_id')::uuid and p.customer_id = v_customer
                     and m.person_id = v_person and m.removed_at is null and m.role = any (pa.roles)) then
      return authz.deny(p_action, 'not_permit_part',
        case when (select roles from core.part_action where action_code = p_action) = array['supervisor']
             then 'Only the permit''s supervisor can do this.'
             else 'Only someone on the permit''s team can do this.' end,
        'A place on the permit''s team', 'The permit''s supervisor or issuer');
    end if;
    return v_base || jsonb_build_object('actor_kind', 'user');
  end if;

  if v_action.basis = 'tenant_admin' then$r$);
  execute d;
end $m$;

-- ---------------------------------------------------------------------------
-- Visibility: holders of the live-control actions at a venue see its jobs and permits.
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
                                            'permit.exclude_worker_as_authority', 'permit.change_supervisor']) a
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

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
grant select on core.area_stop, core.area_stop_lift, core.permit_suspension, core.permit_suspension_lift,
                core.permit_reacceptance, core.permit_extension, core.permit_revalidation to authenticated;

-- Area stops are venue records: administrators and appointees at the venue.
create policy area_stop_read on core.area_stop for select to authenticated
  using (customer_id in (select authz.my_admin_customer_ids()) or venue_id in (select authz.my_appointee_venue_ids())
         or id in (select s.area_stop_id from core.permit_suspension s where s.permit_id in (select authz.visible_permit_ids())));
create policy area_stop_lift_read on core.area_stop_lift for select to authenticated
  using (area_stop_id in (select id from core.area_stop));
create policy suspension_read on core.permit_suspension for select to authenticated
  using (permit_id in (select authz.visible_permit_ids()));
create policy suspension_lift_read on core.permit_suspension_lift for select to authenticated
  using (suspension_id in (select s.id from core.permit_suspension s where s.permit_id in (select authz.visible_permit_ids())));
create policy reacceptance_read on core.permit_reacceptance for select to authenticated
  using (permit_id in (select authz.visible_permit_ids()));
create policy extension_read on core.permit_extension for select to authenticated
  using (permit_id in (select authz.visible_permit_ids()));
create policy revalidation_read on core.permit_revalidation for select to authenticated
  using (permit_id in (select authz.visible_permit_ids()));
