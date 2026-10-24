-- 0014 Contractor administrators, relationship states, invitations, restrictions,
--      privacy notices and appointment type version approval (D-011, D-012)
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

-- ---------------------------------------------------------------------------
-- Contractor administrators (Q28, P2-3): one accountable, at most one deputy
-- ---------------------------------------------------------------------------
create table core.organisation_admin (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  organisation_id      uuid not null,
  person_id            uuid not null,
  role                 text not null check (role in ('accountable', 'deputy')),
  valid_during         tstzrange not null default tstzrange(now(), null),
  granted_by_person_id uuid,
  revoked_at           timestamptz,
  revoked_by_person_id uuid,
  row_version          integer not null default 1,
  created_at           timestamptz not null default now(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, organisation_id) references core.organisation (customer_id, id),
  foreign key (customer_id, person_id) references core.person (customer_id, id),
  foreign key (customer_id, granted_by_person_id) references core.person (customer_id, id),
  foreign key (customer_id, revoked_by_person_id) references core.person (customer_id, id)
);
create unique index organisation_admin_one_per_role
  on core.organisation_admin (organisation_id, role) where revoked_at is null;
create unique index organisation_admin_one_role_per_person
  on core.organisation_admin (organisation_id, person_id) where revoked_at is null;
select core.attach_standard_triggers('core.organisation_admin', 'revoked_at,revoked_by_person_id');

-- ---------------------------------------------------------------------------
-- Relationships gain a lifecycle (P2-8): active only once the person accepts
-- ---------------------------------------------------------------------------
alter table core.person_organisation_relationship rename column revoked_at to ended_at;
alter table core.person_organisation_relationship
  add column status             text not null default 'active',
  add column accepted_at        timestamptz,
  add column acceptance_method  text check (acceptance_method in ('self', 'facilitated')),
  add column acceptance_note    text,
  add column ended_by_person_id uuid,
  add column end_reason         text;
alter table core.person_organisation_relationship
  add foreign key (customer_id, ended_by_person_id) references core.person (customer_id, id);

drop trigger b_guard_update on core.person_organisation_relationship;
-- Rows recorded before this migration were active by definition; any already ended
-- are marked so. Guards are reattached below, after this one-off correction.
update core.person_organisation_relationship set status = 'ended' where ended_at is not null;
alter table core.person_organisation_relationship
  add check ((status = 'ended') = (ended_at is not null));
create trigger b_guard_update before update on core.person_organisation_relationship
  for each row execute function core.guard_update(
    'status,accepted_at,acceptance_method,acceptance_note,ended_at,ended_by_person_id,end_reason', 'transition');
create trigger d_guard_status before insert or update of status on core.person_organisation_relationship
  for each row execute function core.guard_status();
create trigger y_record_status after insert or update of status on core.person_organisation_relationship
  for each row execute function core.record_status();
alter table core.person_organisation_relationship alter column status drop default;

-- ---------------------------------------------------------------------------
-- Privacy notices (Q219). Wording comes from the privacy adviser (G11); the
-- product records which version a person was shown at collection.
-- ---------------------------------------------------------------------------
create table core.privacy_notice_version (
  id                 uuid primary key default gen_random_uuid(),
  customer_id        uuid not null references core.customer,
  version_no         integer not null check (version_no > 0),
  title              text not null check (length(btrim(title)) > 0),
  content_ref        text not null check (length(btrim(content_ref)) > 0),
  owner_person_id    uuid not null,
  effective_from     timestamptz not null,
  change_reason      text not null check (length(btrim(change_reason)) > 0),
  row_version        integer not null default 1,
  created_at         timestamptz not null default now(),
  created_by_user_id uuid default auth.uid(),
  foreign key (customer_id, owner_person_id) references core.person (customer_id, id),
  unique (customer_id, version_no),
  unique (customer_id, id)
);
select core.attach_standard_triggers('core.privacy_notice_version', null);

create table core.privacy_notice_shown (
  id                        uuid primary key default gen_random_uuid(),
  customer_id               uuid not null,
  privacy_notice_version_id uuid not null,
  auth_user_id              uuid not null references auth.users (id),
  person_id                 uuid,
  context                   text not null check (context in ('invitation_acceptance')),
  invitation_id             uuid,
  shown_at                  timestamptz not null default now(),
  row_version               integer not null default 1,
  created_at                timestamptz not null default now(),
  created_by_user_id        uuid default auth.uid(),
  foreign key (customer_id, privacy_notice_version_id) references core.privacy_notice_version (customer_id, id),
  foreign key (customer_id, person_id) references core.person (customer_id, id)
);
select core.attach_standard_triggers('core.privacy_notice_shown', null);

