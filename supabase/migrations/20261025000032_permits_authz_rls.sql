-- 0032 Permits: visibility, RLS, and permits following a material change to the job (D-018)
--
-- People who decide permit steps can see the jobs and permits at their venue, as
-- screening authorities can. A material change to a job now also returns its permits
-- that are not yet issued to draft (invariant 6); issued and active permits are phase 6.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

create or replace function authz.visible_work_package_ids() returns setof uuid
language sql stable security definer
set search_path = ''
as $$
  select wp.id from core.work_package wp
   where wp.customer_id in (select authz.my_admin_customer_ids())
      or wp.venue_id in (select authz.my_action_venue_ids('screening.decide'))
      or wp.venue_id in (select authz.my_action_venue_ids('external_reference.decide'))
      or wp.venue_id in (select authz.my_action_venue_ids('work_package.require_class'))
      or wp.venue_id in (select authz.my_action_venue_ids('permit_step.decide'))
      or wp.venue_id in (select authz.my_action_venue_ids('permit_step.decide_occupier'))
      or wp.venue_id in (select authz.my_action_venue_ids('permit_step.decide_landlord'))
      or wp.venue_id in (select authz.my_action_venue_ids('permit_step.record_external'))
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

create function authz.visible_permit_ids() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select p.id from core.permit p where p.work_package_id in (select authz.visible_work_package_ids()) $$;
create function authz.visible_permit_version_ids() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select v.id from core.permit_version v where v.permit_id in (select authz.visible_permit_ids()) $$;
create function authz.visible_step_decision_ids() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select d.id from core.step_decision d join core.permit_step s on s.id = d.permit_step_id
   where s.permit_version_id in (select authz.visible_permit_version_ids()) $$;
grant execute on function authz.visible_permit_ids(), authz.visible_permit_version_ids(), authz.visible_step_decision_ids() to authenticated;

grant select on core.permit_class_version, core.area_occupation, core.class_requirement, core.permit, core.permit_draft,
                core.permit_version, core.permit_step, core.step_decision, core.permit_condition, core.external_decision,
                core.rfi, core.rfi_response to authenticated;

create policy venue_scoped_read on core.permit_class_version for select to authenticated using (venue_id in (select authz.my_venue_ids()));
-- Occupation is venue information: administrators and appointees at the venue only, never contractors.
create policy occupation_read on core.area_occupation for select to authenticated
  using (customer_id in (select authz.my_admin_customer_ids()) or venue_id in (select authz.my_appointee_venue_ids()));
create policy class_requirement_read on core.class_requirement for select to authenticated
  using (work_package_id in (select authz.visible_work_package_ids()));
create policy permit_read on core.permit for select to authenticated using (id in (select authz.visible_permit_ids()));
create policy permit_draft_read on core.permit_draft for select to authenticated using (permit_id in (select authz.visible_permit_ids()));
create policy permit_version_read on core.permit_version for select to authenticated using (permit_id in (select authz.visible_permit_ids()));
create policy permit_step_read on core.permit_step for select to authenticated
  using (permit_version_id in (select authz.visible_permit_version_ids()));
create policy step_decision_read on core.step_decision for select to authenticated
  using (id in (select authz.visible_step_decision_ids()));
create policy condition_read on core.permit_condition for select to authenticated
  using (step_decision_id in (select authz.visible_step_decision_ids()));
create policy external_decision_read on core.external_decision for select to authenticated
  using (step_decision_id in (select authz.visible_step_decision_ids()));
create policy rfi_read on core.rfi for select to authenticated
  using (permit_version_id in (select authz.visible_permit_version_ids()));
create policy rfi_response_read on core.rfi_response for select to authenticated
  using (permit_version_id in (select authz.visible_permit_version_ids()));

create or replace function api.revise_work_package(p_idempotency_key text, p_work_package_id uuid, p_expected_version integer,
                                        p_input jsonb, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  wp core.work_package; v_action text; v_kind text; t jsonb; r jsonb; v jsonb; ctx uuid; rev uuid;
  problems text[]; x record;
begin
  select * into wp from core.work_package where id = p_work_package_id;
  v_action := core.wp_action('work_package.revise', p_work_package_id, wp.customer_id);
  t := core.wp_target(wp, p_work_package_id, 'work_package', coalesce(core.wp_actor_org(p_work_package_id), wp.performing_organisation_id));
  r := jsonb_build_object('work_package_id', p_work_package_id, 'expected_version', p_expected_version,
                          'input', p_input, 'reason', p_reason);
  v := core.authorised_or_refusal(v_action, t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if wp.status = 'cancelled' then
    return core.refuse(v_action, 'not_ready', 'This job has been cancelled.', 'A job that is not cancelled', 'Nobody: start a new job');
  end if;
  problems := core.revision_problems(wp.venue_id, wp.performing_organisation_id, p_input);
  if length(btrim(coalesce(p_reason, ''))) = 0 then problems := problems || text 'Say why the job is changing.'; end if;
  if cardinality(problems) > 0 then
    return core.refuse(v_action, 'invalid_content', 'The change has problems.', 'Each item listed', 'You',
                       jsonb_build_object('problems', to_jsonb(problems)));
  end if;
  v_kind := core.change_kind(core.revision_facts(wp.current_revision_id), core.input_facts(wp.performing_organisation_id, p_input));
  if v_kind is null then
    return core.refuse(v_action, 'no_change', 'Nothing in the job has changed.', 'A change', 'You');
  end if;
  v := authz.require(v_action, t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ctx := (v ->> 'decision_context_id')::uuid;
  if wp.row_version <> p_expected_version then
    raise exception 'this job changed since you opened it' using errcode = 'PT409';
  end if;
  rev := core.insert_revision(wp, (select max(revision_no) + 1 from core.work_package_revision where work_package_id = wp.id),
                              v_kind, p_reason, p_input, (v ->> 'actor_person_id')::uuid, ctx);

  if v_kind = 'material' and wp.status in ('screening', 'routed') then
    for x in select id, 'core.screening_recommendation' tbl, row_version from core.screening_recommendation
              where work_package_id = wp.id and status <> 'superseded'
             union all
             select id, 'core.external_reference_hold', row_version from core.external_reference_hold
              where work_package_id = wp.id and status <> 'superseded' loop
      perform authz.derive('screening.supersede', 'screening_outcome', x.id);
      perform core.transition(x.tbl::regclass, x.id, 'superseded', x.row_version, core.ctx_uuid('decision_context_id'));
      perform authz.resume(ctx);
    end loop;
    -- Permits not yet issued go back to draft; their next version needs the full route (invariant 6).
    for x in select id, 'core.permit' tbl, row_version from core.permit
              where work_package_id = wp.id and status not in ('draft', 'cancelled') loop
      perform authz.derive('permit.return_to_draft', 'permit', x.id);
      perform core.transition('core.permit', x.id, 'draft', x.row_version, core.ctx_uuid('decision_context_id'));
      perform authz.resume(ctx);
    end loop;
    perform authz.derive('work_package.reopen', 'work_package', wp.id);
    perform core.transition('core.work_package', wp.id, 'draft', wp.row_version, core.ctx_uuid('decision_context_id'),
                            jsonb_build_object('current_revision_id', rev, 'screened_revision_id', null));
    perform authz.resume(ctx);
  else
    update core.work_package set current_revision_id = rev where id = wp.id;
  end if;
  return v || jsonb_build_object('revision_id', rev, 'change_kind', v_kind);
end $$;
