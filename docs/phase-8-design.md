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
