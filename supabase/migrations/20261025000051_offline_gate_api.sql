-- 0051 Offline gate API (phase 7d, D-020)
--
-- Same pattern as before: a repeated request is replayed first; readiness checks refuse with
-- what is missing and who can resolve it; authority only from authz.evaluate.
--
-- Reconciliation checks each uploaded entry against the live record when it arrives, which
-- is at or after the time of entry: anything that would now refuse or check the person, and
-- any work stopped or withdrawn from them since the manifest was made, is raised. It errs
-- towards raising (7d-1).
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

-- The outage procedure is a kind of venue configuration document.
do $m$
declare d text;
begin
  d := pg_get_functiondef('api.create_venue_config_draft(text,uuid,text)'::regprocedure);
  if position($s$not in ('access_purposes')$s$ in d) = 0 or position($s$coalesce(prev.content, '{"purposes": []}')$s$ in d) = 0 then
    raise exception 'api.create_venue_config_draft no longer has the expected structure';
  end if;
  d := replace(d, $s$not in ('access_purposes')$s$, $s$not in ('access_purposes', 'outage_procedure')$s$);
  d := replace(d, $s$coalesce(prev.content, '{"purposes": []}')$s$,
               $s$coalesce(prev.content, case p_kind when 'access_purposes' then '{"purposes": []}'::jsonb else '{"steps": []}'::jsonb end)$s$);
  execute d;
end $m$;

-- Work a person may not do, as the gate's notices say it (P7-12): removed from a live
-- permit's team, or on a permit whose work is stopped.
create function core.gate_work_flags(p_person_id uuid, p_venue_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(f order by f ->> 'permit_id', f ->> 'flag'), '[]') from (
    select jsonb_build_object('permit_id', p.id, 'flag', 'removed',
             'words', format('Not on the %s permit for %s: cannot join that task.', pc.name, w.reference)) f
      from core.permit p join core.permit_class pc on pc.id = p.permit_class_id join core.work_package w on w.id = p.work_package_id
     where p.venue_id = p_venue_id and core.is_live(p.status)
       and exists (select 1 from core.permit_team_member m where m.permit_id = p.id and m.person_id = p_person_id and m.removed_at is not null)
       and not exists (select 1 from core.permit_team_member m where m.permit_id = p.id and m.person_id = p_person_id and m.removed_at is null)
    union all
    select jsonb_build_object('permit_id', p.id, 'flag', 'stopped',
             'words', format('The %s work for %s is stopped: do not start it.', pc.name, w.reference))
      from core.permit p join core.permit_class pc on pc.id = p.permit_class_id join core.work_package w on w.id = p.work_package_id
     where p.venue_id = p_venue_id and p.status in ('suspended', 'hand_back_pending')
       and exists (select 1 from core.permit_team_member m where m.permit_id = p.id and m.person_id = p_person_id and m.removed_at is null)) z $$;

