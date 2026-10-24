-- 0012 Client surface: security-invoker read views and security-definer RPCs
--
-- Every RPC follows one pattern:
--   1. build the target (customer, venue, area/system, record, excluded people)
--   2. authz.require(...)  -> denial or replay is returned as-is
--   3. perform the write (status only via core.transition)
-- Results are jsonb: {ok, id, decision_context_id, replayed} or a denial
-- {ok:false, code, reason, missing, resolvable_by}. Stale versions raise PT409.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

-- ---------------------------------------------------------------------------
-- Read views (RLS applies through security_invoker)
-- ---------------------------------------------------------------------------

create view api.authority_action        with (security_invoker = true) as select * from core.authority_action;
create view api.state_transition        with (security_invoker = true) as select * from core.state_transition;
create view api.engagement_capacity     with (security_invoker = true) as select * from core.engagement_capacity;
create view api.customer                with (security_invoker = true) as select * from core.customer;
create view api.venue                   with (security_invoker = true) as select * from core.venue;
create view api.break_glass_grant       with (security_invoker = true) as select * from core.break_glass_grant;
create view api.area_kind               with (security_invoker = true) as select * from core.area_kind;
create view api.area                    with (security_invoker = true) as select * from core.area;
create view api.system_type             with (security_invoker = true) as select * from core.system_type;
create view api.system                  with (security_invoker = true) as select * from core.system;
create view api.system_area             with (security_invoker = true) as select * from core.system_area;
create view api.system_ownership        with (security_invoker = true) as select * from core.system_ownership;
create view api.organisation            with (security_invoker = true) as select * from core.organisation;
create view api.engagement              with (security_invoker = true) as select * from core.engagement;
create view api.person                  with (security_invoker = true) as select * from core.person;
create view api.person_contact          with (security_invoker = true) as select * from core.person_contact;
create view api.user_account            with (security_invoker = true) as select * from core.user_account;
create view api.person_organisation_relationship with (security_invoker = true) as select * from core.person_organisation_relationship;
create view api.tenant_admin            with (security_invoker = true) as select * from core.tenant_admin;
create view api.permit_class            with (security_invoker = true) as select * from core.permit_class;
create view api.appointment_type        with (security_invoker = true) as select * from core.appointment_type;
create view api.appointment_type_version with (security_invoker = true) as select * from core.appointment_type_version;
create view api.appointment             with (security_invoker = true) as select * from core.appointment;
create view api.appointment_scope       with (security_invoker = true) as select * from core.appointment_scope;
create view api.appointment_permit_class with (security_invoker = true) as select * from core.appointment_permit_class;
create view api.appointment_evidence    with (security_invoker = true) as select * from core.appointment_evidence;
create view api.delegation              with (security_invoker = true) as select * from core.delegation;
create view api.delegation_scope        with (security_invoker = true) as select * from core.delegation_scope;
create view api.decision_context        with (security_invoker = true) as select * from core.decision_context;
create view api.status_history          with (security_invoker = true) as select * from core.status_history;
create view api.audit_event             with (security_invoker = true) as select * from audit.audit_event;

grant select on all tables in schema api to authenticated;

-- ---------------------------------------------------------------------------
-- Internal helpers (not executable by clients)
-- ---------------------------------------------------------------------------

create function core.insert_scopes(p_kind text, p_customer_id uuid, p_venue_id uuid, p_parent_id uuid, p_scopes jsonb)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  s authz.scope_item;
begin
  if jsonb_typeof(p_scopes) is distinct from 'array' or jsonb_array_length(p_scopes) = 0 then
    raise exception 'at least one area or system scope is required' using errcode = '22023';
  end if;
  foreach s in array authz.scope_items_from_json(p_scopes) loop
    if p_kind = 'appointment' then
      insert into core.appointment_scope (customer_id, venue_id, appointment_id, area_id, include_descendants,
                                          system_id, system_type_id, restrict_to_area_id)
      values (p_customer_id, p_venue_id, p_parent_id, s.area_id, s.include_descendants,
              s.system_id, s.system_type_id, s.restrict_to_area_id);
    else
      insert into core.delegation_scope (customer_id, venue_id, delegation_id, area_id, include_descendants,
                                         system_id, system_type_id, restrict_to_area_id)
      values (p_customer_id, p_venue_id, p_parent_id, s.area_id, s.include_descendants,
              s.system_id, s.system_type_id, s.restrict_to_area_id);
    end if;
  end loop;
end $$;

create function core.venue_customer(p_venue_id uuid) returns uuid
language sql stable security definer
set search_path = ''
as $$ select customer_id from core.venue where id = p_venue_id $$;

create function core.check_version(p_current integer, p_expected integer) returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_current is distinct from p_expected then
    raise exception 'record has changed since you loaded it (version % expected, % current)',
      p_expected, p_current using errcode = 'PT409';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Read-only explanation for the interface
-- ---------------------------------------------------------------------------

create function api.check(
  p_action                text,
  p_target                jsonb,
  p_acting_appointment_id uuid default null,
  p_acting_delegation_id  uuid default null
) returns jsonb
language sql stable security definer
set search_path = ''
as $$ select authz.evaluate(p_action, p_target, p_acting_appointment_id, p_acting_delegation_id) $$;

-- ---------------------------------------------------------------------------
-- Platform bootstrap
-- ---------------------------------------------------------------------------

