-- 0053 Notifications and scheduled jobs API (phase 8a, D-021)
--
-- Sources write notifications through core.notify inside the decision's transaction, so a
-- notice exists exactly when its decision committed (P8-2). Critical notices (P8-3) come from
-- triggers on the records that carry the decision (a stop, a control failure, emergency work,
-- an outage exception, a restriction) and from the watch job (an impairment or fire watch
-- overdue). Routine notices come from triggers (issued awaiting acceptance, information
-- requested, accountable administrator changed) and from the jobs (decisions due, chasing).
-- The person who caused an event is not notified of it.
--
-- Recipients are always resolved from the record and from current appointments: never a role
-- name, never a mailing list (invariant 1). Jobs act as the job runner service account; email
-- is claimed and recorded by the notification sender (P8-6).
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

-- Chasing is a kind of venue configuration document; a first draft starts empty.
do $m$
declare d text;
begin
  d := pg_get_functiondef('api.create_venue_config_draft(text,uuid,text)'::regprocedure);
  if position($s$not in ('access_purposes', 'outage_procedure')$s$ in d) = 0
     or position($s$else '{"steps": []}'::jsonb end$s$ in d) = 0 then
    raise exception 'api.create_venue_config_draft no longer has the expected structure';
  end if;
  d := replace(d, $s$not in ('access_purposes', 'outage_procedure')$s$, $s$not in ('access_purposes', 'outage_procedure', 'chasing')$s$);
  d := replace(d, $s$else '{"steps": []}'::jsonb end$s$, $s$when 'chasing' then '{"items": {}}'::jsonb else '{"steps": []}'::jsonb end$s$);
  execute d;
end $m$;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
create function core.person_email(p_person_id uuid) returns text
language sql stable security definer set search_path = '' as $$
  select u.email::text from core.user_account ua join auth.users u on u.id = ua.auth_user_id
   where ua.person_id = p_person_id and ua.disabled_at is null order by ua.created_at limit 1 $$;

-- Who holds a current, unrestricted appointment that could take this action on this target.
create function core.action_holders(p_action text, p_target jsonb) returns uuid[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(distinct a.appointee_person_id), '{}')
    from core.appointment a
   where a.venue_id = (p_target ->> 'venue_id')::uuid and a.status = 'in_force' and now() <@ a.valid_during
     and not authz.person_restricted(a.appointee_person_id, a.venue_id)
     and not (coalesce(p_target -> 'excluded_person_ids', '[]') ? a.appointee_person_id::text)
     and jsonb_array_length(authz.capacities(p_action, p_target, a.appointee_person_id)) > 0 $$;

-- Appointees whose appointment type allows an action anywhere at the venue.
create function core.venue_action_appointees(p_venue_id uuid, p_action text) returns uuid[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(distinct a.appointee_person_id), '{}')
    from core.appointment a join core.appointment_type_version tv on tv.id = a.appointment_type_version_id
   where a.venue_id = p_venue_id and a.status = 'in_force' and now() <@ a.valid_during and p_action = any (tv.allowed_action_codes)
     and not authz.person_restricted(a.appointee_person_id, a.venue_id) $$;

create function core.tenant_admin_people(p_customer_id uuid) returns uuid[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(distinct t.person_id), '{}') from core.tenant_admin t
   where t.customer_id = p_customer_id and t.revoked_at is null and now() <@ t.valid_during $$;

create function core.permit_supervisors(p_permit_id uuid) returns uuid[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(distinct m.person_id), '{}') from core.permit_team_member m
   where m.permit_id = p_permit_id and m.role = 'supervisor' and m.removed_at is null $$;

