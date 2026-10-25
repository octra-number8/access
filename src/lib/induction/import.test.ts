import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { fromInductStarter, parseBrief } from "./import";

const fixture = readFileSync(join(__dirname, "fixtures/brief.md"), "utf8");

describe("induction brief import", () => {
  const r = parseBrief(fixture);

  it("reads the title, sections and their text", () => {
    expect(r.title).toBe("Test Event 2027");
    expect(r.content.modules.map((m) => m.key)).toEqual(["welcome", "on-arrival", "fire-and-evacuation"]);
    expect(r.content.modules[0]!.blocks[0]).toMatchObject({ type: "rich_text" });
    expect((r.content.modules[0]!.blocks[0] as { text: string }).text).toContain("No induction, no work.");
  });

  it("reads questions with their type, correct answers, explanation and linked section", () => {
    const [q1, q2, q3] = r.content.questions;
    expect(q1).toMatchObject({ type: "single_choice", module_key: "on-arrival", placement: "final" });
    expect(q1!.options.filter((o) => o.correct)).toHaveLength(1);
    expect(q2!.type).toBe("multiple_select");
    expect(q2!.options.filter((o) => o.correct).map((o) => o.text)).toEqual(["Stop work", "Leave by the nearest exit"]);
    expect(q3).toMatchObject({ type: "true_false" });
    expect(q3!.options.find((o) => o.correct)!.text).toBe("False");
    expect(q1!.explanation).toMatch(/evacuation/);
  });

  it("never decides what the source does not: reading times and safety-critical questions become open points", () => {
    expect(r.content.modules.every((m) => m.min_seconds === 0)).toBe(true);
    expect(r.content.questions.every((q) => q.safety_critical === false)).toBe(true);
    expect(r.openPoints.map((p) => p.text).join(" ")).toMatch(/minimum reading time/);
    expect(r.openPoints.map((p) => p.text).join(" ")).toMatch(/safety-critical/);
  });

  it("carries the source's open points with their owner, and images still to supply", () => {
    expect(r.openPoints).toContainEqual({ text: "Assembly point location. Not in any source.", owner: "The venue" });
    expect(r.openPoints.some((p) => /Image still to supply for "Fire and evacuation"/.test(p.text))).toBe(true);
  });

  it("attaches images to their section with alt text, awaiting upload", () => {
    expect(r.images).toEqual([{ file: "01 site plan.png", moduleKey: "welcome", alt: "Site plan showing the production office." }]);
    expect(r.content.modules[0]!.blocks.at(-1)).toMatchObject({ type: "image", media_id: null, alt: "Site plan showing the production office." });
  });

  it("reads the declaration, and does not import extra data collection", () => {
    expect(r.content.declaration.map((d) => d.text)).toEqual(["I have read and understood this induction", "I will follow the site rules"]);
    expect(r.notes.join(" ")).toMatch(/registration fields .* not imported/);
  });
});

// Optional: the real briefs and Induct starters, when present on this machine.
const briefs = "/Users/wespierce/Projects/Claude/Induction briefs/VodafoneThree Consumer Operations and Franchise Events 2026/induction.md";
describe.skipIf(!existsSync(briefs))("the VodafoneThree brief", () => {
  it("imports 20 sections, 12 questions, 5 declaration items and 6 images", () => {
    const r = parseBrief(readFileSync(briefs, "utf8"));
    expect(r.content.modules).toHaveLength(20);
    expect(r.content.questions).toHaveLength(12);
    expect(r.content.declaration).toHaveLength(5);
    expect(r.images).toHaveLength(6);
    expect(r.content.questions.every((q) => q.module_key !== null)).toBe(true);
    expect(r.content.questions.every((q) => q.options.some((o) => o.correct))).toBe(true);
    expect(r.openPoints.length).toBeGreaterThan(4);
  });
});

const induct = "/Users/wespierce/Projects/Claude/Inductions/supabase/migrations/20260915090000_starter_templates.sql";
describe.skipIf(!existsSync(induct))("OCTRA Induct starter templates", () => {
  it("imports every starter in the Induct migrations", () => {
    const dir = "/Users/wespierce/Projects/Claude/Inductions/supabase/migrations";
    const starters = readdirSync(dir).flatMap((f) =>
      [...readFileSync(join(dir, f), "utf8").matchAll(/(\{\s*"schema":\s*1,[\s\S]*?\n\s*\})\s*(?:'|\$\w*\$)/g)].map((m) => m[1]!),
    );
    expect(starters.length).toBeGreaterThan(0);
    for (const text of starters) {
      const r = fromInductStarter(JSON.parse(text));
      expect(r.content.modules.length).toBeGreaterThan(0);
      expect(r.content.questions.every((q) => q.options.length >= 2)).toBe(true);
      expect(r.content.declaration.length).toBeGreaterThan(0);
    }
  });
});
