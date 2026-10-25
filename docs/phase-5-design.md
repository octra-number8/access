# Build phase 5 — permits: design for approval

**Status:** Approved 25 October 2026 (D-018). Decisions are in §13.
Builds on phases 1–4: appointments and the authorisation service, organisations, evidence, inductions, and routed work packages.

Source questions: Q61–Q68 (request and evidence), Q69–Q75 (review and information requests), Q76–Q83 (approval routes), Q84–Q90 (notice and calendars), Q91–Q97 (urgent and late work), Q98–Q104 (issue and acceptance). Most are **Requires specialist validation**. This phase builds the machinery and the approval route for each piece of content. It never decides the content itself: notice periods, cut-off times, which approvals a class needs, and what the acceptance declaration says. Notice periods also depend on the Olympia/OES source set (**N2**), which is still needed.

---

## 1. What phase 5 delivers

A routed job becomes a **Work Approval** with a linked permit for each required class. The applicant completes each permit's class-specific questions and evidence, names the supervisor and team, and submits with a declaration. The venue's appointed reviewers decide each step of the class's approval route, in parallel or in sequence. They can ask for more information, and the applicant resubmits a new version. When every step is decided, the permit is **Approved for issue**. On the day, an appointed issuer runs the pre-issue checks and **issues** it. The issue snapshot is frozen. The named supervisor **accepts** it at the workface after briefing the team, and only then is it **Active**.

Late notice and clashes with event or area restrictions go through a recorded decision, which can be a refusal.

What it does **not** do:
- Live changes, suspension, extension, worker swaps, isolations, impairments, fire watch, hand-back and closure (phase 6).
- Entry at the gate (phase 7): an active permit is not permission to enter, and entry is not permission to work.
- Notifications and reminders (phase 8): overdue items are shown on screen with their owner; nothing is sent and time never settles anything (invariant 10).

Proposed split **[P5-1]**:
- **5a:** permit records and versions, class configuration, approval routes, information requests.
- **5b:** calendars, notice, exceptions, team, issue, acceptance.
- **5c:** screens.

Each part is tested and committed on its own.

## 2. The permit model (CLAUDE.md §3, §4, Q57)

| Table | Holds |
|---|---|
| `permit` | Work package, kind (`work_approval` or `child`), permit class, parent (for a child), status, current version, issue snapshot, `row_version`. |
| `permit_version` | **Immutable.** The job revision it is for; the class version it was prepared under; answers to the class's questions; the time window; supervisor and team; cited document versions; the declaration and who made it; submitted at. A resubmission or change is a new version. |
| `permit_team_member` | Version × person × role (`supervisor`, `operative`). |
| `issue_snapshot` | **Immutable** (invariant 5). It freezes the permit version, the class version, every step decision and condition, the team, the evidence and inductions relied on, the calendar and notice rule in force, the issuer and their appointment, plus a SHA-256 over all of it. |

- **One Work Approval per job [P5-2].** When a routed job needs at least one permit, it gets one Work Approval: the parent record for the job's overall scope, method and dates. Each required class becomes a child permit linked to it. A job routed as "no permit required" gets none.
- **States (§4):** Draft → Submitted → Under review → (More information required → Under review) → Approved for issue → Issued awaiting acceptance → Active, with side states Cancelled, Expired and **Refused [P5-3]**. Suspended, Hand-back pending and Closed arrive in phase 6.
  - *Submitted*: the declaration is made and the approval route is set up.
  - *Under review*: a reviewer has started on it.
  - All transitions go through `core.transition()` only.
- **Parent and child rules (invariant 4) [P5-4]**, enforced by a trigger:
  - a parent cannot be approved for issue while a required child is Refused, Cancelled or Expired;
  - a parent cannot be issued until every required child is at least Approved for issue;
  - a child cannot be issued unless its parent is issued;
  - a child that becomes Refused, Cancelled or Expired stops the parent moving forward.

  Phase 6 adds suspension of an active parent.
- **When the job changes (invariant 6):** a material revision of the job returns it to draft (as built in phase 4). Every permit for it that is not yet issued goes back to Draft, and its next version needs the full route again. Issued and active permits are phase 6, where they suspend.

## 3. Permit class configuration (Q61–Q64, Q68, Q101)

Each class (and the Work Approval) has a **class version**: venue configuration with an owner and an effective date, approved by the technical authority as screening versions are (D-017 pattern). **A class cannot be used until it has an approved version [P5-5].**

A class version holds:

