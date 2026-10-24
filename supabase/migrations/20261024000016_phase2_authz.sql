-- 0016 Authorisation service, phase 2 (D-003, D-010, D-011, D-012)
--
-- Adds: organisation_admin, invitee, service and derived bases; restriction and
-- evidence preconditions; derived decisions; evidence evaluation (Q39); and
-- visibility helpers shared by RLS policies and the API, so visibility is decided
-- in exactly one place.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

-- ---------------------------------------------------------------------------
-- Membership and visibility helpers
-- ---------------------------------------------------------------------------

-- Relationships now have a lifecycle; only active ones count.
create or replace function authz.my_organisation_ids() returns setof uuid
language sql stable security definer
set search_path = ''
as $$
  select r.organisation_id
    from core.person_organisation_relationship r
   where r.person_id in (select authz.my_person_ids())
     and r.status = 'active'
     and now() <@ r.valid_during
$$;

create function authz.my_admin_organisation_ids() returns setof uuid
language sql stable security definer
set search_path = ''
as $$
  select oa.organisation_id
    from core.organisation_admin oa
   where oa.person_id in (select authz.my_person_ids())
     and oa.revoked_at is null
     and now() <@ oa.valid_during
$$;

create or replace function authz.visible_person_ids() returns setof uuid
language sql stable security definer
set search_path = ''
as $$
  select r.person_id
    from core.person_organisation_relationship r
   where r.organisation_id in (select authz.visible_organisation_ids())
     and r.status = 'active'
  union
  select a.appointee_person_id
    from core.appointment a
   where a.venue_id in (select authz.my_venue_ids())
     and a.status <> 'revoked'
  union
  select r.person_id
    from core.person_organisation_relationship r
   where r.organisation_id in (select authz.my_admin_organisation_ids())
     and r.status in ('active', 'invited')
$$;

-- Venues where I currently hold an appointment (or delegation) that allows an action.
create function authz.my_action_venue_ids(p_action text) returns setof uuid
language sql stable security definer
set search_path = ''
as $$
  select a.venue_id
    from core.appointment a
    join core.appointment_type_version tv on tv.id = a.appointment_type_version_id
   where a.appointee_person_id in (select authz.my_person_ids())
     and a.status = 'in_force' and now() <@ a.valid_during
     and p_action = any (tv.allowed_action_codes)
  union
  select d.venue_id
    from core.delegation d
   where d.delegate_person_id in (select authz.my_person_ids())
     and d.status = 'in_force' and now() <@ d.valid_during
     and p_action = any (d.action_codes)
     and authz.appointment_in_force(d.delegator_appointment_id)
$$;

-- Organisations (and their venues) with a live engagement.
create function authz.engaged_organisation_venues() returns table (organisation_id uuid, venue_id uuid)
language sql stable security definer
set search_path = ''
as $$
  select e.organisation_id, e.venue_id from core.engagement e where e.status in ('proposed', 'active', 'suspended')
$$;

create function authz.visible_engagement_ids() returns setof uuid
language sql stable security definer
set search_path = ''
as $$
  select e.id from core.engagement e
   where e.customer_id in (select authz.my_oversight_customer_ids())
      or e.venue_id in (select authz.my_appointee_venue_ids())
      or e.organisation_id in (select authz.my_organisation_ids())
$$;

-- Documents: owners and their administrators, tenant administrators, and document
-- reviewers at venues where the owner is engaged. Not break-glass.
create function authz.visible_document_ids() returns setof uuid
language sql stable security definer
set search_path = ''
as $$
  select d.id from core.document d
   where d.customer_id in (select authz.my_admin_customer_ids())
      or (d.owner_kind = 'organisation' and d.organisation_id in (select authz.my_admin_organisation_ids()))
      or (d.owner_kind = 'person' and d.person_id in (select authz.my_person_ids()))
      or (d.owner_kind = 'person' and d.provided_via_organisation_id in (select authz.my_admin_organisation_ids())
          and exists (select 1 from core.person_organisation_relationship r
                       where r.person_id = d.person_id and r.organisation_id = d.provided_via_organisation_id
                         and r.status = 'active'))
      or (d.venue_id in (select authz.my_action_venue_ids('document.review'))
          and (   (d.owner_kind = 'organisation' and exists (
                     select 1 from authz.engaged_organisation_venues() ev
                      where ev.organisation_id = d.organisation_id and ev.venue_id = d.venue_id))
               or (d.owner_kind = 'person' and exists (
                     select 1 from core.person_organisation_relationship r
                       join authz.engaged_organisation_venues() ev on ev.organisation_id = r.organisation_id
                      where r.person_id = d.person_id and r.status = 'active' and ev.venue_id = d.venue_id))))
