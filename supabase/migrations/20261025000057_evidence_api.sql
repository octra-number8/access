-- 0057 Evidence and history (phase 8c): packs requested by an evidence.export appointee and
--      built by the pack builder service, report downloads recorded, record history, and
--      corrections.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

-- ---------------------------------------------------------------------------
-- Authority targets
-- ---------------------------------------------------------------------------
-- A pack covers a whole job, so the authority must cover the job's Work Approval: its class
-- and the job's places (P8-8).
create function core.export_target(p_wp_id uuid, p_record_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select core.wp_target(wp, p_record_id, 'export', null) || core.revision_scope(wp.current_revision_id)
         || jsonb_build_object('permit_class_id', wa.permit_class_id)
    from core.work_package wp join core.permit wa on wa.work_package_id = wp.id and wa.kind = 'work_approval'
   where wp.id = p_wp_id $$;

-- The frozen records of a permit that can carry a correction, with who made each one.
create function core.correctable(p_permit_id uuid) returns table (target_type text, target_id uuid, label text, author_person_id uuid, at timestamptz)
language sql stable security definer set search_path = '' as $$
  select 'issue_snapshot', s.id, 'The permit as issued', s.issuer_person_id, s.issued_at
    from core.issue_snapshot s where s.permit_id = p_permit_id
  union all
  select 'close_out_snapshot', c.id, 'The record of closure', dc.actor_person_id, c.created_at
    from core.close_out_snapshot c join core.decision_context dc on dc.id = c.decision_context_id where c.permit_id = p_permit_id
  union all
  select 'step_decision', d.id, s.name || ': decision', d.decider_person_id, d.created_at
    from core.step_decision d join core.permit_step s on s.id = d.permit_step_id
    join core.permit_version v on v.id = s.permit_version_id where v.permit_id = p_permit_id
  union all
  select 'hand_back_decision', d.id, 'Hand-back decision', d.decider_person_id, d.created_at
    from core.hand_back_decision d join core.hand_back h on h.id = d.hand_back_id where h.permit_id = p_permit_id $$;

-- ---------------------------------------------------------------------------
-- Permit packs (Q213, Q214, P8-8, P8-9)
--   p_omissions: [{item: "file:<document version id>" | "answers:<permit id>", reason}]
-- ---------------------------------------------------------------------------
create function api.request_permit_pack(p_idempotency_key text, p_permit_id uuid, p_purpose text, p_recipient text, p_profile text,
                                        p_omissions jsonb default '[]',
                                        p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  p core.permit; wp core.work_package; t jsonb; r jsonb; v jsonb; ctx uuid; e_id uuid := gen_random_uuid(); ref text;
  errs text[] := '{}'; o jsonb; files jsonb; content jsonb; omissions jsonb := '[]';
begin
  select * into p from core.permit where id = p_permit_id;
  select * into wp from core.work_package where id = p.work_package_id;
  if wp.id is null then
    return core.refuse('evidence.export', 'not_found', 'The record does not exist or you do not have access to it.', 'Access to this permit', 'The venue');
  end if;
  t := core.export_target(wp.id, e_id);
  r := jsonb_build_object('permit_id', p_permit_id, 'purpose', p_purpose, 'recipient', p_recipient, 'profile', p_profile, 'omissions', p_omissions);
  -- A repeated request replays the original pack, whose record id was new the first time.
  if exists (select 1 from core.decision_context where actor_user_id = auth.uid() and action_code = 'evidence.export' and idempotency_key = p_idempotency_key) then
    return authz.require('evidence.export', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  end if;
  v := core.authorised_or_refusal('evidence.export', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;

  if length(btrim(coalesce(p_purpose, ''))) not between 1 and 500 then errs := errs || text 'State what the pack is for.'; end if;
  if length(btrim(coalesce(p_recipient, ''))) not between 1 and 300 then errs := errs || text 'Name who will receive it.'; end if;
  if p_profile is null or p_profile not in ('external', 'internal') then errs := errs || text 'Choose external or internal.'; end if;
  if jsonb_typeof(coalesce(p_omissions, '[]')) <> 'array' then
    errs := errs || text 'Omissions must be a list.';
  else
    files := core.pack_files(wp.id, coalesce(p_profile, 'external'), '[]');
    for o in select * from jsonb_array_elements(p_omissions) loop
      if length(btrim(coalesce(o ->> 'reason', ''))) not between 1 and 500 then
        errs := errs || text 'Every omission needs a reason (P8-9).';
      elsif not ((o ->> 'item') in (select 'file:' || (f ->> 'version_id') from jsonb_array_elements(files) f)
                 or (o ->> 'item') in (select 'answers:' || x.id::text from core.permit x
                                        where x.work_package_id = wp.id and exists (select 1 from core.issue_snapshot s where s.permit_id = x.id))) then
        errs := errs || ('This pack has nothing called ' || coalesce(o ->> 'item', '(blank)') || ' to leave out.');
      else
        omissions := omissions || jsonb_build_array(jsonb_build_object('item', o ->> 'item', 'reason', btrim(o ->> 'reason'),
          'what', case when o ->> 'item' like 'file:%'
                       then (select 'Evidence file: ' || (f ->> 'title') from jsonb_array_elements(files) f where 'file:' || (f ->> 'version_id') = o ->> 'item')
                       else (select 'Answers to the ' || pc.name || ' questions' from core.permit x join core.permit_class pc on pc.id = x.permit_class_id
                              where 'answers:' || x.id::text = o ->> 'item') end));
      end if;
    end loop;
  end if;
  if not exists (select 1 from core.issue_snapshot s join core.permit x on x.id = s.permit_id where x.work_package_id = wp.id) then
    errs := errs || text 'Nothing on this job has been issued, so there is no frozen evidence to put in a pack.';
  end if;
  if cardinality(errs) > 0 then
    return core.refuse('evidence.export', 'invalid_content', 'The pack cannot be made as asked.', array_to_string(errs, ' '), 'You',
                       jsonb_build_object('problems', to_jsonb(errs)));
  end if;

  v := authz.require('evidence.export', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ctx := (v ->> 'decision_context_id')::uuid;
  perform pg_advisory_xact_lock(hashtextextended('octra.pack:' || wp.id::text, 0));
  ref := 'PK-' || wp.reference || '-' || lpad(((select count(*) from core.export x where x.work_package_id = wp.id) + 1)::text, 2, '0');
  content := core.pack_content(e_id, ref, wp.id, p_profile, omissions, jsonb_build_object(
    'purpose', btrim(p_purpose), 'recipient', btrim(p_recipient),
    'made_by', jsonb_build_object('person_id', v ->> 'actor_person_id',
                                  'capacity', (select core.capacity_words(dc) from core.decision_context dc where dc.id = ctx))));
  insert into core.export (id, customer_id, venue_id, kind, reference, work_package_id, purpose, recipient, profile, omissions, scope,
                           content, content_sha256, made_by_person_id, decision_context_id, build_state)
  values (e_id, wp.customer_id, wp.venue_id, 'permit_pack', ref, wp.id, btrim(p_purpose), btrim(p_recipient), p_profile, omissions,
          jsonb_build_object('work_package_id', wp.id, 'requested_from_permit_id', p_permit_id,
                             'permit_ids', (select coalesce(jsonb_agg(x -> 'id'), '[]') from jsonb_array_elements(content -> 'permits') x),
                             'issue_snapshot_ids', (select coalesce(jsonb_agg(s -> 'id'), '[]') from jsonb_array_elements(content -> 'permits') x,
                                                      jsonb_array_elements(x -> 'issue_snapshots') s),
                             'close_out_snapshot_ids', (select coalesce(jsonb_agg(x #> '{close_out,id}'), '[]') from jsonb_array_elements(content -> 'permits') x
                                                          where x -> 'close_out' <> 'null'),
                             'events', jsonb_array_length(content -> 'chronology')),
          content, sha256(convert_to(content::text, 'UTF8')), (v ->> 'actor_person_id')::uuid, ctx, 'queued');
  return v || jsonb_build_object('id', e_id, 'reference', ref);
end $$;

-- The permit page's evidence section: corrections for anyone who can see the permit. The packs
-- made (with their purpose and recipient) only for the customer's tenant administrators and the
-- venue's evidence.export appointees; what can be corrected or left out only for those who can.
create function api.permit_evidence(p_permit_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare p core.permit; side boolean; me uuid; t jsonb; packs boolean;
begin
  select * into p from core.permit where id = p_permit_id;
  if p.id is null or p.id not in (select authz.visible_permit_ids()) then
    return core.refuse('evidence.read', 'not_visible', 'The record does not exist or you do not have access to it.', 'Access to this permit', 'The venue');
  end if;
  side := authz.venue_side(p.venue_id);
  me := authz.actor_person(p.customer_id);
  t := core.export_target(p.work_package_id, p.work_package_id);
  packs := p.customer_id in (select authz.my_admin_customer_ids()) or me = any (core.venue_action_appointees(p.venue_id, 'evidence.export'));
  return jsonb_build_object('ok', true,
    'corrections', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'target_type', c.target_type, 'target_id', c.target_id,
                       'label', (select k.label from core.correctable(c.permit_id) k where k.target_id = c.target_id),
                       'about', c.about, 'was', c.was, 'corrected', c.corrected, 'reason', c.reason, 'evidence', c.evidence,
                       'by', core.person_name(c.recorded_by_person_id), 'at', c.created_at) order by c.created_at), '[]')
                      from core.correction c where c.permit_id = p.id),
    'venue_side', side,
    'can_correct', coalesce(side and me = any (core.action_holders('record.correct', core.permit_target(p, p.id, 'correction', null)
                                                         || core.revision_scope((select current_revision_id from core.work_package where id = p.work_package_id))
                                                         || jsonb_build_object('permit_class_id', p.permit_class_id))), false),
    'correctable', case when me = any (core.venue_action_appointees(p.venue_id, 'record.correct')) then (select coalesce(jsonb_agg(jsonb_build_object('target_type', k.target_type, 'target_id', k.target_id,
                                                                                    'label', k.label, 'at', k.at) order by k.at), '[]')
                                          from core.correctable(p.id) k) else '[]' end,
    'can_export', coalesce(side and me = any (core.action_holders('evidence.export', t)), false),
    'export_options', case when packs then jsonb_build_object(
        'files', core.pack_files(p.work_package_id, 'internal', '[]'),
        'permits', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'class', pc.name) order by (x.kind <> 'work_approval'), x.created_at), '[]')
                      from core.permit x join core.permit_class pc on pc.id = x.permit_class_id
                     where x.work_package_id = p.work_package_id and exists (select 1 from core.issue_snapshot s where s.permit_id = x.id)))
      end,
    'packs', case when packs then (select coalesce(jsonb_agg(jsonb_build_object(
        'id', e.id, 'reference', e.reference, 'made_at', e.created_at, 'made_by', core.person_name(e.made_by_person_id),
        'capacity', e.content #>> '{made_by,capacity}', 'purpose', e.purpose, 'recipient', e.recipient, 'profile', e.profile,
        'omissions', e.omissions, 'build_state', e.build_state, 'content_sha256', encode(e.content_sha256, 'hex'),
        'pack_sha256', encode(e.pack_sha256, 'hex'), 'pack_bytes', e.pack_bytes, 'files', e.files, 'built_at', e.built_at,
        'events', e.scope -> 'events') order by e.created_at desc), '[]')
      from core.export e where e.work_package_id = p.work_package_id and e.kind = 'permit_pack') else '[]' end);
