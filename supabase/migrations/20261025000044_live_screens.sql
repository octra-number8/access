-- 0044 Reads for the live-control screens (phase 6d, D-019), and venue emergency contacts
--
-- The supervisor's live view must show emergency contacts (CLAUDE.md §6). They are venue
-- configuration with an owner and a date, published by a tenant administrator, and shown
-- with the permit to everyone who can see it. Until a venue publishes them the view says
-- so; there is no default number.
--
-- api.my_live_permits lists the permits someone is on the team of, so a supervisor finds
-- their permit on a phone. api.live_board lists, for venue authorities, the live permits at
-- their venues with what is holding each one and who can resolve it: actions, owners and
-- deadlines, not counts (CLAUDE.md §6). Neither decides anything.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.

insert into core.authority_action (code, basis, delegable, description) values
  ('venue_emergency_contacts.publish', 'tenant_admin', false, 'Publish the venue''s emergency contacts shown on live permits');

create table core.venue_emergency_contacts (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null,
  venue_id             uuid not null,
  contacts             jsonb not null check (jsonb_typeof(contacts) = 'array' and jsonb_array_length(contacts) > 0),
  owner_person_id      uuid not null,
  effective_from       timestamptz not null,
  change_reason        text not null check (length(btrim(change_reason)) > 0),
  decision_context_id  uuid not null references core.decision_context,
  row_version          integer not null default 1,
  created_at           timestamptz not null default clock_timestamp(),
  created_by_user_id   uuid default auth.uid(),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id),
  foreign key (customer_id, owner_person_id) references core.person (customer_id, id)
);
select core.attach_standard_triggers('core.venue_emergency_contacts', null);
grant select on core.venue_emergency_contacts to authenticated;
create policy venue_scoped_read on core.venue_emergency_contacts for select to authenticated using (venue_id in (select authz.my_venue_ids()));

