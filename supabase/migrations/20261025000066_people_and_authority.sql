-- 0066 People and authority screens (S1a, D-026)
--
-- What the S1a screens need that the API did not have:
--   - Staff invitations (S1-2): a tenant administrator gives one of the customer's own people a
--     login. The invitation names an existing person record; accepting links the invitee's login
--     to it. Nothing else changes: a login grants nothing (invariant 9).
--   - Revoking a tenant administrator (S1-3): never oneself, never the last one.
--   - Reads for the screens: the venue's authority overview, a person's own appointments, and the
--     choices offered when granting or delegating from an appointment. The choices are a
--     convenience; api.grant_appointment and api.grant_delegation re-check everything.
--
-- Rollback / recovery: forward-only. To withdraw, restore api.accept_invitation,
-- api.invitation_preview and api.cancel_invitation from their 0018 definitions and api.venue_setup
-- from 0065, drop the new
-- functions, and cancel any pending staff invitations; accepted ones leave ordinary logins.

-- Catalogue --------------------------------------------------------------------------------
insert into core.authority_action (code, basis, delegable, description) values
  ('invitation.create_staff', 'tenant_admin', false, 'Invite one of the customer''s own people to sign in (S1-2)'),
  ('invitation.cancel_staff', 'tenant_admin', false, 'Cancel a pending staff invitation'),
  ('tenant_admin.revoke',     'tenant_admin', false, 'End a person''s tenant administration (S1-3)');
insert into core.state_initial (machine, state, required_action) values
  ('invitation', 'pending', 'invitation.create_staff');
insert into core.state_transition (machine, from_state, to_state, required_action) values
  ('invitation', 'pending', 'cancelled', 'invitation.cancel_staff');

-- Staff invitations ------------------------------------------------------------------------
alter table core.invitation add column person_id uuid;
alter table core.invitation add constraint invitation_person_fk
  foreign key (customer_id, person_id) references core.person (customer_id, id) deferrable initially immediate;
alter table core.invitation drop constraint invitation_kind_check;
alter table core.invitation add constraint invitation_kind_check check (kind in ('organisation', 'person', 'staff'));
alter table core.invitation add constraint invitation_staff_check
  check ((kind = 'staff') = (person_id is not null)
         and (kind <> 'staff' or (organisation_id is null and venue_id is null and relationship_kind is null)));
create unique index invitation_one_pending_staff on core.invitation (person_id) where kind = 'staff' and status = 'pending';

create function api.create_staff_invitation(p_idempotency_key text, p_person_id uuid, p_invitee_email text,
                                            p_expires_at timestamptz)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id    uuid := gen_random_uuid();
  v_token text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  p       core.person;
  v_email text := lower(btrim(coalesce(p_invitee_email, '')));
  v       jsonb;
  v_other uuid;
begin
  select * into p from core.person where id = p_person_id;
  v := authz.require('invitation.create_staff',
         jsonb_build_object('customer_id', p.customer_id, 'record_id', v_id, 'target_type', 'invitation'),
         p_idempotency_key,
         jsonb_build_object('person_id', p_person_id, 'invitee_email', v_email, 'expires_at', p_expires_at));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  if p.deactivated_at is not null then
    raise exception 'this person has been deactivated, so they cannot be invited to sign in' using errcode = 'PT409';
  end if;
  if exists (select 1 from core.user_account where person_id = p.id and disabled_at is null) then
    raise exception 'this person already has a login' using errcode = 'PT409';
  end if;
  if exists (select 1 from core.invitation where person_id = p.id and kind = 'staff' and status = 'pending') then
    raise exception 'this person already has a pending invitation: cancel it first to send a new one' using errcode = 'PT409';
  end if;
  select ua.person_id into v_other
    from core.user_account ua join auth.users u on u.id = ua.auth_user_id
   where ua.customer_id = p.customer_id and ua.disabled_at is null and lower(u.email) = v_email;
  if v_other is not null then
    raise exception 'that email address already signs in as % here', core.person_name(v_other) using errcode = 'PT409';
  end if;
  if p_expires_at is null or p_expires_at <= now() then
    raise exception 'an invitation needs an expiry in the future' using errcode = '22023';
  end if;

  insert into core.invitation (id, customer_id, kind, person_id, invitee_given_name, invitee_family_name, invitee_email,
                               owner_person_id, invited_by_person_id, expires_at, token_hash, status)
  values (v_id, p.customer_id, 'staff', p.id, p.given_name, p.family_name, v_email,
          (v ->> 'actor_person_id')::uuid, (v ->> 'actor_person_id')::uuid, p_expires_at, core.token_hash(v_token), 'pending');
  return v || jsonb_build_object('token', v_token, 'email', v_email);
