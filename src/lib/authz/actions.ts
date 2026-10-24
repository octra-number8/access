// Authority action codes seeded in supabase/migrations/…_catalogue_state_machine.sql.
// The database is the source of truth; this list only gives the client type safety.
// A parity test (authz.test.ts) fails if the two drift.
export const AUTHORITY_ACTIONS = [
  "customer.create",
  "break_glass.open",
  "tenant_admin.grant",
  "venue.create",
  "area_kind.create",
  "area.create",
  "area.retire",
  "system_type.create",
  "system.create",
  "system.link_area",
  "system_ownership.record",
  "organisation.create",
  "person.create",
  "user_account.link",
  "user_account.disable",
  "person_organisation.record",
  "engagement.create",
  "engagement.end",
  "permit_class.create",
  "appointment_type.create",
  "appointment_type.publish",
  "appointment.record_root",
  "appointment.confirm_root",
  "appointment.revoke_root",
  "appointment.acknowledge",
  "delegation.revoke",
  "appointment.grant",
  "appointment.revoke",
  "delegation.grant",
  "engagement.suspend",
  "engagement.reinstate",
] as const;

export type AuthorityAction = (typeof AUTHORITY_ACTIONS)[number];