$$;

create function authz.visible_competency_ids() returns setof uuid
language sql stable security definer
set search_path = ''
as $$
  select c.id from core.competency c
   where c.customer_id in (select authz.my_admin_customer_ids())
      or c.person_id in (select authz.my_person_ids())
      or (c.declared_via_organisation_id in (select authz.my_admin_organisation_ids())
          and exists (select 1 from core.person_organisation_relationship r
                       where r.person_id = c.person_id and r.organisation_id = c.declared_via_organisation_id
                         and r.status = 'active'))
      or (c.venue_id in (select authz.my_action_venue_ids('competency.verify'))
          and exists (select 1 from core.person_organisation_relationship r
                        join authz.engaged_organisation_venues() ev on ev.organisation_id = r.organisation_id
                       where r.person_id = c.person_id and r.status = 'active' and ev.venue_id = c.venue_id))
$$;

-- ---------------------------------------------------------------------------
-- Evidence evaluation (Q39): what this decision needs, for these dates
-- ---------------------------------------------------------------------------

create function authz.evidence_lines(
  p_venue_id       uuid,
  p_kind           text,     -- 'engagement' or 'appointment'
  p_key            text,     -- engagement capacity code, or appointment type id
  p_organisation_id uuid,
  p_person_id      uuid,
  p_window         tstzrange
) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  r        record;
  v_lines  jsonb := '[]';
  v_state  text;
  v_expiry date;
  v_dv     core.document_version;
  v_review core.review_decision;
  v_start  date := greatest(now(), lower(p_window))::date;
  v_end    date := case when upper_inf(p_window) then null else upper(p_window)::date end;
  v_comp   record;
begin
  for r in
    select er.*
      from core.evidence_requirement er
     where er.venue_id = p_venue_id
       and ((p_kind = 'engagement' and er.applies_to_kind = 'engagement_capacity' and er.capacity_code = p_key)
         or (p_kind = 'appointment' and er.applies_to_kind = 'appointment_type' and er.appointment_type_id::text = p_key))
       and (select v.in_force from core.evidence_requirement_version v
             where v.evidence_requirement_id = er.id and v.effective_from <= now()
             order by v.effective_from desc limit 1)
     order by er.code
  loop
    v_state := null; v_expiry := null;
    if r.requires_kind = 'document_type' then
      select dv.* into v_dv
        from core.document d join core.document_version dv on dv.document_id = d.id
       where d.document_type_id = r.document_type_id
         and ((p_kind = 'engagement' and d.organisation_id = p_organisation_id)
           or (p_kind = 'appointment' and d.person_id = p_person_id))
       order by dv.created_at desc, dv.version_no desc
       limit 1;
      if v_dv.id is null then
        v_state := 'missing';
      elsif v_dv.scan_status = 'pending' then
        v_state := 'scan_pending';
      elsif v_dv.scan_status = 'infected' then
        v_state := 'not_accepted';
      else
        select * into v_review from core.review_decision
         where document_version_id = v_dv.id and venue_id = p_venue_id
         order by created_at desc limit 1;
        if v_review.id is null then
          v_state := 'not_reviewed';
        elsif v_review.outcome = 'more_information_required' then
          v_state := 'more_information_required';
        elsif v_review.outcome = 'not_accepted' then
          v_state := 'not_accepted';
        else
          v_expiry := v_dv.expires_on;
        end if;
      end if;
    else
      -- The best currently verified declaration of this competency type.
      select c.id, least(c.expires_on, cv.valid_until) as expiry, cv.outcome into v_comp
        from core.competency c
        left join lateral (select * from core.competency_verification x
                            where x.competency_id = c.id order by x.created_at desc limit 1) cv on true
       where c.person_id = p_person_id and c.competency_type_id = r.competency_type_id
       order by (cv.outcome = 'verified') desc nulls last, least(c.expires_on, cv.valid_until) desc nulls first
       limit 1;
      if v_comp.id is null then
        v_state := 'missing';
      elsif v_comp.outcome is distinct from 'verified' then
        v_state := 'not_verified';
      else
        v_expiry := v_comp.expiry;
      end if;
    end if;

    if v_state is null then
      if v_expiry is not null and v_expiry < v_start then
        v_state := 'expired';
      elsif v_expiry is not null and (v_end is null or v_expiry < v_end) then
        v_state := 'expires_within_window';
      else
        v_state := 'satisfied';
      end if;
    end if;

    v_lines := v_lines || jsonb_build_object(
      'requirement_id', r.id, 'code', r.code, 'label', r.label, 'state', v_state,
      'blocking', v_state not in ('satisfied', 'expires_within_window'),
      'expires_on', v_expiry,
      'resolvable_by', case v_state
        when 'missing'                   then case when p_kind = 'engagement' then 'The organisation''s administrator'
                                                   else 'The person or their organisation''s administrator' end
        when 'scan_pending'              then 'Nobody yet: the file is being checked for malware'
        when 'not_reviewed'              then 'A document reviewer at this venue'
        when 'not_verified'              then 'A competency verifier at this venue'
        when 'more_information_required' then 'Whoever submitted the document'
        when 'not_accepted'              then 'Whoever submitted the document'
        when 'expired'                   then 'Whoever submitted the document, with a current version'
        else null end);
  end loop;
  return v_lines;