create function core.permit_issuer(p_permit_id uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select s.issuer_person_id from core.issue_snapshot s where s.permit_id = p_permit_id order by s.issued_at desc limit 1 $$;

-- The people who answer for a live permit: its supervisors and issuer, and for a child permit
-- the Work Approval's supervisors.
create function core.permit_owners(p_permit_id uuid) returns uuid[]
language sql stable security definer set search_path = '' as $$
  select core.permit_supervisors(p.id) || coalesce(array[core.permit_issuer(p.id)], '{}')
         || case when p.parent_permit_id is not null then core.permit_supervisors(p.parent_permit_id) else '{}' end
    from core.permit p where p.id = p_permit_id $$;

create function core.permit_label(p_permit_id uuid) returns text
language sql stable security definer set search_path = '' as $$
  select format('%s for %s', pc.name, w.reference) from core.permit p join core.permit_class pc on pc.id = p.permit_class_id
    join core.work_package w on w.id = p.work_package_id where p.id = p_permit_id $$;

create function core.venue_time(p_venue_id uuid, p_at timestamptz) returns text
language sql stable security definer set search_path = '' as $$
  select to_char(p_at at time zone coalesce((select timezone from core.venue where id = p_venue_id), 'UTC'), 'HH24:MI "on" DD/MM/YYYY') $$;

-- ---------------------------------------------------------------------------
-- The outbox (P8-2, P8-3, P8-4)
-- ---------------------------------------------------------------------------
create function core.notify(p_customer_id uuid, p_venue_id uuid, p_recipients uuid[], p_class text, p_event text,
                            p_record_table text, p_record_id uuid, p_dedupe_key text, p_subject text, p_body text, p_link text,
                            p_exclude uuid[] default '{}')
returns integer language plpgsql security definer set search_path = '' as $$
declare r uuid; n_id uuid; mode text; n integer := 0;
begin
  for r in select distinct x from unnest(coalesce(p_recipients, '{}')) x
            where x is not null and not (x = any (coalesce(p_exclude, '{}'))) loop
    continue when not exists (select 1 from core.person pe where pe.id = r and pe.customer_id = p_customer_id and pe.deactivated_at is null);
    insert into core.notification (customer_id, venue_id, recipient_person_id, class, event, record_table, record_id, dedupe_key, subject, body, link)
    values (p_customer_id, p_venue_id, r, p_class, p_event, p_record_table, p_record_id, p_dedupe_key, p_subject,
            p_body || case when p_class = 'critical'
              then E'\n\nOctra has recorded this. It is not an instruction: the venue''s direct route (control room, supervisor) still applies.' else '' end,
            p_link)
    on conflict (recipient_person_id, dedupe_key) do nothing
    returning id into n_id;
    continue when n_id is null;
    n := n + 1;
    -- Critical: always emailed, whatever the person chose (P8-3). Routine: as they chose (Q210).
    mode := case when p_class = 'critical' then 'email'
                 else coalesce((select routine_mode from core.notification_preference where person_id = r), 'in_app') end;
    if mode in ('email', 'digest') then
      insert into core.notification_delivery (notification_id, channel, delivery_state)
      values (n_id, mode, case when core.person_email(r) is null then 'no_address' else 'pending' end);
    end if;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------------
-- Critical sources (triggers): in the decision's own transaction.
-- ---------------------------------------------------------------------------
create function core.notify_suspension() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform core.notify(new.customer_id, new.venue_id, core.permit_owners(new.permit_id), 'critical', 'work_stopped',
    'core.permit', new.permit_id, 'suspension:' || new.id,
    format('Work stopped: %s', core.permit_label(new.permit_id)),
    format('%s stopped the %s work at %s. Reason: %s', core.person_name(new.stopped_by_person_id), core.permit_label(new.permit_id),
           core.venue_time(new.venue_id, new.created_at), new.reason),
    '/permits/' || new.permit_id, array[new.stopped_by_person_id]);
  return null;
end $$;
create trigger z_notify after insert on core.permit_suspension for each row execute function core.notify_suspension();

create function core.notify_control_failure() returns trigger
language plpgsql security definer set search_path = '' as $$
declare owners uuid[]; label text;
begin
  -- Whoever answers for the control: its continuing owner, and those who requested, authorised,
  -- applied or proved it.
  owners := coalesce((select array_agg(o.owner_person_id) from core.control_ownership o where o.control_kind = new.control_kind and o.control_id = new.control_id), '{}')
            || coalesce((select array_agg(distinct e.person_id) from core.control_event e
                          where e.control_kind = new.control_kind and e.control_id = new.control_id and e.person_id is not null), '{}')
            || case new.control_kind
                 when 'isolation' then coalesce((select array[requested_by_person_id] from core.isolation where id = new.control_id), '{}')
                 when 'impairment' then coalesce((select array[requested_by_person_id] from core.impairment where id = new.control_id), '{}')
                 when 'fire_watch' then coalesce((select array[watcher_person_id, arranged_by_person_id] from core.fire_watch where id = new.control_id), '{}')
                 else '{}' end;
  label := replace(new.control_kind, '_', ' ');
  perform core.notify(new.customer_id, new.venue_id, owners, 'critical', 'control_failed', 'core.' || new.control_kind, new.control_id,
    'control_failure:' || new.id, format('Control failure: an %s', label),
    format('%s reported that an %s failed at %s: %s. Every job relying on it is stopped.', core.person_name(new.reported_by_person_id), label,
           core.venue_time(new.venue_id, new.created_at), new.reason),
    '/controls', array[new.reported_by_person_id]);
  return null;
end $$;
create trigger z_notify after insert on core.control_failure for each row execute function core.notify_control_failure();

create function core.notify_emergency() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform core.notify(new.customer_id, new.venue_id,
    core.tenant_admin_people(new.customer_id) || core.venue_action_appointees(new.venue_id, 'permit.issue'),
    'critical', 'emergency_authorised', 'core.emergency_work', new.id, 'emergency:' || new.id,
    format('Emergency work authorised: %s', new.reference),
    format('%s authorised emergency work (%s) at %s. Its retrospective permit is due by %s.', core.person_name(new.authorised_by_person_id),
           new.category, core.venue_time(new.venue_id, new.created_at), core.venue_time(new.venue_id, new.deadline_at)),
    '/emergency', array[new.authorised_by_person_id]);
  return null;
end $$;
create trigger z_notify after insert on core.emergency_work for each row execute function core.notify_emergency();

create function core.notify_reconciliation() returns trigger
language plpgsql security definer set search_path = '' as $$
declare gp core.gate_point; recipients uuid[];
begin
  if new.kind = 'work' then
    recipients := core.permit_owners(new.permit_id);
  else
    select g.* into gp from core.gate_point g join core.manual_fallback_entry f on f.gate_point_id = g.id where f.id = new.fallback_entry_id;
    recipients := core.action_holders('gate.reconcile', core.gate_target(gp, new.id, 'reconciliation_exception'));
  end if;
  perform core.notify(new.customer_id, new.venue_id, recipients, 'critical', 'outage_exception', 'core.reconciliation_exception', new.id,
    'reconciliation:' || new.id, case new.kind when 'work' then 'Outage: let in while work was stopped' else 'Outage: an entry needs reconciling' end,
    new.words, '/gate/reconcile',
    array[(select operator_person_id from core.manual_fallback_entry where id = new.fallback_entry_id)]);
  return null;
end $$;
create trigger z_notify after insert on core.reconciliation_exception for each row execute function core.notify_reconciliation();

-- A restriction affecting live work: the permits' owners are told the fact, never the grounds.
create function core.notify_restriction() returns trigger
language plpgsql security definer set search_path = '' as $$
declare x record; who text;
begin
  if new.status <> 'active' then return null; end if;
  who := case new.subject_kind when 'person' then core.person_name(new.person_id)
              else (select legal_name from core.organisation where id = new.organisation_id) end;
  for x in select p.id from core.permit p join core.work_package w on w.id = p.work_package_id
            where p.venue_id = new.venue_id and core.is_live(p.status)
              and ((new.subject_kind = 'person' and exists (select 1 from core.permit_team_member m where m.permit_id = p.id
                                                              and m.person_id = new.person_id and m.removed_at is null))
                or (new.subject_kind = 'organisation' and w.performing_organisation_id = new.organisation_id)) loop
    perform core.notify(new.customer_id, new.venue_id, core.permit_owners(x.id), 'critical', 'restriction_live_work', 'core.permit', x.id,
      'restriction:' || new.id || ':' || x.id, format('Restriction affects live work: %s', core.permit_label(x.id)),
      format('%s is now restricted at this venue. Check the %s work with the venue''s access authority before it continues.', who, core.permit_label(x.id)),
      '/permits/' || x.id, array[(select actor_person_id from core.decision_context where id = new.imposed_by_decision_context_id)]);
  end loop;
  return null;
end $$;
create trigger z_notify after insert on core.restriction for each row execute function core.notify_restriction();

-- ---------------------------------------------------------------------------
-- Routine sources (triggers)
-- ---------------------------------------------------------------------------
create function core.notify_permit_status() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.table_name = 'core.permit' and new.to_state = 'issued_awaiting_acceptance' then
    perform core.notify(new.customer_id, new.venue_id, core.permit_supervisors(new.record_id), 'routine', 'issued_awaiting_acceptance',
      'core.permit', new.record_id, 'issued:' || new.record_id || ':' || new.decision_context_id,
      format('Issued, awaiting your acceptance: %s', core.permit_label(new.record_id)),
      format('The %s has been issued. It is not active until you accept it at the workface.', core.permit_label(new.record_id)),
      '/permits/' || new.record_id);
  end if;
  return null;
end $$;
create trigger z_notify after insert on core.status_history for each row execute function core.notify_permit_status();

create function core.notify_rfi() returns trigger
language plpgsql security definer set search_path = '' as $$
declare p core.permit; rev core.work_package_revision;
begin
  select pe.* into p from core.permit pe join core.permit_version v on v.permit_id = pe.id where v.id = new.permit_version_id;
  select r.* into rev from core.work_package_revision r join core.work_package w on w.current_revision_id = r.id where w.id = p.work_package_id;
  perform core.notify(new.customer_id, new.venue_id, array[rev.contact_person_id, rev.supervisor_person_id], 'routine', 'information_requested',
    'core.rfi', new.id, 'rfi:' || new.id, format('More information requested: %s', core.permit_label(p.id)),
    format('The venue has asked for more information before deciding the %s: %s', core.permit_label(p.id), new.message),
    '/permits/' || p.id);
  return null;
end $$;
create trigger z_notify after insert on core.rfi for each row execute function core.notify_rfi();

-- C1: the venue's administrators are told when an organisation's accountable administrator changes.
create function core.notify_accountable_admin() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.role = 'accountable' and exists (select 1 from core.organisation_admin o where o.organisation_id = new.organisation_id
                                            and o.role = 'accountable' and o.id <> new.id) then
    perform core.notify(new.customer_id, null, core.tenant_admin_people(new.customer_id), 'routine', 'accountable_admin_changed',
      'core.organisation', new.organisation_id, 'org_admin:' || new.id,
      format('Accountable administrator changed: %s', (select legal_name from core.organisation where id = new.organisation_id)),
      format('%s is now the accountable administrator of %s.', core.person_name(new.person_id),
             (select legal_name from core.organisation where id = new.organisation_id)),
      '/venue', array[new.granted_by_person_id]);
  end if;
  return null;
end $$;
create trigger z_notify after insert on core.organisation_admin for each row execute function core.notify_accountable_admin();

-- ---------------------------------------------------------------------------
-- Items that can be overdue, with when they became due and who owns them (Q207).
-- ---------------------------------------------------------------------------
create function core.chase_items(p_venue_id uuid, p_kind text)
returns table (item_id uuid, since timestamptz, owners uuid[], class text, subject text, link text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_kind = 'approval_step' then
    return query select s.id, v.created_at, core.action_holders(core.step_action(s.kind), core.step_target(s, p, s.id)), 'routine'::text,
                        format('Decision due: %s, %s', s.name, core.permit_label(p.id)), '/review'::text
      from core.permit p join core.permit_version v on v.id = p.current_version_id join core.permit_step s on s.permit_version_id = v.id
     where p.venue_id = p_venue_id and p.status in ('submitted', 'under_review') and core.step_open(s.id);
  elsif p_kind = 'rfi' then
    return query select f.id, f.created_at, array[r.contact_person_id, r.supervisor_person_id], 'routine'::text,
                        format('Information still needed: %s', core.permit_label(p.id)), '/permits/' || p.id
      from core.rfi f join core.permit_version v on v.id = f.permit_version_id join core.permit p on p.id = v.permit_id
      join core.work_package w on w.id = p.work_package_id join core.work_package_revision r on r.id = w.current_revision_id
     where f.venue_id = p_venue_id and p.status = 'more_information_required' and p.current_version_id = f.permit_version_id
       and not exists (select 1 from core.rfi_response x where x.rfi_id = f.id);
  elsif p_kind = 'hand_back' then
    return query select p.id, (select max(h.at) from core.status_history h where h.table_name = 'core.permit' and h.record_id = p.id
                                 and h.to_state = 'hand_back_pending'),
                        core.permit_supervisors(p.id), 'routine'::text, format('Hand-back due: %s', core.permit_label(p.id)), '/permits/' || p.id
      from core.permit p where p.venue_id = p_venue_id and p.status = 'hand_back_pending';
  elsif p_kind = 'fire_watch' then
    return query select w.id, core.fire_watch_overdue_since(w), array[w.watcher_person_id, w.arranged_by_person_id] || core.permit_supervisors(w.permit_id),
                        'critical'::text, format('Fire watch not started: %s', core.permit_label(w.permit_id)), '/permits/' || w.permit_id
      from core.fire_watch w where w.venue_id = p_venue_id and core.fire_watch_overdue_since(w) is not null;
  elsif p_kind = 'impairment' then
    return query select i.id, core.impairment_overdue_since(i), array[i.requested_by_person_id]
                          || coalesce((select array_agg(o.owner_person_id) from core.control_ownership o where o.control_kind = 'impairment' and o.control_id = i.id), '{}')
                          || coalesce((select array_agg(x) from core.control_link l, unnest(core.permit_supervisors(l.permit_id)) x
                                        where l.control_kind = 'impairment' and l.control_id = i.id), '{}'),
                        'critical'::text, format('Impairment overdue: %s', (select name from core.system where id = i.system_id)), '/controls'::text
      from core.impairment i where i.venue_id = p_venue_id and core.impairment_overdue_since(i) is not null;
  elsif p_kind = 'invitation' then
    return query select n.id, n.created_at, array[n.owner_person_id], 'routine'::text,
                        format('Invitation not yet accepted: %s %s', n.invitee_given_name, n.invitee_family_name), '/venue'::text
      from core.invitation n where n.venue_id = p_venue_id and n.status = 'pending' and n.expires_at > now();
  end if;
end $$;

-- A fire watch arranged but not started once its permit's work has stopped or ended: the watch
-- should be running. Overdue since the permit left active.
create function core.fire_watch_overdue_since(w core.fire_watch) returns timestamptz
language sql stable security definer set search_path = '' as $$
  select (select max(h.at) from core.status_history h where h.table_name = 'core.permit' and h.record_id = w.permit_id and h.from_state = 'active')
   where w.status = 'arranged'
     and (select status from core.permit where id = w.permit_id) in ('suspended', 'hand_back_pending', 'expired') $$;

-- An impairment past its approved maximum duration, or still not restored after its planned end.
create function core.impairment_overdue_since(i core.impairment) returns timestamptz
language sql stable security definer set search_path = '' as $$
  select least(case when i.status = 'impaired' and i.max_hours is not null
                    then i.impaired_at + make_interval(secs => (i.max_hours * 3600)::double precision) end,
               case when i.status in ('impaired', 'tested') then upper(i.planned_window) end)
   where i.status in ('impaired', 'tested')
     and now() > least(case when i.status = 'impaired' and i.max_hours is not null
                            then i.impaired_at + make_interval(secs => (i.max_hours * 3600)::double precision) end,
                       case when i.status in ('impaired', 'tested') then upper(i.planned_window) end) $$;

create function core.escalation_people(p_venue_id uuid, p_to jsonb) returns uuid[]
language sql stable security definer set search_path = '' as $$
  select coalesce((select array_agg(x::uuid) from jsonb_array_elements_text(coalesce(p_to -> 'person_ids', '[]')) x), '{}')
      || coalesce((select array_agg(distinct a.appointee_person_id) from core.appointment a
                     join core.appointment_type_version tv on tv.id = a.appointment_type_version_id
                    where a.venue_id = p_venue_id and a.status = 'in_force' and now() <@ a.valid_during
                      and tv.appointment_type_id::text in (select jsonb_array_elements_text(coalesce(p_to -> 'appointment_type_ids', '[]')))), '{}') $$;

-- ---------------------------------------------------------------------------
-- The jobs (P8-6)
-- ---------------------------------------------------------------------------
create function core.job_started(p_job text) returns uuid
language sql security definer set search_path = '' as $$
  insert into core.job_run (job) values (p_job) returning id $$;
create function core.job_finished(p_id uuid, p_counts jsonb) returns void
language sql security definer set search_path = '' as $$
  update core.job_run set finished_at = clock_timestamp(), outcome = 'ok', counts = p_counts where id = p_id $$;

-- Decisions due, overdue watches and impairments, and the venue's chasing. Safe to re-run:
-- every notice has a dedupe key, so a second run sends nothing new.
create function api.run_notification_jobs() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v jsonb := authz.evaluate('job.run', '{}'::jsonb); run_id uuid; vn core.venue; cfg core.venue_config_version; k text; c jsonb;
  it record; hours numeric; n_due integer := 0; n_watch integer := 0; n_remind integer := 0; n_escalate integer := 0; nth integer;
begin
  if not (v ->> 'allowed')::boolean then return v; end if;
  run_id := core.job_started('notifications');
  for vn in select * from core.venue loop
    -- Decisions due: the people who can decide each open step (routine).
    for it in select * from core.chase_items(vn.id, 'approval_step') loop
      n_due := n_due + core.notify(vn.customer_id, vn.id, it.owners, 'routine', 'decision_due', 'core.permit_step', it.item_id,
        'step:' || it.item_id, it.subject, 'A decision is waiting for someone who holds the appointment for it. Whoever decides first records it.', it.link);
    end loop;
    -- Overdue watches and impairments are critical whether or not the venue chases them.
    for k in select unnest(array['fire_watch', 'impairment']) loop
      for it in select * from core.chase_items(vn.id, k) loop
        n_watch := n_watch + core.notify(vn.customer_id, vn.id, it.owners, 'critical', k || '_overdue', 'core.' || k, it.item_id,
          k || '_overdue:' || it.item_id, it.subject,
          format('Overdue since %s.', core.venue_time(vn.id, it.since)), it.link);
      end loop;
    end loop;
    -- The venue's chasing (Q207). Nothing is chased without an approved configuration.
    cfg := core.venue_config(vn.id, 'chasing');
    continue when cfg.id is null;
    for k, c in select * from jsonb_each(cfg.content -> 'items') loop
      for it in select * from core.chase_items(vn.id, k) where since is not null loop
        hours := extract(epoch from now() - it.since) / 3600;
        nth := floor(hours / (c ->> 'remind_every_hours')::numeric)::integer;
        if nth >= 1 then
          n_remind := n_remind + core.notify(vn.customer_id, vn.id, it.owners, it.class, 'reminder', null, it.item_id,
            format('remind:%s:%s:%s', k, it.item_id, nth), 'Reminder: ' || it.subject,
            format('Still waiting since %s.', core.venue_time(vn.id, it.since)), it.link);
        end if;
        if jsonb_typeof(c -> 'escalate_after_hours') = 'number' and hours >= (c ->> 'escalate_after_hours')::numeric then
          n_escalate := n_escalate + core.notify(vn.customer_id, vn.id, core.escalation_people(vn.id, c -> 'escalate_to'), it.class, 'escalation', null,
            it.item_id, format('escalate:%s:%s', k, it.item_id), 'Escalated: ' || it.subject,
            format('Waiting since %s, past the venue''s escalation time. It is still with its owner: escalation changes nothing on the record.',
                   core.venue_time(vn.id, it.since)), it.link);
        end if;
      end loop;
    end loop;
  end loop;
  perform core.job_finished(run_id, jsonb_build_object('decisions_due', n_due, 'overdue', n_watch, 'reminders', n_remind, 'escalations', n_escalate));
  return jsonb_build_object('ok', true, 'run_id', run_id, 'decisions_due', n_due, 'overdue', n_watch, 'reminders', n_remind, 'escalations', n_escalate);
end $$;

-- The runner records jobs it runs outside the database (expiry, sending email).
create function api.record_job_run(p_job text, p_outcome text, p_counts jsonb, p_error text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v jsonb := authz.evaluate('job.run', '{}'::jsonb); run_id uuid;
begin
  if not (v ->> 'allowed')::boolean then return v; end if;
  if coalesce(p_outcome, '') not in ('ok', 'failed') or core.blank(p_job) then
    raise exception 'a job run needs a job and an outcome' using errcode = '22023';
  end if;
  insert into core.job_run (job, finished_at, outcome, counts, error) values (p_job, clock_timestamp(), p_outcome, coalesce(p_counts, '{}'), p_error)
  returning id into run_id;
  return jsonb_build_object('ok', true, 'run_id', run_id);
end $$;

-- ---------------------------------------------------------------------------
-- Email delivery (the notification sender service)
-- ---------------------------------------------------------------------------
create function api.claim_email_batch(p_limit integer default 20, p_lease_seconds integer default 120) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v jsonb := authz.evaluate('notification.claim_delivery', '{}'::jsonb); ids uuid[];
begin
  if not (v ->> 'allowed')::boolean then return v; end if;
  if p_limit not between 1 and 200 or p_lease_seconds not between 30 and 900 then
    raise exception 'limit 1-200, lease 30-900 seconds' using errcode = '22023';
  end if;
  select array_agg(id) into ids from (
    select d.id from core.notification_delivery d
     where d.channel = 'email' and d.delivery_state = 'pending' and d.next_attempt_at <= clock_timestamp()
       and (d.leased_until is null or d.leased_until < clock_timestamp())
     order by d.next_attempt_at limit p_limit for update skip locked) z;
  update core.notification_delivery set leased_until = clock_timestamp() + make_interval(secs => p_lease_seconds), attempts = attempts + 1
   where id = any (coalesce(ids, '{}'));
  return jsonb_build_object('ok', true, 'emails', coalesce((select jsonb_agg(jsonb_build_object(
      'delivery_ids', jsonb_build_array(d.id), 'to', core.person_email(n.recipient_person_id), 'class', n.class,
      'subject', case when n.class = 'critical' then '[Critical] ' else '' end || n.subject, 'body', n.body, 'link', n.link))
    from core.notification_delivery d join core.notification n on n.id = d.notification_id where d.id = any (coalesce(ids, '{}'))), '[]'));
end $$;

-- Daily digests: each person with routine notices waiting, at most once a day.
create function api.claim_digest_batch(p_limit integer default 20, p_lease_seconds integer default 120) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v jsonb := authz.evaluate('notification.claim_delivery', '{}'::jsonb); people uuid[]; out jsonb := '[]'; pid uuid; ids uuid[];
begin
  if not (v ->> 'allowed')::boolean then return v; end if;
  select array_agg(r) into people from (
    select distinct n.recipient_person_id r from core.notification_delivery d join core.notification n on n.id = d.notification_id
      left join core.notification_preference pr on pr.person_id = n.recipient_person_id
     where d.channel = 'digest' and d.delivery_state = 'pending' and (d.leased_until is null or d.leased_until < clock_timestamp())
       and (pr.last_digest_at is null or pr.last_digest_at < clock_timestamp() - interval '23 hours')
     limit p_limit) z;
  foreach pid in array coalesce(people, '{}') loop
    select array_agg(d.id) into ids from core.notification_delivery d join core.notification n on n.id = d.notification_id
     where n.recipient_person_id = pid and d.channel = 'digest' and d.delivery_state = 'pending';
    update core.notification_delivery set leased_until = clock_timestamp() + make_interval(secs => p_lease_seconds), attempts = attempts + 1 where id = any (ids);
    out := out || jsonb_build_object('delivery_ids', to_jsonb(ids), 'to', core.person_email(pid), 'class', 'routine',
      'subject', 'Your Octra daily summary',
      'body', (select string_agg('- ' || n.subject || coalesce(' (' || n.link || ')', ''), E'\n' order by n.created_at)
                 from core.notification_delivery d join core.notification n on n.id = d.notification_id where d.id = any (ids)),
      'link', '/inbox');
  end loop;
  return jsonb_build_object('ok', true, 'emails', out);
end $$;

create function api.record_email_result(p_delivery_ids uuid[], p_ok boolean, p_error text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v jsonb := authz.evaluate('notification.record_delivery', '{}'::jsonb);
begin
  if not (v ->> 'allowed')::boolean then return v; end if;
  if p_ok then
    update core.notification_delivery set delivery_state = 'sent', sent_at = clock_timestamp(), leased_until = null, last_error = null
     where id = any (p_delivery_ids) and delivery_state = 'pending';
    insert into core.notification_preference (person_id, customer_id, routine_mode, last_digest_at)
    select distinct n.recipient_person_id, n.customer_id, 'digest', clock_timestamp()
      from core.notification_delivery d join core.notification n on n.id = d.notification_id where d.id = any (p_delivery_ids) and d.channel = 'digest'
    on conflict (person_id) do update set last_digest_at = excluded.last_digest_at;
  else
    -- A failure is retried with a growing wait; after five attempts it stays failed and is shown to operations.
    update core.notification_delivery
       set delivery_state = case when attempts >= 5 then 'failed' else 'pending' end, leased_until = null, last_error = left(coalesce(p_error, 'unknown'), 500),
           next_attempt_at = clock_timestamp() + make_interval(mins => power(2, attempts)::integer)
     where id = any (p_delivery_ids) and delivery_state = 'pending';
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------------
-- The inbox and preferences (the person themselves)
-- ---------------------------------------------------------------------------
create function api.mark_notifications_read(p_ids uuid[]) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare n core.notification; v jsonb; done integer := 0;
begin
  for n in select * from core.notification where id = any (coalesce(p_ids, '{}')) and read_at is null loop
    v := authz.evaluate('notification.mark_read', jsonb_build_object('customer_id', n.customer_id, 'record_id', n.id,
                                                                     'target_type', 'notification', 'subject_person_id', n.recipient_person_id));
    continue when not (v ->> 'allowed')::boolean;
    update core.notification set read_at = clock_timestamp() where id = n.id;
    done := done + 1;
  end loop;
  return jsonb_build_object('ok', true, 'marked', done);
end $$;

create function api.set_notification_preference(p_mode text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pe core.person; v jsonb; done integer := 0;
begin
  if coalesce(p_mode, '') not in ('in_app', 'email', 'digest') then
    return core.refuse('notification.set_preferences', 'invalid_content', 'Choose in Octra only, email as it happens, or a daily email.', 'A choice', 'You');
  end if;
  for pe in select * from core.person where id in (select authz.my_person_ids()) loop
    v := authz.evaluate('notification.set_preferences', jsonb_build_object('customer_id', pe.customer_id, 'record_id', pe.id,
                                                                           'target_type', 'notification_preference', 'subject_person_id', pe.id));
    continue when not (v ->> 'allowed')::boolean;
    insert into core.notification_preference (person_id, customer_id, routine_mode) values (pe.id, pe.customer_id, p_mode)
    on conflict (person_id) do update set routine_mode = excluded.routine_mode;
    done := done + 1;
  end loop;
  if done = 0 then
    return core.refuse('notification.set_preferences', 'not_subject', 'Your account is not linked to a person record.', 'A person record', 'The venue');
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------
create view api.notification            with (security_invoker = true) as
  select id, customer_id, venue_id, recipient_person_id, class, event, record_table, record_id, subject, body, link, read_at, created_at
    from core.notification;
create view api.notification_preference with (security_invoker = true) as select person_id, routine_mode, last_digest_at from core.notification_preference;
create view api.notification_delivery   with (security_invoker = true) as
  select id, notification_id, channel, delivery_state, attempts, next_attempt_at, last_error, sent_at, created_at from core.notification_delivery;
create view api.job_run                 with (security_invoker = true) as select * from core.job_run;

grant select on api.notification, api.notification_preference, api.notification_delivery, api.job_run to authenticated;
grant execute on function api.run_notification_jobs(), api.record_job_run(text, text, jsonb, text), api.claim_email_batch(integer, integer),
  api.claim_digest_batch(integer, integer), api.record_email_result(uuid[], boolean, text), api.mark_notifications_read(uuid[]),
  api.set_notification_preference(text) to authenticated;
revoke execute on function api.run_notification_jobs(), api.record_job_run(text, text, jsonb, text), api.claim_email_batch(integer, integer),
  api.claim_digest_batch(integer, integer), api.record_email_result(uuid[], boolean, text), api.mark_notifications_read(uuid[]),
  api.set_notification_preference(text) from anon, public;
revoke execute on function core.notify(uuid, uuid, uuid[], text, text, text, uuid, text, text, text, text, uuid[]) from public;
