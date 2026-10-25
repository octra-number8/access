// The starter screening set (P4-2) is accepted by the database's own validator once a
// venue has the classes it names, and produces the recommendations its rules describe.
// It goes no further than "proposed": approval is the venue's technical authority's.

import { describe, expect, it } from "vitest";
import { loadLocalEnv } from "./env";

loadLocalEnv();
const { buildVenue, signIn, key, must, version } = await import("./world");
const { starterFor, SUGGESTED_CLASSES, STARTER_SOURCE } = await import("@/lib/screening/starter");

describe("the starter screening set", async () => {
  const venue = await buildVenue();
  const a1 = await signIn(venue.admin1);

  it("is a valid draft, can be proposed, and recommends what its rules say", async () => {
    const classes = [];
    for (const s of SUGGESTED_CLASSES) {
      const fn = s.handling === "external_reference" ? "create_external_class" : "create_permit_class";
      const c = await must(a1, fn, { p_idempotency_key: key(), p_venue_id: venue.venueId, p_code: s.code, p_name: s.name });
      classes.push({ id: c.id as string, code: s.code, handling: s.handling });
    }
    const { content, missing } = starterFor(classes);
    expect(missing).toEqual([]);

    const draft = await must(a1, "create_screening_draft", { p_idempotency_key: key(), p_venue_id: venue.venueId });
    await must(a1, "save_screening_draft", { p_idempotency_key: key(), p_version_id: draft.id,
      p_expected_version: await version("screening_set_version", draft.id), p_content: content, p_source_ref: STARTER_SOURCE });

    const { data: preview } = await a1.rpc("preview_screening", { p_version_id: draft.id, p_answers: {
      hot: ["yes"], isolate: ["no"], height: ["yes"], "height-where": ["roof", "ladder"], "life-safety": ["no"],
      confined: ["yes"], lifting: ["no"], penetrate: ["no"], structure: ["no"] } });
    expect(preview.problems).toEqual([]);
    expect(preview.matches.map((m: { rule_key: string }) => m.rule_key).sort()).toEqual(["r-confined", "r-hot", "r-roof-edge"]);
    expect(preview.matches.find((m: { rule_key: string }) => m.rule_key === "r-confined").handling).toBe("external_reference");

    await must(a1, "propose_screening_version", { p_idempotency_key: key(), p_version_id: draft.id,
      p_expected_version: await version("screening_set_version", draft.id) });
    const { data: row } = await a1.from("screening_set_version").select("status, source_ref").eq("id", draft.id).single();
    expect(row).toEqual({ status: "proposed", source_ref: STARTER_SOURCE });
  });
});
