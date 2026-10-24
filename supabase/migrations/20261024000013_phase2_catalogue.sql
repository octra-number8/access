-- 0013 Phase 2 catalogue: new action bases and verbs, state machines, derived
--      decisions and service accounts (D-012)
--
-- New bases:
--   organisation_admin  a current administrator of the organisation the record belongs to
--   invitee             the signed-in holder of a pending invitation's token, whose login
--                       email matches the invitation
--   service             a registered platform service account (e.g. the malware scanner)
--   derived             only via authz.derive(), inside an authorised parent decision
--
-- Changes a product rule from phase 1: engagements no longer start active; they start
-- proposed and need engagement.approve (P2-2). Existing rows are not touched.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

alter table core.authority_action drop constraint authority_action_basis_check;
alter table core.authority_action add constraint authority_action_basis_check
  check (basis in ('appointment', 'tenant_admin', 'platform_admin', 'subject',
                   'organisation_admin', 'invitee', 'service', 'derived'));

insert into core.authority_action (code, basis, delegable, description) values
  -- contractor administration (§2)
  ('invitation.create_person',          'organisation_admin', false, 'Invite a person to join the organisation'),
  ('invitation.cancel_person',          'organisation_admin', false, 'Cancel a pending person invitation'),
  ('organisation_admin.appoint_deputy', 'organisation_admin', false, 'Name a deputy organisation administrator'),
  ('organisation_admin.revoke_deputy',  'organisation_admin', false, 'Remove the deputy organisation administrator'),
  ('organisation_admin.transfer',       'organisation_admin', false, 'Hand the accountable administrator role to another person'),
  ('relationship.end',                  'organisation_admin', false, 'End a person''s relationship with the organisation'),
  ('document.submit_org',               'organisation_admin', false, 'Submit an organisation document'),
  ('document.submit_for_person',        'organisation_admin', false, 'Submit a document for one of the organisation''s people'),
  ('competency.declare_for_person',     'organisation_admin', false, 'Declare a competency for one of the organisation''s people'),
  -- venue administration
  ('invitation.create_organisation',    'tenant_admin',       false, 'Invite an organisation to a venue'),
  ('invitation.cancel_organisation',    'tenant_admin',       false, 'Cancel an organisation invitation'),
  ('invitation.resolve_match',          'tenant_admin',       false, 'Decide whether an accepting organisation is an existing one (Q26)'),
  ('organisation_admin.set_accountable','tenant_admin',       false, 'Set an organisation''s accountable administrator'),
  ('relationship.confirm_facilitated',  'tenant_admin',       false, 'Record a person''s facilitated acceptance of a relationship'),
  ('relationship.end_by_admin',         'tenant_admin',       false, 'End a relationship administratively'),
  ('engagement.withdraw',               'tenant_admin',       false, 'Withdraw a proposed engagement that will not start'),
  ('appointment_type.propose',          'tenant_admin',       false, 'Propose a new appointment type version (D-011)'),
  ('document_type.create',              'tenant_admin',       false, 'Add a document type'),
  ('review_criteria.publish',           'tenant_admin',       false, 'Publish declared review criteria for a document type'),
  ('competency_type.create',            'tenant_admin',       false, 'Add a competency type'),
  ('evidence_requirement.create',       'tenant_admin',       false, 'Define an evidence requirement'),
  ('evidence_requirement.publish',      'tenant_admin',       false, 'Publish a version of an evidence requirement'),
  ('privacy_notice.publish',            'tenant_admin',       false, 'Publish a privacy notice version'),
  -- people acting for themselves
  ('person.update_own',                 'subject',            false, 'Update one''s own name, language and contact details'),
  ('relationship.accept',               'subject',            false, 'Accept a relationship with an organisation'),
  ('relationship.decline',              'subject',            false, 'Decline a relationship with an organisation'),
  ('relationship.end_own',              'subject',            false, 'End one''s own relationship with an organisation'),
  ('document.submit_own',               'subject',            false, 'Submit one''s own document'),
  ('competency.declare_own',            'subject',            false, 'Declare one''s own competency'),
  -- invitees
  ('invitation.accept',                 'invitee',            false, 'Accept an invitation'),
  ('invitation.decline',                'invitee',            false, 'Decline an invitation'),
  -- services
  ('document.record_scan',              'service',            false, 'Record a malware scan result'),
  ('invitation.record_delivery_failure','service',            false, 'Record that an invitation could not be delivered'),
  -- operational decisions
  ('engagement.approve',                'appointment',        true,  'Approve an engagement once its evidence is in place (Q31)'),
  ('document.review',                   'appointment',        true,  'Review a document against declared criteria (Q37)'),
  ('competency.verify',                 'appointment',        true,  'Verify a competency against an authoritative source (Q38)'),
  ('person.restrict',                   'appointment',        true,  'Restrict a person at a venue (Q18)'),
  ('person.lift_restriction',           'appointment',        true,  'Lift a person''s restriction (D-010)'),
  ('organisation.restrict',             'appointment',        true,  'Restrict an organisation at a venue (Q18)'),
  ('organisation.lift_restriction',     'appointment',        true,  'Lift an organisation''s restriction (D-010)'),
  ('appointment_type.approve',          'appointment',        false, 'Approve a proposed appointment type version (D-011, root appointees only)'),
  ('appointment_type.reject',           'appointment',        false, 'Reject a proposed appointment type version (D-011, root appointees only)'),
  -- derived from an authorised parent decision
  ('engagement.create_via_invitation',  'derived',            false, 'Create the proposed engagement an accepted invitation implies'),
  ('relationship.create_via_invitation','derived',            false, 'Create the relationship an accepted invitation implies');

