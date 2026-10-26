-- 0047 Access visits (phase 7b, D-020): catalogue, venue configuration, visits, rosters,
--      occupier consent, attendance and linked work requests
--
-- A separate, lighter workflow than a permit (Q120, P7-7): an organisation asks for a visit
-- or a series for a named roster, a purpose, places and dates; an appointed access authority
-- approves it, with conditions. A visit is a reason to enter, never permission to work, and
-- never becomes a permit (Q122): a work request can only be linked to it.
--
-- Purposes, what each allows and prohibits, and what each needs, are venue configuration
-- with no default, approved by an appointed authority (Q121, Q162). The same versioned
-- configuration document will carry the outage procedure (7d).
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

insert into core.authority_action (code, basis, delegable, description) values
  ('venue_config.draft',              'tenant_admin',       false, 'Start a draft of a venue configuration document'),
  ('venue_config.save_draft',         'tenant_admin',       false, 'Edit a draft venue configuration document'),
  ('venue_config.propose',            'tenant_admin',       false, 'Propose a venue configuration document for approval'),
  ('venue_config.approve',            'appointment',        false, 'Approve a venue configuration document (Q121, Q162)'),
  ('venue_config.reject',             'appointment',        false, 'Reject a proposed venue configuration document'),
  ('venue_config.supersede',          'derived',            false, 'Mark the previous venue configuration superseded'),
  ('access.request',                  'organisation_admin', false, 'Ask for an access visit (Q125)'),
  ('access.request_for_venue',        'tenant_admin',       false, 'Ask for an access visit, for the venue'),
  ('access.approve',                  'appointment',        true,  'Approve or refuse an access visit or a roster addition (Q123)'),
  ('access.consent_occupier',         'appointment',        true,  'Give or refuse an occupier''s consent to a visit to its area'),
  ('access.change_roster',            'organisation_admin', false, 'Add or remove people on an access visit'),
  ('access.change_roster_for_venue',  'tenant_admin',       false, 'Add or remove people on an access visit, for the venue'),
  ('access.cancel',                   'organisation_admin', false, 'Withdraw or cancel an access visit'),
  ('access.cancel_for_venue',         'tenant_admin',       false, 'Cancel an access visit, for the venue'),
  ('access.cancel_as_authority',      'appointment',        true,  'Cancel an access visit, as an access authority'),
  ('access.link_work_request',        'organisation_admin', false, 'Link a work request raised from an access visit (Q122)');

insert into core.derived_action (parent_action, child_action) values ('venue_config.approve', 'venue_config.supersede');

insert into core.state_machine (code, table_name) values
  ('venue_config_version', 'core.venue_config_version'),
  ('access_authorisation', 'core.access_authorisation');
insert into core.state_initial (machine, state, required_action) values
  ('venue_config_version', 'draft', 'venue_config.draft'),
  ('access_authorisation', 'requested', 'access.request'),
  ('access_authorisation', 'requested', 'access.request_for_venue');
insert into core.state_transition (machine, from_state, to_state, required_action) values
  ('venue_config_version', 'draft', 'proposed', 'venue_config.propose'),
  ('venue_config_version', 'proposed', 'approved', 'venue_config.approve'),
  ('venue_config_version', 'proposed', 'rejected', 'venue_config.reject'),
  ('venue_config_version', 'approved', 'superseded', 'venue_config.supersede'),
  ('access_authorisation', 'requested', 'approved', 'access.approve'),
  ('access_authorisation', 'requested', 'refused', 'access.approve'),
  ('access_authorisation', 'requested', 'withdrawn', 'access.cancel'),
  ('access_authorisation', 'requested', 'withdrawn', 'access.cancel_for_venue'),
  ('access_authorisation', 'approved', 'cancelled', 'access.cancel'),
  ('access_authorisation', 'approved', 'cancelled', 'access.cancel_for_venue'),
  ('access_authorisation', 'approved', 'cancelled', 'access.cancel_as_authority');

-- ---------------------------------------------------------------------------
-- Venue configuration documents: versioned, drafted by the venue, approved by an appointee.
--   access_purposes: {purposes: [{key, name, allows, prohibits, induction_course_ids: [...],
--                                 escort: never | always, occupier_consent: boolean}]}
-- ---------------------------------------------------------------------------
create table core.venue_config_version (
  id                     uuid primary key default gen_random_uuid(),
  customer_id            uuid not null,
  venue_id               uuid not null,
  kind                   text not null check (kind in ('access_purposes')),
  version_no             integer not null check (version_no > 0),
  status                 text not null,
  content                jsonb not null,
  source_ref             text,
  authored_by_person_id  uuid not null,
  proposed_by_person_id  uuid,
  decided_by_person_id   uuid,
  decided_at             timestamptz,
  decision_reason        text,
  content_sha256         bytea,
  row_version            integer not null default 1,
  created_at             timestamptz not null default now(),
  created_by_user_id     uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, authored_by_person_id) references core.person (customer_id, id),
  foreign key (customer_id, proposed_by_person_id) references core.person (customer_id, id),
  foreign key (customer_id, decided_by_person_id) references core.person (customer_id, id),
  unique (venue_id, kind, version_no),
  check ((status = 'draft') = (content_sha256 is null))
);
create unique index venue_config_one_approved on core.venue_config_version (venue_id, kind) where status = 'approved';
select core.attach_standard_triggers('core.venue_config_version',
  'status,content,source_ref,proposed_by_person_id,decided_by_person_id,decided_at,decision_reason,content_sha256', null, true);
