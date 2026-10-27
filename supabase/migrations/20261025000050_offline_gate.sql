-- 0050 Offline gate (phase 7d, D-020): the outage procedure, manifests, manual fallback
--      entries and reconciliation exceptions
--
-- Offline status is never current authorisation (invariant 11, P7-8). A gate device may
-- download a read-only manifest of what the live record said at a moment, to look people
-- up during an outage; it never admits anyone by itself. Every entry made during an outage
-- is a manual fallback entry under the venue's own outage procedure (Q200, Q201). On
-- reconnection each entry is checked against the live record; where it differs, a
-- reconciliation exception is raised with an owner and stays open until resolved with a
-- note, never by time (Q202, invariant 10). A suspension after the last sync is always
-- raised (Q203). Octra notifies nobody (phase 8).
--
-- The outage procedure, and the manifest's maximum age, are venue configuration with no
-- default (Q198, Q201, P7-10), in the venue configuration document from 7b.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

insert into core.authority_action (code, basis, delegable, description) values
  ('gate.download_manifest', 'appointment', true, 'Download a gate manifest for look-up during an outage (Q198)'),
  ('gate.submit_fallback',   'appointment', true, 'Upload the manual entries made at a gate during an outage (Q200)'),
  ('gate.reconcile',         'appointment', true, 'Resolve an entry exception found on reconnection (Q202)'),
  ('gate.reconcile_work',    'appointment', true, 'Resolve a work exception found on reconnection, for a permit (Q202, Q203)');

-- ---------------------------------------------------------------------------
-- The outage procedure (Q198, Q199, Q201)
--   outage_procedure: {instruction: text shown on the offline banner,
--                      steps: [text], manifest_max_age_minutes: 1..1440}
-- ---------------------------------------------------------------------------
alter table core.venue_config_version drop constraint venue_config_version_kind_check;
alter table core.venue_config_version add constraint venue_config_version_kind_check check (kind in ('access_purposes', 'outage_procedure'));

