-- 0052 Notifications and scheduled jobs (phase 8a, D-021): catalogue, the outbox, deliveries,
--      preferences, the job run log and the chasing configuration
--
-- A notification tells someone that a decision was recorded or that something is due. It is
-- written in the decision's own transaction, to people resolved then from the record and from
-- current appointments (P8-2, invariant 1). It never changes a status, never settles anything
-- by time (invariant 10), and never replaces the venue's direct route for stopping work (Q203).
-- Critical notices always reach the inbox and email and cannot be switched off (P8-3). Routine
-- notices go where each person chooses (Q210, P8-4). Reminders and escalation follow the
-- venue's chasing configuration, which has no default (P8-5, CLAUDE.md §9). Scheduled jobs run
-- as a service account, never with the service role key, and every run is logged (P8-6).
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

insert into core.authority_action (code, basis, delegable, description) values
  ('notification.mark_read',       'subject', false, 'Mark one of my notifications read'),
  ('notification.set_preferences', 'subject', false, 'Choose how I receive routine notices (Q210)'),
  ('notification.claim_delivery',  'service', false, 'Lease notifications to send by email'),
  ('notification.record_delivery', 'service', false, 'Record whether a notification email was sent'),
  ('job.run',                      'service', false, 'Run a scheduled background job and record the run');

alter table core.service_account drop constraint service_account_purpose_check;
alter table core.service_account add constraint service_account_purpose_check
  check (purpose in ('malware_scanner', 'notification_sender', 'permit_expiry', 'job_runner'));
insert into core.service_action (purpose, action_code) values
  ('notification_sender', 'notification.claim_delivery'),
  ('notification_sender', 'notification.record_delivery'),
  ('job_runner', 'job.run');

-- ---------------------------------------------------------------------------
-- Chasing (Q207, P8-5): for each kind of overdue item the venue chooses to chase, how often to
-- remind its owner, and when and to whom to escalate. No default: an unconfigured kind is shown
-- on screen with its owner and never chased.
--   chasing: {items: {<kind>: {remind_every_hours: 1..720, escalate_after_hours: 1..2160 | null,
--                              escalate_to: {person_ids: [...], appointment_type_ids: [...]}}}}
--   kinds: approval_step, rfi, hand_back, fire_watch, impairment, invitation
-- ---------------------------------------------------------------------------
alter table core.venue_config_version drop constraint venue_config_version_kind_check;
alter table core.venue_config_version add constraint venue_config_version_kind_check
  check (kind in ('access_purposes', 'outage_procedure', 'chasing'));

create function core.chasing_kinds() returns text[]
language sql immutable set search_path = '' as $$
  select array['approval_step', 'rfi', 'hand_back', 'fire_watch', 'impairment', 'invitation'] $$;

