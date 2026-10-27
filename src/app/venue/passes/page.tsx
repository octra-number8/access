import { randomUUID } from "node:crypto";
import Link from "next/link";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { venueTime } from "@/lib/permits";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { revokePass } from "../entry/actions";
import { IssueCard } from "./issue";

export const metadata = { title: "Card passes" };

// Passes (P7-3): printed cards for people without a phone or an account, issued by the
// tenant administrator; any pass can be revoked with a reason. A pass identifies a person;
// it never decides entry, which the gate evaluates on every scan.
export default async function Passes() {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/venue/passes");
  if (session.tenantAdminCustomerIds.length === 0 && session.appointmentVenueIds.length === 0) return <p>Passes are managed by the venue.</p>;
  const db = await supabaseServer();
  const { data: venues } = await db.from("venue").select("id, name, timezone, customer_id").order("name");
  const venue = (venues ?? []).find((v) => session.tenantAdminCustomerIds.includes(v.customer_id)) ?? (venues ?? []).find((v) => session.appointmentVenueIds.includes(v.id));
  if (!venue) return <p>No venue.</p>;
  const [{ data: passes }, { data: people }] = await Promise.all([
    db.from("person_pass").select("id, person_id, kind, pass_number, revoked_at, revoke_reason, created_at").eq("venue_id", venue.id).order("pass_number"),
    db.from("person").select("id, given_name, family_name, deactivated_at").eq("customer_id", venue.customer_id).order("family_name"),
  ]);
  const name = new Map((people ?? []).map((p) => [p.id, `${p.given_name} ${p.family_name}`]));
  const live = (passes ?? []).filter((p) => !p.revoked_at);
  const revoked = (passes ?? []).filter((p) => p.revoked_at);
  const isAdmin = session.tenantAdminCustomerIds.includes(venue.customer_id);
  const k = () => randomUUID();

  return (
    <>
      <p className="no-print"><Link href="/venue/entry">Entry set-up</Link></p>
      <h1 className="no-print">Passes — {venue.name}</h1>
      {isAdmin ? (
        <>
          <h2 className="no-print">Issue a card</h2>
          <p className="muted no-print">For someone without a smartphone or an account. One live card per person; revoke a lost card before issuing another.</p>
          <IssueCard venueId={venue.id} newKey={k()} people={(people ?? []).filter((p) => !p.deactivated_at).map((p) => ({ id: p.id, name: `${p.given_name} ${p.family_name}` }))} />
        </>
      ) : null}

      <h2 className="no-print">Live passes</h2>
      {live.length === 0 ? <p className="no-print">None.</p> : (
        <div className="table-wrap no-print"><table>
          <thead><tr><th scope="col">Pass</th><th scope="col">Person</th><th scope="col">Issued</th><th scope="col">Revoke</th></tr></thead>
          <tbody>{live.map((p) => (
            <tr key={p.id}>
              <td>{p.pass_number} <span className="muted">({p.kind === "phone" ? "phone" : "card"})</span></td>
              <td>{name.get(p.person_id) ?? "—"}</td>
              <td>{venueTime(p.created_at, venue.timezone)}</td>
              <td>
                <details><summary>Revoke</summary>
                  <ActionForm action={revokePass} what="Revoking this pass" submitLabel="Revoke pass" secondary>
                    <input type="hidden" name="key" value={k()} />
                    <input type="hidden" name="pass_id" value={p.id} />
                    <label>Reason<input name="reason" required placeholder="e.g. Card reported lost" /></label>
                  </ActionForm>
                </details>
              </td>
            </tr>
          ))}</tbody>
        </table></div>
      )}
      {revoked.length ? (
        <details className="no-print"><summary>Revoked passes</summary>
          <ul>{revoked.map((p) => <li key={p.id}>{p.pass_number} · {name.get(p.person_id) ?? "—"}: {p.revoke_reason} ({venueTime(p.revoked_at, venue.timezone)})</li>)}</ul>
        </details>
      ) : null}
    </>
  );
}