end $$;

do $$
declare d text; n text;
begin
  -- Accepting a staff invitation links the login to the named person and does nothing else.
  d := pg_get_functiondef('api.accept_invitation(text,text,uuid,text,text,text,text,text,text)'::regprocedure);
  n := $s$  -- Person invitation: the person's acceptance is what activates the relationship (P2-8).$s$;
  if position(n in d) = 0 then raise exception '0066: accept_invitation anchor not found'; end if;
  d := replace(d, n, $s$  -- Staff invitation (S1-2): the login is linked to the person the administrator named.
  if i.kind = 'staff' then
    if exists (select 1 from core.user_account where auth_user_id = auth.uid() and customer_id = i.customer_id and disabled_at is null) then
      raise exception 'this login is already linked to someone here, so it cannot accept this invitation' using errcode = 'PT409';
    end if;
    if exists (select 1 from core.user_account where person_id = i.person_id and disabled_at is null) then
      raise exception 'this person already has a login' using errcode = 'PT409';
    end if;
    if (select deactivated_at from core.person where id = i.person_id) is not null then
      raise exception 'this person has been deactivated, so the invitation can no longer be accepted' using errcode = 'PT409';
    end if;
    perform core.transition('core.invitation', i.id, 'accepted', i.row_version, v_ctx,
      jsonb_build_object('accepted_by_user_id', auth.uid(), 'accepted_at', now(), 'result_person_id', i.person_id,
                         'privacy_notice_version_id', p_privacy_notice_version_id));
    insert into core.user_account (customer_id, person_id, auth_user_id) values (i.customer_id, i.person_id, auth.uid());
    if not exists (select 1 from core.person_contact where person_id = i.person_id) then
      insert into core.person_contact (customer_id, person_id, email) values (i.customer_id, i.person_id, i.invitee_email);
    end if;
    return v || jsonb_build_object('status', 'accepted', 'person_id', i.person_id);
  end if;

$s$ || n);
  execute d;

  d := pg_get_functiondef('api.invitation_preview(text)'::regprocedure);
  n := $s$'capacity_code', i.capacity_code,$s$;
  if position(n in d) = 0 then raise exception '0066: invitation_preview anchor not found'; end if;
  execute replace(d, n, $s$'customer_name', (select name from core.customer where id = i.customer_id),
    'person_name', case when i.kind = 'staff' then core.person_name(i.person_id) end,
    $s$ || n);

  d := pg_get_functiondef('api.cancel_invitation(text,uuid,integer)'::regprocedure);
  n := $s$case i.kind when 'person' then 'invitation.cancel_person' else 'invitation.cancel_organisation' end$s$;
  if position(n in d) = 0 then raise exception '0066: cancel_invitation anchor not found'; end if;
  execute replace(d, n, $s$case i.kind when 'person' then 'invitation.cancel_person' when 'staff' then 'invitation.cancel_staff'
                       else 'invitation.cancel_organisation' end$s$);

  -- The set-up page (P4) now links the root appointment to its screen.
  d := pg_get_functiondef('api.venue_setup(uuid)'::regprocedure);
  n := $s$the appointee acknowledges it.',
    null, null);$s$;
  if position(n in d) = 0 then raise exception '0066: venue_setup anchor not found'; end if;
  execute replace(d, n, $s$the appointee acknowledges it.',
    null, '/venue/authority');$s$);
