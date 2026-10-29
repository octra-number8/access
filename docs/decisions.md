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
- The first appointment at a venue is a recorded **root appointment** made by the customer's named duty holder, backed by an uploaded letter of appointment (corrected by D-026: a reference to the signed letter), confirmed by a second named person, and written as a dedicated audit event.
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

## D-020 — Phase 7 design approved
- **Date:** 26 October 2026 · **Decided by:** Wes Pierce
- [phase-7-design.md](phase-7-design.md) approved with P7-1 to P7-13: split into 7a (entry rules, passes, evaluation, scans, overrides), 7b (access visits), 7c (screens) and 7d (offline); entry rules per audience as venue configuration drafted by the venue and approved by an `entry_rule.approve` appointee, with no default; a phone pass with a code changing every 30 seconds plus a revocable printed card; no photographs held by Octra for the pilot; gate operators and overrides by appointment (`gate.operate`, `gate.override`), overrides time-limited with a fixed never-overridable floor (restriction, revoked pass, deactivated person) plus the venue's list; access visits as a separate workflow never converting into a permit; offline as a read-only manifest with a venue-set maximum age, manual fallback entries and reconciliation exceptions with owners; the outage procedure as venue configuration; browser barcode reading with a typed fallback; permits only as notices at the gate; people outside the three audiences not decided by Octra. P7-14 (who holds the gate roles at the pilot venue) to follow with the venue.

## D-021 — Phase 8 design approved
- **Date:** 27 October 2026 · **Decided by:** Wes Pierce
- [phase-8-design.md](phase-8-design.md) approved with P8-1 to P8-15: split into 8a (jobs and notifications), 8b (dashboards and reports), 8c (packs, exports, history, corrections) and 8d (retention and legal holds); notifications written in the decision's own transaction to recipients resolved from appointments and ownership, delivered by a job; a mandatory critical class, always emailed and never switchable off, each notice saying the venue's direct route still applies; email and in-app inbox only, routine notices by personal choice; reminder and escalation intervals and contacts as venue configuration with no default, escalation only adding recipients; one scheduled job runner acting as a service account, with leases, idempotent jobs and a run log; dashboards as lists of actions with owners and deadlines; permit packs from frozen snapshots and the audit log only, as a PDF plus evidence files in a ZIP with hashes, using `pdf-lib`, its font support and `fflate` (download approved); external packs always remove the Q214 list but never decision-makers; record history for anyone who can see the record; corrections beside the original; retention rules with no default, disposal confirmed batch by batch, the audit log not disposed of in this phase; legal holds by separate requester and approver, never lapsing; the external reviewer view, portable disclosure withdrawal, scheduled report emails and SMS deferred. P8-16 (who holds export, retention and legal-hold authority at the pilot venue) to follow with the venue.

## D-022 — Phase 8d detailed design approved
- **Date:** 28 October 2026 · **Decided by:** Wes Pierce
- [phase-8-design.md](phase-8-design.md) §16 approved with 8d-1 to 8d-5: from migration 0058 the audit log records action, actor, capacity, target, time, the columns changed by name, the reason and a per-record keyed digest, never record contents; disposal categories, triggers and methods as in §16.2, with appointments, identities, job runs and the audit log kept; a person's or organisation's files disposed of only when every venue of the customer has a rule that has run out; closed jobs deleted outright, packs included; built as 8d(a) (audit change, schedule, holds, disposal except closed jobs, live-record corrections) and 8d(b) (closed-job disposal). Settles 8c-5 (live-record corrections in 8d). Every retention period remains the venue's, with no default; G11 and P8-16 remain open.

