-- 0061 Disposal of closed jobs, and of induction links, invitations and passes (phase 8d(b), D-022:
--      8d-2, 8d-4, 8d-11)
--
-- A closed job is disposed of whole (8d-4): the work package, its revisions and screening, every
-- permit with its versions, steps, decisions, information requests, snapshots, acceptances,
-- suspensions, hand-backs and close-out, its permit packs (and their stored files), corrections,
-- emergency-work links, and the physical controls that belonged only to this job. Only once every
-- permit is finished and every control, fire watch, exclusion zone and custody movement is resolved
-- (invariant 8), and nothing outside the job still points into it. Controls shared with another job
-- stay, without this job's links.
--
-- The job's records refer to each other in circles (a permit and its current version, a permit and
-- its issue snapshot, a job and its current revision). Every foreign key in core becomes deferrable,
-- still checked immediately unless a transaction says otherwise; only the confirming function defers
-- them, deletes the job's rows, and forces every check before it returns. A row outside the job that
-- still refers to one inside makes the whole confirmation fail and nothing is disposed of.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

-- ---------------------------------------------------------------------------
-- Deferrable foreign keys (behaviour unchanged unless a transaction defers them).
-- ---------------------------------------------------------------------------
do $m$
declare r record;
begin
  for r in select c.conrelid::regclass as tbl, c.conname from pg_constraint c
            where c.contype = 'f' and c.connamespace = 'core'::regnamespace and not c.condeferrable loop
    execute format('alter table %s alter constraint %I deferrable initially immediate', r.tbl, r.conname);
  end loop;
end $m$;

-- ---------------------------------------------------------------------------
-- Categories: closed jobs, and the records that hold email addresses or pass secrets (8d-11).
-- ---------------------------------------------------------------------------
create or replace function core.retention_categories() returns table (code text, name text, trigger_words text, method text, never_while text, ord integer)
language sql immutable set search_path = '' as $$
  values
  ('closed_jobs', 'Closed jobs', 'The last of the job''s permits closed, cancelled or refused (or the job cancelled); for a job that needed no permit, the end of its planned window',
   'Deleted whole: the job, its permits, decisions, snapshots, controls used only by it, and its permit packs with their files',
   'Any permit is unfinished, any control, fire watch, exclusion zone or custody item is unresolved, or a gate reconciliation exception still names a permit', 0),
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
   'The file is removed from storage; the record and the result stay', 'Never kept back except by a legal hold', 7),
  ('induction_links', 'Induction links', 'The link used, revoked or expired, whichever is first',
   'Deleted (the link holds the email address it was sent to)', 'It can still be used', 8),
  ('invitations', 'Invitations', 'The invitation accepted, declined or cancelled, or its expiry if it was never answered',
   'Deleted (it holds the invitee''s name and email address); the organisation or person it created stays', 'It can still be answered or is awaiting a match decision', 9),
  ('passes', 'Gate passes', 'The pass revoked',
   'Deleted', 'It is not revoked, or a gate check still kept names it', 10)
$$;

-- ---------------------------------------------------------------------------
-- Disposed files: documents' files and permit packs.
-- ---------------------------------------------------------------------------
alter table core.file_disposal drop constraint file_disposal_customer_id_document_version_id_fkey;
alter table core.file_disposal alter column document_version_id drop not null;
alter table core.file_disposal add column export_id uuid unique;
alter table core.file_disposal drop constraint file_disposal_bucket_check;
alter table core.file_disposal add constraint file_disposal_bucket_check check (bucket in ('documents', 'evidence-packs'));
alter table core.file_disposal add constraint file_disposal_one_source
  check ((bucket = 'documents') = (document_version_id is not null and export_id is null)
         and (bucket = 'evidence-packs') = (export_id is not null and document_version_id is null));