end $$;

-- Tenant administrators ------------------------------------------------------------------
create function api.revoke_tenant_admin(p_idempotency_key text, p_tenant_admin_id uuid, p_expected_version integer,
                                        p_reason text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  t core.tenant_admin;
  v jsonb;
begin
  select * into t from core.tenant_admin where id = p_tenant_admin_id;
  v := authz.require('tenant_admin.revoke',
         jsonb_build_object('customer_id', t.customer_id, 'record_id', p_tenant_admin_id, 'target_type', 'tenant_admin',
                            'excluded_person_ids', jsonb_build_array(t.person_id)),
         p_idempotency_key,
         jsonb_build_object('tenant_admin_id', p_tenant_admin_id, 'expected_version', p_expected_version, 'reason', p_reason));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  if length(btrim(coalesce(p_reason, ''))) = 0 then
    raise exception 'a reason is required to end someone''s administration' using errcode = '22023';
  end if;
  -- Serialise revocations per customer, so two administrators cannot remove each other at once.
  perform 1 from core.tenant_admin where customer_id = t.customer_id and revoked_at is null for update;
  perform core.check_version((select row_version from core.tenant_admin where id = t.id), p_expected_version);
  if t.revoked_at is not null then
    raise exception 'this administration has already ended' using errcode = 'PT409';
  end if;
  if not exists (select 1 from core.tenant_admin x where x.customer_id = t.customer_id and x.id <> t.id
                    and x.revoked_at is null and now() <@ x.valid_during) then
    raise exception 'this is the customer''s only tenant administrator: appoint another before ending this one' using errcode = 'PT409';
  end if;
  update core.tenant_admin set revoked_at = now() where id = t.id;
  return v;
end $$;

-- Reads ------------------------------------------------------------------------------------
-- An appointment's scope in words.
create function core.scope_words(p_items authz.scope_item[]) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(case
      when s.area_id is not null then (select name from core.area where id = s.area_id)
                                      || case when s.include_descendants then ' and everything below it' else ' only' end
      when s.system_id is not null then (select name from core.system where id = s.system_id)
      else 'Every ' || (select label from core.system_type where id = s.system_type_id) || ' system' end
      || case when s.restrict_to_area_id is not null then ', within ' || (select name from core.area where id = s.restrict_to_area_id) else '' end), '[]')
    from unnest(p_items) s
$$;

