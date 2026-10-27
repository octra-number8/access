-- 0056 Evidence and history (phase 8c, D-021: Q211, Q213–Q217, P8-8 to P8-12): catalogue, the
--      export and correction records, record history, and the pack's content
--
-- A permit pack is built only from frozen evidence: the issue and close-out snapshots, the
-- document versions they name, and the audit log (P8-8). Its content is fixed when it is
-- requested, with its hash; a service account then builds the files and records their hashes,
-- so nobody who asks for a pack can supply or replace one. The external profile removes contact
-- and personal details (Q214); who decided what, under which appointment and when, is never
-- removed (P8-9). History shows each decision on a record from the audit log, without raw
-- values (P8-11). A correction is recorded beside a frozen record and never changes it (P8-12).
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only: export and correction
-- records are never rewritten, and a pack that was handed over stays as it was.

insert into core.authority_action (code, basis, delegable, description) values
  ('evidence.export',     'appointment', false, 'Make a permit pack of frozen evidence for someone outside Octra (Q213)'),
  ('record.correct',      'appointment', false, 'Record a correction beside a frozen record (Q216)'),
  ('evidence.build_pack', 'service',     false, 'Build a requested permit pack and record its files and hashes');

alter table core.service_account drop constraint service_account_purpose_check;
alter table core.service_account add constraint service_account_purpose_check
  check (purpose in ('malware_scanner', 'notification_sender', 'permit_expiry', 'job_runner', 'pack_builder'));
insert into core.service_action (purpose, action_code) values ('pack_builder', 'evidence.build_pack');

-- Evidence officers and correction appointees see the jobs at their venue, as other appointees do.
do $m$
declare d text;
begin
  d := pg_get_functiondef('authz.visible_work_package_ids()'::regprocedure);
  if position('''emergency.authorise'']' in d) = 0 then
    raise exception 'authz.visible_work_package_ids no longer has the expected structure';
  end if;
  execute replace(d, '''emergency.authorise'']', '''emergency.authorise'', ''evidence.export'', ''record.correct'']');
end $m$;

