import "server-only";
import { supabaseServer } from "./supabase/server";

export interface Session {
  userId: string;
  email: string | null;
  personIds: string[];
  tenantAdminCustomerIds: string[];
  organisationAdmin: Array<{ organisation_id: string; role: string }>;
  appointmentVenueIds: string[];
}

/** Who the signed-in user is, per customer. Only what RLS lets them see. */
export async function getSession(): Promise<Session | null> {
  const db = await supabaseServer();
  const { data: auth } = await db.auth.getUser();
  if (!auth.user) return null;
  const [accounts, admins, orgAdmins, appointments] = await Promise.all([
    db.from("user_account").select("person_id").eq("auth_user_id", auth.user.id).is("disabled_at", null),
    db.from("tenant_admin").select("customer_id, person_id").is("revoked_at", null),
    db.from("organisation_admin").select("organisation_id, role, person_id").is("revoked_at", null),
    db.from("appointment").select("venue_id, appointee_person_id, status"),
  ]);
  const personIds = (accounts.data ?? []).map((a) => a.person_id as string);
  return {
    userId: auth.user.id,
    email: auth.user.email ?? null,
    personIds,
    tenantAdminCustomerIds: (admins.data ?? []).filter((a) => personIds.includes(a.person_id)).map((a) => a.customer_id),
    organisationAdmin: (orgAdmins.data ?? []).filter((a) => personIds.includes(a.person_id)),
    appointmentVenueIds: [
      ...new Set(
        (appointments.data ?? [])
          .filter((a) => personIds.includes(a.appointee_person_id) && a.status === "in_force")
          .map((a) => a.venue_id as string),
      ),
    ],
  };
}
