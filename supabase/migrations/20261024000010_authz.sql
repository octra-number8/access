-- 0010 The single authorisation service (D-003)
--
-- Every write through the API calls authz.require(). Membership helpers here are
-- also the only inputs to RLS policies (0011). Administrator rights are an input
-- only to tenant_admin- and platform_admin-basis actions, never to an
-- appointment-basis action (invariant 9).
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only
-- (functions are replaced with `create or replace` in a new migration).

create type authz.scope_item as (
  area_id             uuid,
  include_descendants boolean,
  system_id           uuid,
  system_type_id      uuid,
  restrict_to_area_id uuid
);

-- ---------------------------------------------------------------------------
-- Who is acting
-- ---------------------------------------------------------------------------

create function authz.my_person_ids() returns setof uuid
language sql stable security definer
set search_path = ''
as $$
  select ua.person_id
    from core.user_account ua
    join core.person p on p.id = ua.person_id
   where ua.auth_user_id = auth.uid()
     and ua.disabled_at is null
     and p.deactivated_at is null
$$;

create function authz.actor_person(p_customer_id uuid) returns uuid
language sql stable security definer
set search_path = ''
as $$
  select ua.person_id
    from core.user_account ua
    join core.person p on p.id = ua.person_id
   where ua.auth_user_id = auth.uid()
     and ua.customer_id = p_customer_id
     and ua.disabled_at is null
     and p.deactivated_at is null
$$;

create function authz.is_platform_admin() returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (select 1 from core.platform_admin
                  where auth_user_id = auth.uid() and revoked_at is null)
$$;

create function authz.my_admin_customer_ids() returns setof uuid
language sql stable security definer
set search_path = ''
as $$
  select ta.customer_id
    from core.tenant_admin ta
   where ta.person_id in (select authz.my_person_ids())
     and ta.revoked_at is null
     and now() <@ ta.valid_during
$$;

create function authz.my_break_glass_customer_ids() returns setof uuid
language sql stable security definer
set search_path = ''
as $$
  select g.customer_id
    from core.break_glass_grant g
   where g.platform_admin_user_id = auth.uid()
     and now() <@ g.valid_during
     and authz.is_platform_admin()
$$;

-- Tenant administrators, plus platform administrators under an open break-glass grant.
create function authz.my_oversight_customer_ids() returns setof uuid
language sql stable security definer
set search_path = ''
as $$
  select authz.my_admin_customer_ids()
  union
  select authz.my_break_glass_customer_ids()
$$;

-- Venues where I hold a current or pending appointment.
create function authz.my_appointee_venue_ids() returns setof uuid
language sql stable security definer
set search_path = ''
as $$
  select a.venue_id
    from core.appointment a
   where a.appointee_person_id in (select authz.my_person_ids())
     and a.status <> 'revoked'
     and (upper_inf(a.valid_during) or upper(a.valid_during) > now())
$$;

create function authz.my_organisation_ids() returns setof uuid
language sql stable security definer
set search_path = ''
as $$
  select r.organisation_id
    from core.person_organisation_relationship r
   where r.person_id in (select authz.my_person_ids())
     and r.revoked_at is null
     and now() <@ r.valid_during
$$;

create function authz.my_engaged_venue_ids() returns setof uuid
language sql stable security definer
set search_path = ''
as $$
  select e.venue_id
    from core.engagement e
   where e.organisation_id in (select authz.my_organisation_ids())
     and e.status <> 'ended'
     and now() <@ e.valid_during
$$;

create function authz.my_venue_ids() returns setof uuid
language sql stable security definer
set search_path = ''
as $$
  select v.id from core.venue v where v.customer_id in (select authz.my_oversight_customer_ids())
  union
  select authz.my_appointee_venue_ids()
  union
  select authz.my_engaged_venue_ids()
$$;

create function authz.my_customer_ids() returns setof uuid
language sql stable security definer
set search_path = ''
as $$
  select authz.my_oversight_customer_ids()
  union
  select p.customer_id from core.person p where p.id in (select authz.my_person_ids())
$$;

-- Organisations engaged at venues where I hold an appointment.
create function authz.visible_organisation_ids() returns setof uuid
language sql stable security definer
set search_path = ''
as $$
  select e.organisation_id
    from core.engagement e
   where e.venue_id in (select authz.my_appointee_venue_ids())
     and e.status <> 'ended'
$$;

-- People related to those organisations, and people holding appointments at venues
-- I can see (so "who can resolve this" can be answered by name).
create function authz.visible_person_ids() returns setof uuid
language sql stable security definer
set search_path = ''
as $$
  select r.person_id
    from core.person_organisation_relationship r
   where r.organisation_id in (select authz.visible_organisation_ids())
     and r.revoked_at is null
  union
  select a.appointee_person_id
    from core.appointment a
   where a.venue_id in (select authz.my_venue_ids())
     and a.status <> 'revoked'
