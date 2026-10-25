# Build phase 4 — work packages and activity screening: design for approval

**Status:** Approved 25 October 2026 (D-017). Decisions are in §11.
Builds on phases 1–3: tenancy, areas and systems, appointments and the authorisation service (phase 1); organisations, engagements, evidence and restrictions (phase 2); events (phase 3).

Source questions: Q48–Q54 (work packages, all **Proposed**), Q55–Q60 (permit selection, all **Requires specialist validation**), with Q9, Q12, Q183 and Q185 for parties, affected occupiers and event builds. Nothing in them is approved by default (CLAUDE.md §9). In particular, **which activities trigger which permit is technical-authority content**: this phase builds the machinery and the approval route for it, never the content.

---

## 1. What phase 4 delivers

A contractor (or the venue) describes a job as a **work package**, answers the venue's **activity screening**, and sees which permit classes the venue's approved rules recommend, with the reason for each. The contractor accepts a recommendation or **challenges** it; an appointed authority decides the challenge. Where nothing is recommended, or a challenge succeeds, an appointed authority records a **"no permit required" decision** with a reason. The package is then **routed**: the list of permit classes it needs is fixed for phase 5 to build the permits.

What it does **not** do:
- Screening never authorises work. "Routed" means a routing decision was recorded, nothing more: there is no permit, no issue and no permission to start until phase 5–6.
- No AI classifier and no hidden scoring. Every recommendation is traceable to a rule the venue's technical authority approved (CLAUDE.md §7).
- No permits, approval routes, notice periods or calendars (phase 5).

Proposed split, as before (decision P4-1): **4a** database, API and pgTAP; **4b** screens.

## 2. Work packages (Q48–Q54, Q9, Q185)

| Table | Holds |
|---|---|
| `work_type` | Venue configuration: the starting branches of one journey (Q50), e.g. routine maintenance, access/survey, inspection, fit-out, event build. Owner, version, effective date. No list is hard-coded. |
| `work_package` | Venue, reference, work type, optional event and event phase, **performing organisation's engagement** (required), status, current revision, created by, `row_version`. |
| `work_package_revision` | **Immutable.** One per change: title, scope, method summary, planned window, contact, proposed supervisor (optional in draft), areas, affected systems, parties, change kind (`initial` / `administrative` / `material`), reason, author. The package always points at its current revision. |
| `work_package_area` / `work_package_system` | Revision × area (phase 1 hierarchy) and revision × system. At least one area before submission. |
| `work_package_party` | Revision × organisation × role: `commissioning`, `performing`, `principal_contractor`, `affected_occupier`, `landlord_operator` (Q9). Exactly one `performing`; others optional and declared by the applicant (Q12). |

- **Who starts one (Q48):** an organisation administrator of an organisation with an **active, unrestricted engagement** at the venue, for work it performs or commissions; or a tenant administrator for the venue. This is administration, not operational authority (invariant 9). **[P4-3]**
- **Minimum to save a draft (Q49):** title, work type, performing organisation, scope, at least one area, an estimated window, a contact. Everything else can wait.
- **One performing organisation per package (Q185):** an event build with several contractors is several packages linked to the same event and phase; the event view lists them together. **[P4-4]**
- **Changes (Q53, invariant 6):** every change is a new revision. The kind is decided by **which fields changed**, not by the person making it:
  - *material*: scope, method, performing organisation, areas or systems, the planned window, the supervisor, or any screening answer;
  - *administrative*: title wording, contact details, description typos — with a reason, visible in the history.

  A material change after submission returns the package to `draft`, marks its screening outcome superseded, and requires screening again. **[P4-5]**
- **States:** `draft` → `screening` (submitted; answers locked; recommendations open) → `routed` (every recommendation settled) — plus `cancelled` from `draft` or `screening`. Phase 5 adds the states after `routed`. Transitions go only through `core.transition()` (CLAUDE.md §4).

## 3. Activity screening (Q55–Q57)

