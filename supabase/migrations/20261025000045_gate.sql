-- 0045 Gate (phase 7a, D-020): catalogue, entry rules, gate points, passes, evaluations,
--      scan events and overrides
--
-- Entry is permission to be in a place at a time, never permission to work (CLAUDE.md §1).
-- What each audience needs to enter is venue configuration, drafted by the venue and
-- approved by an appointed access authority, with no default (P7-2). Every scan is
-- evaluated against the live record at that moment and kept (invariant 11); what the
-- operator then did is a separate record. A refusal is set aside only by a time-limited
-- override from an appointed access authority, never for the fixed floor: a restriction,
-- a revoked pass, a deactivated person (P7-6).
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- Catalogue
-- ---------------------------------------------------------------------------
insert into core.authority_action (code, basis, delegable, description) values
  ('entry_rule_version.draft',     'tenant_admin', false, 'Start a draft of the venue''s entry rules (P7-2)'),
  ('entry_rule_version.save_draft','tenant_admin', false, 'Edit a draft of the venue''s entry rules'),
  ('entry_rule_version.propose',   'tenant_admin', false, 'Propose the venue''s entry rules for approval'),
  ('entry_rule_version.approve',   'appointment',  false, 'Approve the venue''s entry rules (Q191, Q192)'),
  ('entry_rule_version.reject',    'appointment',  false, 'Reject a proposed version of the venue''s entry rules'),
  ('entry_rule_version.supersede', 'derived',      false, 'Mark the previous entry rules superseded'),
  ('gate_point.create',            'tenant_admin', false, 'Add a gate point where entry is checked'),
  ('pass.issue_card',              'tenant_admin', false, 'Issue a printed pass to a person (P7-3)'),
  ('pass.create_phone',            'subject',      false, 'Create my own phone pass for a venue'),
  ('pass.revoke',                  'appointment',  true,  'Revoke a pass'),
  ('pass.revoke_for_venue',        'tenant_admin', false, 'Revoke a pass, for the venue'),
  ('gate.operate',                 'appointment',  true,  'Check entry at a gate point (P7-5)'),
  ('gate.override',                'appointment',  true,  'Set aside an entry refusal for a stated time (Q195, P7-6)');

insert into core.derived_action (parent_action, child_action) values
  ('entry_rule_version.approve', 'entry_rule_version.supersede');

insert into core.state_machine (code, table_name) values ('entry_rule_version', 'core.entry_rule_version');
insert into core.state_initial (machine, state, required_action) values ('entry_rule_version', 'draft', 'entry_rule_version.draft');
insert into core.state_transition (machine, from_state, to_state, required_action) values
  ('entry_rule_version', 'draft',    'proposed',   'entry_rule_version.propose'),
  ('entry_rule_version', 'proposed', 'approved',   'entry_rule_version.approve'),
  ('entry_rule_version', 'proposed', 'rejected',   'entry_rule_version.reject'),
  ('entry_rule_version', 'approved', 'superseded', 'entry_rule_version.supersede');

-- ---------------------------------------------------------------------------
-- Entry rules (Q191, Q192, P7-2)
--   {audiences: [{key, name, capacities: [engagement capacity], relationship_kinds: [kind],
--                 event_phase: null | build | live | breakdown, induction_course_ids: [...],
--                 escort: never | always, area_ids: [...]}],
--    never_overridable: [reason code]}
-- ---------------------------------------------------------------------------
create table core.entry_rule_version (
  id                     uuid primary key default gen_random_uuid(),
  customer_id            uuid not null,
  venue_id               uuid not null,
  version_no             integer not null check (version_no > 0),
  status                 text not null,
  content                jsonb not null default '{"audiences": []}',
  source_ref             text,
  authored_by_person_id  uuid not null,
  proposed_by_person_id  uuid,
  decided_by_person_id   uuid,
  decided_at             timestamptz,
  decision_reason        text,
  content_sha256         bytea,
  row_version            integer not null default 1,
  created_at             timestamptz not null default now(),
  created_by_user_id     uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, authored_by_person_id) references core.person (customer_id, id),
  foreign key (customer_id, proposed_by_person_id) references core.person (customer_id, id),
  foreign key (customer_id, decided_by_person_id) references core.person (customer_id, id),
  unique (venue_id, version_no),
  check ((status = 'draft') = (content_sha256 is null))
);
create unique index entry_rule_one_approved on core.entry_rule_version (venue_id) where status = 'approved';
select core.attach_standard_triggers('core.entry_rule_version',
  'status,content,source_ref,proposed_by_person_id,decided_by_person_id,decided_at,decision_reason,content_sha256', null, true);