-- ---------------------------------------------------------------------------
-- Invitations (Q26, Q27, Q32)
-- ---------------------------------------------------------------------------
create table core.invitation (
  id                        uuid primary key default gen_random_uuid(),
  customer_id               uuid not null references core.customer,
  kind                      text not null check (kind in ('organisation', 'person')),
  -- organisation invitations
  venue_id                  uuid,
  capacity_code             text references core.engagement_capacity,
  engagement_valid_from     timestamptz,
  engagement_valid_to       timestamptz,
  -- person invitations
  organisation_id           uuid,
  relationship_kind         text check (relationship_kind in
                              ('employee', 'agency', 'self_employed', 'volunteer', 'subcontractor', 'exhibitor')),
  invitee_given_name        text not null check (length(btrim(invitee_given_name)) > 0),
  invitee_family_name       text not null check (length(btrim(invitee_family_name)) > 0),
  invitee_email             text not null check (invitee_email = lower(btrim(invitee_email)) and invitee_email like '%_@_%'),
  owner_person_id           uuid not null,
  invited_by_person_id      uuid,
  expires_at                timestamptz not null,
  token_hash                bytea not null unique check (length(token_hash) = 32),
  status                    text not null,
  delivery_failed_at        timestamptz,
  delivery_failure_detail   text,
  accepted_by_user_id       uuid references auth.users (id),
  accepted_at               timestamptz,
  acceptance_details        jsonb,
  match_organisation_id     uuid,
  resolution                text check (resolution in ('linked', 'separate')),
  privacy_notice_version_id uuid,
  result_organisation_id    uuid,
  result_person_id          uuid,
  result_engagement_id      uuid,
  row_version               integer not null default 1,
  created_at                timestamptz not null default now(),
  created_by_user_id        uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, organisation_id) references core.organisation (customer_id, id),
  foreign key (customer_id, owner_person_id) references core.person (customer_id, id),
  foreign key (customer_id, invited_by_person_id) references core.person (customer_id, id),
  foreign key (customer_id, match_organisation_id) references core.organisation (customer_id, id),
  foreign key (customer_id, result_organisation_id) references core.organisation (customer_id, id),
  foreign key (customer_id, result_person_id) references core.person (customer_id, id),
  foreign key (customer_id, privacy_notice_version_id) references core.privacy_notice_version (customer_id, id),
  check (expires_at > created_at),
  check (kind <> 'organisation' or (venue_id is not null and capacity_code is not null
                                    and engagement_valid_from is not null and organisation_id is null)),
  check (kind <> 'person' or (organisation_id is not null and relationship_kind is not null and venue_id is null)),
  check (engagement_valid_to is null or engagement_valid_to > engagement_valid_from)
);
create index invitation_email_idx on core.invitation (invitee_email);
select core.attach_standard_triggers('core.invitation',
  'status,delivery_failed_at,delivery_failure_detail,accepted_by_user_id,accepted_at,acceptance_details,'
  || 'match_organisation_id,resolution,privacy_notice_version_id,result_organisation_id,result_person_id,result_engagement_id',
  null, true);

-- ---------------------------------------------------------------------------
-- Restrictions on people and organisations at a venue (Q18, D-010, P2-7)
-- ---------------------------------------------------------------------------
create table core.restriction (
  id                             uuid primary key default gen_random_uuid(),
  customer_id                    uuid not null,
  venue_id                       uuid not null,
  subject_kind                   text not null check (subject_kind in ('person', 'organisation')),
  person_id                      uuid,
  organisation_id                uuid,
  reason                         text not null check (length(btrim(reason)) > 0),
  status                         text not null,
  imposed_by_decision_context_id uuid not null references core.decision_context,
  lifted_at                      timestamptz,
  lift_reason                    text,
  row_version                    integer not null default 1,
  created_at                     timestamptz not null default now(),
  created_by_user_id             uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, person_id) references core.person (customer_id, id),
  foreign key (customer_id, organisation_id) references core.organisation (customer_id, id),
  check ((subject_kind = 'person') = (person_id is not null)),
  check ((subject_kind = 'organisation') = (organisation_id is not null)),
  check ((status = 'lifted') = (lifted_at is not null))
);
create index restriction_active_idx on core.restriction (venue_id, person_id, organisation_id) where status = 'active';
select core.attach_standard_triggers('core.restriction', 'status,lifted_at,lift_reason', 'transition', true);

-- ---------------------------------------------------------------------------
-- Appointment type versions need root-appointee approval (D-011)
-- ---------------------------------------------------------------------------
alter table core.appointment_type_version
  add column status                text not null default 'approved',
  add column proposed_by_person_id uuid,
  add column decided_by_person_id  uuid,
  add column decided_at            timestamptz,
  add column decision_reason       text;
alter table core.appointment_type_version
  add foreign key (customer_id, proposed_by_person_id) references core.person (customer_id, id),
  add foreign key (customer_id, decided_by_person_id) references core.person (customer_id, id);
alter table core.appointment_type_version alter column status drop default;
drop trigger b_forbid_update on core.appointment_type_version;
create trigger b_guard_update before update on core.appointment_type_version
  for each row execute function core.guard_update('status,decided_by_person_id,decided_at,decision_reason', 'transition');
create trigger c_bump_version before update on core.appointment_type_version
  for each row execute function core.bump_version();
create trigger d_guard_status before insert or update of status on core.appointment_type_version
  for each row execute function core.guard_status();
create trigger y_record_status after insert or update of status on core.appointment_type_version
  for each row execute function core.record_status();