-- ---------------------------------------------------------------------------
-- What a closed job is made of: every row the job owns, by table. Controls are included only when
-- every link they have is to this job's permits.
-- ---------------------------------------------------------------------------
create function core.job_controls(p_wp_id uuid) returns table (control_kind text, control_id uuid, only_this_job boolean)
language sql stable security definer set search_path = '' as $$
  select l.control_kind, l.control_id,
         not exists (select 1 from core.control_link_record o join core.permit op on op.id = o.permit_id
                      where o.control_kind = l.control_kind and o.control_id = l.control_id and op.work_package_id <> p_wp_id)
    from core.control_link_record l join core.permit p on p.id = l.permit_id
   where p.work_package_id = p_wp_id
   group by l.control_kind, l.control_id $$;

create function core.job_disposal_rows(p_wp_id uuid) returns table (table_name text, ids uuid[])
language sql stable security definer set search_path = '' as $$
  with p as (select id from core.permit where work_package_id = p_wp_id),
       rev as (select id from core.work_package_revision where work_package_id = p_wp_id),
       pv as (select id from core.permit_version where permit_id in (select id from p)),
       st as (select id from core.permit_step where permit_version_id in (select id from pv)),
       sd as (select id from core.step_decision where permit_step_id in (select id from st)),
       rf as (select id from core.rfi where permit_version_id in (select id from pv)),
       er as (select id from core.exception_request where permit_version_id in (select id from pv)),
       iss as (select id from core.issue_snapshot where permit_id in (select id from p)),
       su as (select id from core.permit_suspension where permit_id in (select id from p)),
       hb as (select id from core.hand_back where permit_id in (select id from p)),
       rec as (select id from core.screening_recommendation where work_package_id = p_wp_id),
       ch as (select id from core.screening_challenge where recommendation_id in (select id from rec)),
       xh as (select id from core.external_reference_hold where work_package_id = p_wp_id),
       ctl as (select control_kind, control_id from core.job_controls(p_wp_id) where only_this_job),
       cf as (select f.id from core.control_failure f join ctl on ctl.control_kind = f.control_kind and ctl.control_id = f.control_id)
  select t, coalesce(x, '{}') from (values
    ('core.work_package', array(select id from core.work_package where id = p_wp_id)),
    ('core.work_package_revision', array(select id from rev)),
    ('core.work_package_area', array(select id from core.work_package_area where revision_id in (select id from rev))),
    ('core.work_package_system', array(select id from core.work_package_system where revision_id in (select id from rev))),
    ('core.work_package_party', array(select id from core.work_package_party where revision_id in (select id from rev))),
    ('core.screening_draft', array(select id from core.screening_draft where work_package_id = p_wp_id)),
    ('core.screening_response', array(select id from core.screening_response where work_package_id = p_wp_id)),
    ('core.screening_recommendation', array(select id from rec)),
    ('core.screening_challenge', array(select id from ch)),
    ('core.challenge_decision', array(select id from core.challenge_decision where challenge_id in (select id from ch))),
    ('core.no_permit_required_decision', array(select id from core.no_permit_required_decision where work_package_id = p_wp_id)),
    ('core.external_reference_hold', array(select id from xh)),
    ('core.external_reference_evidence', array(select id from core.external_reference_evidence where hold_id in (select id from xh))),
    ('core.external_reference_decision', array(select id from core.external_reference_decision where hold_id in (select id from xh))),
    ('core.class_requirement', array(select id from core.class_requirement where work_package_id = p_wp_id)),
    ('core.access_work_request', array(select id from core.access_work_request where work_package_id = p_wp_id)),
    ('core.emergency_work', array(select id from core.emergency_work where work_package_id = p_wp_id)),
    ('core.export', array(select id from core.export where work_package_id = p_wp_id)),
    ('core.correction', array(select id from core.correction where work_package_id = p_wp_id)),
    ('core.permit', array(select id from p)),
    ('core.permit_draft', array(select id from core.permit_draft where permit_id in (select id from p))),
    ('core.permit_version', array(select id from pv)),
    ('core.permit_step', array(select id from st)),
    ('core.step_decision', array(select id from sd)),
    ('core.permit_condition', array(select id from core.permit_condition where step_decision_id in (select id from sd))),
    ('core.external_decision', array(select id from core.external_decision where step_decision_id in (select id from sd))),
    ('core.rfi', array(select id from rf)),
    ('core.rfi_response', array(select id from core.rfi_response where permit_version_id in (select id from pv))),
    ('core.exception_request', array(select id from er)),
    ('core.exception_decision', array(select id from core.exception_decision where exception_request_id in (select id from er))),
    ('core.permit_team_member', array(select id from core.permit_team_member where permit_id in (select id from p))),
    ('core.issue_snapshot', array(select id from iss)),
    ('core.permit_acceptance', array(select id from core.permit_acceptance where issue_snapshot_id in (select id from iss))),
    ('core.permit_reacceptance', array(select id from core.permit_reacceptance where permit_id in (select id from p))),
    ('core.permit_extension', array(select id from core.permit_extension where permit_id in (select id from p))),
    ('core.permit_revalidation', array(select id from core.permit_revalidation where permit_id in (select id from p))),
    ('core.permit_suspension', array(select id from su)),
    ('core.permit_suspension_lift', array(select id from core.permit_suspension_lift where suspension_id in (select id from su))),
    ('core.hand_back', array(select id from hb)),
    ('core.hand_back_decision', array(select id from core.hand_back_decision where hand_back_id in (select id from hb))),
    ('core.area_return', array(select id from core.area_return where permit_id in (select id from p))),
    ('core.permit_abandonment', array(select id from core.permit_abandonment where permit_id in (select id from p))),
    ('core.close_out_snapshot', array(select id from core.close_out_snapshot where permit_id in (select id from p))),
    ('core.fire_watch', array(select id from core.fire_watch where permit_id in (select id from p))),
    ('core.exclusion_zone', array(select id from core.exclusion_zone where permit_id in (select id from p))),
    ('core.custody_movement', array(select id from core.custody_movement where permit_id in (select id from p))),
    ('core.control_link_record', array(select id from core.control_link_record where permit_id in (select id from p))),
    ('core.isolation', array(select control_id from ctl where control_kind = 'isolation')),
    ('core.isolation_lock', array(select id from core.isolation_lock where isolation_id in (select control_id from ctl where control_kind = 'isolation'))),
    ('core.impairment', array(select control_id from ctl where control_kind = 'impairment')),
    ('core.control_event', array(select e.id from core.control_event e join ctl on ctl.control_kind = e.control_kind and ctl.control_id = e.control_id)),
    ('core.control_ownership', array(select o.id from core.control_ownership o join ctl on ctl.control_kind = o.control_kind and ctl.control_id = o.control_id)),
    ('core.control_failure', array(select id from cf)),
    ('core.control_failure_resolution', array(select id from core.control_failure_resolution where failure_id in (select id from cf)))
  ) v(t, x) $$;

