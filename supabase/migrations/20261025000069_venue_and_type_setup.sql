-- 0069 Venue creation and appointment type screens
--
-- What the screens need that the API did not have: refusals in words, instead of a constraint
-- error, for a venue code already used by the customer, a time zone the database does not
-- know, and an appointment type code already used at the venue. Who may do these is unchanged
-- (tenant administration, 0003); nothing here grants authority.
--
-- Rollback / recovery: forward-only. To withdraw, restore api.create_venue and
-- api.create_appointment_type from 0012. No recorded data changes.

create or replace function api.create_venue(p_idempotency_key text, p_customer_id uuid, p_code text, p_name text, p_timezone text)
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
  if exists (select 1 from core.venue x where x.customer_id = p_customer_id and x.code = p_code) then
    raise exception 'that code is already used by another of your venues' using errcode = '22023';
  end if;
  if not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = p_timezone) then
    raise exception 'choose a time zone from the list' using errcode = '22023';
  end if;

  insert into core.venue (id, customer_id, code, name, timezone, status)
  values (v_id, p_customer_id, p_code, p_name, p_timezone, 'onboarding');
  -- Every venue has exactly one root area, the whole site.
  insert into core.area (customer_id, venue_id, code, name)
  values (p_customer_id, v_id, 'SITE', p_name);
  return v || jsonb_build_object('root_area_id',
    (select id from core.area where venue_id = v_id and parent_id is null));
end $$;

create or replace function api.create_appointment_type(p_idempotency_key text, p_venue_id uuid, p_code text, p_name text)
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
  if exists (select 1 from core.appointment_type t where t.venue_id = p_venue_id and t.code = p_code) then
    raise exception 'that code is already used by another appointment type at this venue' using errcode = '22023';
  end if;

  insert into core.appointment_type (id, customer_id, venue_id, code, name)
  values (v_id, v_customer, p_venue_id, p_code, p_name);
  return v;
end $$;