-- Which decisions may create child decisions inside the same request.
create table core.derived_action (
  parent_action text not null references core.authority_action,
  child_action  text not null references core.authority_action,
  primary key (parent_action, child_action)
);
insert into core.derived_action (parent_action, child_action) values
  ('invitation.accept',        'engagement.create_via_invitation'),
  ('invitation.accept',        'relationship.create_via_invitation'),
  ('invitation.resolve_match', 'engagement.create_via_invitation'),
  ('invitation.resolve_match', 'relationship.create_via_invitation');
alter table core.derived_action enable row level security;
alter table core.derived_action force row level security;
create trigger forbid_change before update or delete on core.derived_action
  for each row execute function audit.forbid_change();

insert into core.state_machine (code, table_name) values
  ('invitation',               'core.invitation'),
  ('relationship',             'core.person_organisation_relationship'),
  ('restriction',              'core.restriction'),
  ('appointment_type_version', 'core.appointment_type_version');

-- P2-2: engagements no longer start active. Product rules change only in migrations.
alter table core.state_initial disable trigger forbid_change;
delete from core.state_initial where machine = 'engagement' and state = 'active' and required_action = 'engagement.create';
alter table core.state_initial enable trigger forbid_change;

insert into core.state_initial (machine, state, required_action) values
  ('engagement',               'proposed',  'engagement.create'),
  ('engagement',               'proposed',  'engagement.create_via_invitation'),
  ('invitation',               'pending',   'invitation.create_organisation'),
  ('invitation',               'pending',   'invitation.create_person'),
  ('relationship',             'invited',   'person_organisation.record'),
  ('relationship',             'active',    'relationship.create_via_invitation'),
  ('restriction',              'active',    'person.restrict'),
  ('restriction',              'active',    'organisation.restrict'),
  ('appointment_type_version', 'approved',  'appointment_type.publish'),
  ('appointment_type_version', 'proposed',  'appointment_type.propose');

insert into core.state_transition (machine, from_state, to_state, required_action) values
  ('engagement',               'proposed',       'active',         'engagement.approve'),
  ('engagement',               'proposed',       'withdrawn',      'engagement.withdraw'),
  ('invitation',               'pending',        'accepted',       'invitation.accept'),
  ('invitation',               'pending',        'awaiting_match', 'invitation.accept'),
  ('invitation',               'awaiting_match', 'accepted',       'invitation.resolve_match'),
  ('invitation',               'pending',        'declined',       'invitation.decline'),
  ('invitation',               'pending',        'cancelled',      'invitation.cancel_organisation'),
  ('invitation',               'pending',        'cancelled',      'invitation.cancel_person'),
  ('invitation',               'awaiting_match', 'cancelled',      'invitation.cancel_organisation'),
  ('relationship',             'invited',        'active',         'relationship.accept'),
  ('relationship',             'invited',        'active',         'relationship.confirm_facilitated'),
  ('relationship',             'invited',        'declined',       'relationship.decline'),
  ('relationship',             'active',         'ended',          'relationship.end'),
  ('relationship',             'active',         'ended',          'relationship.end_own'),
  ('relationship',             'active',         'ended',          'relationship.end_by_admin'),
  ('restriction',              'active',         'lifted',         'person.lift_restriction'),
  ('restriction',              'active',         'lifted',         'organisation.lift_restriction'),
  ('appointment_type_version', 'proposed',       'approved',       'appointment_type.approve'),
  ('appointment_type_version', 'proposed',       'rejected',       'appointment_type.reject');

-- Platform service accounts, inserted by an operator (runbook), never via the API.
-- They act only through service-basis actions matching their purpose.
create table core.service_account (
  id                 uuid primary key default gen_random_uuid(),
  auth_user_id       uuid not null references auth.users (id),
  purpose            text not null check (purpose in ('malware_scanner', 'notification_sender')),
  granted_at         timestamptz not null default now(),
  revoked_at         timestamptz,
  row_version        integer not null default 1,
  created_at         timestamptz not null default now(),
  created_by_user_id uuid default auth.uid()
);
create unique index service_account_current_uq on core.service_account (auth_user_id, purpose) where revoked_at is null;
select core.attach_standard_triggers('core.service_account', 'revoked_at');

-- Which service purpose may perform which service action.
create table core.service_action (
  purpose     text not null,
  action_code text not null references core.authority_action,
  primary key (purpose, action_code)
);
insert into core.service_action (purpose, action_code) values
  ('malware_scanner',     'document.record_scan'),
  ('notification_sender', 'invitation.record_delivery_failure');
alter table core.service_action enable row level security;
alter table core.service_action force row level security;
create trigger forbid_change before update or delete on core.service_action
  for each row execute function audit.forbid_change();

-- decision_context gains the new actor kinds and a parent for derived decisions.
alter table core.decision_context drop constraint decision_context_actor_kind_check;
alter table core.decision_context add constraint decision_context_actor_kind_check
  check (actor_kind in ('user', 'tenant_admin', 'platform_admin', 'organisation_admin', 'service'));
alter table core.decision_context add column parent_id uuid references core.decision_context;

alter table audit.audit_event drop constraint audit_event_actor_kind_check;
alter table audit.audit_event add constraint audit_event_actor_kind_check
  check (actor_kind in ('user', 'tenant_admin', 'platform_admin', 'organisation_admin', 'service', 'system'));
