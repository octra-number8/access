-- 0023 Inductions: link-holder basis, visibility helpers and RLS (D-016)
--
-- Learners never read course content directly: the content column (which holds the
-- correct answers) is withheld from the client role, and learners receive content only
-- through api.learner_course, which strips the answers.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

-- ---- link_holder basis in authz.evaluate ------------------------------------------------
do $m$
declare d text;
begin
  d := pg_get_functiondef('authz.evaluate(text,jsonb,uuid,uuid)'::regprocedure);
  if position('  v_inv      core.invitation;' in d) = 0
     or position('  if v_customer is null or not exists (select 1 from core.customer where id = v_customer) then' in d) = 0 then
    raise exception 'authz.evaluate no longer has the expected structure';
  end if;
  d := replace(d, '  v_inv      core.invitation;', '  v_inv      core.invitation;
  v_link     core.induction_link;');
  d := replace(d, '  if v_customer is null or not exists (select 1 from core.customer where id = v_customer) then', $r$  -- The signed-in holder of a personal induction link, whose login email matches it (P3-2).
  if v_action.basis = 'link_holder' then
    select * into v_link from core.induction_link where id = (p_target ->> 'record_id')::uuid;
    if v_link.id is null or v_link.token_hash is distinct from decode(p_target ->> 'token_hash', 'hex') then
      return authz.deny(p_action, 'not_found', v_not_found, 'A valid induction link', 'Whoever sent you the link');
    end if;
    if v_link.status <> 'issued' then
      return authz.deny(p_action, 'link_revoked', 'This induction link has been withdrawn.', 'A new link',
                        'Whoever sent you the link');
    end if;
    if now() >= v_link.expires_at then
      return authz.deny(p_action, 'link_expired', 'This induction link has expired.', 'A new link',
                        'Whoever sent you the link');
    end if;
    if (select lower(u.email) from auth.users u where u.id = auth.uid()) is distinct from v_link.email then
      return authz.deny(p_action, 'link_wrong_account',
        'This induction link was sent to a different email address. Sign in with the address it was sent to.',
        'The account the link was sent to', 'Whoever sent you the link, if the address was wrong');
    end if;
    if authz.actor_person(v_link.customer_id) is not null and authz.actor_person(v_link.customer_id) <> v_link.person_id then
      return authz.deny(p_action, 'link_other_person',
        'This induction link is for someone else.', 'The person the link was issued to', 'Whoever sent you the link');
    end if;
    return v_base || jsonb_build_object('actor_kind', 'user', 'actor_person_id', v_link.person_id);
  end if;

  if v_customer is null or not exists (select 1 from core.customer where id = v_customer) then$r$);
  execute d;
end $m$;

-- ---- Visibility ---------------------------------------------------------------------------
-- Completions: the person, tenant administrators, appointees at the venue (the gate phase
-- will need them), and the administrators of an organisation the person works with.
create function authz.visible_completion_ids() returns setof uuid
language sql stable security definer
set search_path = ''
as $$
  select c.id from core.induction_completion c
   where c.person_id in (select authz.my_person_ids())
      or c.customer_id in (select authz.my_admin_customer_ids())
      or c.venue_id in (select authz.my_appointee_venue_ids())
      or c.person_id in (select r.person_id from core.person_organisation_relationship r
                          where r.status = 'active' and r.organisation_id in (select authz.my_admin_organisation_ids()))
$$;

create function authz.visible_attempt_ids() returns setof uuid
language sql stable security definer
set search_path = ''
as $$
  select a.id from core.induction_attempt a
   where a.person_id in (select authz.my_person_ids())
      or a.customer_id in (select authz.my_admin_customer_ids())
      or a.venue_id in (select authz.my_action_venue_ids('induction.facilitate'))
$$;

grant execute on function authz.visible_completion_ids(), authz.visible_attempt_ids() to authenticated;

-- ---- Grants -------------------------------------------------------------------------------
grant select on core.event, core.event_phase, core.induction_course, core.course_open_point,
                core.induction_attempt, core.module_progress, core.question_response,
                core.induction_completion, core.completion_invalidation to authenticated;
-- Content (with correct answers) is never readable by clients directly.
grant select (id, customer_id, venue_id, course_id, version_no, language, status, source_ref, pass_mark_percent,
              all_critical_required, max_attempts, retry_delay_minutes, shuffle_options, validity_mode, validity_days,
              validity_until, signature_mode, authored_by_person_id, submitted_by_person_id, published_by_person_id,
              published_at, return_reason, content_sha256, row_version, created_at, created_by_user_id)
  on core.course_version to authenticated;
grant select (id, customer_id, venue_id, course_id, person_id, email, expires_at, issued_by_person_id,
              via_organisation_id, status, revoked_at, claimed_at, row_version, created_at, created_by_user_id)
  on core.induction_link to authenticated;
grant select (id, customer_id, venue_id, sha256, media_type, size_bytes, original_name, uploaded_by_person_id,
              scan_status, row_version, created_at, created_by_user_id)
  on core.induction_media to authenticated;

-- ---- Policies -------------------------------------------------------------------------------
create policy venue_scoped_read on core.event             for select to authenticated using (venue_id in (select authz.my_venue_ids()));
create policy venue_scoped_read on core.event_phase       for select to authenticated using (venue_id in (select authz.my_venue_ids()));
create policy venue_scoped_read on core.induction_course  for select to authenticated using (venue_id in (select authz.my_venue_ids()));
create policy venue_scoped_read on core.course_version    for select to authenticated using (venue_id in (select authz.my_venue_ids()));
create policy venue_scoped_read on core.course_open_point for select to authenticated using (venue_id in (select authz.my_venue_ids()));
create policy venue_scoped_read on core.induction_media   for select to authenticated using (venue_id in (select authz.my_venue_ids()));

create policy induction_link_read on core.induction_link for select to authenticated
  using (customer_id in (select authz.my_admin_customer_ids())
         or issued_by_person_id in (select authz.my_person_ids())
         or person_id in (select authz.my_person_ids())
         or via_organisation_id in (select authz.my_admin_organisation_ids()));

create policy attempt_read on core.induction_attempt for select to authenticated
  using (id in (select authz.visible_attempt_ids()));
create policy module_progress_read on core.module_progress for select to authenticated
  using (attempt_id in (select authz.visible_attempt_ids()));
create policy question_response_read on core.question_response for select to authenticated
  using (attempt_id in (select authz.visible_attempt_ids()));
create policy completion_read on core.induction_completion for select to authenticated
  using (id in (select authz.visible_completion_ids()));
create policy invalidation_read on core.completion_invalidation for select to authenticated
  using (completion_id in (select authz.visible_completion_ids()));
