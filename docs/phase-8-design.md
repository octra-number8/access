# Build phase 8 — evidence and oversight: design for approval

**Status:** Approved 27 October 2026 (D-021), P8-16 to follow with the venue. Decisions are in §12.
Builds on phases 1–7: the audit log and its hash chain, decision contexts, issue and close-out snapshots, documents in private storage, the gate's records, and the malware scanner's service-account pattern.

Source questions:
- Q204–Q210 (notifications and dashboards).
- Q211–Q217 (evidence and audit).
- Q218–Q224 (retention and privacy).

Carried in from earlier phases:
- Q32: invitation reminders (phase 2).
- Q96: reporting repeated use of the emergency route (phase 6).
- Q119: the final permit pack (phase 6).
- Q203 and P6-13: telling a suspension's owner about an offline admission (phase 7).
- The scanner's deferred removal of infected files.
- Scheduling of the expiry job.
- C1: telling the venue owner when an organisation's accountable administrator changes.

Also CLAUDE.md:
- §7 item 8.
- §8 scenario 5 ("… evidence export").
- §3: the evidence and accountability model (`legal_hold`, `retention_rule`, `export` with scope, omissions and redactions recorded).
- §9: no silent default for retention periods.
- Invariants 5 and 10.

Q204–Q210 are **Proposed**. Q211–Q224 are **Requires specialist validation**: insurer and privacy (Q213–Q215), privacy and legal (Q218–Q224). As in earlier phases, this phase builds the machinery and the decision records, never the content. These are venue configuration with no silent default:
- reminder and escalation intervals;
- escalation contacts;
- every retention period and its trigger;
- who may approve retention and legal holds.

G11 (the controller/processor split) still blocks pilot data. This phase does not settle it: it makes the controls G11 will need exist and be testable.

Three things this phase must not do:
- **Notifications are never a control.** A notice tells someone that a decision was recorded or is due. It never changes a status, never settles anything by time passing (invariant 10), and never replaces the venue's direct route for stopping work (Q203).
- **No colour, score or percentage implying safety or compliance** (D-005). Dashboards show actions, owners and deadlines, not headline counts (CLAUDE.md §6).
- **No universal legal retention period** (CLAUDE.md §9). Nothing is deleted until the venue's controller has approved a rule for that category.

---

## 1. What phase 8 delivers

**Someone is told when something needs them.** An event that matters is recorded, in the same transaction as the decision, as a notification to the people who hold the relevant role at that moment. It is shown in their Octra inbox and, where they have chosen or the notice is critical, sent by email. Critical notices cannot be switched off. Overdue items are chased, and escalated to a named contact, at intervals the venue sets. The overdue item itself stays exactly as it was.

**Each person sees what is theirs to do.**
- **A venue manager** sees today's work, decisions due, stopped work and controls, overdue hand-backs, and gate exceptions.
- **A contractor administrator** sees what is due next and what is missing, each with its owner and deadline.
- **Reports** give lead times, returns, late requests and emergency-route use, by organisation and owner (Q96, Q209).

**Evidence can be handed over.**
- **A permit pack:** an authorised person can produce a fixed, indexed pack for an insurer, regulator or solicitor (Q213). It is built only from frozen snapshots and the audit log, never from the current live record. Contact details are removed by default (Q214), and anything else left out is recorded with a reason.
- **Proof the pack is untouched:** it carries its own hash and the audit chain's verification.
- **Record history:** venue users see the history of a record they are allowed to see (Q217).
- **Corrections:** factual corrections are recorded beside the original, never over it (Q216).

**Records are kept as long as the venue's controller decides, and no longer.**
- **Retention rules per category:** each has its own trigger event (Q222), approved by an appointee the controller names.
- **Disposal:** records past their period are listed for disposal, confirmed batch by batch, and recorded.
- **Legal holds** (Q223): a hold stops disposal for a defined matter until it is reviewed and lifted.

**Background jobs run on a schedule:** expiry, reminders, email delivery and disposal listing. Each is idempotent, safe to re-run, and logged where operations can see it (CLAUDE.md §5).

**What it does not do:**
- **No SMS or push notifications.** Email and the in-app inbox only.
- **No time-limited external reviewer view** (Q215 says fixed export first).
- **No withdrawal of portable disclosures** (Q220). Identity is per customer for the pilot (D-006), so there is nothing portable yet.
- **No scheduled report emails.** Reports are on screen with a CSV download (P8-15).
- **No anonymising or deleting of the audit log** in this phase (P8-13).
- **No settling of G11 or of any retention period.**

Proposed split **[P8-1]**:
- **8a:** the job runner, the notification outbox, critical and routine classes, preferences, the inbox, email delivery, reminders and escalation. This includes scheduling the existing expiry job, invitation reminders and Q203's offline-admission notice.
- **8b:** dashboards (venue, contractor) and reports, including Q96 and gate attendance.
- **8c:** permit packs and exports, redaction, record history, and corrections. Completes scenario 5.
- **8d:** retention rules, disposal, legal holds, and disposal of rejected uploads.

---

## 2. Background jobs (CLAUDE.md §5, P8-6)

- **The runner.** One scheduled endpoint, triggered every minute by the host's scheduler (Vercel Cron in production; a local script in development).
  - It acts as a dedicated **service account** (purpose `job_runner`), like the malware scanner: never the service role key, never a person.
  - Each job is a database function that the service account is allowed to call, and nothing else.
- **Jobs:**
  - Expiry of permits (the existing `api.expire_permits`, now scheduled).
  - Due reminders and escalations (§3).
  - Building and sending the email batch (§3).
  - Listing records due for disposal (§9).
  - Legal-hold review reminders (§10).
- **Idempotent and safe to re-run.** Each job claims its work with a lease, as the scanner does. A job that dies leaves its claims to expire and be taken again. Running a job twice never sends a notice twice or disposes of anything twice.
- **Observable.** Every run is a `job_run` record: job, started, finished, outcome, counts, error. Operations see it on the existing platform operations page, with a warning when a job has not succeeded within its expected interval.
- **Never a decision.** No job approves, issues, accepts, lifts or closes anything (invariant 10). Expiry is the only status change a job makes, as now. It ends an authority whose time ran out, never grants one.

---

## 3. Notifications (Q206, Q207, Q210, P6-13, Q203, Q32, C1)

**Recording.** A consequential decision that needs someone to know writes a `notification` row in the same transaction (an outbox), through one function, `core.notify(event, record, recipients)`. Recipients are resolved at that moment from the record and from current appointments, never from a job title or a mailing list (invariant 1). Examples:
- the permit's supervisor;
- the issuer who issued it;
- the appointees who can lift the suspension;
- the owner of an overdue fire watch;
- the reviewer assigned to a step.

**Classes [P8-3]:**

- **Critical: always in the inbox and always emailed, and nobody can switch them off.**
  - Work stopped or suspended, and a material change suspending live work. Sent to the supervisor, the issuer and the Work Approval holder.
  - A control failure or area stop affecting live work. Sent to each affected permit's supervisor and the control's owner.
  - An overdue fire watch or post-work watch; an impairment past its approved duration; a restoration overdue. Sent to the named watcher or owner, then escalated.
  - Emergency work authorised. Sent to the venue's tenant administrators and to the appointees who issue the retrospective permit's class there.
  - A reconciliation exception after an outage: an admission while work was stopped, or of someone the live record refuses. Sent to the exception's owner, and for work, the permit's supervisor (Q203).
  - A restriction imposed on a person or organisation with work today. Sent to the affected permits' supervisors and issuers, saying only that the person or organisation is restricted, never why.

  Every critical notice says that Octra has recorded the decision, and that the venue's direct route (control room, supervisor) still applies. A notification is never the stop instruction.

- **Routine: the person chooses in-app only, email as it happens, or a daily email digest** (Q210):
  - a decision assigned or due;
  - a request returned for information;
  - a permit issued awaiting acceptance;
  - approvals completed;
  - invitation reminders (Q32);
  - expiries that affect planned work or visits (Q208: an expiry is notified only when it falls before or during a job, visit or permit that needs that evidence);
  - the accountable administrator of an organisation changed (C1);
  - legal-hold reviews due.

**Content.** An email says what happened and where to look, with a link that needs sign-in. It never carries:
- personal contact details, document content, the grounds of a restriction, or medical or HR information;
- anything the recipient could not see in Octra.