end $$;

-- A pack is released only to someone who could make it now, as a short-lived link the server
-- signs; every release is audited (CLAUDE.md §5).
create function api.pack_access(p_export_id uuid) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare e core.export; t jsonb;
begin
  select * into e from core.export where id = p_export_id and kind = 'permit_pack';
  if e.id is not null then t := core.export_target(e.work_package_id, e.id); end if;
  if e.id is null or not (authz.actor_person(e.customer_id) = any (core.action_holders('evidence.export', t))) then
    return core.refuse('evidence.download', 'not_found', 'The record does not exist or you do not have access to it.',
                       'An appointment to make permit packs for this job', 'The venue''s appointing authority');
  end if;
  if e.build_state <> 'ready' then
    return core.refuse('evidence.download', 'not_ready',
      case e.build_state when 'queued' then 'This pack is still being built.' else 'This pack could not be built. Make a new one.' end,
      'A finished pack', case e.build_state when 'queued' then 'Nobody: try again shortly' else 'You' end);
  end if;
  perform audit.record('export.downloaded', e.customer_id, e.venue_id, 'core.export', e.id, null, null);
  return jsonb_build_object('ok', true, 'storage_path', e.storage_path, 'file_name', e.reference || '.zip', 'sha256', encode(e.pack_sha256, 'hex'));