-- Defect fix (phase 5): a proposed permit class version stored its SHA-256 as the hex text's
-- bytes (64 bytes), so issue snapshots and packs showed a hash of the wrong form. From now on
-- the digest itself is stored. Versions proposed before this keep what they recorded.
do $m$
declare d text;
begin
  d := pg_get_functiondef('api.propose_class_version(text,uuid,integer)'::regprocedure);
  if position('''content_sha256'', encode(sha256(convert_to(c.content::text, ''UTF8'')), ''hex'')' in d) = 0 then
    raise exception 'api.propose_class_version no longer has the expected structure';
  end if;
  execute replace(d, '''content_sha256'', encode(sha256(convert_to(c.content::text, ''UTF8'')), ''hex'')',
                     '''content_sha256'', ''\x'' || encode(sha256(convert_to(c.content::text, ''UTF8'')), ''hex'')');
end $m$;

-- History looks events up by record and by decision.
create index audit_event_target_id_idx on audit.audit_event (target_id);
create index audit_event_context_idx on audit.audit_event (decision_context_id);

-- ---------------------------------------------------------------------------
-- Exports (CLAUDE.md §3): every pack, and every report download, with who, why and what.
-- A pack's content and hash are fixed at request; only its build fields change, once.
-- ---------------------------------------------------------------------------
create table core.export (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  venue_id             uuid not null,
  kind                 text not null check (kind in ('permit_pack', 'report_csv')),
  reference            text not null,
  work_package_id      uuid references core.work_package,
  purpose              text check (length(btrim(purpose)) between 1 and 500),
  recipient            text check (length(btrim(recipient)) between 1 and 300),
  profile              text check (profile in ('external', 'internal')),
  omissions            jsonb not null default '[]',
  scope                jsonb not null,
  content              jsonb,
  content_sha256       bytea check (length(content_sha256) = 32),
  made_by_person_id    uuid not null,
  decision_context_id  uuid references core.decision_context,
  build_state          text check (build_state in ('queued', 'ready', 'failed')),
  attempts             integer not null default 0,
  leased_until         timestamptz,
  build_error          text,
  files                jsonb,
  pack_sha256          bytea check (length(pack_sha256) = 32),
  pack_bytes           bigint,
  storage_path         text unique,
  built_at             timestamptz,
  row_version          integer not null default 1,
  created_at           timestamptz not null default now(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, made_by_person_id) references core.person (customer_id, id),
  unique (customer_id, reference),
  check ((kind = 'permit_pack') = (work_package_id is not null)),
  check (kind <> 'permit_pack' or (purpose is not null and recipient is not null and profile is not null and content is not null
                                   and content_sha256 is not null and decision_context_id is not null and build_state is not null)),
  check (kind = 'permit_pack' or (content is null and build_state is null)),
  check ((build_state = 'ready') = (pack_sha256 is not null and files is not null and storage_path is not null and built_at is not null))
);
create index export_work_package_idx on core.export (work_package_id);
select core.attach_standard_triggers('core.export', 'build_state,attempts,leased_until,build_error,files,pack_sha256,pack_bytes,storage_path,built_at');

-- A finished pack never changes: a different pack is a new one (invariant 5).
create function core.export_finished() returns trigger
language plpgsql set search_path = '' as $$
begin
  if old.build_state in ('ready', 'failed') then
    raise exception 'a finished pack never changes: make a new one' using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;
create trigger b0_export_finished before update on core.export for each row execute function core.export_finished();

-- ---------------------------------------------------------------------------
-- Corrections (Q216, P8-12): beside a frozen record of a job, never over it.
-- ---------------------------------------------------------------------------
create table core.correction (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  venue_id              uuid not null,
  work_package_id       uuid not null references core.work_package,
  permit_id             uuid not null references core.permit,
  target_type           text not null check (target_type in ('issue_snapshot', 'close_out_snapshot', 'step_decision', 'hand_back_decision')),
  target_id             uuid not null,
  about                 text not null check (length(btrim(about)) between 1 and 300),
  was                   text not null check (length(btrim(was)) between 1 and 2000),
  corrected             text not null check (length(btrim(corrected)) between 1 and 2000),
  reason                text not null check (length(btrim(reason)) between 1 and 2000),
  evidence              text not null check (length(btrim(evidence)) between 1 and 2000),
  recorded_by_person_id uuid not null,
  decision_context_id   uuid not null references core.decision_context,
  row_version           integer not null default 1,
  created_at            timestamptz not null default clock_timestamp(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, recorded_by_person_id) references core.person (customer_id, id),
  check (was is distinct from corrected)
);
create index correction_permit_idx on core.correction (permit_id);
select core.attach_standard_triggers('core.correction', null);

-- ---------------------------------------------------------------------------
-- Which records belong to a job (or one of its permits): the set history and packs read.
-- ---------------------------------------------------------------------------
create function core.job_record_ids(p_wp_id uuid, p_permit_id uuid default null) returns uuid[]
language sql stable security definer set search_path = '' as $$
  with p as (select id from core.permit where work_package_id = p_wp_id and (p_permit_id is null or id = p_permit_id)),
       v as (select id from core.permit_version where permit_id in (select id from p)),
       st as (select id from core.permit_step where permit_version_id in (select id from v)),
       sd as (select id from core.step_decision where permit_step_id in (select id from st)),
       rf as (select id from core.rfi where permit_version_id in (select id from v)),
       er as (select id from core.exception_request where permit_version_id in (select id from v)),
       iss as (select id from core.issue_snapshot where permit_id in (select id from p)),
       su as (select id from core.permit_suspension where permit_id in (select id from p)),
       hb as (select id from core.hand_back where permit_id in (select id from p)),
       ctl as (select distinct control_id as id from core.control_link_record where permit_id in (select id from p))
  select coalesce(array_agg(distinct x), '{}') from (
    select id x from p union all select id from v union all select id from st union all select id from sd
    union all select id from core.permit_condition where step_decision_id in (select id from sd)
    union all select id from core.external_decision where step_decision_id in (select id from sd)
    union all select id from rf union all select id from core.rfi_response where rfi_id in (select id from rf)
    union all select id from er union all select id from core.exception_decision where exception_request_id in (select id from er)
    union all select id from iss union all select id from core.permit_acceptance where issue_snapshot_id in (select id from iss)
    union all select id from core.permit_draft where permit_id in (select id from p)
    union all select id from core.permit_team_member where permit_id in (select id from p)
    union all select id from core.permit_extension where permit_id in (select id from p)
    union all select id from core.permit_reacceptance where permit_id in (select id from p)
    union all select id from core.permit_revalidation where permit_id in (select id from p)
    union all select id from su union all select id from core.permit_suspension_lift where suspension_id in (select id from su)
    union all select id from hb union all select id from core.hand_back_decision where hand_back_id in (select id from hb)
    union all select id from core.area_return where permit_id in (select id from p)
    union all select id from core.close_out_snapshot where permit_id in (select id from p)
    union all select id from core.permit_abandonment where permit_id in (select id from p)
    union all select id from core.custody_movement where permit_id in (select id from p)
    union all select id from core.exclusion_zone where permit_id in (select id from p)
    union all select id from core.fire_watch where permit_id in (select id from p)
    union all select id from core.reconciliation_exception where permit_id in (select id from p)
    union all select id from core.control_link_record where permit_id in (select id from p)
    union all select id from ctl
    union all select id from core.control_event where control_id in (select id from ctl)
    union all select id from core.control_failure where control_id in (select id from ctl)
    union all select id from core.control_ownership where control_id in (select id from ctl)
    union all select id from core.correction where permit_id in (select id from p)
    -- The job's own records, unless only one permit was asked for.
    union all select p_wp_id where p_permit_id is null
    union all select id from core.work_package_revision where work_package_id = p_wp_id and p_permit_id is null
    union all select id from core.screening_response where work_package_id = p_wp_id and p_permit_id is null
    union all select id from core.screening_recommendation where work_package_id = p_wp_id and p_permit_id is null
    union all select id from core.no_permit_required_decision where work_package_id = p_wp_id and p_permit_id is null
    union all select id from core.class_requirement where work_package_id = p_wp_id and p_permit_id is null
    union all select id from core.external_reference_hold where work_package_id = p_wp_id and p_permit_id is null
    union all select id from core.emergency_work where work_package_id = p_wp_id and p_permit_id is null
    union all select id from core.export where work_package_id = p_wp_id and p_permit_id is null) z $$;

-- The records of a person, an organisation or a visit, for their history.
create function core.person_record_ids(p_person_id uuid) returns uuid[]
language sql stable security definer set search_path = '' as $$
  with d as (select id from core.document where person_id = p_person_id),
       dv as (select id from core.document_version where document_id in (select id from d)),
       c as (select id from core.competency where person_id = p_person_id)
  select coalesce(array_agg(distinct x), '{}') from (
    select p_person_id x
    union all select id from core.user_account where person_id = p_person_id
    union all select id from core.person_organisation_relationship where person_id = p_person_id
    union all select id from d union all select id from dv
    union all select id from core.review_decision where document_version_id in (select id from dv)
    union all select id from c union all select id from core.competency_verification where competency_id in (select id from c)
    union all select id from core.induction_completion where person_id = p_person_id
    union all select id from core.restriction where person_id = p_person_id) z $$;

create function core.organisation_record_ids(p_organisation_id uuid) returns uuid[]
language sql stable security definer set search_path = '' as $$
  with d as (select id from core.document where organisation_id = p_organisation_id),
       dv as (select id from core.document_version where document_id in (select id from d))
  select coalesce(array_agg(distinct x), '{}') from (
    select p_organisation_id x
    union all select id from core.engagement where organisation_id = p_organisation_id
    union all select id from core.organisation_admin where organisation_id = p_organisation_id
    union all select id from core.person_organisation_relationship where organisation_id = p_organisation_id
    union all select id from core.invitation where organisation_id = p_organisation_id
    union all select id from d union all select id from dv
    union all select id from core.review_decision where document_version_id in (select id from dv)
    union all select id from core.restriction where organisation_id = p_organisation_id) z $$;

create function core.visit_record_ids(p_access_id uuid) returns uuid[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(distinct x), '{}') from (
    select p_access_id x
    union all select id from core.access_roster_member where authorisation_id = p_access_id
    union all select id from core.access_consent where authorisation_id = p_access_id
    union all select id from core.visit_attendance where authorisation_id = p_access_id) z $$;

-- ---------------------------------------------------------------------------
-- History (Q217, P8-11): each decision that touched the records, from the decision contexts and
-- the audit log: who, in which capacity, what, when, any change of recorded state, and the reason
-- where one was given. Never raw values. The grounds of a restriction are shown only to the
-- venue's side (Q214, P5-6).
-- ---------------------------------------------------------------------------
create function core.capacity_words(dc core.decision_context) returns text
language sql stable security definer set search_path = '' as $$
  select case
    when dc.acting_appointment_id is not null then
      (select t.name from core.appointment a join core.appointment_type_version tv on tv.id = a.appointment_type_version_id
         join core.appointment_type t on t.id = tv.appointment_type_id where a.id = dc.acting_appointment_id)
    when dc.acting_delegation_id is not null then
      (select 'Delegated by ' || core.person_name(g.delegator_person_id) || ' (' || t.name || ')' from core.delegation g
         join core.appointment a on a.id = g.delegator_appointment_id
         join core.appointment_type_version tv on tv.id = a.appointment_type_version_id
         join core.appointment_type t on t.id = tv.appointment_type_id where g.id = dc.acting_delegation_id)
    when dc.basis = 'tenant_admin' then 'tenant administrator (no operational authority)'
    when dc.basis = 'organisation_admin' then 'their organisation''s administrator'
    when dc.basis = 'subject' then 'the person concerned'
    when dc.basis = 'derived' then 'part of another decision they made'
    when dc.basis = 'permit_part' then 'someone named on the permit'
    when dc.basis = 'invitee' then 'the person invited'
    when dc.basis = 'link_holder' then 'the holder of an induction link'
    when dc.basis = 'platform_admin' then 'Octra platform administrator'
    when dc.basis = 'service' then 'an Octra service'
    else replace(dc.basis, '_', ' ') end $$;

-- The reason an audited row records, whatever its column is called.
create function core.event_reason(p_reason text, p_change jsonb) returns text
language sql immutable set search_path = '' as $$
  select coalesce(p_reason,
    (select coalesce(p_change -> 'new' ->> k, p_change #>> array['changed', k, 'new'])
       from unnest(array['reason', 'decision_reason', 'lift_reason', 'unlinked_reason', 'change_reason', 'cancel_reason', 'removal_reason']) with ordinality u(k, o)
      where coalesce(p_change -> 'new' ->> k, p_change #>> array['changed', k, 'new']) is not null
      order by o limit 1)) $$;

-- Actions whose reason is the grounds of a restriction.
create function core.restriction_action(p_action text) returns boolean
language sql immutable set search_path = '' as $$
  select p_action in ('person.restrict', 'person.lift_restriction', 'organisation.restrict', 'organisation.lift_restriction',
                      'engagement.suspend', 'engagement.reinstate') $$;

create function core.history(p_customer_id uuid, p_ids uuid[], p_venue_side boolean) returns jsonb
language sql stable security definer set search_path = '' as $$
  with ctx as (
    select dc.* from core.decision_context dc
     where dc.customer_id = p_customer_id
       and (dc.target_id = any (p_ids)
            or dc.id in (select a.decision_context_id from audit.audit_event a
                          where a.target_id = any (p_ids) and a.decision_context_id is not null and a.customer_id = p_customer_id)))
  select coalesce(jsonb_agg(jsonb_build_object(
      'at', dc.created_at,
      'action', dc.action_code,
      'what', aa.description,
      -- Someone accepting an invitation has no person record until that decision makes one.
      'who', coalesce(core.person_name(dc.actor_person_id),
                      core.person_name((select ua.person_id from core.user_account ua
                                         where ua.auth_user_id = dc.actor_user_id and ua.customer_id = dc.customer_id limit 1)),
                      'Unknown person'),
      'capacity', core.capacity_words(dc),
      'changes', (select coalesce(jsonb_agg(jsonb_build_object('record', replace(sh.table_name, 'core.', ''), 'from', sh.from_state, 'to', sh.to_state)
                                            order by sh.id), '[]')
                    from core.status_history sh where sh.decision_context_id = dc.id),
      'reason', case when not p_venue_side and core.restriction_action(dc.action_code) then null
                     else (select r from (select core.event_reason(a.reason, a.change) r, a.id from audit.audit_event a
                                           where a.decision_context_id = dc.id and a.action like 'row.%') z
                            where r is not null order by id limit 1) end,
      'grounds_withheld', not p_venue_side and core.restriction_action(dc.action_code),
      'seq', (select a.chain_seq from audit.audit_event a where a.target_table = 'core.decision_context' and a.target_id = dc.id limit 1),
      'hash', (select encode(a.hash, 'hex') from audit.audit_event a where a.target_table = 'core.decision_context' and a.target_id = dc.id limit 1))
    order by dc.created_at, dc.id), '[]')
  from ctx dc join core.authority_action aa on aa.code = dc.action_code $$;

-- The venue's side for records held at customer level (people, organisations).
create function authz.customer_side(p_customer_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_customer_id in (select authz.my_admin_customer_ids())
      or exists (select 1 from core.venue v where v.customer_id = p_customer_id and v.id in (select authz.my_appointee_venue_ids())) $$;

-- ---------------------------------------------------------------------------
-- Redaction for the external profile (Q214, P8-9): contact and personal fields are removed by
-- name, and email addresses and telephone numbers are removed from free text. Identifiers,
-- dates and hashes are left alone. Names are never removed: who decided is the evidence.
-- ---------------------------------------------------------------------------
create function core.scrub_text(s text) returns text
language plpgsql immutable set search_path = '' as $$
declare m text; out text := s;
begin
  if s ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' or s ~ '^\d{4}-\d{2}-\d{2}([T ][0-9:.+-]+Z?)?$'
     or s ~ '^[0-9a-f]{64}$' then
    return s;
  end if;
  out := regexp_replace(out, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '[email address removed]', 'g');
  for m in select (regexp_matches(out, '\+?\(?\d[\d ().-]{7,}\d', 'g'))[1] loop
    if length(regexp_replace(m, '\D', '', 'g')) between 10 and 15 then
      out := replace(out, m, '[phone number removed]');
    end if;
  end loop;
  return out;
end $$;

create function core.pack_scrub(j jsonb) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare k text; v jsonb; out jsonb := '{}';
begin
  case jsonb_typeof(j)
    when 'object' then
      for k, v in select * from jsonb_each(j) loop
        if k ~* '(phone|e_?mail|address|contacts?$|emergency_contact|medical|date_of_birth|passport|national_insurance)' then
          out := out || jsonb_build_object(k, '[Removed: contact or personal detail]');
        else
          out := out || jsonb_build_object(k, core.pack_scrub(v));
        end if;
      end loop;
      return out;
    when 'array' then
      return coalesce((select jsonb_agg(core.pack_scrub(e) order by o) from jsonb_array_elements(j) with ordinality x(e, o)), '[]');
    when 'string' then
      return to_jsonb(core.scrub_text(j #>> '{}'));
    else
      return j;
  end case;
end $$;

-- How often a marker appears in a text.
create function core.occurrences(p_text text, p_marker text) returns integer
language sql immutable set search_path = '' as $$
  select (length(p_text) - length(replace(p_text, p_marker, ''))) / length(p_marker) $$;

-- The evidence files a job's issued permits name, with whether each goes into a pack. A file is
-- released as documents are (D-014): scanned clean, or recorded as not scanned while scanning is
-- off, which the pack states.
create function core.pack_files(p_wp_id uuid, p_profile text, p_omissions jsonb) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'version_id', dv.id, 'title', d.title, 'type', dt.label, 'version_no', dv.version_no, 'owner_kind', d.owner_kind,
      'owner', coalesce((select o.legal_name from core.organisation o where o.id = d.organisation_id), core.person_name(d.person_id)),
      'media_type', dv.media_type, 'bytes', dv.size_bytes, 'sha256', encode(dv.sha256, 'hex'), 'scan_status', dv.scan_status,
      'included', w.why is null,
      'omitted_reason', w.why,
      'name_in_pack', case when w.why is null then 'evidence/' || lpad(f.n::text, 2, '0') || '-' ||
                             left(trim(both '-' from regexp_replace(lower(d.title), '[^a-z0-9]+', '-', 'g')), 40) ||
                             case dv.media_type when 'application/pdf' then '.pdf' when 'image/png' then '.png' when 'image/jpeg' then '.jpg' else '' end end)
    order by f.n), '[]')
  from (select x.vid, row_number() over (order by min(x.at), x.vid) n
          from (select (jsonb_array_elements_text(s.content #> '{version,documents}'))::uuid vid, s.issued_at at
                  from core.issue_snapshot s join core.permit p on p.id = s.permit_id where p.work_package_id = p_wp_id) x
         group by x.vid) f
  join core.document_version dv on dv.id = f.vid
  join core.document d on d.id = dv.document_id
  join core.document_type dt on dt.id = d.document_type_id
  cross join lateral (select case
      when dv.scan_status = 'pending' then 'Not released: still waiting for the malware check'
      when dv.scan_status not in ('clean', 'not_scanned') then 'Not released: the file failed the malware check'
      when p_profile = 'external' and d.owner_kind = 'person' then 'A person''s own document: left out of external packs (Q214)'
      else (select o ->> 'reason' from jsonb_array_elements(p_omissions) o where o ->> 'item' = 'file:' || dv.id::text) end as why) w $$;

-- The pack's content, fixed at request (P8-8, Q213). Snapshots are reproduced as frozen, with
-- dictionaries that name the people, appointments, areas and organisations they refer to.
create function core.pack_content(p_export_id uuid, p_reference text, p_wp_id uuid, p_profile text, p_omissions jsonb, p_meta jsonb)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  wp core.work_package; vn core.venue; ids uuid[]; permits jsonb; job jsonb; files jsonb; chron jsonb; verification jsonb;
  corrections jsonb; contacts jsonb; content jsonb; t text; dict jsonb; omissions jsonb;
begin
  select * into wp from core.work_package where id = p_wp_id;
  select * into vn from core.venue where id = wp.venue_id;
  ids := core.job_record_ids(p_wp_id, null);

  -- Each permit with its frozen evidence; answers left out where the exporter chose, with the reason.
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'class', pc.name, 'kind', p.kind, 'parent_permit_id', p.parent_permit_id,
      'state_when_made', p.status,
      'closed', exists (select 1 from core.close_out_snapshot c where c.permit_id = p.id),
      'issue_snapshots', (select coalesce(jsonb_agg(jsonb_build_object(
            'id', s.id, 'issued_at', s.issued_at, 'sha256', encode(s.content_sha256, 'hex'),
            'content', case when om.reason is null then s.content
                            else jsonb_set(s.content, '{version,answers}', to_jsonb('[Omitted by the exporter: ' || om.reason || ']')) end)
          order by s.issued_at), '[]') from core.issue_snapshot s where s.permit_id = p.id),
      'close_out', (select jsonb_build_object('id', c.id, 'at', c.created_at, 'sha256', encode(c.content_sha256, 'hex'), 'content', c.content)
                      from core.close_out_snapshot c where c.permit_id = p.id))
    order by (p.kind <> 'work_approval'), p.created_at, p.id), '[]')
    into permits
    from core.permit p join core.permit_class pc on pc.id = p.permit_class_id
    left join lateral (select o ->> 'reason' as reason from jsonb_array_elements(p_omissions) o where o ->> 'item' = 'answers:' || p.id::text limit 1) om on true
   where p.work_package_id = p_wp_id and exists (select 1 from core.issue_snapshot s where s.permit_id = p.id);

  -- The job as frozen in its most recent issue snapshot (the Work Approval's first).
  select s.content -> 'job' into job from core.issue_snapshot s join core.permit p on p.id = s.permit_id
   where p.work_package_id = p_wp_id order by (p.kind <> 'work_approval'), s.issued_at desc limit 1;

  files := core.pack_files(p_wp_id, p_profile, p_omissions);
  chron := core.history(wp.customer_id, ids, true);
  verification := jsonb_build_object(
    'checked_at', clock_timestamp(),
    'events_in_chain', (select count(*) from audit.audit_event a where a.customer_id = wp.customer_id),
    'events_in_pack', jsonb_array_length(chron),
    'problems', (select coalesce(jsonb_agg(jsonb_build_object('seq', v.chain_seq, 'problem', v.problem) order by v.chain_seq), '[]')
                   from audit.verify_chain(wp.customer_id) v));
  corrections := (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'permit_id', c.permit_id, 'target_type', c.target_type, 'target_id', c.target_id,
                                                               'about', c.about, 'was', c.was, 'corrected', c.corrected, 'reason', c.reason,
                                                               'evidence', c.evidence, 'by', c.recorded_by_person_id, 'at', c.created_at)
                                            order by c.created_at), '[]')
                    from core.correction c where c.work_package_id = p_wp_id);

  -- Internal packs keep the contact details recorded for the job (Q214); external packs never have them.
  if p_profile = 'internal' then
    contacts := jsonb_build_object(
      'people', (select coalesce(jsonb_agg(jsonb_build_object('role', x.role, 'person_id', x.pid, 'email', pc.email, 'phone', pc.phone)), '[]')
                   from (select 'Job contact' role, r.contact_person_id pid from core.work_package_revision r where r.id = wp.current_revision_id
                         union all
                         select 'Supervisor', r.supervisor_person_id from core.work_package_revision r
                          where r.id = wp.current_revision_id and r.supervisor_person_id is not null) x
                   left join core.person_contact pc on pc.person_id = x.pid),
      'venue_emergency_contacts', (select e.contacts from core.venue_emergency_contacts e where e.venue_id = wp.venue_id and e.effective_from <= now()
                                    order by e.effective_from desc limit 1));
  end if;

  content := jsonb_build_object(
    'format', 'octra-permit-pack/1',
    'export_id', p_export_id,
    'reference', p_reference,
    'venue', jsonb_build_object('id', vn.id, 'name', vn.name, 'timezone', vn.timezone),
    'made_at', clock_timestamp(),
    'made_by', p_meta -> 'made_by',
    'purpose', p_meta ->> 'purpose',
    'recipient', p_meta ->> 'recipient',
    'profile', p_profile,
    'statement', 'This pack reproduces records frozen in Octra Access when each decision was made, and the audit log of those decisions. '
                 || 'A recorded status means a decision was recorded, nothing more. Octra does not certify competence, approve engineering '
                 || 'design or guarantee compliance, and nothing in this pack says that work was safe or compliant.',
    'profile_rules', case p_profile
      when 'external' then jsonb_build_array(
        'Telephone numbers and email addresses are removed, from recorded fields and from free text.',
        'Home addresses and emergency contacts are removed where they are recorded as fields. Free text is not checked for addresses: the person who made the pack reviews it before sending.',
        'Identity document details, medical and HR information are not included.',
        'A person''s own documents (for example certificates and cards) are left out.',
        'The grounds of any restriction are not included.')
      else jsonb_build_array(
        'For the venue''s own investigation: the contact details recorded for the job are kept.',
        'Identity document details, medical and HR information are not included.',
        'The grounds of any restriction are not included.') end,
    'never_removed', 'Who made each decision, under which appointment, and when.',
    'omissions', p_omissions,
    'job', coalesce(job, '{}') || jsonb_build_object('reference', wp.reference),
    'permits', permits,
    'not_issued', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'class', pc.name, 'state_when_made', p.status) order by p.created_at), '[]')
                     from core.permit p join core.permit_class pc on pc.id = p.permit_class_id
                    where p.work_package_id = p_wp_id and not exists (select 1 from core.issue_snapshot s where s.permit_id = p.id)),
    'files', files,
    'corrections', corrections,
    'contacts', contacts,
    'chronology', chron,
    'verification', verification);

  if p_profile = 'external' then
    content := content || jsonb_build_object('job', core.pack_scrub(content -> 'job'), 'permits', core.pack_scrub(content -> 'permits'),
                                             'corrections', core.pack_scrub(content -> 'corrections'), 'chronology', core.pack_scrub(content -> 'chronology'));
    t := content::text;
    content := content || jsonb_build_object('redactions', jsonb_build_object(
      'fields', core.occurrences(t, '[Removed: contact or personal detail]'),
      'email_addresses', core.occurrences(t, '[email address removed]'),
      'phone_numbers', core.occurrences(t, '[phone number removed]')));
  end if;

  -- Dictionaries for every identifier the content mentions, named as at the time the pack was made.
  t := content::text;
  with u as (select distinct m[1]::uuid id from regexp_matches(t, '"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"', 'g') m)
  select jsonb_build_object(
    'people', (select coalesce(jsonb_object_agg(x.id, x.given_name || ' ' || x.family_name), '{}') from core.person x
                where x.id in (select id from u) and x.customer_id = wp.customer_id),
    'appointments', (select coalesce(jsonb_object_agg(a.id, jsonb_build_object('type', ty.name, 'holder', core.person_name(a.appointee_person_id))), '{}')
                       from core.appointment a join core.appointment_type_version tv on tv.id = a.appointment_type_version_id
                       join core.appointment_type ty on ty.id = tv.appointment_type_id
                      where a.id in (select id from u) and a.customer_id = wp.customer_id),
    'areas', (select coalesce(jsonb_object_agg(a.id, a.name), '{}') from core.area a where a.id in (select id from u) and a.customer_id = wp.customer_id),
    'organisations', (select coalesce(jsonb_object_agg(o.id, o.legal_name), '{}') from core.organisation o
                       where o.id in (select id from u) and o.customer_id = wp.customer_id),
    'permits', (select coalesce(jsonb_object_agg(p.id, pc.name), '{}') from core.permit p join core.permit_class pc on pc.id = p.permit_class_id
                 where p.id in (select id from u) and p.customer_id = wp.customer_id))
    into dict;
  return content || jsonb_build_object('names', dict);
end $$;