create function core.appointment_summary(a core.appointment) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', a.id, 'row_version', a.row_version, 'is_root', a.is_root, 'venue_id', a.venue_id,
    'venue', (select name from core.venue where id = a.venue_id),
    'appointee_person_id', a.appointee_person_id, 'appointee', core.person_name(a.appointee_person_id),
    'type', t.name, 'version_no', tv.version_no,
    'actions', (select coalesce(jsonb_agg(jsonb_build_object('code', x.code, 'description', x.description) order by x.description), '[]')
                  from core.authority_action x where x.code = any (tv.allowed_action_codes)),
    'classes', (select coalesce(jsonb_agg(c.name order by c.name), '[]') from core.permit_class c
                 where c.id = any (authz.appointment_class_ids(a.id))),
    'scope', core.scope_words(authz.appointment_scope_items(a.id)),
    'valid_from', lower(a.valid_during), 'valid_to', upper(a.valid_during), 'review_due_on', a.review_due_on,
    'limitations', a.limitations_text, 'root_evidence_ref', a.root_evidence_ref,
    'competence_evidence', (select coalesce(jsonb_agg(e.competence_evidence_ref), '[]') from core.appointment_evidence e where e.appointment_id = a.id),
    'appointed_by', core.person_name(a.appointed_by_person_id),
    'recorded_by', core.person_name(a.recorded_by_person_id), 'recorded_by_person_id', a.recorded_by_person_id,
    'confirmed_by', core.person_name(a.confirmed_by_person_id),
    'under', case when a.appointed_under_appointment_id is null then null
                  else (select jsonb_build_object('id', u.id, 'appointee', core.person_name(u.appointee_person_id), 'type', ut.name)
                          from core.appointment u join core.appointment_type_version uv on uv.id = u.appointment_type_version_id
                          join core.appointment_type ut on ut.id = uv.appointment_type_id where u.id = a.appointed_under_appointment_id) end,
    'status', a.status,
    'state', case when a.status = 'revoked' then 'revoked'
                  when a.status = 'in_force' and upper(a.valid_during) <= now() then 'ended'
                  when a.status = 'in_force' and lower(a.valid_during) > now() then 'scheduled'
                  else a.status end,
    'state_words', case when a.status = 'revoked' then 'Revoked'
                        when a.status = 'pending_confirmation' then 'Waiting for confirmation'
                        when a.status = 'pending_acknowledgement' then 'Waiting for acknowledgement'
                        when upper(a.valid_during) <= now() then 'Ended'
                        when lower(a.valid_during) > now() then 'Acknowledged, not yet started'
                        else 'In force' end,
    'next_step', case when a.status = 'pending_confirmation'
                        then 'A second tenant administrator, not the one who recorded it, must confirm it.'
                      when a.status = 'pending_acknowledgement'
                        then format('%s must acknowledge it on their own Your appointments page.', core.person_name(a.appointee_person_id)) end,
    'revoked_reason', a.revoked_reason)
    from core.appointment_type_version tv join core.appointment_type t on t.id = tv.appointment_type_id
   where tv.id = a.appointment_type_version_id
$$;

create function core.delegation_summary(g core.delegation) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', g.id, 'row_version', g.row_version, 'venue', (select name from core.venue where id = g.venue_id),
    'delegator', core.person_name(g.delegator_person_id), 'delegator_person_id', g.delegator_person_id,
    'delegate', core.person_name(g.delegate_person_id), 'delegate_person_id', g.delegate_person_id,
    'actions', (select coalesce(jsonb_agg(x.description order by x.description), '[]') from core.authority_action x where x.code = any (g.action_codes)),
    'classes', (select coalesce(jsonb_agg(c.name order by c.name), '[]') from core.permit_class c where c.id = any (g.permit_class_ids)),
    'scope', core.scope_words(authz.delegation_scope_items(g.id)),
    'valid_from', lower(g.valid_during), 'valid_to', upper(g.valid_during), 'reason', g.reason,
    'in_force', g.status = 'in_force' and now() <@ g.valid_during
                and authz.appointment_in_force(g.delegator_appointment_id) and authz.appointment_in_force(g.delegate_appointment_id),
    'status', g.status)
$$;

-- Appointments a viewer of the venue should see: not revoked and not ended, or revoked or
-- ended in the last 30 days.
create function core.recent_appointment(a core.appointment) returns boolean
language sql stable set search_path = '' as $$
  select (a.status <> 'revoked' and (upper_inf(a.valid_during) or upper(a.valid_during) > now() - interval '30 days'))
      or (a.status = 'revoked' and a.revoked_at > now() - interval '30 days')
$$;