-- ---------------------------------------------------------------------------
-- Candidates: the new categories.
-- ---------------------------------------------------------------------------
do $m$
declare d text; anchor text := $s$  else
    raise exception 'unknown retention category %', p_category using errcode = '22023';$s$;
begin
  d := pg_get_functiondef('core.retention_candidates(uuid,text)'::regprocedure);
  if position(anchor in d) = 0 then raise exception 'core.retention_candidates no longer has the expected structure'; end if;
  execute replace(d, anchor, $s$  elsif p_category = 'closed_jobs' then
    return query
      select * from (
        select p_category, 'core.work_package', w.id, w.venue_id,
               case when w.status = 'cancelled'
                      then (select max(sh.at) from core.status_history sh where sh.record_id = w.id and sh.to_state = 'cancelled')
                    when exists (select 1 from core.permit p where p.work_package_id = w.id)
                      then (select max(sh.at) from core.status_history sh join core.permit p on p.id = sh.record_id
                             where p.work_package_id = w.id and sh.to_state = p.status)
                    else (select upper(r.planned_window) from core.work_package_revision r where r.id = w.current_revision_id) end as t,
               core.clean_ids(array(select x from core.work_package_revision r, unnest(array[r.contact_person_id, r.supervisor_person_id, r.author_person_id]) x
                                      where r.work_package_id = w.id)
                              || array(select m.person_id from core.permit_team_member m join core.permit p on p.id = m.permit_id where p.work_package_id = w.id)
                              || array[w.created_by_person_id]),
               core.clean_ids(array[w.performing_organisation_id]
                              || array(select pa.organisation_id from core.work_package_party pa join core.work_package_revision r on r.id = pa.revision_id
                                        where r.work_package_id = w.id)),
               array[w.id],
               core.clean_ids(array(select a.authorisation_id from core.access_work_request a where a.work_package_id = w.id)),
               (select tstzrange(min(lower(r.planned_window)), null) from core.work_package_revision r where r.work_package_id = w.id)
          from core.work_package w
         where w.customer_id = p_customer_id
           and (w.status = 'cancelled'
                or (w.status = 'routed' and exists (select 1 from core.permit p where p.work_package_id = w.id))
                or (w.status = 'routed' and exists (select 1 from core.no_permit_required_decision n where n.work_package_id = w.id)))
           and not exists (select 1 from core.permit p where p.work_package_id = w.id
                            and p.status not in ('closed', 'cancelled', 'refused') and not (w.status = 'cancelled' and p.status = 'draft'))
           and not exists (select 1 from core.job_controls(w.id) c
                            where (c.control_kind = 'isolation' and (select status from core.isolation where id = c.control_id) not in ('returned', 'refused', 'withdrawn'))
                               or (c.control_kind = 'impairment' and (select status from core.impairment where id = c.control_id) not in ('restored', 'refused', 'withdrawn')))
           and not exists (select 1 from core.fire_watch f join core.permit p on p.id = f.permit_id where p.work_package_id = w.id and f.status <> 'ended')
           and not exists (select 1 from core.exclusion_zone z join core.permit p on p.id = z.permit_id where p.work_package_id = w.id and z.status <> 'removed')
           and not exists (select 1 from core.custody_movement m join core.permit p on p.id = m.permit_id where p.work_package_id = w.id and m.returned_at is null)
           and not exists (select 1 from core.reconciliation_exception x join core.permit p on p.id = x.permit_id where p.work_package_id = w.id)) z
       where z.t <= now();

  elsif p_category = 'induction_links' then
    return query
      select * from (
        select p_category, 'core.induction_link', l.id, l.venue_id,
               case when l.status = 'revoked' then l.revoked_at when l.claimed_at is not null then l.claimed_at else l.expires_at end as t,
               array[l.person_id], core.clean_ids(array[l.via_organisation_id]), '{}'::uuid[], '{}'::uuid[],
               tstzrange(l.created_at, greatest(l.created_at, l.expires_at), '[]')
          from core.induction_link l
         where l.customer_id = p_customer_id) z
       where z.t <= now();

  elsif p_category = 'invitations' then
    return query
      select * from (
        select p_category, 'core.invitation', i.id, i.venue_id,
               case when i.status in ('accepted', 'declined', 'cancelled')
                      then (select max(sh.at) from core.status_history sh where sh.record_id = i.id and sh.to_state = i.status)
                    when i.status = 'pending' then i.expires_at end as t,
               core.clean_ids(array[i.result_person_id, i.owner_person_id]), core.clean_ids(array[i.organisation_id, i.result_organisation_id]),
               '{}'::uuid[], '{}'::uuid[], tstzrange(i.created_at, greatest(i.created_at, i.expires_at), '[]')
          from core.invitation i
         where i.customer_id = p_customer_id and i.status <> 'awaiting_match') z
       where z.t <= now();

  elsif p_category = 'passes' then
    return query
      select p_category, 'core.person_pass', s.id, s.venue_id, s.revoked_at,
             array[s.person_id], core.person_org_ids(array[s.person_id]), '{}'::uuid[], '{}'::uuid[], tstzrange(least(s.created_at, s.revoked_at), greatest(s.created_at, s.revoked_at), '[]')
        from core.person_pass s
       where s.customer_id = p_customer_id and s.revoked_at is not null
         and not exists (select 1 from core.entry_eligibility_evaluation e where e.pass_id = s.id);
$s$ || anchor);
end $m$;

