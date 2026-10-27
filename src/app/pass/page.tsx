import { randomUUID } from "node:crypto";
import Link from "next/link";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { EntryResultView } from "@/components/gate/entry-result";
import type { EntryResult } from "@/lib/gate";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { createPhonePass } from "./actions";
import { PhonePassCode } from "./code";

export const metadata = { title: "My pass" };

// The person's own pass and their entry result now (§11). The result is the same evaluation
// the gate runs, recording nothing; it can change at any moment, so it is not a promise.
export default async function MyPass({ searchParams }: { searchParams: Promise<{ venue?: string }> }) {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/pass");
  if (session.personIds.length === 0) return <p>Your account is not linked to a person record yet.</p>;
  const db = await supabaseServer();
  const { data: venues } = await db.from("venue").select("id, name, timezone").order("name");
  const { venue: vid } = await searchParams;
  const venue = (venues ?? []).find((v) => v.id === vid) ?? (venues ?? [])[0];
  if (!venue) return <p>You are not connected to any venue yet.</p>;
  const [{ data: passes }, { data: entry }] = await Promise.all([
    db.from("person_pass").select("id, kind, pass_number, revoked_at, revoke_reason").eq("venue_id", venue.id).in("person_id", session.personIds)
      .order("created_at", { ascending: false }),
    db.rpc("my_entry", { p_venue_id: venue.id }),
  ]);
  const phone = (passes ?? []).find((p) => p.kind === "phone" && !p.revoked_at);
  const card = (passes ?? []).find((p) => p.kind === "card" && !p.revoked_at);
  const result = (entry as ({ ok: boolean } & EntryResult) | null);

  return (
    <>
      {(venues ?? []).length > 1 ? <p>{(venues ?? []).map((v) => <Link key={v.id} href={`/pass?venue=${v.id}`} style={{ marginRight: "1rem" }}>{v.name}</Link>)}</p> : null}
      <h1>My pass — {venue.name}</h1>
      {phone ? (
        <>
          <PhonePassCode venueId={venue.id} />
          <p className="muted">Show this at the gate. A screenshot will not work: the code changes every 30 seconds. You will also be asked for photo ID.</p>
        </>
      ) : (
        <ActionForm action={createPhonePass} what="Creating your phone pass" submitLabel="Create my phone pass">
          <input type="hidden" name="key" value={randomUUID()} />
          <input type="hidden" name="venue_id" value={venue.id} />
          <p>A phone pass shows a code the gate scans. It does not decide whether you may enter: the gate checks that each time.</p>
        </ActionForm>
      )}
      {card ? <p>You also have a printed card, {card.pass_number}. If it is lost, tell the venue&apos;s pass desk so it can be revoked.</p> : null}
      {(passes ?? []).filter((p) => p.revoked_at).map((p) => (
        <p key={p.id} className="muted">{p.kind === "phone" ? "Phone pass" : "Card"} {p.pass_number} was revoked: {p.revoke_reason}</p>
      ))}

      <h2>If you came to the gate now</h2>
      {result?.ok ? (
        <EntryResultView r={result} tz={venue.timezone}>
          <p className="muted">Checked {new Date().toLocaleTimeString("en-GB", { timeZone: venue.timezone })}. The gate checks again when you arrive; this can change. <Link href={`/pass?venue=${venue.id}`}>Check again</Link></p>
        </EntryResultView>
      ) : <p className="notice notice-blocked">{(entry as { reason?: string } | null)?.reason ?? "Your result could not be checked."}</p>}
    </>
  );
}