**Chasing and escalation (Q207) [P8-5].** For each overdue kind (approval step, information request, hand-back, fire watch, impairment, restoration, legal-hold review), the venue configures:
- the reminder interval;
- after how long to escalate;
- to whom: the owner's deputy, or a named appointment type or person.

None has a default: until configured, overdue items are shown on screen with their owner, as now, and nothing is chased. Escalation adds recipients. It never reassigns, approves or closes anything.

**Delivery.** The email job sends through the existing SMTP configuration. It:
- records each send and failure;
- retries a failure with a backoff;
- shows a notice that keeps failing on the operations page.

A failed email never blocks or undoes the decision that caused it. The inbox always has the notice.

**Inbox.** `/inbox`: a person's notices, newest first, each linking to its record. They can be marked read; reading changes nothing else.

---

## 4. Dashboards (Q204, Q205, Q208)

Lists of actions with owners and deadlines, never counts, percentages or traffic lights (CLAUDE.md §6, D-005). Each row links to the record where the action is taken.

**Venue dashboard (`/dashboard`, tenant administrators and venue appointees), five groups (Q204):**
1. Today's live and imminent work, by location and event phase.
2. Missing prerequisites and decisions due before a start time, with their owner.
3. Stopped work, control failures, impairments and fire watches in progress or overdue.
4. Overdue hand-backs, continuing controls with their owner, and open reconciliation exceptions.
5. Restrictions and expiries that affect today's or tomorrow's work or visits (Q208).