create function api.create_customer(
  p_idempotency_key     text,
  p_name                text,
  p_admin_given_name    text,
  p_admin_family_name   text,
  p_admin_auth_user_id  uuid
) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id     uuid := gen_random_uuid();
  v_person uuid := gen_random_uuid();
  v        jsonb;
begin
  v := authz.require('customer.create',
         jsonb_build_object('customer_id', v_id, 'record_id', v_id, 'target_type', 'customer'),
         p_idempotency_key,
         jsonb_build_object('name', p_name, 'admin_given_name', p_admin_given_name,
                            'admin_family_name', p_admin_family_name, 'admin_auth_user_id', p_admin_auth_user_id));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  insert into core.customer (id, name) values (v_id, p_name);
  insert into core.person (id, customer_id, given_name, family_name)
    values (v_person, v_id, p_admin_given_name, p_admin_family_name);
  insert into core.user_account (customer_id, person_id, auth_user_id)
    values (v_id, v_person, p_admin_auth_user_id);
  insert into core.tenant_admin (customer_id, person_id) values (v_id, v_person);
  return v || jsonb_build_object('admin_person_id', v_person);
end $$;

create function api.open_break_glass(
  p_idempotency_key text,
  p_customer_id     uuid,
  p_reason          text,
  p_hours           numeric
) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v    jsonb;
begin
  v := authz.require('break_glass.open',
         jsonb_build_object('customer_id', p_customer_id, 'record_id', v_id, 'target_type', 'break_glass_grant'),
         p_idempotency_key,
         jsonb_build_object('customer_id', p_customer_id, 'reason', p_reason, 'hours', p_hours));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  insert into core.break_glass_grant (id, customer_id, platform_admin_user_id, reason, valid_during)
  values (v_id, p_customer_id, auth.uid(), p_reason,
          tstzrange(now(), now() + make_interval(secs => (p_hours * 3600)::double precision)));
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Tenant administration (master data; grants no operational authority)
-- ---------------------------------------------------------------------------