create function core.emergency_contacts(p_venue_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select c.contacts from core.venue_emergency_contacts c where c.venue_id = p_venue_id and c.effective_from <= now()
   order by c.effective_from desc, c.created_at desc limit 1 $$;

--   p_contacts: [{label, phone}] — venue numbers (control room, security, first aid), never a person's own.
create function api.publish_emergency_contacts(p_idempotency_key text, p_venue_id uuid, p_contacts jsonb, p_change_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare vn core.venue; t jsonb; r jsonb; v jsonb; c_id uuid := gen_random_uuid();
begin
  select * into vn from core.venue where id = p_venue_id;
  t := jsonb_build_object('customer_id', vn.customer_id, 'venue_id', vn.id, 'record_id', c_id, 'target_type', 'venue_emergency_contacts');
  r := jsonb_build_object('venue_id', p_venue_id, 'contacts', p_contacts, 'reason', p_change_reason);
  v := core.authorised_or_refusal('venue_emergency_contacts.publish', t, p_idempotency_key, r);
  if v is not null then return v; end if;
  if jsonb_typeof(p_contacts) is distinct from 'array' or jsonb_array_length(p_contacts) = 0
     or exists (select 1 from jsonb_array_elements(p_contacts) x
                 where core.blank(x ->> 'label') or coalesce(x ->> 'phone', '') !~ '^\+?[0-9 ()-]{6,20}$')
     or core.blank(p_change_reason) then
    return core.refuse('venue_emergency_contacts.publish', 'invalid_content', 'Give each contact a label and a phone number, and say why the list is changing.',
                       'Each contact', 'You');
  end if;
  v := authz.require('venue_emergency_contacts.publish', t, p_idempotency_key, r);
  if not (v ->> 'ok')::boolean or (v ->> 'replayed')::boolean then return v; end if;
  insert into core.venue_emergency_contacts (id, customer_id, venue_id, contacts, owner_person_id, effective_from, change_reason, decision_context_id)
  values (c_id, vn.customer_id, vn.id, p_contacts, (v ->> 'actor_person_id')::uuid, now(), p_change_reason, (v ->> 'decision_context_id')::uuid);
  return v;
end $$;

do $m$
declare d text;
begin
  d := pg_get_functiondef('api.permit_detail(uuid)'::regprocedure);
  if position('''close_out'', core.permit_close_out(p.id));' in d) = 0 then
    raise exception 'api.permit_detail no longer has the expected structure';
  end if;
  execute replace(d, '''close_out'', core.permit_close_out(p.id));',
                     '''close_out'', core.permit_close_out(p.id), ''emergency_contacts'', core.emergency_contacts(p.venue_id));');
end $m$;

-- One permit, for lists.
create function core.permit_summary(p core.permit) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id, 'kind', p.kind, 'status', p.status, 'class_name', pc.name, 'job_reference', w.reference,
    'job_title', (select title from core.work_package_revision where id = w.current_revision_id),
    'organisation', (select legal_name from core.organisation where id = w.performing_organisation_id),
    'areas', (select coalesce(jsonb_agg(a.name order by a.name), '[]') from core.area a where a.id = any (core.live_area_ids(p.id))),
    'window_end', core.permit_window_end(p.id), 'venue_timezone', (select timezone from core.venue where id = p.venue_id),
    'holding', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'kind', s.kind, 'reason', s.reason, 'at', s.created_at,
                                                             'who', core.suspension_owner(s)) order by s.created_at), '[]')
                  from core.permit_suspension s where s.permit_id = p.id and core.suspension_holding(s.id)),
    'reissue_pending', coalesce(core.reissue_pending(p.id), false),
    'extension_pending', exists (select 1 from core.permit_extension e where e.issue_snapshot_id = p.issue_snapshot_id and e.acknowledged_at is null),
    'revalidation_overdue', coalesce((core.revalidation_status(p.id) ->> 'overdue')::boolean, false),
    'duties', jsonb_array_length(core.hand_back_duties(p.id)),
    'area_return_pending', exists (select 1 from core.area_return x where x.permit_id = p.id and x.outcome is null),
    'abandoned', exists (select 1 from core.permit_abandonment a where a.permit_id = p.id))
  from core.permit_class pc, core.work_package w where pc.id = p.permit_class_id and w.id = p.work_package_id $$;

-- The permits the caller is on the live team of.
create function api.my_live_permits() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('ok', true, 'permits', coalesce(jsonb_agg(core.permit_summary(p) || jsonb_build_object('role', m.role)
                                                                      order by p.status = 'active' desc, core.permit_window_end(p.id)), '[]'))
    from core.permit p join core.permit_team_member m on m.permit_id = p.id
   where m.removed_at is null and m.person_id in (select authz.my_person_ids())
     and (p.status in ('issued_awaiting_acceptance', 'active', 'suspended', 'hand_back_pending')
          or (p.status = 'expired' and jsonb_array_length(core.hand_back_duties(p.id)) > 0)) $$;

-- The live board for venue authorities: live permits and what holds them, area stops in
-- force, and emergency work whose retrospective permit is overdue.
create function api.live_board() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('ok', true,
    'permits', (select coalesce(jsonb_agg(core.permit_summary(p)
                  order by case p.status when 'hand_back_pending' then 0 when 'suspended' then 1 when 'expired' then 2
                                         when 'issued_awaiting_acceptance' then 3 else 4 end, core.permit_window_end(p.id)), '[]')
                  from core.permit p
                 where (p.venue_id in (select authz.my_appointee_venue_ids()) or p.customer_id in (select authz.my_admin_customer_ids()))
                   and (p.status in ('issued_awaiting_acceptance', 'active', 'suspended', 'hand_back_pending')
                        or (p.status = 'expired' and jsonb_array_length(core.hand_back_duties(p.id)) > 0))),
    'area_stops', (select coalesce(jsonb_agg(jsonb_build_object('id', z.id, 'area', a.name, 'area_id', a.id, 'category', z.category, 'reason', z.reason,
                                                                'by', core.person_name(z.stopped_by_person_id), 'at', z.created_at,
                                                                'venue_timezone', (select timezone from core.venue where id = z.venue_id))
                                            order by z.created_at desc), '[]')
                     from core.area_stop z join core.area a on a.id = z.area_id
                    where not exists (select 1 from core.area_stop_lift l where l.area_stop_id = z.id)
                      and (z.venue_id in (select authz.my_appointee_venue_ids()) or z.customer_id in (select authz.my_admin_customer_ids()))),
    'emergencies_overdue', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'reference', e.reference, 'deadline_at', e.deadline_at,
                                                                         'organisation', (select legal_name from core.organisation where id = e.organisation_id))
                                                     order by e.deadline_at), '[]')
                              from core.emergency_work e
                             where (core.emergency_status(e) ->> 'overdue')::boolean
                               and (e.venue_id in (select authz.my_appointee_venue_ids()) or e.customer_id in (select authz.my_admin_customer_ids())))) $$;

-- Fix (6b): the impairment refusal's list of missing measures overwrote the refusal's own
-- "what is missing" wording; the list now travels as items.
do $m$
declare d text;
begin
  d := pg_get_functiondef('api.impair_system(text,uuid,integer,jsonb,jsonb,uuid,uuid)'::regprocedure);
  if position('jsonb_build_object(''missing'', missing)' in d) = 0 then
    raise exception 'api.impair_system no longer has the expected structure';
  end if;
  execute replace(d, 'jsonb_build_object(''missing'', missing)', 'jsonb_build_object(''items'', missing)');
end $m$;

-- Personal locks carry their holder, so the holder can take their own lock off.
do $m$
declare d text;
begin
  d := pg_get_functiondef('core.permit_controls(uuid)'::regprocedure);
  if position('jsonb_build_object(''id'', k.id, ''name'', core.person_name(k.person_id),' in d) = 0 then
    raise exception 'core.permit_controls no longer has the expected structure';
  end if;
  execute replace(d, 'jsonb_build_object(''id'', k.id, ''name'', core.person_name(k.person_id),',
                     'jsonb_build_object(''id'', k.id, ''person_id'', k.person_id, ''name'', core.person_name(k.person_id),');
end $m$;

create view api.venue_emergency_contacts with (security_invoker = true) as select * from core.venue_emergency_contacts;

grant select on all tables in schema api to authenticated;
grant execute on all functions in schema api to authenticated;
revoke execute on all functions in schema api from anon, public;