create function api.authority_overview(p_venue_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  vn core.venue;
  me uuid;
  is_admin boolean;
begin
  select * into vn from core.venue where id = p_venue_id;
  if vn.id is null or not core.setup_viewer(vn.id) then
    return jsonb_build_object('ok', false, 'code', 'not_found', 'reason', 'The record does not exist or you do not have access to it.');
  end if;
  me := authz.actor_person(vn.customer_id);
  is_admin := vn.customer_id in (select authz.my_admin_customer_ids());
  return jsonb_build_object('ok', true, 'venue', jsonb_build_object('id', vn.id, 'name', vn.name, 'timezone', vn.timezone),
    'customer_id', vn.customer_id, 'me', me, 'is_admin', is_admin,
    'admins', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'row_version', t.row_version, 'person_id', t.person_id,
                                         'name', core.person_name(t.person_id), 'since', lower(t.valid_during),
                                         'granted_by', core.person_name(t.granted_by_person_id)) order by core.person_name(t.person_id)), '[]')
                 from core.tenant_admin t where t.customer_id = vn.customer_id and t.revoked_at is null and now() <@ t.valid_during),
    'people', case when not is_admin then null else (
      select coalesce(jsonb_agg(jsonb_build_object(
          'id', p.id, 'name', core.person_name(p.id), 'deactivated', p.deactivated_at is not null,
          'organisations', (select coalesce(jsonb_agg(o.legal_name order by o.legal_name), '[]')
                              from core.person_organisation_relationship r join core.organisation o on o.id = r.organisation_id
                             where r.person_id = p.id and r.status = 'active'),
          'login', case when exists (select 1 from core.user_account u where u.person_id = p.id and u.disabled_at is null) then 'active'
                        when exists (select 1 from core.user_account u where u.person_id = p.id) then 'disabled' else 'none' end,
          'login_id', (select u.id from core.user_account u where u.person_id = p.id and u.disabled_at is null),
          'login_row_version', (select u.row_version from core.user_account u where u.person_id = p.id and u.disabled_at is null),
          'is_admin', exists (select 1 from core.tenant_admin t where t.person_id = p.id and t.revoked_at is null and now() <@ t.valid_during),
          'invitation', (select jsonb_build_object('id', i.id, 'row_version', i.row_version, 'email', i.invitee_email,
                                                   'expires_at', i.expires_at, 'expired', now() >= i.expires_at)
                           from core.invitation i where i.person_id = p.id and i.kind = 'staff' and i.status = 'pending'))
        order by p.family_name, p.given_name), '[]')
        from core.person p where p.customer_id = vn.customer_id) end,
    'root_versions', (select coalesce(jsonb_agg(jsonb_build_object('id', tv.id, 'type', t.name, 'version_no', tv.version_no,
                                         'actions', (select coalesce(jsonb_agg(x.description order by x.description), '[]') from core.authority_action x where x.code = any (tv.allowed_action_codes)),
                                         'class_ids', to_jsonb(tv.eligible_permit_class_ids), 'system_type_ids', to_jsonb(tv.eligible_system_type_ids),
                                         'requires_competence_evidence', tv.requires_competence_evidence) order by t.name), '[]')
                        from core.appointment_type t join core.appointment_type_version tv on tv.appointment_type_id = t.id
                       where t.venue_id = vn.id and t.retired_at is null and tv.status = 'approved' and tv.is_root_eligible
                         and tv.effective_from <= now()
                         and tv.version_no = (select max(x.version_no) from core.appointment_type_version x
                                               where x.appointment_type_id = t.id and x.status = 'approved' and x.effective_from <= now())),
    'classes', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) order by c.name), '[]')
                  from core.permit_class c where c.venue_id = vn.id and c.retired_at is null),
    'areas', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'code', a.code, 'depth', cardinality(a.path) - 1) order by a.path), '[]')
                from core.area a where a.venue_id = vn.id and a.retired_at is null),
    'system_types', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'label', t.label) order by t.label), '[]')
                       from core.system_type t where t.venue_id = vn.id and t.retired_at is null),
    'systems', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'type', t.label) order by t.label, s.name), '[]')
                  from core.system s join core.system_type t on t.id = s.system_type_id where s.venue_id = vn.id and s.retired_at is null),
    'appointments', (select coalesce(jsonb_agg(core.appointment_summary(a) || jsonb_build_object(
                         'can_confirm', is_admin and a.status = 'pending_confirmation' and me is distinct from a.recorded_by_person_id
                                        and me is distinct from a.appointee_person_id,
                         'can_revoke_root', is_admin and a.is_root and a.status <> 'revoked' and me is distinct from a.appointee_person_id,
                         'can_revoke', not a.is_root and a.status <> 'revoked' and me is distinct from a.appointee_person_id
                                       and jsonb_array_length(authz.capacities('appointment.revoke',
                                             jsonb_build_object('venue_id', a.venue_id, 'record_id', a.id), me)) > 0)
                       order by a.is_root desc, core.person_name(a.appointee_person_id)), '[]')
                       from core.appointment a where a.venue_id = vn.id and core.recent_appointment(a)),
    'delegations', (select coalesce(jsonb_agg(core.delegation_summary(g) order by g.created_at desc), '[]')
                      from core.delegation g where g.venue_id = vn.id and g.status = 'in_force' and upper(g.valid_during) > now()));
