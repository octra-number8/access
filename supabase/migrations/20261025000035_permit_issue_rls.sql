-- 0035 Permits 5b: visibility, RLS, and material change with issued permits (D-018)
--
-- Issuers, exception deciders and the people named on a permit's team can see the job
-- and its permits. A material change is refused while a job has issued or active
-- permits: those need suspension and re-issue (phase 6), never a silent return to draft.
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
      or wp.venue_id in (select authz.my_action_venue_ids('permit.issue'))
      or wp.venue_id in (select authz.my_action_venue_ids('permit.exception_decide'))
      or exists (select 1 from core.permit p join core.permit_team_member m on m.permit_id = p.id
                  where p.work_package_id = wp.id and m.removed_at is null and m.person_id in (select authz.my_person_ids()))
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

grant select on core.venue_calendar_version, core.restriction_window, core.exception_request, core.exception_decision,
                core.permit_team_member, core.issue_snapshot, core.permit_acceptance to authenticated;

create policy venue_scoped_read on core.venue_calendar_version for select to authenticated using (venue_id in (select authz.my_venue_ids()));
create policy venue_scoped_read on core.restriction_window     for select to authenticated using (venue_id in (select authz.my_venue_ids()));
create policy exception_request_read on core.exception_request for select to authenticated
  using (permit_version_id in (select authz.visible_permit_version_ids()));
create policy exception_decision_read on core.exception_decision for select to authenticated
  using (exception_request_id in (select r.id from core.exception_request r
                                   where r.permit_version_id in (select authz.visible_permit_version_ids())));
create policy team_read on core.permit_team_member for select to authenticated using (permit_id in (select authz.visible_permit_ids()));
create policy snapshot_read on core.issue_snapshot for select to authenticated using (permit_id in (select authz.visible_permit_ids()));
create policy acceptance_read on core.permit_acceptance for select to authenticated
  using (issue_snapshot_id in (select s.id from core.issue_snapshot s where s.permit_id in (select authz.visible_permit_ids())));

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
  -- Issued and active permits cannot follow a material change back to draft: they need
  -- suspension and re-issue, which arrive in phase 6.
  if v_kind = 'material' and exists (select 1 from core.permit where work_package_id = wp.id
                                        and status in ('issued_awaiting_acceptance', 'active')) then
    return core.refuse(v_action, 'permits_issued',
      'This job has issued permits, so it cannot be changed materially here. The issued permits would first have to be suspended, which is not yet available.',
      'No issued or active permits on the job', 'The venue''s permit issuer');
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
