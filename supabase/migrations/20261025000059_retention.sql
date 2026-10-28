-- 0059 Retention schedule, legal holds and disposal records (phase 8d(a), D-022: Q218, Q221–Q224,
--      P8-13, P8-14): catalogue, the categories, the schedule document, holds, disposal batches,
--      and the one route by which a core row can ever be deleted
--
-- Records are kept for as long as the venue's approved schedule says, and no longer (§16.2).
-- There is no default: a category without an approved rule is kept. A scheduled job lists what
-- has run out and is not under an active legal hold; it never disposes. An appointee holding
-- `retention.dispose` (never the schedule's approver, never an administrator) confirms each batch,
-- and every record is checked again at that moment. Core rows remain undeletable except inside
-- that confirmation: the delete guard allows a delete only for a row the confirming transaction
-- has itself named against a confirmed batch. Files are removed from storage by the job runner
-- afterwards; their records stay.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only. Disposal cannot be
-- undone: that is its purpose. Batches, items and the identifiers of every deleted row are kept.

insert into core.authority_action (code, basis, delegable, description) values
  ('retention.approve',      'appointment', false, 'Approve or reject the venue''s retention schedule (Q224)'),
  ('retention.dispose',      'appointment', false, 'Confirm or decline a batch of records listed for disposal under the retention schedule'),
  ('retention.list',         'service',     false, 'List records past their retention period, and legal holds due for review'),
  ('retention.remove_files', 'service',     false, 'Remove disposed files from storage and record it'),
  ('legal_hold.request',     'appointment', false, 'Ask for a legal hold on records (Q223)'),
  ('legal_hold.approve',     'appointment', false, 'Approve, refuse, renew or lift a legal hold (Q223)');
insert into core.service_action (purpose, action_code) values ('job_runner', 'retention.list'), ('job_runner', 'retention.remove_files');

-- The schedule is a venue configuration document approved by a retention appointee, not by the
-- general configuration approver.
insert into core.derived_action (parent_action, child_action) values ('retention.approve', 'venue_config.supersede');
insert into core.state_transition (machine, from_state, to_state, required_action) values
  ('venue_config_version', 'proposed', 'approved', 'retention.approve'),
  ('venue_config_version', 'proposed', 'rejected', 'retention.approve');

-- ---------------------------------------------------------------------------
-- Categories (§16.2). The trigger event and what disposal does are fixed per category (Q222);
-- the period is the venue's. Closed jobs arrive in 8d(b).
-- ---------------------------------------------------------------------------
create function core.retention_categories() returns table (code text, name text, trigger_words text, method text, never_while text, ord integer)
language sql immutable set search_path = '' as $$
  values
  ('gate_scans', 'Gate scans and entry checks', 'The check at the gate',
   'Deleted', 'It is a scan recorded against a visit: it is kept, and disposed of, with the visit', 1),
  ('gate_outage', 'Offline manifests, manual fallback entries and reconciliation exceptions',
   'For a fallback entry, its last exception resolved (or the entry received, if it raised none); for a manifest, the end of its usable life',
   'Deleted', 'Any exception on the entry is unresolved, or a fallback entry still names the manifest', 2),
  ('visits', 'Access visits', 'The visit''s end, or its refusal, withdrawal or cancellation',
   'Deleted, with its roster, consents, attendance and the scans recorded against it', 'It is awaiting a decision, or a work request is linked to it', 3),
  ('inductions', 'Induction records', 'The completion''s expiry, invalidation or supersession by a later completion of the same course; for an unfinished attempt, its last activity',
   'Deleted: attempts, answers and completions', 'It is the person''s current completion for the course', 4),
  ('notifications', 'Notifications', 'The notice made',
   'Deleted, with its email records', 'An email for it is still waiting to be sent', 5),
  ('document_files', 'Earlier evidence files', 'A newer version submitted, the file''s expiry, or its review not accepted, whichever is first',
   'The file is removed from storage; the record keeps its type, dates, review decisions and hash', 'It is the document''s current version, a permit names it, or a recorded competency relies on it', 6),
  ('rejected_uploads', 'Rejected and infected uploads', 'The malware check''s result',
   'The file is removed from storage; the record and the result stay', 'Never kept back except by a legal hold', 7)
$$;

-- ---------------------------------------------------------------------------
-- The schedule: venue configuration of kind `retention`.
--   retention: {rules: {<category>: {days: 1..36500, basis: "what the venue relies on"}}}
-- ---------------------------------------------------------------------------
alter table core.venue_config_version drop constraint venue_config_version_kind_check;
alter table core.venue_config_version add constraint venue_config_version_kind_check
  check (kind in ('access_purposes', 'outage_procedure', 'chasing', 'retention'));

create function core.validate_retention(c jsonb, p_strict boolean) returns text[]
language plpgsql stable security definer set search_path = '' as $$
declare errs text[] := '{}'; k text; x jsonb;
begin
  if jsonb_typeof(c -> 'rules') is distinct from 'object' then return array['A retention schedule is a set of rules, one per category.']; end if;
  for k, x in select * from jsonb_each(c -> 'rules') loop
    if not exists (select 1 from core.retention_categories() rc where rc.code = k) then
      errs := errs || format('"%s" is not a category of record.', k); continue;
    end if;
    if coalesce(x ->> 'days', '') !~ '^[0-9]{1,5}$' or (x ->> 'days')::int not between 1 and 36500 then
      errs := errs || format('%s: keep for a whole number of days, 1 to 36500.', (select name from core.retention_categories() where code = k));
    end if;
    if length(btrim(coalesce(x ->> 'basis', ''))) not between 1 and 500 then
      errs := errs || format('%s: say what the period is based on (the advice, policy or decision relied on).', (select name from core.retention_categories() where code = k));
    end if;
  end loop;
  if p_strict and (select count(*) from jsonb_object_keys(c -> 'rules')) = 0 then
    errs := errs || text 'Set a rule for at least one category.';
  end if;
  return errs;
end $$;

do $m$
declare d text; anchor text := $s$  else
    errs := errs || text 'Unknown kind of configuration.';$s$;
begin
  d := pg_get_functiondef('core.validate_venue_config(uuid,text,jsonb,boolean)'::regprocedure);
  if position(anchor in d) = 0 then raise exception 'core.validate_venue_config no longer has the expected structure'; end if;
  execute replace(d, anchor, $s$  elsif p_kind = 'retention' then
    errs := errs || core.validate_retention(c, p_strict);
$s$ || anchor);
end $m$;

-- The rule a venue's approved schedule sets for a category, if any.
create function core.retention_rule(p_venue_id uuid, p_category text) returns table (config_id uuid, days integer, approver_person_id uuid)
language sql stable security definer set search_path = '' as $$
  select c.id, (c.content #>> array['rules', p_category, 'days'])::int, c.decided_by_person_id
    from core.venue_config_version c
   where c.venue_id = p_venue_id and c.kind = 'retention' and c.status = 'approved' and c.content -> 'rules' ? p_category $$;

-- Records that belong to the customer rather than a venue (8d-3): disposed of only when every
-- venue of the customer has a rule for the category, under the longest; that venue's batch lists
-- them and its appointees confirm.
create function core.customer_wide_rule(p_customer_id uuid, p_category text) returns table (venue_id uuid, config_id uuid, days integer, approver_person_id uuid)
language sql stable security definer set search_path = '' as $$
  select v.id, r.config_id, r.days, r.approver_person_id
    from core.venue v cross join lateral core.retention_rule(v.id, p_category) r
   where v.customer_id = p_customer_id
     and not exists (select 1 from core.venue w where w.customer_id = p_customer_id
                      and not exists (select 1 from core.retention_rule(w.id, p_category)))
   order by r.days desc, v.id limit 1 $$;

-- ---------------------------------------------------------------------------
-- Legal holds (Q223, P8-14, §16.4). Requested and approved by different appointees; active until
-- lifted with a reason; a review date that tells people, and never ends the hold (invariant 10).
-- Scope identifiers are kept without foreign keys so a hold never prevents later disposal of
-- something it no longer covers.
-- ---------------------------------------------------------------------------
create table core.legal_hold (
  id                     uuid primary key default gen_random_uuid(),
  customer_id            uuid not null,
  venue_id               uuid not null,
  reference              text not null,
  matter                 text not null check (length(btrim(matter)) between 1 and 200),
  reason                 text not null check (length(btrim(reason)) between 1 and 2000),
  scope_organisation_id  uuid,
  scope_person_id        uuid,
  scope_work_package_id  uuid,
  scope_visit_id         uuid,
  scope_from             timestamptz,
  scope_to               timestamptz,
  review_on              date not null,
  status                 text not null,
  requested_by_person_id uuid not null,
  decided_by_person_id   uuid,
  decided_at             timestamptz,
  decision_reason        text,
  lifted_by_person_id    uuid,
  lifted_at              timestamptz,
  lift_reason            text,
  row_version            integer not null default 1,
  created_at             timestamptz not null default clock_timestamp(),
  created_by_user_id     uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, requested_by_person_id) references core.person (customer_id, id),
  foreign key (customer_id, decided_by_person_id) references core.person (customer_id, id),
  foreign key (customer_id, lifted_by_person_id) references core.person (customer_id, id),
  unique (customer_id, reference),
  check (scope_from is null or scope_to is null or scope_from < scope_to),
  check ((decided_at is null) = (decided_by_person_id is null) and (decided_at is null) = (decision_reason is null)),
  check ((lifted_at is null) = (lifted_by_person_id is null) and (lifted_at is null) = (lift_reason is null))
);
select core.attach_standard_triggers('core.legal_hold',
  'status,decided_by_person_id,decided_at,decision_reason,lifted_by_person_id,lifted_at,lift_reason', 'transition', true);

-- A renewal sets a new review date; the latest one is the hold's review date.
create table core.legal_hold_renewal (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  venue_id              uuid not null,
  hold_id               uuid not null references core.legal_hold,
  review_on             date not null,
  reason                text not null check (length(btrim(reason)) between 1 and 2000),
  renewed_by_person_id  uuid not null,
  decision_context_id   uuid not null references core.decision_context,
  row_version           integer not null default 1,
  created_at            timestamptz not null default clock_timestamp(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, renewed_by_person_id) references core.person (customer_id, id)
);
select core.attach_standard_triggers('core.legal_hold_renewal', null);

insert into core.state_machine (code, table_name) values ('legal_hold', 'core.legal_hold');
insert into core.state_initial (machine, state, required_action) values ('legal_hold', 'requested', 'legal_hold.request');
insert into core.state_transition (machine, from_state, to_state, required_action) values
  ('legal_hold', 'requested', 'active', 'legal_hold.approve'),
  ('legal_hold', 'requested', 'refused', 'legal_hold.approve'),
  ('legal_hold', 'active', 'lifted', 'legal_hold.approve');

create function core.hold_review_on(p_hold_id uuid) returns date
language sql stable security definer set search_path = '' as $$
  select coalesce((select r.review_on from core.legal_hold_renewal r where r.hold_id = p_hold_id order by r.created_at desc, r.id desc limit 1),
                  (select h.review_on from core.legal_hold h where h.id = p_hold_id)) $$;

-- ---------------------------------------------------------------------------
-- What a record is, for disposal and for matching holds.
-- ---------------------------------------------------------------------------
create type core.retention_candidate as (
  category          text,
  root_table        text,
  root_id           uuid,
  venue_id          uuid,         -- null: belongs to the customer (8d-3)
  trigger_at        timestamptz,
  person_ids        uuid[],
  organisation_ids  uuid[],
  work_package_ids  uuid[],
  visit_ids         uuid[],
  during            tstzrange
);

create function core.person_org_ids(p_person_ids uuid[]) returns uuid[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(distinct r.organisation_id), '{}') from core.person_organisation_relationship r where r.person_id = any (p_person_ids) $$;

create function core.clean_ids(p uuid[]) returns uuid[]
language sql immutable set search_path = '' as $$ select coalesce(array_agg(distinct x), '{}') from unnest(p) x where x is not null $$;

-- Every record of a category whose state allows disposal now (whatever its period). Records
-- that may never be disposed of yet are not returned at all.
create function core.retention_candidates(p_customer_id uuid, p_category text) returns setof core.retention_candidate
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_category = 'gate_scans' then
    return query
      select p_category, 'core.entry_eligibility_evaluation', e.id, e.venue_id, e.evaluated_at,
             core.clean_ids(array[e.person_id]), core.person_org_ids(array[e.person_id]), '{}'::uuid[], '{}'::uuid[],
             tstzrange(e.evaluated_at, e.evaluated_at, '[]')
        from core.entry_eligibility_evaluation e
       where e.customer_id = p_customer_id
         and not exists (select 1 from core.scan_event s join core.visit_attendance va on s.id in (va.arrival_scan_id, va.departure_scan_id)
                          where s.evaluation_id = e.id);

  elsif p_category = 'gate_outage' then
    return query
      select p_category, 'core.manual_fallback_entry', f.id, f.venue_id,
             coalesce((select max(x.resolved_at) from core.reconciliation_exception x where x.fallback_entry_id = f.id), f.received_at),
             core.clean_ids(array[f.person_id] || array(select x.person_id from core.reconciliation_exception x where x.fallback_entry_id = f.id)),
             core.person_org_ids(core.clean_ids(array[f.person_id] || array(select x.person_id from core.reconciliation_exception x where x.fallback_entry_id = f.id))),
             core.clean_ids(array(select p.work_package_id from core.reconciliation_exception x join core.permit p on p.id = x.permit_id
                                    where x.fallback_entry_id = f.id)),
             '{}'::uuid[], tstzrange(f.recorded_at, f.recorded_at, '[]')
        from core.manual_fallback_entry f
       where f.customer_id = p_customer_id
         and not exists (select 1 from core.reconciliation_exception x where x.fallback_entry_id = f.id and x.resolved_at is null)
      union all
      select p_category, 'core.gate_manifest', m.id, m.venue_id, m.made_at + make_interval(mins => m.max_age_minutes),
             core.clean_ids(array(select g.person_id from core.gate_manifest_entry g where g.manifest_id = m.id)),
             core.person_org_ids(array(select g.person_id from core.gate_manifest_entry g where g.manifest_id = m.id)),
             '{}'::uuid[], '{}'::uuid[], tstzrange(m.made_at, m.made_at + make_interval(mins => m.max_age_minutes), '[]')
        from core.gate_manifest m
       where m.customer_id = p_customer_id
         and not exists (select 1 from core.manual_fallback_entry f where f.manifest_id = m.id);

  elsif p_category = 'visits' then
    return query
      select p_category, 'core.access_authorisation', a.id, a.venue_id,
             case when a.status = 'approved' then upper(a.valid_during)
                  else (select max(sh.at) from core.status_history sh where sh.record_id = a.id and sh.to_state = a.status) end,
             core.clean_ids(array[a.requested_by_person_id]
                            || array(select r.person_id from core.access_roster_member r where r.authorisation_id = a.id)
                            || array(select va.person_id from core.visit_attendance va where va.authorisation_id = a.id)),
             array[a.organisation_id], '{}'::uuid[], array[a.id], a.valid_during
        from core.access_authorisation a
       where a.customer_id = p_customer_id and a.status in ('approved', 'refused', 'withdrawn', 'cancelled')
         and not exists (select 1 from core.access_work_request w where w.authorisation_id = a.id);

  elsif p_category = 'inductions' then
    return query
      select * from (
        select p_category, 'core.induction_completion', c.id, c.venue_id,
               least(c.valid_until,
                     (select min(i.created_at) from core.completion_invalidation i where i.completion_id = c.id),
                     (select min(n.completed_at) from core.induction_completion n join core.course_version nv on nv.id = n.course_version_id
                       where n.person_id = c.person_id and nv.course_id = cv.course_id and n.completed_at > c.completed_at)) as t,
               array[c.person_id], core.person_org_ids(array[c.person_id]), '{}'::uuid[], '{}'::uuid[],
               tstzrange(least(c.completed_at, c.valid_until), greatest(c.completed_at, c.valid_until), '[]')
          from core.induction_completion c join core.course_version cv on cv.id = c.course_version_id
         where c.customer_id = p_customer_id) z
       where z.t <= now()
      union all
      select p_category, 'core.induction_attempt', a.id, a.venue_id,
             greatest(a.started_at, a.finished_at,
                      (select max(greatest(m.started_at, m.completed_at)) from core.module_progress m where m.attempt_id = a.id),
                      (select max(q.answered_at) from core.question_response q where q.attempt_id = a.id)),
             array[a.person_id], core.person_org_ids(array[a.person_id]), '{}'::uuid[], '{}'::uuid[],
             tstzrange(a.started_at, greatest(a.started_at, a.finished_at), '[]')
        from core.induction_attempt a
       where a.customer_id = p_customer_id
         and not exists (select 1 from core.induction_completion c where c.attempt_id = a.id);

  elsif p_category = 'notifications' then
    return query
      select p_category, 'core.notification', n.id, n.venue_id, n.created_at,
             array[n.recipient_person_id], '{}'::uuid[],
             core.clean_ids(array[case n.record_table when 'core.work_package' then n.record_id
                                                     when 'core.permit' then (select p.work_package_id from core.permit p where p.id = n.record_id) end]),
             core.clean_ids(array[case when n.record_table = 'core.access_authorisation' then n.record_id end]),
             tstzrange(n.created_at, n.created_at, '[]')
        from core.notification n
       where n.customer_id = p_customer_id
         and not exists (select 1 from core.notification_delivery d where d.notification_id = n.id and d.delivery_state = 'pending');

  elsif p_category = 'document_files' then
    return query
      select * from (
        select p_category, 'core.document_version', dv.id, d.venue_id,
               least((select min(n.submitted_at) from core.document_version n where n.document_id = dv.document_id and n.version_no > dv.version_no),
                     case when dv.expires_on is not null
                          then ((dv.expires_on + 1)::timestamp at time zone coalesce((select timezone from core.venue where id = d.venue_id), 'UTC')) end,
                     (select min(r.created_at) from core.review_decision r where r.document_version_id = dv.id and r.outcome = 'not_accepted')) as t,
               core.clean_ids(array[d.person_id]), core.clean_ids(array[d.organisation_id, d.provided_via_organisation_id]),
               '{}'::uuid[], '{}'::uuid[], tstzrange(dv.submitted_at, null, '[)')
          from core.document_version dv join core.document d on d.id = dv.document_id
         where dv.customer_id = p_customer_id and dv.scan_status in ('clean', 'not_scanned')
           and exists (select 1 from core.document_version n where n.document_id = dv.document_id and n.version_no > dv.version_no)
           and not exists (select 1 from core.file_disposal fd where fd.document_version_id = dv.id)
           and not exists (select 1 from core.permit_version pv where dv.id = any (pv.document_version_ids))
           and not exists (select 1 from core.issue_snapshot s where s.content #> '{version,documents}' ? dv.id::text)
           and not exists (select 1 from core.competency c where c.document_version_id = dv.id)) z
       where z.t <= now();

  elsif p_category = 'rejected_uploads' then
    return query
      select p_category, 'core.document_version', dv.id, d.venue_id, dv.scanned_at,
             core.clean_ids(array[d.person_id]), core.clean_ids(array[d.organisation_id, d.provided_via_organisation_id]),
             '{}'::uuid[], '{}'::uuid[], tstzrange(least(dv.submitted_at, dv.scanned_at), greatest(dv.submitted_at, dv.scanned_at), '[]')
        from core.document_version dv join core.document d on d.id = dv.document_id
       where dv.customer_id = p_customer_id and dv.scan_status in ('infected', 'rejected')
         and not exists (select 1 from core.file_disposal fd where fd.document_version_id = dv.id);
  else
    raise exception 'unknown retention category %', p_category using errcode = '22023';
  end if;
end $$;

-- Whether an active hold covers a record: every part of its scope must match; a hold with no
-- scope covers everything at its venue. Customer-wide records are covered by a hold at any venue.
create function core.hold_covers(h core.legal_hold, c core.retention_candidate) returns boolean
language sql immutable set search_path = '' as $$
  select (c.venue_id is null or h.venue_id = c.venue_id)
     and (h.scope_organisation_id is null or h.scope_organisation_id = any (c.organisation_ids))
     and (h.scope_person_id is null or h.scope_person_id = any (c.person_ids))
     and (h.scope_work_package_id is null or h.scope_work_package_id = any (c.work_package_ids))
     and (h.scope_visit_id is null or h.scope_visit_id = any (c.visit_ids))
     and ((h.scope_from is null and h.scope_to is null) or c.during && tstzrange(h.scope_from, h.scope_to, '[]')) $$;

create function core.covering_holds(p_customer_id uuid, c core.retention_candidate) returns uuid[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(h.id order by h.reference), '{}') from core.legal_hold h
   where h.customer_id = p_customer_id and h.status = 'active' and core.hold_covers(h, c) $$;

-- ---------------------------------------------------------------------------
-- Disposal batches: listed by the job, confirmed or declined by an appointee.
-- ---------------------------------------------------------------------------
create table core.disposal_batch (
  id                     uuid primary key default gen_random_uuid(),
  customer_id            uuid not null,
  venue_id               uuid not null,
  reference              text not null,
  category               text not null,
  rule_config_id         uuid not null references core.venue_config_version,
  period_days            integer not null check (period_days between 1 and 36500),
  held_back              jsonb not null default '[]',
  listed_count           integer not null check (listed_count > 0),
  status                 text not null,
  decided_by_person_id   uuid,
  decided_at             timestamptz,
  decision_reason        text,
  disposed_count         integer,
  kept_count             integer,
  row_version            integer not null default 1,
  created_at             timestamptz not null default clock_timestamp(),
  created_by_user_id     uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, decided_by_person_id) references core.person (customer_id, id),
  unique (customer_id, reference),
  check ((decided_at is null) = (decided_by_person_id is null) and (decided_at is null) = (decision_reason is null))
);
create unique index disposal_batch_one_proposed on core.disposal_batch (venue_id, category) where status = 'proposed';
select core.attach_standard_triggers('core.disposal_batch',
  'status,decided_by_person_id,decided_at,decision_reason,disposed_count,kept_count', 'transition', true);

insert into core.state_machine (code, table_name) values ('disposal_batch', 'core.disposal_batch');
insert into core.state_initial (machine, state, required_action) values ('disposal_batch', 'proposed', 'retention.list');
insert into core.state_transition (machine, from_state, to_state, required_action) values
  ('disposal_batch', 'proposed', 'confirmed', 'retention.dispose'),
  ('disposal_batch', 'proposed', 'declined', 'retention.dispose');

-- One row per record listed: its identifier and trigger, and what happened to it. Never content.
create table core.disposal_item (
  id                  uuid primary key default gen_random_uuid(),
  customer_id         uuid not null,
  batch_id            uuid not null references core.disposal_batch,
  root_table          text not null,
  root_id             uuid not null,
  trigger_at          timestamptz not null,
  outcome             text not null default 'listed' check (outcome in ('listed', 'disposed', 'kept')),
  kept_reason         text,
  row_version         integer not null default 1,
  created_at          timestamptz not null default clock_timestamp(),
  created_by_user_id  uuid default auth.uid(),
  unique (batch_id, root_table, root_id),
  check ((outcome = 'kept') = (kept_reason is not null))
);
create index disposal_item_root_idx on core.disposal_item (root_id);
select core.attach_standard_triggers('core.disposal_item', 'outcome,kept_reason');

-- The identifier of every row deleted, by batch. Written by the confirming function just before
-- each delete; the delete guard allows nothing else.
create table core.disposal_row (
  id          bigint generated always as identity primary key,
  batch_id    uuid not null references core.disposal_batch,
  table_name  text not null,
  record_id   uuid not null,
  xact_id     xid8 not null default pg_current_xact_id(),
  created_at  timestamptz not null default clock_timestamp()
);
create index disposal_row_lookup on core.disposal_row (table_name, record_id);
alter table core.disposal_row enable row level security;
alter table core.disposal_row force row level security;
create trigger a_forbid_delete before delete on core.disposal_row for each row execute function core.forbid_delete();
create trigger b_forbid_update before update on core.disposal_row for each row execute function core.forbid_update();

-- A disposed file: its record stays; the job runner removes the stored object.
create table core.file_disposal (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  venue_id             uuid not null,
  document_version_id  uuid not null unique,
  batch_id             uuid not null references core.disposal_batch,
  bucket               text not null check (bucket in ('documents')),
  storage_path         text not null,
  removed_at           timestamptz,
  attempts             integer not null default 0,
  leased_until         timestamptz,
  last_error           text,
  row_version          integer not null default 1,
  created_at           timestamptz not null default clock_timestamp(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, document_version_id) references core.document_version (customer_id, id)
);
select core.attach_standard_triggers('core.file_disposal', 'removed_at,attempts,leased_until,last_error');

-- The delete guard (phase 1) now has exactly one exception: a row this transaction named against
-- a confirmed disposal batch.
create or replace function core.forbid_delete() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if exists (select 1 from core.disposal_row d join core.disposal_batch b on b.id = d.batch_id
              where d.table_name = tg_table_schema || '.' || tg_table_name and d.record_id::text = to_jsonb(old) ->> 'id'
                and d.xact_id = pg_current_xact_id() and b.status = 'confirmed') then
    return old;
  end if;
  raise exception '% rows cannot be deleted; retire or revoke instead', tg_table_name
    using errcode = 'insufficient_privilege';
end $$;

-- A record's audit key goes only with the record.
create function audit.record_key_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' and exists (select 1 from core.disposal_row d join core.disposal_batch b on b.id = d.batch_id
                                   where d.table_name = old.table_name and d.record_id = old.record_id
                                     and d.xact_id = pg_current_xact_id() and b.status = 'confirmed') then
    return old;
  end if;
  raise exception 'audit record keys change only when their record is disposed of' using errcode = 'insufficient_privilege';
