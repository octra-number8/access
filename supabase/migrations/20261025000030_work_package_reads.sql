-- 0030 Read functions for the phase 4b screens (D-017)
--
-- api.preview_screening runs a screening version's rules over sample answers, so an
-- author can see what a job would be recommended before proposing it. It uses the same
-- evaluator as submission and records nothing.
-- api.work_package_detail gives everyone who can see a job the names they need to read
-- it (parties, contact, supervisor, areas, classes, deciders) without granting them the
-- underlying person or organisation records. Names only: never contact details.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

create function api.preview_screening(p_version_id uuid, p_answers jsonb) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare s core.screening_set_version;
begin
  select * into s from core.screening_set_version where id = p_version_id;
  if s.id is null or s.venue_id not in (select authz.my_venue_ids()) then
    return core.refuse('screening_set.save_draft', 'not_found', 'The record does not exist or you do not have access to it.',
                       'Access to this screening', 'The venue''s tenant administrator');
  end if;
  return jsonb_build_object('ok', true,
    'problems', to_jsonb(core.screening_answer_problems(s.content, coalesce(p_answers, '{}'))),
    'matches', coalesce((
      select jsonb_agg(jsonb_build_object('rule_key', m.rule_key, 'permit_class_id', m.permit_class_id,
                                          'class_name', pc.name, 'handling', pc.handling,
                                          'rationale', (select r ->> 'rationale' from jsonb_array_elements(s.content -> 'rules') r
                                                         where r ->> 'key' = m.rule_key)) order by pc.name, m.rule_key)
        from core.screening_matches(s.content, coalesce(p_answers, '{}')) m
        join core.permit_class pc on pc.id = m.permit_class_id), '[]'));
end $$;

create function core.person_name(p_id uuid) returns text
language sql stable security definer set search_path = '' as $$
  select given_name || ' ' || family_name from core.person where id = p_id $$;