create or replace function core.validate_venue_config(p_venue_id uuid, p_kind text, c jsonb, p_strict boolean) returns text[]
language plpgsql stable security definer set search_path = '' as $$
declare errs text[] := '{}'; x jsonb; keys text[] := '{}';
begin
  if p_kind = 'access_purposes' then
    if jsonb_typeof(c -> 'purposes') is distinct from 'array' then return array['Access purposes are a list.']; end if;
    for x in select * from jsonb_array_elements(c -> 'purposes') loop
      if coalesce(x ->> 'key', '') !~ '^[a-z0-9-]{1,60}$' or (x ->> 'key') = any (keys) then
        errs := errs || text 'Every purpose needs a unique key of lower-case letters, digits and hyphens.'; continue;
      end if;
      keys := keys || (x ->> 'key');
      if core.blank(x ->> 'name') or core.blank(x ->> 'allows') or core.blank(x ->> 'prohibits') then
        errs := errs || format('Purpose "%s" needs a name, what it allows and what it prohibits (Q121).', x ->> 'key');
      end if;
      if jsonb_typeof(x -> 'induction_course_ids') is distinct from 'array'
         or exists (select 1 from jsonb_array_elements_text(x -> 'induction_course_ids') k
                     where not exists (select 1 from core.induction_course ic where ic.id::text = k and ic.venue_id = p_venue_id)) then
        errs := errs || format('Purpose "%s": state the inductions a visitor needs (none is allowed, but must be stated).', x ->> 'key');
      end if;
      if coalesce(x ->> 'escort', '') not in ('never', 'always') then
        errs := errs || format('Purpose "%s": choose whether visitors are always escorted.', x ->> 'key');
      end if;
      if jsonb_typeof(x -> 'occupier_consent') is distinct from 'boolean' then
        errs := errs || format('Purpose "%s": choose whether the occupier of an area must consent (Q123).', x ->> 'key');
      end if;
    end loop;
    if p_strict and jsonb_array_length(c -> 'purposes') = 0 then errs := errs || text 'Define at least one purpose.'; end if;
  elsif p_kind = 'outage_procedure' then
    if c ? 'steps' and (jsonb_typeof(c -> 'steps') is distinct from 'array'
                        or exists (select 1 from jsonb_array_elements(c -> 'steps') s where jsonb_typeof(s) <> 'string' or core.blank(s #>> '{}'))) then
      errs := errs || text 'The procedure''s steps are a list of instructions, none blank.';
    end if;
    if c ? 'manifest_max_age_minutes' and (jsonb_typeof(c -> 'manifest_max_age_minutes') is distinct from 'number'
         or (c ->> 'manifest_max_age_minutes')::numeric <> floor((c ->> 'manifest_max_age_minutes')::numeric)
         or (c ->> 'manifest_max_age_minutes')::numeric not between 1 and 1440) then
      errs := errs || text 'The manifest''s maximum age is a whole number of minutes, from 1 to 1440 (Q198).';
    end if;
    if p_strict then
      if core.blank(c ->> 'instruction') then errs := errs || text 'Give the instruction shown to gate staff while offline (Q199).'; end if;
      if jsonb_typeof(c -> 'steps') is distinct from 'array' or jsonb_array_length(c -> 'steps') = 0 then
        errs := errs || text 'Give the steps of the venue''s outage procedure (Q201).';
      end if;
      if not c ? 'manifest_max_age_minutes' then
        errs := errs || text 'Set how long a downloaded manifest may be used (Q198): there is no default.';
      end if;
    end if;
  else
    errs := errs || text 'Unknown kind of configuration.';
  end if;
  return errs;
end $$;

-- ---------------------------------------------------------------------------
-- Manifests: what the live record said, for one gate point, at one moment (Q198)
-- ---------------------------------------------------------------------------
create table core.gate_manifest (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  venue_id              uuid not null,
  gate_point_id         uuid not null references core.gate_point,
  made_at               timestamptz not null default clock_timestamp(),
  made_by_person_id     uuid not null,
  outage_config_id      uuid not null references core.venue_config_version,
  max_age_minutes       integer not null check (max_age_minutes between 1 and 1440),
  rule_version_id       uuid references core.entry_rule_version,
  decision_context_id   uuid not null references core.decision_context,
  row_version           integer not null default 1,
  created_at            timestamptz not null default now(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, made_by_person_id) references core.person (customer_id, id)
);
select core.attach_standard_triggers('core.gate_manifest', null);

create table core.gate_manifest_entry (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  venue_id              uuid not null,
  manifest_id           uuid not null references core.gate_manifest,
  person_id             uuid not null,
  pass_numbers          text[] not null default '{}',
  outcome               text not null check (outcome in ('admit', 'admit_with_escort', 'check', 'do_not_admit')),
  result                jsonb not null,
  work_flags            jsonb not null default '[]',
  row_version           integer not null default 1,
  created_at            timestamptz not null default now(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, person_id) references core.person (customer_id, id),
  unique (manifest_id, person_id)
);
select core.attach_standard_triggers('core.gate_manifest_entry', null);

-- ---------------------------------------------------------------------------
-- Manual fallback entries (Q200): what the operator did during an outage, uploaded on
-- reconnection with the device's time and the manifest relied on, then checked live.
-- ---------------------------------------------------------------------------
create table core.manual_fallback_entry (
  id                     uuid primary key default gen_random_uuid(),
  customer_id            uuid not null,
  venue_id               uuid not null,
  gate_point_id          uuid not null references core.gate_point,
  client_entry_id        uuid not null,
  manifest_id            uuid references core.gate_manifest,
  recorded_at            timestamptz not null,
  received_at            timestamptz not null default clock_timestamp(),
  manifest_age_minutes   integer,
  manifest_usable        boolean not null,
  person_id              uuid,
  pass_number            text,
  name_given             text not null check (length(btrim(name_given)) > 0),
  organisation_given     text,
  purpose                text not null check (length(btrim(purpose)) > 0),
  contacted              text not null check (length(btrim(contacted)) > 0),
  direction              text not null check (direction in ('in', 'out')),
  identity_method        text not null check (identity_method in ('photo_id', 'known_to_operator', 'not_checked')),
  decision               text not null check (decision in ('admitted', 'refused', 'referred')),
  notes                  text,
  live_result            jsonb,
  operator_person_id     uuid not null,
  decision_context_id    uuid not null references core.decision_context,
  row_version            integer not null default 1,
  created_at             timestamptz not null default now(),
  created_by_user_id     uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, person_id) references core.person (customer_id, id),
  foreign key (customer_id, operator_person_id) references core.person (customer_id, id),
  unique (customer_id, client_entry_id),
  check (decision <> 'admitted' or identity_method <> 'not_checked'),
  check ((manifest_id is null) = (manifest_age_minutes is null))
);
select core.attach_standard_triggers('core.manual_fallback_entry', null);

-- ---------------------------------------------------------------------------
-- Reconciliation exceptions (Q202, Q203): open until resolved with a note; resolved once.
-- ---------------------------------------------------------------------------
create table core.reconciliation_exception (
  id                           uuid primary key default gen_random_uuid(),
  customer_id                  uuid not null,
  venue_id                     uuid not null,
  fallback_entry_id            uuid not null references core.manual_fallback_entry,
  kind                         text not null check (kind in ('entry', 'work')),
  code                         text not null,
  permit_id                    uuid references core.permit,
  person_id                    uuid,
  words                        text not null,
  owner                        text not null,
  resolved_at                  timestamptz,
  resolved_by_person_id        uuid,
  resolution_note              text,
  resolve_decision_context_id  uuid references core.decision_context,
  row_version                  integer not null default 1,
  created_at                   timestamptz not null default clock_timestamp(),
  created_by_user_id           uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, resolved_by_person_id) references core.person (customer_id, id),
  check ((kind = 'work') = (permit_id is not null)),
  check ((resolved_at is null) = (resolved_by_person_id is null) and (resolved_at is null) = (resolution_note is null)
         and (resolved_at is null) = (resolve_decision_context_id is null)),
  check (resolution_note is null or length(btrim(resolution_note)) > 0)
);
select core.attach_standard_triggers('core.reconciliation_exception', 'resolved_at,resolved_by_person_id,resolution_note,resolve_decision_context_id');

create function core.exception_resolve_once() returns trigger
language plpgsql set search_path = '' as $$
begin
  if old.resolved_at is not null then
    raise exception 'a reconciliation exception is resolved once' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger exception_resolve_once before update on core.reconciliation_exception for each row execute function core.exception_resolve_once();

-- ---------------------------------------------------------------------------
-- Who sees offline records: the venue's administrators and its gate staff, never other
-- contractors or another tenant.
-- ---------------------------------------------------------------------------
create function authz.gate_staff_venue_ids() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select v.id from core.venue v where v.customer_id in (select authz.my_admin_customer_ids())
  union select authz.my_action_venue_ids('gate.operate') union select authz.my_action_venue_ids('gate.override')
  union select authz.my_action_venue_ids('gate.download_manifest') union select authz.my_action_venue_ids('gate.submit_fallback')
  union select authz.my_action_venue_ids('gate.reconcile') union select authz.my_action_venue_ids('gate.reconcile_work') $$;
grant execute on function authz.gate_staff_venue_ids() to authenticated;

alter table core.gate_manifest enable row level security;
alter table core.gate_manifest_entry enable row level security;
alter table core.manual_fallback_entry enable row level security;
alter table core.reconciliation_exception enable row level security;
grant select on core.gate_manifest, core.gate_manifest_entry, core.manual_fallback_entry, core.reconciliation_exception to authenticated;
create policy manifest_read on core.gate_manifest for select to authenticated using (venue_id in (select authz.gate_staff_venue_ids()));
create policy manifest_entry_read on core.gate_manifest_entry for select to authenticated using (venue_id in (select authz.gate_staff_venue_ids()));
create policy fallback_read on core.manual_fallback_entry for select to authenticated using (venue_id in (select authz.gate_staff_venue_ids()));
create policy exception_read on core.reconciliation_exception for select to authenticated using (venue_id in (select authz.gate_staff_venue_ids()));
