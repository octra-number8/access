-- 0021 Malware scanning held off (D-014)
--
-- Scanning becomes a platform setting. While it is `off`, a new upload is recorded
-- honestly as `not_scanned` and is usable at once; it is never labelled clean. While
-- it is `required`, uploads start `pending` and nothing is released until the scanner
-- records `clean` (the D-013 behaviour, unchanged and still tested).
--
-- The setting changes only by migration: there is no API or administrator switch.
-- The scanner tables, functions, bucket policy and service remain in place.
--
-- Recovery: pre-pilot, `supabase db reset`. To turn scanning on: a forward migration
-- inserting a `required` row, after the scanner is deployed (docs/scanner-design.md).

create table core.platform_setting (
  id             uuid primary key default gen_random_uuid(),
  seq            bigint generated always as identity,
  key            text not null check (key in ('malware_scanning')),
  value          text not null,
  effective_from timestamptz not null default clock_timestamp(),
  decision_ref   text not null check (length(btrim(decision_ref)) > 0),
  check (key <> 'malware_scanning' or value in ('off', 'required'))
);
alter table core.platform_setting enable row level security;
alter table core.platform_setting force row level security;
create trigger a_forbid_delete before delete on core.platform_setting for each row execute function core.forbid_delete();
create trigger b_forbid_update before update on core.platform_setting for each row execute function core.forbid_update();
create trigger z_audit after insert on core.platform_setting for each row execute function audit.capture_row();
grant select on core.platform_setting to authenticated;
create policy platform_setting_read on core.platform_setting for select to authenticated using (true);

insert into core.platform_setting (key, value, decision_ref)
values ('malware_scanning', 'off', 'D-014: scanning held off until the portal needs it');

create function core.malware_scanning() returns text
language sql stable security definer
set search_path = ''
as $$
  select value from core.platform_setting
   where key = 'malware_scanning' and effective_from <= clock_timestamp()
   order by effective_from desc, seq desc limit 1
$$;

create view api.platform_setting with (security_invoker = true) as
  select key, value, effective_from, decision_ref from core.platform_setting;
grant select on api.platform_setting to authenticated;

-- ---- not_scanned ----------------------------------------------------------------------
alter table core.document_version drop constraint document_version_scan_status_check;
alter table core.document_version add constraint document_version_scan_status_check
  check (scan_status in ('pending', 'not_scanned', 'clean', 'infected', 'rejected'));
alter table core.document_version drop constraint document_version_check1;
alter table core.document_version add constraint document_version_scanned_at_check
  check ((scan_status in ('pending', 'not_scanned')) = (scanned_at is null));

-- A file recorded while scanning was off may be scanned later, once.
create or replace function core.scan_once() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.scan_status is distinct from old.scan_status and old.scan_status not in ('pending', 'not_scanned') then
    raise exception 'a scan result is recorded once' using errcode = 'check_violation';
  end if;
  return new;
end $$;

-- ---- Functions follow the setting ------------------------------------------------------
do $m$
declare d text;
begin
  -- Uploads start pending only when scanning is required.
  d := pg_get_functiondef('api.submit_document(text,uuid,uuid,text,uuid,uuid,uuid,text,text,text,bigint,text,text,date,date)'::regprocedure);
  if position('size_bytes, issuer, reference, valid_from, expires_on, uploaded_by_person_id)' in d) = 0 then
    raise exception 'submit_document no longer has the expected insert';
  end if;
  d := replace(d, 'size_bytes, issuer, reference, valid_from, expires_on, uploaded_by_person_id)',
                  'size_bytes, issuer, reference, valid_from, expires_on, uploaded_by_person_id, scan_status)');
  d := replace(d, '(v ->> ''actor_person_id'')::uuid);',
                  '(v ->> ''actor_person_id'')::uuid,
          case core.malware_scanning() when ''required'' then ''pending'' else ''not_scanned'' end);');
  d := replace(d, 'return v || jsonb_build_object(''storage_path'', v_customer || ''/'' || p_document_id || ''/'' || p_version_id);',
                  'return v || jsonb_build_object(''storage_path'', v_customer || ''/'' || p_document_id || ''/'' || p_version_id,
                            ''scan_status'', (select scan_status from core.document_version where id = p_version_id));');
  execute d;

  -- Release: clean, or recorded as not scanned while scanning was off.
  d := pg_get_functiondef('api.document_access(uuid)'::regprocedure);
  if position('if dv.scan_status <> ''clean'' then' in d) = 0 then
    raise exception 'document_access no longer has the expected scan check';
  end if;
  d := replace(d, 'if dv.scan_status <> ''clean'' then', 'if dv.scan_status not in (''clean'', ''not_scanned'') then');
  d := replace(d, '''sha256'', encode(dv.sha256, ''hex''), ''disposition'', ''attachment'');',
                  '''sha256'', encode(dv.sha256, ''hex''), ''disposition'', ''attachment'',
                            ''malware_scanned'', dv.scan_status = ''clean'');');
  execute d;

  -- Review: the same files can be reviewed.
  d := pg_get_functiondef('api.review_document(text,uuid,uuid,text,jsonb,text,text,uuid,uuid)'::regprocedure);
  if position('if dv.scan_status <> ''clean'' then' in d) = 0 then
    raise exception 'review_document no longer has the expected scan check';
  end if;
  d := replace(d, 'if dv.scan_status <> ''clean'' then', 'if dv.scan_status not in (''clean'', ''not_scanned'') then');
  d := replace(d, 'a document can be reviewed only once its file has been scanned clean',
                  'a document can be reviewed only once its file is released (scanned clean, or recorded as not scanned)');
  execute d;

  -- Evidence: a not-scanned file is usable evidence; pending, infected and rejected are not.
  d := pg_get_functiondef('authz.evidence_lines(uuid,text,text,uuid,uuid,tstzrange)'::regprocedure);
  if position('elsif v_dv.scan_status <> ''clean'' then' in d) = 0 then
    raise exception 'evidence_lines no longer has the expected scan branch';
  end if;
  d := replace(d, 'elsif v_dv.scan_status <> ''clean'' then', 'elsif v_dv.scan_status not in (''clean'', ''not_scanned'') then');
  execute d;
end $m$;