| Part | What it is | Default |
|---|---|---|
| Request questions | Class-specific questions, revealed by earlier answers (Q63); same content format as screening | None |
| Required evidence | Document types and verified competencies, for the organisation, the supervisor or every team member; **induction courses** completed and valid for the window (Q99) | None |
| Approval route | The steps (§4) | None: an empty route is not allowed |
| Notice rule | §6 | None: must be set, even if zero |
| Submission declaration (Q68) and acceptance declaration (Q101) | Wording for this class | None |
| Requires physical controls | Isolation, impairment or fire watch: a class with this cannot be issued until phase 6 records those controls **[P5-11]** | Must be chosen |
| Override prohibited (Q93) | Late-notice exceptions are not allowed for this class | Must be chosen |

Evidence requirements reuse phase 2's `evidence_requirement`, extended to apply to a permit class and to require an induction course. Expiry is judged against the permit's own window (Q39). There is still no person-level status.

## 4. Approval routes (Q76–Q83)

| Table | Holds |
|---|---|
| `approval_step` (in the class version) | Key, name, kind (`review`, `occupier`, `landlord_operator`, `external`), order group (the same group runs in parallel; groups run in sequence), when it applies (always; when the job has an affected-occupier or landlord party; when the job touches a system of a given type), and the authority it needs. |
| `permit_step` | Permit version × step: state `waiting` (an earlier group is not done) → `open` → `decided`. The decision is one of: `no_further_comments`, `conditions`, `more_information`, `refused` or `not_applicable`. It records the decider, acting capacity, reason and scope wording (Q72: never "approved" as a bare word). |
| `permit_condition` | Step × condition text, and whether it must be acknowledged at acceptance. Conditions carry into the issue snapshot. |
| `external_decision` | For `external` steps (Q82): the external decision-maker and organisation, reference, scope, date, conditions and correspondence, recorded separately from the person who entered it. |

- **Who decides a step:** a person holding a current appointment for that step's action. It must cover the permit class and **every area and system of the job**, using the phase 4 scope rule. The applicant, the submitter and anyone connected with the job are excluded (invariant 3).
- **Occupiers and landlords:** decided by people the venue has appointed for that demise or system. Authority still comes from an appointment, never from being "the occupier" (invariant 1). This needs a venue-maintained **area occupation register**: area, occupying organisation and dates. The system-ownership register already exists (phase 1). The venue, not the contractor, names occupier and landlord parties on a job, which settles **P4-9** **[P5-6]**.
- **Not applicable (Q81):** only someone appointed for that step, with a reason. Never the applicant, and never an administrator.
- **Conditions added later (Q80):** a condition added after other steps are decided is shown to those deciders. Their decisions stand unless a decider reopens their own step.
- **Withdrawal (Q83):** before issue, a decider can reopen their own decided step with a reason. The permit returns to Under review and cannot be issued.
- **Refusal:** a `refused` step refuses the permit. A required child that is refused blocks the parent (§2).

## 5. Information requests and resubmission (Q69–Q75)

| Table | Holds |
|---|---|
| `rfi` | Permit version, step, raised by, items (each linked to a question, a document version or the job), and one consolidated message (Q70). |
| `rfi_response` | The applicant's answer to each item. Replacement documents are new versions (Q71, Q74). |

