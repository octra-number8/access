-- 0063 Critical notices about people without an Octra account (decision 8a-2, D-023)
--
-- People without an account (6b-2: watchers, operatives with a card pass) cannot read the in-app
-- inbox, and may have no email address. A critical notice addressed to such a person now also
-- goes to the current administrators of each organisation they currently work for, saying why.
-- The notice to the person is still recorded (and emailed if they have an address). The admin's
-- copy is itself critical, so it is always emailed. It is added in core.notify, so every critical
-- source is covered, now and later. A copy is never copied on (its dedupe key carries ':for:'),
-- so an administrator who has no account does not pass the notice up another level.
--
-- Rollback / recovery: forward-only. To withdraw, replace core.notify with its 0053 definition.
-- Notices already written stay, as every notice does.

create or replace function core.notify(p_customer_id uuid, p_venue_id uuid, p_recipients uuid[], p_class text, p_event text,
                            p_record_table text, p_record_id uuid, p_dedupe_key text, p_subject text, p_body text, p_link text,
                            p_exclude uuid[] default '{}')
returns integer language plpgsql security definer set search_path = '' as $$
declare r uuid; a uuid; org text; n_id uuid; mode text; n integer := 0;
begin
  for r in select distinct x from unnest(coalesce(p_recipients, '{}')) x
            where x is not null and not (x = any (coalesce(p_exclude, '{}'))) loop
    continue when not exists (select 1 from core.person pe where pe.id = r and pe.customer_id = p_customer_id and pe.deactivated_at is null);
    insert into core.notification (customer_id, venue_id, recipient_person_id, class, event, record_table, record_id, dedupe_key, subject, body, link)
    values (p_customer_id, p_venue_id, r, p_class, p_event, p_record_table, p_record_id, p_dedupe_key, p_subject,
            p_body || case when p_class = 'critical'
              then E'\n\nOctra has recorded this. It is not an instruction: the venue''s direct route (control room, supervisor) still applies.' else '' end,
            p_link)
    on conflict (recipient_person_id, dedupe_key) do nothing
    returning id into n_id;
    continue when n_id is null;
    n := n + 1;
    -- Critical: always emailed, whatever the person chose (P8-3). Routine: as they chose (Q210).
    mode := case when p_class = 'critical' then 'email'
                 else coalesce((select routine_mode from core.notification_preference where person_id = r), 'in_app') end;
    if mode in ('email', 'digest') then
      insert into core.notification_delivery (notification_id, channel, delivery_state)
      values (n_id, mode, case when core.person_email(r) is null then 'no_address' else 'pending' end);
    end if;
  end loop;
  -- 8a-2 (D-023): a critical notice to someone with no Octra account also goes to the current
  -- administrators of each organisation they currently work for, saying why. Administrators who
  -- already received this notice directly, or who are excluded (the actor), are not added; the
  -- nested call skips deactivated administrators, as it does every recipient.
  if p_class = 'critical' and p_dedupe_key not like '%:for:%' then
    for r, a, org in
      select distinct x, oa.person_id, o.legal_name
        from unnest(coalesce(p_recipients, '{}')) x
        join core.person pe on pe.id = x and pe.customer_id = p_customer_id and pe.deactivated_at is null
        join core.person_organisation_relationship por on por.person_id = x and por.status = 'active' and now() <@ por.valid_during
        join core.organisation o on o.id = por.organisation_id
        join core.organisation_admin oa on oa.organisation_id = por.organisation_id and oa.revoked_at is null and now() <@ oa.valid_during
       where not exists (select 1 from core.user_account ua where ua.person_id = x and ua.disabled_at is null)
         and not (x = any (coalesce(p_exclude, '{}')))
         and not (oa.person_id = any (coalesce(p_recipients, '{}')))
         and not (oa.person_id = any (coalesce(p_exclude, '{}')))
    loop
      n := n + core.notify(p_customer_id, p_venue_id, array[a], 'critical', p_event, p_record_table, p_record_id,
                           p_dedupe_key || ':for:' || r, p_subject,
                           format('Sent to you as an administrator of %s, because %s has no Octra account and cannot receive this notice.',
                                  org, core.person_name(r)) || E'\n\n' || p_body,
                           p_link);
    end loop;
  end if;
  return n;
end $$;
