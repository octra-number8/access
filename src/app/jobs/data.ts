import "server-only";
import type { supabaseServer } from "@/lib/supabase/server";
import type { AreaOption, PersonOption } from "./job-fields";

type Db = Awaited<ReturnType<typeof supabaseServer>>;

/** A venue's current areas in hierarchy order (parents before children), with their depth. */
export async function venueAreas(db: Db, venueId: string): Promise<AreaOption[]> {
  const { data } = await db.from("area").select("id, name, parent_id").eq("venue_id", venueId).is("retired_at", null);
  const rows = data ?? [];
  const children = new Map<string | null, typeof rows>();
  for (const a of rows) children.set(a.parent_id, [...(children.get(a.parent_id) ?? []), a]);
  const ids = new Set(rows.map((a) => a.id));
  const out: AreaOption[] = [];
  const walk = (parent: string | null, depth: number) => {
    for (const a of (children.get(parent) ?? []).sort((x, y) => x.name.localeCompare(y.name))) {
      out.push({ id: a.id, name: a.name, depth });
      walk(a.id, depth + 1);
    }
  };
  for (const root of rows.filter((a) => !a.parent_id || !ids.has(a.parent_id))) {
    out.push({ id: root.id, name: root.name, depth: 0 });
    walk(root.id, 1);
  }
  return out;
}

/** People who currently work with an organisation (for contact and supervisor). */
export async function organisationPeople(db: Db, organisationId: string): Promise<PersonOption[]> {
  const { data: rels } = await db.from("person_organisation_relationship").select("person_id")
    .eq("organisation_id", organisationId).eq("status", "active");
  const { data: people } = await db.from("person").select("id, given_name, family_name")
    .in("id", (rels ?? []).map((r) => r.person_id)).order("family_name");
  return (people ?? []).map((p) => ({ id: p.id, name: `${p.given_name} ${p.family_name}` }));
}