end $$;

create function authz.evidence_blocking(p_lines jsonb) returns boolean
language sql immutable
set search_path = ''
as $$ select exists (select 1 from jsonb_array_elements(p_lines) l where (l ->> 'blocking')::boolean) $$;

-- ---------------------------------------------------------------------------
-- Restrictions (P2-7)
-- ---------------------------------------------------------------------------

create function authz.person_restricted(p_person_id uuid, p_venue_id uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (select 1 from core.restriction
                  where person_id = p_person_id and venue_id = p_venue_id and status = 'active')
$$;

create function authz.organisation_restricted(p_organisation_id uuid, p_venue_id uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (select 1 from core.restriction
                  where organisation_id = p_organisation_id and venue_id = p_venue_id and status = 'active')
$$;

-- ---------------------------------------------------------------------------
-- Capacities: appointment_type.approve/reject need a root appointment (D-011)
-- ---------------------------------------------------------------------------

create or replace function authz.capacities(p_action text, p_target jsonb, p_person_id uuid) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_venue  uuid := (p_target ->> 'venue_id')::uuid;
  v_class  uuid := (p_target ->> 'permit_class_id')::uuid;
  v_record uuid := (p_target ->> 'record_id')::uuid;
  v_owner  uuid := (p_target ->> 'owner_appointment_id')::uuid;
  v_spec   jsonb := coalesce(p_target -> 'spec', '{}');
  v_item   authz.scope_item;
  v_result jsonb;
  v_t      record;
begin
  if p_action = 'appointment.grant' then
    select coalesce(jsonb_agg(jsonb_build_object('appointment_id', a.id)), '[]') into v_result
      from core.appointment a
      join core.appointment_type_version tv on tv.id = a.appointment_type_version_id
     where a.appointee_person_id = p_person_id
       and a.venue_id = v_venue
       and a.status = 'in_force' and now() <@ a.valid_during
       and 'appointment.grant' = any (tv.allowed_action_codes)
       and (select n.appointment_type_id from core.appointment_type_version n
             where n.id = (v_spec ->> 'type_version_id')::uuid) = any (tv.grantable_type_ids)
       and authz.json_uuids(v_spec -> 'permit_class_ids') <@ authz.appointment_class_ids(a.id)
       and authz.scopes_cover(authz.appointment_scope_items(a.id), authz.scope_items_from_json(v_spec -> 'scopes'))
       and tstzrange((v_spec ->> 'valid_from')::timestamptz, (v_spec ->> 'valid_to')::timestamptz) <@ a.valid_during;

  elsif p_action = 'appointment.revoke' then
    select t.id, tv.appointment_type_id into v_t
      from core.appointment t
      join core.appointment_type_version tv on tv.id = t.appointment_type_version_id
     where t.id = v_record;
    select coalesce(jsonb_agg(jsonb_build_object('appointment_id', a.id)), '[]') into v_result
      from core.appointment a
      join core.appointment_type_version tv on tv.id = a.appointment_type_version_id
     where a.appointee_person_id = p_person_id
       and a.venue_id = v_venue
       and a.id <> v_record
       and a.status = 'in_force' and now() <@ a.valid_during
       and 'appointment.revoke' = any (tv.allowed_action_codes)
       and v_t.appointment_type_id = any (tv.grantable_type_ids)
       and authz.appointment_class_ids(v_record) <@ authz.appointment_class_ids(a.id)
       and authz.scopes_cover(authz.appointment_scope_items(a.id), authz.appointment_scope_items(v_record));

  elsif p_action = 'delegation.grant' then
    select coalesce(jsonb_agg(jsonb_build_object('appointment_id', a.id)), '[]') into v_result
      from core.appointment a
      join core.appointment_type_version tv on tv.id = a.appointment_type_version_id
      join core.appointment d on d.id = (v_spec ->> 'delegate_appointment_id')::uuid
     where a.appointee_person_id = p_person_id
       and a.venue_id = v_venue
       and a.status = 'in_force' and now() <@ a.valid_during
       and 'delegation.grant' = any (tv.allowed_action_codes)
       and authz.json_texts(v_spec -> 'action_codes') <@ tv.allowed_action_codes
       and not exists (select 1 from unnest(authz.json_texts(v_spec -> 'action_codes')) c
                        where not exists (select 1 from core.authority_action x
                                           where x.code = c and x.delegable))
       and d.id <> a.id
       and d.venue_id = v_venue
       and d.appointee_person_id = (v_spec ->> 'delegate_person_id')::uuid
       and d.status = 'in_force' and now() <@ d.valid_during
       and authz.json_uuids(v_spec -> 'permit_class_ids') <@ authz.appointment_class_ids(a.id)
       and authz.json_uuids(v_spec -> 'permit_class_ids') <@ authz.appointment_class_ids(d.id)
       and authz.scopes_cover(authz.appointment_scope_items(a.id), authz.scope_items_from_json(v_spec -> 'scopes'))
       and authz.scopes_cover(authz.appointment_scope_items(d.id), authz.scope_items_from_json(v_spec -> 'scopes'));

  else
    v_item := authz.target_item(v_venue, (p_target ->> 'area_id')::uuid, (p_target ->> 'system_id')::uuid);
    select coalesce(jsonb_agg(c), '[]') into v_result from (
      select jsonb_build_object('appointment_id', a.id) as c
        from core.appointment a
        join core.appointment_type_version tv on tv.id = a.appointment_type_version_id
       where a.appointee_person_id = p_person_id
         and a.venue_id = v_venue
         and a.status = 'in_force' and now() <@ a.valid_during
         and p_action = any (tv.allowed_action_codes)
         and (p_action not in ('appointment_type.approve', 'appointment_type.reject') or a.is_root)
         and (v_class is null or v_class = any (authz.appointment_class_ids(a.id)))
         and authz.items_match(authz.appointment_scope_items(a.id), v_item)
         and (v_owner is null or a.id = v_owner
              or tv.appointment_type_id = (select ov.appointment_type_id
                                             from core.appointment o
                                             join core.appointment_type_version ov on ov.id = o.appointment_type_version_id
                                            where o.id = v_owner))
      union all
      select jsonb_build_object('delegation_id', g.id)
        from core.delegation g
       where g.delegate_person_id = p_person_id
         and g.venue_id = v_venue
         and g.status = 'in_force' and now() <@ g.valid_during
         and p_action = any (g.action_codes)
         and (g.target_id is null or g.target_id = v_record)
         and (v_class is null or v_class = any (g.permit_class_ids))
         and authz.items_match(authz.delegation_scope_items(g.id), v_item)
         and authz.appointment_in_force(g.delegator_appointment_id)
         and authz.appointment_in_force(g.delegate_appointment_id)
         and (v_owner is null or g.delegator_appointment_id = v_owner)
    ) s;
  end if;
  return v_result;
end $$;

-- ---------------------------------------------------------------------------
-- Evaluate
-- ---------------------------------------------------------------------------

create or replace function authz.evaluate(
  p_action                text,
  p_target                jsonb,
  p_acting_appointment_id uuid default null,
  p_acting_delegation_id  uuid default null
) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_action   core.authority_action;
  v_customer uuid := (p_target ->> 'customer_id')::uuid;
  v_venue    uuid := (p_target ->> 'venue_id')::uuid;
  v_org      uuid := (p_target ->> 'organisation_id')::uuid;
  v_person   uuid;
  v_excluded uuid[] := authz.json_uuids(p_target -> 'excluded_person_ids');
  v_caps     jsonb;
  v_cap      jsonb;
  v_base     jsonb;
  v_inv      core.invitation;
  v_lines    jsonb;
  v_spec     jsonb := coalesce(p_target -> 'spec', '{}');
  v_not_found constant text := 'The record does not exist or you do not have access to it.';
begin
  select * into v_action from core.authority_action where code = p_action;
  if not found then
    return authz.deny(p_action, 'unknown_action', 'This action is not recognised.', 'A valid action', 'Octra support');
  end if;
  v_base := jsonb_build_object('ok', true, 'allowed', true, 'action', p_action, 'basis', v_action.basis);

  if v_action.basis = 'derived' then
    return authz.deny(p_action, 'derived_only', 'This happens only as part of another decision.',
                      'The decision it belongs to', 'Nobody: use the parent action');
  end if;

  if auth.uid() is null then
    return authz.deny(p_action, 'not_authenticated', 'You are not signed in.', 'A signed-in account', 'Sign in and try again');
  end if;

  if v_action.basis = 'platform_admin' then
    if not authz.is_platform_admin() then
      return authz.deny(p_action, 'not_platform_admin',
        'Only an Octra platform administrator can do this.', 'Platform administrator role', 'Octra platform operations');
    end if;
    return v_base || jsonb_build_object('actor_kind', 'platform_admin');
  end if;

  if v_action.basis = 'service' then
    if not exists (select 1 from core.service_account sa
                     join core.service_action s on s.purpose = sa.purpose
                    where sa.auth_user_id = auth.uid() and sa.revoked_at is null and s.action_code = p_action) then
      return authz.deny(p_action, 'not_service', 'Only the platform service responsible can do this.',
                        'A registered service account', 'Octra platform operations');
    end if;
    return v_base || jsonb_build_object('actor_kind', 'service');
  end if;

  if v_action.basis = 'invitee' then
    select * into v_inv from core.invitation where id = (p_target ->> 'record_id')::uuid;
    if v_inv.id is null or v_inv.token_hash is distinct from decode(p_target ->> 'token_hash', 'hex') then
      return authz.deny(p_action, 'not_found', v_not_found, 'A valid invitation link', 'Whoever invited you');
    end if;
    if v_inv.status <> 'pending' then
      return authz.deny(p_action, 'invitation_not_pending',
        'This invitation has already been used, declined or cancelled.', 'A current invitation', 'Whoever invited you');
    end if;
    if now() >= v_inv.expires_at then
      return authz.deny(p_action, 'invitation_expired', 'This invitation has expired.', 'A new invitation',
                        'Whoever invited you');
    end if;
    if (select lower(u.email) from auth.users u where u.id = auth.uid()) is distinct from v_inv.invitee_email then
      return authz.deny(p_action, 'invitation_wrong_account',
        'This invitation was sent to a different email address. Sign in with the address it was sent to.',
        'The account the invitation was sent to', 'Whoever invited you, if the address was wrong');
    end if;
    return v_base || jsonb_build_object('actor_kind', 'user',
                                        'actor_person_id', authz.actor_person(v_inv.customer_id));
  end if;

  if v_customer is null or not exists (select 1 from core.customer where id = v_customer) then
    return authz.deny(p_action, 'not_found', v_not_found, 'Access to this record',
                      'A tenant administrator for your organisation');
  end if;
  v_person := authz.actor_person(v_customer);
  if v_person is null then
    return authz.deny(p_action, 'not_found', v_not_found, 'Access to this record',
                      'A tenant administrator for your organisation');
  end if;
  v_base := v_base || jsonb_build_object('actor_person_id', v_person);

  -- Separation-of-duties floor (D-007): fixed in code, never configurable.
  if v_person = any (v_excluded) then
    return authz.deny(p_action, 'separation_of_duties',
      'You submitted, authored or are the subject of this record, or work for the organisation it concerns, so you cannot also make this decision.',
      'A decision by a different, appropriately authorised person', 'Another person holding the required authority');
  end if;

  -- A restricted organisation cannot be newly engaged or approved at that venue.
  if p_action in ('engagement.create', 'engagement.approve', 'invitation.resolve_match')
     and v_org is not null and v_venue is not null and authz.organisation_restricted(v_org, v_venue) then
    return authz.deny(p_action, 'organisation_restricted',
      'This organisation is restricted at this venue, so it cannot be engaged or approved here.',
      'The restriction to be lifted', 'The authority that imposed the restriction');
  end if;

  if v_action.basis = 'tenant_admin' then
    if v_customer not in (select authz.my_admin_customer_ids()) then
      return authz.deny(p_action, 'not_tenant_admin',
        'Only a tenant administrator can do this.', 'Tenant administrator role for this customer',
        'A tenant administrator for this customer');
    end if;
    -- D-011: direct publication is only for setting up a venue with no root appointment.
    if p_action = 'appointment_type.publish' and exists (
         select 1 from core.appointment a where a.venue_id = v_venue and a.is_root and a.status <> 'revoked') then
      return authz.deny(p_action, 'bootstrap_closed',
        'This venue has a root appointment, so new appointment type versions must be proposed and approved by the root appointee.',
        'Approval by the venue''s root appointee', 'The venue''s root appointee');
    end if;
    return v_base || jsonb_build_object('actor_kind', 'tenant_admin');
  end if;

  if v_action.basis = 'subject' then
    if v_person is distinct from (p_target ->> 'subject_person_id')::uuid then
      return authz.deny(p_action, 'not_subject',
        'Only the person this record concerns can do this.', 'To be the person this record concerns',
        'The person this record concerns');
    end if;
    return v_base || jsonb_build_object('actor_kind', 'user');
  end if;

  if v_action.basis = 'organisation_admin' then
    if not exists (select 1 from core.organisation_admin oa
                    where oa.organisation_id = v_org and oa.person_id = v_person
                      and oa.revoked_at is null and now() <@ oa.valid_during
                      and (oa.role = 'accountable' or not coalesce((p_target ->> 'require_accountable')::boolean, false))) then
      return authz.deny(p_action, 'not_organisation_admin',
        case when coalesce((p_target ->> 'require_accountable')::boolean, false)
             then 'Only the organisation''s accountable administrator can do this.'
             else 'Only an administrator of this organisation can do this.' end,
        'Administrator role for this organisation', 'The organisation''s accountable administrator');
    end if;
    if p_target ? 'person_id' and not exists (
         select 1 from core.person_organisation_relationship r
          where r.person_id = (p_target ->> 'person_id')::uuid and r.organisation_id = v_org
            and r.status = 'active' and now() <@ r.valid_during) then
      return authz.deny(p_action, 'person_not_in_organisation',
        'This person does not currently work with your organisation.', 'An active relationship with this person',
        'The person, by accepting an invitation from your organisation');
    end if;
    return v_base || jsonb_build_object('actor_kind', 'organisation_admin');
  end if;

  -- Appointment basis. Administrator rights play no part from here on.
  if v_venue is null then
    raise exception 'appointment-based actions need a venue in the target' using errcode = '22023';
  end if;

  if authz.person_restricted(v_person, v_venue) then
    return authz.deny(p_action, 'person_restricted',
      'You are restricted at this venue, so you cannot use your appointments here.',
      'The restriction to be lifted', 'The authority that imposed the restriction');
  end if;

  v_caps := authz.capacities(p_action, p_target, v_person);

  if p_acting_appointment_id is not null or p_acting_delegation_id is not null then
    select c into v_cap from jsonb_array_elements(v_caps) c
     where (p_acting_appointment_id is not null and (c ->> 'appointment_id')::uuid = p_acting_appointment_id)
        or (p_acting_delegation_id is not null and (c ->> 'delegation_id')::uuid = p_acting_delegation_id)
     limit 1;
    if v_cap is null and not exists (
         select 1 from core.appointment a
          where a.id = p_acting_appointment_id and a.appointee_person_id = v_person
         union all
         select 1 from core.delegation d
          where d.id = p_acting_delegation_id and d.delegate_person_id = v_person) then
      return authz.deny(p_action, 'capacity_not_valid',
        'The capacity you chose is not one of your appointments or delegations.',
        'One of your own current appointments or delegations',
        'Choose another capacity');
    end if;
  elsif jsonb_array_length(v_caps) = 1 then
    v_cap := v_caps -> 0;
  elsif jsonb_array_length(v_caps) > 1 then
    return authz.deny(p_action, 'capacity_selection_required',
      'More than one of your appointments covers this action. Choose the capacity you are acting in.',
      'An explicit choice of capacity', 'You', jsonb_build_object('options', v_caps));
  end if;

  if v_cap is null then
    return authz.deny(p_action, 'no_covering_appointment',
      case p_action
        when 'appointment.grant' then
          'Your appointments do not let you make this appointment: its type, permit classes, area or system scope, or dates go beyond what you hold.'
        when 'appointment.revoke' then
          'Your appointments do not cover this appointment, so you cannot revoke it.'
        when 'delegation.grant' then
          'This delegation goes beyond your appointment or the delegate''s own appointment, or includes an action that cannot be delegated.'
        when 'engagement.reinstate' then
          'Only the authority that imposed this restriction, an equivalent appointment holder, or their delegate can lift it.'
        when 'person.lift_restriction' then
          'Only the authority that imposed this restriction, an equivalent appointment holder, or their delegate can lift it.'
        when 'organisation.lift_restriction' then
          'Only the authority that imposed this restriction, an equivalent appointment holder, or their delegate can lift it.'
        when 'appointment_type.approve' then
          'Only the venue''s root appointee can approve appointment type versions.'
        when 'appointment_type.reject' then
          'Only the venue''s root appointee can reject appointment type versions.'
        else
          format('No current appointment or delegation of yours covers "%s" for this place, system, permit class and time.',
                 v_action.description)
      end,
      'An in-force appointment, or a delegation backed by your own appointment, covering this action',
      'The venue''s appointing authority for this scope');
  end if;

  -- Evidence the decision actually needs, for its actual dates (Q39).
  if p_action = 'engagement.approve' then
    v_lines := authz.evidence_lines(v_venue, 'engagement', p_target ->> 'capacity_code', v_org, null,
                                    (p_target ->> 'window')::tstzrange);
  elsif p_action = 'appointment.grant' then
    v_lines := authz.evidence_lines(v_venue, 'appointment',
                 (select n.appointment_type_id::text from core.appointment_type_version n
                   where n.id = (v_spec ->> 'type_version_id')::uuid),
                 null, (v_spec ->> 'appointee_person_id')::uuid,
                 tstzrange((v_spec ->> 'valid_from')::timestamptz, (v_spec ->> 'valid_to')::timestamptz));
  end if;
  if v_lines is not null and authz.evidence_blocking(v_lines) then
    return authz.deny(p_action, 'evidence_incomplete',
      'The evidence this decision needs is not all in place for its dates.',
      'Each blocking item listed', 'As listed for each item', jsonb_build_object('evidence', v_lines));
  end if;

  return v_base || jsonb_build_object(
    'actor_kind', 'user',
    'acting_appointment_id', v_cap -> 'appointment_id',
    'acting_delegation_id', v_cap -> 'delegation_id')
    || case when v_lines is not null then jsonb_build_object('evidence', v_lines) else '{}'::jsonb end;
end $$;

-- ---------------------------------------------------------------------------
-- Derived decisions: a child decision inside an authorised parent decision
-- ---------------------------------------------------------------------------

create function authz.derive(p_child_action text, p_target_type text, p_target_id uuid) returns uuid
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_parent core.decision_context;
  v_id     uuid := gen_random_uuid();
begin
  select * into v_parent from core.decision_context where id = core.ctx_uuid('decision_context_id');
  if v_parent.id is null or v_parent.xact_id <> pg_current_xact_id() then
    raise exception 'a derived decision needs an authorised parent decision in this transaction'
      using errcode = 'insufficient_privilege';
  end if;
  -- Derive from the top-level decision, never from another derived one.
  if v_parent.parent_id is not null then
    select * into v_parent from core.decision_context where id = v_parent.parent_id;
  end if;
  if not exists (select 1 from core.derived_action
                  where parent_action = v_parent.action_code and child_action = p_child_action) then
    raise exception '% cannot be derived from %', p_child_action, v_parent.action_code
      using errcode = 'insufficient_privilege';
  end if;

  perform set_config('octra.authz_writing', v_id::text, true);
  insert into core.decision_context (
    id, customer_id, venue_id, actor_user_id, actor_person_id, actor_kind, action_code, basis,
    target_type, target_id, acting_appointment_id, acting_delegation_id, evaluation,
    idempotency_key, request_hash, parent_id)
  values (
    v_id, v_parent.customer_id, v_parent.venue_id, v_parent.actor_user_id, v_parent.actor_person_id,
    v_parent.actor_kind, p_child_action, 'derived', p_target_type, p_target_id,
    v_parent.acting_appointment_id, v_parent.acting_delegation_id,
    jsonb_build_object('derived_from', v_parent.id),
    'derived:' || v_parent.id || ':' || p_target_id, v_parent.request_hash, v_parent.id);
  perform set_config('octra.authz_writing', '', true);
  perform set_config('octra.decision_context_id', v_id::text, true);
  return v_id;
end $$;

-- Returns the transaction context to a parent decision after derived writes.
create function authz.resume(p_decision_context_id uuid) returns void
language plpgsql volatile security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from core.decision_context
                  where id = p_decision_context_id and xact_id = pg_current_xact_id()) then
    raise exception 'can only resume a decision made in this transaction' using errcode = 'insufficient_privilege';
  end if;
  perform set_config('octra.decision_context_id', p_decision_context_id::text, true);
end $$;

-- ---------------------------------------------------------------------------
-- Appointments must use an approved type version in force (D-011)
-- ---------------------------------------------------------------------------

create or replace function core.appointment_complete() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_type core.appointment_type_version;
begin
  select * into v_type from core.appointment_type_version where id = new.appointment_type_version_id;
  if v_type.status <> 'approved' or v_type.effective_from > now() or exists (
       select 1 from core.appointment_type_version later
        where later.appointment_type_id = v_type.appointment_type_id
          and later.status = 'approved'
          and later.effective_from > v_type.effective_from
          and later.effective_from <= now()) then
    raise exception 'an appointment must use the approved appointment type version currently in force'
      using errcode = 'check_violation';
  end if;
  if not exists (select 1 from core.appointment_scope where appointment_id = new.id) then
    raise exception 'an appointment needs at least one area or system scope' using errcode = 'check_violation';
  end if;
  if exists (select 1 from core.appointment_permit_class c
              where c.appointment_id = new.id and c.permit_class_id <> all (v_type.eligible_permit_class_ids)) then
    raise exception 'appointment names a permit class its type does not allow' using errcode = 'check_violation';
  end if;
  if exists (select 1 from core.appointment_scope s
               left join core.system sy on sy.id = s.system_id
              where s.appointment_id = new.id
                and coalesce(s.system_type_id, sy.system_type_id) is not null
                and coalesce(s.system_type_id, sy.system_type_id) <> all (v_type.eligible_system_type_ids)) then
    raise exception 'appointment names a system type its type does not allow' using errcode = 'check_violation';
  end if;
  if v_type.requires_competence_evidence
     and not exists (select 1 from core.appointment_evidence where appointment_id = new.id) then
    raise exception 'this appointment type requires a competence evidence reference' using errcode = 'check_violation';
  end if;
  if new.is_root and not v_type.is_root_eligible then
    raise exception 'this appointment type cannot be used for a root appointment' using errcode = 'check_violation';
  end if;
  return null;
end $$;

-- The previous ordering rule counted rejected versions; only live ones count now.
create or replace function core.appointment_type_version_validate() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_bad text;
begin
  select string_agg(c, ', ') into v_bad
    from unnest(new.allowed_action_codes) c
   where not exists (select 1 from core.authority_action a where a.code = c and a.basis = 'appointment');
  if v_bad is not null then
    raise exception 'not an appointment-based action: %', v_bad using errcode = 'check_violation';
  end if;
  if exists (select 1 from unnest(new.eligible_permit_class_ids) x
              where not exists (select 1 from core.permit_class p where p.id = x and p.venue_id = new.venue_id)) then
    raise exception 'eligible permit classes must belong to this venue' using errcode = 'check_violation';
  end if;
  if exists (select 1 from unnest(new.eligible_system_type_ids) x
              where not exists (select 1 from core.system_type s where s.id = x and s.venue_id = new.venue_id)) then
    raise exception 'eligible system types must belong to this venue' using errcode = 'check_violation';
  end if;
  if exists (select 1 from unnest(new.grantable_type_ids) x
              where not exists (select 1 from core.appointment_type t where t.id = x and t.venue_id = new.venue_id)) then
    raise exception 'grantable appointment types must belong to this venue' using errcode = 'check_violation';
  end if;
  if exists (select 1 from core.appointment_type_version v
              where v.appointment_type_id = new.appointment_type_id
                and v.status <> 'rejected'
                and v.effective_from >= new.effective_from) then
    raise exception 'a new version must take effect after the previous one' using errcode = 'check_violation';
  end if;
  new.version_no := coalesce((select max(version_no) from core.appointment_type_version
                               where appointment_type_id = new.appointment_type_id), 0) + 1;
  return new;
end $$;
