-- 0019 Malware scanner support (D-013, docs/scanner-design.md)
--
-- Adds the `rejected` outcome (S3), leased scan jobs (S2), scanner heartbeats, the
-- private documents bucket with the platform file limits (P2-6), and a storage
-- policy letting only the scanner account read only files still awaiting a scan.
-- Nothing here ever marks a file clean except a scan result from the scanner.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

-- ---- S3: rejected -------------------------------------------------------------------
alter table core.document_version drop constraint document_version_scan_status_check;
alter table core.document_version add constraint document_version_scan_status_check
  check (scan_status in ('pending', 'clean', 'infected', 'rejected'));

insert into core.authority_action (code, basis, delegable, description) values
  ('document.claim_scan', 'service', false, 'Lease the next file awaiting a malware scan'),
  ('scanner.heartbeat',   'service', false, 'Report scanner health and signature age');
insert into core.service_action (purpose, action_code) values
  ('malware_scanner', 'document.claim_scan'),
  ('malware_scanner', 'scanner.heartbeat');

-- ---- S2: leased jobs ------------------------------------------------------------------
-- A lease stops two scanners taking the same file and lets a crashed scan be retried.
create table core.scan_lease (
  id                  uuid primary key default gen_random_uuid(),
  document_version_id uuid not null unique references core.document_version,
  scanner_user_id     uuid not null references auth.users (id),
  leased_until        timestamptz not null,
  attempts            integer not null default 1 check (attempts > 0),
  row_version         integer not null default 1,
  created_at          timestamptz not null default now(),
  created_by_user_id  uuid default auth.uid()
);
select core.attach_standard_triggers('core.scan_lease', 'scanner_user_id,leased_until,attempts');

-- Telemetry, not decisions: no decision context and no audit trail, by design.
create table core.scanner_heartbeat (
  id                bigint generated always as identity primary key,
  scanner_user_id   uuid not null references auth.users (id),
  engine_version    text not null,
  signature_version text not null,
  signature_date    timestamptz not null,
  state             text not null check (state in ('scanning', 'signatures_stale', 'clamd_unavailable')),
  queue_depth       integer not null check (queue_depth >= 0),
  oldest_pending_at timestamptz,
  recorded_at       timestamptz not null default clock_timestamp()
);
alter table core.scanner_heartbeat enable row level security;
alter table core.scanner_heartbeat force row level security;
create trigger a_forbid_delete before delete on core.scanner_heartbeat for each row execute function core.forbid_delete();
create trigger b_forbid_update before update on core.scanner_heartbeat for each row execute function core.forbid_update();

grant select on core.scan_lease, core.scanner_heartbeat to authenticated;
create policy scan_lease_read on core.scan_lease for select to authenticated
  using ((select authz.is_platform_admin()) or scanner_user_id = (select auth.uid()));
create policy scanner_heartbeat_read on core.scanner_heartbeat for select to authenticated
  using ((select authz.is_platform_admin()) or scanner_user_id = (select auth.uid()));

-- ---- "Latest submission" must be unambiguous ------------------------------------------
-- created_at is the transaction's start time, so two submissions in one transaction tie.
-- submitted_at uses the wall clock at insert.
alter table core.document_version add column submitted_at timestamptz not null default clock_timestamp();
do $m$
declare d text;
begin
  d := pg_get_functiondef('authz.evidence_lines(uuid,text,text,uuid,uuid,tstzrange)'::regprocedure);
  if position('order by dv.created_at desc, dv.version_no desc' in d) = 0 then
    raise exception 'evidence_lines no longer has the expected ordering';
  end if;
  d := replace(d, 'order by dv.created_at desc, dv.version_no desc', 'order by dv.submitted_at desc, dv.version_no desc');
  execute d;
end $m$;
grant select (submitted_at) on core.document_version to authenticated;

-- ---- Evidence must treat every non-clean outcome as unusable --------------------------
-- Previously only `infected` was handled explicitly; `rejected` would have fallen
-- through to the review checks. Replace the branch so anything not clean is blocking.
do $m$
declare d text;
begin
  d := pg_get_functiondef('authz.evidence_lines(uuid,text,text,uuid,uuid,tstzrange)'::regprocedure);
  if position('elsif v_dv.scan_status = ''infected'' then' in d) = 0 then
    raise exception 'evidence_lines no longer has the expected scan branch';
  end if;
  d := replace(d, 'elsif v_dv.scan_status = ''infected'' then', 'elsif v_dv.scan_status <> ''clean'' then');
  execute d;
end $m$;

-- ---- Scanner API -------------------------------------------------------------------------

create function api.claim_scan_job(p_lease_seconds integer default 120) returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_eval jsonb := authz.evaluate('document.claim_scan', '{}'::jsonb);
  dv     core.document_version;
