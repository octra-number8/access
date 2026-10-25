-- 0029 Work packages and activity screening API (phase 4a, D-017)
--
-- Pattern as before: checks about content or readiness run before authz.require and
-- return a refusal value (the request key is not consumed); authority is decided only
-- by authz.evaluate; status changes only through core.transition, with derived
-- decisions for the records one decision creates or settles.
--
-- Who acts for a job: an administrator of its performing organisation, or of a
-- commissioning party with an active engagement at the venue (organisation_admin
-- actions), or a tenant administrator of the venue (the *_for_venue actions). Accepting
-- or challenging a recommendation and providing external evidence are for the party
-- organisations only. Decisions (challenges, "no permit required", external evidence)
-- are appointment-based and exclude everyone connected with the job.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

-- ---------------------------------------------------------------------------
-- Helpers (not executable by clients)
-- ---------------------------------------------------------------------------

-- A repeated request (same key, same user, same action) goes straight to authz.require,
-- which replays the original decision or refuses a reused key, before any readiness
-- check could give a different answer the second time.
create or replace function core.authorised_or_refusal(p_action text, p_target jsonb, p_key text, p_request jsonb,
                                                      p_appt uuid default null, p_deleg uuid default null)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare v jsonb;
begin
  if exists (select 1 from core.decision_context
              where actor_user_id = auth.uid() and action_code = p_action and idempotency_key = p_key) then
    return authz.require(p_action, p_target, p_key, p_request, p_appt, p_deleg);
  end if;
  v := authz.evaluate(p_action, p_target, p_appt, p_deleg);
  if (v ->> 'allowed')::boolean then return null; end if;
  return authz.require(p_action, p_target, p_key, p_request, p_appt, p_deleg);
end $$;

