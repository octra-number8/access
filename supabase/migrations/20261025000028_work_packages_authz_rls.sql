-- 0028 Work packages: authorisation service extensions, visibility and RLS (D-017)
--
-- Two extensions to the single authorisation service, both the existing rules applied
-- more widely, never a new kind of permission:
--   * A decision about a job in several areas or systems needs an appointment that
--     covers every one of them: targets may carry `area_ids` / `system_ids` lists, each
--     matched exactly as a single `area_id` / `system_id` is.
--   * A restricted organisation cannot start or submit work at that venue (D-010), as it
--     already cannot be engaged or approved there.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

create function authz.covers_all(p_items authz.scope_item[], p_venue_id uuid, p_target jsonb) returns boolean
language sql stable security definer set search_path = '' as $$
  select not exists (select 1 from jsonb_array_elements_text(coalesce(p_target -> 'area_ids', '[]')) x
                      where not authz.items_match(p_items, authz.target_item(p_venue_id, x::uuid, null)))
     and not exists (select 1 from jsonb_array_elements_text(coalesce(p_target -> 'system_ids', '[]')) x
                      where not authz.items_match(p_items, authz.target_item(p_venue_id, null, x::uuid))) $$;

do $m$
declare d text;
  a_old constant text := 'and authz.items_match(authz.appointment_scope_items(a.id), v_item)';
  g_old constant text := 'and authz.items_match(authz.delegation_scope_items(g.id), v_item)';
begin
  d := pg_get_functiondef('authz.capacities(text,jsonb,uuid)'::regprocedure);
  if (length(d) - length(replace(d, a_old, ''))) / length(a_old) <> 1
     or (length(d) - length(replace(d, g_old, ''))) / length(g_old) <> 1 then
    raise exception 'authz.capacities no longer has the expected structure';
  end if;
  d := replace(d, a_old, a_old || E'\n         and authz.covers_all(authz.appointment_scope_items(a.id), v_venue, p_target)');
  d := replace(d, g_old, g_old || E'\n         and authz.covers_all(authz.delegation_scope_items(g.id), v_venue, p_target)');
  execute d;

  d := pg_get_functiondef('authz.evaluate(text,jsonb,uuid,uuid)'::regprocedure);
  if position($s$if p_action in ('engagement.create', 'engagement.approve', 'invitation.resolve_match')$s$ in d) = 0 then
    raise exception 'authz.evaluate no longer has the expected structure';
  end if;
  d := replace(d, $s$if p_action in ('engagement.create', 'engagement.approve', 'invitation.resolve_match')$s$,
                  $s$if p_action in ('engagement.create', 'engagement.approve', 'invitation.resolve_match',
                     'work_package.create', 'work_package.create_for_venue',
                     'work_package.submit', 'work_package.submit_for_venue')$s$);
  -- The performing organisation is checked too when someone else (a commissioning party)
  -- acts for the job.
  if position('and v_org is not null and v_venue is not null and authz.organisation_restricted(v_org, v_venue) then' in d) = 0 then
    raise exception 'authz.evaluate restriction check no longer has the expected structure';
  end if;
  d := replace(d, 'and v_org is not null and v_venue is not null and authz.organisation_restricted(v_org, v_venue) then',
                  $s$and v_venue is not null
     and ((v_org is not null and authz.organisation_restricted(v_org, v_venue))
          or (p_target ? 'performing_organisation_id'
              and authz.organisation_restricted((p_target ->> 'performing_organisation_id')::uuid, v_venue))) then$s$);
  d := replace(d, $s$'This organisation is restricted at this venue, so it cannot be engaged or approved here.'$s$,
                  $s$case when p_action like 'work_package.%'
             then 'This organisation is restricted at this venue, so it cannot start or submit work here.'
             else 'This organisation is restricted at this venue, so it cannot be engaged or approved here.' end$s$);
  execute d;
end $m$;