end $$;

-- ---------------------------------------------------------------------------
-- The pack builder service: claims queued packs with a lease, then records each one's files
-- and hashes. It cannot change what a pack contains, and the database checks that the files it
-- reports are the ones the pack names.
-- ---------------------------------------------------------------------------
create function api.claim_pack_builds(p_limit integer default 5, p_lease_seconds integer default 300) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v jsonb := authz.evaluate('evidence.build_pack', '{}'::jsonb); ids uuid[];
begin
  if not (v ->> 'allowed')::boolean then return v; end if;
  if p_limit not between 1 and 50 or p_lease_seconds not between 30 and 1800 then
    raise exception 'limit 1-50, lease 30-1800 seconds' using errcode = '22023';
  end if;
  select array_agg(id) into ids from (
    select e.id from core.export e
     where e.build_state = 'queued' and (e.leased_until is null or e.leased_until < clock_timestamp())
     order by e.created_at limit p_limit for update skip locked) z;
  update core.export set leased_until = clock_timestamp() + make_interval(secs => p_lease_seconds), attempts = attempts + 1
   where id = any (coalesce(ids, '{}'));
  return jsonb_build_object('ok', true, 'packs', coalesce((select jsonb_agg(jsonb_build_object(
      'id', e.id, 'reference', e.reference, 'customer_id', e.customer_id, 'content_text', e.content::text,
      'files', (select coalesce(jsonb_agg(jsonb_build_object('version_id', dv.id, 'storage_path', dv.storage_path, 'sha256', f ->> 'sha256',
                                                             'media_type', dv.media_type, 'name_in_pack', f ->> 'name_in_pack')), '[]')
                  from jsonb_array_elements(e.content -> 'files') f join core.document_version dv on dv.id = (f ->> 'version_id')::uuid
                 where (f ->> 'included')::boolean))
    order by e.created_at) from core.export e where e.id = any (coalesce(ids, '{}'))), '[]'));