end $$;

create function api.my_appointments() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('ok', true,
    'appointments', (select coalesce(jsonb_agg(core.appointment_summary(a) || jsonb_build_object(
          'can_grant', a.status = 'in_force' and now() <@ a.valid_during and 'appointment.grant' = any (tv.allowed_action_codes),
          'can_delegate', a.status = 'in_force' and now() <@ a.valid_during and 'delegation.grant' = any (tv.allowed_action_codes))
        order by (a.status = 'pending_acknowledgement') desc, core.person_name(a.appointee_person_id), a.created_at), '[]')
        from core.appointment a join core.appointment_type_version tv on tv.id = a.appointment_type_version_id
       where a.appointee_person_id in (select authz.my_person_ids()) and core.recent_appointment(a)),
    'received', (select coalesce(jsonb_agg(core.delegation_summary(g) order by g.created_at desc), '[]')
                   from core.delegation g where g.delegate_person_id in (select authz.my_person_ids())
                    and g.status = 'in_force' and upper(g.valid_during) > now()),
    'given', (select coalesce(jsonb_agg(core.delegation_summary(g) order by g.created_at desc), '[]')
                from core.delegation g where g.delegator_person_id in (select authz.my_person_ids())
                 and g.status = 'in_force' and upper(g.valid_during) > now()))
$$;