create function core.entry_rule_freeze() returns trigger
language plpgsql set search_path = '' as $$
begin
  if old.status <> 'draft' and (new.content is distinct from old.content or new.content_sha256 is distinct from old.content_sha256) then
    raise exception 'only a draft of the entry rules can be changed; start a new version instead' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger entry_rule_freeze before update on core.entry_rule_version for each row execute function core.entry_rule_freeze();

-- The refusal reasons the evaluation can give, and whether an override can ever reach them.
create function core.entry_reason_floor() returns text[]
language sql immutable set search_path = '' as $$ select array['pass_revoked', 'pass_unknown', 'person_deactivated', 'person_restricted', 'organisation_restricted'] $$;
create function core.entry_reason_overridable() returns text[]
language sql immutable set search_path = '' as $$ select array['no_reason', 'induction_missing', 'no_rule'] $$;

create function core.validate_entry_rules(p_venue_id uuid, c jsonb, p_strict boolean) returns text[]
language plpgsql stable security definer set search_path = '' as $$
declare errs text[] := '{}'; a jsonb; keys text[] := '{}';
begin
  if jsonb_typeof(c -> 'audiences') is distinct from 'array' then
    return array['Entry rules are a list of audiences.'];
  end if;
  for a in select * from jsonb_array_elements(c -> 'audiences') loop
    if coalesce(a ->> 'key', '') !~ '^[a-z0-9-]{1,60}$' or (a ->> 'key') = any (keys) then
      errs := errs || text 'Every audience needs a unique key of lower-case letters, digits and hyphens.'; continue;
    end if;
    keys := keys || (a ->> 'key');
    if core.blank(a ->> 'name') then errs := errs || format('Audience "%s" needs a name.', a ->> 'key'); end if;
    if jsonb_typeof(a -> 'capacities') is distinct from 'array' or jsonb_array_length(a -> 'capacities') = 0
       or exists (select 1 from jsonb_array_elements_text(a -> 'capacities') x where not exists (select 1 from core.engagement_capacity k where k.code = x)) then
      errs := errs || format('Audience "%s" needs the engagement capacities it covers.', a ->> 'key');
    end if;
    if jsonb_typeof(a -> 'relationship_kinds') is distinct from 'array' or jsonb_array_length(a -> 'relationship_kinds') = 0
       or exists (select 1 from jsonb_array_elements_text(a -> 'relationship_kinds') x
                   where x not in ('employee', 'agency', 'self_employed', 'volunteer', 'subcontractor', 'exhibitor')) then
      errs := errs || format('Audience "%s" needs the kinds of working relationship it covers.', a ->> 'key');
    end if;
    if not a ? 'event_phase' or (jsonb_typeof(a -> 'event_phase') <> 'null' and coalesce(a ->> 'event_phase', '') not in ('build', 'live', 'breakdown')) then
      errs := errs || format('Audience "%s": say whether it applies only in an event phase (build, live, breakdown), or always.', a ->> 'key');
    end if;
    if jsonb_typeof(a -> 'induction_course_ids') is distinct from 'array'
       or exists (select 1 from jsonb_array_elements_text(a -> 'induction_course_ids') x
                   where not exists (select 1 from core.induction_course k where k.id::text = x and k.venue_id = p_venue_id)) then
      errs := errs || format('Audience "%s": state the inductions needed to enter (none is allowed, but must be stated).', a ->> 'key');
    end if;
    if coalesce(a ->> 'escort', '') not in ('never', 'always') then
      errs := errs || format('Audience "%s": choose whether an escort is needed.', a ->> 'key');
    end if;
    if jsonb_typeof(a -> 'area_ids') is distinct from 'array' or jsonb_array_length(a -> 'area_ids') = 0
       or exists (select 1 from jsonb_array_elements_text(a -> 'area_ids') x
                   where not exists (select 1 from core.area k where k.id::text = x and k.venue_id = p_venue_id)) then
      errs := errs || format('Audience "%s": name the areas it may enter.', a ->> 'key');
    end if;
  end loop;
  if c ? 'never_overridable' and (jsonb_typeof(c -> 'never_overridable') is distinct from 'array'
     or exists (select 1 from jsonb_array_elements_text(c -> 'never_overridable') x where not (x = any (core.entry_reason_overridable())))) then
    errs := errs || text 'Never-overridable reasons are chosen from: no reason to be here, induction missing, no rule for the role.';
  end if;
  if p_strict then
    if jsonb_array_length(c -> 'audiences') = 0 then errs := errs || text 'Entry rules need at least one audience.'; end if;
    if not c ? 'never_overridable' then
      errs := errs || text 'Choose which refusals can never be overridden at this venue, beyond the fixed ones (none is allowed, but must be chosen).';
    end if;
  end if;
  return errs;