end $$;

-- p_files: [{name, sha256, bytes}] for every file in the ZIP.
create function api.record_pack_build(p_export_id uuid, p_ok boolean, p_files jsonb, p_pack_sha256 text, p_pack_bytes bigint,
                                      p_storage_path text, p_error text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb := authz.evaluate('evidence.build_pack', '{}'::jsonb); e core.export; missing text;
begin
  if not (v ->> 'allowed')::boolean then return v; end if;
  select * into e from core.export where id = p_export_id and kind = 'permit_pack' for update;
  if e.id is null or e.build_state <> 'queued' then
    return core.refuse('evidence.build_pack', 'not_queued', 'This pack is not waiting to be built.', 'A queued pack', 'Nobody');
  end if;
  if not p_ok then
    update core.export set build_error = left(coalesce(p_error, 'unknown error'), 500), leased_until = null,
                           build_state = case when attempts >= 3 then 'failed' else 'queued' end
     where id = e.id;
    return jsonb_build_object('ok', true, 'build_state', case when e.attempts >= 3 then 'failed' else 'queued' end);
  end if;
  -- The ZIP must hold the pack's own content, unaltered, and every evidence file it names.
  select string_agg(x.name, ', ') into missing from (
    select 'pack.json' as name, encode(e.content_sha256, 'hex') as sha256
    union all
    select f ->> 'name_in_pack', f ->> 'sha256' from jsonb_array_elements(e.content -> 'files') f where (f ->> 'included')::boolean) x
   where not exists (select 1 from jsonb_array_elements(coalesce(p_files, '[]')) g where g ->> 'name' = x.name and g ->> 'sha256' = x.sha256);
  if missing is not null then
    return core.refuse('evidence.build_pack', 'files_do_not_match', 'The built pack does not hold these files as recorded: ' || missing,
                       'The recorded files, unaltered', 'Octra platform operations');
  end if;
  if p_storage_path is distinct from e.customer_id::text || '/' || e.id::text || '.zip' or p_pack_sha256 !~ '^[0-9a-f]{64}$' or coalesce(p_pack_bytes, 0) <= 0 then
    raise exception 'storage path, pack hash and size are required as given to the builder' using errcode = '22023';
  end if;
  update core.export set build_state = 'ready', files = p_files, pack_sha256 = decode(p_pack_sha256, 'hex'), pack_bytes = p_pack_bytes,
                         storage_path = p_storage_path, built_at = clock_timestamp(), leased_until = null, build_error = null
   where id = e.id;
  return jsonb_build_object('ok', true, 'build_state', 'ready');
end $$;

-- ---------------------------------------------------------------------------
-- Report downloads are exports too (§6): who, which report, which period. No content is kept.
-- ---------------------------------------------------------------------------
create function api.report_export(p_kind text, p_venue_id uuid, p_from date, p_to date, p_organisation_id uuid default null) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare r jsonb := api.report(p_kind, p_venue_id, p_from, p_to, p_organisation_id); vn core.venue; e_id uuid := gen_random_uuid();
begin
  if not coalesce((r ->> 'ok')::boolean, false) then return r; end if;
  select * into vn from core.venue where id = p_venue_id;
  insert into core.export (id, customer_id, venue_id, kind, reference, scope, made_by_person_id)
  values (e_id, vn.customer_id, vn.id, 'report_csv', 'RP-' || upper(left(replace(e_id::text, '-', ''), 10)),
          jsonb_build_object('report', p_kind, 'from', p_from, 'to', p_to, 'organisation_id', p_organisation_id, 'rows', jsonb_array_length(r -> 'rows')),
          authz.actor_person(vn.customer_id));
  return r || jsonb_build_object('export_id', e_id);
end $$;

-- ---------------------------------------------------------------------------
-- Record history (Q217, P8-11): for anyone who can see the record. Times are read in the
-- record's venue's time zone; for people and organisations, which belong to the customer, in
-- that of the customer's first venue.
-- ---------------------------------------------------------------------------
create function api.record_history(p_kind text, p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare cust uuid; ids uuid[]; side boolean; refusal jsonb; venue uuid;
begin
  refusal := core.refuse('history.read', 'not_visible', 'The record does not exist or you do not have access to it.',
                         'Access to this record', 'Its owner or the venue');
  if p_kind = 'permit' then
    if p_id not in (select authz.visible_permit_ids()) then return refusal; end if;
    select p.customer_id, core.job_record_ids(p.work_package_id, p.id), authz.venue_side(p.venue_id), p.venue_id into cust, ids, side, venue
      from core.permit p where p.id = p_id;
  elsif p_kind = 'job' then
    if p_id not in (select authz.visible_work_package_ids()) then return refusal; end if;
    select w.customer_id, core.job_record_ids(w.id, null), authz.venue_side(w.venue_id), w.venue_id into cust, ids, side, venue
      from core.work_package w where w.id = p_id;
  elsif p_kind = 'person' then
    if p_id not in (select authz.visible_person_ids()) and p_id not in (select authz.my_person_ids())
       and not exists (select 1 from core.person x where x.id = p_id and x.customer_id in (select authz.my_admin_customer_ids())) then
      return refusal;
    end if;
    select x.customer_id, core.person_record_ids(x.id), authz.customer_side(x.customer_id) into cust, ids, side from core.person x where x.id = p_id;
  elsif p_kind = 'organisation' then
    if p_id not in (select authz.visible_organisation_ids())
       and not exists (select 1 from core.organisation o where o.id = p_id and o.customer_id in (select authz.my_admin_customer_ids())) then
      return refusal;
    end if;
    select o.customer_id, core.organisation_record_ids(o.id), authz.customer_side(o.customer_id) into cust, ids, side
      from core.organisation o where o.id = p_id;
  elsif p_kind = 'visit' then
    if p_id not in (select authz.visible_access_ids()) then return refusal; end if;
    select a.customer_id, core.visit_record_ids(a.id), authz.venue_side(a.venue_id), a.venue_id into cust, ids, side, venue
      from core.access_authorisation a where a.id = p_id;
  else
    return refusal;
  end if;
  if cust is null then return refusal; end if;
  return jsonb_build_object('ok', true, 'entries', core.history(cust, ids, side),
    'timezone', coalesce((select v.timezone from core.venue v where v.id = venue),
                         (select v.timezone from core.venue v where v.customer_id = cust order by v.created_at limit 1)));
end $$;

-- ---------------------------------------------------------------------------
-- Corrections (Q216, P8-12): beside the frozen record, by a record.correct appointee who did
-- not make the record and is not connected with the job (D-007).
-- ---------------------------------------------------------------------------
create function api.record_correction(p_idempotency_key text, p_target_type text, p_target_id uuid, p_about text, p_was text, p_corrected text,
                                      p_reason text, p_evidence text,
                                      p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  p core.permit; k record; t jsonb; r jsonb; v jsonb; c_id uuid := gen_random_uuid(); errs text[] := '{}';
begin
  select x.* into p from core.permit x
   where x.id = case p_target_type
     when 'issue_snapshot' then (select permit_id from core.issue_snapshot where id = p_target_id)
     when 'close_out_snapshot' then (select permit_id from core.close_out_snapshot where id = p_target_id)
     when 'step_decision' then (select v2.permit_id from core.step_decision d join core.permit_step s on s.id = d.permit_step_id
                                  join core.permit_version v2 on v2.id = s.permit_version_id where d.id = p_target_id)
     when 'hand_back_decision' then (select h.permit_id from core.hand_back_decision d join core.hand_back h on h.id = d.hand_back_id where d.id = p_target_id)
   end;
  if p.id is null then
    return core.refuse('record.correct', 'not_found', 'The record does not exist or you do not have access to it.', 'A frozen record of a permit', 'The venue');
  end if;
  select * into k from core.correctable(p.id) c where c.target_id = p_target_id and c.target_type = p_target_type;
  if not found then
    return core.refuse('record.correct', 'not_found', 'The record does not exist or you do not have access to it.', 'A frozen record of a permit', 'The venue');
  end if;
  t := core.permit_target(p, c_id, 'correction', null)
       || core.revision_scope((select current_revision_id from core.work_package where id = p.work_package_id))
       || jsonb_build_object('permit_class_id', p.permit_class_id,
                             'excluded_person_ids', core.work_package_people(p.work_package_id) || to_jsonb(array[k.author_person_id]));
  r := jsonb_build_object('target_type', p_target_type, 'target_id', p_target_id, 'about', p_about, 'was', p_was, 'corrected', p_corrected,
                          'reason', p_reason, 'evidence', p_evidence);
  if exists (select 1 from core.decision_context where actor_user_id = auth.uid() and action_code = 'record.correct' and idempotency_key = p_idempotency_key) then
    return authz.require('record.correct', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  end if;
  v := core.authorised_or_refusal('record.correct', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if length(btrim(coalesce(p_about, ''))) not between 1 and 300 then errs := errs || text 'Say what is being corrected.'; end if;
  if length(btrim(coalesce(p_was, ''))) not between 1 and 2000 then errs := errs || text 'Give what the record says.'; end if;
  if length(btrim(coalesce(p_corrected, ''))) not between 1 and 2000 then errs := errs || text 'Give the correct value.'; end if;
  if btrim(coalesce(p_was, '')) = btrim(coalesce(p_corrected, '')) then errs := errs || text 'The correct value is the same as what the record says.'; end if;
  if length(btrim(coalesce(p_reason, ''))) not between 1 and 2000 then errs := errs || text 'Give the reason for the correction.'; end if;
  if length(btrim(coalesce(p_evidence, ''))) not between 1 and 2000 then errs := errs || text 'Say what shows the correct value.'; end if;
  if cardinality(errs) > 0 then
    return core.refuse('record.correct', 'invalid_content', 'The correction cannot be recorded as given.', array_to_string(errs, ' '), 'You',
                       jsonb_build_object('problems', to_jsonb(errs)));
  end if;
  v := authz.require('record.correct', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.correction (id, customer_id, venue_id, work_package_id, permit_id, target_type, target_id, about, was, corrected, reason, evidence,
                               recorded_by_person_id, decision_context_id)
  values (c_id, p.customer_id, p.venue_id, p.work_package_id, p.id, p_target_type, p_target_id, btrim(p_about), btrim(p_was), btrim(p_corrected),
          btrim(p_reason), btrim(p_evidence), (v ->> 'actor_person_id')::uuid, (v ->> 'decision_context_id')::uuid);
  return v || jsonb_build_object('id', c_id);
end $$;

grant execute on function
  api.request_permit_pack(text, uuid, text, text, text, jsonb, uuid, uuid), api.permit_evidence(uuid), api.pack_access(uuid),
  api.claim_pack_builds(integer, integer), api.record_pack_build(uuid, boolean, jsonb, text, bigint, text, text),
  api.report_export(text, uuid, date, date, uuid), api.record_history(text, uuid),
  api.record_correction(text, text, uuid, text, text, text, text, text, uuid, uuid)
to authenticated;
revoke execute on function
  api.request_permit_pack(text, uuid, text, text, text, jsonb, uuid, uuid), api.permit_evidence(uuid), api.pack_access(uuid),
  api.claim_pack_builds(integer, integer), api.record_pack_build(uuid, boolean, jsonb, text, bigint, text, text),
  api.report_export(text, uuid, date, date, uuid), api.record_history(text, uuid),
  api.record_correction(text, text, uuid, text, text, text, text, text, uuid, uuid)
from anon, public;

-- ---------------------------------------------------------------------------
-- Storage: a private bucket for built packs. Nobody reads it directly: the server signs a
-- short-lived link only after api.pack_access has authorised and audited the release.
-- ---------------------------------------------------------------------------
do $s$
begin
  if to_regclass('storage.buckets') is null then
    raise notice 'storage schema absent: evidence-packs bucket not created';
    return;
  end if;
  insert into storage.buckets (id, name, public, allowed_mime_types)
  values ('evidence-packs', 'evidence-packs', false, array['application/zip'])
  on conflict (id) do nothing;
end $s$;
