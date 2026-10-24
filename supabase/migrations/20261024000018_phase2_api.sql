-- 0018 Phase 2 client surface (D-012)
--
-- Same pattern as 0012: build the target, authz.require, then write; status only
-- via core.transition; child records of a multi-record decision via authz.derive.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------
create view api.organisation_admin          with (security_invoker = true) as select * from core.organisation_admin;
create view api.invitation                  with (security_invoker = true) as
  select id, customer_id, kind, venue_id, capacity_code, engagement_valid_from, engagement_valid_to, organisation_id,
         relationship_kind, invitee_given_name, invitee_family_name, invitee_email, owner_person_id,
         invited_by_person_id, expires_at, status, delivery_failed_at, delivery_failure_detail, accepted_by_user_id,
         accepted_at, match_organisation_id, resolution, result_organisation_id, result_person_id,
         result_engagement_id, row_version, created_at
    from core.invitation;   -- the token hash is never exposed
create view api.restriction                 with (security_invoker = true) as select * from core.restriction;
create view api.privacy_notice_version      with (security_invoker = true) as select * from core.privacy_notice_version;
create view api.document_type               with (security_invoker = true) as select * from core.document_type;
create view api.review_criteria_version     with (security_invoker = true) as select * from core.review_criteria_version;
create view api.document                    with (security_invoker = true) as select * from core.document;
create view api.document_version            with (security_invoker = true) as
  select id, customer_id, document_id, version_no, encode(sha256, 'hex') as sha256, media_type, size_bytes, issuer,
         reference, valid_from, expires_on, uploaded_by_person_id, scan_status, scanned_at, row_version, created_at
    from core.document_version;   -- the storage path is released only by api.document_access
create view api.review_decision             with (security_invoker = true) as select * from core.review_decision;
create view api.competency_type             with (security_invoker = true) as select * from core.competency_type;
create view api.competency                  with (security_invoker = true) as select * from core.competency;
create view api.competency_verification     with (security_invoker = true) as select * from core.competency_verification;
create view api.evidence_requirement        with (security_invoker = true) as select * from core.evidence_requirement;
create view api.evidence_requirement_version with (security_invoker = true) as select * from core.evidence_requirement_version;

-- The phase 1 relationship view predates the renamed and new columns.
drop view api.person_organisation_relationship;
create view api.person_organisation_relationship with (security_invoker = true) as
  select * from core.person_organisation_relationship;

grant select on all tables in schema api to authenticated;

-- Defence in depth: the client role cannot read storage paths or token hashes even
-- through the underlying tables.
revoke select on core.document_version from authenticated;
grant select (id, customer_id, document_id, version_no, sha256, media_type, size_bytes, issuer, reference,
              valid_from, expires_on, uploaded_by_person_id, scan_status, scanned_at, scan_engine, scan_detail,
              row_version, created_at, created_by_user_id)
  on core.document_version to authenticated;
revoke select on core.invitation from authenticated;
grant select (id, customer_id, kind, venue_id, capacity_code, engagement_valid_from, engagement_valid_to,
              organisation_id, relationship_kind, invitee_given_name, invitee_family_name, invitee_email,
              owner_person_id, invited_by_person_id, expires_at, status, delivery_failed_at,
              delivery_failure_detail, accepted_by_user_id, accepted_at, acceptance_details, match_organisation_id,
              resolution, privacy_notice_version_id, result_organisation_id, result_person_id,
              result_engagement_id, row_version, created_at, created_by_user_id)
  on core.invitation to authenticated;

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

create function core.token_hash(p_token text) returns bytea
language sql immutable
set search_path = ''
as $$ select sha256(convert_to(p_token, 'UTF8')) $$;

-- People currently working with an organisation: excluded from deciding about it.
create function core.organisation_people(p_organisation_id uuid) returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(r.person_id), '[]')
    from core.person_organisation_relationship r
   where r.organisation_id = p_organisation_id and r.status = 'active' and now() <@ r.valid_during
$$;

-- The current privacy notice for a customer.
create function core.current_privacy_notice(p_customer_id uuid) returns uuid
language sql stable security definer
set search_path = ''
as $$
  select id from core.privacy_notice_version
   where customer_id = p_customer_id and effective_from <= now()
   order by effective_from desc limit 1
$$;

-- Finds the acceptor's person in the customer, or creates one with a login.
create function core.person_for_login(p_customer_id uuid, p_auth_user_id uuid, p_given text, p_family text,
                                      p_email text) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_person uuid;
begin
  select ua.person_id into v_person from core.user_account ua
   where ua.auth_user_id = p_auth_user_id and ua.customer_id = p_customer_id and ua.disabled_at is null;
  if v_person is null then
    v_person := gen_random_uuid();
    insert into core.person (id, customer_id, given_name, family_name) values (v_person, p_customer_id, p_given, p_family);
    insert into core.person_contact (customer_id, person_id, email) values (p_customer_id, v_person, p_email);
    insert into core.user_account (customer_id, person_id, auth_user_id) values (p_customer_id, v_person, p_auth_user_id);
  end if;
  return v_person;
end $$;