end $$;
create trigger record_key_guard before update or delete on audit.record_key for each row execute function audit.record_key_guard();

-- Deletes rows of one table under a confirmed batch, recording their identifiers first.
create function core.dispose_rows(p_batch_id uuid, p_table regclass, p_ids uuid[]) returns integer
language plpgsql security definer set search_path = '' as $$
declare n integer; v_name text := p_table::text;
begin
  if coalesce(cardinality(p_ids), 0) = 0 then return 0; end if;
  if not exists (select 1 from core.disposal_batch where id = p_batch_id and status = 'confirmed') then
    raise exception 'disposal needs a confirmed batch' using errcode = 'insufficient_privilege';
  end if;
  insert into core.disposal_row (batch_id, table_name, record_id) select p_batch_id, v_name, x from unnest(p_ids) x;
  execute format('delete from %s where id = any ($1)', p_table) using p_ids;
  get diagnostics n = row_count;
  delete from audit.record_key where table_name = v_name and record_id = any (p_ids);
  return n;
end $$;

revoke execute on function core.retention_categories(), core.validate_retention(jsonb, boolean), core.retention_rule(uuid, text),
  core.customer_wide_rule(uuid, text), core.hold_review_on(uuid), core.person_org_ids(uuid[]), core.clean_ids(uuid[]),
  core.retention_candidates(uuid, text), core.hold_covers(core.legal_hold, core.retention_candidate),
  core.covering_holds(uuid, core.retention_candidate), core.dispose_rows(uuid, regclass, uuid[]), audit.record_key_guard() from public;