-- ---------------------------------------------------------------------------
-- Disposal routes for the new categories.
-- ---------------------------------------------------------------------------
create function core.dispose_job(p_batch_id uuid, p_wp_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  -- Pack files go from storage after the commit; their records go with the job.
  insert into core.file_disposal (customer_id, venue_id, export_id, batch_id, bucket, storage_path)
  select e.customer_id, e.venue_id, e.id, p_batch_id, 'evidence-packs', e.storage_path
    from core.export e where e.work_package_id = p_wp_id and e.storage_path is not null;
  set constraints all deferred;
  for r in select * from core.job_disposal_rows(p_wp_id) loop
    perform core.dispose_rows(p_batch_id, r.table_name::regclass, r.ids);
  end loop;
  -- Every reference is checked now: anything outside the job still pointing into it fails the
  -- whole confirmation, and nothing is disposed of.
  set constraints all immediate;
end $$;

do $m$
declare d text; anchor text := $s$  else
    raise exception 'no disposal route for %', c.root_table;$s$;
begin
  d := pg_get_functiondef('core.dispose_root(uuid,core.retention_candidate)'::regprocedure);
  if position(anchor in d) = 0 then raise exception 'core.dispose_root no longer has the expected structure'; end if;
  execute replace(d, anchor, $s$  elsif c.root_table = 'core.work_package' then
    perform core.dispose_job(p_batch_id, c.root_id);
  elsif c.root_table in ('core.induction_link', 'core.invitation', 'core.person_pass') then
    perform core.dispose_rows(p_batch_id, c.root_table::regclass, array[c.root_id]);
$s$ || anchor);
end $m$;

-- Labels for the people reviewing a batch.
do $m$
declare d text; anchor text := $s$    when 'core.document_version' then$s$;
begin
  d := pg_get_functiondef('core.retention_label(text,uuid,uuid)'::regprocedure);
  if position(anchor in d) = 0 then raise exception 'core.retention_label no longer has the expected structure'; end if;
  execute replace(d, anchor, $s$    when 'core.work_package' then
      (select 'Job ' || w.reference || ', ' || coalesce((select r.title from core.work_package_revision r where r.id = w.current_revision_id), '')
              || coalesce(' (' || (select legal_name from core.organisation where id = w.performing_organisation_id) || ')', '')
         from core.work_package w where w.id = p_id)
    when 'core.induction_link' then
      (select 'Induction link for ' || core.person_name(l.person_id) || ', issued ' || to_char(l.created_at, 'DD/MM/YYYY') from core.induction_link l where l.id = p_id)
    when 'core.invitation' then
      (select 'Invitation to ' || i.invitee_given_name || ' ' || i.invitee_family_name || ', ' || i.status || ', sent ' || to_char(i.created_at, 'DD/MM/YYYY')
         from core.invitation i where i.id = p_id)
    when 'core.person_pass' then
      (select 'Pass ' || s.pass_number || ' (' || core.person_name(s.person_id) || '), revoked ' || to_char(s.revoked_at, 'DD/MM/YYYY') from core.person_pass s where s.id = p_id)
$s$ || anchor);
end $m$;

-- The file removal job now handles pack files too.
do $m$
declare d text;
begin
  d := pg_get_functiondef('api.claim_file_removals(integer,integer)'::regprocedure);
  if position($s$'bucket', f.bucket, 'storage_path', f.storage_path$s$ in d) = 0 then
    raise exception 'api.claim_file_removals no longer has the expected structure';
  end if;
end $m$;

revoke execute on function core.job_controls(uuid), core.job_disposal_rows(uuid), core.dispose_job(uuid, uuid) from public;
