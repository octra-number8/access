# Decisions log

Settled decisions, so they are not reopened without reason (CLAUDE.md §11).
Each entry records what was decided, by whom, and what it changes. Open items are at the end.

---

## D-001 — Source requirements document added
- **Date:** 24 October 2026 · **Decided by:** Wes Pierce
- `Octra Moe answers.docx` (238 questions, research checked 21 October 2026) is the source for [requirements-register.md](requirements-register.md).
- Note: CLAUDE.md §9 calls it "the 238-question review dated 21 October 2026"; this is that document.

## D-002 — Root appointment ceremony (Phase 0 gap G2)
- **Date:** 24 October 2026 · **Decided by:** Wes Pierce
- The first appointment at a venue is a recorded **root appointment** made by the customer's named duty holder, backed by an uploaded letter of appointment, confirmed by a second named person, and written as a dedicated audit event.
- Every later appointment must trace to an appointer holding `appointment.grant` for at least the granted scope (`appointment.appointed_under_appointment_id`).
- Tenant and platform administrators may *record* appointments but never grant authority (invariant 9).
- Related: Q14 (still requires technical-authority validation of the venue's actual appointment chain).

## D-003 — Authorisation service lives in Postgres (Phase 0 P1)
- **Date:** 24 October 2026 · **Decided by:** Wes Pierce
- The single authorisation service of CLAUDE.md §5 is implemented as Postgres functions (`authz.evaluate`, `authz.require`). The TypeScript layer is a thin typed wrapper and never re-derives a permission.
- Reason: the invariants must hold in the database; a TypeScript service plus database triggers would duplicate permission logic.
- Consequence: pgTAP tests are the primary proof for authorisation and RLS.

## D-004 — Migrate per phase, not the whole domain up front (Phase 0 P2)
- **Date:** 24 October 2026 · **Decided by:** Wes Pierce
- The whole domain is modelled on paper first; each build phase migrates only its own tables, together with their RPCs and tests.
- Amends CLAUDE.md §3 "Build and migrate this before building screens".

## D-005 — Colour and status rule (Phase 0 P3)
- **Date:** 24 October 2026 · **Decided by:** Wes Pierce
- No colour, score or percentage may imply that work is safe or compliant. Colour may signal a *recorded decision state* only as a secondary cue to text.
- Gate outcomes are words ("Admit", "Check with [owner]", "Do not admit"); permit statuses use neutral styling.
- Resolves the conflict between CLAUDE.md §2 ("never render a green status") and the build brief's green/amber/red gate model. Related: Q19, Q190–197.

## D-006 — Identity is per customer for the pilot (Phase 0 A2)
- **Date:** 24 October 2026 · **Decided by:** Wes Pierce
- `organisation` and `person` records belong to one customer. A contractor working at two customers' estates has two records; nothing is shared across tenants.
- Within a customer, one organisation identity holds venue-specific engagements (Q8, Q11).
- Revisit before a second customer, and only after the controller/processor split (G11, Q218) is settled. A later cross-customer link would be an explicit, consented relationship, never a merge.

## D-007 — Separation of duties: fixed floor plus venue rules (Phase 0 G3)
- **Date:** 24 October 2026 · **Decided by:** Wes Pierce
- **Fixed floor, in code, not configurable:** the person who submitted, declared or authored a record can never review, approve, issue or accept that same record (invariant 3).
- **Venue-configured extra rules, versioned with owner and effective date:** for example, reviewer ≠ issuer on the same permit, or no approver from the applicant's own organisation. These can add restrictions but never remove the floor (Q16).
- Enforced inside `authz.require` (D-003).

## D-008 — Building systems are an appointment scope (Phase 0 G5)
- **Date:** 24 October 2026 · **Decided by:** Wes Pierce
- Foundations add `system` (fire alarm, sprinklers, HV, …) linked many-to-many to the areas it serves, plus a system ownership register.
- An appointment scope row targets an area (optionally with descendants) **or** a system (optionally restricted to an area).
- Later, isolations and impairments attach to systems. Related: Q9, Q12, Q20, Q135–148.

## D-009 — Foundations schema approved
- **Date:** 24 October 2026 · **Decided by:** Wes Pierce
- [foundations-schema.md](foundations-schema.md) approved for build phase 1, with:
  - **Platform admin access:** none by default; break-glass grant with reason, customer-visible audit event and short expiry.
  - **Appointee acknowledgement:** required before an appointment is in force.
  - **Appointment suspension:** not in phase 1; revoke and re-issue instead.

---

## CLAUDE.md wording — applied 24 October 2026 (approved by Wes Pierce)

Applied verbatim to CLAUDE.md §2, §3, §4, §5 and §8. The copy of CLAUDE.md inside
`Octra Access - Build Brief for Claude Code.docx` still has the earlier wording; the
repository CLAUDE.md is the controlling version.

**§2, final paragraph** — replace with:
> Never render a colour, score or percentage that implies work is safe or legally compliant. Colour may signal a recorded decision state only as a secondary cue to text. Gate outcomes are words ("Admit", "Check with [owner]", "Do not admit"); permit statuses use neutral styling. A status means a decision was recorded, nothing more.

**§3, opening line** — replace "Build and migrate this before building screens." with:
> Model this in full before building screens. Migrate it phase by phase: each build phase adds only its own tables, with their RPCs and tests.

**§4, final line** — replace with:
> Transitions are enforced by a database state table plus trigger. Status changes only through `core.transition()`, which requires a valid decision context; any other write to a status column fails.

**§5, authorisation bullet** — append:
> This service is implemented in Postgres (`authz.*`); the TypeScript layer wraps it and never re-derives a permission.

**§8** — add under the end-to-end scenarios:
> Q231 defines five pilot workflows with the outage fallback exercised within them; scenario 6 above is that exercise made explicit. The launch gate's "five pilot scenarios" refers to Q231's five.

---

## Open — governance and privacy (do not block foundations migrations; G11 blocks pilot data)

| Ref | Question | Recommendation | What the source says |
|---|---|---|---|
| G10 | Product owner versus both founders. | Settle in writing between founders. | Q235 raises the same point. |
| G11 | Privacy controller/processor split. | Qualified privacy advice before any pilot data. | Q218, Q224. |

## Open — raised by the phase 1 build (see foundations-schema.md §14)

| Ref | Question | Recommendation |
|---|---|---|
| B1 | Who counts as an "equivalent" authority able to lift a restriction (Q18, invariant 7)? | Any holder of the same appointment type covering the scope, plus the owner's delegates. People from the restricted organisation are excluded. This is what is built. |
| B2 | Who may publish appointment type versions? | Phase 1: a tenant administrator, naming an owner. From phase 2: require the venue's root appointee (technical authority) to approve, with the administrator recording it (Q23). |
| B3 | Break-glass maximum duration. | 8 hours, as built. A platform setting, not venue configuration. |
| B4 | Supabase CLI on this machine is incomplete (`supabase-go` missing). | Reinstall the CLI so `supabase db reset` and `supabase test db` run; until then `scripts/db-test.sh` runs the same migrations and tests in the Supabase Postgres image. |

## Open — affect later phases

| Ref | Question | Recommendation |
|---|---|---|
| P4 | Configuration with no silent default blocks onboarding. | Configuration-completeness view and onboarding checklist in phase 1 (supports Q20–Q22). |
| P5 | Offline gate scope. | Pilot: manual fallback log plus read-only, age-warned manifest and reconciliation; full offline PWA later (Q198–Q203). |
| P7 | Long gap before users see anything. | Put pilot workflow 1 in front of venue staff at the end of phase 3. |
| N1 | **Lifting and rigging are deferred, but rigging over halls is routine at exhibition venues.** | Confirm the pilot estate's routine rigging volume. Q232's own risk note says that if a deferred control is routine for the first estate, validate it before launch or narrow the pilot. Q167–168 and Q183–184 overlap with event builds. |
| N2 | Answers relying on earlier Olympia/OES material. | Obtain the controlled source set listed in Q234 before configuring notice periods (Q84–90), urgent work (Q92, Q97) and review (Q17, Q70). |
