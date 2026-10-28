-- 0062 What legal holds keep back, per category (decision 8d-12, D-023)
--
-- When a hold keeps back every record due in a category, no batch is made, so until now the
-- retention page could not show that the hold was working. Each run of the retention job now
-- records, per venue and category, how many records due for disposal holds kept back and which
-- holds did so. The row is written only when that changes (the job runs every minute), so
-- `changed_at` says since when the current picture has held. A category skipped because a batch is
-- already awaiting a decision keeps its last check; the batch shows its own held-back list.
--
-- Rollback / recovery: forward-only. To withdraw, replace api.run_retention_jobs and
-- api.retention_overview with their 0060 definitions and drop core.record_hold_check and
-- core.retention_hold_check; nothing else reads the table.

-- Foreign keys are deferrable like every other in core (0061), so a confirmed disposal can defer them.
create table core.retention_hold_check (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null references core.customer deferrable initially immediate,
  venue_id             uuid not null,
  category             text not null,
  rule_config_id       uuid not null references core.venue_config_version deferrable initially immediate,
  held_count           integer not null check (held_count >= 0),
  held_back            jsonb not null default '[]' check (jsonb_typeof(held_back) = 'array'),
  changed_at           timestamptz not null default clock_timestamp(),
  row_version          integer not null default 1,
  created_at           timestamptz not null default clock_timestamp(),
  created_by_user_id   uuid default auth.uid(),
  unique (venue_id, category),
  foreign key (customer_id, venue_id) references core.venue (customer_id, id) deferrable initially immediate
);
select core.attach_standard_triggers('core.retention_hold_check', 'rule_config_id,held_count,held_back,changed_at');

create function core.record_hold_check(p_venue core.venue, p_category text, p_rule uuid, p_count integer, p_holds jsonb) returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into core.retention_hold_check (customer_id, venue_id, category, rule_config_id, held_count, held_back)
  values (p_venue.customer_id, p_venue.id, p_category, p_rule, p_count, p_holds)
  on conflict (venue_id, category) do update
     set rule_config_id = excluded.rule_config_id, held_count = excluded.held_count, held_back = excluded.held_back, changed_at = clock_timestamp()
   where (core.retention_hold_check.rule_config_id, core.retention_hold_check.held_count, core.retention_hold_check.held_back)
         is distinct from (excluded.rule_config_id, excluded.held_count, excluded.held_back);
end $$;
revoke all on function core.record_hold_check(core.venue, text, uuid, integer, jsonb) from public;

create or replace function api.run_retention_jobs() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v jsonb := authz.evaluate('retention.list', '{}'::jsonb);
  vn core.venue; cfg core.venue_config_version; k text; days integer; cw record;
  c core.retention_candidate; listed core.retention_candidate[]; holds uuid[]; held jsonb; h uuid;
  b_id uuid; n_batches integer := 0; n_listed integer := 0; n_held integer := 0; n_reviews integer := 0; hd core.legal_hold;
  n_held_before integer;
