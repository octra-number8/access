# CLAUDE.md — Octra Access

Operating instructions for Claude Code in this repository. Read this fully before any
substantial change. Where this file and a request conflict, raise the conflict rather
than silently resolving it.

---

## 1. What this product is

Octra Access is a multi-tenant contractor management, induction, access and
permit-to-work platform for operationally complex estates. The first release targets a
single UK exhibition/event estate with landlord, occupier, event, public-space and
technical interfaces.

The product controls and evidences **three separate decisions**:

1. **Permission to enter** — may this person be in this place, at this time.
2. **Permission to work** — may this defined task proceed, under whose authority, on
   what conditions.
3. **Technical readiness** — have the required isolations, impairments and physical
   controls actually been applied and verified by a competent person.

These are never collapsed into a single status, a single screen, or a single boolean.

- An inducted person is not automatically admitted.
- An admitted person is not automatically authorised to work.
- An approved document is not an applied isolation.
- A technically reviewed application is not an issued permit.

Octra does not certify competence, approve engineering design, guarantee compliance or
replace supervision. Interface wording, exports and marketing copy must never imply
otherwise.

No venue-specific operating arrangement is hard-coded. Everything that varies by estate
is configuration with an owner, a version and an effective date.

---

## 2. Non-negotiable safety invariants

Enforce every one of these in the database and on the server. A disabled button is
never the control.

1. **Authority comes from a current appointment**, scoped by person x venue x permit
   class x area/asset x validity window. Never from job title, role name, org chart
   position or platform administration rights.
2. **Document review and permit issue are separate decisions** requiring separate
   appointments.
3. **No self-approval.** The person who submitted, declared or authored a record cannot
   review, approve, issue or accept that same record.
4. **A required child permit that is rejected, expired or suspended blocks its dependent
   work.** Enforced by database constraint or trigger, not by application convenience.
5. **Issued evidence is immutable.** Changes create a new version. The issue snapshot
   retains the scope, evidence versions, approvals and the policy/template revision in
   force at that moment.
6. **Material change invalidates dependent authorisation.** Changes to scope, method,
   responsible organisation, area, timing, critical personnel or risk require a new
   version and re-review of affected approvals; live work suspends where the existing
   authorisation no longer applies.
7. **Suspension lifts only through the authority that owns the restricted control**, or
   a formally delegated equivalent holding its own valid appointment.
8. **Hand-back cannot close** while isolations, impairments, fire watches, key/pass
   custody or incomplete work remain unresolved. A continuing isolation must transfer to
   a separately owned live isolation record; it must not disappear because a work area
   was returned.
9. **Platform and tenant administration grant no operational authority.** There must be
   a passing test proving a super-admin cannot issue a permit, approve a step, lift a
   suspension or close a job with open controls.
10. **Time passing never creates approval.** Escalation and reminders preserve the
    unresolved state.
11. **Offline/cached status is never current authorisation.** No new work start, issue,
    acceptance or eligibility change may rely on cached data.

Never render a colour, score or percentage that implies work is safe or legally
compliant. Colour may signal a recorded decision state only as a secondary cue to text.
Gate outcomes are words ("Admit", "Check with [owner]", "Do not admit"); permit statuses
use neutral styling. A status means a decision was recorded, nothing more.

---

## 3. Domain model

Model this in full before building screens. Migrate it phase by phase: each build phase
adds only its own tables, with their RPCs and tests.

**Tenancy and place**
`customer` -> `venue` -> `area` (self-referencing hierarchy: zones, demises, plant
areas, roofs, assets), `system_ownership` register, `venue_calendar` (working days,
closures, cut-off time), `event` and `event_phase` (build / live / breakdown).

**Parties**
`organisation` (single identity) -> `engagement` (organisation x venue, time-bounded,
with capacity: occupier, performing contractor, principal contractor, service provider,
promoter, exhibitor). `person`; `person_organisation_relationship` (employee, agency,
self-employed, volunteer, subcontractor, exhibitor). Supervision and evidence
responsibility recorded explicitly.

**Authority**
`appointment` — appointing authority, appointee, venue, permit classes, area/asset
scope, limitations, competence evidence reference, effective and review dates.
`delegation` — delegator, delegate, permitted actions, scope, start and end.
`acting_capacity` — the capacity a user explicitly selected for a consequential action,
recorded on the resulting decision.

**Evidence**
`document` (organisation / person / job scope), `document_version`,
`review_decision` (reviewer, declared criteria, outcome, conditions, scope wording).
`competency` and `competency_verification` (method, source checked, holder match,
scope, validity) as a separate act from document receipt.

**Induction**
`induction_course` -> `course_version` -> `module`, `question_bank`,
`induction_completion` (person, venue, course version, language, method, facilitator
where assisted, understanding check, result).

**Work**
`work_package` -> one main `work_approval` + linked `child_permit` records.
`permit_class` configuration, `activity_screening_rule`, `screening_response`,
`no_permit_required_decision`.
`approval_route`, `approval_step`, `rfi` (information request), `comment`,
`condition`.

