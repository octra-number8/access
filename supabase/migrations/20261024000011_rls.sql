-- 0011 Grants and Row Level Security policies
--
-- Clients get SELECT only, always filtered by RLS; they never INSERT, UPDATE or
-- DELETE any table. All writes go through api RPCs (0012). RLS was enabled and
-- forced when each table was created; until this migration every table denied all.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

grant usage on schema audit to authenticated;
grant select on all tables in schema core to authenticated;
grant select on audit.audit_event to authenticated;
revoke insert, update, delete, truncate, references, trigger on all tables in schema core from authenticated, anon;
revoke all on audit.audit_event from anon;
revoke insert, update, delete, truncate, references, trigger on audit.audit_event from authenticated;

-- Membership helpers are used inside policies, so the client role must be able to
-- call them. Everything else in authz, core and audit stays non-executable.
grant usage on schema authz to authenticated;
grant execute on function
  authz.my_person_ids(),
  authz.my_admin_customer_ids(),
  authz.my_break_glass_customer_ids(),
  authz.my_oversight_customer_ids(),
  authz.my_appointee_venue_ids(),
  authz.my_organisation_ids(),
  authz.my_engaged_venue_ids(),
  authz.my_venue_ids(),
  authz.my_customer_ids(),
  authz.visible_organisation_ids(),
  authz.visible_person_ids(),
  authz.is_platform_admin()
to authenticated;

-- Product catalogues: readable by any signed-in user.
create policy catalogue_read on core.authority_action    for select to authenticated using (true);
create policy catalogue_read on core.state_machine       for select to authenticated using (true);
create policy catalogue_read on core.state_initial       for select to authenticated using (true);
create policy catalogue_read on core.state_transition    for select to authenticated using (true);
create policy catalogue_read on core.engagement_capacity for select to authenticated using (true);

-- Tenancy
create policy customer_read on core.customer for select to authenticated
  using (id in (select authz.my_customer_ids()));
create policy venue_read on core.venue for select to authenticated
  using (id in (select authz.my_venue_ids()));
create policy platform_admin_read on core.platform_admin for select to authenticated
  using (auth_user_id = (select auth.uid()));
-- The customer's administrators can see every break-glass grant made against them.
create policy break_glass_read on core.break_glass_grant for select to authenticated
  using (customer_id in (select authz.my_admin_customer_ids())
         or platform_admin_user_id = (select auth.uid()));

-- Venue-scoped configuration and place: anyone with visibility of the venue.
create policy venue_scoped_read on core.area_kind               for select to authenticated using (venue_id in (select authz.my_venue_ids()));
create policy venue_scoped_read on core.area                    for select to authenticated using (venue_id in (select authz.my_venue_ids()));
create policy venue_scoped_read on core.system_type             for select to authenticated using (venue_id in (select authz.my_venue_ids()));
create policy venue_scoped_read on core.system                  for select to authenticated using (venue_id in (select authz.my_venue_ids()));
create policy venue_scoped_read on core.system_area             for select to authenticated using (venue_id in (select authz.my_venue_ids()));
create policy venue_scoped_read on core.system_ownership        for select to authenticated using (venue_id in (select authz.my_venue_ids()));
create policy venue_scoped_read on core.permit_class            for select to authenticated using (venue_id in (select authz.my_venue_ids()));
create policy venue_scoped_read on core.appointment_type        for select to authenticated using (venue_id in (select authz.my_venue_ids()));
create policy venue_scoped_read on core.appointment_type_version for select to authenticated using (venue_id in (select authz.my_venue_ids()));

-- Appointment summaries are visible at the venue so "who can resolve this" can be
-- answered. Competence evidence is restricted (appointment_evidence below).
create policy venue_scoped_read on core.appointment              for select to authenticated using (venue_id in (select authz.my_venue_ids()));
create policy venue_scoped_read on core.appointment_scope        for select to authenticated using (venue_id in (select authz.my_venue_ids()));
create policy venue_scoped_read on core.appointment_permit_class for select to authenticated using (venue_id in (select authz.my_venue_ids()));

create policy appointment_evidence_read on core.appointment_evidence for select to authenticated
  using (customer_id in (select authz.my_admin_customer_ids())
         or exists (select 1 from core.appointment a
                     where a.id = appointment_id
                       and (a.appointee_person_id in (select authz.my_person_ids())
                            or a.appointed_by_person_id in (select authz.my_person_ids()))));

create policy delegation_read on core.delegation for select to authenticated
  using (customer_id in (select authz.my_admin_customer_ids())
         or delegator_person_id in (select authz.my_person_ids())
         or delegate_person_id in (select authz.my_person_ids()));
create policy delegation_scope_read on core.delegation_scope for select to authenticated
  using (exists (select 1 from core.delegation d where d.id = delegation_id));

-- Parties
create policy organisation_read on core.organisation for select to authenticated
  using (customer_id in (select authz.my_oversight_customer_ids())
         or id in (select authz.my_organisation_ids())
         or id in (select authz.visible_organisation_ids()));
create policy engagement_read on core.engagement for select to authenticated
  using (customer_id in (select authz.my_oversight_customer_ids())
         or venue_id in (select authz.my_appointee_venue_ids())
         or organisation_id in (select authz.my_organisation_ids()));
create policy person_read on core.person for select to authenticated
  using (id in (select authz.my_person_ids())
         or customer_id in (select authz.my_oversight_customer_ids())
         or id in (select authz.visible_person_ids()));
-- Contact details: the person and their tenant administrators only. Not break-glass.
create policy person_contact_read on core.person_contact for select to authenticated
  using (person_id in (select authz.my_person_ids())
         or customer_id in (select authz.my_admin_customer_ids()));
create policy user_account_read on core.user_account for select to authenticated
  using (auth_user_id = (select auth.uid())
         or customer_id in (select authz.my_admin_customer_ids()));
create policy relationship_read on core.person_organisation_relationship for select to authenticated
  using (person_id in (select authz.my_person_ids())
         or customer_id in (select authz.my_oversight_customer_ids())
         or organisation_id in (select authz.visible_organisation_ids()));
create policy tenant_admin_read on core.tenant_admin for select to authenticated
  using (customer_id in (select authz.my_oversight_customer_ids())
         or person_id in (select authz.my_person_ids()));

-- Accountability
create policy decision_context_read on core.decision_context for select to authenticated
  using (customer_id in (select authz.my_admin_customer_ids())
         or actor_user_id = (select auth.uid()));
create policy status_history_read on core.status_history for select to authenticated
  using (customer_id in (select authz.my_admin_customer_ids())
         or venue_id in (select authz.my_venue_ids()));
create policy audit_read on audit.audit_event for select to authenticated
  using (customer_id in (select authz.my_admin_customer_ids())
         or actor_user_id = (select auth.uid()));