-- ---- Visibility ---------------------------------------------------------------------------
-- A work package is seen by people from its party organisations (administrators, the
-- named contact and supervisor), tenant administrators of the venue, and appointees who
-- can make screening or external-reference decisions there. Never by other contractors.
create function authz.visible_work_package_ids() returns setof uuid
language sql stable security definer
set search_path = ''
as $$
  select wp.id from core.work_package wp
   where wp.customer_id in (select authz.my_admin_customer_ids())
      or wp.venue_id in (select authz.my_action_venue_ids('screening.decide'))
      or wp.venue_id in (select authz.my_action_venue_ids('external_reference.decide'))
      or wp.performing_organisation_id in (select authz.my_admin_organisation_ids())
      or exists (select 1 from core.work_package_revision r
                   join core.work_package_party p on p.revision_id = r.id
                  where r.work_package_id = wp.id
                    and p.organisation_id in (select authz.my_admin_organisation_ids()))
      or exists (select 1 from core.work_package_revision r
                  where r.work_package_id = wp.id
                    and (r.contact_person_id in (select authz.my_person_ids())
                         or r.supervisor_person_id in (select authz.my_person_ids())))
$$;

create function authz.visible_revision_ids() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select r.id from core.work_package_revision r where r.work_package_id in (select authz.visible_work_package_ids()) $$;

create function authz.visible_recommendation_ids() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select x.id from core.screening_recommendation x where x.work_package_id in (select authz.visible_work_package_ids()) $$;

create function authz.visible_hold_ids() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select h.id from core.external_reference_hold h where h.work_package_id in (select authz.visible_work_package_ids()) $$;

grant execute on function authz.visible_work_package_ids(), authz.visible_revision_ids(),
                          authz.visible_recommendation_ids(), authz.visible_hold_ids() to authenticated;

-- ---- Grants and policies ------------------------------------------------------------------
grant select on core.work_type, core.screening_set_version, core.work_package, core.work_package_revision,
                core.work_package_area, core.work_package_system, core.work_package_party, core.screening_draft,
                core.screening_response, core.screening_recommendation, core.screening_challenge,
                core.challenge_decision, core.no_permit_required_decision, core.external_reference_hold,
                core.external_reference_evidence, core.external_reference_decision to authenticated;

-- Configuration is readable at the venues a person works at, so applicants can see the
-- questions and the rules that apply to them (transparent screening, CLAUDE.md §7).
create policy venue_scoped_read on core.work_type             for select to authenticated using (venue_id in (select authz.my_venue_ids()));
create policy venue_scoped_read on core.screening_set_version for select to authenticated using (venue_id in (select authz.my_venue_ids()));

create policy work_package_read on core.work_package for select to authenticated
  using (id in (select authz.visible_work_package_ids()));
create policy revision_read on core.work_package_revision for select to authenticated
  using (work_package_id in (select authz.visible_work_package_ids()));
create policy area_read on core.work_package_area for select to authenticated
  using (revision_id in (select authz.visible_revision_ids()));
create policy system_read on core.work_package_system for select to authenticated
  using (revision_id in (select authz.visible_revision_ids()));
create policy party_read on core.work_package_party for select to authenticated
  using (revision_id in (select authz.visible_revision_ids()));
create policy draft_read on core.screening_draft for select to authenticated
  using (work_package_id in (select authz.visible_work_package_ids()));
create policy response_read on core.screening_response for select to authenticated
  using (work_package_id in (select authz.visible_work_package_ids()));
create policy recommendation_read on core.screening_recommendation for select to authenticated
  using (work_package_id in (select authz.visible_work_package_ids()));
create policy challenge_read on core.screening_challenge for select to authenticated
  using (recommendation_id in (select authz.visible_recommendation_ids()));
create policy challenge_decision_read on core.challenge_decision for select to authenticated
  using (challenge_id in (select c.id from core.screening_challenge c
                           where c.recommendation_id in (select authz.visible_recommendation_ids())));
create policy npr_read on core.no_permit_required_decision for select to authenticated
  using (work_package_id in (select authz.visible_work_package_ids()));
create policy hold_read on core.external_reference_hold for select to authenticated
  using (work_package_id in (select authz.visible_work_package_ids()));
create policy evidence_read on core.external_reference_evidence for select to authenticated
  using (hold_id in (select authz.visible_hold_ids()));
create policy hold_decision_read on core.external_reference_decision for select to authenticated
  using (hold_id in (select authz.visible_hold_ids()));