create trigger venue_config_freeze before update on core.venue_config_version for each row execute function core.entry_rule_freeze();

create function core.venue_config(p_venue_id uuid, p_kind text) returns core.venue_config_version
language sql stable security definer set search_path = '' as $$
  select * from core.venue_config_version where venue_id = p_venue_id and kind = p_kind and status = 'approved' $$;

create function core.validate_venue_config(p_venue_id uuid, p_kind text, c jsonb, p_strict boolean) returns text[]
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
  else
    errs := errs || text 'Unknown kind of configuration.';
  end if;
  return errs;
end $$;

-- ---------------------------------------------------------------------------
-- Visits (Q121-Q126)
-- ---------------------------------------------------------------------------
create table core.access_authorisation (
  id                      uuid primary key default gen_random_uuid(),
  customer_id             uuid not null,
  venue_id                uuid not null,
  reference               text not null,
  organisation_id         uuid not null,
  engagement_id           uuid not null references core.engagement,
  purpose_config_id       uuid not null references core.venue_config_version,
  purpose_key             text not null,
  description             text not null check (length(btrim(description)) > 0),
  area_ids                uuid[] not null check (cardinality(area_ids) > 0),
  valid_during            tstzrange not null check (not isempty(valid_during) and not lower_inf(valid_during) and not upper_inf(valid_during)),
  status                  text not null,
  requested_by_person_id  uuid not null,
  conditions              jsonb not null default '{}',
  decided_by_person_id    uuid,
  decision_reason         text,
  row_version             integer not null default 1,
  created_at              timestamptz not null default clock_timestamp(),
  created_by_user_id      uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, organisation_id) references core.organisation (customer_id, id),
  foreign key (customer_id, requested_by_person_id) references core.person (customer_id, id),
  foreign key (customer_id, decided_by_person_id) references core.person (customer_id, id),
  unique (venue_id, reference),
  unique (customer_id, venue_id, id)
);
select core.attach_standard_triggers('core.access_authorisation', 'status,conditions,decided_by_person_id,decision_reason', 'transition', true);

-- The roster: who may come. People added after approval need approval too (Q125).
create table core.access_roster_member (
  id                     uuid primary key default gen_random_uuid(),
  customer_id            uuid not null,
  venue_id               uuid not null,
  authorisation_id       uuid not null,
  person_id              uuid not null,
  added_by_person_id     uuid not null,
  added_after_approval   boolean not null default false,
  approved_at            timestamptz,
  approved_by_person_id  uuid,
  removed_at             timestamptz,
  removed_by_person_id   uuid,
  removal_reason         text,
  row_version            integer not null default 1,
  created_at             timestamptz not null default clock_timestamp(),
  created_by_user_id     uuid default auth.uid(),
  foreign key (customer_id, venue_id, authorisation_id) references core.access_authorisation (customer_id, venue_id, id),
  foreign key (customer_id, person_id) references core.person (customer_id, id),
  foreign key (customer_id, added_by_person_id) references core.person (customer_id, id),
  foreign key (customer_id, approved_by_person_id) references core.person (customer_id, id),
  foreign key (customer_id, removed_by_person_id) references core.person (customer_id, id),
  check ((approved_at is null) = (approved_by_person_id is null)),
  check ((removed_at is null) = (removed_by_person_id is null) and (removed_at is null) = (removal_reason is null))
);
create unique index access_roster_one_live on core.access_roster_member (authorisation_id, person_id) where removed_at is null;
select core.attach_standard_triggers('core.access_roster_member', 'approved_at,approved_by_person_id,removed_at,removed_by_person_id,removal_reason');
create function core.roster_set_once() returns trigger
language plpgsql set search_path = '' as $$
begin
  if (old.approved_at is not null and new.approved_at is distinct from old.approved_at)
     or (old.removed_at is not null and new.removed_at is distinct from old.removed_at) then
    raise exception 'a roster member''s approval and removal are recorded once' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger roster_set_once before update on core.access_roster_member for each row execute function core.roster_set_once();

