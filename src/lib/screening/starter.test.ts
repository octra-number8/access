import { describe, expect, it } from "vitest";
import { isShown } from "./content";
import { starterFor, SUGGESTED_CLASSES } from "./starter";

describe("starter screening set", () => {
  it("imports only rules whose class the venue has, with the expected handling", () => {
    const { content, missing } = starterFor([
      { id: "hw", code: "HW", handling: "permit" },
      { id: "cs", code: "CS", handling: "permit" }, // wrong handling: not used
    ]);
    expect(content.rules.map((r) => r.key)).toEqual(["r-hot"]);
    expect(content.rules[0]!.permit_class_id).toBe("hw");
    expect(missing.map((m) => m.code)).toEqual(SUGGESTED_CLASSES.map((s) => s.code).filter((c) => c !== "HW"));
    expect(content.questions.length).toBeGreaterThan(5);
  });

  it("never invents thresholds: no numbers in any question or rule", () => {
    const { content } = starterFor(SUGGESTED_CLASSES.map((s) => ({ id: s.code, code: s.code, handling: s.handling })));
    expect(content.rules).toHaveLength(9);
    expect(JSON.stringify(content)).not.toMatch(/\d+\s*(m|metres|°|minutes|hours|days|%)/i);
  });

  it("reveals the follow-up height question only after a yes", () => {
    const q = starterFor([]).content.questions.find((x) => x.key === "height-where")!;
    expect(isShown(q, {})).toBe(false);
    expect(isShown(q, { height: ["no"] })).toBe(false);
    expect(isShown(q, { height: ["yes"] })).toBe(true);
  });
});