## D-023 — Phase 8 build decisions settled
- **Date:** 28 October 2026 · **Decided by:** Wes Pierce
- [phase-8-design.md](phase-8-design.md) decisions accepted as recommended:
  - **As built:** 8a-1 (fire watch overdue when arranged but not started once its permit is suspended, in hand-back or expired; validate with the venue, and any time after work stops would be venue configuration with no default); 8a-3 (invitation reminders to the invitation's owner); 8b-1 (two-day venue dashboard for the pilot); 8b-2 (refused hand-back attempts not recorded); 8b-3 (contractors see who recorded a decision, never who could make it); 8c-4 (whole-job packs only); 8d-6 (evidence-file corrections recorded beside the file, never applied); 8d-8 (venue-less notices disposed of with the venue holding the longest rule); 8d-9 (a hold on one person keeps the whole offline manifest); 8d-10 (declined records listed again only under a new schedule version); 8d-11 (induction links, invitations and passes as retention categories, as built in 8d(b)); 8d-13 (a job kept until its isolation is returned to service); 8d-14 (contact records left to identity erasure, G11 and Q220).
  - **Built before the pilot:** 8a-2 (critical notices about people without an Octra account also go to their organisation's administrators); 8c-2 (Noto Sans, SIL Open Font Licence, bundled with its licence for PDF packs; download approved); 8d-12 (the retention page shows what holds kept back at the last run, per category).
  - **Interim, subject to the privacy adviser (G11):** 8c-1 (external packs always leave out a person's own documents); 8c-3 (free-text home addresses not pattern-matched; the cover tells the exporter to review); 8d-7 (document visibility not widened to correction appointees).
- P8-16 and G11 remain open.

## D-024 — Phase 6 and 7 build decisions settled
- **Date:** 28 October 2026 · **Decided by:** Wes Pierce
- Accepted as recommended:
  - **As built:** 6a-1 (a child permit ending its window expires without stopping its Work Approval); 6a-2 (stop categories fixed in code); 6b-1 (isolation and impairment rules published in one step by an appointed technical authority, for the pilot); 6b-3 (control failure for isolations and impairments only); 6b-4 (isolations and impairments asked for only against permits); 6c-2 (where a rejected hand-back returns); 6c-3 (area stops and restriction checks keep the job's full areas after a partial return; the gate shows permits only as notices, P7-9); 6d-1 (versioned venue emergency contacts; publishing them is a go-live checklist item); 6d-2 (area appointments do not cover systems, D-008); 7a-1 (a gate result is valid for 5 minutes, fixed); 7a-3 (admission on the most favourable fully qualifying engagement); 7b-2 (occupiers see visits only through their appointed representative); 7c-1 (the in-house QR encoder kept); 7c-3 (settled by 7d: the phone hides a code it cannot refresh); 7d-1 (reconciliation against the live record at upload); 7d-4 (work exceptions resolved through `gate.reconcile_work`); I1 (induction videos up to 200 MB; the hosted project's global upload limit must allow it).
  - **For the pilot, to revisit:** 6a-3 (no minimum team size until the technical authority asks for one); 6b-2 (fire watch recorded by the supervisor naming the watcher); 7a-2 (escort per audience, not per area); 7b-1 (attendance from gate scans only); 7c-2 (one covering appointment per gate person; no capacity chooser yet).
  - **Built before the pilot:** 7d-2 (the gate page works after a reload during an outage); 7d-3 (gate devices refresh their manifest automatically while online, at an interval the venue sets with no default; manual until set).
- 6c-1, P7-14, E1, N1 and N2 remain open.

## D-025 — Earlier open items settled (G10, E2, E3, P4, P5, P7)
- **Date:** 28 October 2026 · **Decided by:** Wes Pierce
- Accepted as recommended:
  - **Closed, built or replaced:** E3 (built in phase 3b-2, phase-3-design.md §13); P5 (replaced by D-020's 7d and D-024's 7d-2 and 7d-3; a fully offline app is not planned and is reopened only if pilot gate testing shows a need).
  - **Deferred with a trigger:** E2 folds into D-014. When scanning is switched on, the scanner runs on AWS Fargate London as designed in D-013.
  - **Built:** P4, a read-only venue set-up page. Each item's state is computed from the records ("Not set up", "Draft awaiting approval", "In force from [date]"), with its owner and a link to the screen that sets it. Nothing can be ticked by hand, and there is no percentage or progress bar. It supports Q20–Q22 and is the go-live checklist that 6d-1 refers to.
  - **Outside the build:** G10, which the founders settle in writing before the pilot, recording the outcome here. P7 is reframed as a pilot rehearsal with venue staff: the Q22 set-up workshop followed by Q231's five scenarios, with the set-up page as the agenda. It depends on P7-14 and P8-16.
- 6c-1, P7-14, P8-16, E1, N1, N2, G10 and G11 remain open.
- **As built (P4):**
  - Migration `20261025000065_venue_setup` adds `api.venue_setup(venue)`. It is read-only (stable) and readable by the venue's tenant administrators and anyone holding a current appointment there. Platform administrators, contractors and other customers get `not_found`.
  - Items:
    - **Authority:** root appointment (every root in force is listed, and an unfinished ceremony says who must act next), appointment types.
    - **Places and systems:** areas, building systems.
    - **Work and permits:** working calendar, work types, activity screening, the Work Approval and each permit class (deferred specialist classes are excluded), isolation and impairment rules for each system type with registered systems, emergency work categories, emergency contacts.
    - **Inductions:** each course.
    - **Gate and visits:** entry rules, gate points, outage procedure, access visit purposes.
    - **Notices and records:** reminders and escalation, retention schedule.
  - States are words: Not set up, Draft (not yet proposed), Awaiting approval, Published (not yet in force), In force, Recorded. A newer draft or proposal beside a version in force is shown as pending.
  - "Appointed for this" names come from `core.action_holders` with a venue-wide target, so an appointee scoped to one hall is not named.
  - Page: `/venue/setup`, linked from Venue administration. It shows "Still to do" first, then each section. On a phone each row becomes labelled blocks.
  - Proof: pgTAP `44_venue_setup` (79 assertions); 10 of 10 deliberate weakenings caught; browser check as the demo venue administrator, desktop and 375 px.
  - **Found while building:** the root appointment, ordinary appointments, delegations, areas, area kinds, system types, systems, system ownership, events, document types, review criteria and evidence requirements have an API but no screen; only the seed script has created them. The set-up page says "No screen yet" for these instead of linking nowhere.


## D-026 — Venue set-up screens design approved (S1)
- **Date:** 28 October 2026 · **Decided by:** Wes Pierce
- [set-up-screens-design.md](set-up-screens-design.md) approved with S1-1 to S1-10, as recommended:
  - Split into S1a (people and authority), S1b (places and systems) and S1c (events and evidence settings).
  - A `staff` invitation kind, so a tenant administrator can give venue staff a login without the platform operator.
  - Revoking a tenant administrator, keeping at least one per customer and never revoking oneself.
  - The letter of appointment is held as a reference to where the signed letter is kept, for the pilot; revisit with G11.
  - A fixed acknowledgement declaration for the pilot: "I have read the scope and limitations of this appointment and accept it. I will act only within them."
  - Non-root appointments made on screen need an end date.
  - Delegations are part of S1a.
  - Retiring an area is refused while anything listed in §6 depends on it.
  - Retiring a system and ending an ownership record are added, with the same kind of checks.
  - Evidence requirements join the venue set-up page once S1c is built.
- **D-002 wording corrected (S1-4):** the root appointment is "backed by a reference to the signed letter of appointment", not an uploaded file.
- **As built (S1a):** see set-up-screens-design.md §13. Migration `20261025000066`, screens `/venue/authority`, `/me` (Your appointments) and `/appointments/[id]`; pgTAP `45_people_and_authority`.
- **As built (S1b):** see set-up-screens-design.md §14. Migration `20261025000067`, screen `/venue/places`, gate point retirement on `/venue/entry`; pgTAP `46_places_and_systems`. The retirement checks are slightly stricter than §6 and §7 listed (any appointment or delegation scope naming the area, as 0008 already refused; access visits, restriction windows and keys or passes also block); these are listed in §14 for confirmation.
- **As built (S1c):** see set-up-screens-design.md §15. Migration `20261025000068`, screens `/venue/events` and `/venue/evidence` (competency types moved there from `/venue`); pgTAP `47_events_and_evidence`. Adds checks the design assumed but nothing enforced: a phase within its event's dates, events and phases with some length, distinct review criteria codes. Evidence requirements appear on the set-up page with a new "None defined" state (S1-10).
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
| G10 | Product owner versus both founders. | Settle in writing between founders before the pilot (D-025). | Q235 raises the same point. |
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
| P7 (reframed by D-025) | Venue staff have not yet used the product. | Pilot rehearsal: the Q22 set-up workshop, then Q231's five scenarios, with the venue set-up page as the agenda. Needs P7-14 and P8-16. |
| N1 | **Lifting and rigging are deferred, but rigging over halls is routine at exhibition venues.** | Confirm the pilot estate's routine rigging volume. Q232's own risk note says that if a deferred control is routine for the first estate, validate it before launch or narrow the pilot. Q167–168 and Q183–184 overlap with event builds. |
| N2 | Answers relying on earlier Olympia/OES material. | Obtain the controlled source set listed in Q234 before configuring notice periods (Q84–90), urgent work (Q92, Q97) and review (Q17, Q70). |