end $$;

-- ---------------------------------------------------------------------------
-- Gate points and passes (P7-3)
-- ---------------------------------------------------------------------------
create table core.gate_point (
  id                 uuid primary key default gen_random_uuid(),
  customer_id        uuid not null,
  venue_id           uuid not null,
  area_id            uuid not null references core.area,
  name               text not null check (length(btrim(name)) > 0),
  retired_at         timestamptz,
  row_version        integer not null default 1,
  created_at         timestamptz not null default now(),
  created_by_user_id uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  unique (venue_id, name)
);
select core.attach_standard_triggers('core.gate_point', 'name,retired_at');

create table core.person_pass (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null,
  venue_id              uuid not null,
  person_id             uuid not null,
  kind                  text not null check (kind in ('phone', 'card')),
  pass_number           text not null,
  secret                bytea,
  token_hash            bytea,
  issued_by_person_id   uuid not null,
  decision_context_id   uuid not null references core.decision_context,
  revoked_at            timestamptz,
  revoked_by_person_id  uuid,
  revoke_reason         text,
  revoke_decision_context_id uuid references core.decision_context,
  row_version           integer not null default 1,
  created_at            timestamptz not null default clock_timestamp(),
  created_by_user_id    uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, person_id) references core.person (customer_id, id),
  foreign key (customer_id, issued_by_person_id) references core.person (customer_id, id),
  foreign key (customer_id, revoked_by_person_id) references core.person (customer_id, id),
  unique (venue_id, pass_number),
  check ((kind = 'phone') = (secret is not null) and (kind = 'card') = (token_hash is not null)),
  check ((revoked_at is null) = (revoked_by_person_id is null) and (revoked_at is null) = (revoke_reason is null)
         and (revoked_at is null) = (revoke_decision_context_id is null))
);
create unique index person_pass_one_live on core.person_pass (venue_id, person_id, kind) where revoked_at is null;
select core.attach_standard_triggers('core.person_pass', 'revoked_at,revoked_by_person_id,revoke_reason,revoke_decision_context_id', null, false,
                                     'secret,token_hash');
create function core.pass_revoke_once() returns trigger
language plpgsql set search_path = '' as $$
begin
  if old.revoked_at is not null then raise exception 'a pass is revoked once' using errcode = 'check_violation'; end if;
  return new;
