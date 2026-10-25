// Imported induction content (D-015) is accepted by the database's own validator as a
// draft, and held back from review until its open points, files and settings are dealt with.

import { existsSync, readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { loadLocalEnv } from "./env";

loadLocalEnv();
const { buildVenue, signIn, key, must, version } = await import("./world");
const { parseBrief } = await import("@/lib/induction/import");

const real = "/Users/wespierce/Projects/Claude/Induction briefs/VodafoneThree Consumer Operations and Franchise Events 2026/induction.md";
const sources: Array<[string, string]> = [["the synthetic fixture", "src/lib/induction/fixtures/brief.md"]];
if (existsSync(real)) sources.push(["the VodafoneThree brief", real]);

describe("importing an induction brief", async () => {
  const venue = await buildVenue();
  const a1 = await signIn(venue.admin1);

  it.each(sources)("%s becomes a valid draft that cannot yet go for review", async (_, file) => {
    const parsed = parseBrief(readFileSync(file, "utf8"));
    const course = await must(a1, "create_induction_course", {
      p_idempotency_key: key(), p_venue_id: venue.venueId, p_code: `IMP${Math.floor(Math.random() * 1e6)}`,
      p_title: parsed.title ?? "Imported", p_audience: null, p_event_id: null,
    });
    const draft = await must(a1, "create_course_draft", { p_idempotency_key: key(), p_course_id: course.id, p_language: "en-GB" });
    await must(a1, "save_course_draft", {
      p_idempotency_key: key(), p_version_id: draft.id, p_expected_version: await version("course_version", draft.id),
      p_content: parsed.content, p_source_ref: file.split("/").pop(),
    });
    for (const op of parsed.openPoints) {
      await must(a1, "add_open_point", { p_idempotency_key: key(), p_version_id: draft.id, p_text: op.text, p_owner_text: op.owner });
    }
    const submitted = (await a1.rpc("submit_course_version", {
      p_idempotency_key: key(), p_version_id: draft.id, p_expected_version: await version("course_version", draft.id),
    })).data;
    expect(submitted).toMatchObject({ ok: false, code: "not_ready" });
    const problems = (submitted.problems as string[]).join(" ");
    expect(problems).toMatch(/unresolved open points/);
    expect(problems).toMatch(/Settings not yet set/);
    if (parsed.images.length > 0) expect(problems).toMatch(/has no file yet/);
  });
});
