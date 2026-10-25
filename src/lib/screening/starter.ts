// Starter screening content (P4-2), drawn from the trigger activities in Q56 and Q183.
//
// PROPOSED ONLY. It requires validation by the venue's technical authority (Q55-Q59) and
// becomes a draft, never an approved version. It carries no notice periods, thresholds,
// distances or durations (CLAUDE.md §9). Rules name a suggested class code; a rule is
// imported only if the venue has a class with that code and the expected handling.

import type { ScreeningContent, ScreeningQuestion } from "./content";

export const STARTER_SOURCE = "Octra starter set from Q56 and Q183 — proposed, requires validation by the venue's technical authority";

export interface SuggestedClass {
  code: string;
  name: string;
  handling: "permit" | "external_reference";
}

/** Classes the starter rules refer to. Deferred specialist work is external reference (CLAUDE.md §7). */
export const SUGGESTED_CLASSES: SuggestedClass[] = [
  { code: "HW", name: "Hot works", handling: "permit" },
  { code: "ISO", name: "Electrical and mechanical isolation", handling: "permit" },
  { code: "WAH", name: "Work at height and roof work", handling: "permit" },
  { code: "LSI", name: "Life-safety impairment", handling: "permit" },
  { code: "CS", name: "Confined space entry", handling: "external_reference" },
  { code: "LR", name: "Lifting and rigging", handling: "external_reference" },
  { code: "EXC", name: "Excavation and penetration near services", handling: "external_reference" },
  { code: "TS", name: "Temporary structures and installations", handling: "external_reference" },
];

const QUESTIONS: ScreeningQuestion[] = [
  { key: "hot", type: "yes_no", text: "Will the work produce heat, flame or sparks?",
    help: "For example welding, cutting or grinding metal, soldering, brazing, or using a torch or heat gun." },
  { key: "isolate", type: "yes_no", text: "Does any electrical, mechanical or other energy source need to be isolated or made dead?",
    help: "For example switching off and locking a circuit, a motor, a pressure system or a moving machine." },
  { key: "height", type: "yes_no", text: "Will anyone work at height?" },
  { key: "height-where", type: "choose_many", text: "Where at height?", show_if: { question: "height", answers: ["yes"] },
    options: [
      { key: "roof", text: "On a roof" },
      { key: "edge", text: "Near an open edge, void or fragile surface" },
      { key: "mewp", text: "From a mobile elevating work platform" },
      { key: "scaffold", text: "From a scaffold or mobile tower" },
      { key: "ladder", text: "From a ladder or steps" },
    ] },
  { key: "life-safety", type: "yes_no",
    text: "Will any fire alarm, detection, sprinkler, smoke control or other life-safety system be disabled, covered or altered?" },
  { key: "confined", type: "yes_no", text: "Will anyone enter a tank, vessel, duct, pit, void or other confined space?" },
  { key: "lifting", type: "yes_no", text: "Will anything be lifted, rigged or suspended?",
    help: "For example cranes, hoists, chain motors, or rigging from the building structure." },
  { key: "penetrate", type: "yes_no", text: "Will the work dig, drill, core or cut into floors, walls, ceilings or ground where services may be hidden?" },
  { key: "structure", type: "yes_no", text: "Will the work put up a temporary structure or installation?",
    help: "For example a stage, seating, a marquee, a large screen, an inflatable or a suspended display." },
];

const RULES: Array<{ key: string; class: string; all: Array<{ question: string; answers: string[] }>; rationale: string }> = [
  { key: "r-hot", class: "HW", all: [{ question: "hot", answers: ["yes"] }],
    rationale: "Heat, flame or sparks can start a fire, so the venue controls them with a hot works permit." },
  { key: "r-isolate", class: "ISO", all: [{ question: "isolate", answers: ["yes"] }],
    rationale: "Isolating an energy source must be done and proved by a competent person under an isolation permit." },
  { key: "r-roof-edge", class: "WAH", all: [{ question: "height-where", answers: ["roof", "edge"] }],
    rationale: "Roof work and work near open edges or fragile surfaces need a work at height permit." },
  { key: "r-access-equipment", class: "WAH", all: [{ question: "height-where", answers: ["mewp", "scaffold"] }],
    rationale: "Work from platforms and scaffolds needs a work at height permit." },
  { key: "r-life-safety", class: "LSI", all: [{ question: "life-safety", answers: ["yes"] }],
    rationale: "Disabling or altering a life-safety system needs an impairment permit with compensating measures." },
  { key: "r-confined", class: "CS", all: [{ question: "confined", answers: ["yes"] }],
    rationale: "Confined space entry is specialist work: the venue needs evidence of a validated specialist arrangement first." },
  { key: "r-lifting", class: "LR", all: [{ question: "lifting", answers: ["yes"] }],
    rationale: "Lifting and rigging are specialist work: the venue needs evidence of a validated lifting plan first." },
  { key: "r-penetrate", class: "EXC", all: [{ question: "penetrate", answers: ["yes"] }],
    rationale: "Breaking into fabric or ground near hidden services is specialist work: the venue needs evidence of service checks first." },
  { key: "r-structure", class: "TS", all: [{ question: "structure", answers: ["yes"] }],
    rationale: "Temporary structures bring structural, fire, electrical and crowd interfaces that need specialist review." },
];

/**
 * The starter content mapped onto a venue's classes. Rules whose class the venue does not
 * have (with the expected handling) are left out and reported, never created silently.
 */
export function starterFor(classes: Array<{ id: string; code: string; handling: string; retired_at?: string | null }>): {
  content: ScreeningContent;
  missing: SuggestedClass[];
} {
  const byCode = new Map(classes.filter((c) => !c.retired_at).map((c) => [c.code.toUpperCase(), c]));
  const missing = SUGGESTED_CLASSES.filter((s) => byCode.get(s.code)?.handling !== s.handling);
  const rules = RULES.flatMap((r) => {
    const c = byCode.get(r.class);
    const expected = SUGGESTED_CLASSES.find((s) => s.code === r.class)!;
    return c && c.handling === expected.handling
      ? [{ key: r.key, all: r.all, permit_class_id: c.id, rationale: r.rationale }]
      : [];
  });
  return { content: { questions: QUESTIONS, rules }, missing };
}