end $$;
create trigger pass_revoke_once before update on core.person_pass for each row execute function core.pass_revoke_once();

-- The phone pass's code for a 30-second step: from the pass's own secret, never sent out.
create function core.pass_code(p_secret bytea, p_pass_number text, p_step bigint) returns text
language sql immutable set search_path = '' as $$
  select lpad(((('x' || substr(encode(extensions.hmac(convert_to(p_pass_number || ':' || p_step, 'UTF8'), p_secret, 'sha256'), 'hex'), 1, 8))::bit(32)::bigint)
               % 1000000)::text, 6, '0') $$;

-- ---------------------------------------------------------------------------
-- Evaluations, scans and overrides
-- ---------------------------------------------------------------------------
create table core.entry_override (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  venue_id             uuid not null,
  person_id            uuid not null,
  area_id              uuid not null references core.area,
  reason_codes         text[] not null check (cardinality(reason_codes) > 0),
  purpose              text not null check (length(btrim(purpose)) > 0),
  reason               text not null check (length(btrim(reason)) > 0),
  escort               text,
  valid_during         tstzrange not null check (not isempty(valid_during) and not lower_inf(valid_during) and not upper_inf(valid_during)),
  granted_by_person_id uuid not null,
  decision_context_id  uuid not null references core.decision_context,
  row_version          integer not null default 1,
  created_at           timestamptz not null default clock_timestamp(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, person_id) references core.person (customer_id, id),
  foreign key (customer_id, granted_by_person_id) references core.person (customer_id, id),
  check (not (reason_codes && array['pass_revoked', 'pass_unknown', 'person_deactivated', 'person_restricted', 'organisation_restricted']))
);
select core.attach_standard_triggers('core.entry_override', null);

create table core.entry_eligibility_evaluation (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  venue_id             uuid not null,
  gate_point_id        uuid references core.gate_point,
  person_id            uuid,
  pass_id              uuid references core.person_pass,
  method               text not null check (method in ('phone', 'card', 'manual')),
  outcome              text not null check (outcome in ('admit', 'admit_with_escort', 'check', 'do_not_admit')),
  result               jsonb not null,
  rule_version_id      uuid references core.entry_rule_version,
  operator_person_id   uuid not null,
  decision_context_id  uuid not null references core.decision_context,
  row_version          integer not null default 1,
  evaluated_at         timestamptz not null default clock_timestamp(),
  created_at           timestamptz not null default clock_timestamp(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, operator_person_id) references core.person (customer_id, id)
);
create index entry_evaluation_person on core.entry_eligibility_evaluation (person_id, evaluated_at);
select core.attach_standard_triggers('core.entry_eligibility_evaluation', null);

create table core.scan_event (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  venue_id             uuid not null,
  evaluation_id        uuid not null unique references core.entry_eligibility_evaluation,
  gate_point_id        uuid not null references core.gate_point,
  person_id            uuid,
  direction            text not null check (direction in ('in', 'out')),
  identity_method      text not null check (identity_method in ('photo_id', 'known_to_operator', 'not_checked')),
  action               text not null check (action in ('admitted', 'refused', 'referred')),
  note                 text,
  escort_name          text,
  override_ids         uuid[] not null default '{}',
  operator_person_id   uuid not null,
  decision_context_id  uuid not null references core.decision_context,
  row_version          integer not null default 1,
  created_at           timestamptz not null default clock_timestamp(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, operator_person_id) references core.person (customer_id, id),
  check (action <> 'admitted' or identity_method <> 'not_checked')
);
select core.attach_standard_triggers('core.scan_event', null);

