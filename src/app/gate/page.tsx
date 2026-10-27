import Link from "next/link";
import { redirect } from "next/navigation";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { GateDesk } from "./desk";

export const metadata = { title: "Gate" };

// The gate (Q191–Q197, §11): choose the gate point, then scan or type a pass number. Whether
// this person may operate the gate is decided by the database on every scan (P7-5).
export default async function Gate({ searchParams }: { searchParams: Promise<{ point?: string }> }) {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/gate");
  const db = await supabaseServer();
  const [{ data: points }, { data: venues }] = await Promise.all([
    db.from("gate_point").select("id, name, venue_id, area_id").is("retired_at", null).order("name"),
    db.from("venue").select("id, name, timezone"),
  ]);
  const venue = new Map((venues ?? []).map((v) => [v.id, v]));
  const { point } = await searchParams;
  const chosen = (points ?? []).find((p) => p.id === point) ?? ((points ?? []).length === 1 ? points![0] : null);

  if (!chosen) {
    return (
      <>
        <h1>Gate</h1>
        {(points ?? []).length === 0 ? (
          <p className="notice notice-blocked">No gate points are set up at a venue you work at. The venue&apos;s tenant administrator adds them on the entry set-up page.</p>
        ) : (
          <>
            <p>Which gate are you working?</p>
            <ul>{(points ?? []).map((p) => (
              <li key={p.id}><Link href={`/gate?point=${p.id}`}>{p.name}</Link> <span className="muted">· {venue.get(p.venue_id)?.name}</span></li>
            ))}</ul>
          </>
        )}
      </>
    );
  }
  const v = venue.get(chosen.venue_id);
  return (
    <>
      <p className="muted">
        {v?.name} · <strong>{chosen.name}</strong>
        {(points ?? []).length > 1 ? <> · <Link href="/gate?point=">Change gate</Link></> : null}
        {" "}· <Link href={`/gate/overrides?venue=${chosen.venue_id}`}>Overrides</Link>
      </p>
      <h1 className="sr-only">Gate: {chosen.name}</h1>
      <GateDesk gatePointId={chosen.id} gateName={chosen.name} tz={v?.timezone ?? "Europe/London"} />
    </>
  );
}