| Table | Holds |
|---|---|
| `screening_set` / `screening_set_version` | Venue configuration. Version status `draft` → `proposed` → `approved` / `rejected` → `superseded`. Owner, effective date, proposer, decider and reason. **Immutable once proposed.** |
| `screening_question` | Set version, key, wording, help text, answer type (`yes_no` / `choose_one` / `choose_many`), options, order, and an optional "show only if" condition on an earlier answer (Q63's progressive reveal). |
| `activity_screening_rule` | Set version, key, conditions (all must hold: question key + answers), action, **plain-English rationale** shown to the applicant, and the permit class it recommends — or `external_reference` for a deferred specialist class (§6). |
| `screening_response` | **Immutable.** Work package revision × set version: each answer, the respondent, `submitted_at`. |
| `screening_recommendation` | Work package revision × permit class: the rules that matched (or `applicant_selected` for the direct route), and its state (§4). |

- **How a recommendation is made:** on submission the database evaluates every rule of the approved set version against the answers. Each matching rule adds or confirms a recommendation for its class. The result is stored, so it is the same tomorrow even if the rules change.
- **What the applicant sees:** "Because you answered *Yes* to *Will the work produce heat, flame or sparks?*, the venue's screening (version 3, approved by [name] on [date]) recommends **Hot Works**." Every matched rule is listed.
- **Direct route for frequent users (Q55):** the applicant may also select classes directly. A direct selection **adds** a recommendation (`applicant_selected`). It never removes one: the full screening still runs, and only a challenge decision can remove a rule's recommendation.
- **Several classes, one parent (Q57):** screening can recommend several classes. Which one is the parent (the Work Approval) is a phase 5 matter; screening records the classes only.
- **No approved set, no screening:** a venue with no approved screening set version can draft packages but cannot submit them. The refusal says so and names the venue's technical authority as the person who can resolve it.

## 4. Recommendations, challenges and "no permit required" (Q58, Q59)

A recommendation's states: `recommended` → `accepted` (by the applicant) or `challenged` → `upheld` / `not_required` (by an appointed authority).

| Table | Holds |
|---|---|
| `screening_challenge` | Recommendation, the applicant's reason, supporting document versions, raised by. One open challenge per recommendation. |
| `challenge_decision` | **Immutable.** Outcome (`upheld` / `not_required`), reason, decider and acting capacity, decision context. |
| `no_permit_required_decision` | **Immutable.** Work package revision, scope wording ("no permit is required for [scope] at [areas] during [window]"), reason, decider and acting capacity. Created either for a whole package or by a `not_required` challenge outcome. |

- **While a challenge is open,** the package stays in `screening`: unresolved, never treated as routed. Time passing never resolves it (invariant 10).
- **Who decides (Q59):** someone holding a current appointment for `screening.decide` that covers **that permit class** and the package's areas. People from any party to the package, and whoever raised the challenge, are excluded (invariant 3). Administrators cannot decide (invariant 9).
- **When nothing is recommended:** this does **not** mean no permit. Absence of a recommendation is not a decision. The package cannot be routed until an appointed authority records a `no_permit_required_decision` for it, or the applicant selects a class. **[P4-6]**
- **Wording:** "No permit required" is scoped to the stated work, areas and window, never "approved" or "safe" (CLAUDE.md §1, Q72).
- **Routed** is reached when every recommendation is `accepted`, `upheld` or `not_required`, any whole-package decision is recorded, and every external-reference hold (§6) is resolved.

## 5. Approving the screening content (Q55–Q56: specialist validation)

- The questions and rules are drafted by a tenant administrator, then **proposed** and **approved** by someone holding a current appointment for `screening_set.approve`: the venue's technical authority. The proposer is excluded. This is the same route as appointment types (D-011).
- Once approved, a version is immutable. Changes are a new version, which applies to packages **submitted after** its effective date; packages already screened keep the version they were screened under.
- **Starter content [P4-2]:** Q56 and Q183 list trigger activities: heat, flame or sparks; hazardous energy or isolation; confined space; roofs and higher-risk work at height; lifting and rigging; excavation and penetration near services; fire and life-safety impairment; temporary structures. Octra can provide these as an **importable draft**, clearly marked "proposed — requires validation by your technical authority". It is never active until the venue approves it, and it carries no notice periods, thresholds or distances (CLAUDE.md §9).

## 6. Deferred specialist work: external-reference holds (CLAUDE.md §7)

A rule's action can be `external_reference` instead of a permit class, for confined space, complex lifting and rigging, excavation and penetration, and the rare specialist classes.

| Table | Holds |
|---|---|
| `external_reference_hold` | Work package revision, the specialist area named by the rule (configuration, never a free "other specialist work" tickbox), state `open` → `accepted` / `refused`. |
| `external_reference_evidence` | The external decision-maker and organisation, reference, scope, date, conditions, supporting document versions (Q82). |
| `external_reference_decision` | **Immutable.** Accepted or refused, reason, decider (appointment for `external_reference.decide` covering that specialist area), decision context. |

An open hold keeps the package unrouted. Refusal leaves it unroutable for that scope; the applicant can change the scope (a material change) or cancel. **N1 still applies:** if routine rigging is common at the pilot estate, that procedure has to be validated before launch, or the pilot narrowed.

## 7. Authority and actions

| Action | Basis | Notes |
|---|---|---|
| `work_type.create` · `screening_set.draft` / `propose` | tenant admin | Configuration. |
| `screening_set.approve` / `reject` | appointment | Venue technical authority; proposer excluded. |
| `work_package.create` / `revise` / `submit` / `cancel` | organisation admin (party with active engagement) or tenant admin | Restricted organisations refused (D-010). |
| `screening.answer` / `select_class` / `accept` / `challenge` | organisation admin of the performing or commissioning party, or the package's author | Answers lock on submission. |
| `screening.decide` (challenge outcome, whole-package "no permit required") | appointment, scoped to permit class and area | Parties and challenger excluded. |
| `external_reference.decide` | appointment, scoped to the specialist area | Parties excluded. |

**Who sees a package:** people from its party organisations (administrators and the named contact and supervisor), tenant administrators of the venue, and appointees whose appointment covers a decision on it. Another contractor never sees it. Party organisations see each other's names on the package, never each other's documents.

## 8. Screens (4b)

- **Contractor, mobile-friendly:** "Start a job" (choose a work type), then scope, areas, window and parties. Screening is one question per screen with progressive reveal. The result screen gives each recommendation with its reason, and **Accept** or **Challenge** (reason plus documents). A job page shows the next action, who owns it, and what is outstanding (Q54).
- **The result screen explains the three decisions (Q60)** in ordinary words: entry to a place, permission to do the defined task, and technical isolation are separate, and screening has decided none of them.
- **Venue:** screening set authoring (questions, rules, a preview that runs sample answers) and proposal; work types; a work-package list of actions, owners and deadlines (no headline counts).
- **Authority (decisions page):** screening set approvals, challenges, whole-package "no permit required" requests and external-reference holds, each with the evidence and the matched rules.

## 9. What phase 4 leaves for phase 5

Permit records and their Work Approval parent; approval routes, including occupier and landlord approval driven by `affected_occupier` parties and the system-ownership register (Q76–Q78); notice periods, working calendars and late-notice decisions, including event conflicts (Q84–Q97, scenario 4); RFIs and resubmission (Q69–Q75). An area-to-occupier (demise) register belongs there too; phase 4 records only what the applicant declares.

## 10. Proof

- **pgTAP, positive:** a full path from draft to screening to routed. The stored recommendation shows the matched rule and the set version, and survives a later rule change.
- **pgTAP, negative:**
  - submission with no approved set;
  - a proposed or rejected set used for screening;
  - the proposer approving their own set;
  - answers changed after submission;
  - a recommendation removed except by a challenge decision;
  - the challenger or any party's person deciding;
  - a tenant or platform administrator deciding a challenge or recording "no permit required" (invariant 9);
  - an appointee whose scope does not cover the permit class or area;
  - a restricted organisation creating a package;
  - a package routed with an open challenge, an open hold or no recommendation and no decision;
  - an administrative edit to a material field;
  - idempotent replay of submit and decide;
  - a concurrent revise (version conflict);
  - cross-tenant and cross-venue reads and writes on every new table.
- **pgTAP, material change:** after routing, a change to area or window supersedes the outcome and returns the package to draft. The old revision, answers and decisions stay readable and unchanged.
- **Mutation testing** of the screening evaluator, the exclusion rules and the routed check.
- **End-to-end and browser (4b):** a contractor's job with Hot Works recommended. The challenge is refused (upheld), the recommendation is accepted, and the package is routed. A second job with nothing recommended gets a recorded "no permit required" decision. A material change sends a routed job back to screening. Checked at 360 px and on desktop.

## 11. Decisions needed

| Ref | Decision | Recommendation |
|---|---|---|
| P4-1 | Split into 4a (database, API, pgTAP) and 4b (screens)? | **Yes**, as in phases 2 and 3. |
| P4-2 | Provide the Q56/Q183 trigger list as an importable **draft** screening set, marked as needing technical-authority validation, never active by default? | **Yes.** It speeds onboarding without promoting a proposal into enforced logic (CLAUDE.md §9); the venue's technical authority must approve it. |
| P4-3 | Who can start a package: organisation administrators of a party with an active, unrestricted engagement, and tenant administrators? Supervisors and other colleagues join drafts later (Q65). | **Yes** for v1. An engagement still `proposed` cannot start one; restricted organisations are refused. |
| P4-4 | One performing organisation per package; event builds are several packages linked to the event (Q185)? | **Yes.** It keeps one accountable organisation per job; a shared coordination view comes from the event link. |
| P4-5 | Change kind decided by the fields changed. Scope, method, performing organisation, areas, systems, window, supervisor and screening answers are always **material** in v1. | **Yes**, conservative. The technical authority can later agree narrower rules, such as shortening a window within the original one. |
| P4-6 | No recommendation is not a decision: a package with nothing recommended needs a recorded "no permit required" decision by an appointed authority before it is routed. | **Yes.** It matches Q59 and invariant 10, and makes the authority's judgement visible. The cost is one extra decision for genuinely simple jobs, which a venue can reduce by writing rules. |
| P4-7 | Deferred specialist work is handled by external-reference holds created by screening rules, decided by an appointee for that specialist area (CLAUDE.md §7). | **Yes**, with N1 (routine rigging) to be confirmed for the pilot estate before launch. |
| P4-8 | Work types are venue configuration rather than a fixed list. | **Yes.** Q50's five branches can be offered as suggested entries for the venue to add. |

Open items this phase does not settle: **N2** (notice periods and the Olympia/OES source, phase 5), **C1** (accountable administrator leaving), **G11** (privacy wording), and the **screening content itself**, which is for the technical authority (Q55–Q59).

---

## 12. As built (phase 4a, 25 October 2026)

Implemented in `supabase/migrations/20261025000027…29`; proved by pgTAP `22_screening_config`, `23_work_packages` and `24_screening_decisions` (637 assertions in the whole suite). Eight deliberate weakenings were each caught: routing with an open challenge, a connected person deciding, one area being enough, every change treated as administrative, rules firing on any condition, a whole-job "no permit required" overriding recommendations, "nothing recommended" treated as no permit, and answers changeable after submission. The first run let four of them through; the tests were strengthened until each was caught. No screens yet (4b).

| Area | As built | Note |
|---|---|---|
| Screening content | One validated document per version (`questions`, `rules`), like course versions, not separate question and rule tables | Structural checks on every save; strict checks (at least one question and rule, classes current) at proposal and approval. Immutable once proposed. |
| Effective date | A version takes effect when it is approved; one approved version per venue | Approval supersedes the previous version. Jobs keep the version they were screened under (`screening_response.set_version_id`). |
| Deferred specialist classes | A permit class with `handling = 'external_reference'`, created by `api.create_external_class` | Appointments are already scoped by permit class, so the authority for a specialist area uses the same scoping. Such a class can never be selected directly or recommended; a matching rule creates a hold. |
| Work types | Venue configuration with label and retirement; no version history | Not a safety threshold, so versioning was not needed. |
| Performing organisation | Fixed by the engagement for the life of the job | Changing who performs the work means a new job. |
| Change kind (P4-5) | Decided by comparing facts: only title and contact are administrative; anything else is material | A material change after submission supersedes every recommendation and hold and returns the job to draft. Earlier answers and decisions stay unchanged. |
| Who acts | Organisation administrators of the performing organisation, or of a commissioning party engaged at the venue; tenant administrators through separate `_for_venue` actions | Accepting, challenging and adding external evidence are for party organisations only. |
| Multi-area scope | `authz.capacities` now also takes `area_ids` / `system_ids`; a decision needs an appointment covering every one | An extension of the existing scope rule to lists. Proved by a Hall 1 authority being refused for a job in Halls 1 and 2. |
| Restrictions | `authz.evaluate` refuses work package creation and submission for a restricted performing organisation, including when a commissioning party acts | D-010 applied to work. |
| Repeated requests | The shared pre-check (`core.authorised_or_refusal`) now hands a reused request key straight to `authz.require`, so a repeated request is replayed, never re-judged | Found by the idempotency test: a repeated submission was answered "not a draft" instead of being replayed. Applies to the phase 3 functions too. |
| Routed | Every recommendation accepted, upheld or not required; every hold accepted; and either a class is required or a "no permit required" decision exists | An accepted hold alone does not route a job (P4-6). |
| Not built in 4a | Screens (4b); the starter screening set (P4-2), to be shipped with the 4b authoring screen; reminders | |