-- Occupier consent, for purposes that need it, per occupied area (Q123).
create table core.access_consent (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  venue_id             uuid not null,
  authorisation_id     uuid not null,
  area_id              uuid not null references core.area,
  organisation_id      uuid not null,
  outcome              text not null check (outcome in ('given', 'refused')),
  reason               text not null check (length(btrim(reason)) > 0),
  decider_person_id    uuid not null,
  decision_context_id  uuid not null references core.decision_context,
  row_version          integer not null default 1,
  created_at           timestamptz not null default clock_timestamp(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, venue_id, authorisation_id) references core.access_authorisation (customer_id, venue_id, id),
  foreign key (customer_id, decider_person_id) references core.person (customer_id, id),
  unique (authorisation_id, area_id, organisation_id)
);
select core.attach_standard_triggers('core.access_consent', null);

-- Arrivals and departures against a visit, from the gate (Q126).
create table core.visit_attendance (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  venue_id             uuid not null,
  authorisation_id     uuid not null,
  person_id            uuid not null,
  arrived_at           timestamptz not null,
  arrival_scan_id      uuid not null references core.scan_event,
  left_at              timestamptz,
  departure_scan_id    uuid references core.scan_event,
  row_version          integer not null default 1,
  created_at           timestamptz not null default clock_timestamp(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, venue_id, authorisation_id) references core.access_authorisation (customer_id, venue_id, id),
  foreign key (customer_id, person_id) references core.person (customer_id, id),
  check ((left_at is null) = (departure_scan_id is null))
);
select core.attach_standard_triggers('core.visit_attendance', 'left_at,departure_scan_id');

-- A work request raised from a visit is linked to it; the visit itself never changes (Q122).
create table core.access_work_request (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  venue_id             uuid not null,
  authorisation_id     uuid not null,
  work_package_id      uuid not null unique,
  linked_by_person_id  uuid not null,
  decision_context_id  uuid not null references core.decision_context,
  row_version          integer not null default 1,
  created_at           timestamptz not null default clock_timestamp(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, venue_id, authorisation_id) references core.access_authorisation (customer_id, venue_id, id),
  foreign key (customer_id, venue_id, work_package_id) references core.work_package (customer_id, venue_id, id),
  foreign key (customer_id, linked_by_person_id) references core.person (customer_id, id)
);
select core.attach_standard_triggers('core.access_work_request', null);

-- The purpose a visit was approved under.
create function core.visit_purpose(a core.access_authorisation) returns jsonb
language sql stable security definer set search_path = '' as $$
  select x from core.venue_config_version c, jsonb_array_elements(c.content -> 'purposes') x
   where c.id = a.purpose_config_id and x ->> 'key' = a.purpose_key $$;

-- Occupier consents a visit still needs: occupied areas in the visit, occupied during it by
-- an organisation other than the visitor's, where the purpose needs consent.
create function core.consents_needed(p_authorisation_id uuid) returns table (area_id uuid, organisation_id uuid, given boolean, refused boolean)
language sql stable security definer set search_path = '' as $$
  select o.area_id, o.organisation_id,
         exists (select 1 from core.access_consent c where c.authorisation_id = a.id and c.area_id = o.area_id and c.organisation_id = o.organisation_id and c.outcome = 'given'),
         exists (select 1 from core.access_consent c where c.authorisation_id = a.id and c.area_id = o.area_id and c.organisation_id = o.organisation_id and c.outcome = 'refused')
    from core.access_authorisation a join core.area_occupation o on o.area_id = any (a.area_ids) and o.ended_at is null and o.valid_during && a.valid_during
   where a.id = p_authorisation_id and o.organisation_id <> a.organisation_id
     and coalesce((core.visit_purpose(a) ->> 'occupier_consent')::boolean, false) $$;

-- ---------------------------------------------------------------------------
-- Visibility and RLS: the requesting organisation, the venue, and each person on the roster.
-- ---------------------------------------------------------------------------
create function authz.visible_access_ids() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select a.id from core.access_authorisation a
   where a.customer_id in (select authz.my_admin_customer_ids()) or a.venue_id in (select authz.my_appointee_venue_ids())
      or a.organisation_id in (select authz.my_admin_organisation_ids())
      or exists (select 1 from core.access_roster_member m where m.authorisation_id = a.id and m.removed_at is null and m.person_id in (select authz.my_person_ids())) $$;
grant execute on function authz.visible_access_ids() to authenticated;

grant select on core.venue_config_version, core.access_authorisation, core.access_roster_member, core.access_consent, core.visit_attendance,
                core.access_work_request to authenticated;
create policy venue_scoped_read on core.venue_config_version for select to authenticated using (venue_id in (select authz.my_venue_ids()));
create policy access_read on core.access_authorisation for select to authenticated using (id in (select authz.visible_access_ids()));
create policy roster_read on core.access_roster_member for select to authenticated using (authorisation_id in (select authz.visible_access_ids()));
create policy consent_read on core.access_consent for select to authenticated using (authorisation_id in (select authz.visible_access_ids()));
create policy attendance_read on core.visit_attendance for select to authenticated using (authorisation_id in (select authz.visible_access_ids()));
create policy work_request_read on core.access_work_request for select to authenticated using (authorisation_id in (select authz.visible_access_ids()));