**Controls**
`isolation` (request, authorise, apply, prove, remove; lock/key references;
test-for-dead or zero-energy evidence), `impairment` (system, zones, compensatory
measures, maximum approved duration, reinstatement test and witness), `fire_watch`
(during and post-work, named watcher, actual times, findings), `exclusion_zone`,
`custody_item` (keys, passes, badges).

**Access**
`access_authorisation` (visit or visit series, named roster, purpose, area, validity,
escort, photography and confidentiality conditions), `visit_attendance`.
An access authorisation never converts into a work permit. A linked work request may be
raised from it, carrying verified organisation, location and visit information only.

**Gate**
`entry_eligibility_evaluation` (result, reason, action, owner), `scan_event`,
`offline_manifest`, `manual_fallback_entry`, `reconciliation_exception`.

**Evidence and accountability**
`audit_event` (actor, acting capacity, action, target, timestamp, reason where
required) — append-only. `issue_snapshot`. `legal_hold`. `retention_rule` with
category-specific triggers. `export` with scope, omissions and redactions recorded.

---

## 4. Permit state model

`Draft` -> `Submitted` -> `Under review` -> (`More information required` -> back to
`Under review`) -> `Approved for issue` -> `Issued awaiting acceptance` -> `Active` ->
`Hand-back pending` -> `Closed`.

Side states: `Suspended` (from `Active`, returns to `Active` only through the
responsible authority with renewed readiness checks), `Cancelled`, `Expired`.
`Abandoned` is a management flag on a suspended or expired job — never a closure and
never permission to remove controls.

Only `Active`, with every required dependency satisfied and required physical controls
confirmed, means the defined work may proceed.

Transitions are enforced by a database state table plus trigger. Status changes only
through `core.transition()`, which requires a valid decision context; any other write to
a status column fails.

---

## 5. Technical architecture

- TypeScript throughout. Next.js App Router. Supabase/PostgreSQL. Supabase Auth with
  Row Level Security. Vercel deployment.
- Migrations are version-controlled and forward-only, each with a stated rollback or
  recovery plan. No schema changes made through a console.
- **One server-side authorisation service.** Every consequential action resolves the
  actor's current appointments, active capacity, venue and area scope through this
  single implementation. Permission logic is never duplicated in a component, a route
  handler or a policy comment. This service is implemented in Postgres (`authz.*`); the
  TypeScript layer wraps it and never re-derives a permission.
- RLS enabled on every table from the first migration. Cross-tenant and cross-venue
  denial tests are part of the definition of done, not a later audit.
- Documents live in private storage. Access only via short-lived signed URLs issued
  after an object-level authorisation check. All uploads are untrusted input: validate
  type, scan where available, never serve inline from a trusted origin.
- Idempotency keys on issue, acceptance, suspension, resumption, extension, worker
  change and hand-back. Optimistic concurrency (version column) on permits, isolations
  and impairments.
- Validation defined once and shared across client, server and database constraints.
- Background jobs (expiry evaluation, reminders, escalation, retention) must be
  idempotent, observable and safe to re-run.
- Never expose service-role credentials, secrets or private records through client
  code, logs or error responses. A development bypass is never a production
  implementation.

---

## 6. UX requirements

- Mobile-first for operatives (induction), supervisors (live permit, acceptance,
  hand-back) and gate staff. Dense, fast, keyboard-navigable desktop for reviewers,
  issuers and administrators.
- Plain-English statuses. Restrained, consistent visual system. No decorative gradients,
  sparkles or generic AI iconography.
- Every blocked action states: what is unavailable, why in plain language, what is
  missing, and who can resolve it — without disclosing another person's confidential or
  sensitive records.
- Dashboards show actions, owners and deadlines, not headline counts.
- Live permit view for a supervisor shows, at a glance: active or stop-work status,
  exact scope and limits, location, remaining time, team, current conditions, required
  child permits and their readiness, emergency contacts and outstanding hand-back
  duties.
- Gate view shows the minimum needed to act. RAMS detail, identity documents, private
  contact details and medical information are never shown at the gate.
- WCAG 2.1 AA: contrast, keyboard navigation, screen-reader support, captions and text
  alternatives for induction content.

---

## 7. Build sequence

1. **Foundations** — tenancy, areas, identity, appointments, authorisation service,
   audit, RLS, migration pipeline. Prove with negative tests before any UI.
2. **Organisations and people** — invitation, engagement, accountable administrators,
   documents, verification. Expiry evaluated against actual planned work, area and
   appointment; never a blanket red person status for an unrelated certificate.
3. **Inductions** — mobile delivery, versioning, assessment, assisted and facilitated
   completion, completion records.
4. **Work packages and activity screening** — transparent rule-based screening (no AI
   classifier), contractor challenge route, "no permit required" decision recorded with
   named authority and reason.
5. **Permits** — Work Approval plus children, parallel and sequential approval routes,
   RFI and resubmission, notice-period and working-calendar logic, issue, workface
   acceptance.