create function core.validate_chasing(p_venue_id uuid, c jsonb, p_strict boolean) returns text[]
language plpgsql stable security definer set search_path = '' as $$
declare errs text[] := '{}'; k text; x jsonb; whole text := '^[0-9]+$';
begin
  if jsonb_typeof(c -> 'items') is distinct from 'object' then return array['Chasing is a set of kinds of overdue item.']; end if;
  for k, x in select * from jsonb_each(c -> 'items') loop
    if not (k = any (core.chasing_kinds())) then errs := errs || format('"%s" is not a kind of item that can be chased.', k); continue; end if;
    if coalesce(x ->> 'remind_every_hours', '') !~ whole or (x ->> 'remind_every_hours')::int not between 1 and 720 then
      errs := errs || format('%s: remind every 1 to 720 hours.', k);
    end if;
    if not x ? 'escalate_after_hours' or (jsonb_typeof(x -> 'escalate_after_hours') <> 'null'
         and (coalesce(x ->> 'escalate_after_hours', '') !~ whole or (x ->> 'escalate_after_hours')::int not between 1 and 2160)) then
      errs := errs || format('%s: say after how many hours (1 to 2160) to escalate, or that it is not escalated.', k);
    elsif jsonb_typeof(x -> 'escalate_after_hours') <> 'null' then
      if jsonb_typeof(x #> '{escalate_to,person_ids}') is distinct from 'array' or jsonb_typeof(x #> '{escalate_to,appointment_type_ids}') is distinct from 'array'
         or jsonb_array_length(x #> '{escalate_to,person_ids}') + jsonb_array_length(x #> '{escalate_to,appointment_type_ids}') = 0 then
        errs := errs || format('%s: name whom to escalate to (people, or the holders of an appointment type).', k);
      elsif exists (select 1 from jsonb_array_elements_text(x #> '{escalate_to,person_ids}') p
                     where not exists (select 1 from core.person pe join core.venue v on v.customer_id = pe.customer_id
                                        where pe.id::text = p and v.id = p_venue_id and pe.deactivated_at is null))
            or exists (select 1 from jsonb_array_elements_text(x #> '{escalate_to,appointment_type_ids}') t
                        where not exists (select 1 from core.appointment_type at where at.id::text = t and at.venue_id = p_venue_id)) then
        errs := errs || format('%s: escalate only to active people and appointment types at this venue.', k);
      end if;
    end if;
  end loop;
  if p_strict and (select count(*) from jsonb_object_keys(c -> 'items')) = 0 then
    errs := errs || text 'Choose at least one kind of overdue item to chase.';
  end if;
  return errs;
end $$;

do $m$
declare d text; anchor text := $s$  else
    errs := errs || text 'Unknown kind of configuration.';$s$;
begin
  d := pg_get_functiondef('core.validate_venue_config(uuid,text,jsonb,boolean)'::regprocedure);
  if position(anchor in d) = 0 then raise exception 'core.validate_venue_config no longer has the expected structure'; end if;
  execute replace(d, anchor, $s$  elsif p_kind = 'chasing' then
    errs := errs || core.validate_chasing(p_venue_id, c, p_strict);
$s$ || anchor);
end $m$;

-- ---------------------------------------------------------------------------
-- The outbox. One row per recipient; the dedupe key makes every source safe to re-run.
-- ---------------------------------------------------------------------------
create table core.notification (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null references core.customer,
  venue_id              uuid,
  recipient_person_id   uuid not null,
  class                 text not null check (class in ('critical', 'routine')),
  event                 text not null,
  record_table          text,
  record_id             uuid,
  dedupe_key            text not null,
  subject               text not null check (length(btrim(subject)) > 0),
  body                  text not null,
  link                  text check (link is null or link ~ '^/[^/]'),
  read_at               timestamptz,
  created_at            timestamptz not null default clock_timestamp(),
  row_version           integer not null default 1,
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, recipient_person_id) references core.person (customer_id, id),
  unique (recipient_person_id, dedupe_key)
);
create index notification_recipient_idx on core.notification (recipient_person_id, created_at desc);
select core.attach_standard_triggers('core.notification', 'read_at');

-- What has to be sent by email: critical always; routine as the recipient chose. A digest
-- delivery waits for the recipient's next daily digest.
create table core.notification_delivery (
  id                    uuid primary key default gen_random_uuid(),
  notification_id       uuid not null references core.notification,
  channel               text not null check (channel in ('email', 'digest')),
  delivery_state        text not null default 'pending' check (delivery_state in ('pending', 'sent', 'failed', 'no_address')),
  attempts              integer not null default 0,
  next_attempt_at       timestamptz not null default clock_timestamp(),
  leased_until          timestamptz,
  last_error            text,
  sent_at               timestamptz,
  row_version           integer not null default 1,
  created_at            timestamptz not null default clock_timestamp(),
  created_by_user_id    uuid default auth.uid(),
  unique (notification_id)
);
create index notification_delivery_due_idx on core.notification_delivery (delivery_state, next_attempt_at);
select core.attach_standard_triggers('core.notification_delivery', 'delivery_state,attempts,next_attempt_at,leased_until,last_error,sent_at');

-- A person's choice for routine notices (Q210). With no choice recorded, routine notices are in
-- the inbox only: a personal setting, not venue configuration.
create table core.notification_preference (
  person_id             uuid primary key references core.person,
  customer_id           uuid not null references core.customer,
  routine_mode          text not null check (routine_mode in ('in_app', 'email', 'digest')),
  last_digest_at        timestamptz,
  row_version           integer not null default 1,
  created_at            timestamptz not null default clock_timestamp(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, person_id) references core.person (customer_id, id)
);
select core.attach_standard_triggers('core.notification_preference', 'routine_mode,last_digest_at');

-- ---------------------------------------------------------------------------
-- Job runs (P8-6): every scheduled run, its outcome and counts, for operations.
-- ---------------------------------------------------------------------------
create table core.job_run (
  id                    uuid primary key default gen_random_uuid(),
  job                   text not null,
  started_at            timestamptz not null default clock_timestamp(),
  finished_at           timestamptz,
  outcome               text check (outcome in ('ok', 'failed')),
  counts                jsonb not null default '{}',
  error                 text,
  run_by_user_id        uuid default auth.uid(),
  row_version           integer not null default 1,
  created_at            timestamptz not null default clock_timestamp(),
  created_by_user_id    uuid default auth.uid(),
  check ((finished_at is null) = (outcome is null))
);
create index job_run_job_idx on core.job_run (job, started_at desc);
select core.attach_standard_triggers('core.job_run', 'finished_at,outcome,counts,error');

-- ---------------------------------------------------------------------------
-- Visibility: a person sees their own notifications and preference; deliveries and job runs
-- are for platform operations only. Nobody writes these tables directly.
-- ---------------------------------------------------------------------------
alter table core.notification enable row level security;
alter table core.notification_delivery enable row level security;
alter table core.notification_preference enable row level security;
alter table core.job_run enable row level security;
grant select on core.notification, core.notification_delivery, core.notification_preference, core.job_run to authenticated;
create policy notification_own on core.notification for select to authenticated using (recipient_person_id in (select authz.my_person_ids()));
create policy preference_own on core.notification_preference for select to authenticated using (person_id in (select authz.my_person_ids()));
create policy delivery_ops on core.notification_delivery for select to authenticated using (authz.is_platform_admin());
create policy job_run_ops on core.job_run for select to authenticated using (authz.is_platform_admin());