**Contractor dashboard (on the organisation's page, for its administrators), five groups (Q205):**
1. Jobs and visits due next, and what each still needs.
2. Requests returned, with exactly what was asked.
3. Workers needing an induction, evidence or a place on a team, only where planned work needs it (Q208).
4. Venue decisions outstanding, with who owns them.
5. Live permits, stopped work and hand-backs due.

Each group shows its items, or "Nothing due". A group someone cannot see is not shown (for example, occupiers' names to contractors, P5-6).

---

## 5. Reports (Q209, Q96)

On-screen reports for a chosen period, each with a CSV download. Each reports what was recorded, and none is a score:
- approval lead times by step and owner;
- returns and information requests, with the questions asked;
- late requests and use of the late-notice and emergency routes, by organisation, workstream and stated cause (Q96);
- live controls unresolved at closure attempts, and hand-backs overdue;
- gate activity: evaluations, overrides, offline entries and exceptions by gate and day;
- visit attendance.

Reports follow record visibility: a contractor sees only its own organisation's rows.

---

## 6. Permit packs and exports (Q119, Q211, Q213–Q215, P8-8 to P8-10)

**Source.** A pack is built only from frozen evidence, never from the current live record:
- the issue snapshots (Q211);
- the close-out snapshot (Q119);
- for a permit not yet closed, a statement that it is live, with the snapshots so far;
- the document versions those snapshots name;
- the audit events for the permit, its job, its controls and its team.

**Contents (Q213):**
- **An index.**
- **The record:**
  - identifiers and versions;
  - scope, locations and times;
  - parties, roles, and the appointments under which each decision was made;
  - approvals, conditions and reasons;
  - issued evidence, acceptance and briefings;
  - linked permits;
  - isolations, impairments, fire watches and custody;
  - suspensions, lifts, changes and extensions;
  - hand-back, inspection and closure.
- **The evidence files** named by the snapshots.
- **A chronology** from the audit log, with the chain verification result for the events included.
- **The pack's description:** scope, purpose, recipient, redaction profile and every omission with its reason.

**Form (Q215) [P8-10].** A versioned PDF (the index, record and chronology) and the evidence files, delivered together as one ZIP. Each file's SHA-256, and the pack's, are recorded. The pack is stored privately and downloaded only through a short-lived signed link after an authorisation check (CLAUDE.md §5).

**Who.** An appointee holding `evidence.export` for the venue, and the permit's class and area. Every pack is an `export` record:
- who made it, when, and for what purpose and recipient;
- the scope, profile and redactions;
- its hashes.

A pack is never edited; a new one is made. Platform and tenant administrators cannot export as such (invariant 9). Break-glass support access stays read-only and cannot export.

**Redaction (Q214) [P8-9].**
- **External profile** (insurer, regulator, solicitor) always removes:
  - personal phone numbers, private email addresses, home addresses and emergency contacts;
  - identity document details;
  - medical or HR information;
  - the grounds of any restriction.
- **Internal profile** (the venue's own investigation) keeps contact details recorded for the job.
- **Never removed:** who made each decision, under which appointment, and when. That is the evidence.
- **Further omissions:** the exporter may omit more, each with a reason, and the pack lists every omission.

**Other exports.** CSV downloads from reports (§5) are recorded as exports too (scope and who), without hashes.

---

## 7. Record history and audit visibility (Q217)

- **History panel.** A venue user who can see a record sees its history on its page. It lists, from the audit log, each decision and change: who, in which capacity, what, when, and the reason where one was required. Raw changed values are not shown.
- **Unchanged visibility.** The full audit log, with changed values, stays visible only to the customer's tenant administrators (as now) and to platform security under break-glass. Contractors see the history of their own records only.
- **Verification.** A verification function (already built) checks the hash chain for a customer. The operations page shows the result of a scheduled check. Packs include the result for their events.

---

## 8. Corrections (Q216) [P8-12]

A factual error is corrected without rewriting history.
- **Records that can still change** (a person's or organisation's details, a document's metadata): the change is made through the existing route, and a `correction` record states what was wrong, the corrected value, the reason, the evidence, and who authorised it. The original value stays in the audit log (restricted, §7).
- **Frozen records** (issued and close-out snapshots, decisions): never changed. A `correction` is attached beside them and shown wherever the record or a pack shows them, as "Corrected on [date] by [name]: [what]".
- **Who:** an appointee holding `record.correct` for the venue. Never the person who made the error alone (separation of duties); a correction to one's own details needs another person's verification.

---

## 9. Retention and disposal (Q218, Q221, Q222, Q224) [P8-13]

- **Rules.** For each record category, a venue configuration document states the trigger event and the period. Categories include:
  - permit packs and closed permits;
  - inductions;
  - appointments;
  - custody;
  - scan events and gate evaluations;
  - manifests and fallback entries;
  - visits;
  - documents not used by any issued permit;
  - notifications;
  - job runs.

  The trigger events (Q222) include final closure or cancellation for permits, expiry or supersession for inductions, termination for appointments, and the event's date for scans.
- **No default.** A category with no approved rule is kept, and the retention page says so (CLAUDE.md §9). The rules are approved by an appointee holding `retention.approve`: the person the venue's controller names, typically its data-protection lead. Never the author.
- **Disposal.** A job lists the records past their period and not under hold. An appointee holding `retention.dispose` reviews and confirms each batch. Records are deleted, or anonymised where a parent must remain. Each disposal is recorded (category, rule version, count, who confirmed); never the disposed content. Nothing is disposed automatically in v1.
- **Issued evidence.** A permit's issue and close-out snapshots, and the document versions they name, are disposed only with the permit, under the permit rule.
- **The audit log is not disposed of in this phase.** Its hash chain would break, and what it may hold is a G11 question. Personal data in the log is already minimal (identifiers, not contact details).
- **Rejected uploads.** Infected or rejected files (the scanner design) are removed from storage after the venue's rule for them, keeping their record and the scan result.

---

## 10. Legal holds (Q223) [P8-14]

- **Request.** An appointee holding `legal_hold.request` asks for a hold with:
  - a matter reference and a reason;
  - a scope: a venue, an organisation, a person, a job or permit, a date range, or a combination;
  - a review date (required).
- **Approval.** By an appointee holding `legal_hold.approve`, never the requester.
- **Effect.** While a hold is active, nothing in its scope can be disposed of. The disposal list shows what each hold kept.
- **Review and lifting.** On the review date, the approver and requester are notified (routine). The hold continues until it is reviewed and either renewed with a new review date or lifted with a reason by a `legal_hold.approve` appointee. It never lapses by time (invariant 10).
- **Visibility.** Holds are visible to the venue's administrators and the holders of these actions; never to contractors.

---

## 11. Authority, actions, screens and proof

**About twenty new actions:**

| Area | Actions |
|---|---|
| Notifications | Record (derived, inside decisions); send and claim (service); mark read (subject); set preferences (subject); configure reminders and escalation (venue configuration: tenant administrator drafts, appointee approves). |
| Jobs | Run each job (service). |
| Evidence | `evidence.export` (appointment: venue, class, area); `record.correct` (appointment). |
| Retention | Rules (venue configuration: draft and propose by tenant administrator; `retention.approve` appointment); `retention.dispose` (appointment). |
| Legal holds | `legal_hold.request`, `legal_hold.approve` (appointment). |

**Screens:**

| Screen | Who | What |
|---|---|---|
| Inbox (`/inbox`) and notification preferences | Everyone | Notices, newest first; choices for routine notices. Critical notices are shown as fixed. |
| Venue dashboard (`/dashboard`) | Tenant administrators, appointees | The five groups (§4). |
| Contractor dashboard | Organisation administrators | The five groups, on the organisation page. |
| Reports (`/reports`) | Appointees, tenant administrators, organisation administrators (own rows) | §5, with CSV. |
| Permit pack | `evidence.export` holders | On the permit page: purpose, recipient, profile, omissions; the list of packs made, with their hashes. |
| History panel | Anyone who can see the record | On the permit, job, person, organisation and visit pages. |
| Retention (`/venue/retention`) | Tenant administrators and retention appointees | Rules drafted and approved; categories with no rule; disposal batches to confirm. |
| Legal holds (`/venue/holds`) | Hold appointees, tenant administrators | Request, approve, review, lift. |
| Operations | Platform administrators | Job runs, failed emails, chain verification. |

**Proof:**
- **Database (pgTAP), positive and negative:**
  - **Notifications:**
    - critical notices cannot be switched off;
    - recipients come from current appointments, and a revoked appointee receives nothing;
    - a notice is written in the decision's own transaction and is gone if that rolls back;
    - re-running the send job sends nothing twice;
    - escalation never changes the overdue item.
  - **Packs:**
    - immutable, with a matching hash;
    - an external pack contains no personal phone number, email address or home address;
    - an omission without a reason is refused;
    - cross-tenant and cross-venue export are refused.
  - **Retention:**
    - nothing is disposed of without an approved rule;
    - a hold blocks disposal;
    - the requester cannot approve their own hold;
    - a hold past its review date stays active.
  - **Platform and tenant administrators:** cannot export, approve a hold or confirm disposal.
- **End to end:**
  - **Scenario 5 completed:** a live suspension or worker change, continuing controls, hand-back, then an evidence pack export, checked for content and redaction.
  - **Scenario 6:** the outage exercise over HTTP, now with the critical notice to the suspension's owner (outstanding from 7d).
- **Browser:** the inbox and a critical email in Mailpit; both dashboards; a pack download; a disposal batch blocked by a hold.

---

## 12. Decisions needed

| # | Question | Recommendation |
|---|---|---|
| P8-1 | Split into 8a (jobs and notifications), 8b (dashboards and reports), 8c (packs, exports, history, corrections) and 8d (retention and legal holds)? | **Yes.** 8a first, because the others raise notices; 8c completes scenario 5. |
| P8-2 | Notifications recorded in the decision's own transaction (an outbox), to recipients resolved then from appointments and ownership, delivered later by a job? | **Yes.** A notice can never claim a decision that did not commit, and authority stays with appointments (invariant 1). |
| P8-3 | The critical class in §3, always emailed and never switchable off, with every critical notice saying the direct route still applies? | **Yes.** It is CLAUDE.md §7's "mandatory critical class", grounded in Q206. The list is Proposed: review it with the venue. |
| P8-4 | Email and in-app inbox only, with routine notices as in-app, immediate email or daily digest by personal choice? | **Yes** (Q210). SMS and push are later, if the pilot needs them. |
| P8-5 | Reminder intervals, escalation timing and escalation contacts as venue configuration with no default, escalation only adding recipients? | **Yes.** CLAUDE.md §9 and invariant 10. Until configured, overdue items show on screen as now. |
| P8-6 | One scheduled job runner acting as a dedicated service account, with leases, idempotent jobs and a visible run log; the expiry job scheduled every minute? | **Yes.** It reuses the scanner's pattern and never uses the service role key. |
| P8-7 | Dashboards as lists of actions with owners and deadlines, in the five groups proposed by Q204 and Q205, with no counts or traffic lights? | **Yes.** CLAUDE.md §6 and D-005. |
| P8-8 | Permit packs built only from frozen snapshots, the documents they name and the audit log, by `evidence.export` appointees, each pack an immutable export record with its hashes? | **Yes.** Invariant 5 and Q211, Q213. |
| P8-9 | External packs always remove the Q214 list. Decision-makers, appointments and times are never removed. Further omissions need a reason, and the pack lists them all? | **Yes**, subject to the privacy adviser (G11, Q214). |
| P8-10 | Pack format: a PDF (index, record, chronology) plus the evidence files, in one ZIP. Build it with two small, widely used libraries (`pdf-lib` with its font support, and `fflate`), or write a minimal PDF and ZIP writer as was done for QR codes? | **Use the libraries.** Insurers and solicitors will read these packs; names need proper fonts (accents, Unicode), and a maintained PDF writer is safer than our own. This adds three dependencies: approval to download them is part of this decision. |
| P8-11 | Record history for anyone who can see the record (who, capacity, what, when, reason; no raw values). The raw audit log only for tenant administrators and break-glass? | **Yes.** Q217. |
| P8-12 | Corrections recorded beside the original: live records changed through their own route with a correction record; frozen records never changed, with the correction shown beside them; a correction never made alone by the person who made the error? | **Yes.** Q216 and invariant 5. |
| P8-13 | Retention: per-category rules with their own trigger as venue configuration, no default, approved by a `retention.approve` appointee the controller names. Disposal listed by a job and confirmed batch by batch, never automatic in v1. The audit log not disposed of in this phase? | **Yes.** CLAUDE.md §9 and Q224. Automatic disposal and audit-log treatment only after G11. |
| P8-14 | Legal holds requested and approved by different appointees, with a required review date, never lapsing by time? | **Yes.** Q223 and invariant 10. |
| P8-15 | Defer the time-limited external reviewer view (Q215), withdrawal of portable disclosures (Q220, D-006), scheduled report emails (Q209) and SMS? | **Yes.** Each has a fixed or on-screen alternative in v1. |
| P8-16 | Who holds `evidence.export`, `retention.approve`, `retention.dispose` and the legal-hold actions at the pilot venue? | **Needs your input**, with the venue and its privacy adviser. The machinery does not depend on it; the pilot does. |

Still open from earlier phases, and not blocking phase 8:
- 6a-1 to 6d-2.
- 7a-1 to 7d-4, P7-14.
- N1, N2, I1, E1.
- **G11:** it blocks pilot data and governs P8-9 and P8-13.

---

## 13. As built (phase 8a, 27 October 2026)

**Implementation.**
- **Migrations:** `supabase/migrations/20261025000052` (catalogue, outbox, deliveries, preferences, job runs, chasing configuration) and `…53` (sources, jobs, delivery, inbox).
- **Runner:** `src/lib/job-runner.ts`, called by `/api/jobs/tick` (Vercel Cron every minute, `vercel.json`; locally `node scripts/run-jobs.ts`).

**Proof.**
- **pgTAP:** `38_notifications` (54 assertions), plus notification checks added to:
  - `11` (accountable administrator changed, C1);
  - `31` (control failure; impairment overdue);
  - `32` (emergency work);
  - `37` (outage exceptions, Q203).
- **Totals:** 1,383 in the whole suite, through both test runners.
- **Mutation testing:** 21 of 23 deliberate weakenings caught, three only after tests were strengthened. The other two are equivalent in the fixtures: the actor-exclusion on emergency work, whose authoriser is never a recipient there, and the "only on a change" condition for accountable administrators, whose first grant is made by the venue administrator, who is excluded as the actor.
- **Catalogue:** five new actions, 274 in total.

| Area | As built | Note |
|---|---|---|
| Outbox (P8-2) | `core.notify` writes one row per recipient, with a dedupe key, inside the decision's transaction. A refused or rolled-back decision leaves nothing. Recipients are resolved at that moment: a permit's supervisors and issuer (and, for a child, the Work Approval's supervisors), a control's owner and the people who requested, authorised, applied or proved it, appointees who can take an action (`core.action_holders`, through `authz.capacities`: current, unrestricted, not excluded), or the venue's tenant administrators. The person who caused an event is not told of it. Deactivated people receive nothing. Nobody writes notifications directly. | |
| Critical (P8-3) | **Raised by the decision itself:** work stopped or suspended (each permit, so a stopped child and its Work Approval give two notices); a control failure; emergency work authorised; an outage exception (work: the permit's owners; entry: `gate.reconcile` holders); a restriction affecting a live permit (stated as a fact, never its grounds). **Raised by the watch job:** an impairment past its approved time or planned end, and a fire watch still not started once its permit has stopped. Critical notices are always queued for email whatever the person chose, are marked "[Critical]", and end: "Octra has recorded this. It is not an instruction: the venue's direct route (control room, supervisor) still applies." | "Fire watch overdue" is defined as arranged but not started once the permit is suspended, in hand-back or expired. This definition needs validating with the venue. |
| Routine (P8-4, Q210) | **Notices:** a permit issued awaiting the supervisor's acceptance; information requested (to the job's contact and supervisor); decisions due (to the people who can decide each open step, from the job); the accountable administrator changed (C1). **Delivery:** each person chooses Octra only (the setting when none is recorded), email as it happens, or a daily email. | Invitation reminders go to the invitation's owner. Re-sending to the invitee would need a new link (the token is stored only as a hash), so it remains the existing resend route. |
| Chasing (P8-5, Q207) | Venue configuration of kind `chasing`. For each of approval steps, information requests, hand-backs, fire watches, impairments and invitations, the venue sets: how often to remind, whether and after how long to escalate, and to whom (people, or everyone holding an appointment type). No default: nothing is chased until it is approved by an appointee who did not write it. Edited at `/venue/chasing`; approved on the decisions page. A reminder is sent once per interval and an escalation once. Neither changes the item. | |
| Jobs (P8-6) | **The tick** signs in as the job runner service account (purposes `job_runner`, `permit_expiry`, `notification_sender`), never with the service role key. It runs expiry, the notification jobs (decisions due, the watch, chasing) and email (immediate, then daily digests). **Logging and safety:** each step is logged in `job_run`; a failed step is logged and the others still run; re-running sends nothing twice. **Email:** claimed with a lease, retried with a growing wait, and marked failed after five attempts, with the notice still in the inbox. **Operations page:** job runs, a warning when a job has not succeeded for five minutes, and failed emails (no content). **The route** refuses any call without the shared secret. | Vercel Cron every minute needs a paid Vercel plan; any scheduler that calls the route with the secret will do. |
| Inbox | `/inbox`: notices newest first (critical marked, and its colour only repeats the word), each linking to its record; mark all read; the routine-notice choice, with the critical list stated as fixed. The header shows "Inbox (n new)". | |

**Proved in the browser and on the local stack:**
- **The event:** an outage entry for an unknown visitor, made through the API by the gate operator, raised a critical notice to Ava, the access administrator.
- **The scheduler:** `scripts/run-jobs.ts` ran expiry, the notification jobs and email. The email arrived in Mailpit with the "[Critical]" subject, the direct-route sentence and a sign-in link. A second run sent nothing. The route refused calls with no secret or the wrong one (401).
- **The inbox:** Ava's inbox showed the notice and the header count. Marking it read cleared the count. Her choice of a daily email was saved.
- **Chasing:** admin1 started a draft. Saving without an escalation choice was refused, with the input kept. It was then saved and proposed.

**Fixed during the build:**
- The delivery state column was renamed from `status`, which the structure test reserves for decision states.
- Starting a `chasing` draft was not yet allowed.
- Claims compared against the transaction's frozen time instead of the clock.

**Not covered:**
- **Information requested:** the RFI notice is wired but not exercised by a test. *(Covered in 8b: test 39 checks the job's contact is told once.)*
- **Overdue fire watch:** the source is not exercised in the database tests (the impairment is).
- **Digest emails:** the claim is exercised; no browser check of a digest email.
- **Recipients without an account:** they have no email address, so they receive inbox notices only, which they cannot read. This is visible as `no_address` on the delivery.

### Decisions raised by the 8a build

| # | Question | Recommendation |
|---|---|---|
| 8a-1 | "Fire watch overdue" is defined as arranged but not started once its permit is suspended, in hand-back or expired. Is that the right trigger, or does the venue want a time after work stops? | **Accept for now, validate with the venue.** A time after work stops would be venue configuration with no default. |
| 8a-2 | People without an Octra account (6b-2) cannot receive notices. Should critical notices about them go to their organisation's administrators instead? | **Yes, in 8b**, alongside the contractor dashboard. Today their supervisors already receive the critical notices about the work. |
| 8a-3 | Invitation reminders go to the invitation's owner, not the invitee, because the invitee's link cannot be re-sent without issuing a new one. Accept? | **Yes.** The owner can resend the invitation through the existing route, which issues a fresh link. |

---

## 14. As built (phase 8b, 27 October 2026)

**Implementation.**
- **Migrations:** `supabase/migrations/20261025000054` (the two dashboards) and `…55` (reports). Reads only: no new tables or actions.
- **Screens:**
  - `/dashboard`: the venue's five groups.
  - The contractor's five groups at the top of the organisation page, for its administrators.
  - `/reports`, with a CSV download at `/reports/csv`.
  - Links from the home page.
- **Shared code:** `src/lib/dashboard.ts` (types, wording, CSV writer) and `src/components/dash-list.tsx`. The live board's "what each permit needs" now comes from the same helper.

**Proof.**
- **pgTAP:** `39_dashboards_reports` (74 assertions); 1,457 in the whole suite, through both test runners.
- **Mutation testing:** 27 of 27 deliberate weakenings caught, three only after tests were strengthened (occupier wording, the exact issuer named, the report period).
- **Unit:** CSV quoting and formula-injection guard, and scope parsing.

| Area | As built | Note |
|---|---|---|
| Who sees what | **Venue dashboard:** the venue's side only (`authz.venue_side`: its tenant administrators and anyone holding an appointment there). **Contractor dashboard:** the organisation's own administrators only, not the venue's administrators. **Not visible:** platform administrators, other customers and other organisations see neither; an unknown venue looks the same as one you cannot see. | |
| Venue dashboard (Q204, P8-7) | **The period:** today and tomorrow, in venue time. **The groups:** (1) work approved, issued or live in that period, by location and event phase, with visits listed separately as entry only; (2) decisions due (open steps with the people whose appointment covers them, by name), information requests, permits ready to issue or what is missing before issue, acceptances due, screening decisions and visit requests, each with the work's start time; (3) stopped work, area stops, unresolved control failures, impairments and fire watches; (4) hand-backs due with their outstanding duties, continuing controls with their owner and review date, open outage exceptions, and emergency work without its retrospective permit; (5) restrictions and expiries that affect this work or these visits. **Rules for every line:** it says what is needed, who owns it, and when. "Nobody currently holds an appointment for this" is shown rather than hidden. Overdue lines say so in words. There are no counts, scores or colours. | "Today and tomorrow" is a screen period, not venue configuration. |
| Expiries against real work (Q208) | Group 5 runs the issue checks themselves (organisation and team) for each permit in the period: engagement, organisation evidence, each team member's restriction, induction and competency, all against that permit's dates. Visits check the organisation and each roster member for restriction. A restriction is shown as a fact; its grounds never are. | An expiry that does not affect planned work is not shown, as Q208 asks. |
| Contractor dashboard (Q205) | (1) jobs and visits due next, each permit's state, and what an approved permit still needs before issue; (2) information requests with exactly what was asked, and documents returned; (3) workers on planned work who are missing an induction or competency, are restricted, or are not named; (4) venue decisions it is waiting for, owned by a role ("the venue's reviewer", "the affected occupier", "the venue's access authority"), never a person; (5) live permits, stopped work and hand-backs due. **P5-6:** the occupier and the venue's appointees are never named here. | Recorded decisions keep their decider's name in reports, as the permit page already shows them to the applicant. |
| Reports (Q209, Q96, P8-15) | **One read:** `api.report(kind, venue, from, to, organisation)`. **The six:** approval lead times, returns and information requests, late requests and emergency work (by organisation, work type and stated cause, with outcome), hand-backs (waiting time and duties still outstanding), gate activity (by gate and day), and visit attendance (including who did not attend). **Format:** the columns are defined once, in the database, and the screen and the CSV show the same rows. Times are in venue time, over whole venue days, up to 366 days. **Visibility:** the venue's side sees all rows; an organisation's administrator sees only its own rows, and never gate activity. **The CSV:** a CSV cell that a spreadsheet would treat as a formula is prefixed so it cannot run. | Lead time is measured from the request's submission, not from when a later sequential step opened. |

**Proved in the browser and on the local stack** (two of Cara's jobs, made through the API):
- **The venue dashboard:**
  - Today's work grouped by hall.
  - The stop shown with who can lift it.
  - The unanswered information request, owned by Cara.
  - The Work Approval missing its child permit before issue.
  - The 8a outage exception.
- **The late-requests report:** showed Ian's allowed late notice. The CSV download matched it row for row, with a `text/csv` attachment.
- **Signed out:** the CSV route answered 401 and the dashboard redirected to sign-in.
- **Cara's own view:**
  - Her jobs and what each permit needs.
  - The information request with its two questions.
  - Her live and stopped permits.
  - No venue appointee named.
  - Her reports offered only her organisation's rows, without gate activity.
  - `/dashboard` told her it is for the venue's side.
- **At phone width:** the action lists stack into labelled rows, with no sideways scrolling.

**Fixed during the build:**
- Two loops passed an untyped row where a permit or visit was expected; both failed at run time. Test 39 found the first, and the second was fixed with it.
- The contractor's approved Work Approval said "waiting to be issued" when it was blocked by its child permit. It now lists what is missing.
- Dashboard tables were cramped on a phone; they now stack.

**Not covered:**
- **Gate activity:** the report's rows are not exercised with gate events in test 39 (only that it is offered to the venue's side and refused to an organisation).
- **The work table's event phase:** the fixture's jobs have no event.
- **Closure attempts refused:** "Live controls unresolved at closure attempts" (§5) is reported as hand-backs with their waiting time and the duties still outstanding. A refused hand-back acceptance is not recorded (readiness refusals are returned, not stored), so attempts themselves cannot be counted. See 8b-2.

### Decisions raised by the 8b build

| # | Question | Recommendation |
|---|---|---|
| 8b-1 | The venue dashboard looks at today and tomorrow (venue time). Is a two-day window right for the pilot, or should the venue choose it? | **Keep two days for the pilot.** If venues want another span, make it venue configuration with no default, like the other periods. |
| 8b-2 | §5 asks for "live controls unresolved at closure attempts". Refused attempts are not stored today, so the report shows hand-backs, how long each waited and what is still outstanding. Should refused hand-back acceptances be recorded so attempts can be reported? | **Not now.** The hand-back report shows the same operational fact (what blocked closure, for how long). Recording refusals would add a new kind of record; revisit after the pilot if the venue asks. |
| 8b-3 | The contractor dashboard names no venue person for decisions it is waiting on, but reports and the permit page name whoever *recorded* a decision. Is that the right line? | **Yes.** Who decided is part of the record the applicant already sees; who *could* decide is the venue's internal arrangement. |

---

## 15. As built (phase 8c, 27 October 2026)

**Implementation.**
- **Migrations:** `supabase/migrations/20261025000056` (catalogue, the `export` and `correction` records, the job's record set, history, redaction and the pack's content) and `…57` (requesting, building, releasing and listing packs; report downloads recorded; history; corrections; the private `evidence-packs` bucket).
- **Three new actions** (277 in all): `evidence.export` and `record.correct` (appointment, not delegable) and `evidence.build_pack` (service, purpose `pack_builder`).
- **Libraries (P8-10):** `pdf-lib` 1.17.1, `@pdf-lib/fontkit` 1.1.1 and `fflate` 0.8.3, pinned exactly; `npm audit` reports no vulnerabilities.
- **Code:** `src/lib/pack-format.ts` (PDF and ZIP, no server dependencies), `src/lib/packs.ts` (the builder), the "packs" step in `src/lib/job-runner.ts`, `/api/packs/[exportId]` (release), `src/components/permit-evidence.tsx` and `src/components/history-panel.tsx`.
- **Screens:** an Evidence section on the permit page (corrections; packs made; making a pack; recording a correction) and a History panel on the permit, job, visit and organisation pages and on `/me`. The operations page now watches the "packs" job.

**Proof.**
- **pgTAP:** `40_evidence` (117 assertions); 1,574 in the whole suite, through both test runners, on databases rebuilt from the migrations.
- **Mutation testing:** 33 of 33 deliberate weakenings caught; one (removing contact fields by name) only after a direct test was added.
- **Unit:** the PDF renders and reads back, including characters the font lacks; the ZIP holds `pack.json` byte for byte with the content hash; every manifest hash matches. The catalogue test now expects 277 actions.

| Area | As built | Note |
|---|---|---|
| Who may make a pack (P8-8) | An appointee holding `evidence.export` whose appointment covers the venue, the job's **Work Approval class** and the job's places. A pack covers the whole job: every issued permit on it. Refused, and leaving nothing behind: platform and tenant administrators (invariant 9), other customers, other venues' appointees, the contractor, and an evidence officer for another class only. | See 8c-4. |
| What a pack holds (Q213, Q211, Q119) | Fixed when it is requested, in one transaction, with its SHA-256: each issued permit's issue snapshots and close-out snapshot exactly as frozen (each with its own recorded hash), the permits never issued, the evidence files those snapshots name, corrections recorded so far, the chronology and its audit-chain check, and dictionaries naming every person, appointment, area and organisation mentioned. A job with nothing issued cannot be packed. A pack of a live job says its permits were not closed and holds only what was frozen. | |
| Chronology and history (Q217, P8-11) | One builder for both: every decision context that touched the records (directly, or by writing a row of them), with who, the capacity worded to read after "as", what (the action's description), when, any change of recorded state and the reason given. Pack entries also carry the audit entry's sequence number and hash. Never raw values. **History panel:** for anyone who can see the record. A restriction's grounds are withheld from anyone outside the venue's side, who is told they are held by the venue. A permit's history holds its own decisions; a job's holds all of them, including packs made. | Times are in the venue's time zone; for people and organisations, the customer's first venue's. |
| Redaction (Q214, P8-9) | **External profile:** contact and personal fields (phone, email, address, emergency contacts, medical, date of birth, passport, national insurance) are removed by name at any depth; email addresses and telephone numbers (10–15 digits) are removed from free text; the pack counts what was removed. A person's own documents (cards, certificates) are left out, with that reason. **Internal profile:** adds the job contact's and supervisor's recorded email and phone, and the venue's emergency contacts. **Never removed:** names, appointments and times. **Omissions:** the exporter can leave out any evidence file or any permit's answers, each with a reason; an omission without a reason, or of something the pack does not have, is refused. Every omission is listed in the pack. | Free text is not checked for addresses: see 8c-3. |
| Evidence files | Released as documents are (D-014): scanned clean, or recorded as not scanned while scanning is off, which the pack states for each file. A file waiting for, or failing, the check is never included and is listed with the reason. | |
| Building (P8-10) | The job runner's service account (purpose `pack_builder`) claims queued packs with a lease, reads each file and checks it against its recorded SHA-256, renders the PDF (cover, index, the job, each permit as issued and as closed, corrections, contact details if internal, evidence files, chronology, verification) and the ZIP (`pack.pdf`, `pack.json`, `evidence/…`, `manifest.json`), stores it privately and records the files' hashes. The database refuses the record unless `pack.json` is the recorded content unaltered and every named evidence file is present with its recorded hash. A failed build is retried and, after three attempts, marked failed and never released. The request builds the pack straight away; the scheduled step is the fallback. | The person who asks can neither upload nor record a pack's files. |
| Immutability (invariant 5) | A pack's content, purpose, recipient and profile can never change. Once built (or failed) nothing on it changes. Packs and corrections cannot be deleted. | |
| Release (CLAUDE.md §5) | Only to someone who could make that pack now, once it is built, as a 60-second signed link from the private bucket, named by its reference. Every release is audited. Signed out: 401; anyone else: 404. | |
| Who sees the packs made | The customer's tenant administrators (read-only, no download) and the venue's `evidence.export` appointees, on the permit page: reference, profile, state, when, by whom and in which capacity, recipient, purpose, omissions, content and pack hashes. Never the contractor, even one holding a venue appointment. | |
| Report downloads (§6) | Each CSV download is recorded as an export: which report, venue, period, organisation, row count and who. No content. | |
| Corrections (Q216, P8-12) | Beside a frozen record of a permit (as issued, the closure record, a step decision, a hand-back decision), by a `record.correct` appointee who did not make the record and is not connected with the job (D-007, through the separation-of-duties floor). It states what is wrong, what the record says, the correct value, the reason and what shows it. The original is unchanged and still matches its hash. Shown on the permit page to anyone who can see it, in its history, and in every later pack; an earlier pack stays as it was handed over. | Live records (people, organisations, document details): see 8c-5. |

**Proved in the browser and on the local stack** (Evelyn, a demo Evidence Officer; Cara's job taken to closure with two stored files; script outside the repo):
- **External pack:** made through the form with the Work Approval's answers left out. It was built at once with four files; Cara's own card was left out with the reason. Downloaded through the page link, its SHA-256 matched the recorded pack hash. Inside: the manifest's hashes all matched; `pack.json` matched the content hash; the phone number and email in the hand-back text were gone.
- **The PDF (13 pages):** read page by page. Cover with purpose, recipient, profile, removals and omissions; index with page numbers; each permit as issued and as closed; evidence files with their hashes and malware state; the chronology with each decision's maker, capacity and audit entry; the chain verified.
- **Internal pack:** five files, including the card; the contact details kept.
- **Correction:** recorded through the form; shown on the permit page and at the top of its history.
- **Cara:** sees the correction and the history; no packs; the pack link gives her 404. Her CSV download was recorded as an export. Signed out, the pack link gives 401.
- **Phone width:** the evidence section and history read without sideways scrolling.
- **The job runner:** the "packs" step ran each minute and was logged.

**Fixed during the build:**
- **Permit class version hash (phase 5 defect):** a proposed class version stored its SHA-256 as the hex text's 64 bytes, so issue snapshots carried a hash of the wrong form. New versions now store the digest (tested). Versions proposed before this keep what they recorded, as do snapshots already issued (pre-pilot data only).
- **Choice labels across the app:** every checkbox and radio label marked `inline` was being shown as running text, because Tailwind's own `inline` utility overrode the app's rule. The rule now sits outside the layers; the inbox, permit and visit forms show one choice per line again.
- **Not-scanned files:** the first version included only files scanned clean, so with scanning off (D-014, the current setting) no file would ever have gone into a pack. It now follows the document rule and says which.
- **Evidence officers could not see jobs:** job visibility now includes `evidence.export` and `record.correct` appointees, as it does other appointees.
- **History for tenant administrators:** they reach people and organisations through administration, not the visibility functions, so the history read now allows that route.
- **Wording:** every decision basis is worded ("someone named on the permit", "part of another decision they made"); someone accepting an invitation is named from their account; codes and states are shown in words.
- **The external profile's own description** claimed addresses were removed from free text; it now says what is actually done (8c-3).

**Not covered:**
- **Production font and bundling:** the builder reads Geist from the installed Next.js package at run time. This works locally; on Vercel the file must be included in the function bundle, which is not yet configured or tested. See 8c-2.
- **Corrections to live records** (people, organisations, document details) are not built. See 8c-5.
- **Scenario 5 end to end over HTTP:** packs are proved in pgTAP and the browser, not yet in the end-to-end suite.
- **Large packs:** not measured. The builder holds a whole pack in memory, and evidence files are up to 20 MB each.

### Decisions raised by the 8c build

| # | Question | Recommendation |
|---|---|---|
| 8c-1 | External packs always leave out a person's own documents (cards, certificates), as Q214 lists identity documents and these often show a photo or date of birth. The exporter cannot put one back in. Is that right? | **Yes for the pilot.** If an insurer needs a particular card, make an internal pack for the venue's own handling, or revisit with the privacy adviser (G11). |
| 8c-2 | The PDF uses Geist, read from the installed Next.js package: it covers accented Latin, Greek and Cyrillic, and its licence text is not shipped with it there. Download Noto Sans (SIL Open Font Licence) into the repository with its licence, and bundle it for production? | **Yes, before the pilot.** It is a small, widely used font with a clear licence, and it removes the dependency on Next.js internals. It is a download, so it needs your approval. |
| 8c-3 | External redaction removes contact fields by name, and email addresses and phone numbers from free text, but cannot reliably find home addresses in free text. Accept that, with the cover telling the exporter to review, and omissions available? | **Accept for the pilot**, subject to the privacy adviser (G11, Q214). Pattern-matching addresses would also remove the venue's own address and halls. |
| 8c-4 | A pack covers the whole job, and the authority must cover the job's Work Approval class and places. Should an evidence officer for one specialist class be able to pack only that permit? | **No, keep whole-job packs.** Insurers and investigators need the job's context; single-permit packs can come later if asked for. |
| 8c-5 | Corrections are built for frozen permit records only. People's and organisations' details are changed through their own routes, with the old value kept in the restricted audit log, but without a correction record beside them. Build that in 8d? | **Yes, in 8d**, alongside retention, so that a correction and a disposal of personal data follow the same rules. |

---

## 16. Phase 8d: detailed design (approved 28 October 2026, D-022)

§9 and §10 were approved as principles (P8-13, P8-14). Working out the detail turned up one finding that changes what disposal can achieve, so the detail comes back for approval before any of it is built.

### 16.1 Finding: the audit log keeps a full copy of every record

`audit.capture_row` writes every inserted row in full, and the old and new value of every changed column, into the append-only, hash-chained audit log. Only `person_contact` (email, phone) and `person_pass` (secret, token hash) are redacted. Names, free text, answers, notification bodies, document titles and restriction grounds are all copied there permanently.

- **Consequence:** deleting a record under a retention rule would remove it from Octra's screens but not from Octra. Calling that "disposed" would be a success message masking a partial result (CLAUDE.md §12).
- **Files are different:** evidence files, induction media and packs live in storage, not in the log. Removing a file is real disposal.
- **CLAUDE.md §3** defines `audit_event` as actor, acting capacity, action, target, timestamp and reason where required. It does not ask for record contents. The full-row copy was a phase 1 choice, not a requirement.

**Proposal [8d-1]:** from this migration on, a row event records:
- the action, target, actor, capacity and time (unchanged);
- which columns changed, by name;
- the reason, from the record's reason columns (accountability; History and packs already read it from here);
- a SHA-256 of the row's content, keyed with a random value held per record in a separate table. While the record exists, anyone verifying can show it matches what was recorded. Once the record and its key are disposed of, the digest reveals nothing.

Nothing else from the row. The hash chain is unchanged. Pre-pilot data is reset, so no existing log is rewritten.

Effects:
- **Old values of live records** are no longer recoverable from the log. Where an old value matters, it is kept on purpose in a record of its own, under the same retention as its parent: a correction (8c-5, below) or a version row, as frozen records already are.
- **Reasons stay in clear.** They are why decisions were made. A restriction's grounds therefore remain in the log; they are already withheld from anyone outside the venue's side.

### 16.2 Retention schedule

- **Per venue** (Q218: the venue is assumed to be controller). A venue configuration document of kind `retention`: drafted and proposed by a tenant administrator, approved or rejected by an appointee holding `retention.approve`, never its author or proposer. The existing configuration routes are reused; only the approving action differs.
- **Each rule:** a category, a period in whole days (1 to 36,500), and the source or note the venue relies on. The trigger event is fixed per category (Q222) and shown beside it. There is no default and no suggested period; a category without a rule is kept, and the retention page says so (CLAUDE.md §9).

| Category | Trigger (Q222) | What disposal does | Never disposed while |
|---|---|---|---|
| Gate scans and entry evaluations | The scan | Deletes them | Named by a kept visit, outage exception or open reconciliation |
| Offline manifests, manual fallback entries, reconciliation exceptions | The exception resolved, or the manifest's end if none | Deletes them | Any exception is unresolved |
| Visits (request, roster, consents, attendance and its scans) | The visit's end, or its refusal, withdrawal or cancellation | Deletes them | A linked work request's job is kept |
| Induction records (attempts, answers, completions) | The completion's expiry or supersession; an unfinished attempt, its last activity | Deletes them | It is the person's current valid completion for the course |
| Notifications and their email records | Sent | Deletes them | |
| Evidence files of people and organisations | The version superseded, expired or rejected | Removes the file; the record keeps its type, dates, review decision and hash | Named by an issue snapshot of a kept permit, or the current version |
| Rejected and infected uploads | The scan or review result | Removes the file; the record and result stay | |
| Closed jobs (work package, permits, snapshots, controls, custody, packs and their files, the job's own documents) | Every permit on the job closed, cancelled, refused or expired with nothing outstanding, or the job withdrawn | Deletes the whole job, including packs | Any permit is not finished, any control is live, or any continuing isolation is still owned |

Not in this phase:
- **Appointments.** Every decision names one: they are the authority record. Kept.
- **People and organisations themselves** (erasure of identity). G11 and Q220.
- **Job runs.** Platform housekeeping, holding no personal data.
- **The audit log** (P8-13).

**Customer-wide records [8d-3].** People's and organisations' evidence files belong to the customer, not a venue. Each one is disposed of only when every venue of the customer has a rule for it and every period has passed (the longest wins). Any venue's `retention.dispose` appointee can confirm.

### 16.3 Disposal

- **Listing.** A job (the existing runner) lists, per venue and category, the records past their period and outside every active hold. It makes a proposed **disposal batch**: category, rule version, period, the records' identifiers and a count. It never disposes. Re-running adds nothing already listed.
- **Holds kept back.** The batch states what each active hold kept back, by matter reference.
- **Confirmation.** An appointee holding `retention.dispose` reviews the batch and confirms or declines it, with a reason. The rule's approver cannot confirm a batch under their own rule (separation of duties). Platform and tenant administrators cannot confirm (invariant 9).
- **Rechecked at confirmation.** Each record is checked again: still past its period, still outside every active hold, nothing live. Anything that no longer qualifies is left and listed as such.
- **How deletion is allowed.** Records are deleted only inside the confirming function. Every core table's delete guard allows a delete only when this transaction holds a confirmed batch that names the row's root record. Any other delete still fails.
- **What is recorded:** the batch, who confirmed it and in which capacity, the count disposed and kept, and each root record's identifier. Never the content. Files are removed from storage by the job runner after the database commit. A file that fails to delete is retried, and shown on the operations page until it succeeds.

### 16.4 Legal holds (§10, unchanged except as stated)

- **Request** (`legal_hold.request`) and **approval** (`legal_hold.approve`, never the requester), both appointments at the venue.
- **The hold:** a matter reference, a reason, a required review date, and a scope.
- **Scope:** any combination of an organisation, a person, a job, a visit and a date range, all of which must match. With none of these, the hold covers the whole venue.
- **Duration:** active from approval until lifted with a reason. Reaching its review date tells the requester and approver (a routine notice), and the hold continues (invariant 10). Renewing sets a new review date.
- **Visibility:** the venue's administrators and holders of these actions. Never contractors.

### 16.5 Corrections to live records (8c-5)

- **What it corrects:** a person's name and date of birth, an organisation's name and registration number, or an evidence file's recorded details (issue and expiry dates, reference).
- **How:** through `api.correct_record`, by a `record.correct` appointee who is neither the person concerned nor whoever recorded the value. The field is changed, and a correction record holds what it said, the correct value, the reason and the evidence.
- **Retention:** the correction is disposed of with its parent.

### 16.6 Authority, screens and proof

- **New actions:**
  - `retention.approve` (appointment, through venue configuration);
  - `retention.dispose`;
  - `legal_hold.request`, `legal_hold.approve` (appointments, not delegable);
  - `retention.list` (service, purpose `job_runner`);
  - `record.correct` reused for live records.
- **Screens:**
  - `/venue/retention`: the schedule; categories with no rule; batches to confirm, with what holds kept back.
  - `/venue/holds`: request, approve, renew and lift.
  - A correction form on the person, organisation and document pages.
- **Proof (pgTAP):**
  - Nothing is listed or disposed of without an approved rule.
  - A hold blocks disposal, including a hold approved between listing and confirmation.
  - A requester cannot approve their own hold.
  - A hold past its review date stays active.
  - The rule's approver cannot confirm.
  - Platform and tenant administrators can neither confirm nor approve.
  - Any other delete still fails.
  - A live job, live control or current induction is never disposed of.
  - The audit log holds no content of a disposed record.
  - Cross-tenant and cross-venue attempts fail.
- **Mutation testing, the end-to-end suite and the browser,** as in earlier phases.

### 16.7 Decisions for this phase

| # | Question | Recommendation |
|---|---|---|
| 8d-1 | Change the audit log, from this migration on, to record actions, actors, columns changed, reasons and a keyed digest, not record contents (16.1)? | **Yes.** Without it, disposal would remove records from view but keep their contents for ever, which is not what Q221, Q222 or Q224 mean by disposal. It matches CLAUDE.md §3's definition, costs nothing pre-pilot, and keeps reasons and the chain. Subject to G11 and the privacy adviser. |
| 8d-2 | The categories, triggers and disposal methods in 16.2, with appointments, identities, job runs and the audit log kept for now? | **Yes.** It covers the high-volume personal data (gate, visits, inductions, files) and the full job, while keeping the authority record intact. |
| 8d-3 | A person's or organisation's files disposed of only when every venue of the customer has a rule that has run out? | **Yes.** A venue without a rule keeps the file (no silent default), and a single-venue pilot is unaffected. |
| 8d-4 | Closed jobs deleted outright, packs included, rather than reduced to a summary? | **Yes.** A summary would itself be personal data with no rule of its own. The disposal batch records that the job existed and when it went. |
| 8d-5 | Build in two commits: (a) the audit change, schedule, holds, disposal of everything except closed jobs, and live corrections; (b) closed-job disposal, which touches about forty tables? | **Yes.** Each commit is complete and tested on its own. |

The following stay open and are not settled here: P8-16 (who holds these appointments at the pilot venue), G11, and every retention period. These periods are the venue's to set, with its privacy adviser.

---

## 17. As built (phase 8d(a), 28 October 2026)

**Implementation.**
- **Migrations:**
  - `supabase/migrations/20261025000058`: the audit log without record contents (8d-1).
  - `…59`: catalogue, categories, the `retention` schedule, legal holds, disposal batches and items, the record of deleted rows, file disposals and the one exception to the delete guard.
  - `…60`: the schedule through the configuration routes, holds, the listing job, confirmation, file removal, disposed files refused, live-record corrections, the operations status.
- **Six new actions** (283 in all):
  - `retention.approve`, `retention.dispose`, `legal_hold.request`, `legal_hold.approve` (appointment, not delegable);
  - `retention.list`, `retention.remove_files` (service, the job runner).
- **Screens:**
  - `/venue/retention`: schedule, draft and approval, batches to confirm, decided batches.
  - `/venue/holds`: request, approve or refuse, renew, lift.
  - Corrections on the organisation page and `/me`.
  - The operations page watches the "retention" job and disposed files still in storage.
  - Links from home and venue administration.
- **Job runner:** a "retention" step lists batches and removes confirmed files from the `documents` bucket.

**Proof.**
- **pgTAP:** `41_retention` (113 assertions); 1,687 in the whole suite, through both runners (the fallback on a database rebuilt from the migrations, and the Supabase runner).
- **Mutation testing:** 44 deliberate weakenings, 43 caught. Two were caught only after tests were added (an undecided visit old enough to matter; a current document long expired). The one missed (`d11`, the "current induction" filter) is equivalent: the listing's own period check already excludes a completion that is still valid.
- **Unit:** 39 passed, with the catalogue test at 283 actions. Typecheck clean. End to end: 7 passed, 1 skipped, as before.

| Area | As built | Note |
|---|---|---|
| Audit log (8d-1) | **What a row event records:** the columns set or changed (names only); the record's reason, in clear (from `reason`, `decision_reason`, `lift_reason` and the like); and a SHA-256 of the row keyed with a random 32-byte key held per record in `audit.record_key`. **What it no longer records:** values. **Checking a record:** `audit.record_matches` says whether a record still matches its last event. A change made outside Octra's routes shows as a mismatch (tested). **On disposal:** the key is deleted with the record, so the digest reveals nothing. **Unchanged:** the chain, decision contexts, status history and every other event. History and packs read reasons as before. | Events written before 0058 keep the contents they recorded: pre-pilot data only. |
| Schedule (Q224, §16.2) | **The document:** venue configuration of kind `retention`, `{rules: {category: {days, basis}}}`, with 1 to 36,500 whole days and what the period is based on. There is no default and no suggested period. **Who:** drafted and proposed by a tenant administrator; approved or rejected by a `retention.approve` appointee, never its author or proposer. The general configuration approver cannot approve it, and nor can any administrator. **The page:** for each category, the trigger, what disposal does, and when a record is never disposed of. A category without a rule reads "No rule: kept". | |
| Categories (8d-2) | Seven: gate scans and entry checks; offline manifests, fallback entries and reconciliation exceptions; visits; induction records; notifications; earlier evidence files; rejected and infected uploads. The triggers and exclusions are as in §16.2. **Earlier files:** a version is excluded while it is current (even long expired), while a permit version or issue snapshot names it, and while a competency relies on it. Closed jobs follow in 8d(b). | See 8d-9 for manifests. |
| Customer-wide records (8d-3) | Documents already belong to a venue, so only notices without a venue are customer-wide. Such a notice is listed only when every venue of the customer has a notifications rule, under the longest, in that venue's batch, and that venue's disposal appointees confirm it. | Narrower than §16.2's "any venue's appointee": see 8d-8. |
| Listing (§16.3) | **What it does:** the job runner lists, per venue and category, the records past their period that no active hold covers, as a proposed batch of up to 2,000. It records how many each hold kept back, by reference and matter, and tells the venue's disposal appointees, except the schedule's approver. **What it never does:** dispose of anything. **Duplicates:** one proposed batch per venue and category; records already proposed, or declined under the same schedule version, are not listed again. **Hold reviews:** an active hold at its review date is notified to its requester and approver, once per review date. | Declined records wait for a new schedule version: see 8d-10. |
| Confirmation (§16.3, invariant 9) | **Who:** a `retention.dispose` appointee who did not approve the schedule the batch follows. Never a tenant or platform administrator, nor another customer. **The decision:** confirm or decline, with a reason. **The recheck:** at confirmation, every record is checked again against its state, the schedule in force now, and active holds. Anything that no longer qualifies is kept, with the reason (tested for all three). **What is kept:** the batch records how many records were disposed of and how many kept; each item keeps its identifier, trigger and outcome; `core.disposal_row` keeps the identifier of every row deleted. Never content. | |
| Deletion | **The guard:** `core.forbid_delete` allows a delete only for a row the confirming transaction has itself written to `core.disposal_row` against a confirmed batch. Any other delete still fails, even as the database owner (tested); so does deleting an audit key or a disposal record. **The order:** dependent rows go first (scans with their check, a visit's attendance, consents, roster and the checks recorded against it, an induction's invalidations, attempt, progress and answers, a notice's email records). | |
| Files | **On confirmation:** a disposed file gets a `file_disposal` record; its document record stays. **Release:** `api.document_access` refuses it ("removed under the venue's retention schedule on …"), and the download route answers 410. **Removal:** the job runner claims removals with a lease, deletes the stored object, and records success or the error for retry. **Visibility:** the operations page shows how many are waiting and why any are failing, without paths. | |
| Legal holds (Q223, §16.4) | **Request and approval:** requested by a `legal_hold.request` appointee, with matter, reason, a review date after today (venue date) and an optional scope (organisation, person, job, visit, activity period: all must match; none means the whole venue). Approved or refused by a `legal_hold.approve` appointee who did not ask for it. **While in force:** active until lifted with a reason. Renewal sets a new review date, kept as its own record. **Reaching the review date** only notifies; the hold stays in force (tested). **Visibility:** the venue's tenant administrators and holders of the retention and hold actions; never contractors (tested). | |
| Corrections to live records (8c-5, §16.5) | `api.correct_record` under a `record.correct` appointment at one of the customer's venues. Never by the person concerned, the people of the organisation concerned, or whoever created the record (tested for self). **Person's and organisation's details** (names, company number) are corrected in place, with a correction record keeping what it said. **An evidence file's recorded details** (issuer, reference, dates) are recorded beside the file and never applied. **Visibility:** shown on the organisation page and `/me` to anyone who can see the record. The audit log records which detail changed, not its values. | Documents: see 8d-6 and 8d-7. |

**Proved in the browser and on the local stack.** The set-up script (outside the repository) created Rhona (retention approver), Dev (disposal officer), Holly (hold requester) and Harry (hold approver), had Cara upload a certificate twice, and back-dated a card, a certificate and the notices by 40 days.
- **The schedule:**
  - The administrator started a draft. A rule of 0 days with no basis was refused in words, with the form kept.
  - A schedule of 30 days for notifications and earlier files was saved and proposed; Rhona approved it.
- **Listing:** the job listed 3 records in 2 batches and disposed of nothing. Cara's first card version was not listed, because the 8c job's permit names it.
- **Rhona's view:** told that someone else confirms.
- **Dev's confirmation:**
  - Dev confirmed both batches: 1 file and 2 notices disposed of.
  - The next run removed the stored object; the document record stayed, and the job log shows both runs.
- **Cara's view:**
  - The old certificate answered 410 with its reason; the current version still downloads.
  - Retention and holds pages tell her they are for the venue's side.
- **Holds:** Holly asked for a hold on Cara Electrical; Harry approved it, and it shows as in force with its review date.
- **Corrections:** Evelyn corrected Cara's family name on the organisation page; it shows with the earlier value. The audit entry holds only the column names and a digest.
- **Phone width:** the retention and organisation pages read without sideways scrolling.

**Fixed during the build:**
- **The delete guard:** it compared a bigint identifier with a uuid; it now compares as text.
- **An expired induction's activity period could run backwards,** which fails as a range; the period is now ordered.
- **Saving the schedule:** the confirmation vanished because the form remounted; it now stays.
- **Test 41:** it counted rows across the whole database, so the Supabase runner, which runs against the local stack with demo data, failed two assertions. It now counts only its own records.

**Not covered:**
- **Closed jobs (8d(b)).**
- **Induction links** (which hold an email address), invitations, passes and person contact records are not categories yet.
- **Old files a competency relies on** are kept while the competency exists.
- **Disposal of a large batch** is not measured; it runs in one transaction of up to 2,000 records.
- **Records with no venue** other than notices are not handled.

### Decisions raised by the 8d(a) build

| # | Question | Recommendation |
|---|---|---|
| 8d-6 | §16.5 said an evidence file's recorded details would be changed. As built, they are recorded beside the file and never applied: a reviewer's decision relied on the details as submitted, and changing an expiry date could extend what the venue accepted without review. The contractor uploads a new version, which is reviewed. Accept? | **Yes.** It keeps invariant 5's intent for reviewed evidence; names and company numbers are still corrected in place. |
| 8d-7 | `record.correct` appointees cannot see contractors' documents (document visibility is unchanged), so in practice document corrections are recorded by people who can see them, such as a reviewer who also holds `record.correct`. Widen document visibility to correction appointees? | **Not now.** Give the reviewers `record.correct` if the venue wants document corrections; widening access to personal documents is a privacy decision (G11). |
| 8d-8 | Notices with no venue are disposed of in the batch of the venue with the longest rule, confirmed by that venue's appointees, rather than any venue's. Accept? | **Yes.** One accountable venue per record; it makes no difference for a single-venue pilot. |
| 8d-9 | An offline manifest lists everyone admissible at that moment, so a hold on any one person keeps the whole manifest. Accept? | **Yes.** A hold should err towards keeping; manifests are small. |
| 8d-10 | A declined batch's records are not listed again until a new schedule version is approved. Should they come back after a period instead? | **Accept for the pilot.** If venues decline for temporary reasons, add a re-listing interval as venue configuration with no default. |
| 8d-11 | Before the pilot, should induction links, invitations, passes and contact records become retention categories? | **Yes, with 8d(b)**, as they hold email addresses; each with its own trigger (link expiry or use, invitation decision, pass revocation, relationship end). |