create function api.grant_tenant_admin(p_idempotency_key text, p_customer_id uuid, p_person_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v    jsonb;
begin
  v := authz.require('tenant_admin.grant',
         jsonb_build_object('customer_id', p_customer_id, 'record_id', v_id, 'target_type', 'tenant_admin',
                            'excluded_person_ids', jsonb_build_array(p_person_id)),
         p_idempotency_key, jsonb_build_object('customer_id', p_customer_id, 'person_id', p_person_id));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  insert into core.tenant_admin (id, customer_id, person_id, granted_by_person_id)
  values (v_id, p_customer_id, p_person_id, (v ->> 'actor_person_id')::uuid);
  return v;
end $$;

create function api.create_venue(p_idempotency_key text, p_customer_id uuid, p_code text, p_name text, p_timezone text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v    jsonb;
begin
  v := authz.require('venue.create',
         jsonb_build_object('customer_id', p_customer_id, 'record_id', v_id, 'target_type', 'venue'),
         p_idempotency_key,
         jsonb_build_object('customer_id', p_customer_id, 'code', p_code, 'name', p_name, 'timezone', p_timezone));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  insert into core.venue (id, customer_id, code, name, timezone, status)
  values (v_id, p_customer_id, p_code, p_name, p_timezone, 'onboarding');
  -- Every venue has exactly one root area, the whole site.
  insert into core.area (customer_id, venue_id, code, name)
  values (p_customer_id, v_id, 'SITE', p_name);
  return v || jsonb_build_object('root_area_id',
    (select id from core.area where venue_id = v_id and parent_id is null));
end $$;

create function api.create_area_kind(p_idempotency_key text, p_venue_id uuid, p_code text, p_label text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v_customer uuid := core.venue_customer(p_venue_id);
  v    jsonb;
begin
  v := authz.require('area_kind.create',
         jsonb_build_object('customer_id', v_customer, 'venue_id', p_venue_id, 'record_id', v_id, 'target_type', 'area_kind'),
         p_idempotency_key, jsonb_build_object('venue_id', p_venue_id, 'code', p_code, 'label', p_label));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  insert into core.area_kind (id, customer_id, venue_id, code, label)
  values (v_id, v_customer, p_venue_id, p_code, p_label);
  return v;
end $$;

create function api.create_area(p_idempotency_key text, p_parent_area_id uuid, p_area_kind_id uuid, p_code text, p_name text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id     uuid := gen_random_uuid();
  v_parent core.area;
  v        jsonb;
begin
  select * into v_parent from core.area where id = p_parent_area_id;
  v := authz.require('area.create',
         jsonb_build_object('customer_id', v_parent.customer_id, 'venue_id', v_parent.venue_id,
                            'record_id', v_id, 'target_type', 'area'),
         p_idempotency_key,
         jsonb_build_object('parent_area_id', p_parent_area_id, 'area_kind_id', p_area_kind_id,
                            'code', p_code, 'name', p_name));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  insert into core.area (id, customer_id, venue_id, parent_id, area_kind_id, code, name)
  values (v_id, v_parent.customer_id, v_parent.venue_id, p_parent_area_id, p_area_kind_id, p_code, p_name);
  return v;
end $$;

create function api.retire_area(p_idempotency_key text, p_area_id uuid, p_expected_version integer)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_area core.area;
  v      jsonb;
begin
  select * into v_area from core.area where id = p_area_id for update;
  v := authz.require('area.retire',
         jsonb_build_object('customer_id', v_area.customer_id, 'venue_id', v_area.venue_id,
                            'record_id', p_area_id, 'target_type', 'area'),
         p_idempotency_key, jsonb_build_object('area_id', p_area_id, 'expected_version', p_expected_version));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  perform core.check_version(v_area.row_version, p_expected_version);
  if v_area.parent_id is null then
    raise exception 'the venue''s root area cannot be retired' using errcode = 'check_violation';
  end if;
  update core.area set retired_at = now() where id = p_area_id;
  return v;
end $$;

create function api.create_system_type(p_idempotency_key text, p_venue_id uuid, p_code text, p_label text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v_customer uuid := core.venue_customer(p_venue_id);
  v    jsonb;
begin
  v := authz.require('system_type.create',
         jsonb_build_object('customer_id', v_customer, 'venue_id', p_venue_id, 'record_id', v_id, 'target_type', 'system_type'),
         p_idempotency_key, jsonb_build_object('venue_id', p_venue_id, 'code', p_code, 'label', p_label));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  insert into core.system_type (id, customer_id, venue_id, code, label)
  values (v_id, v_customer, p_venue_id, p_code, p_label);
  return v;
end $$;

create function api.create_system(p_idempotency_key text, p_venue_id uuid, p_system_type_id uuid,
                                  p_code text, p_name text, p_description text default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v_customer uuid := core.venue_customer(p_venue_id);
  v    jsonb;
begin
  v := authz.require('system.create',
         jsonb_build_object('customer_id', v_customer, 'venue_id', p_venue_id, 'record_id', v_id, 'target_type', 'system'),
         p_idempotency_key,
         jsonb_build_object('venue_id', p_venue_id, 'system_type_id', p_system_type_id, 'code', p_code,
                            'name', p_name, 'description', p_description));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  insert into core.system (id, customer_id, venue_id, system_type_id, code, name, description)
  values (v_id, v_customer, p_venue_id, p_system_type_id, p_code, p_name, p_description);
  return v;
end $$;

create function api.link_system_area(p_idempotency_key text, p_system_id uuid, p_area_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id  uuid := gen_random_uuid();
  v_sys core.system;
  v     jsonb;
begin
  select * into v_sys from core.system where id = p_system_id;
  v := authz.require('system.link_area',
         jsonb_build_object('customer_id', v_sys.customer_id, 'venue_id', v_sys.venue_id,
                            'record_id', v_id, 'target_type', 'system_area'),
         p_idempotency_key, jsonb_build_object('system_id', p_system_id, 'area_id', p_area_id));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  insert into core.system_area (id, customer_id, venue_id, system_id, area_id)
  values (v_id, v_sys.customer_id, v_sys.venue_id, p_system_id, p_area_id);
  return v;
end $$;

create function api.record_system_ownership(
  p_idempotency_key text, p_system_id uuid, p_organisation_id uuid, p_responsibility text,
  p_valid_from timestamptz, p_valid_to timestamptz default null,
  p_engagement_id uuid default null, p_evidence_ref text default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id  uuid := gen_random_uuid();
  v_sys core.system;
  v     jsonb;
begin
  select * into v_sys from core.system where id = p_system_id;
  v := authz.require('system_ownership.record',
         jsonb_build_object('customer_id', v_sys.customer_id, 'venue_id', v_sys.venue_id,
                            'record_id', v_id, 'target_type', 'system_ownership'),
         p_idempotency_key,
         jsonb_build_object('system_id', p_system_id, 'organisation_id', p_organisation_id,
                            'responsibility', p_responsibility, 'valid_from', p_valid_from, 'valid_to', p_valid_to,
                            'engagement_id', p_engagement_id, 'evidence_ref', p_evidence_ref));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  insert into core.system_ownership (id, customer_id, venue_id, system_id, organisation_id, engagement_id,
                                     responsibility, valid_during, evidence_ref)
  values (v_id, v_sys.customer_id, v_sys.venue_id, p_system_id, p_organisation_id, p_engagement_id,
          p_responsibility, tstzrange(p_valid_from, p_valid_to), p_evidence_ref);
  return v;
end $$;

create function api.create_organisation(p_idempotency_key text, p_customer_id uuid, p_legal_name text,
                                        p_trading_name text default null, p_company_number text default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v    jsonb;
begin
  v := authz.require('organisation.create',
         jsonb_build_object('customer_id', p_customer_id, 'record_id', v_id, 'target_type', 'organisation'),
         p_idempotency_key,
         jsonb_build_object('customer_id', p_customer_id, 'legal_name', p_legal_name,
                            'trading_name', p_trading_name, 'company_number', p_company_number));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  insert into core.organisation (id, customer_id, legal_name, trading_name, company_number)
  values (v_id, p_customer_id, p_legal_name, p_trading_name, p_company_number);
  return v;
end $$;

create function api.create_person(p_idempotency_key text, p_customer_id uuid, p_given_name text, p_family_name text,
                                  p_preferred_name text default null, p_preferred_language text default null,
                                  p_email text default null, p_phone text default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v    jsonb;
begin
  v := authz.require('person.create',
         jsonb_build_object('customer_id', p_customer_id, 'record_id', v_id, 'target_type', 'person'),
         p_idempotency_key,
         jsonb_build_object('customer_id', p_customer_id, 'given_name', p_given_name, 'family_name', p_family_name,
                            'preferred_name', p_preferred_name, 'preferred_language', p_preferred_language,
                            'email', p_email, 'phone', p_phone));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  insert into core.person (id, customer_id, given_name, family_name, preferred_name, preferred_language)
  values (v_id, p_customer_id, p_given_name, p_family_name, p_preferred_name, p_preferred_language);
  if p_email is not null or p_phone is not null then
    insert into core.person_contact (customer_id, person_id, email, phone)
    values (p_customer_id, v_id, p_email, p_phone);
  end if;
  return v;
end $$;

create function api.link_user_account(p_idempotency_key text, p_person_id uuid, p_auth_user_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v_customer uuid := (select customer_id from core.person where id = p_person_id);
  v    jsonb;
begin
  v := authz.require('user_account.link',
         jsonb_build_object('customer_id', v_customer, 'record_id', v_id, 'target_type', 'user_account'),
         p_idempotency_key, jsonb_build_object('person_id', p_person_id, 'auth_user_id', p_auth_user_id));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  insert into core.user_account (id, customer_id, person_id, auth_user_id)
  values (v_id, v_customer, p_person_id, p_auth_user_id);
  return v;
end $$;

create function api.disable_user_account(p_idempotency_key text, p_person_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_acct core.user_account;
  v      jsonb;
begin
  select * into v_acct from core.user_account where person_id = p_person_id and disabled_at is null for update;
  v := authz.require('user_account.disable',
         jsonb_build_object('customer_id', coalesce(v_acct.customer_id, (select customer_id from core.person where id = p_person_id)),
                            'record_id', coalesce(v_acct.id, p_person_id), 'target_type', 'user_account'),
         p_idempotency_key, jsonb_build_object('person_id', p_person_id));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  if v_acct.id is null then
    raise exception 'this person has no active login' using errcode = 'PT404';
  end if;

  update core.user_account set disabled_at = now() where id = v_acct.id;
  return v;
end $$;

create function api.record_person_organisation(
  p_idempotency_key text, p_person_id uuid, p_organisation_id uuid, p_kind text,
  p_valid_from timestamptz, p_valid_to timestamptz default null,
  p_supervisor_person_id uuid default null, p_evidence_responsible_organisation_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v_customer uuid := (select customer_id from core.person where id = p_person_id);
  v    jsonb;
begin
  v := authz.require('person_organisation.record',
         jsonb_build_object('customer_id', v_customer, 'record_id', v_id, 'target_type', 'person_organisation_relationship'),
         p_idempotency_key,
         jsonb_build_object('person_id', p_person_id, 'organisation_id', p_organisation_id, 'kind', p_kind,
                            'valid_from', p_valid_from, 'valid_to', p_valid_to,
                            'supervisor_person_id', p_supervisor_person_id,
                            'evidence_responsible_organisation_id', p_evidence_responsible_organisation_id));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  insert into core.person_organisation_relationship (id, customer_id, person_id, organisation_id, kind, valid_during,
                                                     supervisor_person_id, evidence_responsible_organisation_id)
  values (v_id, v_customer, p_person_id, p_organisation_id, p_kind, tstzrange(p_valid_from, p_valid_to),
          p_supervisor_person_id, p_evidence_responsible_organisation_id);
  return v;
end $$;

create function api.create_permit_class(p_idempotency_key text, p_venue_id uuid, p_code text, p_name text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v_customer uuid := core.venue_customer(p_venue_id);
  v    jsonb;
begin
  v := authz.require('permit_class.create',
         jsonb_build_object('customer_id', v_customer, 'venue_id', p_venue_id, 'record_id', v_id, 'target_type', 'permit_class'),
         p_idempotency_key, jsonb_build_object('venue_id', p_venue_id, 'code', p_code, 'name', p_name));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  insert into core.permit_class (id, customer_id, venue_id, code, name)
  values (v_id, v_customer, p_venue_id, p_code, p_name);
  return v;
end $$;

create function api.create_appointment_type(p_idempotency_key text, p_venue_id uuid, p_code text, p_name text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v_customer uuid := core.venue_customer(p_venue_id);
  v    jsonb;
begin
  v := authz.require('appointment_type.create',
         jsonb_build_object('customer_id', v_customer, 'venue_id', p_venue_id, 'record_id', v_id, 'target_type', 'appointment_type'),
         p_idempotency_key, jsonb_build_object('venue_id', p_venue_id, 'code', p_code, 'name', p_name));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  insert into core.appointment_type (id, customer_id, venue_id, code, name)
  values (v_id, v_customer, p_venue_id, p_code, p_name);
  return v;
end $$;

create function api.publish_appointment_type_version(
  p_idempotency_key              text,
  p_appointment_type_id          uuid,
  p_allowed_action_codes         text[],
  p_eligible_permit_class_ids    uuid[],
  p_eligible_system_type_ids     uuid[],
  p_grantable_type_ids           uuid[],
  p_is_root_eligible             boolean,
  p_requires_competence_evidence boolean,
  p_owner_person_id              uuid,
  p_effective_from               timestamptz,
  p_change_reason                text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id   uuid := gen_random_uuid();
  v_type core.appointment_type;
  v      jsonb;
begin
  select * into v_type from core.appointment_type where id = p_appointment_type_id;
  v := authz.require('appointment_type.publish',
         jsonb_build_object('customer_id', v_type.customer_id, 'venue_id', v_type.venue_id,
                            'record_id', v_id, 'target_type', 'appointment_type_version'),
         p_idempotency_key,
         jsonb_build_object('appointment_type_id', p_appointment_type_id, 'allowed_action_codes', p_allowed_action_codes,
                            'eligible_permit_class_ids', p_eligible_permit_class_ids,
                            'eligible_system_type_ids', p_eligible_system_type_ids,
                            'grantable_type_ids', p_grantable_type_ids, 'is_root_eligible', p_is_root_eligible,
                            'requires_competence_evidence', p_requires_competence_evidence,
                            'owner_person_id', p_owner_person_id, 'effective_from', p_effective_from,
                            'change_reason', p_change_reason));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  insert into core.appointment_type_version (
    id, customer_id, venue_id, appointment_type_id, version_no, allowed_action_codes, eligible_permit_class_ids,
    eligible_system_type_ids, grantable_type_ids, is_root_eligible, requires_competence_evidence,
    owner_person_id, effective_from, change_reason)
  values (
    v_id, v_type.customer_id, v_type.venue_id, p_appointment_type_id, 1, p_allowed_action_codes,
    coalesce(p_eligible_permit_class_ids, '{}'), coalesce(p_eligible_system_type_ids, '{}'),
    coalesce(p_grantable_type_ids, '{}'), p_is_root_eligible, p_requires_competence_evidence,
    p_owner_person_id, p_effective_from, p_change_reason);
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Engagements
-- ---------------------------------------------------------------------------

create function api.create_engagement(
  p_idempotency_key text, p_venue_id uuid, p_organisation_id uuid, p_capacity_code text,
  p_valid_from timestamptz, p_valid_to timestamptz default null,
  p_engaged_via_organisation_id uuid default null, p_accountable_admin_person_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v_customer uuid := core.venue_customer(p_venue_id);
  v    jsonb;
begin
  v := authz.require('engagement.create',
         jsonb_build_object('customer_id', v_customer, 'venue_id', p_venue_id, 'record_id', v_id, 'target_type', 'engagement'),
         p_idempotency_key,
         jsonb_build_object('venue_id', p_venue_id, 'organisation_id', p_organisation_id, 'capacity_code', p_capacity_code,
                            'valid_from', p_valid_from, 'valid_to', p_valid_to,
                            'engaged_via_organisation_id', p_engaged_via_organisation_id,
                            'accountable_admin_person_id', p_accountable_admin_person_id));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  insert into core.engagement (id, customer_id, venue_id, organisation_id, capacity_code, valid_during,
                               engaged_via_organisation_id, accountable_admin_person_id, status)
  values (v_id, v_customer, p_venue_id, p_organisation_id, p_capacity_code, tstzrange(p_valid_from, p_valid_to),
          p_engaged_via_organisation_id, p_accountable_admin_person_id, 'active');
  return v;
end $$;

create function api.end_engagement(p_idempotency_key text, p_engagement_id uuid, p_expected_version integer, p_reason text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_e core.engagement;
  v   jsonb;
begin
  select * into v_e from core.engagement where id = p_engagement_id;
  v := authz.require('engagement.end',
         jsonb_build_object('customer_id', v_e.customer_id, 'venue_id', v_e.venue_id,
                            'record_id', p_engagement_id, 'target_type', 'engagement'),
         p_idempotency_key,
         jsonb_build_object('engagement_id', p_engagement_id, 'expected_version', p_expected_version, 'reason', p_reason));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  perform core.transition('core.engagement', p_engagement_id, 'ended', p_expected_version,
                          (v ->> 'decision_context_id')::uuid,
                          jsonb_build_object('ended_at', now(), 'end_reason', p_reason));
  return v;
end $$;

-- Restricting an engagement is an operational decision: appointment basis (Q18).
create function api.suspend_engagement(
  p_idempotency_key text, p_engagement_id uuid, p_expected_version integer, p_reason text,
  p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_e core.engagement;
  v   jsonb;
begin
  select * into v_e from core.engagement where id = p_engagement_id;
  v := authz.require('engagement.suspend',
         jsonb_build_object('customer_id', v_e.customer_id, 'venue_id', v_e.venue_id,
                            'record_id', p_engagement_id, 'target_type', 'engagement'),
         p_idempotency_key,
         jsonb_build_object('engagement_id', p_engagement_id, 'expected_version', p_expected_version, 'reason', p_reason),
         p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  if length(btrim(coalesce(p_reason, ''))) = 0 then
    raise exception 'a reason is required to suspend an engagement' using errcode = '22023';
  end if;
  perform core.transition('core.engagement', p_engagement_id, 'suspended', p_expected_version,
                          (v ->> 'decision_context_id')::uuid,
                          jsonb_build_object('suspended_by_decision_context_id', v ->> 'decision_context_id',
                                             'suspension_reason', p_reason));
  return v;
end $$;

-- Lifting a restriction is limited to its owner, an equivalent appointment holder, or
-- the owner's delegate (invariant 7). People from the restricted organisation are
-- excluded from lifting it.
create function api.reinstate_engagement(
  p_idempotency_key text, p_engagement_id uuid, p_expected_version integer, p_reason text,
  p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_e     core.engagement;
  v_owner uuid;
  v       jsonb;
begin
  select * into v_e from core.engagement where id = p_engagement_id;
  select coalesce(dc.acting_appointment_id, d.delegator_appointment_id) into v_owner
    from core.decision_context dc
    left join core.delegation d on d.id = dc.acting_delegation_id
   where dc.id = v_e.suspended_by_decision_context_id;

  v := authz.require('engagement.reinstate',
         jsonb_build_object(
           'customer_id', v_e.customer_id, 'venue_id', v_e.venue_id,
           'record_id', p_engagement_id, 'target_type', 'engagement',
           'owner_appointment_id', v_owner,
           'excluded_person_ids', coalesce((
              select jsonb_agg(r.person_id) from core.person_organisation_relationship r
               where r.organisation_id = v_e.organisation_id and r.revoked_at is null
                 and now() <@ r.valid_during), '[]')),
         p_idempotency_key,
         jsonb_build_object('engagement_id', p_engagement_id, 'expected_version', p_expected_version, 'reason', p_reason),
         p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  if v_e.status <> 'suspended' then
    raise exception 'this engagement is not suspended' using errcode = 'PT409';
  end if;
  if length(btrim(coalesce(p_reason, ''))) = 0 then
    raise exception 'a reason is required to reinstate an engagement' using errcode = '22023';
  end if;
  perform core.transition('core.engagement', p_engagement_id, 'active', p_expected_version,
                          (v ->> 'decision_context_id')::uuid,
                          jsonb_build_object('suspended_by_decision_context_id', null, 'suspension_reason', null));
  perform audit.record('engagement.reinstated', v_e.customer_id, v_e.venue_id, 'core.engagement',
                       p_engagement_id, p_reason, null);
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Appointments (D-002, D-009)
-- ---------------------------------------------------------------------------

create function core.insert_appointment(
  p_id uuid, p_customer_id uuid, p_venue_id uuid, p_appointee_person_id uuid, p_type_version_id uuid,
  p_appointed_by_person_id uuid, p_appointed_under uuid, p_is_root boolean, p_permit_class_ids uuid[],
  p_scopes jsonb, p_valid_from timestamptz, p_valid_to timestamptz, p_review_due_on date,
  p_limitations_text text, p_status text, p_recorded_by uuid, p_root_evidence_ref text,
  p_competence_evidence_ref text)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  c uuid;
begin
  insert into core.appointment (
    id, customer_id, venue_id, appointee_person_id, appointment_type_version_id, appointed_by_person_id,
    appointed_under_appointment_id, is_root, limitations_text, valid_during, review_due_on, status,
    recorded_by_person_id, root_evidence_ref)
  values (
    p_id, p_customer_id, p_venue_id, p_appointee_person_id, p_type_version_id, p_appointed_by_person_id,
    p_appointed_under, p_is_root, p_limitations_text, tstzrange(p_valid_from, p_valid_to), p_review_due_on,
    p_status, p_recorded_by, p_root_evidence_ref);
  foreach c in array coalesce(p_permit_class_ids, '{}') loop
    insert into core.appointment_permit_class (customer_id, venue_id, appointment_id, permit_class_id)
    values (p_customer_id, p_venue_id, p_id, c);
  end loop;
  perform core.insert_scopes('appointment', p_customer_id, p_venue_id, p_id, p_scopes);
  if p_competence_evidence_ref is not null then
    insert into core.appointment_evidence (customer_id, venue_id, appointment_id, competence_evidence_ref)
    values (p_customer_id, p_venue_id, p_id, p_competence_evidence_ref);
  end if;
  -- Check completeness now rather than at commit, so the caller sees the error.
  set constraints core.appointment_complete immediate;
  set constraints core.appointment_complete deferred;
end $$;

create function api.record_root_appointment(
  p_idempotency_key text, p_venue_id uuid, p_appointee_person_id uuid, p_duty_holder_person_id uuid,
  p_type_version_id uuid, p_permit_class_ids uuid[], p_scopes jsonb, p_valid_from timestamptz,
  p_valid_to timestamptz, p_review_due_on date, p_limitations_text text, p_root_evidence_ref text,
  p_competence_evidence_ref text default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v_customer uuid := core.venue_customer(p_venue_id);
  v    jsonb;
begin
  v := authz.require('appointment.record_root',
         jsonb_build_object('customer_id', v_customer, 'venue_id', p_venue_id, 'record_id', v_id,
                            'target_type', 'appointment',
                            'excluded_person_ids', jsonb_build_array(p_appointee_person_id)),
         p_idempotency_key,
         jsonb_build_object('venue_id', p_venue_id, 'appointee_person_id', p_appointee_person_id,
                            'duty_holder_person_id', p_duty_holder_person_id, 'type_version_id', p_type_version_id,
                            'permit_class_ids', p_permit_class_ids, 'scopes', p_scopes, 'valid_from', p_valid_from,
                            'valid_to', p_valid_to, 'review_due_on', p_review_due_on,
                            'limitations_text', p_limitations_text, 'root_evidence_ref', p_root_evidence_ref,
                            'competence_evidence_ref', p_competence_evidence_ref));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  perform core.insert_appointment(v_id, v_customer, p_venue_id, p_appointee_person_id, p_type_version_id,
    p_duty_holder_person_id, null, true, p_permit_class_ids, p_scopes, p_valid_from, p_valid_to, p_review_due_on,
    p_limitations_text, 'pending_confirmation', (v ->> 'actor_person_id')::uuid, p_root_evidence_ref,
    p_competence_evidence_ref);
  return v;
end $$;

create function api.confirm_root_appointment(p_idempotency_key text, p_appointment_id uuid, p_expected_version integer)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_a core.appointment;
  v   jsonb;
begin
  select * into v_a from core.appointment where id = p_appointment_id;
  v := authz.require('appointment.confirm_root',
         jsonb_build_object('customer_id', v_a.customer_id, 'venue_id', v_a.venue_id,
                            'record_id', p_appointment_id, 'target_type', 'appointment',
                            'excluded_person_ids', jsonb_build_array(v_a.recorded_by_person_id, v_a.appointee_person_id)),
         p_idempotency_key, jsonb_build_object('appointment_id', p_appointment_id, 'expected_version', p_expected_version));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  if not v_a.is_root then
    raise exception 'only root appointments need confirmation' using errcode = 'PT409';
  end if;
  perform core.transition('core.appointment', p_appointment_id, 'pending_acknowledgement', p_expected_version,
                          (v ->> 'decision_context_id')::uuid,
                          jsonb_build_object('confirmed_by_person_id', v ->> 'actor_person_id', 'confirmed_at', now()));
  perform audit.record('appointment.root_confirmed', v_a.customer_id, v_a.venue_id, 'core.appointment',
                       p_appointment_id, null, null);
  return v;
end $$;

create function api.revoke_root_appointment(p_idempotency_key text, p_appointment_id uuid, p_expected_version integer,
                                            p_reason text, p_evidence_ref text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_a core.appointment;
  v   jsonb;
begin
  select * into v_a from core.appointment where id = p_appointment_id;
  v := authz.require('appointment.revoke_root',
         jsonb_build_object('customer_id', v_a.customer_id, 'venue_id', v_a.venue_id,
                            'record_id', p_appointment_id, 'target_type', 'appointment',
                            'excluded_person_ids', jsonb_build_array(v_a.appointee_person_id)),
         p_idempotency_key,
         jsonb_build_object('appointment_id', p_appointment_id, 'expected_version', p_expected_version,
                            'reason', p_reason, 'evidence_ref', p_evidence_ref));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  if not v_a.is_root then
    raise exception 'use revoke_appointment for appointments made within the system' using errcode = 'PT409';
  end if;
  if length(btrim(coalesce(p_reason, ''))) = 0 or length(btrim(coalesce(p_evidence_ref, ''))) = 0 then
    raise exception 'a reason and the duty holder''s evidence are required' using errcode = '22023';
  end if;
  perform core.transition('core.appointment', p_appointment_id, 'revoked', p_expected_version,
                          (v ->> 'decision_context_id')::uuid,
                          jsonb_build_object('revoked_at', now(), 'revoked_by_person_id', v ->> 'actor_person_id',
                                             'revoked_reason', p_reason, 'revocation_evidence_ref', p_evidence_ref));
  return v;
end $$;

create function api.grant_appointment(
  p_idempotency_key text, p_venue_id uuid, p_appointee_person_id uuid, p_type_version_id uuid,
  p_permit_class_ids uuid[], p_scopes jsonb, p_valid_from timestamptz, p_valid_to timestamptz,
  p_review_due_on date default null, p_limitations_text text default null,
  p_competence_evidence_ref text default null, p_acting_appointment_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v_customer uuid := core.venue_customer(p_venue_id);
  v    jsonb;
begin
  v := authz.require('appointment.grant',
         jsonb_build_object(
           'customer_id', v_customer, 'venue_id', p_venue_id, 'record_id', v_id, 'target_type', 'appointment',
           'excluded_person_ids', jsonb_build_array(p_appointee_person_id),
           'spec', jsonb_build_object('type_version_id', p_type_version_id,
                                      'permit_class_ids', to_jsonb(coalesce(p_permit_class_ids, '{}')),
                                      'scopes', p_scopes, 'valid_from', p_valid_from, 'valid_to', p_valid_to)),
         p_idempotency_key,
         jsonb_build_object('venue_id', p_venue_id, 'appointee_person_id', p_appointee_person_id,
                            'type_version_id', p_type_version_id, 'permit_class_ids', p_permit_class_ids,
                            'scopes', p_scopes, 'valid_from', p_valid_from, 'valid_to', p_valid_to,
                            'review_due_on', p_review_due_on, 'limitations_text', p_limitations_text,
                            'competence_evidence_ref', p_competence_evidence_ref),
         p_acting_appointment_id, null);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  perform core.insert_appointment(v_id, v_customer, p_venue_id, p_appointee_person_id, p_type_version_id,
    (v ->> 'actor_person_id')::uuid, (v ->> 'acting_appointment_id')::uuid, false, p_permit_class_ids, p_scopes,
    p_valid_from, p_valid_to, p_review_due_on, p_limitations_text, 'pending_acknowledgement', null, null,
    p_competence_evidence_ref);
  return v;
end $$;

-- D-009: an appointment is not in force until the appointee acknowledges it.
create function api.acknowledge_appointment(p_idempotency_key text, p_appointment_id uuid, p_expected_version integer)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_a core.appointment;
  v   jsonb;
begin
  select * into v_a from core.appointment where id = p_appointment_id;
  v := authz.require('appointment.acknowledge',
         jsonb_build_object('customer_id', v_a.customer_id, 'venue_id', v_a.venue_id,
                            'record_id', p_appointment_id, 'target_type', 'appointment',
                            'subject_person_id', v_a.appointee_person_id),
         p_idempotency_key, jsonb_build_object('appointment_id', p_appointment_id, 'expected_version', p_expected_version));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  perform core.transition('core.appointment', p_appointment_id, 'in_force', p_expected_version,
                          (v ->> 'decision_context_id')::uuid, jsonb_build_object('acknowledged_at', now()));
  return v;
end $$;

create function api.revoke_appointment(p_idempotency_key text, p_appointment_id uuid, p_expected_version integer,
                                       p_reason text, p_acting_appointment_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_a core.appointment;
  v   jsonb;
begin
  select * into v_a from core.appointment where id = p_appointment_id;
  v := authz.require('appointment.revoke',
         jsonb_build_object('customer_id', v_a.customer_id, 'venue_id', v_a.venue_id,
                            'record_id', p_appointment_id, 'target_type', 'appointment',
                            'excluded_person_ids', jsonb_build_array(v_a.appointee_person_id)),
         p_idempotency_key,
         jsonb_build_object('appointment_id', p_appointment_id, 'expected_version', p_expected_version, 'reason', p_reason),
         p_acting_appointment_id, null);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  if length(btrim(coalesce(p_reason, ''))) = 0 then
    raise exception 'a reason is required to revoke an appointment' using errcode = '22023';
  end if;
  perform core.transition('core.appointment', p_appointment_id, 'revoked', p_expected_version,
                          (v ->> 'decision_context_id')::uuid,
                          jsonb_build_object('revoked_at', now(), 'revoked_by_person_id', v ->> 'actor_person_id',
                                             'revoked_reason', p_reason));
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Delegations (invariant 7)
-- ---------------------------------------------------------------------------

create function api.grant_delegation(
  p_idempotency_key text, p_delegator_appointment_id uuid, p_delegate_appointment_id uuid,
  p_action_codes text[], p_permit_class_ids uuid[], p_scopes jsonb,
  p_valid_from timestamptz, p_valid_to timestamptz, p_reason text,
  p_target_type text default null, p_target_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id   uuid := gen_random_uuid();
  v_from core.appointment;
  v_to   core.appointment;
  v      jsonb;
  c      uuid;
begin
  select * into v_from from core.appointment where id = p_delegator_appointment_id;
  select * into v_to from core.appointment where id = p_delegate_appointment_id;
  v := authz.require('delegation.grant',
         jsonb_build_object(
           'customer_id', v_from.customer_id, 'venue_id', v_from.venue_id, 'record_id', v_id,
           'target_type', 'delegation',
           'excluded_person_ids', jsonb_build_array(v_to.appointee_person_id),
           'spec', jsonb_build_object('delegate_appointment_id', p_delegate_appointment_id,
                                      'delegate_person_id', v_to.appointee_person_id,
                                      'action_codes', to_jsonb(p_action_codes),
                                      'permit_class_ids', to_jsonb(coalesce(p_permit_class_ids, '{}')),
                                      'scopes', p_scopes)),
         p_idempotency_key,
         jsonb_build_object('delegator_appointment_id', p_delegator_appointment_id,
                            'delegate_appointment_id', p_delegate_appointment_id, 'action_codes', p_action_codes,
                            'permit_class_ids', p_permit_class_ids, 'scopes', p_scopes, 'valid_from', p_valid_from,
                            'valid_to', p_valid_to, 'reason', p_reason, 'target_type', p_target_type,
                            'target_id', p_target_id),
         p_delegator_appointment_id, null);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  insert into core.delegation (id, customer_id, venue_id, delegator_person_id, delegator_appointment_id,
                               delegate_person_id, delegate_appointment_id, action_codes, permit_class_ids,
                               target_type, target_id, valid_during, reason, status)
  values (v_id, v_from.customer_id, v_from.venue_id, v_from.appointee_person_id, p_delegator_appointment_id,
          v_to.appointee_person_id, p_delegate_appointment_id, p_action_codes, coalesce(p_permit_class_ids, '{}'),
          p_target_type, p_target_id, tstzrange(p_valid_from, p_valid_to), p_reason, 'in_force');
  perform core.insert_scopes('delegation', v_from.customer_id, v_from.venue_id, v_id, p_scopes);
  set constraints core.delegation_complete immediate;
  set constraints core.delegation_complete deferred;
  return v;
end $$;

create function api.revoke_delegation(p_idempotency_key text, p_delegation_id uuid, p_expected_version integer, p_reason text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_d core.delegation;
  v   jsonb;
begin
  select * into v_d from core.delegation where id = p_delegation_id;
  v := authz.require('delegation.revoke',
         jsonb_build_object('customer_id', v_d.customer_id, 'venue_id', v_d.venue_id,
                            'record_id', p_delegation_id, 'target_type', 'delegation',
                            'subject_person_id', v_d.delegator_person_id),
         p_idempotency_key,
         jsonb_build_object('delegation_id', p_delegation_id, 'expected_version', p_expected_version, 'reason', p_reason));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  perform core.transition('core.delegation', p_delegation_id, 'revoked', p_expected_version,
                          (v ->> 'decision_context_id')::uuid,
                          jsonb_build_object('revoked_at', now(), 'revoked_by_person_id', v ->> 'actor_person_id',
                                             'revoked_reason', p_reason));
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Execute grants: only api functions, only for signed-in users
-- ---------------------------------------------------------------------------

grant execute on all functions in schema api to authenticated;
revoke execute on all functions in schema api from anon, public;