-- Completes an organisation invitation: organisation (new or linked), acceptor's
-- person and relationship, accountable administrator, proposed engagement.
create function core.complete_organisation_invitation(p_invitation_id uuid, p_link_organisation_id uuid,
                                                      p_parent_ctx uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  i        core.invitation;
  d        jsonb;
  v_org    uuid := p_link_organisation_id;
  v_person uuid;
  v_rel    uuid := gen_random_uuid();
  v_eng    uuid := gen_random_uuid();
begin
  select * into i from core.invitation where id = p_invitation_id;
  d := i.acceptance_details;
  if v_org is null then
    v_org := gen_random_uuid();
    insert into core.organisation (id, customer_id, legal_name, trading_name, company_number)
    values (v_org, i.customer_id, d ->> 'legal_name', d ->> 'trading_name', d ->> 'company_number');
  end if;
  v_person := core.person_for_login(i.customer_id, i.accepted_by_user_id,
                                    coalesce(d ->> 'given_name', i.invitee_given_name),
                                    coalesce(d ->> 'family_name', i.invitee_family_name), i.invitee_email);

  perform authz.derive('relationship.create_via_invitation', 'person_organisation_relationship', v_rel);
  insert into core.person_organisation_relationship (id, customer_id, person_id, organisation_id, kind, valid_during,
                                                     status, accepted_at, acceptance_method)
  values (v_rel, i.customer_id, v_person, v_org, coalesce(d ->> 'relationship_kind', 'employee'),
          tstzrange(now(), null), 'active', i.accepted_at, 'self');
  perform authz.resume(p_parent_ctx);

  if not exists (select 1 from core.organisation_admin
                  where organisation_id = v_org and role = 'accountable' and revoked_at is null) then
    insert into core.organisation_admin (customer_id, organisation_id, person_id, role, granted_by_person_id)
    values (i.customer_id, v_org, v_person, 'accountable', null);
  end if;

  perform authz.derive('engagement.create_via_invitation', 'engagement', v_eng);
  insert into core.engagement (id, customer_id, venue_id, organisation_id, capacity_code, valid_during, status)
  values (v_eng, i.customer_id, i.venue_id, v_org, i.capacity_code,
          tstzrange(i.engagement_valid_from, i.engagement_valid_to), 'proposed');
  perform authz.resume(p_parent_ctx);

  return jsonb_build_object('organisation_id', v_org, 'person_id', v_person, 'engagement_id', v_eng,
                            'relationship_id', v_rel);
end $$;

-- ---------------------------------------------------------------------------
-- Replaced phase 1 functions
-- ---------------------------------------------------------------------------

-- P2-2: engagements start proposed.
create or replace function api.create_engagement(
  p_idempotency_key text, p_venue_id uuid, p_organisation_id uuid, p_capacity_code text,
  p_valid_from timestamptz, p_valid_to timestamptz default null,
  p_engaged_via_organisation_id uuid default null, p_accountable_admin_person_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v_customer uuid := core.venue_customer(p_venue_id);
  v    jsonb;
begin
  v := authz.require('engagement.create',
         jsonb_build_object('customer_id', v_customer, 'venue_id', p_venue_id, 'record_id', v_id,
                            'target_type', 'engagement', 'organisation_id', p_organisation_id),
         p_idempotency_key,
         jsonb_build_object('venue_id', p_venue_id, 'organisation_id', p_organisation_id, 'capacity_code', p_capacity_code,
                            'valid_from', p_valid_from, 'valid_to', p_valid_to,
                            'engaged_via_organisation_id', p_engaged_via_organisation_id,
                            'accountable_admin_person_id', p_accountable_admin_person_id));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  insert into core.engagement (id, customer_id, venue_id, organisation_id, capacity_code, valid_during,
                               engaged_via_organisation_id, accountable_admin_person_id, status)
  values (v_id, v_customer, p_venue_id, p_organisation_id, p_capacity_code, tstzrange(p_valid_from, p_valid_to),
          p_engaged_via_organisation_id, p_accountable_admin_person_id, 'proposed');
  return v;
end $$;

-- P2-8: a relationship recorded by an administrator waits for the person's acceptance.
create or replace function api.record_person_organisation(
  p_idempotency_key text, p_person_id uuid, p_organisation_id uuid, p_kind text,
  p_valid_from timestamptz, p_valid_to timestamptz default null,
  p_supervisor_person_id uuid default null, p_evidence_responsible_organisation_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v_customer uuid := (select customer_id from core.person where id = p_person_id);
  v    jsonb;
begin
  v := authz.require('person_organisation.record',
         jsonb_build_object('customer_id', v_customer, 'record_id', v_id, 'target_type', 'person_organisation_relationship'),
         p_idempotency_key,
         jsonb_build_object('person_id', p_person_id, 'organisation_id', p_organisation_id, 'kind', p_kind,
                            'valid_from', p_valid_from, 'valid_to', p_valid_to,
                            'supervisor_person_id', p_supervisor_person_id,
                            'evidence_responsible_organisation_id', p_evidence_responsible_organisation_id));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  insert into core.person_organisation_relationship (id, customer_id, person_id, organisation_id, kind, valid_during,
                                                     supervisor_person_id, evidence_responsible_organisation_id, status)
  values (v_id, v_customer, p_person_id, p_organisation_id, p_kind, tstzrange(p_valid_from, p_valid_to),
          p_supervisor_person_id, p_evidence_responsible_organisation_id, 'invited');
  return v;
end $$;

create or replace function api.reinstate_engagement(
  p_idempotency_key text, p_engagement_id uuid, p_expected_version integer, p_reason text,
  p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_e     core.engagement;
  v_owner uuid;
  v       jsonb;
begin
  select * into v_e from core.engagement where id = p_engagement_id;
  select coalesce(dc.acting_appointment_id, d.delegator_appointment_id) into v_owner
    from core.decision_context dc
    left join core.delegation d on d.id = dc.acting_delegation_id
   where dc.id = v_e.suspended_by_decision_context_id;

  v := authz.require('engagement.reinstate',
         jsonb_build_object(
           'customer_id', v_e.customer_id, 'venue_id', v_e.venue_id,
           'record_id', p_engagement_id, 'target_type', 'engagement',
           'owner_appointment_id', v_owner,
           'excluded_person_ids', core.organisation_people(v_e.organisation_id)),
         p_idempotency_key,
         jsonb_build_object('engagement_id', p_engagement_id, 'expected_version', p_expected_version, 'reason', p_reason),
         p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  if v_e.status <> 'suspended' then
    raise exception 'this engagement is not suspended' using errcode = 'PT409';
  end if;
  if length(btrim(coalesce(p_reason, ''))) = 0 then
    raise exception 'a reason is required to reinstate an engagement' using errcode = '22023';
  end if;
  perform core.transition('core.engagement', p_engagement_id, 'active', p_expected_version,
                          (v ->> 'decision_context_id')::uuid,
                          jsonb_build_object('suspended_by_decision_context_id', null, 'suspension_reason', null));
  perform audit.record('engagement.reinstated', v_e.customer_id, v_e.venue_id, 'core.engagement',
                       p_engagement_id, p_reason, null);
  return v;
end $$;

-- Evidence for appointments is the appointee's (Q39): pass them to authz.
create or replace function api.grant_appointment(
  p_idempotency_key text, p_venue_id uuid, p_appointee_person_id uuid, p_type_version_id uuid,
  p_permit_class_ids uuid[], p_scopes jsonb, p_valid_from timestamptz, p_valid_to timestamptz,
  p_review_due_on date default null, p_limitations_text text default null,
  p_competence_evidence_ref text default null, p_acting_appointment_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v_customer uuid := core.venue_customer(p_venue_id);
  v    jsonb;
begin
  v := authz.require('appointment.grant',
         jsonb_build_object(
           'customer_id', v_customer, 'venue_id', p_venue_id, 'record_id', v_id, 'target_type', 'appointment',
           'excluded_person_ids', jsonb_build_array(p_appointee_person_id),
           'spec', jsonb_build_object('type_version_id', p_type_version_id,
                                      'appointee_person_id', p_appointee_person_id,
                                      'permit_class_ids', to_jsonb(coalesce(p_permit_class_ids, '{}')),
                                      'scopes', p_scopes, 'valid_from', p_valid_from, 'valid_to', p_valid_to)),
         p_idempotency_key,
         jsonb_build_object('venue_id', p_venue_id, 'appointee_person_id', p_appointee_person_id,
                            'type_version_id', p_type_version_id, 'permit_class_ids', p_permit_class_ids,
                            'scopes', p_scopes, 'valid_from', p_valid_from, 'valid_to', p_valid_to,
                            'review_due_on', p_review_due_on, 'limitations_text', p_limitations_text,
                            'competence_evidence_ref', p_competence_evidence_ref),
         p_acting_appointment_id, null);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  perform core.insert_appointment(v_id, v_customer, p_venue_id, p_appointee_person_id, p_type_version_id,
    (v ->> 'actor_person_id')::uuid, (v ->> 'acting_appointment_id')::uuid, false, p_permit_class_ids, p_scopes,
    p_valid_from, p_valid_to, p_review_due_on, p_limitations_text, 'pending_acknowledgement', null, null,
    p_competence_evidence_ref);
  return v;
end $$;

-- Bootstrap publication only (D-011): approved immediately, refused once the venue
-- has a root appointment.
create or replace function api.publish_appointment_type_version(
  p_idempotency_key              text,
  p_appointment_type_id          uuid,
  p_allowed_action_codes         text[],
  p_eligible_permit_class_ids    uuid[],
  p_eligible_system_type_ids     uuid[],
  p_grantable_type_ids           uuid[],
  p_is_root_eligible             boolean,
  p_requires_competence_evidence boolean,
  p_owner_person_id              uuid,
  p_effective_from               timestamptz,
  p_change_reason                text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
begin
  return core.insert_appointment_type_version('appointment_type.publish', 'approved', p_idempotency_key,
    p_appointment_type_id, p_allowed_action_codes, p_eligible_permit_class_ids, p_eligible_system_type_ids,
    p_grantable_type_ids, p_is_root_eligible, p_requires_competence_evidence, p_owner_person_id,
    p_effective_from, p_change_reason);
end $$;

create function api.propose_appointment_type_version(
  p_idempotency_key              text,
  p_appointment_type_id          uuid,
  p_allowed_action_codes         text[],
  p_eligible_permit_class_ids    uuid[],
  p_eligible_system_type_ids     uuid[],
  p_grantable_type_ids           uuid[],
  p_is_root_eligible             boolean,
  p_requires_competence_evidence boolean,
  p_owner_person_id              uuid,
  p_effective_from               timestamptz,
  p_change_reason                text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
begin
  return core.insert_appointment_type_version('appointment_type.propose', 'proposed', p_idempotency_key,
    p_appointment_type_id, p_allowed_action_codes, p_eligible_permit_class_ids, p_eligible_system_type_ids,
    p_grantable_type_ids, p_is_root_eligible, p_requires_competence_evidence, p_owner_person_id,
    p_effective_from, p_change_reason);
end $$;

create function core.insert_appointment_type_version(
  p_action text, p_status text, p_idempotency_key text, p_appointment_type_id uuid, p_allowed_action_codes text[],
  p_eligible_permit_class_ids uuid[], p_eligible_system_type_ids uuid[], p_grantable_type_ids uuid[],
  p_is_root_eligible boolean, p_requires_competence_evidence boolean, p_owner_person_id uuid,
  p_effective_from timestamptz, p_change_reason text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id   uuid := gen_random_uuid();
  v_type core.appointment_type;
  v      jsonb;
begin
  select * into v_type from core.appointment_type where id = p_appointment_type_id;
  v := authz.require(p_action,
         jsonb_build_object('customer_id', v_type.customer_id, 'venue_id', v_type.venue_id,
                            'record_id', v_id, 'target_type', 'appointment_type_version'),
         p_idempotency_key,
         jsonb_build_object('appointment_type_id', p_appointment_type_id, 'allowed_action_codes', p_allowed_action_codes,
                            'eligible_permit_class_ids', p_eligible_permit_class_ids,
                            'eligible_system_type_ids', p_eligible_system_type_ids,
                            'grantable_type_ids', p_grantable_type_ids, 'is_root_eligible', p_is_root_eligible,
                            'requires_competence_evidence', p_requires_competence_evidence,
                            'owner_person_id', p_owner_person_id, 'effective_from', p_effective_from,
                            'change_reason', p_change_reason));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  insert into core.appointment_type_version (
    id, customer_id, venue_id, appointment_type_id, version_no, allowed_action_codes, eligible_permit_class_ids,
    eligible_system_type_ids, grantable_type_ids, is_root_eligible, requires_competence_evidence,
    owner_person_id, effective_from, change_reason, status, proposed_by_person_id)
  values (
    v_id, v_type.customer_id, v_type.venue_id, p_appointment_type_id, 1, p_allowed_action_codes,
    coalesce(p_eligible_permit_class_ids, '{}'), coalesce(p_eligible_system_type_ids, '{}'),
    coalesce(p_grantable_type_ids, '{}'), p_is_root_eligible, p_requires_competence_evidence,
    p_owner_person_id, p_effective_from, p_change_reason, p_status, (v ->> 'actor_person_id')::uuid);
  return v;
end $$;

create function api.decide_appointment_type_version(
  p_idempotency_key text, p_version_id uuid, p_expected_version integer, p_decision text, p_reason text,
  p_acting_appointment_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  t core.appointment_type_version;
  v jsonb;
begin
  if p_decision not in ('approve', 'reject') then
    raise exception 'decision must be approve or reject' using errcode = '22023';
  end if;
  select * into t from core.appointment_type_version where id = p_version_id;
  v := authz.require('appointment_type.' || p_decision,
         jsonb_build_object('customer_id', t.customer_id, 'venue_id', t.venue_id, 'record_id', p_version_id,
                            'target_type', 'appointment_type_version',
                            'excluded_person_ids', jsonb_build_array(t.proposed_by_person_id)),
         p_idempotency_key,
         jsonb_build_object('version_id', p_version_id, 'expected_version', p_expected_version,
                            'decision', p_decision, 'reason', p_reason),
         p_acting_appointment_id, null);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  perform core.transition('core.appointment_type_version', p_version_id,
                          case p_decision when 'approve' then 'approved' else 'rejected' end, p_expected_version,
                          (v ->> 'decision_context_id')::uuid,
                          jsonb_build_object('decided_by_person_id', v ->> 'actor_person_id',
                                             'decided_at', now(), 'decision_reason', p_reason));
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Privacy notices (Q219)
-- ---------------------------------------------------------------------------

create function api.publish_privacy_notice(p_idempotency_key text, p_customer_id uuid, p_title text,
                                           p_content_ref text, p_owner_person_id uuid, p_effective_from timestamptz,
                                           p_change_reason text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v    jsonb;
begin
  v := authz.require('privacy_notice.publish',
         jsonb_build_object('customer_id', p_customer_id, 'record_id', v_id, 'target_type', 'privacy_notice_version'),
         p_idempotency_key,
         jsonb_build_object('customer_id', p_customer_id, 'title', p_title, 'content_ref', p_content_ref,
                            'owner_person_id', p_owner_person_id, 'effective_from', p_effective_from,
                            'change_reason', p_change_reason));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  insert into core.privacy_notice_version (id, customer_id, version_no, title, content_ref, owner_person_id,
                                           effective_from, change_reason)
  values (v_id, p_customer_id, 1, p_title, p_content_ref, p_owner_person_id, p_effective_from, p_change_reason);
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Invitations (Q26, Q27, Q32)
-- ---------------------------------------------------------------------------

-- Returns the token once. It is never stored; only its hash is.
create function api.create_organisation_invitation(
  p_idempotency_key text, p_venue_id uuid, p_capacity_code text, p_invitee_given_name text,
  p_invitee_family_name text, p_invitee_email text, p_owner_person_id uuid, p_expires_at timestamptz,
  p_engagement_valid_from timestamptz, p_engagement_valid_to timestamptz default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id       uuid := gen_random_uuid();
  v_token    text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  v_customer uuid := core.venue_customer(p_venue_id);
  v          jsonb;
begin
  v := authz.require('invitation.create_organisation',
         jsonb_build_object('customer_id', v_customer, 'venue_id', p_venue_id, 'record_id', v_id, 'target_type', 'invitation'),
         p_idempotency_key,
         jsonb_build_object('venue_id', p_venue_id, 'capacity_code', p_capacity_code,
                            'invitee_given_name', p_invitee_given_name, 'invitee_family_name', p_invitee_family_name,
                            'invitee_email', p_invitee_email, 'owner_person_id', p_owner_person_id,
                            'expires_at', p_expires_at, 'engagement_valid_from', p_engagement_valid_from,
                            'engagement_valid_to', p_engagement_valid_to));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  insert into core.invitation (id, customer_id, kind, venue_id, capacity_code, engagement_valid_from, engagement_valid_to,
                               invitee_given_name, invitee_family_name, invitee_email, owner_person_id,
                               invited_by_person_id, expires_at, token_hash, status)
  values (v_id, v_customer, 'organisation', p_venue_id, p_capacity_code, p_engagement_valid_from, p_engagement_valid_to,
          p_invitee_given_name, p_invitee_family_name, lower(btrim(p_invitee_email)), p_owner_person_id,
          (v ->> 'actor_person_id')::uuid, p_expires_at, core.token_hash(v_token), 'pending');
  return v || jsonb_build_object('token', v_token);
end $$;

create function api.create_person_invitation(
  p_idempotency_key text, p_organisation_id uuid, p_relationship_kind text, p_invitee_given_name text,
  p_invitee_family_name text, p_invitee_email text, p_expires_at timestamptz)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id       uuid := gen_random_uuid();
  v_token    text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  v_customer uuid := (select customer_id from core.organisation where id = p_organisation_id);
  v          jsonb;
begin
  v := authz.require('invitation.create_person',
         jsonb_build_object('customer_id', v_customer, 'organisation_id', p_organisation_id,
                            'record_id', v_id, 'target_type', 'invitation'),
         p_idempotency_key,
         jsonb_build_object('organisation_id', p_organisation_id, 'relationship_kind', p_relationship_kind,
                            'invitee_given_name', p_invitee_given_name, 'invitee_family_name', p_invitee_family_name,
                            'invitee_email', p_invitee_email, 'expires_at', p_expires_at));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  insert into core.invitation (id, customer_id, kind, organisation_id, relationship_kind, invitee_given_name,
                               invitee_family_name, invitee_email, owner_person_id, invited_by_person_id,
                               expires_at, token_hash, status)
  values (v_id, v_customer, 'person', p_organisation_id, p_relationship_kind, p_invitee_given_name,
          p_invitee_family_name, lower(btrim(p_invitee_email)), (v ->> 'actor_person_id')::uuid,
          (v ->> 'actor_person_id')::uuid, p_expires_at, core.token_hash(v_token), 'pending');
  return v || jsonb_build_object('token', v_token);
end $$;

-- What the invitee sees before accepting: only for the signed-in account the
-- invitation was sent to.
create function api.invitation_preview(p_token text) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  i core.invitation;
  n core.privacy_notice_version;
begin
  select * into i from core.invitation where token_hash = core.token_hash(p_token);
  if i.id is null or (select lower(email) from auth.users where id = auth.uid()) is distinct from i.invitee_email then
    return authz.deny('invitation.accept', 'not_found', 'The record does not exist or you do not have access to it.',
                      'A valid invitation link for your account', 'Whoever invited you');
  end if;
  select * into n from core.privacy_notice_version where id = core.current_privacy_notice(i.customer_id);
  return jsonb_build_object(
    'ok', true, 'invitation_id', i.id, 'kind', i.kind, 'status', i.status, 'expires_at', i.expires_at,
    'expired', now() >= i.expires_at,
    'venue_name', (select name from core.venue where id = i.venue_id),
    'organisation_name', (select legal_name from core.organisation where id = i.organisation_id),
    'capacity_code', i.capacity_code, 'relationship_kind', i.relationship_kind,
    'privacy_notice', case when n.id is null then null
                           else jsonb_build_object('id', n.id, 'title', n.title, 'content_ref', n.content_ref) end);
end $$;

create function api.accept_invitation(
  p_idempotency_key text, p_token text, p_privacy_notice_version_id uuid,
  p_legal_name text default null, p_trading_name text default null, p_company_number text default null,
  p_given_name text default null, p_family_name text default null, p_relationship_kind text default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  i        core.invitation;
  v        jsonb;
  v_ctx    uuid;
  v_match  uuid;
  v_result jsonb;
  v_person uuid;
  v_rel    uuid := gen_random_uuid();
  v_details jsonb;
begin
  select * into i from core.invitation where token_hash = core.token_hash(p_token);
  v := authz.require('invitation.accept',
         jsonb_build_object('customer_id', i.customer_id, 'venue_id', i.venue_id,
                            'record_id', coalesce(i.id, gen_random_uuid()), 'target_type', 'invitation',
                            'token_hash', encode(core.token_hash(p_token), 'hex')),
         p_idempotency_key,
         jsonb_build_object('token_hash', encode(core.token_hash(p_token), 'hex'),
                            'privacy_notice_version_id', p_privacy_notice_version_id,
                            'legal_name', p_legal_name, 'trading_name', p_trading_name,
                            'company_number', p_company_number, 'given_name', p_given_name,
                            'family_name', p_family_name, 'relationship_kind', p_relationship_kind));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  v_ctx := (v ->> 'decision_context_id')::uuid;

  -- Personal data is collected only against the privacy notice the person was shown (Q219).
  if p_privacy_notice_version_id is null
     or p_privacy_notice_version_id is distinct from core.current_privacy_notice(i.customer_id) then
    raise exception 'accepting requires the current privacy notice to have been shown' using errcode = '22023';
  end if;
  insert into core.privacy_notice_shown (customer_id, privacy_notice_version_id, auth_user_id, person_id, context, invitation_id)
  values (i.customer_id, p_privacy_notice_version_id, auth.uid(), (v ->> 'actor_person_id')::uuid,
          'invitation_acceptance', i.id);

  if i.kind = 'organisation' then
    if length(btrim(coalesce(p_legal_name, ''))) = 0 then
      raise exception 'the organisation''s legal or trading name is required' using errcode = '22023';
    end if;
    v_details := jsonb_build_object('legal_name', btrim(p_legal_name), 'trading_name', p_trading_name,
                                    'company_number', nullif(btrim(coalesce(p_company_number, '')), ''),
                                    'given_name', p_given_name, 'family_name', p_family_name,
                                    'relationship_kind', coalesce(p_relationship_kind, 'employee'));
    -- Q26: a matching registration number is never merged automatically.
    select id into v_match from core.organisation
     where customer_id = i.customer_id and company_number = v_details ->> 'company_number';
    if v_match is not null then
      perform core.transition('core.invitation', i.id, 'awaiting_match', i.row_version, v_ctx,
        jsonb_build_object('accepted_by_user_id', auth.uid(), 'accepted_at', now(), 'acceptance_details', v_details,
                           'match_organisation_id', v_match, 'privacy_notice_version_id', p_privacy_notice_version_id));
      return v || jsonb_build_object('status', 'awaiting_match');
    end if;
    -- The invitation carries the acceptance details for the completion step.
    perform core.transition('core.invitation', i.id, 'accepted', i.row_version, v_ctx,
      jsonb_build_object('accepted_by_user_id', auth.uid(), 'accepted_at', now(), 'acceptance_details', v_details,
                         'privacy_notice_version_id', p_privacy_notice_version_id));
    v_result := core.complete_organisation_invitation(i.id, null, v_ctx);
    update core.invitation
       set result_organisation_id = (v_result ->> 'organisation_id')::uuid,
           result_person_id = (v_result ->> 'person_id')::uuid,
           result_engagement_id = (v_result ->> 'engagement_id')::uuid
     where id = i.id;
    return v || v_result || jsonb_build_object('status', 'accepted');
  end if;

  -- Person invitation: the person's acceptance is what activates the relationship (P2-8).
  v_person := core.person_for_login(i.customer_id, auth.uid(), coalesce(p_given_name, i.invitee_given_name),
                                    coalesce(p_family_name, i.invitee_family_name), i.invitee_email);
  if exists (select 1 from core.person_organisation_relationship
              where person_id = v_person and organisation_id = i.organisation_id and status in ('active', 'invited')) then
    raise exception 'you already have a relationship with this organisation' using errcode = 'PT409';
  end if;
  perform core.transition('core.invitation', i.id, 'accepted', i.row_version, v_ctx,
    jsonb_build_object('accepted_by_user_id', auth.uid(), 'accepted_at', now(), 'result_person_id', v_person,
                       'privacy_notice_version_id', p_privacy_notice_version_id));
  perform authz.derive('relationship.create_via_invitation', 'person_organisation_relationship', v_rel);
  insert into core.person_organisation_relationship (id, customer_id, person_id, organisation_id, kind, valid_during,
                                                     status, accepted_at, acceptance_method)
  values (v_rel, i.customer_id, v_person, i.organisation_id, i.relationship_kind, tstzrange(now(), null),
          'active', now(), 'self');
  perform authz.resume(v_ctx);
  return v || jsonb_build_object('status', 'accepted', 'person_id', v_person, 'relationship_id', v_rel);
end $$;

create function api.decline_invitation(p_idempotency_key text, p_token text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  i core.invitation;
  v jsonb;
begin
  select * into i from core.invitation where token_hash = core.token_hash(p_token);
  v := authz.require('invitation.decline',
         jsonb_build_object('customer_id', i.customer_id, 'venue_id', i.venue_id,
                            'record_id', coalesce(i.id, gen_random_uuid()), 'target_type', 'invitation',
                            'token_hash', encode(core.token_hash(p_token), 'hex')),
         p_idempotency_key, jsonb_build_object('token_hash', encode(core.token_hash(p_token), 'hex')));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.invitation', i.id, 'declined', i.row_version, (v ->> 'decision_context_id')::uuid);
  return v;
end $$;

create function api.cancel_invitation(p_idempotency_key text, p_invitation_id uuid, p_expected_version integer)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  i core.invitation;
  v jsonb;
begin
  select * into i from core.invitation where id = p_invitation_id;
  v := authz.require(case i.kind when 'person' then 'invitation.cancel_person' else 'invitation.cancel_organisation' end,
         jsonb_build_object('customer_id', i.customer_id, 'venue_id', i.venue_id, 'organisation_id', i.organisation_id,
                            'record_id', p_invitation_id, 'target_type', 'invitation'),
         p_idempotency_key, jsonb_build_object('invitation_id', p_invitation_id, 'expected_version', p_expected_version));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.invitation', p_invitation_id, 'cancelled', p_expected_version,
                          (v ->> 'decision_context_id')::uuid);
  return v;
end $$;

-- Q26: a tenant administrator decides whether the accepting organisation is the
-- existing one. Linking never makes the acceptor accountable for an organisation
-- that already has an accountable administrator.
create function api.resolve_invitation_match(p_idempotency_key text, p_invitation_id uuid, p_expected_version integer,
                                             p_resolution text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  i        core.invitation;
  v        jsonb;
  v_ctx    uuid;
  v_result jsonb;
begin
  if p_resolution not in ('linked', 'separate') then
    raise exception 'resolution must be linked or separate' using errcode = '22023';
  end if;
  select * into i from core.invitation where id = p_invitation_id;
  v := authz.require('invitation.resolve_match',
         jsonb_build_object('customer_id', i.customer_id, 'venue_id', i.venue_id, 'record_id', p_invitation_id,
                            'target_type', 'invitation',
                            'organisation_id', case when p_resolution = 'linked' then i.match_organisation_id end),
         p_idempotency_key,
         jsonb_build_object('invitation_id', p_invitation_id, 'expected_version', p_expected_version,
                            'resolution', p_resolution));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  v_ctx := (v ->> 'decision_context_id')::uuid;

  perform core.transition('core.invitation', p_invitation_id, 'accepted', p_expected_version, v_ctx,
                          jsonb_build_object('resolution', p_resolution));
  if p_resolution = 'separate' then
    -- A separate organisation cannot reuse the registration number.
    update core.invitation
       set acceptance_details = acceptance_details - 'company_number'
     where id = p_invitation_id;
  end if;
  v_result := core.complete_organisation_invitation(p_invitation_id,
                case when p_resolution = 'linked' then i.match_organisation_id end, v_ctx);
  update core.invitation
     set result_organisation_id = (v_result ->> 'organisation_id')::uuid,
         result_person_id = (v_result ->> 'person_id')::uuid,
         result_engagement_id = (v_result ->> 'engagement_id')::uuid
   where id = p_invitation_id;
  return v || v_result;
end $$;

create function api.record_invitation_delivery_failure(p_idempotency_key text, p_invitation_id uuid, p_detail text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  i core.invitation;
  v jsonb;
begin
  select * into i from core.invitation where id = p_invitation_id;
  v := authz.require('invitation.record_delivery_failure',
         jsonb_build_object('customer_id', i.customer_id, 'record_id', p_invitation_id, 'target_type', 'invitation'),
         p_idempotency_key, jsonb_build_object('invitation_id', p_invitation_id, 'detail', p_detail));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  update core.invitation set delivery_failed_at = now(), delivery_failure_detail = p_detail where id = p_invitation_id;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Contractor administrators (Q28)
-- ---------------------------------------------------------------------------

create function core.admin_change_target(p_organisation_id uuid, p_person_id uuid, p_record_id uuid,
                                         p_require_accountable boolean)
returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select jsonb_build_object('customer_id', o.customer_id, 'organisation_id', o.id, 'person_id', p_person_id,
                            'record_id', p_record_id, 'target_type', 'organisation_admin',
                            'require_accountable', p_require_accountable)
    from core.organisation o where o.id = p_organisation_id
$$;

create function api.appoint_deputy_admin(p_idempotency_key text, p_organisation_id uuid, p_person_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v    jsonb;
begin
  v := authz.require('organisation_admin.appoint_deputy',
         core.admin_change_target(p_organisation_id, p_person_id, v_id, true) - 'person_id'
           || jsonb_build_object('person_id', p_person_id),
         p_idempotency_key, jsonb_build_object('organisation_id', p_organisation_id, 'person_id', p_person_id));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.organisation_admin (id, customer_id, organisation_id, person_id, role, granted_by_person_id)
  values (v_id, (select customer_id from core.organisation where id = p_organisation_id), p_organisation_id,
          p_person_id, 'deputy', (v ->> 'actor_person_id')::uuid);
  return v;
end $$;

create function api.revoke_deputy_admin(p_idempotency_key text, p_organisation_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  a core.organisation_admin;
  v jsonb;
begin
  select * into a from core.organisation_admin
   where organisation_id = p_organisation_id and role = 'deputy' and revoked_at is null;
  v := authz.require('organisation_admin.revoke_deputy',
         core.admin_change_target(p_organisation_id, null, coalesce(a.id, p_organisation_id), true) - 'person_id',
         p_idempotency_key, jsonb_build_object('organisation_id', p_organisation_id));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  if a.id is null then
    raise exception 'this organisation has no deputy administrator' using errcode = 'PT404';
  end if;
  update core.organisation_admin set revoked_at = now(), revoked_by_person_id = (v ->> 'actor_person_id')::uuid
   where id = a.id;
  return v;
end $$;

-- Hands the accountable role to someone actively working with the organisation.
create function core.replace_accountable_admin(p_organisation_id uuid, p_person_id uuid, p_actor uuid) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
begin
  update core.organisation_admin set revoked_at = now(), revoked_by_person_id = p_actor
   where organisation_id = p_organisation_id and revoked_at is null
     and (role = 'accountable' or person_id = p_person_id);
  insert into core.organisation_admin (id, customer_id, organisation_id, person_id, role, granted_by_person_id)
  values (v_id, (select customer_id from core.organisation where id = p_organisation_id), p_organisation_id,
          p_person_id, 'accountable', p_actor);
  return v_id;
end $$;

create function api.transfer_accountable_admin(p_idempotency_key text, p_organisation_id uuid, p_person_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v    jsonb;
begin
  v := authz.require('organisation_admin.transfer',
         core.admin_change_target(p_organisation_id, p_person_id, v_id, true),
         p_idempotency_key, jsonb_build_object('organisation_id', p_organisation_id, 'person_id', p_person_id));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.replace_accountable_admin(p_organisation_id, p_person_id, (v ->> 'actor_person_id')::uuid);
  return v;
end $$;

create function api.set_accountable_admin(p_idempotency_key text, p_organisation_id uuid, p_person_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v    jsonb;
begin
  v := authz.require('organisation_admin.set_accountable',
         core.admin_change_target(p_organisation_id, null, v_id, false) - 'person_id',
         p_idempotency_key, jsonb_build_object('organisation_id', p_organisation_id, 'person_id', p_person_id));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  if not exists (select 1 from core.person_organisation_relationship
                  where person_id = p_person_id and organisation_id = p_organisation_id and status = 'active') then
    raise exception 'the accountable administrator must work with the organisation' using errcode = '22023';
  end if;
  perform core.replace_accountable_admin(p_organisation_id, p_person_id, (v ->> 'actor_person_id')::uuid);
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Relationships (P2-8, Q40)
-- ---------------------------------------------------------------------------

create function core.relationship_decision(p_action text, p_idempotency_key text, p_relationship_id uuid,
                                           p_expected_version integer, p_to_state text, p_note text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  r core.person_organisation_relationship;
  v jsonb;
begin
  select * into r from core.person_organisation_relationship where id = p_relationship_id;
  v := authz.require(p_action,
         jsonb_build_object('customer_id', r.customer_id, 'organisation_id', r.organisation_id,
                            'subject_person_id', r.person_id, 'record_id', p_relationship_id,
                            'target_type', 'person_organisation_relationship'),
         p_idempotency_key,
         jsonb_build_object('relationship_id', p_relationship_id, 'expected_version', p_expected_version, 'note', p_note));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  perform core.transition('core.person_organisation_relationship', p_relationship_id, p_to_state, p_expected_version,
    (v ->> 'decision_context_id')::uuid,
    case p_to_state
      when 'active' then jsonb_build_object('accepted_at', now(),
                           'acceptance_method', case when p_action = 'relationship.confirm_facilitated' then 'facilitated' else 'self' end,
                           'acceptance_note', p_note)
      when 'ended'  then jsonb_build_object('ended_at', now(), 'ended_by_person_id', v ->> 'actor_person_id',
                                            'end_reason', p_note)
      else '{}'::jsonb end);
  -- Ending a relationship ends any administrator role it supported.
  if p_to_state = 'ended' then
    update core.organisation_admin set revoked_at = now(), revoked_by_person_id = (v ->> 'actor_person_id')::uuid
     where organisation_id = r.organisation_id and person_id = r.person_id and revoked_at is null;
  end if;
  return v;
end $$;

create function api.accept_relationship(p_idempotency_key text, p_relationship_id uuid, p_expected_version integer)
returns jsonb language sql security definer set search_path = '' as $$
  select core.relationship_decision('relationship.accept', p_idempotency_key, p_relationship_id, p_expected_version, 'active', null) $$;
create function api.decline_relationship(p_idempotency_key text, p_relationship_id uuid, p_expected_version integer)
returns jsonb language sql security definer set search_path = '' as $$
  select core.relationship_decision('relationship.decline', p_idempotency_key, p_relationship_id, p_expected_version, 'declined', null) $$;
create function api.confirm_relationship_facilitated(p_idempotency_key text, p_relationship_id uuid,
                                                     p_expected_version integer, p_note text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if length(btrim(coalesce(p_note, ''))) < 10 then
    raise exception 'record how the person''s acceptance was obtained' using errcode = '22023';
  end if;
  return core.relationship_decision('relationship.confirm_facilitated', p_idempotency_key, p_relationship_id,
                                    p_expected_version, 'active', p_note);
end $$;
create function api.end_relationship(p_idempotency_key text, p_relationship_id uuid, p_expected_version integer, p_reason text)
returns jsonb language sql security definer set search_path = '' as $$
  select core.relationship_decision('relationship.end', p_idempotency_key, p_relationship_id, p_expected_version, 'ended', p_reason) $$;
create function api.end_own_relationship(p_idempotency_key text, p_relationship_id uuid, p_expected_version integer, p_reason text)
returns jsonb language sql security definer set search_path = '' as $$
  select core.relationship_decision('relationship.end_own', p_idempotency_key, p_relationship_id, p_expected_version, 'ended', p_reason) $$;
create function api.end_relationship_by_admin(p_idempotency_key text, p_relationship_id uuid, p_expected_version integer, p_reason text)
returns jsonb language sql security definer set search_path = '' as $$
  select core.relationship_decision('relationship.end_by_admin', p_idempotency_key, p_relationship_id, p_expected_version, 'ended', p_reason) $$;

-- Q33: people maintain their own identity and contact details.
create function api.update_own_person(p_idempotency_key text, p_person_id uuid, p_expected_version integer,
                                      p_given_name text, p_family_name text, p_preferred_name text,
                                      p_preferred_language text, p_email text, p_phone text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  p core.person;
  v jsonb;
begin
  select * into p from core.person where id = p_person_id for update;
  v := authz.require('person.update_own',
         jsonb_build_object('customer_id', p.customer_id, 'subject_person_id', p_person_id,
                            'record_id', p_person_id, 'target_type', 'person'),
         p_idempotency_key,
         jsonb_build_object('person_id', p_person_id, 'expected_version', p_expected_version, 'given_name', p_given_name,
                            'family_name', p_family_name, 'preferred_name', p_preferred_name,
                            'preferred_language', p_preferred_language, 'email', p_email, 'phone', p_phone));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.check_version(p.row_version, p_expected_version);
  update core.person set given_name = p_given_name, family_name = p_family_name, preferred_name = p_preferred_name,
                         preferred_language = p_preferred_language
   where id = p_person_id;
  insert into core.person_contact (customer_id, person_id, email, phone)
  values (p.customer_id, p_person_id, p_email, p_phone)
  on conflict (person_id) do update set email = excluded.email, phone = excluded.phone;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Documents (Q36, Q37)
-- ---------------------------------------------------------------------------

create function api.create_document_type(p_idempotency_key text, p_venue_id uuid, p_code text, p_label text,
                                         p_owner_level text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v_customer uuid := core.venue_customer(p_venue_id);
  v    jsonb;
begin
  v := authz.require('document_type.create',
         jsonb_build_object('customer_id', v_customer, 'venue_id', p_venue_id, 'record_id', v_id, 'target_type', 'document_type'),
         p_idempotency_key,
         jsonb_build_object('venue_id', p_venue_id, 'code', p_code, 'label', p_label, 'owner_level', p_owner_level));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.document_type (id, customer_id, venue_id, code, label, owner_level)
  values (v_id, v_customer, p_venue_id, p_code, p_label, p_owner_level);
  return v;
end $$;

create function api.publish_review_criteria(p_idempotency_key text, p_document_type_id uuid, p_criteria jsonb,
                                            p_owner_person_id uuid, p_effective_from timestamptz, p_change_reason text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  t    core.document_type;
  v    jsonb;
begin
  select * into t from core.document_type where id = p_document_type_id;
  v := authz.require('review_criteria.publish',
         jsonb_build_object('customer_id', t.customer_id, 'venue_id', t.venue_id, 'record_id', v_id,
                            'target_type', 'review_criteria_version'),
         p_idempotency_key,
         jsonb_build_object('document_type_id', p_document_type_id, 'criteria', p_criteria,
                            'owner_person_id', p_owner_person_id, 'effective_from', p_effective_from,
                            'change_reason', p_change_reason));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  if exists (select 1 from jsonb_array_elements(p_criteria) c
              where jsonb_typeof(c -> 'code') <> 'string' or jsonb_typeof(c -> 'label') <> 'string') then
    raise exception 'each criterion needs a code and a label' using errcode = '22023';
  end if;
  insert into core.review_criteria_version (id, customer_id, venue_id, document_type_id, version_no, criteria,
                                            owner_person_id, effective_from, change_reason)
  values (v_id, t.customer_id, t.venue_id, p_document_type_id, 1, p_criteria, p_owner_person_id, p_effective_from,
          p_change_reason);
  return v;
end $$;

-- Registers a file the server has already validated and stored at
-- customer/document/version. A new document_id starts a document; an existing one
-- adds a version (CLAUDE.md §2 invariant 5: never overwrite).
create function api.submit_document(
  p_idempotency_key text, p_document_id uuid, p_version_id uuid, p_owner_kind text,
  p_organisation_id uuid, p_person_id uuid, p_document_type_id uuid, p_title text,
  p_sha256_hex text, p_media_type text, p_size_bytes bigint,
  p_issuer text default null, p_reference text default null, p_valid_from date default null,
  p_expires_on date default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  d          core.document;
  t          core.document_type;
  v_action   text;
  v_customer uuid;
  v_target   jsonb;
  v          jsonb;
begin
  select * into d from core.document where id = p_document_id;
  if d.id is not null then
    -- A new version keeps the document's owner and route.
    p_owner_kind := d.owner_kind; p_organisation_id := coalesce(d.organisation_id, d.provided_via_organisation_id);
    p_person_id := d.person_id; p_document_type_id := d.document_type_id;
  end if;
  select * into t from core.document_type where id = p_document_type_id;
  v_customer := t.customer_id;

  if p_owner_kind = 'organisation' then
    v_action := 'document.submit_org';
    v_target := jsonb_build_object('organisation_id', p_organisation_id);
  elsif p_organisation_id is null then
    v_action := 'document.submit_own';
    v_target := jsonb_build_object('subject_person_id', p_person_id);
  else
    v_action := 'document.submit_for_person';
    v_target := jsonb_build_object('organisation_id', p_organisation_id, 'person_id', p_person_id);
  end if;

  v := authz.require(v_action,
         v_target || jsonb_build_object('customer_id', v_customer, 'venue_id', t.venue_id,
                                        'record_id', p_version_id, 'target_type', 'document_version'),
         p_idempotency_key,
         jsonb_build_object('document_id', p_document_id, 'version_id', p_version_id, 'owner_kind', p_owner_kind,
                            'organisation_id', p_organisation_id, 'person_id', p_person_id,
                            'document_type_id', p_document_type_id, 'title', p_title, 'sha256', p_sha256_hex,
                            'media_type', p_media_type, 'size_bytes', p_size_bytes, 'issuer', p_issuer,
                            'reference', p_reference, 'valid_from', p_valid_from, 'expires_on', p_expires_on));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  if d.id is null then
    insert into core.document (id, customer_id, venue_id, document_type_id, owner_kind, organisation_id, person_id,
                               provided_via_organisation_id, title)
    values (p_document_id, v_customer, t.venue_id, p_document_type_id, p_owner_kind,
            case when p_owner_kind = 'organisation' then p_organisation_id end,
            case when p_owner_kind = 'person' then p_person_id end,
            case when p_owner_kind = 'person' then p_organisation_id end,
            p_title);
  end if;
  insert into core.document_version (id, customer_id, document_id, version_no, storage_path, sha256, media_type,
                                     size_bytes, issuer, reference, valid_from, expires_on, uploaded_by_person_id)
  values (p_version_id, v_customer, p_document_id,
          coalesce((select max(version_no) from core.document_version where document_id = p_document_id), 0) + 1,
          v_customer || '/' || p_document_id || '/' || p_version_id, decode(p_sha256_hex, 'hex'),
          p_media_type, p_size_bytes, p_issuer, p_reference, p_valid_from, p_expires_on,
          (v ->> 'actor_person_id')::uuid);
  return v || jsonb_build_object('storage_path', v_customer || '/' || p_document_id || '/' || p_version_id);
end $$;

create function api.record_scan_result(p_idempotency_key text, p_version_id uuid, p_result text, p_engine text,
                                       p_detail text default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  dv core.document_version;
  v  jsonb;
begin
  select * into dv from core.document_version where id = p_version_id;
  v := authz.require('document.record_scan',
         jsonb_build_object('customer_id', dv.customer_id, 'record_id', p_version_id, 'target_type', 'document_version'),
         p_idempotency_key,
         jsonb_build_object('version_id', p_version_id, 'result', p_result, 'engine', p_engine, 'detail', p_detail));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  if p_result not in ('clean', 'infected') then
    raise exception 'scan result must be clean or infected' using errcode = '22023';
  end if;
  update core.document_version set scan_status = p_result, scanned_at = now(), scan_engine = p_engine,
                                   scan_detail = p_detail
   where id = p_version_id;
  return v;
end $$;

-- Releases the storage path only for a visible, clean version; the server then signs
-- a short-lived URL. Every release is audited.
create function api.document_access(p_version_id uuid) returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  dv core.document_version;
  d  core.document;
begin
  select * into dv from core.document_version where id = p_version_id;
  if dv.id is null or dv.document_id not in (select authz.visible_document_ids()) then
    return authz.deny('document.access', 'not_found', 'The record does not exist or you do not have access to it.',
                      'Access to this document', 'The document''s owner or a tenant administrator');
  end if;
  if dv.scan_status <> 'clean' then
    return authz.deny('document.access', case dv.scan_status when 'pending' then 'scan_pending' else 'infected' end,
      case dv.scan_status when 'pending' then 'This file is still being checked for malware.'
                          else 'This file failed the malware check and will not be released.' end,
      'A clean malware scan', case dv.scan_status when 'pending' then 'Nobody yet: try again shortly'
                                                  else 'Whoever submitted the document, with a new file' end);
  end if;
  select * into d from core.document where id = dv.document_id;
  perform audit.record('document.accessed', dv.customer_id, d.venue_id, 'core.document_version', dv.id, null, null);
  return jsonb_build_object('ok', true, 'storage_path', dv.storage_path, 'media_type', dv.media_type,
                            'sha256', encode(dv.sha256, 'hex'), 'disposition', 'attachment');
end $$;

create function api.review_document(
  p_idempotency_key text, p_version_id uuid, p_criteria_version_id uuid, p_outcome text, p_criteria_results jsonb,
  p_scope_wording text, p_conditions text default null, p_acting_appointment_id uuid default null,
  p_acting_delegation_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  dv   core.document_version;
  d    core.document;
  c    core.review_criteria_version;
  v    jsonb;
begin
  select * into dv from core.document_version where id = p_version_id;
  select * into d from core.document where id = dv.document_id;
  v := authz.require('document.review',
         jsonb_build_object(
           'customer_id', d.customer_id, 'venue_id', d.venue_id, 'record_id', v_id, 'target_type', 'review_decision',
           -- P2-4: the uploader, the person concerned and the owning organisation's people are excluded.
           'excluded_person_ids',
             jsonb_build_array(dv.uploaded_by_person_id, d.person_id)
             || core.organisation_people(coalesce(d.organisation_id, d.provided_via_organisation_id))),
         p_idempotency_key,
         jsonb_build_object('version_id', p_version_id, 'criteria_version_id', p_criteria_version_id,
                            'outcome', p_outcome, 'criteria_results', p_criteria_results,
                            'scope_wording', p_scope_wording, 'conditions', p_conditions),
         p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  if dv.scan_status <> 'clean' then
    raise exception 'a document can be reviewed only once its file has been scanned clean' using errcode = 'PT409';
  end if;
  select * into c from core.review_criteria_version where id = p_criteria_version_id;
  if c.document_type_id is distinct from d.document_type_id
     or c.id is distinct from (select x.id from core.review_criteria_version x
                                where x.document_type_id = d.document_type_id and x.effective_from <= now()
                                order by x.effective_from desc limit 1) then
    raise exception 'review against the criteria currently in force for this document type' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(c.criteria) k
              where coalesce(jsonb_typeof(p_criteria_results -> (k ->> 'code')), 'missing') <> 'boolean') then
    raise exception 'record a result for every declared criterion' using errcode = '22023';
  end if;
  if p_outcome = 'reviewed_no_further_comments' and exists (
       select 1 from jsonb_array_elements(c.criteria) k where not (p_criteria_results ->> (k ->> 'code'))::boolean) then
    raise exception 'a document that fails a criterion cannot be reviewed with no further comments' using errcode = '22023';
  end if;

  insert into core.review_decision (id, customer_id, venue_id, document_version_id, review_criteria_version_id,
                                    reviewer_person_id, decision_context_id, outcome, criteria_results, conditions,
                                    scope_wording)
  values (v_id, d.customer_id, d.venue_id, p_version_id, p_criteria_version_id, (v ->> 'actor_person_id')::uuid,
          (v ->> 'decision_context_id')::uuid, p_outcome, p_criteria_results, p_conditions, p_scope_wording);
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Competencies (Q38)
-- ---------------------------------------------------------------------------

create function api.create_competency_type(p_idempotency_key text, p_venue_id uuid, p_code text, p_label text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v_customer uuid := core.venue_customer(p_venue_id);
  v    jsonb;
begin
  v := authz.require('competency_type.create',
         jsonb_build_object('customer_id', v_customer, 'venue_id', p_venue_id, 'record_id', v_id, 'target_type', 'competency_type'),
         p_idempotency_key, jsonb_build_object('venue_id', p_venue_id, 'code', p_code, 'label', p_label));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.competency_type (id, customer_id, venue_id, code, label) values (v_id, v_customer, p_venue_id, p_code, p_label);
  return v;
end $$;

create function api.declare_competency(
  p_idempotency_key text, p_person_id uuid, p_competency_type_id uuid, p_issuer text, p_number text,
  p_expires_on date, p_document_version_id uuid default null, p_via_organisation_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  t    core.competency_type;
  v    jsonb;
begin
  select * into t from core.competency_type where id = p_competency_type_id;
  v := authz.require(case when p_via_organisation_id is null then 'competency.declare_own' else 'competency.declare_for_person' end,
         jsonb_build_object('customer_id', t.customer_id, 'venue_id', t.venue_id, 'record_id', v_id, 'target_type', 'competency')
         || case when p_via_organisation_id is null then jsonb_build_object('subject_person_id', p_person_id)
                 else jsonb_build_object('organisation_id', p_via_organisation_id, 'person_id', p_person_id) end,
         p_idempotency_key,
         jsonb_build_object('person_id', p_person_id, 'competency_type_id', p_competency_type_id, 'issuer', p_issuer,
                            'number', p_number, 'expires_on', p_expires_on, 'document_version_id', p_document_version_id,
                            'via_organisation_id', p_via_organisation_id));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  if p_document_version_id is not null and not exists (
       select 1 from core.document_version dv join core.document d on d.id = dv.document_id
        where dv.id = p_document_version_id and d.person_id = p_person_id) then
    raise exception 'supporting evidence must be one of this person''s documents' using errcode = '22023';
  end if;
  insert into core.competency (id, customer_id, venue_id, person_id, competency_type_id, issuer, number, expires_on,
                               document_version_id, declared_by_person_id, declared_via_organisation_id)
  values (v_id, t.customer_id, t.venue_id, p_person_id, p_competency_type_id, p_issuer, p_number, p_expires_on,
          p_document_version_id, (v ->> 'actor_person_id')::uuid, p_via_organisation_id);
  return v;
end $$;

create function api.verify_competency(
  p_idempotency_key text, p_competency_id uuid, p_method text, p_source_checked text, p_holder_match boolean,
  p_scope text, p_valid_until date, p_outcome text, p_notes text default null,
  p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  c    core.competency;
  v    jsonb;
begin
  select * into c from core.competency where id = p_competency_id;
  v := authz.require('competency.verify',
         jsonb_build_object('customer_id', c.customer_id, 'venue_id', c.venue_id, 'record_id', v_id,
                            'target_type', 'competency_verification',
                            'excluded_person_ids', jsonb_build_array(c.person_id, c.declared_by_person_id)
                                                   || core.organisation_people(c.declared_via_organisation_id)),
         p_idempotency_key,
         jsonb_build_object('competency_id', p_competency_id, 'method', p_method, 'source_checked', p_source_checked,
                            'holder_match', p_holder_match, 'scope', p_scope, 'valid_until', p_valid_until,
                            'outcome', p_outcome, 'notes', p_notes),
         p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.competency_verification (id, customer_id, venue_id, competency_id, verifier_person_id,
                                            decision_context_id, method, source_checked, holder_match, scope,
                                            valid_until, outcome, notes)
  values (v_id, c.customer_id, c.venue_id, p_competency_id, (v ->> 'actor_person_id')::uuid,
          (v ->> 'decision_context_id')::uuid, p_method, p_source_checked, p_holder_match, p_scope, p_valid_until,
          p_outcome, p_notes);
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Evidence requirements (Q39)
-- ---------------------------------------------------------------------------

create function api.create_evidence_requirement(
  p_idempotency_key text, p_venue_id uuid, p_code text, p_label text, p_applies_to_kind text,
  p_capacity_code text, p_appointment_type_id uuid, p_requires_kind text, p_document_type_id uuid,
  p_competency_type_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v_customer uuid := core.venue_customer(p_venue_id);
  v    jsonb;
begin
  v := authz.require('evidence_requirement.create',
         jsonb_build_object('customer_id', v_customer, 'venue_id', p_venue_id, 'record_id', v_id,
                            'target_type', 'evidence_requirement'),
         p_idempotency_key,
         jsonb_build_object('venue_id', p_venue_id, 'code', p_code, 'label', p_label,
                            'applies_to_kind', p_applies_to_kind, 'capacity_code', p_capacity_code,
                            'appointment_type_id', p_appointment_type_id, 'requires_kind', p_requires_kind,
                            'document_type_id', p_document_type_id, 'competency_type_id', p_competency_type_id));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.evidence_requirement (id, customer_id, venue_id, code, label, applies_to_kind, capacity_code,
                                         appointment_type_id, requires_kind, document_type_id, competency_type_id)
  values (v_id, v_customer, p_venue_id, p_code, p_label, p_applies_to_kind, p_capacity_code, p_appointment_type_id,
          p_requires_kind, p_document_type_id, p_competency_type_id);
  return v;
end $$;

create function api.publish_evidence_requirement_version(
  p_idempotency_key text, p_requirement_id uuid, p_in_force boolean, p_owner_person_id uuid,
  p_effective_from timestamptz, p_change_reason text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  r    core.evidence_requirement;
  v    jsonb;
begin
  select * into r from core.evidence_requirement where id = p_requirement_id;
  v := authz.require('evidence_requirement.publish',
         jsonb_build_object('customer_id', r.customer_id, 'venue_id', r.venue_id, 'record_id', v_id,
                            'target_type', 'evidence_requirement_version'),
         p_idempotency_key,
         jsonb_build_object('requirement_id', p_requirement_id, 'in_force', p_in_force,
                            'owner_person_id', p_owner_person_id, 'effective_from', p_effective_from,
                            'change_reason', p_change_reason));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.evidence_requirement_version (id, customer_id, venue_id, evidence_requirement_id, version_no,
                                                 in_force, owner_person_id, effective_from, change_reason)
  values (v_id, r.customer_id, r.venue_id, p_requirement_id, 1, p_in_force, p_owner_person_id, p_effective_from,
          p_change_reason);
  return v;
end $$;

-- What an engagement needs, for its dates, for anyone who can see the engagement.
create function api.engagement_evidence(p_engagement_id uuid) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  e core.engagement;
begin
  select * into e from core.engagement where id = p_engagement_id;
  if e.id is null or e.id not in (select authz.visible_engagement_ids()) then
    return authz.deny('engagement.approve', 'not_found', 'The record does not exist or you do not have access to it.',
                      'Access to this engagement', 'A tenant administrator for this customer');
  end if;
  return jsonb_build_object('ok', true, 'engagement_id', e.id,
    'evidence', authz.evidence_lines(e.venue_id, 'engagement', e.capacity_code, e.organisation_id, null, e.valid_during));
end $$;

-- ---------------------------------------------------------------------------
-- Engagement approval and withdrawal (Q31, P2-2)
-- ---------------------------------------------------------------------------

create function api.approve_engagement(p_idempotency_key text, p_engagement_id uuid, p_expected_version integer,
                                       p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  e core.engagement;
  v jsonb;
begin
  select * into e from core.engagement where id = p_engagement_id;
  v := authz.require('engagement.approve',
         jsonb_build_object('customer_id', e.customer_id, 'venue_id', e.venue_id, 'record_id', p_engagement_id,
                            'target_type', 'engagement', 'organisation_id', e.organisation_id,
                            'capacity_code', e.capacity_code, 'window', e.valid_during::text,
                            'excluded_person_ids', core.organisation_people(e.organisation_id)),
         p_idempotency_key, jsonb_build_object('engagement_id', p_engagement_id, 'expected_version', p_expected_version),
         p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.engagement', p_engagement_id, 'active', p_expected_version,
                          (v ->> 'decision_context_id')::uuid);
  return v;
end $$;

create function api.withdraw_engagement(p_idempotency_key text, p_engagement_id uuid, p_expected_version integer,
                                        p_reason text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  e core.engagement;
  v jsonb;
begin
  select * into e from core.engagement where id = p_engagement_id;
  v := authz.require('engagement.withdraw',
         jsonb_build_object('customer_id', e.customer_id, 'venue_id', e.venue_id, 'record_id', p_engagement_id,
                            'target_type', 'engagement'),
         p_idempotency_key,
         jsonb_build_object('engagement_id', p_engagement_id, 'expected_version', p_expected_version, 'reason', p_reason));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.engagement', p_engagement_id, 'withdrawn', p_expected_version,
                          (v ->> 'decision_context_id')::uuid,
                          jsonb_build_object('ended_at', now(), 'end_reason', p_reason));
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Restrictions (Q18, D-010, P2-7)
-- ---------------------------------------------------------------------------

create function api.impose_restriction(p_idempotency_key text, p_venue_id uuid, p_subject_kind text, p_subject_id uuid,
                             p_reason text, p_acting_appointment_id uuid default null,
                             p_acting_delegation_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v_customer uuid := core.venue_customer(p_venue_id);
  v    jsonb;
begin
  if p_subject_kind not in ('person', 'organisation') then
    raise exception 'subject must be a person or an organisation' using errcode = '22023';
  end if;
  v := authz.require(p_subject_kind || '.restrict',
         jsonb_build_object('customer_id', v_customer, 'venue_id', p_venue_id, 'record_id', v_id,
                            'target_type', 'restriction',
                            'excluded_person_ids', case p_subject_kind when 'person' then jsonb_build_array(p_subject_id)
                                                                      else '[]'::jsonb end),
         p_idempotency_key,
         jsonb_build_object('venue_id', p_venue_id, 'subject_kind', p_subject_kind, 'subject_id', p_subject_id,
                            'reason', p_reason),
         p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.restriction (id, customer_id, venue_id, subject_kind, person_id, organisation_id, reason, status,
                                imposed_by_decision_context_id)
  values (v_id, v_customer, p_venue_id, p_subject_kind,
          case when p_subject_kind = 'person' then p_subject_id end,
          case when p_subject_kind = 'organisation' then p_subject_id end,
          p_reason, 'active', (v ->> 'decision_context_id')::uuid);
  return v;
end $$;

create function api.lift_restriction(p_idempotency_key text, p_restriction_id uuid, p_expected_version integer,
                                     p_reason text, p_acting_appointment_id uuid default null,
                                     p_acting_delegation_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  r       core.restriction;
  v_owner uuid;
  v_excl  jsonb;
  v       jsonb;
begin
  select * into r from core.restriction where id = p_restriction_id;
  select coalesce(dc.acting_appointment_id, d.delegator_appointment_id) into v_owner
    from core.decision_context dc left join core.delegation d on d.id = dc.acting_delegation_id
   where dc.id = r.imposed_by_decision_context_id;
  if r.subject_kind = 'person' then
    -- The person, and anyone working with the same organisations, are excluded.
    select jsonb_build_array(r.person_id) || coalesce(jsonb_agg(x.p), '[]') into v_excl
      from (select jsonb_array_elements(core.organisation_people(rel.organisation_id)) p
              from core.person_organisation_relationship rel
             where rel.person_id = r.person_id and rel.status = 'active') x;
  else
    v_excl := core.organisation_people(r.organisation_id);
  end if;
  v := authz.require(r.subject_kind || '.lift_restriction',
         jsonb_build_object('customer_id', r.customer_id, 'venue_id', r.venue_id, 'record_id', p_restriction_id,
                            'target_type', 'restriction', 'owner_appointment_id', v_owner,
                            'excluded_person_ids', v_excl),
         p_idempotency_key,
         jsonb_build_object('restriction_id', p_restriction_id, 'expected_version', p_expected_version, 'reason', p_reason),
         p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  if length(btrim(coalesce(p_reason, ''))) = 0 then
    raise exception 'a reason is required to lift a restriction' using errcode = '22023';
  end if;
  perform core.transition('core.restriction', p_restriction_id, 'lifted', p_expected_version,
                          (v ->> 'decision_context_id')::uuid,
                          jsonb_build_object('lifted_at', now(), 'lift_reason', p_reason));
  return v;
end $$;

grant execute on all functions in schema api to authenticated;
revoke execute on all functions in schema api from anon, public;
