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

## D-010 — Lifting a restriction: owner, equivalent or owner's delegate (B1)
- **Date:** 24 October 2026 · **Decided by:** Wes Pierce
- A restriction may be lifted by the appointment that imposed it, any in-force appointment of the **same appointment type** covering the scope, or a delegate of the imposing appointment. People currently related to the restricted organisation are excluded. As built in phase 1; applies to every later restriction (person, organisation, permit suspension).

## D-011 — Appointment type versions need technical-authority sign-off (B2)
- **Date:** 24 October 2026 · **Decided by:** Wes Pierce
- Phase 1: a tenant administrator publishes, naming an owner (bootstrap only).
- From phase 2: a new version is proposed by an administrator and takes effect only when approved by an in-force root appointee at that venue (Q23). The bootstrap path remains only while the venue has no root appointment.

## D-012 — Phase 2 design approved
- **Date:** 24 October 2026 · **Decided by:** Wes Pierce
- [phase-2-design.md](phase-2-design.md) approved with the recommendations for P2-1 to P2-9: phase 2 is split into 2a (database and API) and 2b (screens, email, storage); engagements start `proposed` and need appointment-based approval against evidence; one accountable plus at most one deputy contractor administrator; uploader and owning organisation excluded from review; downloads blocked until scanned clean; PDF/JPEG/PNG up to 20 MB; restrictions have real effects; relationships activate only on the person's acceptance; appointment type versions need root-appointee approval.
- **Deferred:** the malware scanner product (P2-5) is chosen before 2b.

## D-013 — Malware scanner design approved
- **Date:** 24 October 2026 · **Decided by:** Wes Pierce
- [scanner-design.md](scanner-design.md) approved with S1–S6: self-hosted ClamAV on AWS ECS Fargate in eu-west-2, one always-on task; pull-based worker with leased jobs and no inbound endpoint; a `rejected` scan outcome; starting thresholds (poll 5 s, queue alert 15 min, heartbeat 5 min, signature maximum 24 h); the scanner's own Supabase login in AWS Secrets Manager, rotated quarterly; the `clamav/clamav` image pulled for local tests.

## D-014 — Malware scanning held off
- **Date:** 24 October 2026 · **Decided by:** Wes Pierce
- Scanning is held off for now and kept as an improvement "if this portal takes off". Supersedes the *deployment* part of D-013; the D-013 design stands for when scanning is switched on.
- Uploads are recorded as `not_scanned` (never "clean") and are usable at once. Reviewers are told on screen that the file has not been malware-scanned.
- Still in force: content-based type checks (PDF, JPEG, PNG only), 20 MB limit, SHA-256 recorded at upload, downloads only as 60-second attachment links after authorisation and audit, never served inline.
- The switch is `core.platform_setting` (`malware_scanning`), changeable only by migration. Turning scanning on later: deploy the scanner (docs/scanner-design.md), then a migration inserting `required`. Files recorded while it was off can then be scanned.
- Scanner code, tables and tests remain and keep passing (pgTAP with the setting on; end-to-end with `E2E_SCANNER=1`).
- **Risk accepted:** files reach reviewers' computers unscanned. Mitigation: reviewers use machines with up-to-date antivirus. Customers' security questionnaires may ask about this.

## D-015 — Inductions: bring OCTRA Induct's design, journey and content format into Access
- **Date:** 25 October 2026 · **Decided by:** Wes Pierce
- Phase 3 reuses the existing OCTRA Induct product (`~/Projects/Claude/Inductions`): its design tokens and look, its one-task-per-screen learner journey and components, and its content format (sections, blocks, questions with options and explanations, declaration).
- It is built on Access's data model, not Induct's: completions bound to a person at a venue, course version, language and method (self, assisted, facilitated); immutable completions; venue-set pass mark, retries and validity (CLAUDE.md §2, §3, §9).
- The two products are not integrated; Access does not depend on Induct at run time.

## D-016 — Phase 3 design approved
- **Date:** 25 October 2026 · **Decided by:** Wes Pierce
- [phase-3-design.md](phase-3-design.md) approved with P3-1 to P3-10: split into 3a (database, API, importer) and 3b (screens, Induct look, E3 screens); learners enter by personal induction link, email code or facilitation (no anonymous public link); minimal `event` and `event_phase` now; publication by an appointed H&S authority with author and submitter excluded; assessment and validity settings required per version with no defaults; safety-critical question flag; the app takes Induct's look, light-only; typed name by default, drawn signature optional per venue; English only for now with language recorded; Induct components copied with provenance.

## D-017 — Phase 4 design approved
- **Date:** 25 October 2026 · **Decided by:** Wes Pierce
- [phase-4-design.md](phase-4-design.md) approved with P4-1 to P4-8: split into 4a (database, API, pgTAP) and 4b (screens); the Q56/Q183 trigger list offered only as an importable draft screening set needing technical-authority approval; packages started by organisation administrators of a party with an active, unrestricted engagement, or by tenant administrators; one performing organisation per package, event builds as linked packages; change kind decided by the fields changed, with scope, method, performing organisation, areas, systems, window, supervisor and screening answers always material; no recommendation is not a decision, so a recorded "no permit required" decision is needed; deferred specialist work through external-reference holds (N1 still to confirm); work types are venue configuration.

---