-- The party organisation the caller administers for this job (performing first, then
-- commissioning), or null.
create function core.wp_actor_org(p_wp_id uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select o from (
    select wp.performing_organisation_id as o, 0 as rank from core.work_package wp where wp.id = p_wp_id
    union all
    select p.organisation_id, 1 from core.work_package wp
      join core.work_package_party p on p.revision_id = wp.current_revision_id and p.role = 'commissioning'
     where wp.id = p_wp_id) x
   where x.o in (select authz.my_admin_organisation_ids())
   order by rank limit 1 $$;

-- The action to use: the organisation-administrator form when the caller administers a
-- party, otherwise the venue form for a tenant administrator, otherwise the
-- organisation form (which authz.evaluate then refuses with the right explanation).
create function core.wp_action(p_base text, p_wp_id uuid, p_customer_id uuid) returns text
language sql stable security definer set search_path = '' as $$
  select case when core.wp_actor_org(p_wp_id) is not null then p_base
              when p_customer_id in (select authz.my_admin_customer_ids()) then p_base || '_for_venue'
              else p_base end $$;

-- Areas and systems of a revision, for scoping decisions to every place the job touches.
create function core.revision_scope(p_revision_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'area_id', (select a.area_id from core.work_package_area a join core.area x on x.id = a.area_id
                 where a.revision_id = p_revision_id order by cardinality(x.path), x.code, a.area_id limit 1),
    'area_ids', coalesce((select jsonb_agg(a.area_id) from core.work_package_area a where a.revision_id = p_revision_id), '[]'),
    'system_ids', coalesce((select jsonb_agg(s.system_id) from core.work_package_system s where s.revision_id = p_revision_id), '[]')) $$;

-- Everyone connected with the job: its creator, every revision's author, contact and
-- supervisor, and everyone working with any party organisation (invariant 3).
create function core.work_package_people(p_wp_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(distinct x), '[]') from (
    select to_jsonb(wp.created_by_person_id) x from core.work_package wp where wp.id = p_wp_id
    union all
    select to_jsonb(r.author_person_id) from core.work_package_revision r where r.work_package_id = p_wp_id
    union all
    select to_jsonb(r.contact_person_id) from core.work_package_revision r where r.work_package_id = p_wp_id
    union all
    select to_jsonb(r.supervisor_person_id) from core.work_package_revision r
     where r.work_package_id = p_wp_id and r.supervisor_person_id is not null
    union all
    select jsonb_array_elements(core.organisation_people(o.org)) from (
      select wp.performing_organisation_id org from core.work_package wp where wp.id = p_wp_id
      union
      select p.organisation_id from core.work_package_revision r
        join core.work_package_party p on p.revision_id = r.id where r.work_package_id = p_wp_id) o
  ) s $$;

-- Base target for a decision about a job.
create function core.wp_target(p_wp core.work_package, p_record_id uuid, p_type text, p_org uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('customer_id', p_wp.customer_id, 'venue_id', p_wp.venue_id, 'record_id', p_record_id,
                            'target_type', p_type, 'organisation_id', p_org,
                            'performing_organisation_id', p_wp.performing_organisation_id) $$;

-- Plain-English problems with a revision's content. Empty means it can be saved.
--   {title, scope, method?, window_from, window_to, contact_person_id, supervisor_person_id?,
--    area_ids: [..], system_ids: [..], parties: [{organisation_id, role}]}
create function core.revision_problems(p_venue_id uuid, p_performer uuid, p_input jsonb) returns text[]
language plpgsql stable security definer set search_path = '' as $$
declare
  errs text[] := '{}';
  v_customer uuid := core.venue_customer(p_venue_id);
  p jsonb;
begin
  if length(btrim(coalesce(p_input ->> 'title', ''))) = 0 then errs := errs || text 'Give the job a title.'; end if;
  if length(btrim(coalesce(p_input ->> 'scope', ''))) = 0 then errs := errs || text 'Describe the scope of the work.'; end if;
  begin
    if (p_input ->> 'window_from')::timestamptz is null or (p_input ->> 'window_to')::timestamptz is null
       or (p_input ->> 'window_to')::timestamptz <= (p_input ->> 'window_from')::timestamptz then
      errs := errs || text 'Give an estimated start and an end after it.';
    end if;
  exception when others then
    errs := errs || text 'The planned dates are not valid dates.';
  end;
  if jsonb_typeof(p_input -> 'area_ids') is distinct from 'array' or jsonb_array_length(p_input -> 'area_ids') = 0 then
    errs := errs || text 'Choose at least one area where the work happens.';
  elsif exists (select 1 from jsonb_array_elements_text(p_input -> 'area_ids') x
                 where x !~ '^[0-9a-f-]{36}$'
                    or not exists (select 1 from core.area a where a.id = x::uuid and a.venue_id = p_venue_id
                                                               and a.retired_at is null)) then
    errs := errs || text 'One of the areas is not a current area at this venue.';
  end if;
  if jsonb_typeof(coalesce(p_input -> 'system_ids', '[]')) <> 'array'
     or exists (select 1 from jsonb_array_elements_text(coalesce(p_input -> 'system_ids', '[]')) x
                 where x !~ '^[0-9a-f-]{36}$'
                    or not exists (select 1 from core.system s where s.id = x::uuid and s.venue_id = p_venue_id
                                                                 and s.retired_at is null)) then
    errs := errs || text 'One of the systems is not a current system at this venue.';
  end if;
  if coalesce(p_input ->> 'contact_person_id', '') !~ '^[0-9a-f-]{36}$'
     or not exists (select 1 from core.person x where x.id = (p_input ->> 'contact_person_id')::uuid
                                                and x.customer_id = v_customer) then
    errs := errs || text 'Name a contact for the job.';
  end if;
  if p_input ->> 'supervisor_person_id' is not null and (
       (p_input ->> 'supervisor_person_id') !~ '^[0-9a-f-]{36}$'
       or not exists (select 1 from core.person_organisation_relationship r
                       where r.person_id = (p_input ->> 'supervisor_person_id')::uuid
                         and r.organisation_id = p_performer and r.status = 'active' and now() <@ r.valid_during)) then
    errs := errs || text 'The supervisor must currently work with the performing organisation.';
  end if;
  if jsonb_typeof(coalesce(p_input -> 'parties', '[]')) <> 'array' then
    errs := errs || text 'Parties must be a list.';
  else
    for p in select * from jsonb_array_elements(coalesce(p_input -> 'parties', '[]')) loop
      if coalesce(p ->> 'role', '') not in ('commissioning', 'principal_contractor', 'affected_occupier', 'landlord_operator') then
        errs := errs || text 'Each other party is commissioning, principal contractor, affected occupier or landlord/operator; the performing organisation is set by the engagement.';
      elsif coalesce(p ->> 'organisation_id', '') !~ '^[0-9a-f-]{36}$'
            or not exists (select 1 from core.organisation o where o.id = (p ->> 'organisation_id')::uuid
                                                             and o.customer_id = v_customer) then
        errs := errs || text 'One of the parties is not a known organisation.';
      end if;
    end loop;
  end if;
  return errs;
end $$;

-- Writes a revision and its areas, systems and parties (the performing organisation is
-- always a party). Runs inside an authorised decision.
create function core.insert_revision(p_wp core.work_package, p_no integer, p_kind text, p_reason text, p_input jsonb,
                                     p_author uuid, p_ctx uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid := gen_random_uuid();
begin
  insert into core.work_package_revision (id, customer_id, venue_id, work_package_id, revision_no, change_kind, reason,
    title, scope, method, planned_window, contact_person_id, supervisor_person_id, author_person_id, decision_context_id)
  values (v_id, p_wp.customer_id, p_wp.venue_id, p_wp.id, p_no, p_kind, p_reason,
    btrim(p_input ->> 'title'), btrim(p_input ->> 'scope'), nullif(btrim(coalesce(p_input ->> 'method', '')), ''),
    tstzrange((p_input ->> 'window_from')::timestamptz, (p_input ->> 'window_to')::timestamptz),
    (p_input ->> 'contact_person_id')::uuid, (p_input ->> 'supervisor_person_id')::uuid, p_author, p_ctx);
  insert into core.work_package_area (customer_id, venue_id, revision_id, area_id)
  select distinct p_wp.customer_id, p_wp.venue_id, v_id, x::uuid from jsonb_array_elements_text(p_input -> 'area_ids') x;
  insert into core.work_package_system (customer_id, venue_id, revision_id, system_id)
  select distinct p_wp.customer_id, p_wp.venue_id, v_id, x::uuid
    from jsonb_array_elements_text(coalesce(p_input -> 'system_ids', '[]')) x;
  insert into core.work_package_party (customer_id, venue_id, revision_id, organisation_id, role)
  values (p_wp.customer_id, p_wp.venue_id, v_id, p_wp.performing_organisation_id, 'performing');
  insert into core.work_package_party (customer_id, venue_id, revision_id, organisation_id, role)
  select distinct p_wp.customer_id, p_wp.venue_id, v_id, (p ->> 'organisation_id')::uuid, p ->> 'role'
    from jsonb_array_elements(coalesce(p_input -> 'parties', '[]')) p;
  return v_id;
end $$;

-- What a revision says, in a comparable form.
create function core.revision_facts(p_revision_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'scope', r.scope, 'method', r.method, 'window', r.planned_window::text, 'supervisor', r.supervisor_person_id,
    'areas', (select coalesce(jsonb_agg(a.area_id order by a.area_id), '[]') from core.work_package_area a where a.revision_id = r.id),
    'systems', (select coalesce(jsonb_agg(s.system_id order by s.system_id), '[]') from core.work_package_system s where s.revision_id = r.id),
    'parties', (select coalesce(jsonb_agg(jsonb_build_array(p.organisation_id, p.role) order by p.organisation_id, p.role), '[]')
                  from core.work_package_party p where p.revision_id = r.id),
    'title', r.title, 'contact', r.contact_person_id)
    from core.work_package_revision r where r.id = p_revision_id $$;

create function core.input_facts(p_performer uuid, p_input jsonb) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'scope', btrim(p_input ->> 'scope'), 'method', nullif(btrim(coalesce(p_input ->> 'method', '')), ''),
    'window', tstzrange((p_input ->> 'window_from')::timestamptz, (p_input ->> 'window_to')::timestamptz)::text,
    'supervisor', (p_input ->> 'supervisor_person_id')::uuid,
    'areas', (select coalesce(jsonb_agg(distinct x::uuid order by x::uuid), '[]') from jsonb_array_elements_text(p_input -> 'area_ids') x),
    'systems', (select coalesce(jsonb_agg(distinct x::uuid order by x::uuid), '[]')
                  from jsonb_array_elements_text(coalesce(p_input -> 'system_ids', '[]')) x),
    'parties', (select coalesce(jsonb_agg(distinct y order by y), '[]') from (
                  select jsonb_build_array(p_performer, 'performing') y
                  union all
                  select jsonb_build_array((p ->> 'organisation_id')::uuid, p ->> 'role')
                    from jsonb_array_elements(coalesce(p_input -> 'parties', '[]')) p) z),
    'title', btrim(p_input ->> 'title'), 'contact', (p_input ->> 'contact_person_id')::uuid) $$;

-- Invariant 6: the kind of change is decided by which facts changed, never by the person.
create function core.change_kind(p_old jsonb, p_new jsonb) returns text
language sql immutable set search_path = '' as $$
  select case
    when p_old = p_new then null
    when (p_old - 'title' - 'contact') is distinct from (p_new - 'title' - 'contact') then 'material'
    else 'administrative' end $$;

create function core.current_screening_version(p_venue_id uuid) returns core.screening_set_version
language sql stable security definer set search_path = '' as $$
  select * from core.screening_set_version where venue_id = p_venue_id and status = 'approved' $$;

-- Routed: every recommendation settled, every hold accepted, and either a class is
-- required or an authority has recorded that none is (P4-6).
create function core.wp_routable(p_wp_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select wp.status = 'screening'
     and not exists (select 1 from core.screening_recommendation x
                      where x.revision_id = wp.screened_revision_id and x.status in ('recommended', 'challenged'))
     and not exists (select 1 from core.external_reference_hold h
                      where h.revision_id = wp.screened_revision_id and h.status in ('open', 'refused'))
     and (exists (select 1 from core.screening_recommendation x
                   where x.revision_id = wp.screened_revision_id and x.status in ('accepted', 'upheld'))
          or exists (select 1 from core.no_permit_required_decision n where n.revision_id = wp.screened_revision_id))
    from core.work_package wp where wp.id = p_wp_id $$;

-- Routes the job if it is now routable. Runs inside the decision that settled it.
create function core.try_route(p_wp_id uuid, p_parent uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if not core.wp_routable(p_wp_id) then return false; end if;
  perform authz.derive('work_package.route', 'work_package', p_wp_id);
  perform core.transition('core.work_package', p_wp_id, 'routed',
                          (select row_version from core.work_package where id = p_wp_id),
                          core.ctx_uuid('decision_context_id'));
  perform authz.resume(p_parent);
  return true;
end $$;

create function core.wording_problem(p_text text) returns text
language sql immutable set search_path = '' as $$
  select case when length(btrim(coalesce(p_text, ''))) = 0 then 'State the scope the decision covers.'
              when p_text ~* '(approv|certif|verif|guarant|complian|safe to)'
                then 'The scope wording must not say the work is approved, certified, verified, guaranteed, compliant or safe. Describe what was decided and for what work.'
         end $$;

-- Documents an applicant may attach: their own organisation's, or provided by it.
create function core.documents_of(p_org uuid, p_version_ids uuid[]) returns boolean
language sql stable security definer set search_path = '' as $$
  select not exists (
    select 1 from unnest(coalesce(p_version_ids, '{}')) v
     where not exists (select 1 from core.document_version dv join core.document d on d.id = dv.document_id
                        where dv.id = v and (d.organisation_id = p_org or d.provided_via_organisation_id = p_org))) $$;

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

create function api.create_work_type(p_idempotency_key text, p_venue_id uuid, p_code text, p_label text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_id uuid := gen_random_uuid(); v_customer uuid := core.venue_customer(p_venue_id); v jsonb;
begin
  v := authz.require('work_type.create',
         jsonb_build_object('customer_id', v_customer, 'venue_id', p_venue_id, 'record_id', v_id, 'target_type', 'work_type'),
         p_idempotency_key, jsonb_build_object('venue_id', p_venue_id, 'code', p_code, 'label', p_label));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.work_type (id, customer_id, venue_id, code, label) values (v_id, v_customer, p_venue_id, p_code, p_label);
  return v || jsonb_build_object('id', v_id);
end $$;

create function api.create_external_class(p_idempotency_key text, p_venue_id uuid, p_code text, p_name text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_id uuid := gen_random_uuid(); v_customer uuid := core.venue_customer(p_venue_id); v jsonb;
begin
  v := authz.require('permit_class.create_external',
         jsonb_build_object('customer_id', v_customer, 'venue_id', p_venue_id, 'record_id', v_id, 'target_type', 'permit_class'),
         p_idempotency_key, jsonb_build_object('venue_id', p_venue_id, 'code', p_code, 'name', p_name));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.permit_class (id, customer_id, venue_id, code, name, handling)
  values (v_id, v_customer, p_venue_id, p_code, p_name, 'external_reference');
  return v || jsonb_build_object('id', v_id);
end $$;

-- A new draft starts from the latest version's content, so a venue edits rather than retypes.
create function api.create_screening_draft(p_idempotency_key text, p_venue_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_id uuid := gen_random_uuid(); v_customer uuid := core.venue_customer(p_venue_id); v jsonb; prev core.screening_set_version;
begin
  v := authz.require('screening_set.draft',
         jsonb_build_object('customer_id', v_customer, 'venue_id', p_venue_id, 'record_id', v_id, 'target_type', 'screening_set_version'),
         p_idempotency_key, jsonb_build_object('venue_id', p_venue_id));
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  if exists (select 1 from core.screening_set_version where venue_id = p_venue_id and status in ('draft', 'proposed')) then
    raise exception 'this venue already has a screening version in progress; finish or reject it first' using errcode = '22023';
  end if;
  select * into prev from core.screening_set_version where venue_id = p_venue_id order by version_no desc limit 1;
  insert into core.screening_set_version (id, customer_id, venue_id, version_no, status, content, authored_by_person_id)
  values (v_id, v_customer, p_venue_id, coalesce(prev.version_no, 0) + 1, 'draft',
          coalesce(prev.content, '{"questions": [], "rules": []}'), (v ->> 'actor_person_id')::uuid);
  return v || jsonb_build_object('id', v_id);
end $$;

create function api.save_screening_draft(p_idempotency_key text, p_version_id uuid, p_expected_version integer,
                                         p_content jsonb, p_source_ref text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s core.screening_set_version; t jsonb; r jsonb; v jsonb; problems text[];
begin
  select * into s from core.screening_set_version where id = p_version_id;
  t := jsonb_build_object('customer_id', s.customer_id, 'venue_id', s.venue_id, 'record_id', p_version_id,
                          'target_type', 'screening_set_version');
  r := jsonb_build_object('version_id', p_version_id, 'expected_version', p_expected_version, 'content', p_content);
  v := core.authorised_or_refusal('screening_set.save_draft', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if s.status <> 'draft' then
    raise exception 'only a draft screening version can be changed' using errcode = 'PT409';
  end if;
  problems := core.validate_screening_content(s.venue_id, p_content, false);
  if cardinality(problems) > 0 then
    return core.refuse('screening_set.save_draft', 'invalid_content', 'The screening content has problems.',
                       'Each item listed', 'Whoever is editing the screening', jsonb_build_object('problems', to_jsonb(problems)));
  end if;
  v := authz.require('screening_set.save_draft', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  if s.row_version <> p_expected_version then
    raise exception 'this screening version changed since you opened it' using errcode = 'PT409';
  end if;
  update core.screening_set_version set content = p_content, source_ref = p_source_ref where id = p_version_id;
  return v;
end $$;

create function api.propose_screening_version(p_idempotency_key text, p_version_id uuid, p_expected_version integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s core.screening_set_version; t jsonb; r jsonb; v jsonb; problems text[];
begin
  select * into s from core.screening_set_version where id = p_version_id;
  t := jsonb_build_object('customer_id', s.customer_id, 'venue_id', s.venue_id, 'record_id', p_version_id,
                          'target_type', 'screening_set_version');
  r := jsonb_build_object('version_id', p_version_id, 'expected_version', p_expected_version);
  v := core.authorised_or_refusal('screening_set.propose', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  problems := core.validate_screening_content(s.venue_id, s.content, true);
  if cardinality(problems) > 0 then
    return core.refuse('screening_set.propose', 'not_ready', 'This screening version is not ready for approval.',
                       'Each item listed', 'Whoever is editing the screening', jsonb_build_object('problems', to_jsonb(problems)));
  end if;
  v := authz.require('screening_set.propose', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.screening_set_version', p_version_id, 'proposed', p_expected_version,
    (v ->> 'decision_context_id')::uuid,
    jsonb_build_object('proposed_by_person_id', v ->> 'actor_person_id',
                       'content_sha256', encode(sha256(convert_to(s.content::text, 'UTF8')), 'hex')));
  return v;
end $$;

-- Q55-Q56: the venue's technical authority approves the questions and rules. The author
-- and proposer are excluded. Approval supersedes the previous approved version.
create function api.decide_screening_version(p_idempotency_key text, p_version_id uuid, p_expected_version integer,
                                             p_decision text, p_reason text, p_acting_appointment_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s core.screening_set_version; prev uuid; ctx uuid; t jsonb; r jsonb; v jsonb; problems text[];
begin
  if p_decision not in ('approve', 'reject') then
    raise exception 'decision must be approve or reject' using errcode = '22023';
  end if;
  select * into s from core.screening_set_version where id = p_version_id;
  t := jsonb_build_object('customer_id', s.customer_id, 'venue_id', s.venue_id, 'record_id', p_version_id,
                          'target_type', 'screening_set_version',
                          'excluded_person_ids', jsonb_build_array(s.authored_by_person_id, s.proposed_by_person_id));
  r := jsonb_build_object('version_id', p_version_id, 'expected_version', p_expected_version,
                          'decision', p_decision, 'reason', p_reason);
  v := core.authorised_or_refusal('screening_set.' || p_decision, t, p_idempotency_key, r, p_acting_appointment_id);
  if v is not null then return v; end if;
  if s.status <> 'proposed' then
    return core.refuse('screening_set.' || p_decision, 'not_proposed', 'Only a proposed screening version can be decided.',
                       'A proposed version', 'The venue''s tenant administrator, who proposes it');
  end if;
  v := authz.require('screening_set.' || p_decision, t, p_idempotency_key, r, p_acting_appointment_id, null);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ctx := (v ->> 'decision_context_id')::uuid;
  if length(btrim(coalesce(p_reason, ''))) = 0 then
    raise exception 'give a reason for the decision' using errcode = '22023';
  end if;
  if p_decision = 'approve' then
    problems := core.validate_screening_content(s.venue_id, s.content, true);
    if cardinality(problems) > 0 then
      raise exception 'this screening version cannot be approved: %', array_to_string(problems, ' ') using errcode = '22023';
    end if;
    select id into prev from core.screening_set_version where venue_id = s.venue_id and status = 'approved';
    if prev is not null then
      perform authz.derive('screening_set.supersede', 'screening_set_version', prev);
      perform core.transition('core.screening_set_version', prev, 'superseded',
                              (select row_version from core.screening_set_version where id = prev),
                              core.ctx_uuid('decision_context_id'));
      perform authz.resume(ctx);
    end if;
  end if;
  perform core.transition('core.screening_set_version', p_version_id,
                          case p_decision when 'approve' then 'approved' else 'rejected' end, p_expected_version, ctx,
                          jsonb_build_object('decided_by_person_id', v ->> 'actor_person_id', 'decided_at', now(),
                                             'decision_reason', p_reason));
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Work packages (Q48-Q54)
-- ---------------------------------------------------------------------------

create function api.create_work_package(p_idempotency_key text, p_venue_id uuid, p_engagement_id uuid,
                                        p_work_type_id uuid, p_input jsonb,
                                        p_event_id uuid default null, p_event_phase_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  e        core.engagement;
  wp       core.work_package;
  v_id     uuid := gen_random_uuid();
  v_org    uuid;
  v_action text;
  t jsonb; r jsonb; v jsonb; problems text[]; rev uuid;
begin
  select * into e from core.engagement where id = p_engagement_id and venue_id = p_venue_id;
  -- Acting for the performing organisation, a commissioning party engaged at the venue, or the venue.
  if e.organisation_id in (select authz.my_admin_organisation_ids()) then
    v_org := e.organisation_id;
  else
    select (p ->> 'organisation_id')::uuid into v_org from jsonb_array_elements(coalesce(p_input -> 'parties', '[]')) p
     where p ->> 'role' = 'commissioning'
       and (p ->> 'organisation_id')::uuid in (select authz.my_admin_organisation_ids())
       and exists (select 1 from core.engagement x where x.organisation_id = (p ->> 'organisation_id')::uuid
                     and x.venue_id = p_venue_id and x.status = 'active' and now() <@ x.valid_during)
     limit 1;
  end if;
  v_action := case when v_org is null and core.venue_customer(p_venue_id) in (select authz.my_admin_customer_ids())
                   then 'work_package.create_for_venue' else 'work_package.create' end;
  t := jsonb_build_object('customer_id', core.venue_customer(p_venue_id), 'venue_id', p_venue_id, 'record_id', v_id,
                          'target_type', 'work_package', 'organisation_id', coalesce(v_org, e.organisation_id),
                          'performing_organisation_id', e.organisation_id);
  r := jsonb_build_object('venue_id', p_venue_id, 'engagement_id', p_engagement_id, 'work_type_id', p_work_type_id,
                          'event_id', p_event_id, 'event_phase_id', p_event_phase_id, 'input', p_input);
  v := core.authorised_or_refusal(v_action, t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if e.id is null or e.status <> 'active' or not (now() <@ e.valid_during) then
    return core.refuse(v_action, 'engagement_not_active',
      'Work can be started only for an organisation whose engagement at this venue has been approved and is current.',
      'An active engagement for the performing organisation', 'The venue''s compliance authority, who approves engagements');
  end if;
  if not exists (select 1 from core.work_type w where w.id = p_work_type_id and w.venue_id = p_venue_id and w.retired_at is null) then
    return core.refuse(v_action, 'invalid_content', 'Choose a current work type for this venue.', 'A work type', 'You');
  end if;
  if p_event_id is not null and not exists (select 1 from core.event ev where ev.id = p_event_id and ev.venue_id = p_venue_id)
     or p_event_phase_id is not null and not exists (select 1 from core.event_phase ph where ph.id = p_event_phase_id
                                                       and ph.event_id = p_event_id) then
    return core.refuse(v_action, 'invalid_content', 'The event or event phase is not at this venue.', 'A matching event', 'You');
  end if;
  problems := core.revision_problems(p_venue_id, e.organisation_id, p_input);
  if cardinality(problems) > 0 then
    return core.refuse(v_action, 'invalid_content', 'The job description has problems.', 'Each item listed', 'You',
                       jsonb_build_object('problems', to_jsonb(problems)));
  end if;
  v := authz.require(v_action, t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;

  perform pg_advisory_xact_lock(hashtext('work_package_reference:' || p_venue_id::text));
  insert into core.work_package (id, customer_id, venue_id, reference, work_type_id, event_id, event_phase_id,
                                 performing_engagement_id, performing_organisation_id, status, created_by_person_id)
  values (v_id, e.customer_id, p_venue_id,
          'WP-' || lpad(((select count(*) from core.work_package x where x.venue_id = p_venue_id) + 1)::text, 5, '0'),
          p_work_type_id, p_event_id, p_event_phase_id, e.id, e.organisation_id, 'draft', (v ->> 'actor_person_id')::uuid)
  returning * into wp;
  rev := core.insert_revision(wp, 1, 'initial', null, p_input, (v ->> 'actor_person_id')::uuid, (v ->> 'decision_context_id')::uuid);
  update core.work_package set current_revision_id = rev where id = v_id;
  insert into core.screening_draft (customer_id, venue_id, work_package_id) values (e.customer_id, p_venue_id, v_id);
  return v || jsonb_build_object('id', v_id, 'reference', wp.reference);
end $$;

-- Q53, invariant 6: every change is a new revision; a material change after submission
-- supersedes the screening outcome and returns the job to draft.
create function api.revise_work_package(p_idempotency_key text, p_work_package_id uuid, p_expected_version integer,
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
    perform authz.derive('work_package.reopen', 'work_package', wp.id);
    perform core.transition('core.work_package', wp.id, 'draft', wp.row_version, core.ctx_uuid('decision_context_id'),
                            jsonb_build_object('current_revision_id', rev, 'screened_revision_id', null));
    perform authz.resume(ctx);
  else
    update core.work_package set current_revision_id = rev where id = wp.id;
  end if;
  return v || jsonb_build_object('revision_id', rev, 'change_kind', v_kind);
end $$;

-- Draft answers and directly selected classes (Q55's direct route), saved as the
-- applicant goes; they lock on submission.
create function api.save_screening_answers(p_idempotency_key text, p_work_package_id uuid, p_answers jsonb,
                                           p_selected_class_ids uuid[] default '{}')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare wp core.work_package; v_action text; t jsonb; r jsonb; v jsonb;
begin
  select * into wp from core.work_package where id = p_work_package_id;
  v_action := core.wp_action('work_package.answer', p_work_package_id, wp.customer_id);
  t := core.wp_target(wp, p_work_package_id, 'work_package', coalesce(core.wp_actor_org(p_work_package_id), wp.performing_organisation_id));
  r := jsonb_build_object('work_package_id', p_work_package_id, 'answers', p_answers, 'selected', p_selected_class_ids);
  v := core.authorised_or_refusal(v_action, t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if wp.status <> 'draft' then
    return core.refuse(v_action, 'not_draft', 'Answers can only change while the job is a draft.',
                       'A draft job (a change to the job returns it to draft)', 'You');
  end if;
  if jsonb_typeof(p_answers) is distinct from 'object'
     or exists (select 1 from jsonb_each(p_answers) a where jsonb_typeof(a.value) <> 'array') then
    return core.refuse(v_action, 'invalid_content', 'Answers must be lists of chosen options.', 'Valid answers', 'You');
  end if;
  if exists (select 1 from unnest(coalesce(p_selected_class_ids, '{}')) c
              where not exists (select 1 from core.permit_class pc where pc.id = c and pc.venue_id = wp.venue_id
                                  and pc.handling = 'permit' and pc.retired_at is null)) then
    return core.refuse(v_action, 'invalid_content', 'One of the selected permit classes is not available at this venue.',
                       'A current permit class', 'You');
  end if;
  v := authz.require(v_action, t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  update core.screening_draft set answers = p_answers, selected_class_ids = coalesce(p_selected_class_ids, '{}')
   where work_package_id = p_work_package_id;
  return v;
end $$;

-- Locks the answers, runs the venue's approved rules and stores the outcome.
create function api.submit_work_package(p_idempotency_key text, p_work_package_id uuid, p_expected_version integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  wp core.work_package; s core.screening_set_version; d core.screening_draft; e core.engagement;
  v_action text; t jsonb; r jsonb; v jsonb; ctx uuid; problems text[]; c record; v_rec uuid; routed boolean;
  n_rec integer := 0; n_hold integer := 0;
begin
  select * into wp from core.work_package where id = p_work_package_id;
  v_action := core.wp_action('work_package.submit', p_work_package_id, wp.customer_id);
  t := core.wp_target(wp, p_work_package_id, 'work_package', coalesce(core.wp_actor_org(p_work_package_id), wp.performing_organisation_id));
  r := jsonb_build_object('work_package_id', p_work_package_id, 'expected_version', p_expected_version);
  v := core.authorised_or_refusal(v_action, t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if wp.status <> 'draft' then
    return core.refuse(v_action, 'not_draft', 'Only a draft job can be submitted for screening.', 'A draft job', 'You');
  end if;
  s := core.current_screening_version(wp.venue_id);
  if s.id is null then
    return core.refuse(v_action, 'no_screening',
      'This venue has no approved activity screening yet, so jobs cannot be screened.',
      'An approved screening version', 'The venue''s technical authority');
  end if;
  select * into e from core.engagement where id = wp.performing_engagement_id;
  if e.status <> 'active' or not (now() <@ e.valid_during) then
    return core.refuse(v_action, 'engagement_not_active',
      'The performing organisation''s engagement at this venue is not active.',
      'An active engagement', 'The venue''s compliance authority, who approves engagements');
  end if;
  select * into d from core.screening_draft where work_package_id = p_work_package_id;
  problems := core.screening_answer_problems(s.content, d.answers);
  if cardinality(problems) > 0 then
    return core.refuse(v_action, 'answers_incomplete', 'The screening answers are not complete.', 'Each item listed', 'You',
                       jsonb_build_object('problems', to_jsonb(problems)));
  end if;
  v := authz.require(v_action, t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ctx := (v ->> 'decision_context_id')::uuid;

  insert into core.screening_response (customer_id, venue_id, work_package_id, revision_id, set_version_id, answers,
                                       selected_class_ids, respondent_person_id, decision_context_id)
  values (wp.customer_id, wp.venue_id, wp.id, wp.current_revision_id, s.id, d.answers, d.selected_class_ids,
          (v ->> 'actor_person_id')::uuid, ctx);
  perform core.transition('core.work_package', wp.id, 'screening', p_expected_version, ctx,
                          jsonb_build_object('screened_revision_id', wp.current_revision_id));

  -- One recommendation per class: from matched rules, from the applicant's direct
  -- selection, or both. A class the applicant chose is accepted by that choice.
  for c in
    select pc.id as class_id, pc.handling, coalesce(array_agg(m.rule_key order by m.rule_key) filter (where m.rule_key is not null), '{}') as rules,
           pc.id = any (d.selected_class_ids) as selected
      from core.permit_class pc
      left join core.screening_matches(s.content, d.answers) m on m.permit_class_id = pc.id
     where pc.venue_id = wp.venue_id and (m.rule_key is not null or pc.id = any (d.selected_class_ids))
     group by pc.id, pc.handling
  loop
    v_rec := gen_random_uuid();
    if c.handling = 'external_reference' then
      perform authz.derive('screening.hold', 'external_reference_hold', v_rec);
      insert into core.external_reference_hold (id, customer_id, venue_id, work_package_id, revision_id, permit_class_id,
                                                matched_rule_keys, status)
      values (v_rec, wp.customer_id, wp.venue_id, wp.id, wp.current_revision_id, c.class_id, c.rules, 'open');
      n_hold := n_hold + 1;
    else
      perform authz.derive('screening.recommend', 'screening_recommendation', v_rec);
      insert into core.screening_recommendation (id, customer_id, venue_id, work_package_id, revision_id, permit_class_id,
                                                 matched_rule_keys, applicant_selected, status)
      values (v_rec, wp.customer_id, wp.venue_id, wp.id, wp.current_revision_id, c.class_id, c.rules, c.selected,
              case when c.selected then 'accepted' else 'recommended' end);
      n_rec := n_rec + 1;
    end if;
    perform authz.resume(ctx);
  end loop;
  routed := core.try_route(wp.id, ctx);
  return v || jsonb_build_object('recommendations', n_rec, 'holds', n_hold, 'routed', routed);
end $$;

create function api.cancel_work_package(p_idempotency_key text, p_work_package_id uuid, p_expected_version integer,
                                        p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare wp core.work_package; v_action text; t jsonb; r jsonb; v jsonb;
begin
  select * into wp from core.work_package where id = p_work_package_id;
  v_action := core.wp_action('work_package.cancel', p_work_package_id, wp.customer_id);
  t := core.wp_target(wp, p_work_package_id, 'work_package', coalesce(core.wp_actor_org(p_work_package_id), wp.performing_organisation_id));
  r := jsonb_build_object('work_package_id', p_work_package_id, 'expected_version', p_expected_version, 'reason', p_reason);
  v := core.authorised_or_refusal(v_action, t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if length(btrim(coalesce(p_reason, ''))) = 0 then
    return core.refuse(v_action, 'invalid_content', 'Say why the job is being cancelled.', 'A reason', 'You');
  end if;
  v := authz.require(v_action, t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  perform core.transition('core.work_package', wp.id, 'cancelled', p_expected_version, (v ->> 'decision_context_id')::uuid,
                          jsonb_build_object('cancel_reason', p_reason));
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Recommendations, challenges and "no permit required" (Q58, Q59)
-- ---------------------------------------------------------------------------

create function api.accept_recommendation(p_idempotency_key text, p_recommendation_id uuid, p_expected_version integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare x core.screening_recommendation; wp core.work_package; t jsonb; r jsonb; v jsonb; ctx uuid; routed boolean;
begin
  select * into x from core.screening_recommendation where id = p_recommendation_id;
  select * into wp from core.work_package where id = x.work_package_id;
  t := core.wp_target(wp, p_recommendation_id, 'screening_recommendation',
                      coalesce(core.wp_actor_org(wp.id), wp.performing_organisation_id));
  r := jsonb_build_object('recommendation_id', p_recommendation_id, 'expected_version', p_expected_version);
  v := core.authorised_or_refusal('screening.accept', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if x.status <> 'recommended' then
    return core.refuse('screening.accept', 'not_open', 'This recommendation has already been settled or replaced.',
                       'An open recommendation', 'Nobody');
  end if;
  v := authz.require('screening.accept', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ctx := (v ->> 'decision_context_id')::uuid;
  perform core.transition('core.screening_recommendation', x.id, 'accepted', p_expected_version, ctx);
  routed := core.try_route(wp.id, ctx);
  return v || jsonb_build_object('routed', routed);
end $$;

create function api.challenge_recommendation(p_idempotency_key text, p_recommendation_id uuid, p_expected_version integer,
                                             p_reason text, p_document_version_ids uuid[] default '{}')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare x core.screening_recommendation; wp core.work_package; t jsonb; r jsonb; v jsonb; v_org uuid;
begin
  select * into x from core.screening_recommendation where id = p_recommendation_id;
  select * into wp from core.work_package where id = x.work_package_id;
  v_org := coalesce(core.wp_actor_org(wp.id), wp.performing_organisation_id);
  t := core.wp_target(wp, p_recommendation_id, 'screening_recommendation', v_org);
  r := jsonb_build_object('recommendation_id', p_recommendation_id, 'expected_version', p_expected_version,
                          'reason', p_reason, 'documents', p_document_version_ids);
  v := core.authorised_or_refusal('screening.challenge', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if x.status <> 'recommended' then
    return core.refuse('screening.challenge', 'not_open', 'Only an open recommendation can be challenged.',
                       'An open recommendation', 'Nobody');
  end if;
  if length(btrim(coalesce(p_reason, ''))) = 0 then
    return core.refuse('screening.challenge', 'invalid_content', 'Say why you think this permit is not needed.', 'A reason', 'You');
  end if;
  if not core.documents_of(v_org, p_document_version_ids) then
    return core.refuse('screening.challenge', 'invalid_content', 'Supporting documents must be your organisation''s own.',
                       'Your organisation''s documents', 'You');
  end if;
  v := authz.require('screening.challenge', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.screening_challenge (customer_id, venue_id, recommendation_id, reason, document_version_ids,
                                        raised_by_person_id, decision_context_id)
  values (x.customer_id, x.venue_id, x.id, p_reason, coalesce(p_document_version_ids, '{}'),
          (v ->> 'actor_person_id')::uuid, (v ->> 'decision_context_id')::uuid);
  perform core.transition('core.screening_recommendation', x.id, 'challenged', p_expected_version,
                          (v ->> 'decision_context_id')::uuid);
  return v;
end $$;

-- Decided by an appointee whose appointment covers this permit class and every area and
-- system of the job. Everyone connected with the job, and the challenger, are excluded.
create function api.decide_challenge(p_idempotency_key text, p_recommendation_id uuid, p_expected_version integer,
                                     p_outcome text, p_reason text, p_scope_wording text default null,
                                     p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  x core.screening_recommendation; wp core.work_package; ch core.screening_challenge;
  t jsonb; r jsonb; v jsonb; ctx uuid; routed boolean; problem text;
begin
  if p_outcome not in ('upheld', 'not_required') then
    raise exception 'outcome must be upheld or not_required' using errcode = '22023';
  end if;
  select * into x from core.screening_recommendation where id = p_recommendation_id;
  select * into wp from core.work_package where id = x.work_package_id;
  select * into ch from core.screening_challenge where recommendation_id = p_recommendation_id;
  t := core.wp_target(wp, p_recommendation_id, 'screening_recommendation', null)
       || core.revision_scope(x.revision_id)
       || jsonb_build_object('permit_class_id', x.permit_class_id,
                             'excluded_person_ids', core.work_package_people(wp.id) || coalesce(to_jsonb(ch.raised_by_person_id), '[]'));
  r := jsonb_build_object('recommendation_id', p_recommendation_id, 'expected_version', p_expected_version,
                          'outcome', p_outcome, 'reason', p_reason, 'scope_wording', p_scope_wording);
  v := core.authorised_or_refusal('screening.decide', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if x.status <> 'challenged' then
    return core.refuse('screening.decide', 'not_open', 'This recommendation is not waiting for a challenge decision.',
                       'A challenged recommendation', 'Nobody');
  end if;
  problem := case when length(btrim(coalesce(p_reason, ''))) = 0 then 'Give the reason for the decision.'
                  when p_outcome = 'not_required' then core.wording_problem(p_scope_wording) end;
  if problem is not null then
    return core.refuse('screening.decide', 'invalid_content', problem, 'A reason and scope wording', 'You');
  end if;
  v := authz.require('screening.decide', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ctx := (v ->> 'decision_context_id')::uuid;
  insert into core.challenge_decision (customer_id, venue_id, challenge_id, outcome, reason, decider_person_id, decision_context_id)
  values (x.customer_id, x.venue_id, ch.id, p_outcome, p_reason, (v ->> 'actor_person_id')::uuid, ctx);
  if p_outcome = 'not_required' then
    insert into core.no_permit_required_decision (customer_id, venue_id, work_package_id, revision_id, recommendation_id,
                                                  scope_wording, reason, decider_person_id, decision_context_id)
    values (x.customer_id, x.venue_id, wp.id, x.revision_id, x.id, p_scope_wording, p_reason, (v ->> 'actor_person_id')::uuid, ctx);
  end if;
  perform core.transition('core.screening_recommendation', x.id, p_outcome, p_expected_version, ctx);
  routed := core.try_route(wp.id, ctx);
  return v || jsonb_build_object('routed', routed);
end $$;

-- P4-6: nothing recommended is not a decision; an appointed authority records it.
create function api.record_no_permit_required(p_idempotency_key text, p_work_package_id uuid, p_expected_version integer,
                                              p_scope_wording text, p_reason text,
                                              p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare wp core.work_package; t jsonb; r jsonb; v jsonb; ctx uuid; routed boolean; problem text;
begin
  select * into wp from core.work_package where id = p_work_package_id;
  t := core.wp_target(wp, p_work_package_id, 'work_package', null)
       || core.revision_scope(wp.screened_revision_id)
       || jsonb_build_object('excluded_person_ids', core.work_package_people(wp.id));
  r := jsonb_build_object('work_package_id', p_work_package_id, 'expected_version', p_expected_version,
                          'scope_wording', p_scope_wording, 'reason', p_reason);
  v := core.authorised_or_refusal('screening.decide', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if wp.status <> 'screening' then
    return core.refuse('screening.decide', 'not_ready', 'Only a job in screening can have this decision.', 'A job in screening',
                       'Whoever is preparing the job');
  end if;
  if exists (select 1 from core.screening_recommendation x where x.revision_id = wp.screened_revision_id) then
    return core.refuse('screening.decide', 'has_recommendations',
      'Screening recommended permits for this job; each is settled by acceptance or by deciding a challenge.',
      'A challenge for each recommendation the applicant disputes', 'The applicant');
  end if;
  problem := case when length(btrim(coalesce(p_reason, ''))) = 0 then 'Give the reason for the decision.'
                  else core.wording_problem(p_scope_wording) end;
  if problem is not null then
    return core.refuse('screening.decide', 'invalid_content', problem, 'A reason and scope wording', 'You');
  end if;
  v := authz.require('screening.decide', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ctx := (v ->> 'decision_context_id')::uuid;
  if wp.row_version <> p_expected_version then
    raise exception 'this job changed since you opened it' using errcode = 'PT409';
  end if;
  insert into core.no_permit_required_decision (customer_id, venue_id, work_package_id, revision_id, scope_wording, reason,
                                                decider_person_id, decision_context_id)
  values (wp.customer_id, wp.venue_id, wp.id, wp.screened_revision_id, p_scope_wording, p_reason,
          (v ->> 'actor_person_id')::uuid, ctx);
  routed := core.try_route(wp.id, ctx);
  return v || jsonb_build_object('routed', routed);
end $$;

-- ---------------------------------------------------------------------------
-- Deferred specialist work (CLAUDE.md §7, Q82)
-- ---------------------------------------------------------------------------

create function api.add_external_evidence(p_idempotency_key text, p_hold_id uuid, p_external_decider text,
                                          p_external_organisation text, p_reference text, p_scope text, p_decided_on date,
                                          p_conditions text default null, p_document_version_ids uuid[] default '{}')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare h core.external_reference_hold; wp core.work_package; t jsonb; r jsonb; v jsonb; v_id uuid := gen_random_uuid(); v_org uuid;
begin
  select * into h from core.external_reference_hold where id = p_hold_id;
  select * into wp from core.work_package where id = h.work_package_id;
  v_org := coalesce(core.wp_actor_org(wp.id), wp.performing_organisation_id);
  t := core.wp_target(wp, v_id, 'external_reference_evidence', v_org);
  r := jsonb_build_object('hold_id', p_hold_id, 'decider', p_external_decider, 'organisation', p_external_organisation,
                          'reference', p_reference, 'scope', p_scope, 'decided_on', p_decided_on,
                          'conditions', p_conditions, 'documents', p_document_version_ids);
  v := core.authorised_or_refusal('external_reference.add_evidence', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if h.status <> 'open' then
    return core.refuse('external_reference.add_evidence', 'not_open', 'This hold has already been decided.', 'An open hold', 'Nobody');
  end if;
  if not core.documents_of(v_org, p_document_version_ids) then
    return core.refuse('external_reference.add_evidence', 'invalid_content',
                       'Supporting documents must be your organisation''s own.', 'Your organisation''s documents', 'You');
  end if;
  v := authz.require('external_reference.add_evidence', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.external_reference_evidence (id, customer_id, venue_id, hold_id, external_decider, external_organisation,
    reference, scope, decided_on, conditions, document_version_ids, submitted_by_person_id, decision_context_id)
  values (v_id, h.customer_id, h.venue_id, h.id, p_external_decider, p_external_organisation, p_reference, p_scope,
          p_decided_on, p_conditions, coalesce(p_document_version_ids, '{}'), (v ->> 'actor_person_id')::uuid,
          (v ->> 'decision_context_id')::uuid);
  return v || jsonb_build_object('id', v_id);
end $$;

create function api.decide_external_reference(p_idempotency_key text, p_hold_id uuid, p_expected_version integer,
                                              p_outcome text, p_reason text,
                                              p_acting_appointment_id uuid default null, p_acting_delegation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare h core.external_reference_hold; wp core.work_package; t jsonb; r jsonb; v jsonb; ctx uuid; routed boolean;
begin
  if p_outcome not in ('accepted', 'refused') then
    raise exception 'outcome must be accepted or refused' using errcode = '22023';
  end if;
  select * into h from core.external_reference_hold where id = p_hold_id;
  select * into wp from core.work_package where id = h.work_package_id;
  t := core.wp_target(wp, p_hold_id, 'external_reference_hold', null)
       || core.revision_scope(h.revision_id)
       || jsonb_build_object('permit_class_id', h.permit_class_id, 'excluded_person_ids', core.work_package_people(wp.id));
  r := jsonb_build_object('hold_id', p_hold_id, 'expected_version', p_expected_version, 'outcome', p_outcome, 'reason', p_reason);
  v := core.authorised_or_refusal('external_reference.decide', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if v is not null then return v; end if;
  if length(btrim(coalesce(p_reason, ''))) = 0 then
    return core.refuse('external_reference.decide', 'invalid_content', 'Give the reason for the decision.', 'A reason', 'You');
  end if;
  if h.status <> 'open' then
    return core.refuse('external_reference.decide', 'not_open', 'This hold has already been decided or replaced.',
                       'An open hold', 'Nobody');
  end if;
  if p_outcome = 'accepted' and not exists (select 1 from core.external_reference_evidence e where e.hold_id = p_hold_id) then
    return core.refuse('external_reference.decide', 'evidence_incomplete',
      'There is no external evidence to accept yet.', 'Evidence from the external decision-maker', 'The applicant');
  end if;
  v := authz.require('external_reference.decide', t, p_idempotency_key, r, p_acting_appointment_id, p_acting_delegation_id);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  ctx := (v ->> 'decision_context_id')::uuid;
  insert into core.external_reference_decision (customer_id, venue_id, hold_id, outcome, reason, decider_person_id, decision_context_id)
  values (h.customer_id, h.venue_id, h.id, p_outcome, p_reason, (v ->> 'actor_person_id')::uuid, ctx);
  perform core.transition('core.external_reference_hold', h.id, p_outcome, p_expected_version, ctx);
  routed := core.try_route(wp.id, ctx);
  return v || jsonb_build_object('routed', routed);
end $$;

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------
create or replace view api.permit_class with (security_invoker = true) as select * from core.permit_class;
create view api.work_type                   with (security_invoker = true) as select * from core.work_type;
create view api.screening_set_version       with (security_invoker = true) as
  select id, customer_id, venue_id, version_no, status, content, source_ref, authored_by_person_id, proposed_by_person_id,
         decided_by_person_id, decided_at, decision_reason, encode(content_sha256, 'hex') as content_sha256, row_version, created_at
    from core.screening_set_version;
create view api.work_package                with (security_invoker = true) as select * from core.work_package;
create view api.work_package_revision       with (security_invoker = true) as
  select id, customer_id, venue_id, work_package_id, revision_no, change_kind, reason, title, scope, method,
         lower(planned_window) as window_from, upper(planned_window) as window_to, contact_person_id, supervisor_person_id,
         author_person_id, decision_context_id, created_at
    from core.work_package_revision;
create view api.work_package_area           with (security_invoker = true) as select * from core.work_package_area;
create view api.work_package_system         with (security_invoker = true) as select * from core.work_package_system;
create view api.work_package_party          with (security_invoker = true) as select * from core.work_package_party;
create view api.screening_draft             with (security_invoker = true) as select * from core.screening_draft;
create view api.screening_response          with (security_invoker = true) as select * from core.screening_response;
create view api.screening_recommendation    with (security_invoker = true) as select * from core.screening_recommendation;
create view api.screening_challenge         with (security_invoker = true) as select * from core.screening_challenge;
create view api.challenge_decision          with (security_invoker = true) as select * from core.challenge_decision;
create view api.no_permit_required_decision with (security_invoker = true) as select * from core.no_permit_required_decision;
create view api.external_reference_hold     with (security_invoker = true) as select * from core.external_reference_hold;
create view api.external_reference_evidence with (security_invoker = true) as select * from core.external_reference_evidence;
create view api.external_reference_decision with (security_invoker = true) as select * from core.external_reference_decision;

grant select on all tables in schema api to authenticated;
grant execute on all functions in schema api to authenticated;
revoke execute on all functions in schema api from anon, public;