-- ---------------------------------------------------------------------------
-- The manifest (Q198): everyone with a reason to be expected at the venue now or in the
-- next day, as the live record judges them at this moment, for one gate point.
-- ---------------------------------------------------------------------------
create function api.download_manifest(p_idempotency_key text, p_gate_point_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare gp core.gate_point; vn core.venue; cfg core.venue_config_version; t jsonb; r jsonb; v jsonb; m_id uuid := gen_random_uuid();
        pid uuid; res jsonb;
begin
  select * into gp from core.gate_point where id = p_gate_point_id and retired_at is null;
  select * into vn from core.venue where id = gp.venue_id;
  t := core.gate_target(gp, m_id, 'gate_manifest');
  r := jsonb_build_object('gate_point_id', p_gate_point_id);
  v := core.authorised_or_refusal('gate.download_manifest', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  cfg := core.venue_config(gp.venue_id, 'outage_procedure');
  if cfg.id is null then
    return core.refuse('gate.download_manifest', 'not_configured', 'The venue has no approved outage procedure, so it has not said how long a manifest may be used (Q198, Q201).',
                       'An approved outage procedure', 'The venue''s tenant administrator drafts it; an access authority approves it');
  end if;
  v := authz.require('gate.download_manifest', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.gate_manifest (id, customer_id, venue_id, gate_point_id, made_by_person_id, outage_config_id, max_age_minutes, rule_version_id, decision_context_id)
  values (m_id, gp.customer_id, gp.venue_id, gp.id, (v ->> 'actor_person_id')::uuid, cfg.id, (cfg.content ->> 'manifest_max_age_minutes')::integer,
          (select id from core.entry_rule_version where venue_id = gp.venue_id and status = 'approved'), (v ->> 'decision_context_id')::uuid);
  for pid in
    select r.person_id from core.person_organisation_relationship r join core.engagement e on e.organisation_id = r.organisation_id
     where e.venue_id = gp.venue_id and e.status = 'active' and now() <@ e.valid_during and r.status = 'active' and now() <@ r.valid_during
    union
    select m.person_id from core.access_roster_member m join core.access_authorisation a on a.id = m.authorisation_id
     where a.venue_id = gp.venue_id and a.status = 'approved' and a.valid_during && tstzrange(now(), now() + interval '1 day') and m.removed_at is null
    union
    select k.person_id from core.person_pass k where k.venue_id = gp.venue_id and k.revoked_at is null
  loop
    res := core.entry_evaluation(pid, gp.venue_id, gp.id);
    insert into core.gate_manifest_entry (customer_id, venue_id, manifest_id, person_id, pass_numbers, outcome, result, work_flags)
    values (gp.customer_id, gp.venue_id, m_id, pid,
            array(select k.pass_number from core.person_pass k where k.venue_id = gp.venue_id and k.person_id = pid and k.revoked_at is null order by 1),
            res ->> 'outcome', res, core.gate_work_flags(pid, gp.venue_id));
  end loop;
  return v || (select jsonb_build_object(
    'manifest_id', m.id, 'made_at', m.made_at, 'max_age_minutes', m.max_age_minutes, 'gate_point', gp.name, 'venue', vn.name, 'timezone', vn.timezone,
    'instruction', cfg.content ->> 'instruction', 'steps', cfg.content -> 'steps',
    'entries', coalesce((select jsonb_agg(jsonb_build_object(
        'person_id', e.person_id, 'name', e.result #>> '{person,name}', 'organisation', e.result ->> 'organisation', 'pass_numbers', to_jsonb(e.pass_numbers),
        'outcome', e.outcome, 'audience', e.result ->> 'audience', 'areas', e.result -> 'areas', 'escort', e.result ->> 'escort',
        'reasons', (select coalesce(jsonb_agg(jsonb_build_object('words', x ->> 'words', 'owner', x ->> 'owner')), '[]')
                      from jsonb_array_elements(e.result -> 'reasons') x where not x ? 'overridden_by'),
        'notices', e.result -> 'notices') order by e.result #>> '{person,name}')
      from core.gate_manifest_entry e where e.manifest_id = m.id), '[]'))
    from core.gate_manifest m where m.id = m_id);
end $$;

-- ---------------------------------------------------------------------------
-- Manual fallback entries (Q200, Q202, Q203)
--   entries: [{client_entry_id, recorded_at, person_id?, pass_number?, name_given, organisation_given?,
--              purpose, contacted, direction, identity_method, decision, notes?}]
-- ---------------------------------------------------------------------------
create function core.raise_exception(f core.manual_fallback_entry, p_kind text, p_code text, p_words text, p_owner text, p_permit_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare x_id uuid := gen_random_uuid();
begin
  insert into core.reconciliation_exception (id, customer_id, venue_id, fallback_entry_id, kind, code, permit_id, person_id, words, owner)
  values (x_id, f.customer_id, f.venue_id, f.id, p_kind, p_code, p_permit_id, f.person_id, p_words, p_owner);
  return jsonb_build_object('id', x_id, 'kind', p_kind, 'code', p_code, 'words', p_words, 'owner', p_owner);
end $$;

create function api.submit_fallback_entries(p_idempotency_key text, p_gate_point_id uuid, p_manifest_id uuid, p_entries jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  gp core.gate_point; vn core.venue; m core.gate_manifest; t jsonb; r jsonb; v jsonb; problems text[] := '{}'; x jsonb; i integer := 0;
  f core.manual_fallback_entry; pid uuid; k core.person_pass; live jsonb; at timestamptz; age integer; raised jsonb := '[]'; added integer := 0;
  already integer := 0; prior jsonb; flag jsonb; label text; issuer text;
begin
  select * into gp from core.gate_point where id = p_gate_point_id;
  select * into vn from core.venue where id = gp.venue_id;
  t := core.gate_target(gp, gen_random_uuid(), 'manual_fallback_entry');
  r := jsonb_build_object('gate_point_id', p_gate_point_id, 'manifest_id', p_manifest_id, 'entries', p_entries);
  v := core.authorised_or_refusal('gate.submit_fallback', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if p_manifest_id is not null then
    select * into m from core.gate_manifest where id = p_manifest_id and gate_point_id = gp.id;
    if m.id is null then problems := problems || text 'The manifest named is not one made for this gate point.'; end if;
  end if;
  if jsonb_typeof(p_entries) is distinct from 'array' or jsonb_array_length(p_entries) = 0 or jsonb_array_length(p_entries) > 500 then
    problems := problems || text 'Send between 1 and 500 entries.';
  else
    for x in select * from jsonb_array_elements(p_entries) loop
      i := i + 1;
      begin
        at := (x ->> 'recorded_at')::timestamptz;
        perform (x ->> 'client_entry_id')::uuid, nullif(x ->> 'person_id', '')::uuid;
      exception when others then
        problems := problems || format('Entry %s: the time or an identifier is not readable.', i); continue;
      end;
      if at is null or x ->> 'client_entry_id' is null then problems := problems || format('Entry %s: give its time and identifier.', i); continue; end if;
      if at > clock_timestamp() + interval '5 minutes' then problems := problems || format('Entry %s: its time is in the future (check the device''s clock).', i); end if;
      if m.id is not null and at < m.made_at then problems := problems || format('Entry %s: it is earlier than the manifest it relied on.', i); end if;
      if core.blank(x ->> 'name_given') or core.blank(x ->> 'purpose') or core.blank(x ->> 'contacted') then
        problems := problems || format('Entry %s: record the name given, the purpose and who was contacted (Q200).', i);
      end if;
      if coalesce(x ->> 'direction', '') not in ('in', 'out') or coalesce(x ->> 'identity_method', '') not in ('photo_id', 'known_to_operator', 'not_checked')
         or coalesce(x ->> 'decision', '') not in ('admitted', 'refused', 'referred') then
        problems := problems || format('Entry %s: record the direction, how identity was checked and what was decided.', i);
      elsif x ->> 'decision' = 'admitted' and x ->> 'identity_method' = 'not_checked' then
        problems := problems || format('Entry %s: nobody is let through without an identity check.', i);
      end if;
      if nullif(x ->> 'person_id', '') is not null
         and not exists (select 1 from core.person p where p.id = (x ->> 'person_id')::uuid and p.customer_id = gp.customer_id) then
        problems := problems || format('Entry %s: the person is not known at this venue.', i);
      end if;
    end loop;
  end if;
  if cardinality(problems) > 0 then
    return core.refuse('gate.submit_fallback', 'invalid_content', 'Some entries cannot be accepted; nothing was uploaded. Keep them on the device and correct them.',
                       'Each item listed', 'The operator', jsonb_build_object('problems', to_jsonb(problems)));
  end if;
  v := authz.require('gate.submit_fallback', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  for x in select * from jsonb_array_elements(p_entries) loop
    if exists (select 1 from core.manual_fallback_entry e where e.customer_id = gp.customer_id and e.client_entry_id = (x ->> 'client_entry_id')::uuid) then
      already := already + 1; continue;
    end if;
    at := (x ->> 'recorded_at')::timestamptz;
    select * into k from core.person_pass where venue_id = gp.venue_id and pass_number = upper(btrim(coalesce(x ->> 'pass_number', '')));
    pid := coalesce(nullif(x ->> 'person_id', '')::uuid, k.person_id);
    live := case when pid is not null then core.entry_evaluation(pid, gp.venue_id, gp.id) end;
    age := case when m.id is not null then floor(extract(epoch from at - m.made_at) / 60)::integer end;
    insert into core.manual_fallback_entry (customer_id, venue_id, gate_point_id, client_entry_id, manifest_id, recorded_at, manifest_age_minutes, manifest_usable,
      person_id, pass_number, name_given, organisation_given, purpose, contacted, direction, identity_method, decision, notes, live_result,
      operator_person_id, decision_context_id)
    values (gp.customer_id, gp.venue_id, gp.id, (x ->> 'client_entry_id')::uuid, m.id, at, age, coalesce(age <= m.max_age_minutes, false),
      pid, nullif(upper(btrim(coalesce(x ->> 'pass_number', ''))), ''), btrim(x ->> 'name_given'), nullif(btrim(coalesce(x ->> 'organisation_given', '')), ''),
      btrim(x ->> 'purpose'), btrim(x ->> 'contacted'), x ->> 'direction', x ->> 'identity_method', x ->> 'decision', nullif(btrim(coalesce(x ->> 'notes', '')), ''),
      live, (v ->> 'actor_person_id')::uuid, (v ->> 'decision_context_id')::uuid)
    returning * into f;
    added := added + 1;
    label := to_char(at at time zone vn.timezone, 'HH24:MI "on" DD/MM/YYYY');

    -- Only an admission can have let in someone who should not have been.
    if f.direction = 'in' and f.decision = 'admitted' then
      if pid is null then
        raised := raised || core.raise_exception(f, 'entry', 'unknown_person',
          format('Let in at %s as "%s"%s, but no person record matches.', label, f.name_given, coalesce(' (' || f.organisation_given || ')', '')),
          'The venue''s access administrator');
      else
        if k.id is not null and k.revoked_at is not null then
          raised := raised || core.raise_exception(f, 'entry', 'pass_revoked', format('Let in at %s on pass %s, which is revoked.', label, k.pass_number),
                                                   'The venue''s pass desk');
        end if;
        if live ->> 'outcome' in ('check', 'do_not_admit') then
          raised := raised || core.raise_exception(f, 'entry', 'live_' || (live ->> 'outcome'),
            format('Let in at %s, but the live record says %s: %s', label, case live ->> 'outcome' when 'check' then 'Check' else 'Do not admit' end,
                   (select string_agg(y ->> 'words', ' ') from jsonb_array_elements(live -> 'reasons') y where not y ? 'overridden_by')),
            coalesce((select y ->> 'owner' from jsonb_array_elements(live -> 'reasons') y where not y ? 'overridden_by' limit 1), 'The venue''s access administrator'));
        end if;
        -- Work stopped or withdrawn since the manifest was made, or with no manifest at all (Q203).
        prior := coalesce((select work_flags from core.gate_manifest_entry where manifest_id = m.id and person_id = pid), '[]');
        for flag in select * from jsonb_array_elements(core.gate_work_flags(pid, gp.venue_id)) loop
          continue when prior @> jsonb_build_array(jsonb_build_object('permit_id', flag ->> 'permit_id', 'flag', flag ->> 'flag'));
          issuer := (select core.person_name(s.issuer_person_id) from core.issue_snapshot s where s.permit_id = (flag ->> 'permit_id')::uuid
                      order by s.issued_at desc limit 1);
          raised := raised || core.raise_exception(f, 'work', 'work_' || (flag ->> 'flag'),
            format('Let in at %s while: %s The gate''s manifest did not show this.', label, flag ->> 'words'),
            coalesce('The permit''s issuer, ' || issuer, 'The permit''s issuer'), (flag ->> 'permit_id')::uuid);
        end loop;
      end if;
    end if;
  end loop;
  return v || jsonb_build_object('added', added, 'already_uploaded', already, 'exceptions', raised);
end $$;

-- ---------------------------------------------------------------------------
-- Resolving an exception (Q202): entry exceptions by an access administrator for the gate's
-- area, work exceptions by an appointee for the permit's class and area. Never the operator
-- who made the entry, nor the person it concerns. A note is required; nothing closes by time.
-- ---------------------------------------------------------------------------
create function api.resolve_reconciliation_exception(p_idempotency_key text, p_exception_id uuid, p_note text,
                                                     p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e core.reconciliation_exception; f core.manual_fallback_entry; gp core.gate_point; p core.permit; pv core.permit_version;
        v_action text; t jsonb; r jsonb; v jsonb; excluded jsonb;
begin
  select * into e from core.reconciliation_exception where id = p_exception_id;
  select * into f from core.manual_fallback_entry where id = e.fallback_entry_id;
  if e.id is null or e.venue_id not in (select authz.gate_staff_venue_ids()) then
    return core.refuse('gate.reconcile', 'not_found', 'The record does not exist or you do not have access to it.', 'Access', 'The venue');
  end if;
  excluded := jsonb_build_array(f.operator_person_id) || case when f.person_id is not null then jsonb_build_array(f.person_id) else '[]' end;
  if e.kind = 'work' then
    v_action := 'gate.reconcile_work';
    select * into p from core.permit where id = e.permit_id;
    select * into pv from core.permit_version where id = p.current_version_id;
    t := core.permit_target(p, e.id, 'reconciliation_exception', null) || core.revision_scope(pv.revision_id)
         || jsonb_build_object('permit_class_id', p.permit_class_id, 'excluded_person_ids', excluded);
  else
    v_action := 'gate.reconcile';
    select * into gp from core.gate_point where id = f.gate_point_id;
    t := core.gate_target(gp, e.id, 'reconciliation_exception', excluded);
  end if;
  r := jsonb_build_object('exception_id', p_exception_id, 'note', p_note);
  v := core.authorised_or_refusal(v_action, t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if e.resolved_at is not null then
    return core.refuse(v_action, 'already_resolved', 'This exception is already resolved.', 'An open exception', 'Nobody');
  end if;
  if core.blank(p_note) then
    return core.refuse(v_action, 'invalid_content', 'Say what was found and done: an exception is resolved only with a note.', 'A note', 'You');
  end if;
  v := authz.require(v_action, t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  update core.reconciliation_exception set resolved_at = clock_timestamp(), resolved_by_person_id = (v ->> 'actor_person_id')::uuid,
                                           resolution_note = btrim(p_note), resolve_decision_context_id = (v ->> 'decision_context_id')::uuid
   where id = e.id;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------
create view api.gate_manifest            with (security_invoker = true) as select * from core.gate_manifest;
create view api.manual_fallback_entry    with (security_invoker = true) as select * from core.manual_fallback_entry;
create view api.reconciliation_exception with (security_invoker = true) as select * from core.reconciliation_exception;

grant select on api.gate_manifest, api.manual_fallback_entry, api.reconciliation_exception to authenticated;
grant execute on function api.download_manifest(text, uuid), api.submit_fallback_entries(text, uuid, uuid, jsonb),
  api.resolve_reconciliation_exception(text, uuid, text, uuid, uuid) to authenticated;
revoke execute on function api.download_manifest(text, uuid), api.submit_fallback_entries(text, uuid, uuid, jsonb),
  api.resolve_reconciliation_exception(text, uuid, text, uuid, uuid) from anon, public;
revoke execute on function core.raise_exception(core.manual_fallback_entry, text, text, text, text, uuid), core.gate_work_flags(uuid, uuid) from public;