-- What an appointee may offer when granting or delegating from one of their own appointments.
create function api.grant_options(p_appointment_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  a core.appointment;
  tv core.appointment_type_version;
  mine authz.scope_item[];
  my_classes uuid[];
begin
  select * into a from core.appointment where id = p_appointment_id;
  if a.id is null or a.appointee_person_id not in (select authz.my_person_ids())
     or a.status <> 'in_force' or not now() <@ a.valid_during then
    return jsonb_build_object('ok', false, 'code', 'not_found',
      'reason', 'This appointment is not one of yours in force, so nothing can be granted from it.');
  end if;
  select * into tv from core.appointment_type_version where id = a.appointment_type_version_id;
  mine := authz.appointment_scope_items(a.id);
  my_classes := authz.appointment_class_ids(a.id);
  return jsonb_build_object('ok', true, 'appointment', core.appointment_summary(a),
    'timezone', (select timezone from core.venue where id = a.venue_id),
    'can_grant', 'appointment.grant' = any (tv.allowed_action_codes),
    'can_delegate', 'delegation.grant' = any (tv.allowed_action_codes),
    'types', (select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'type', t.name, 'version_no', v.version_no,
                 'actions', (select coalesce(jsonb_agg(x.description order by x.description), '[]') from core.authority_action x where x.code = any (v.allowed_action_codes)),
                 'class_ids', to_jsonb(array(select unnest(v.eligible_permit_class_ids) intersect select unnest(my_classes))),
                 'requires_competence_evidence', v.requires_competence_evidence) order by t.name), '[]')
                from core.appointment_type t join core.appointment_type_version v on v.appointment_type_id = t.id
               where t.id = any (tv.grantable_type_ids) and t.retired_at is null and v.status = 'approved' and v.effective_from <= now()
                 and v.version_no = (select max(x.version_no) from core.appointment_type_version x
                                      where x.appointment_type_id = t.id and x.status = 'approved' and x.effective_from <= now())),
    'classes', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) order by c.name), '[]')
                  from core.permit_class c where c.id = any (my_classes)),
    -- Areas: offered alone where covered; "and everything below" only where that is covered too.
    'areas', (select coalesce(jsonb_agg(jsonb_build_object('id', ar.id, 'name', ar.name, 'depth', cardinality(ar.path) - 1,
                 'with_below', authz.scopes_cover(mine, array[row(ar.id, true, null, null, null)::authz.scope_item])) order by ar.path), '[]')
                from core.area ar where ar.venue_id = a.venue_id and ar.retired_at is null
                 and authz.scopes_cover(mine, array[row(ar.id, false, null, null, null)::authz.scope_item])),
    'systems', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'type', t.label) order by t.label, s.name), '[]')
                  from core.system s join core.system_type t on t.id = s.system_type_id
                 where s.venue_id = a.venue_id and s.retired_at is null
                   and authz.scopes_cover(mine, array[row(null, true, s.id, null, null)::authz.scope_item])),
    'people', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', core.person_name(p.id)) order by p.family_name, p.given_name), '[]')
                 from core.person p
                where p.customer_id = a.customer_id and p.deactivated_at is null and p.id <> a.appointee_person_id
                  and exists (select 1 from core.user_account u where u.person_id = p.id and u.disabled_at is null)),
    'valid_to', upper(a.valid_during),
    -- Delegation: actions this appointment may pass on; for each other appointment in force at the
    -- venue, the classes and scope items both appointments cover (invariant 7).
    'delegable', (select coalesce(jsonb_agg(jsonb_build_object('code', x.code, 'description', x.description) order by x.description), '[]')
                    from core.authority_action x where x.code = any (tv.allowed_action_codes) and x.delegable),
    'my_scope', (select coalesce(jsonb_agg(jsonb_build_object('item', to_jsonb(s), 'words', core.scope_words(array[s]) ->> 0)), '[]') from unnest(mine) s),
    'delegates', case when not 'delegation.grant' = any (tv.allowed_action_codes) then '[]'::jsonb else (
      select coalesce(jsonb_agg(jsonb_build_object('appointment_id', d.id, 'person', core.person_name(d.appointee_person_id), 'type', dt.name,
                 'class_ids', to_jsonb(array(select unnest(authz.appointment_class_ids(d.id)) intersect select unnest(my_classes))),
                 'scope_indexes', (select coalesce(jsonb_agg(i - 1), '[]') from generate_subscripts(mine, 1) i
                                    where authz.scopes_cover(authz.appointment_scope_items(d.id), array[mine[i]])),
                 'valid_to', upper(d.valid_during))
               order by core.person_name(d.appointee_person_id)), '[]')
        from core.appointment d join core.appointment_type_version dv on dv.id = d.appointment_type_version_id
        join core.appointment_type dt on dt.id = dv.appointment_type_id
       where d.venue_id = a.venue_id and d.appointee_person_id <> a.appointee_person_id
         and d.status = 'in_force' and now() <@ d.valid_during) end);
end $$;

grant execute on function api.create_staff_invitation(text, uuid, text, timestamptz),
  api.revoke_tenant_admin(text, uuid, integer, text), api.authority_overview(uuid), api.my_appointments(),
  api.grant_options(uuid) to authenticated;
revoke execute on function api.create_staff_invitation(text, uuid, text, timestamptz),
  api.revoke_tenant_admin(text, uuid, integer, text), api.authority_overview(uuid), api.my_appointments(),
  api.grant_options(uuid) from anon;
revoke execute on function core.scope_words(authz.scope_item[]), core.appointment_summary(core.appointment),
  core.delegation_summary(core.delegation), core.recent_appointment(core.appointment)
from public, anon, authenticated;