6. **Live controls** — suspension, extension, worker add/swap/exclude, isolations,
   impairments, fire watch, revalidation, hand-back (including partial), closure.
7. **Gate** — entry eligibility, scanning, amber/red reasons with owner, overrides
   restricted to an appointed access authority, offline degraded mode with persistent
   "OFFLINE — status last updated [time]" banner and manual fallback log.
8. **Evidence and oversight** — frozen permit packs, exports with redaction,
   dashboards, notifications with a mandatory critical class, retention and legal holds.

**Launch permit classes (proposed — do not treat as confirmed):** Work Approval,
Access, Hot Works, Work at Height/Roof, Electrical and Mechanical Isolation,
Life-Safety Impairment.

**Deferred:** confined space entry, complex lifting and rigging, excavation and
penetration, and all rare specialist classes (radiation, lasers, explosives, diving).
Route these through a controlled external-reference record that holds the job until a
competent venue authority accepts the evidence. Never present a generic "other
specialist work" tickbox.

---

## 8. Testing

A feature is complete when it works from the user's first action through to its
operational outcome, positive and negative. Not when it compiles or renders.

Required end-to-end scenarios:

1. Invite contractor or event worker, complete induction, verify entry eligibility.
2. Work Approval with a linked specialist permit: review, issue, workface acceptance.
3. Incomplete evidence returned, corrected resubmission, renewed approvals.
4. Event conflict or late-notice request through a controlled decision, **including a
   refusal**.
5. Live suspension or worker change, continuing controls, hand-back, evidence export.
6. Outage exercise through the gate manual fallback and post-reconnection
   reconciliation.

Q231 defines five pilot workflows with the outage fallback exercised within them;
scenario 6 above is that exercise made explicit. The launch gate's "five pilot
scenarios" refers to Q231's five.

Required negative suite (minimum):

- Expired or out-of-scope appointment attempting issue.
- Self-approval attempt.
- Cross-tenant and cross-venue read and write.
- Rejected or suspended child permit blocking the parent.
- Super-admin attempting issue, approval, suspension lift and closure.
- Closure attempted with an open isolation, impairment or fire watch.
- Repeated submission of the same issue/acceptance request (idempotency).
- Concurrent edit of a live permit.
- Material change after authorisation.
- Suspension occurring after the last device sync.

Where a testing tool or environment is unavailable, state the limitation. Never
fabricate test results or deployment outcomes.

---

## 9. Requirements discipline

The source requirements document is the 238-question review dated 21 October 2026. It
mixes confirmed direction, recommendations, research findings and matters needing
specialist approval. **Nothing in it is approved by default.**

Maintain `/docs/requirements-register.md`, keyed to question numbers Q1–Q238, with one
of: **Confirmed / Proposed / Requires specialist validation / Deferred / Implemented**.

Never promote a proposed default into enforced logic. Specifically, these are venue
configuration with no silent default: notice periods and cut-off times, induction pass
marks and retry limits, induction validity, fire-watch durations, impairment maximum
durations, permit extension limits, offline manifest maximum age, scan-event and other
retention periods, combustible clearance distances, weather thresholds.

Do not invent universal legal retention periods or statutory thresholds.

---

## 10. Decision boundaries

Decide without asking: component design, code organisation, refactoring, accessibility
improvements, minor UX choices, defect fixes, test design.

Seek approval before changing: product scope, the technical authority or approval
model, safety-critical workflow rules, significant database or architectural direction,
data ownership or privacy purposes, anything needing insurer or technical-authority
input, anything affecting existing operational records.

Group related decisions into a single review with a recommendation and reasoning. Work
in substantial tested increments, not a sequence of small approval requests.

---

## 11. Reporting

At the end of each substantial phase, report:

**Completed** (implemented and working) / **Tested** (including negative scenarios) /
**Fixed** / **Outstanding** / **Decisions** (grouped, with recommendations) / **Next**.

Distinguish implemented, tested, proposed and awaiting validation. Maintain continuity
between sessions so settled decisions are not reopened without reason.

---

## 12. Known failure modes to avoid

Attractive interfaces over incomplete functionality. Buttons that do nothing. Dead-end
workflows. Placeholder functions presented as working. Mock data reaching production.
Permissions enforced inconsistently across layers. Duplicated business logic. Broad
success messages masking partial failure. Security controls implemented only in the
browser. Unnecessary redesign of working areas. Fixing one workflow while breaking
another.

Review the application as a whole product regularly. A feature that works in isolation
but causes problems elsewhere is not finished.

---

## 13. Launch gate

Do not recommend launch if any of the following is true:

- Work can become active without the required authority or physical controls.
- Entry is presented in a way that could be mistaken for work permission.
- Linked controls can be orphaned, or a job closed with controls outstanding.
- Material changes can overwrite approved evidence.
- An enabled specialist class lacks a validated procedure or a competent owner.
- Privacy roles or tenant separation are unvalidated.
- The venue cannot operate a tested outage and incident fallback.
- Contractors, supervisors and gate staff cannot reliably complete the five pilot
  scenarios.

Visual completeness is not sufficient.