create function api.work_package_detail(p_work_package_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare wp core.work_package; rev core.work_package_revision; resp core.screening_response; s core.screening_set_version;
begin
  select * into wp from core.work_package where id = p_work_package_id;
  if wp.id is null or wp.id not in (select authz.visible_work_package_ids()) then
    return core.refuse('work_package.revise', 'not_found', 'The record does not exist or you do not have access to it.',
                       'Access to this job', 'The job''s organisation or the venue');
  end if;
  select * into rev from core.work_package_revision where id = wp.current_revision_id;
  select * into resp from core.screening_response where revision_id = wp.screened_revision_id;
  select * into s from core.screening_set_version where id = resp.set_version_id;

  return jsonb_build_object(
    'ok', true, 'id', wp.id, 'reference', wp.reference, 'status', wp.status, 'row_version', wp.row_version,
    'cancel_reason', wp.cancel_reason, 'venue_id', wp.venue_id,
    'venue', (select name from core.venue where id = wp.venue_id),
    'work_type', (select label from core.work_type where id = wp.work_type_id),
    'event', (select name from core.event where id = wp.event_id),
    'performing_organisation_id', wp.performing_organisation_id,
    'performing_organisation', (select legal_name from core.organisation where id = wp.performing_organisation_id),
    'created_by', core.person_name(wp.created_by_person_id),
    'revision', jsonb_build_object(
      'id', rev.id, 'no', rev.revision_no, 'title', rev.title, 'scope', rev.scope, 'method', rev.method,
      'window_from', lower(rev.planned_window), 'window_to', upper(rev.planned_window),
      'contact_person_id', rev.contact_person_id, 'contact', core.person_name(rev.contact_person_id),
      'supervisor_person_id', rev.supervisor_person_id, 'supervisor', core.person_name(rev.supervisor_person_id),
      'areas', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name) order by a.name), '[]')
                  from core.work_package_area x join core.area a on a.id = x.area_id where x.revision_id = rev.id),
      'systems', (select coalesce(jsonb_agg(jsonb_build_object('id', y.id, 'name', y.name) order by y.name), '[]')
                    from core.work_package_system x join core.system y on y.id = x.system_id where x.revision_id = rev.id),
      'parties', (select coalesce(jsonb_agg(jsonb_build_object('organisation_id', o.id, 'name', o.legal_name, 'role', p.role)
                                            order by p.role, o.legal_name), '[]')
                    from core.work_package_party p join core.organisation o on o.id = p.organisation_id where p.revision_id = rev.id)),
    'revisions', (select coalesce(jsonb_agg(jsonb_build_object('no', r.revision_no, 'kind', r.change_kind, 'reason', r.reason,
                                                             'title', r.title, 'at', r.created_at, 'by', core.person_name(r.author_person_id))
                                            order by r.revision_no desc), '[]')
                    from core.work_package_revision r where r.work_package_id = wp.id),
    'draft_answers', (select answers from core.screening_draft where work_package_id = wp.id),
    'draft_selected', (select to_jsonb(selected_class_ids) from core.screening_draft where work_package_id = wp.id),
    'screening', case when resp.id is null then null else jsonb_build_object(
      'version_no', s.version_no, 'approved_by', core.person_name(s.decided_by_person_id), 'approved_at', s.decided_at,
      'submitted_at', resp.created_at, 'submitted_by', core.person_name(resp.respondent_person_id),
      'answers', (select coalesce(jsonb_agg(jsonb_build_object('question', q ->> 'text',
                    'answer', (select string_agg(coalesce((select o ->> 'text' from jsonb_array_elements(q -> 'options') o where o ->> 'key' = a),
                                                          case a when 'yes' then 'Yes' when 'no' then 'No' else a end), ', ')
                                 from jsonb_array_elements_text(resp.answers -> (q ->> 'key')) a))), '[]')
                    from jsonb_array_elements(s.content -> 'questions') q where resp.answers ? (q ->> 'key'))) end,
    'recommendations', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', x.id, 'status', x.status, 'row_version', x.row_version, 'applicant_selected', x.applicant_selected,
        'permit_class_id', x.permit_class_id, 'class_name', pc.name,
        'reasons', (select coalesce(jsonb_agg(jsonb_build_object('rule_key', r ->> 'key', 'rationale', r ->> 'rationale')), '[]')
                      from jsonb_array_elements(s.content -> 'rules') r where (r ->> 'key') = any (x.matched_rule_keys)),
        'challenge', (select jsonb_build_object('reason', c.reason, 'at', c.created_at, 'by', core.person_name(c.raised_by_person_id),
                                                'documents', cardinality(c.document_version_ids))
                        from core.screening_challenge c where c.recommendation_id = x.id),
        'decision', (select jsonb_build_object('outcome', d.outcome, 'reason', d.reason, 'at', d.created_at,
                                               'by', core.person_name(d.decider_person_id))
                       from core.screening_challenge c join core.challenge_decision d on d.challenge_id = c.id
                      where c.recommendation_id = x.id)) order by pc.name), '[]')
        from core.screening_recommendation x join core.permit_class pc on pc.id = x.permit_class_id
       where x.revision_id = wp.screened_revision_id),
    'holds', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', h.id, 'status', h.status, 'row_version', h.row_version, 'class_name', pc.name,
        'reasons', (select coalesce(jsonb_agg(jsonb_build_object('rule_key', r ->> 'key', 'rationale', r ->> 'rationale')), '[]')
                      from jsonb_array_elements(s.content -> 'rules') r where (r ->> 'key') = any (h.matched_rule_keys)),
        'evidence', (select coalesce(jsonb_agg(jsonb_build_object('decider', e.external_decider, 'organisation', e.external_organisation,
                                                                  'reference', e.reference, 'scope', e.scope, 'decided_on', e.decided_on,
                                                                  'conditions', e.conditions, 'documents', cardinality(e.document_version_ids))
                                               order by e.created_at), '[]')
                       from core.external_reference_evidence e where e.hold_id = h.id),
        'decision', (select jsonb_build_object('outcome', d.outcome, 'reason', d.reason, 'at', d.created_at,
                                               'by', core.person_name(d.decider_person_id))
                       from core.external_reference_decision d where d.hold_id = h.id)) order by pc.name), '[]')
        from core.external_reference_hold h join core.permit_class pc on pc.id = h.permit_class_id
       where h.revision_id = wp.screened_revision_id),
    'no_permit_required', (select coalesce(jsonb_agg(jsonb_build_object('scope', n.scope_wording, 'reason', n.reason, 'at', n.created_at,
                                                                     'by', core.person_name(n.decider_person_id),
                                                                     'for_class', (select pc.name from core.screening_recommendation x
                                                                                     join core.permit_class pc on pc.id = x.permit_class_id
                                                                                    where x.id = n.recommendation_id))
                                                  order by n.created_at), '[]')
        from core.no_permit_required_decision n where n.revision_id = wp.screened_revision_id),
    'routable_blockers', case when wp.status = 'screening' then jsonb_build_object(
        'open_recommendations', (select count(*) from core.screening_recommendation x
                                  where x.revision_id = wp.screened_revision_id and x.status = 'recommended'),
        'open_challenges', (select count(*) from core.screening_recommendation x
                             where x.revision_id = wp.screened_revision_id and x.status = 'challenged'),
        'open_holds', (select count(*) from core.external_reference_hold h
                        where h.revision_id = wp.screened_revision_id and h.status = 'open'),
        'refused_holds', (select count(*) from core.external_reference_hold h
                           where h.revision_id = wp.screened_revision_id and h.status = 'refused'),
        'needs_no_permit_decision', not exists (select 1 from core.screening_recommendation x
                                                 where x.revision_id = wp.screened_revision_id and x.status in ('accepted', 'upheld', 'recommended', 'challenged'))
                                    and not exists (select 1 from core.no_permit_required_decision n where n.revision_id = wp.screened_revision_id))
      end);
end $$;

grant execute on function api.preview_screening(uuid, jsonb), api.work_package_detail(uuid) to authenticated;
revoke execute on function api.preview_screening(uuid, jsonb), api.work_package_detail(uuid) from anon, public;