begin
  if not (v_eval ->> 'allowed')::boolean then
    return v_eval;
  end if;
  if p_lease_seconds not between 30 and 900 then
    raise exception 'lease must be between 30 and 900 seconds' using errcode = '22023';
  end if;
  select v.* into dv
    from core.document_version v
    left join core.scan_lease l on l.document_version_id = v.id
   where v.scan_status = 'pending'
     and (l.id is null or l.leased_until < now())
   order by v.created_at
   limit 1
   for update of v skip locked;
  if dv.id is null then
    return jsonb_build_object('ok', true, 'job', null);
  end if;
  insert into core.scan_lease (document_version_id, scanner_user_id, leased_until)
  values (dv.id, auth.uid(), now() + make_interval(secs => p_lease_seconds))
  on conflict (document_version_id) do update
    set scanner_user_id = excluded.scanner_user_id, leased_until = excluded.leased_until,
        attempts = core.scan_lease.attempts + 1;
  return jsonb_build_object('ok', true, 'job', jsonb_build_object(
    'version_id', dv.id, 'storage_path', dv.storage_path, 'media_type', dv.media_type,
    'size_bytes', dv.size_bytes, 'sha256', encode(dv.sha256, 'hex'),
    'attempts', (select attempts from core.scan_lease where document_version_id = dv.id)));
end $$;

create function api.scanner_heartbeat(p_engine_version text, p_signature_version text, p_signature_date timestamptz,
                                      p_state text)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_eval jsonb := authz.evaluate('scanner.heartbeat', '{}'::jsonb);
begin
  if not (v_eval ->> 'allowed')::boolean then
    return v_eval;
  end if;
  insert into core.scanner_heartbeat (scanner_user_id, engine_version, signature_version, signature_date, state,
                                      queue_depth, oldest_pending_at)
  select auth.uid(), p_engine_version, p_signature_version, p_signature_date, p_state,
         count(*), min(created_at)
    from core.document_version where scan_status = 'pending';
  return jsonb_build_object('ok', true);
end $$;

-- The S3 outcome is accepted by the scan recorder.
do $m$
declare d text;
begin
  d := pg_get_functiondef('api.record_scan_result(text,uuid,text,text,text)'::regprocedure);
  d := replace(d, 'if p_result not in (''clean'', ''infected'') then', 'if p_result not in (''clean'', ''infected'', ''rejected'') then');
  d := replace(d, 'scan result must be clean or infected', 'scan result must be clean, infected or rejected');
  execute d;
end $m$;

-- A rejected file is never released, and the contractor is told it is a file problem.
do $m$
declare d text;
begin
  d := pg_get_functiondef('api.document_access(uuid)'::regprocedure);
  d := replace(d,
    'return authz.deny(''document.access'', case dv.scan_status when ''pending'' then ''scan_pending'' else ''infected'' end,',
    'return authz.deny(''document.access'', case dv.scan_status when ''pending'' then ''scan_pending'' else dv.scan_status end,');
  d := replace(d,
    'else ''This file failed the malware check and will not be released.'' end,',
    'when ''rejected'' then ''This file could not be fully checked or is not the type it claims to be, so it will not be released.'' else ''This file failed the malware check and will not be released.'' end,');
  execute d;
end $m$;

-- Platform operations view of scanner health (D-013 §5).
create view api.scanner_status with (security_invoker = true) as
  select h.scanner_user_id, h.engine_version, h.signature_version, h.signature_date, h.state,
         h.queue_depth, h.oldest_pending_at, h.recorded_at
    from core.scanner_heartbeat h
   where h.id = (select max(id) from core.scanner_heartbeat x where x.scanner_user_id = h.scanner_user_id);
grant select on api.scanner_status to authenticated;

grant execute on function api.claim_scan_job(integer), api.scanner_heartbeat(text, text, timestamptz, text) to authenticated;
revoke execute on function api.claim_scan_job(integer), api.scanner_heartbeat(text, text, timestamptz, text) from anon, public;

-- ---- Storage: private bucket and the scanner's read policy ---------------------------------
-- Only present where Supabase Storage is installed (always, under the Supabase CLI and
-- hosted projects; the plain-Postgres fallback runner has no storage schema).
create function authz.scanner_may_read(p_object_name text) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (select 1 from core.service_account sa
                  where sa.auth_user_id = auth.uid() and sa.purpose = 'malware_scanner' and sa.revoked_at is null)
     and exists (select 1 from core.document_version dv
                  where dv.storage_path = p_object_name and dv.scan_status = 'pending')
$$;
grant execute on function authz.scanner_may_read(text) to authenticated;

do $m$
begin
  if to_regclass('storage.buckets') is null then
    raise notice 'storage schema absent: bucket and storage policy not created';
    return;
  end if;
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('documents', 'documents', false, 20971520, array['application/pdf', 'image/jpeg', 'image/png']);
  -- No other policy exists on this bucket: people never read it directly. The server
  -- releases files only after api.document_access has authorised and audited it.
  execute $p$create policy documents_scanner_read on storage.objects for select to authenticated
            using (bucket_id = 'documents' and authz.scanner_may_read(name))$p$;
end $m$;