-- ---------------------------------------------------------------------------
-- The evaluation (Q191-Q194): the single place entry is decided. It reads only current
-- records, and decides entry only: permits appear as notices, never as a reason to admit.
-- ---------------------------------------------------------------------------
create function core.entry_evaluation(p_person_id uuid, p_venue_id uuid, p_gate_point_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  pe core.person; rule core.entry_rule_version; gp core.gate_point; gate_path uuid[];
  reasons jsonb := '[]'; notices jsonb := '[]'; best jsonb; cand jsonb; b record; a jsonb; missing jsonb; c text;
  any_engaged boolean := false; any_restricted_org boolean := false; overrides jsonb := '[]'; ov record; outcome text;
  never text[];
begin
  select * into pe from core.person where id = p_person_id;
  select * into gp from core.gate_point where id = p_gate_point_id;
  gate_path := coalesce((select path from core.area where id = gp.area_id), (select path from core.area where venue_id = p_venue_id and parent_id is null));
  select * into rule from core.entry_rule_version where venue_id = p_venue_id and status = 'approved';
  never := array(select jsonb_array_elements_text(coalesce(rule.content -> 'never_overridable', '[]')));

  -- The fixed floor.
  if pe.deactivated_at is not null then
    reasons := reasons || jsonb_build_object('code', 'person_deactivated', 'severity', 'do_not_admit', 'words', 'This person''s record is no longer active.',
                                             'owner', 'The venue''s tenant administrator');
  end if;
  if authz.person_restricted(pe.id, p_venue_id) then
    reasons := reasons || jsonb_build_object('code', 'person_restricted', 'severity', 'do_not_admit', 'words', 'Restricted at this venue.',
                                             'owner', 'The authority that imposed the restriction');
  end if;

  -- A reason to be here now (Q191): an active engagement of an organisation they work with.
  for b in select r.kind, e.id as engagement_id, e.capacity_code, o.id as organisation_id, o.legal_name,
                  authz.organisation_restricted(o.id, p_venue_id) as restricted
             from core.person_organisation_relationship r
             join core.engagement e on e.organisation_id = r.organisation_id
             join core.organisation o on o.id = r.organisation_id
            where r.person_id = pe.id and r.status = 'active' and now() <@ r.valid_during
              and e.venue_id = p_venue_id and e.status = 'active' and now() <@ e.valid_during loop
    if b.restricted then any_restricted_org := true; continue; end if;
    any_engaged := true;
    for a in select x from jsonb_array_elements(coalesce(rule.content -> 'audiences', '[]')) x
              where x -> 'capacities' ? b.capacity_code and x -> 'relationship_kinds' ? b.kind
                and (jsonb_typeof(x -> 'event_phase') = 'null'
                     or exists (select 1 from core.event_phase ph where ph.venue_id = p_venue_id and ph.phase = x ->> 'event_phase' and now() <@ ph.valid_during)) loop
      missing := '[]';
      for c in select jsonb_array_elements_text(a -> 'induction_course_ids') loop
        if not exists (select 1 from core.induction_completion ic join core.course_version k on k.id = ic.course_version_id
                        where ic.person_id = pe.id and k.course_id = c::uuid and ic.valid_until >= now()
                          and not exists (select 1 from core.completion_invalidation i where i.completion_id = ic.id)) then
          missing := missing || jsonb_build_object('code', 'induction_missing', 'severity', 'do_not_admit',
            'words', format('No valid induction: %s.', (select title from core.induction_course where id = c::uuid)),
            'owner', format('%s, by completing it', pe.given_name || ' ' || pe.family_name));
        end if;
      end loop;
      cand := jsonb_build_object('audience', a ->> 'name', 'audience_key', a ->> 'key', 'organisation', b.legal_name, 'organisation_id', b.organisation_id,
                                 'engagement_id', b.engagement_id, 'escort', a ->> 'escort', 'missing', missing,
                                 'area_ids', a -> 'area_ids',
                                 'inductions', (select coalesce(jsonb_agg(jsonb_build_object('course', k.title,
                                                  'valid_until', (select max(ic.valid_until) from core.induction_completion ic join core.course_version cv on cv.id = ic.course_version_id
                                                                   where ic.person_id = pe.id and cv.course_id = k.id
                                                                     and not exists (select 1 from core.completion_invalidation i where i.completion_id = ic.id)))), '[]')
                                                  from core.induction_course k where k.id::text in (select jsonb_array_elements_text(a -> 'induction_course_ids'))));
      -- The most favourable basis: nothing missing first, then without an escort.
      if best is null or (jsonb_array_length(missing) < jsonb_array_length(best -> 'missing'))
         or (jsonb_array_length(missing) = jsonb_array_length(best -> 'missing') and a ->> 'escort' = 'never' and best ->> 'escort' = 'always') then
        best := cand;
      end if;
    end loop;
  end loop;

  if not any_engaged then
    reasons := reasons || case when any_restricted_org
      then jsonb_build_object('code', 'organisation_restricted', 'severity', 'do_not_admit', 'words', 'Their organisation is restricted at this venue.',
                              'owner', 'The authority that imposed the restriction')
      else jsonb_build_object('code', 'no_reason', 'severity', 'do_not_admit', 'words', 'No current engagement or visit here for now.',
                              'owner', 'Their organisation and the venue''s engagement owner') end;
  elsif rule.id is null then
    reasons := reasons || jsonb_build_object('code', 'no_rule', 'severity', 'check', 'words', 'The venue has no approved entry rules.',
                                             'owner', 'The venue''s access authority');
  elsif best is null then
    reasons := reasons || jsonb_build_object('code', 'no_rule', 'severity', 'check', 'words', 'No entry rule covers this person''s role here now.',
                                             'owner', 'The venue''s access authority');
  else
    reasons := reasons || (best -> 'missing');
  end if;

  -- Overrides in force for this place cover the reasons they name, never the floor or the
  -- venue's never-overridable list.
  for ov in select o.* from core.entry_override o where o.person_id = pe.id and o.venue_id = p_venue_id and now() <@ o.valid_during
                                                    and o.area_id = any (gate_path) loop
    if exists (select 1 from jsonb_array_elements(reasons) x where x ->> 'code' = any (ov.reason_codes)
                 and not (x ->> 'code' = any (core.entry_reason_floor())) and not (x ->> 'code' = any (never))) then
      overrides := overrides || jsonb_build_object('id', ov.id, 'reasons', to_jsonb(ov.reason_codes), 'until', upper(ov.valid_during),
                                                   'escort', ov.escort, 'purpose', ov.purpose, 'by', core.person_name(ov.granted_by_person_id));
      reasons := (select coalesce(jsonb_agg(case when x ->> 'code' = any (ov.reason_codes) and not (x ->> 'code' = any (core.entry_reason_floor()))
                                                  and not (x ->> 'code' = any (never))
                                             then x || jsonb_build_object('overridden_by', ov.id) else x end), '[]')
                    from jsonb_array_elements(reasons) x);
    end if;
  end loop;
  reasons := (select coalesce(jsonb_agg(x || jsonb_build_object('overridable', (x ->> 'code') = any (core.entry_reason_overridable()) and not ((x ->> 'code') = any (never)))), '[]')
                from jsonb_array_elements(reasons) x);

  outcome := case
    when exists (select 1 from jsonb_array_elements(reasons) x where x ->> 'severity' = 'do_not_admit' and not x ? 'overridden_by') then 'do_not_admit'
    when exists (select 1 from jsonb_array_elements(reasons) x where x ->> 'severity' = 'check' and not x ? 'overridden_by') then 'check'
    when best ->> 'escort' = 'always' or exists (select 1 from jsonb_array_elements(overrides) o where not core.blank(o ->> 'escort')) then 'admit_with_escort'
    else 'admit' end;

  -- Permits, as notices only (Q193, Q194, P7-12).
  notices := (select coalesce(jsonb_agg(n), '[]') from (
    select format('Not on the %s permit for %s: cannot join that task.', pc.name, w.reference) n
      from core.permit p join core.permit_class pc on pc.id = p.permit_class_id join core.work_package w on w.id = p.work_package_id
     where p.venue_id = p_venue_id and core.is_live(p.status)
       and exists (select 1 from core.permit_team_member m where m.permit_id = p.id and m.person_id = pe.id and m.removed_at is not null)
       and not exists (select 1 from core.permit_team_member m where m.permit_id = p.id and m.person_id = pe.id and m.removed_at is null)
    union all
    select format('The %s work for %s is stopped: do not start it.', pc.name, w.reference)
      from core.permit p join core.permit_class pc on pc.id = p.permit_class_id join core.work_package w on w.id = p.work_package_id
     where p.venue_id = p_venue_id and p.status in ('suspended', 'hand_back_pending')
       and exists (select 1 from core.permit_team_member m where m.permit_id = p.id and m.person_id = pe.id and m.removed_at is null)) z);

  return jsonb_build_object(
    'outcome', outcome,
    'person', jsonb_build_object('id', pe.id, 'name', pe.given_name || ' ' || pe.family_name),
    'organisation', best ->> 'organisation', 'audience', best ->> 'audience', 'engagement_id', best -> 'engagement_id',
    'areas', (select coalesce(jsonb_agg(ar.name order by ar.name), '[]') from core.area ar where ar.id::text in (select jsonb_array_elements_text(coalesce(best -> 'area_ids', '[]')))),
    'escort', coalesce(best ->> 'escort', 'never'),
    'inductions', coalesce(best -> 'inductions', '[]'),
    'reasons', reasons, 'overrides', overrides, 'notices', notices,
    'rule_version_id', rule.id,
    'entry_only', 'This is permission to be here, not permission to work.') ;
end $$;

-- ---------------------------------------------------------------------------
-- Visibility and RLS
-- ---------------------------------------------------------------------------
grant select on core.entry_rule_version, core.gate_point, core.entry_override, core.entry_eligibility_evaluation, core.scan_event to authenticated;
grant select (id, customer_id, venue_id, person_id, kind, pass_number, issued_by_person_id, revoked_at, revoked_by_person_id, revoke_reason,
              row_version, created_at) on core.person_pass to authenticated;

create policy venue_scoped_read on core.entry_rule_version for select to authenticated using (venue_id in (select authz.my_venue_ids()));
create policy venue_scoped_read on core.gate_point for select to authenticated using (venue_id in (select authz.my_venue_ids()));
-- A pass: the person, the venue's administrators and appointees.
create policy pass_read on core.person_pass for select to authenticated
  using (person_id in (select authz.my_person_ids()) or customer_id in (select authz.my_admin_customer_ids())
         or venue_id in (select authz.my_appointee_venue_ids()));
-- Gate records: the person themselves, the venue's administrators, and those who operate or
-- override its gates. Never other contractors.
create policy evaluation_read on core.entry_eligibility_evaluation for select to authenticated
  using (person_id in (select authz.my_person_ids()) or customer_id in (select authz.my_admin_customer_ids())
         or venue_id in (select authz.my_action_venue_ids('gate.operate')) or venue_id in (select authz.my_action_venue_ids('gate.override')));
create policy scan_read on core.scan_event for select to authenticated
  using (person_id in (select authz.my_person_ids()) or customer_id in (select authz.my_admin_customer_ids())
         or venue_id in (select authz.my_action_venue_ids('gate.operate')) or venue_id in (select authz.my_action_venue_ids('gate.override')));
create policy override_read on core.entry_override for select to authenticated
  using (person_id in (select authz.my_person_ids()) or customer_id in (select authz.my_admin_customer_ids())
         or venue_id in (select authz.my_action_venue_ids('gate.operate')) or venue_id in (select authz.my_action_venue_ids('gate.override')));