begin
  if not (v ->> 'allowed')::boolean then return v; end if;
  for vn in select * from core.venue order by id loop
    cfg := core.venue_config(vn.id, 'retention');
    continue when cfg.id is null;
    for k in select jsonb_object_keys(cfg.content -> 'rules') loop
      continue when exists (select 1 from core.disposal_batch where venue_id = vn.id and category = k and status = 'proposed');
      continue when not exists (select 1 from core.retention_categories() rc where rc.code = k);
      days := (cfg.content #>> array['rules', k, 'days'])::int;
      select * into cw from core.customer_wide_rule(vn.customer_id, k);
      listed := '{}'; held := '{}'; n_held_before := n_held;
      for c in select x.* from core.retention_candidates(vn.customer_id, k) x
                where (x.venue_id = vn.id or (x.venue_id is null and cw.venue_id = vn.id))
                  and x.trigger_at + make_interval(days => days) <= now()
                  and not exists (select 1 from core.disposal_item i join core.disposal_batch b on b.id = i.batch_id
                                   where i.root_id = x.root_id and i.root_table = x.root_table
                                     and (b.status = 'proposed' or (b.status = 'declined' and b.rule_config_id = cfg.id)))
                order by x.trigger_at, x.root_id loop
        holds := core.covering_holds(vn.customer_id, c);
        if cardinality(holds) > 0 then
          foreach h in array holds loop
            held := jsonb_set(held, array[h::text], to_jsonb(coalesce((held ->> h::text)::int, 0) + 1));
          end loop;
          n_held := n_held + 1;
        elsif cardinality(listed) < 2000 then
          listed := listed || c;
        end if;
      end loop;
      perform core.record_hold_check(vn, k, cfg.id, n_held - n_held_before,
        (select coalesce(jsonb_agg(jsonb_build_object('hold_id', lh.id, 'reference', lh.reference, 'matter', lh.matter, 'count', (held ->> lh.id::text)::int)
                                   order by lh.reference), '[]')
           from core.legal_hold lh where held ? lh.id::text));
      continue when cardinality(listed) = 0;
      b_id := gen_random_uuid();
      v := authz.require('retention.list', jsonb_build_object('customer_id', vn.customer_id, 'venue_id', vn.id, 'record_id', b_id, 'target_type', 'disposal_batch'),
                         'list:' || b_id, jsonb_build_object('venue_id', vn.id, 'category', k, 'rule', cfg.id));
      if not (v ->> 'ok')::boolean then return v; end if;
      insert into core.disposal_batch (id, customer_id, venue_id, reference, category, rule_config_id, period_days, held_back, listed_count, status)
      values (b_id, vn.customer_id, vn.id, 'DB-' || upper(left(replace(b_id::text, '-', ''), 8)), k, cfg.id, days,
              (select coalesce(jsonb_agg(jsonb_build_object('hold_id', lh.id, 'reference', lh.reference, 'matter', lh.matter, 'count', (held ->> lh.id::text)::int)
                                         order by lh.reference), '[]')
                 from core.legal_hold lh where held ? lh.id::text),
              cardinality(listed), 'proposed');
      insert into core.disposal_item (customer_id, batch_id, root_table, root_id, trigger_at)
      select vn.customer_id, b_id, x.root_table, x.root_id, x.trigger_at from unnest(listed) x;
      perform core.notify(vn.customer_id, vn.id, core.venue_action_appointees(vn.id, 'retention.dispose'), 'routine', 'disposal_listed',
        'core.disposal_batch', b_id, 'disposal_listed:' || b_id, format('Records listed for disposal: %s', core.category_name(k)),
        format('%s records of the category "%s" are past the %s days the venue''s retention schedule sets, and no legal hold covers them. Nothing is disposed of until someone confirms the batch.',
               cardinality(listed), core.category_name(k), days),
        '/venue/retention', array[cfg.decided_by_person_id]);
      n_batches := n_batches + 1; n_listed := n_listed + cardinality(listed);
    end loop;
  end loop;

  -- Holds at their review date: tell the requester and the approver; the hold stays in force.
  for hd in select * from core.legal_hold where status = 'active' and core.hold_review_on(id) <= core.venue_date(venue_id) loop
    n_reviews := n_reviews + core.notify(hd.customer_id, hd.venue_id, array[hd.requested_by_person_id, hd.decided_by_person_id], 'routine', 'legal_hold_review',
      'core.legal_hold', hd.id, 'hold_review:' || hd.id || ':' || core.hold_review_on(hd.id),
      format('Legal hold due for review: %s', hd.matter),
      format('Legal hold %s (%s) reached its review date of %s. It stays in force until a legal hold approver renews it with a new review date or lifts it with a reason.',
             hd.reference, hd.matter, to_char(core.hold_review_on(hd.id), 'DD/MM/YYYY')),
      '/venue/holds', '{}');
  end loop;
  return jsonb_build_object('ok', true, 'batches', n_batches, 'listed', n_listed, 'held_back', n_held, 'hold_reviews', n_reviews);
end $$;

create or replace function api.retention_overview(p_venue_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare vn core.venue; cfg core.venue_config_version; draft core.venue_config_version;
begin
  select * into vn from core.venue where id = p_venue_id;
  if vn.id is null or not core.retention_viewer(vn.id) then
    return jsonb_build_object('ok', false, 'code', 'not_found', 'reason', 'The record does not exist or you do not have access to it.');
  end if;
  cfg := core.venue_config(vn.id, 'retention');
  select * into draft from core.venue_config_version where venue_id = vn.id and kind = 'retention' and status in ('draft', 'proposed');
  return jsonb_build_object('ok', true, 'venue', jsonb_build_object('id', vn.id, 'name', vn.name, 'timezone', vn.timezone),
    'is_admin', vn.customer_id in (select authz.my_admin_customer_ids()),
    'can_approve', vn.id in (select authz.my_action_venue_ids('retention.approve')),
    'can_dispose', vn.id in (select authz.my_action_venue_ids('retention.dispose')),
    'me', authz.actor_person(vn.customer_id),
    'categories', (select jsonb_agg(jsonb_build_object('code', rc.code, 'name', rc.name, 'trigger', rc.trigger_words, 'method', rc.method,
                                                       'never_while', rc.never_while, 'rule', cfg.content #> array['rules', rc.code],
                                                       'kept_back', (select jsonb_build_object('count', hc.held_count, 'holds', hc.held_back, 'since', hc.changed_at)
                                                                       from core.retention_hold_check hc
                                                                      where hc.venue_id = vn.id and hc.category = rc.code and hc.held_count > 0))
                                     order by rc.ord)
                     from core.retention_categories() rc),
    'schedule', case when cfg.id is null then null else jsonb_build_object('id', cfg.id, 'version_no', cfg.version_no, 'decided_by', core.person_name(cfg.decided_by_person_id),
                                                                         'decided_at', cfg.decided_at, 'decision_reason', cfg.decision_reason, 'source_ref', cfg.source_ref) end,
    'draft', case when draft.id is null then null else jsonb_build_object('id', draft.id, 'status', draft.status, 'version_no', draft.version_no, 'content', draft.content,
                                                                        'row_version', draft.row_version, 'authored_by', core.person_name(draft.authored_by_person_id),
                                                                        'authored_by_person_id', draft.authored_by_person_id,
                                                                        'proposed_by_person_id', draft.proposed_by_person_id) end,
    'batches', coalesce((select jsonb_agg(jsonb_build_object(
        'id', b.id, 'reference', b.reference, 'category', core.category_name(b.category), 'status', b.status, 'listed_count', b.listed_count,
        'period_days', b.period_days, 'listed_at', b.created_at, 'held_back', b.held_back, 'row_version', b.row_version,
        'rule_version', (select version_no from core.venue_config_version where id = b.rule_config_id),
        'rule_approver_person_id', (select decided_by_person_id from core.venue_config_version where id = b.rule_config_id),
        'decided_by', core.person_name(b.decided_by_person_id), 'decided_at', b.decided_at, 'decision_reason', b.decision_reason,
        'disposed_count', b.disposed_count, 'kept_count', b.kept_count,
        'items', case when b.status = 'proposed' then (select coalesce(jsonb_agg(jsonb_build_object('label', core.retention_label(i.root_table, i.root_id, b.venue_id),
                                                                                                   'trigger_at', i.trigger_at) order by i.trigger_at), '[]')
                                                         from (select * from core.disposal_item where batch_id = b.id order by trigger_at limit 200) i)
                      else (select coalesce(jsonb_agg(jsonb_build_object('kept_reason', i.kept_reason, 'label', core.retention_label(i.root_table, i.root_id, b.venue_id),
                                                                          'trigger_at', i.trigger_at) order by i.trigger_at), '[]')
                              from core.disposal_item i where i.batch_id = b.id and i.outcome = 'kept') end)
      order by case b.status when 'proposed' then 0 else 1 end, b.created_at desc)
      from (select * from core.disposal_batch where venue_id = vn.id order by created_at desc limit 50) b), '[]'),
    'files_waiting', (select count(*) from core.file_disposal where venue_id = vn.id and removed_at is null));
end $$;