$$;

-- ---------------------------------------------------------------------------
-- Scope (D-008)
-- ---------------------------------------------------------------------------

-- Inclusive: an area is within itself.
create function authz.area_within(p_area_id uuid, p_ancestor_id uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select p_area_id = p_ancestor_id
      or exists (select 1 from core.area a where a.id = p_area_id and p_ancestor_id = any (a.path))
$$;

create function authz.restriction_contains(p_container_area_id uuid, p_item_area_id uuid) returns boolean
language sql stable
set search_path = ''
as $$
  select p_container_area_id is null
      or (p_item_area_id is not null and authz.area_within(p_item_area_id, p_container_area_id))
$$;

-- Does scope item c contain scope item x? Area authority never contains system
-- authority, and system authority never contains area authority.
create function authz.scope_contains(c authz.scope_item, x authz.scope_item) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select coalesce(case
    when c.area_id is not null then
      x.area_id is not null and (
        (x.area_id = c.area_id and (c.include_descendants or not coalesce(x.include_descendants, false)))
        or (c.include_descendants and x.area_id <> c.area_id and authz.area_within(x.area_id, c.area_id)))
    when c.system_id is not null then
      x.system_id is not null and x.system_id = c.system_id
      and authz.restriction_contains(c.restrict_to_area_id, x.restrict_to_area_id)
    when c.system_type_id is not null then
      (x.system_type_id = c.system_type_id
       or (x.system_id is not null and exists (
             select 1 from core.system s where s.id = x.system_id and s.system_type_id = c.system_type_id)))
      and authz.restriction_contains(c.restrict_to_area_id, x.restrict_to_area_id)
    else false
  end, false)
$$;

create function authz.items_match(p_containers authz.scope_item[], p_item authz.scope_item) returns boolean
language sql stable
set search_path = ''
as $$
  select exists (select 1 from generate_subscripts(p_containers, 1) j
                  where authz.scope_contains(p_containers[j], p_item))
$$;

create function authz.scopes_cover(p_containers authz.scope_item[], p_items authz.scope_item[]) returns boolean
language sql stable
set search_path = ''
as $$
  select cardinality(p_items) > 0
     and not exists (select 1 from generate_subscripts(p_items, 1) i
                      where not authz.items_match(p_containers, p_items[i]))
$$;

create function authz.appointment_scope_items(p_appointment_id uuid) returns authz.scope_item[]
language sql stable security definer
set search_path = ''
as $$
  select coalesce(array_agg(row(s.area_id, s.include_descendants, s.system_id, s.system_type_id,
                                s.restrict_to_area_id)::authz.scope_item), '{}')
    from core.appointment_scope s where s.appointment_id = p_appointment_id
$$;

create function authz.delegation_scope_items(p_delegation_id uuid) returns authz.scope_item[]
language sql stable security definer
set search_path = ''
as $$
  select coalesce(array_agg(row(s.area_id, s.include_descendants, s.system_id, s.system_type_id,
                                s.restrict_to_area_id)::authz.scope_item), '{}')
    from core.delegation_scope s where s.delegation_id = p_delegation_id
$$;

create function authz.scope_items_from_json(p_scopes jsonb) returns authz.scope_item[]
language sql immutable
set search_path = ''
as $$
  select coalesce(array_agg(row(
           (e ->> 'area_id')::uuid,
           coalesce((e ->> 'include_descendants')::boolean, true),
           (e ->> 'system_id')::uuid,
           (e ->> 'system_type_id')::uuid,
           (e ->> 'restrict_to_area_id')::uuid)::authz.scope_item), '{}')
    from jsonb_array_elements(coalesce(p_scopes, '[]')) e
$$;

create function authz.json_uuids(p jsonb) returns uuid[]
language sql immutable
set search_path = ''
as $$
  select coalesce(array_agg(x::uuid), '{}') from jsonb_array_elements_text(coalesce(p, '[]')) x
$$;

create function authz.json_texts(p jsonb) returns text[]
language sql immutable
set search_path = ''
as $$
  select coalesce(array_agg(x), '{}') from jsonb_array_elements_text(coalesce(p, '[]')) x
$$;

-- A target with no area and no system is a venue-level target: it needs authority
-- over the venue's root area.
create function authz.target_item(p_venue_id uuid, p_area_id uuid, p_system_id uuid) returns authz.scope_item
language sql stable security definer
set search_path = ''
as $$
  select case
    when p_system_id is not null then row(null, false, p_system_id, null, p_area_id)::authz.scope_item
    else row(coalesce(p_area_id, (select a.id from core.area a
                                   where a.venue_id = p_venue_id and a.parent_id is null)),
             false, null, null, null)::authz.scope_item
  end
$$;

create function authz.appointment_in_force(p_appointment_id uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (select 1 from core.appointment a
                  where a.id = p_appointment_id and a.status = 'in_force' and now() <@ a.valid_during)
$$;

create function authz.appointment_class_ids(p_appointment_id uuid) returns uuid[]
language sql stable security definer
set search_path = ''
as $$
  select coalesce(array_agg(c.permit_class_id), '{}')
    from core.appointment_permit_class c where c.appointment_id = p_appointment_id
$$;

-- ---------------------------------------------------------------------------
-- Capacities: which of the actor's appointments or delegations cover an action
-- ---------------------------------------------------------------------------

create function authz.capacities(p_action text, p_target jsonb, p_person_id uuid) returns jsonb
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
    -- Type must be grantable by the appointer's type; classes, scope and window may
    -- never widen beyond the appointer's own appointment.
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
    -- Actions come from the delegator's appointment and must be delegable. Classes
    -- and scope must sit within both the delegator's appointment and the delegate's
    -- own appointment (invariant 7). Delegation is never re-delegable because
    -- delegation.grant itself is not delegable.
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
    -- v_owner, when present, is the appointment that imposed a restriction. Only it,
    -- an appointment of the same type, or a delegation from it may lift it
    -- (invariant 7).
    select coalesce(jsonb_agg(c), '[]') into v_result from (
      select jsonb_build_object('appointment_id', a.id) as c
        from core.appointment a
        join core.appointment_type_version tv on tv.id = a.appointment_type_version_id
       where a.appointee_person_id = p_person_id
         and a.venue_id = v_venue
         and a.status = 'in_force' and now() <@ a.valid_during
         and p_action = any (tv.allowed_action_codes)
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
-- Evaluate and require
-- ---------------------------------------------------------------------------

create function authz.deny(p_action text, p_code text, p_reason text, p_missing text, p_resolvable_by text,
                           p_extra jsonb default '{}')
returns jsonb
language sql immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'ok', false, 'allowed', false, 'action', p_action, 'code', p_code,
    'reason', p_reason, 'missing', p_missing, 'resolvable_by', p_resolvable_by) || p_extra
$$;

-- Read-only: may this user take this action on this target now, and in which
-- capacity? Returns a structured explanation either way (CLAUDE.md §6).
create function authz.evaluate(
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
  v_person   uuid;
  v_excluded uuid[] := authz.json_uuids(p_target -> 'excluded_person_ids');
  v_caps     jsonb;
  v_cap      jsonb;
  v_base     jsonb;
begin
  select * into v_action from core.authority_action where code = p_action;
  if not found then
    return authz.deny(p_action, 'unknown_action', 'This action is not recognised.', 'A valid action', 'Octra support');
  end if;
  v_base := jsonb_build_object('ok', true, 'allowed', true, 'action', p_action, 'basis', v_action.basis);

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

  if v_customer is null or not exists (select 1 from core.customer where id = v_customer) then
    return authz.deny(p_action, 'not_found', 'The record does not exist or you do not have access to it.',
                      'Access to this record', 'A tenant administrator for your organisation');
  end if;
  v_person := authz.actor_person(v_customer);
  if v_person is null then
    -- Same answer as a missing record, so other tenants' records are not disclosed.
    return authz.deny(p_action, 'not_found', 'The record does not exist or you do not have access to it.',
                      'Access to this record', 'A tenant administrator for your organisation');
  end if;
  v_base := v_base || jsonb_build_object('actor_person_id', v_person);

  -- Separation-of-duties floor (D-007): fixed in code, never configurable.
  if v_person = any (v_excluded) then
    return authz.deny(p_action, 'separation_of_duties',
      'You submitted, authored or are the subject of this record, so you cannot also make this decision.',
      'A decision by a different, appropriately authorised person', 'Another person holding the required authority');
  end if;

  if v_action.basis = 'tenant_admin' then
    if v_customer not in (select authz.my_admin_customer_ids()) then
      return authz.deny(p_action, 'not_tenant_admin',
        'Only a tenant administrator can do this.', 'Tenant administrator role for this customer',
        'A tenant administrator for this customer');
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

  -- Appointment basis. Administrator rights play no part from here on.
  if v_venue is null then
    raise exception 'appointment-based actions need a venue in the target' using errcode = '22023';
  end if;
  v_caps := authz.capacities(p_action, p_target, v_person);

  if p_acting_appointment_id is not null or p_acting_delegation_id is not null then
    select c into v_cap from jsonb_array_elements(v_caps) c
     where (p_acting_appointment_id is not null and (c ->> 'appointment_id')::uuid = p_acting_appointment_id)
        or (p_acting_delegation_id is not null and (c ->> 'delegation_id')::uuid = p_acting_delegation_id)
     limit 1;
    -- A capacity that is not the user's own is simply invalid. If it is their own,
    -- fall through to the specific explanation of what it does not cover.
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
        else
          format('No current appointment or delegation of yours covers "%s" for this place, system, permit class and time.',
                 v_action.description)
      end,
      'An in-force appointment, or a delegation backed by your own appointment, covering this action',
      'The venue''s appointing authority for this scope');
  end if;

  return v_base || jsonb_build_object(
    'actor_kind', 'user',
    'acting_appointment_id', v_cap -> 'appointment_id',
    'acting_delegation_id', v_cap -> 'delegation_id');
end $$;

-- Evaluates, and on success writes the decision context and sets the transaction
-- context that the status guard and audit rely on. Denials are returned (not
-- raised) so the audit record of the attempt is kept.
create function authz.require(
  p_action                text,
  p_target                jsonb,
  p_idempotency_key       text,
  p_request               jsonb,
  p_acting_appointment_id uuid default null,
  p_acting_delegation_id  uuid default null
) returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_id        uuid := gen_random_uuid();
  v_target_id uuid := (p_target ->> 'record_id')::uuid;
  v_customer  uuid := (p_target ->> 'customer_id')::uuid;
  v_hash      bytea;
  v_prior     core.decision_context;
  v_eval      jsonb;
begin
  if p_idempotency_key is null or length(p_idempotency_key) not between 8 and 200 then
    raise exception 'an idempotency key of 8 to 200 characters is required' using errcode = '22023';
  end if;
  if v_target_id is null or p_target ->> 'target_type' is null then
    raise exception 'target record_id and target_type are required' using errcode = '22023';
  end if;

  v_hash := sha256(convert_to(jsonb_build_object(
    'action', p_action, 'request', p_request,
    'appointment', p_acting_appointment_id, 'delegation', p_acting_delegation_id)::text, 'UTF8'));

  select * into v_prior from core.decision_context
   where actor_user_id = auth.uid() and action_code = p_action and idempotency_key = p_idempotency_key;
  if found then
    if v_prior.request_hash = v_hash then
      return jsonb_build_object('ok', true, 'allowed', true, 'replayed', true, 'action', p_action,
                                'decision_context_id', v_prior.id, 'id', v_prior.target_id);
    end if;
    return authz.deny(p_action, 'idempotency_key_reused',
      'This request key was already used for a different request.',
      'A new request key', 'Retry with a fresh request key');
  end if;

  v_eval := authz.evaluate(p_action, p_target, p_acting_appointment_id, p_acting_delegation_id);

  if not (v_eval ->> 'allowed')::boolean then
    perform audit.record('authz.denied',
      case when exists (select 1 from core.customer where id = v_customer) then v_customer end,
      (p_target ->> 'venue_id')::uuid,
      p_target ->> 'target_type', v_target_id, v_eval ->> 'code',
      jsonb_build_object('evaluation', v_eval,
                         'acting_appointment_id', p_acting_appointment_id,
                         'acting_delegation_id', p_acting_delegation_id));
    return v_eval;
  end if;

  perform set_config('octra.decision_context_id', v_id::text, true);
  perform set_config('octra.actor_kind', v_eval ->> 'actor_kind', true);
  perform set_config('octra.actor_person_id', coalesce(v_eval ->> 'actor_person_id', ''), true);
  perform set_config('octra.acting_appointment_id', coalesce(v_eval ->> 'acting_appointment_id', ''), true);
  perform set_config('octra.acting_delegation_id', coalesce(v_eval ->> 'acting_delegation_id', ''), true);
  perform set_config('octra.authz_writing', v_id::text, true);

  insert into core.decision_context (
    id, customer_id, venue_id, actor_user_id, actor_person_id, actor_kind, action_code, basis,
    target_type, target_id, acting_appointment_id, acting_delegation_id, evaluation,
    idempotency_key, request_hash)
  values (
    v_id, v_customer, (p_target ->> 'venue_id')::uuid, auth.uid(), (v_eval ->> 'actor_person_id')::uuid,
    v_eval ->> 'actor_kind', p_action, v_eval ->> 'basis',
    p_target ->> 'target_type', v_target_id,
    (v_eval ->> 'acting_appointment_id')::uuid, (v_eval ->> 'acting_delegation_id')::uuid, v_eval,
    p_idempotency_key, v_hash);

  perform set_config('octra.authz_writing', '', true);

  return v_eval || jsonb_build_object('replayed', false, 'decision_context_id', v_id, 'id', v_target_id);
end $$;
