-- 0037 Read functions for the phase 5c screens (D-018)
--
-- api.permit_detail gives everyone who can see a permit what the screens need in one
-- read: names (never contact details), the current version, every step with its latest
-- decision and conditions, information requests and responses, the team, exceptions,
-- notice, the issue blockers (for an approved permit), the snapshot and acceptance, and
-- which steps are open now. It decides nothing; every action is still decided by
-- authz.evaluate when it is taken.
-- api.open_permit_steps lists the open steps on permits the caller can see, for the
-- reviewer's queue.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

create function api.permit_detail(p_permit_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare p core.permit; v core.permit_version; d core.permit_draft; cv core.permit_class_version; wp core.work_package;
begin
  select * into p from core.permit where id = p_permit_id;
  if p.id is null or p.id not in (select authz.visible_permit_ids()) then
    return core.refuse('permit.submit', 'not_found', 'The record does not exist or you do not have access to it.',
                       'Access to this permit', 'The job''s organisation or the venue');
  end if;
  select * into v from core.permit_version where id = p.current_version_id;
  select * into d from core.permit_draft where permit_id = p.id;
  select * into wp from core.work_package where id = p.work_package_id;
  cv := case when v.id is not null then (select c from core.permit_class_version c where c.id = v.class_version_id)
             else core.current_class_version(p.permit_class_id) end;
  return jsonb_build_object(
    'ok', true, 'id', p.id, 'kind', p.kind, 'status', p.status, 'row_version', p.row_version,
    'class', (select jsonb_build_object('id', id, 'code', code, 'name', name) from core.permit_class where id = p.permit_class_id),
    'class_version', case when cv.id is null then null else jsonb_build_object('id', cv.id, 'no', cv.version_no, 'content', cv.content) end,
    'work_package_id', wp.id, 'job_reference', wp.reference, 'job_status', wp.status,
    'job_title', (select title from core.work_package_revision where id = wp.current_revision_id),
    'performing_organisation_id', wp.performing_organisation_id,
    'performing_organisation', (select legal_name from core.organisation where id = wp.performing_organisation_id),
    'venue_id', p.venue_id, 'venue_timezone', (select timezone from core.venue where id = p.venue_id),
    'parent', (select jsonb_build_object('id', x.id, 'status', x.status, 'class_name', pc.name)
                 from core.permit x join core.permit_class pc on pc.id = x.permit_class_id where x.id = p.parent_permit_id),
    'children', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'status', x.status, 'class_name', pc.name) order by pc.name), '[]')
                   from core.permit x join core.permit_class pc on pc.id = x.permit_class_id
                  where x.parent_permit_id = p.id and x.status <> 'cancelled'),
    'draft', jsonb_build_object('answers', d.answers, 'window_from', d.window_from, 'window_to', d.window_to,
                                'document_version_ids', to_jsonb(d.document_version_ids)),
    'job_window', (select jsonb_build_object('from', lower(r.planned_window), 'to', upper(r.planned_window))
                     from core.work_package_revision r where r.id = wp.current_revision_id),
    'job_areas', (select coalesce(jsonb_agg(a.name order by a.name), '[]') from core.work_package_area x join core.area a on a.id = x.area_id
                   where x.revision_id = wp.current_revision_id),
    'version', case when v.id is null then null else jsonb_build_object(
      'id', v.id, 'no', v.version_no, 'answers', v.answers, 'window_from', lower(v.planned_window), 'window_to', upper(v.planned_window),
      'declaration', v.declaration, 'declared_by', core.person_name(v.declared_by_person_id), 'submitted_at', v.created_at,
      'documents', (select coalesce(jsonb_agg(jsonb_build_object('id', dv.id, 'title', doc.title, 'version_no', dv.version_no)), '[]')
                      from core.document_version dv join core.document doc on doc.id = dv.document_id where dv.id = any (v.document_version_ids))) end,
    'versions', (select coalesce(jsonb_agg(jsonb_build_object('no', x.version_no, 'at', x.created_at, 'by', core.person_name(x.declared_by_person_id),
                                                              'responds_to_rfi', x.responds_to_rfi_id is not null) order by x.version_no desc), '[]')
                   from core.permit_version x where x.permit_id = p.id),
    'steps', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', s.id, 'key', s.step_key, 'name', s.name, 'kind', s.kind, 'group', s.group_no, 'open', core.step_open(s.id),
        'party', (select legal_name from core.organisation where id = s.party_organisation_id),
        'areas', (select coalesce(jsonb_agg(a.name order by a.name), '[]') from core.area a where a.id = any (s.area_ids)),
        'decision', (select jsonb_build_object('id', dd.id, 'outcome', dd.outcome, 'reason', dd.reason, 'scope_wording', dd.scope_wording,
                                               'by', core.person_name(dd.decider_person_id), 'by_person_id', dd.decider_person_id, 'at', dd.created_at,
                                               'conditions', (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'text', k.text,
                                                               'acknowledge', k.acknowledge_at_acceptance)), '[]') from core.permit_condition k where k.step_decision_id = dd.id),
                                               'external', (select to_jsonb(e) - 'customer_id' - 'venue_id' - 'created_by_user_id'
                                                              from core.external_decision e where e.step_decision_id = dd.id))
                       from core.step_decision dd where dd.id = (core.latest_decision(s.id)).id),
        -- What the step decided on the previous version, so a reviewer can confirm it (P5-7).
        'previous', (select jsonb_build_object('outcome', pd.outcome, 'reason', pd.reason, 'scope_wording', pd.scope_wording,
                                               'by', core.person_name(pd.decider_person_id))
                       from core.permit_version pv2 join core.permit_step ps on ps.permit_version_id = pv2.id
                       join core.step_decision pd on pd.id = (core.latest_decision(ps.id)).id
                      where pv2.permit_id = p.id and pv2.version_no = v.version_no - 1 and ps.step_key = s.step_key
                        and ps.party_organisation_id is not distinct from s.party_organisation_id))
        order by s.group_no, s.step_key), '[]')
        from core.permit_step s where s.permit_version_id = v.id),
    'rfis', (select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'version_no', pv.version_no, 'message', q.message, 'items', q.items,
                                                          'asked_by', core.person_name(sd.decider_person_id), 'step', ps.name, 'at', q.created_at,
                                                          'responses', (select x.responses from core.rfi_response x where x.rfi_id = q.id))
                                       order by q.created_at desc), '[]')
               from core.rfi q join core.permit_version pv on pv.id = q.permit_version_id
               join core.step_decision sd on sd.id = q.step_decision_id join core.permit_step ps on ps.id = sd.permit_step_id
              where pv.permit_id = p.id),
    'team', (select coalesce(jsonb_agg(jsonb_build_object('person_id', t.person_id, 'name', core.person_name(t.person_id), 'role', t.role)
                                       order by t.role desc, core.person_name(t.person_id)), '[]')
               from core.permit_team_member t where t.permit_id = p.id and t.removed_at is null),
    'exceptions', (select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'kind', q.kind, 'reason', q.reason, 'consequence', q.consequence_of_delay,
                                                                'restriction', (select reason from core.restriction_window w where w.id = q.restriction_window_id),
                                                                'by', core.person_name(q.requested_by_person_id), 'at', q.created_at,
                                                                'decision', (select jsonb_build_object('outcome', x.outcome, 'conditions', x.conditions, 'reason', x.reason,
                                                                                                       'by', core.person_name(x.decider_person_id), 'at', x.created_at)
                                                                               from core.exception_decision x where x.exception_request_id = q.id))
                                             order by q.created_at), '[]')
                     from core.exception_request q where q.permit_version_id = v.id),
    'restrictions', case when v.id is null then '[]'::jsonb else (select coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'effect', w.effect, 'reason', w.reason,
                                                     'from', lower(w.during), 'to', upper(w.during))), '[]') from core.permit_restrictions(p.id) w) end,
    'notice', core.permit_notice(p.id),
    'blockers', case when p.status = 'approved_for_issue' then core.issue_blockers(p.id) end,
    'draft_problems', case when p.status in ('draft', 'more_information_required') then to_jsonb(core.permit_draft_problems(p.id)) end,
    'snapshot', (select jsonb_build_object('id', s.id, 'content', s.content, 'issued_at', s.issued_at, 'issuer', core.person_name(s.issuer_person_id))
                   from core.issue_snapshot s where s.id = p.issue_snapshot_id),
    'acceptance', (select jsonb_build_object('accepted_at', a.accepted_at, 'by', core.person_name(a.supervisor_person_id),
                                             'briefed', (select jsonb_agg(core.person_name(x)) from unnest(a.briefed_person_ids) x), 'briefed_at', a.briefed_at)
                     from core.permit_acceptance a where a.issue_snapshot_id = p.issue_snapshot_id));