- Asking for information moves the permit to More information required. The applicant answers and **resubmits a new version** with a fresh declaration.
- **Every step re-confirms on a new version [P5-7].** Each reviewer sees what changed: their earlier decision, the item, the response and the new version side by side (Q71). They can confirm their previous decision in one step. Nothing carries over silently.
- **Reviewer corrections (Q73):** a reviewer may correct only administrative facts (the same fields as phase 4's administrative change), with a reason and a visible before-and-after record.
- **Reminders (Q75):** none in phase 5. Each open request shows how long it has waited and who owns it (CLAUDE.md §6).

## 6. Calendars, notice and late work (Q84–Q97, scenario 4)

| Table | Holds |
|---|---|
| `venue_calendar` | Venue configuration with an owner and an effective date: working days, closure dates and the cut-off time, in the venue's time zone (Q85, Q86). **No default calendar**: until one is approved, no notice can be measured, so no permit can be submitted. |
| Notice rule (in the class version) | Amount and unit (`working_days`, `calendar_days` or `hours`), whether the cut-off applies, whether a material resubmission restarts it (Q88), and any longer notice for particular areas, systems or event phases (Q89). |
| `restriction_window` | Venue configuration: areas, a time window (or an event phase), and an effect (`no_work` or `decision_required`), with an owner. This is where event build, live and breakdown clashes are recorded. |
| `exception_decision` | **Immutable.** Permit version, kind (`late_notice` or `restriction_conflict`), the applicant's reason and the consequence of delay (Q94), outcome (`allowed` with reduced scope and conditions, or `refused`), decider and reason. |

- **Earliest compliant start (Q87)** is calculated on the server, from the calendar and the notice rule, and shown before submission.
- **Late or clashing requests (Q90):** they can be submitted, but they are marked as late or clashing, and normal issue is blocked until an appointed authority records an exception decision. A refusal leaves the permit unissuable; the applicant changes the dates or the job. Where a class prohibits overrides (Q93), no exception can be recorded at all.
- **The flag stays visible (Q95):** the exception label, its reason and the decider are carried on the permit and in the issue snapshot, and later at the gate.
- **Emergency and urgent make-safe work (Q91, Q92, Q94, Q97) moves to phase 6 [P5-9].** That work usually starts before the paperwork and needs live controls and a retrospective permit. This phase covers planned late notice and restriction clashes only.

## 7. Issue (Q98, Q99, Q102)

- **Who issues:** someone with a current appointment for `permit.issue` that covers the class and every area and system of the job. Invariant 2 already requires issuing to be a different appointment from reviewing. **In addition, the issuer must not be anyone who decided a step on that version, nor the applicant or submitter [P5-10].**
- **When:** not before the start of the first day of the permit's window, in venue local time [P5-10]. Before that the permit stays Approved for issue (Q102).
- **Pre-issue checks (Q99)**, run by the database at the moment of issue. Each failure is listed with who can resolve it.
  - **The request itself:**
    - the version is current;
    - every applicable step is decided without refusal, with no open information request;
    - notice is met, or an exception allows it;
    - the window is not in a `no_work` restriction;
    - the parent and child rules are met.
  - **The people:**
    - the issuer's own appointment covers the decision;
    - a supervisor is named;
    - every team member works for the performing organisation;
    - every team member has the class's required inductions valid for the window, and its verified competencies;
    - no team member is restricted.
  - **The organisation:**
    - its evidence lines for the window are met;
    - its engagement is active and it is not restricted.
  - **Controls:** the class does not require physical controls that phase 6 has not yet recorded.
- **What issuing does:** it freezes the issue snapshot and moves the permit to Issued awaiting acceptance. It is idempotent. A repeated issue request replays the original decision.

## 8. Acceptance at the workface (Q100, Q101, Q103, Q104)

- **Who accepts:** only the supervisor named on the issued version, signed in as themselves. This is a `subject`-basis action, so an administrator cannot accept on their behalf.
- **What they record:**
  - the class's acceptance declaration;
  - acknowledgement of each condition that requires it;
  - a **workface briefing record**: who was briefed from the team, and when.

  Acceptance then makes the permit **Active**.
- **Online only (invariant 11):** acceptance uses current data at that moment, never a cached copy.
- **What Active means:** the defined work may proceed under the stated conditions. Nothing more, and only while every dependency holds (§2).
- **Expiry:** when the window ends, an active or issued permit becomes **Expired**. This is done by an idempotent, re-runnable service job. Expiry only ever removes authority; it never grants it (invariant 10).

## 9. Authority and actions (summary)

| Action | Basis | Notes |
|---|---|---|
| Class configuration: draft, propose | tenant admin | As with screening |
| Class configuration: approve, reject | appointment | Technical authority; the proposer is excluded |
| Calendars, restriction windows, area occupation | tenant admin, versioned with an owner | Their content belongs to the venue (Q86) |
| `permit.prepare` / `submit` / `respond` / `cancel` | organisation admin of the performing organisation, or the venue's `_for_venue` forms | The submission declaration is made by a named authorised representative (Q68) |
| `permit_step.decide` / `not_applicable` / `reopen` | appointment, scoped to the class and every area and system | Everyone connected with the job is excluded |
| `permit.exception_decide` | appointment | Late notice and restriction clashes, including refusal |
| `permit.issue` | appointment | Four-eyes rule, §7 |
| `permit.accept` | subject (the named supervisor) | |
| `permit.expire` | service | Background job |
| `work_package.require_class` | appointment | **P4-10:** an authority adds a class that screening missed, with a reason; this creates the permit draft **[P5-12]** |

Platform and tenant administrators can take none of the appointment or subject actions (invariant 9). The super-admin negative tests extend to step decisions, exceptions, issue and acceptance.

## 10. Screens (5c)

- **Contractor:**
  - the permit list grouped under the job, each with its next action, owner and deadline;
  - class questions, one per screen on a phone;
  - an evidence checklist grouped as missing, expiring within the window, awaiting review, or not applicable (Q67);
  - team selection with each person's readiness for this class;
  - responding to information requests;
  - submit with the declaration.
- **Reviewer, desktop:** a dense queue of open steps by deadline. Each step shows the permit, the job, the class's questions and answers, the evidence, and earlier decisions and changes side by side. It offers: decide, ask for information, conditions, not applicable, reopen.
- **Issuer:** a readiness panel listing every pre-issue check, each with its owner when it fails, and Issue.
- **Supervisor, phone (Q104):** the issued permit showing:
  - its exact scope and limits, location, window and time left;
  - the team, the conditions and the linked permits' state;
  - the emergency and stop-work contact;
  - the declaration and the briefing record;
  - Accept.
- **Venue:** class configuration authoring and preview, calendars, notice rules, restriction windows and area occupation.

## 11. What phase 5 leaves for phase 6

Suspension and resumption; extension; adding, swapping or excluding workers; isolations, impairments and fire watch, which also lifts the issue block for classes that need them; emergency and urgent make-safe work; hand-back, including partial hand-back; closure; and suspension of active permits when the job or a child permit changes.

## 12. Proof

- **pgTAP, positive:** a Work Approval with a linked work-at-height permit goes from draft, through a two-group route with one information request and a resubmission, to approved, issued with the full snapshot, accepted and active (pilot scenario 2, without physical controls). A late request is allowed by exception, and another is refused (scenario 4).
- **pgTAP, negative:**
  - step decided by the applicant or anyone connected with the job;
  - an appointee whose scope does not cover every area, or not the class;
  - a tenant or platform administrator deciding, issuing or accepting;
  - issue by anyone who decided a step on that version;
  - issue before the window, without notice or an exception, with an open information request, or with a refused or unapproved required child;
  - a child issued before its parent;
  - a team member without the required induction, or restricted;
  - a class that needs physical controls;
  - acceptance by anyone but the named supervisor;
  - issue snapshot or permit versions edited;
  - a repeated issue or acceptance request (idempotency);
  - a concurrent edit (version conflict);
  - a material job change after approval;
  - cross-tenant and cross-venue reads and writes on every new table;
  - expiry run twice.
- **Mutation testing** of the dependency trigger, the pre-issue checks, the four-eyes rule, the notice calculation and the scope rule.
- **End-to-end and browser (5c):** scenarios 2, 3 and 4 by the contractor, reviewers, issuer and supervisor, the supervisor at 360 px.

## 13. Decisions needed

| Ref | Decision | Recommendation |
|---|---|---|
| P5-1 | Split into 5a (permits, class configuration, routes, information requests), 5b (calendars, notice, exceptions, team, issue, acceptance) and 5c (screens)? | **Yes.** Phase 5 is about three times phase 4; each part is tested and committed on its own. |
| P5-2 | One Work Approval per job that needs any permit, with each required class as a linked child permit? | **Yes**, as CLAUDE.md §3 describes. Its own route covers the overall scope, method and dates. |
| P5-3 | Add **Refused** as a side state of the permit model? | **Yes.** It changes CLAUDE.md §4, wording: "Side states: `Suspended` …, `Cancelled`, `Expired`, `Refused` (an approval step refused the request)". Recording a refusal as Cancelled would hide who refused it and why. |
| P5-4 | The parent and child rules in §2? | **Yes.** They are the database form of invariant 4. |
| P5-5 | Each class (and the Work Approval) needs an approved, versioned configuration before it can be used: questions, evidence, route, notice, declarations, flags, with no defaults? | **Yes**, approved by the technical authority, as with screening. Starter content may be offered as a draft later, as with P4-2. |
| P5-6 | Occupier and landlord approval through venue appointments scoped to the demise or system; a venue-maintained area occupation register; occupier and landlord parties named by the venue, not the contractor (settles P4-9)? | **Yes.** Authority stays with appointments (invariant 1), and contractors never see a list of the venue's organisations. |
| P5-7 | On a resubmitted version, every step re-confirms, with the earlier decision and the changes shown and one-step confirmation? | **Yes.** Nothing carries over silently. Q74 retention is met by keeping every version. |
| P5-8 | Calendars, notice rules and restriction windows are configuration with no defaults; no permit can be submitted until the venue has an approved calendar and the class has a notice rule (zero is allowed, but only if chosen)? | **Yes** (CLAUDE.md §9). The actual numbers wait for the Olympia/OES source and the technical authority (N2). |
| P5-9 | Phase 5 handles late notice and restriction clashes, including refusal; emergency and urgent make-safe work moves to phase 6? | **Yes.** Emergency work needs live controls and a retrospective permit, which arrive in phase 6. |
| P5-10 | The issuer cannot be anyone who decided a step on that version, nor the applicant or submitter; and issue is not before the start of the window's first day? | **Yes.** It is a four-eyes check on top of invariant 2, and it keeps "approved in advance, issued on the day" (Q102). A small venue with one authorised person would need a second; say if that is a problem for the pilot. |
| P5-11 | Classes configured as needing physical controls (isolation, impairment, fire watch) cannot be issued until phase 6 records those controls? | **Yes.** Otherwise "Active" could exist without its controls (launch gate). In phase 5, pilot scenario 2 uses a class without physical controls, such as work at height. |
| P5-12 | P4-10: an appointed authority can add a class that screening missed to a routed job, with a reason? | **Yes.** It creates the child permit draft and is recorded against the authority. |

**Open items this phase depends on:**
- **N2:** the Olympia/OES source, needed before notice periods, cut-off times and urgent-work arrangements are configured.
- **N1:** routine rigging at the pilot estate.
- The class content itself (questions, evidence, routes, declarations): Q61–Q104 marked "Requires specialist validation" are for the technical authority.
- **G11:** privacy wording, for the team's personal data shown to reviewers.

---

## 14. As built (phase 5a, 25 October 2026)

Implemented in `supabase/migrations/20261025000031…33`; proved by pgTAP `26_permit_config` and `27_permit_review` (724 assertions in the whole suite) and by mutation testing: ten deliberate weakenings were each caught, after two tests were added for weakenings the first run let through. No screens yet (5c); issue and acceptance are 5b.

| Area | As built | Note |
|---|---|---|
| Class configuration | One validated document per class version: questions (screening format), route, submission and acceptance declarations, and the two flags. Approved by an appointee whose appointment covers that class across the venue; the author and proposer are excluded; approval supersedes the previous version. | Notice rules and evidence requirements join the configuration in 5b. |
| Work Approval | A permit class with `handling = 'work_approval'`, one per venue. | Configured and approved like any class. |
| Starting permits | Explicit (`api.start_permits`), not automatic on routing. It creates the Work Approval and one child per required class, and cancels children whose class the job no longer needs. Refused, naming the classes, while any lacks an approved configuration. | Starting again after a change reconciles rather than duplicates. |
| Required classes | Accepted or upheld recommendations on the screened revision, plus classes an authority required (`class_requirement`, P5-12). | If permits are already started, a required class's draft joins them at once. |
| Versions | The editable draft (`permit_draft`) becomes an immutable `permit_version` on submission and on each response to an information request, with the declaration and its hash. | |
| Steps | Instantiated per version from the route. Review and external steps cover every area and system of the job and need the class. Occupier and landlord steps are one per party of that role: an occupier step is scoped to the areas the register says that party occupies (else the whole job), and does not need the class. | Proved: the occupier's representative for Hall 2 decides an occupier step on a job in Halls 1 and 2. |
| Decisions | Every decision is an immutable `step_decision`; the latest one on each step counts. The permit's state is derived from them (`core.settle_permit`), never set directly. One decision at a time per permit (row lock). | Withdrawal (Q83) is a `reopened` decision by the original decider only. |
| Information requests | Asking for information blocks every other step until the applicant responds; the response is a new version on which every step decides again (P5-7), and the earlier version keeps its decisions. | |
| Work Approval dependency (P5-4) | `core.wa_children_ready`, used by both the state derivation and a trigger: a Work Approval cannot be approved for issue while a required class has no live child, or its child is refused or expired. A child being refused later takes an approved Work Approval back to review. A child still being prepared does not block approval; it blocks issue (5b). | |
| Material change | A material change to the job returns every permit not yet issued to draft; earlier versions and decisions stay unchanged. | |
| Visibility | Permit deciders can see jobs and permits at their venue. The area occupation register is visible to venue administrators and appointees only, never to contractors. | |

Test environment note: two other projects' local Supabase stacks were running on the same machine during this build, and the CLI's database connection and the auth service timed out intermittently. The suite was run through the standalone harness (`scripts/db-test.sh`) while that lasted; once it cleared, the CLI runner and the end-to-end tests passed too.
