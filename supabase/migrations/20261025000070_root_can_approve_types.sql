-- 0070 A root appointment must leave the venue able to approve appointment types (T-1)
--
-- Appointment type versions can be published directly only until a venue has a root
-- appointment (D-011). After that, every version needs `appointment_type.approve`, which comes
-- only from an appointment. A root appointment whose type does not allow it, with no other root
-- appointment in force that does, left the venue unable ever to change its appointment types,
-- including adding that action. Recording such a root appointment is now refused, on every path.
--
-- Administration still grants nothing (invariant 9): this refuses a record, it never adds an action.
-- Existing appointments are untouched.
--
-- Rollback / recovery: forward-only. To withdraw, drop the trigger and function.

create function core.root_can_approve_types() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.is_root
     and not exists (select 1 from core.appointment_type_version tv
                      where tv.id = new.appointment_type_version_id and 'appointment_type.approve' = any (tv.allowed_action_codes))
     and not exists (select 1 from core.appointment a
                       join core.appointment_type_version tv on tv.id = a.appointment_type_version_id
                      where a.venue_id = new.venue_id and a.is_root and a.id <> new.id
                        and a.status = 'in_force' and now() <@ a.valid_during
                        and 'appointment_type.approve' = any (tv.allowed_action_codes)) then
    raise exception 'a root appointment''s type must allow approving appointment types, because no other root appointment in force here does; without it nobody could ever change this venue''s appointment types'
      using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger root_can_approve_types before insert on core.appointment
  for each row execute function core.root_can_approve_types();
revoke execute on function core.root_can_approve_types() from public, anon, authenticated;