end $$;

-- Open steps on permits the caller can see. Whether they may decide is still decided by
-- authz.evaluate when they try.
create function api.open_permit_steps() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'step_id', s.id, 'step_name', s.name, 'kind', s.kind, 'permit_id', p.id, 'class_name', pc.name, 'permit_status', p.status,
           'job_reference', wp.reference, 'job_title', (select title from core.work_package_revision where id = wp.current_revision_id),
           'organisation', (select legal_name from core.organisation where id = wp.performing_organisation_id),
           'submitted_at', v.created_at, 'window_from', lower(v.planned_window),
           'venue_timezone', (select timezone from core.venue where id = p.venue_id),
           'party', (select legal_name from core.organisation where id = s.party_organisation_id))
         order by lower(v.planned_window), v.created_at), '[]')
    from core.permit p
    join core.permit_version v on v.id = p.current_version_id
    join core.permit_step s on s.permit_version_id = v.id
    join core.permit_class pc on pc.id = p.permit_class_id
    join core.work_package wp on wp.id = p.work_package_id
   where p.id in (select authz.visible_permit_ids()) and core.step_open(s.id)
     and wp.venue_id in (select authz.my_appointee_venue_ids()) $$;

grant execute on function api.permit_detail(uuid), api.open_permit_steps() to authenticated;
revoke execute on function api.permit_detail(uuid), api.open_permit_steps() from anon, public;
