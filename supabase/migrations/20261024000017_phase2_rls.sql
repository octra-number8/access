-- 0017 Grants and RLS for phase 2 tables; engagement, relationship and contact
--      policies widened for contractor administrators
--
-- Where a visibility rule is also needed by an API function (engagements, documents,
-- competencies), the policy and the function both use the same authz helper.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

grant select on all tables in schema core to authenticated;
revoke insert, update, delete, truncate, references, trigger on all tables in schema core from authenticated, anon;

grant execute on function
  authz.my_admin_organisation_ids(),
  authz.my_action_venue_ids(text),
  authz.visible_engagement_ids(),
  authz.visible_document_ids(),
  authz.visible_competency_ids()
to authenticated;

create policy catalogue_read on core.derived_action for select to authenticated using (true);
create policy catalogue_read on core.service_action for select to authenticated using (true);
create policy service_account_read on core.service_account for select to authenticated
  using (auth_user_id = (select auth.uid()));

create policy organisation_admin_read on core.organisation_admin for select to authenticated
  using (customer_id in (select authz.my_oversight_customer_ids())
         or organisation_id in (select authz.my_organisation_ids())
         or organisation_id in (select authz.visible_organisation_ids()));

create policy invitation_read on core.invitation for select to authenticated
  using (customer_id in (select authz.my_admin_customer_ids())
         or owner_person_id in (select authz.my_person_ids())
         or invited_by_person_id in (select authz.my_person_ids())
         or (kind = 'person' and organisation_id in (select authz.my_admin_organisation_ids()))
         or accepted_by_user_id = (select auth.uid()));

-- The restricted person and organisation can see their own restriction, so a blocked
-- action can be explained to them (Q19).
create policy restriction_read on core.restriction for select to authenticated
  using (customer_id in (select authz.my_admin_customer_ids())
         or venue_id in (select authz.my_appointee_venue_ids())
         or person_id in (select authz.my_person_ids())
         or organisation_id in (select authz.my_organisation_ids()));

create policy privacy_notice_read on core.privacy_notice_version for select to authenticated
  using (customer_id in (select authz.my_customer_ids()));
create policy privacy_notice_shown_read on core.privacy_notice_shown for select to authenticated
  using (customer_id in (select authz.my_admin_customer_ids()) or auth_user_id = (select auth.uid()));

create policy venue_scoped_read on core.document_type               for select to authenticated using (venue_id in (select authz.my_venue_ids()));
create policy venue_scoped_read on core.review_criteria_version     for select to authenticated using (venue_id in (select authz.my_venue_ids()));
create policy venue_scoped_read on core.competency_type             for select to authenticated using (venue_id in (select authz.my_venue_ids()));
create policy venue_scoped_read on core.evidence_requirement        for select to authenticated using (venue_id in (select authz.my_venue_ids()));
create policy venue_scoped_read on core.evidence_requirement_version for select to authenticated using (venue_id in (select authz.my_venue_ids()));

create policy document_read on core.document for select to authenticated
  using (id in (select authz.visible_document_ids()));
create policy document_version_read on core.document_version for select to authenticated
  using (document_id in (select authz.visible_document_ids()));
create policy review_decision_read on core.review_decision for select to authenticated
  using (exists (select 1 from core.document_version v
                  where v.id = document_version_id and v.document_id in (select authz.visible_document_ids())));
create policy competency_read on core.competency for select to authenticated
  using (id in (select authz.visible_competency_ids()));
create policy competency_verification_read on core.competency_verification for select to authenticated
  using (competency_id in (select authz.visible_competency_ids()));

drop policy engagement_read on core.engagement;
create policy engagement_read on core.engagement for select to authenticated
  using (id in (select authz.visible_engagement_ids()));

drop policy relationship_read on core.person_organisation_relationship;
create policy relationship_read on core.person_organisation_relationship for select to authenticated
  using (person_id in (select authz.my_person_ids())
         or customer_id in (select authz.my_oversight_customer_ids())
         or organisation_id in (select authz.visible_organisation_ids())
         or organisation_id in (select authz.my_admin_organisation_ids()));

-- An organisation administrator can reach the people actively working with them.
drop policy person_contact_read on core.person_contact;
create policy person_contact_read on core.person_contact for select to authenticated
  using (person_id in (select authz.my_person_ids())
         or customer_id in (select authz.my_admin_customer_ids())
         or person_id in (select r.person_id from core.person_organisation_relationship r
                           where r.status = 'active'
                             and r.organisation_id in (select authz.my_admin_organisation_ids())));