## D-018 — Phase 5 design approved
- **Date:** 25 October 2026 · **Decided by:** Wes Pierce
- [phase-5-design.md](phase-5-design.md) approved with P5-1 to P5-12: split into 5a (permits, class configuration, approval routes, information requests), 5b (calendars, notice, exceptions, team, issue, acceptance) and 5c (screens); one Work Approval per job needing any permit, with each required class a linked child permit; `Refused` added as a permit side state (CLAUDE.md §4 amended); the parent/child rules of invariant 4 as a database trigger; approved, versioned class configuration with no defaults before a class can be used; occupier and landlord approval through venue appointments scoped to the demise or system, with a venue-kept area occupation register and venue-named parties (settles P4-9); every step re-confirms on a resubmitted version; calendars, notice rules and restriction windows are configuration with no defaults; late notice and restriction clashes in phase 5, emergency and urgent make-safe work in phase 6; four-eyes issue, not before the window's first day; classes needing physical controls not issued until phase 6; an appointed authority can require a class screening missed (settles P4-10).

---

## D-019 — Phase 6 design approved
- **Date:** 25 October 2026 · **Decided by:** Wes Pierce
- [phase-6-design.md](phase-6-design.md) approved with P6-1 to P6-14: split into 6a (live lifecycle), 6b (physical controls), 6c (hand-back, closure, emergency work) and 6d (screens); a wide right to stop work through a new *permit part* basis inside `authz.evaluate`; resumption needs the owning authority's lift and the supervisor's re-acceptance; every material change to a live job suspends its live permits and requires a reissue (`Suspended → Submitted` added to CLAUDE.md §4); extension by an issuer within class limits that must be chosen; worker additions count only once briefed, and a supervisor change suspends the permit until the new supervisor accepts; missed revalidation is shown, never a silent status change; `physical_controls` replaces `requires_physical_controls`, with existing classes "not yet chosen"; the isolation lifecycle with apply/prove/witness rules per system type; expired and suspended permits close out through hand-back (CLAUDE.md §4 amended); the emergency route built but nobody appointed until Q91/Q92 are defined; partial hand-back by child, area and worker; required notifications recorded as given; access authorisations and roof access without work move to phase 7.

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
| B3 | Break-glass maximum duration. | 8 hours, as built. A platform setting, not venue configuration. |

## Open — raised by the phase 2a build (see phase-2-design.md §11)

| Ref | Question | Recommendation |
|---|---|---|
| C1 | When an organisation's accountable administrator leaves, who takes over? | A tenant administrator sets the new one (built). Notify the venue owner when it happens (notifications phase). |
| C2 | Evidence uses the latest submitted version, so a newer version awaiting review blocks. | Keep: the newest evidence is what the contractor is relying on. |
| C3 | Organisation administrators can see their people's contact details. | Keep, subject to the privacy adviser (G11). |

## Open — raised by the phase 2b build

| Ref | Question | Recommendation |
|---|---|---|
| E1 | Production email: invitations are sent by the app over SMTP, and Supabase Auth sends sign-in codes. Supabase's built-in mail is not for production. | One UK/EU-hosted SMTP provider for both (configured in Supabase Auth and the app), with SPF/DKIM on an Octra sending domain. Choose before the pilot. |
| E2 | Hosting for the scanner, when scanning is switched on (D-014). | AWS Fargate London (D-013) or Fly.io London; decide when scanning is needed. |
| E3 | Screens for the remaining phase 2 actions (see phase-2-design.md §12). | Build them alongside phase 3 (inductions), where operatives and contractor administrators first need them. |

## Open — raised by the phase 3a build (see phase-3-design.md §11)

| Ref | Question | Recommendation |
|---|---|---|
| I1 | Maximum size for induction video files. | 200 MB per video (a few minutes of 1080p). Documents and images stay at 20 MB (P2-6). |

## Open — raised by the phase 4b build (see phase-4-design.md §13)

| Ref | Question | Recommendation |
|---|---|---|
| P4-9 (settled by D-018, P5-6) | How are other parties (commissioning, principal contractor, affected occupier, landlord/operator) named on a job? A contractor-facing list of organisations would disclose who is engaged at the venue. | The venue names them: tenant administrators add parties on the job page; contractors see the parties' names on their own jobs but never a list of the venue's organisations. Revisit with the privacy adviser (G11) and when approval routes need occupiers (phase 5, Q77–Q78). |
| P4-10 (settled by D-018, P5-12) | Can the venue's authority require a permit that screening missed, on a job already in screening? | Yes, in phase 5: an appointment-based "require a class" decision with a reason, which adds an accepted recommendation and is recorded against the authority. Until then the applicant changes the job and selects the class. |

## Open — affect later phases

| Ref | Question | Recommendation |
|---|---|---|
| P4 | Configuration with no silent default blocks onboarding. | Configuration-completeness view and onboarding checklist in phase 1 (supports Q20–Q22). |
| P5 | Offline gate scope. | Pilot: manual fallback log plus read-only, age-warned manifest and reconciliation; full offline PWA later (Q198–Q203). |
| P7 | Long gap before users see anything. | Put pilot workflow 1 in front of venue staff at the end of phase 3. |
| N1 | **Lifting and rigging are deferred, but rigging over halls is routine at exhibition venues.** | Confirm the pilot estate's routine rigging volume. Q232's own risk note says that if a deferred control is routine for the first estate, validate it before launch or narrow the pilot. Q167–168 and Q183–184 overlap with event builds. |
| N2 | Answers relying on earlier Olympia/OES material. | Obtain the controlled source set listed in Q234 before configuring notice periods (Q84–90), urgent work (Q92, Q97) and review (Q17, Q70). |
