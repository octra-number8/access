# Build phase 6 — live controls: design for approval

**Status:** Approved 25 October 2026 (D-019). Decisions are in §15.
Builds on phases 1–5: appointments and the authorisation service, organisations, evidence, inductions, routed work packages, and permits up to **Active**.

Source questions: Q105–Q119 (live changes, suspension, hand-back and closure), Q127–Q134 (hot works and fire watch), Q135–Q141 (impairments), Q142–Q148 (isolations), Q156–Q162 (height, roofs and keys), and the urgent-work questions moved here from phase 5 (Q91, Q92, Q94–Q97, P5-9). Almost all are **Requires specialist validation**. As in phases 4 and 5, this phase builds the machinery and the decision records. It never decides the content: which systems need isolation, fire-watch durations, maximum impairment periods, extension limits, hand-back declarations, weather thresholds and the deadline for a retrospective permit are venue or class configuration that must be chosen, with no silent default (CLAUDE.md §9).

Invariants this phase must make true in the database: 4 (a blocked child blocks its dependent work), 5 (issued evidence is immutable), 6 (material change invalidates dependent authorisation), 7 (suspension lifts only through the owning authority), 8 (hand-back cannot close with controls outstanding, and continuing isolations transfer rather than disappear), 9 (administrators have no operational authority), 10 (time never creates approval) and 11 (cached status is never current authorisation).

---

## 1. What phase 6 delivers

Once a permit is **Active**, everything that happens to the live job is a recorded decision by someone with a current appointment or a defined part in the permit:

- **Stop and resume.** Anyone with a part in the work can stop it. Only the authority that owns the reason for stopping can lift it, after renewed checks and re-acceptance at the workface.
- **Changes while live.** Extensions, worker additions, swaps and exclusions, and material changes that force a reissue.
- **Physical controls.** Isolations, impairments, fire watches, exclusion zones, and keys and passes. Each is its own record with its own owner and lifecycle. A permit that needs them cannot be issued, accepted or resumed until they are applied and proved.
- **Emergency and urgent make-safe work.** It can start on an appointed authority's recorded decision, and must be converted into a full retrospective permit by a configured deadline.
- **Hand-back and closure.** Full or partial. A permit cannot close while any control, custody item, fire watch or child permit is outstanding. A continuing isolation is transferred to a named owner, never dropped.

What it does **not** do:
- Gate entry, scanning, access authorisations and offline gate mode (phase 7, including Q120–Q126 and roof access without work, Q162). A live permit remains separate from permission to enter.
- Sending notifications (phase 8). Notifications the procedures require (Q111, Q137) are **recorded as given** — who told whom, when and how. Nothing is sent automatically, and an unrecorded notification shows as outstanding with its owner.
- The final permit pack and exports (phase 8, Q119). Phase 6 freezes a **close-out snapshot** so the pack has an immutable source.

Proposed split **[P6-1]**:
- **6a:** live permit lifecycle: stop and suspension, resumption, material change and reissue, extension, worker changes, revalidation.
- **6b:** physical controls: isolations (including group isolation and personal locks), impairments, fire watch, exclusion zones, custody items. Wired into issue, acceptance and resumption, which lifts the P5-11 block.
- **6c:** hand-back (full and partial), close-out of expired permits, closure, the close-out snapshot, and emergency work with its retrospective permit.
- **6d:** screens: the supervisor's live permit view (mobile), the controls desk, the issuer's live board, and the hand-back flow.

---

## 2. The live permit state model (CLAUDE.md §4)

Phase 5 has these transitions: `approved_for_issue → issued_awaiting_acceptance → active` and the three `→ expired` transitions. Phase 6 adds:

| From | To | Action | Notes |
|---|---|---|---|
| `active` | `suspended` | `permit.suspend` | Stop-work (§3). Never removes a control. |
| `issued_awaiting_acceptance` | `suspended` | `permit.suspend` | Issued but not yet started work can be stopped too. |
| `suspended` | `active` | `permit.resume` | Only when the owner's lift **and** the supervisor's re-acceptance are both recorded (§3) **[P6-3]**. |
| `suspended` | `submitted` | `permit.reissue_submit` | A material change needs a new version and re-review (§4) **[P6-4]**. |
| `active` | `hand_back_pending` | `permit.hand_back_submit` | §10. |
| `hand_back_pending` | `active` | `permit.hand_back_reject` | Hand-back not accepted; work resumes only if the window is still open. Otherwise the permit expires and a fresh hand-back is required. |
| `hand_back_pending` | `closed` | `permit.close` | Only with nothing outstanding (trigger, §10). |
| `suspended`, `expired` | `hand_back_pending` | `permit.hand_back_submit` | Close-out of a job that stopped or ran out of time (§11) **[P6-10]**. |
| `issued_awaiting_acceptance` | `cancelled` | `permit.cancel_issued` | Issuer only, and only if no control has been applied. |

`active` and `suspended` permits also reach `expired` through the existing expiry job. Expiry ends the authority to work. It does not end the controls, and it does not close the permit (§11).

**Abandoned** is a flag, not a state: `permit_abandonment` (reason, venue authority, time) on a suspended or expired permit. It never closes the permit, never removes a control, and the permit still shows its outstanding duties.

Two changes to CLAUDE.md §4 need approval: Suspended may also go to Submitted for a reissue (P6-4), and Expired may go to Hand-back pending for close-out (P6-10).

---

## 3. Stop-work, suspension and resumption (Q105, Q109, Q110, invariant 7)

**Who may stop work [P6-2].** Stopping work only ever reduces risk, so the right to stop is deliberately wide:
- The permit's supervisor and team members (a defined part in the permit, recorded at issue).
- The issuer and any appointed venue authority whose scope covers the permit's area or class.
- The job's occupier or landlord contact (the job's parties).

Anyone else with access who sees unsafe work must reach one of those people. Q110 remains open for the occupier's exact role.

A stop needs a reason category (configured per venue: unsafe act, change in conditions, control failure, emergency, weather, instruction from an authority) and free text. It applies immediately: the permit moves to `suspended` and any active child permits are suspended with it (stop-work for the whole job).

**Area stop.** An appointed venue authority with `permit.stop_area` can stop every live permit whose area falls within an area, including its sub-areas. This is the route for an emergency or event conflict. Each affected permit gets its own suspension record, which references the area stop.

**Who owns a suspension.** Each `suspension` record names the authority that owns the restricted control: the action and scope needed to lift it. This is derived from the reason, so it cannot be chosen freely:

| Reason | Lifted by |
|---|---|
| Control failure on an isolation or impairment | The system's isolation or impairment authority (appointment scoped to that system) |
| Area stop | The authority that stopped the area, or an equivalent appointment for that area |
| Material change (§4) | Not lifted. It resolves only through reissue. |
| Anything else | The permit class's issuer (an appointment covering the class and area) |

A formal delegation with its own valid appointment counts (invariant 7). The person who stopped the work may lift it only if they hold the owning appointment. That is allowed, because lifting is not approving their own record: the restricted control is the owner's, not the stopper's.

**Required child suspended (invariant 4).** If a required child permit is suspended, the parent Work Approval is suspended too, through a derived decision whose owner is "the child's resumption". The parent's lift is blocked while any required child is not `active`. This adds to the existing `core.wa_children_ready` rule: it now also runs on suspension, not only at issue.

**Resumption [P6-3]** happens in two recorded steps, so the state model stays `suspended → active`:
1. The owner records a **lift**: the reason is resolved, plus any new conditions. The permit stays `suspended` and shows "lift recorded, waiting for the supervisor to re-brief and re-accept".
2. The supervisor **re-accepts** at the workface. They must re-brief the team and acknowledge any new conditions, using the same checks as acceptance in phase 5. These include the readiness checks re-run at that moment:
   - the window is still open;
   - the team is still valid;
   - required controls are still in place and proved;
   - required children are active;
   - there is no restriction clash.

Only then does the permit become `active`. Lifting a suspension never touches the snapshot. A material change goes through §4 instead.

Time never lifts a suspension. An unlifted suspension stays on the owner's queue with its age (invariant 10).

---

## 4. Material change and reissue (Q105, invariant 6)

Phase 5 refused `revise_work_package` once any permit was issued (`permits_issued`). Phase 6 replaces that refusal:

- **The change kind** is still decided by which facts changed (phase 4). Every change to scope, method, organisation, areas, timing, critical personnel or risk is material. There is no "minor amendment" route for these in the pilot **[P6-4]**.
- A material revision of a job with live permits:
  1. suspends every `active` or `issued_awaiting_acceptance` permit, with reason `material_change`;
  2. returns unissued permits to draft (as in phase 5).
- **Reissue.** The applicant amends the permit and submits a new version (`suspended → submitted`). The approval route runs again. Each step shows its decision on the previous version, as P5-7 already does. The permit is then issued again, which creates a new snapshot linked to the previous one, and is accepted again.
- **Controls stay attached to the permit throughout.** A reissue does not remove an isolation. Whoever reissues must confirm each linked control still matches the new scope. A control that no longer applies must be removed or transferred through its own lifecycle, not dropped.

The changes that are **not** reissues each have their own controlled route:
- extension (§5);
- worker changes (§6);
- the job's administrative title and contact.

---

## 5. Extension (Q108, Q116)

- **Who.** An issuer with `permit.extend` for the class and area. Not the applicant, and not the supervisor.
- **Limits** come from the class configuration `extension: {max_count, max_total}`, which must be chosen for each class. A class that has not chosen limits cannot be extended at all **[P6-5]**.
- **Within the job.** An extension cannot go beyond the job's planned window; going further needs a job revision.
- **No backdating.** It can only be made while the permit is `active` or `suspended` and before the window ends. Once a permit has expired it cannot be extended (time passing never creates approval).
- **Checks.** The extension re-runs the time-dependent issue checks against the new end:
  - inductions, competencies and engagement evidence still valid;
  - restriction windows;
  - the working calendar;
  - each required child's window;
  - notice (with no exception route for extensions) **[P6-5]**.
- **Record.** It produces an extension decision and an **addendum snapshot**, which is linked to the issue snapshot and records the new end, the reason and the checks. The original snapshot is never modified. The supervisor acknowledges the extension before the extended time counts. Required child permits are not extended automatically: each is extended on its own decision.

---

## 6. Worker changes (Q106, Q107)

- **Add.** The supervisor adds a person.
  - They must pass the same per-person checks as at issue, at that moment: still with the organisation, unrestricted, the class's inductions and competencies valid to the end of the window.
  - They count as part of the team only once the supervisor records that they have been briefed. Until then they appear as "added, not briefed".
  - Whether an addition also needs the issuer's approval is class configuration `worker_add: supervisor | issuer_approval`, which must be chosen **[P6-6]**.
- **Swap.** A removal plus an addition, recorded together.
- **Exclude.** The supervisor, the issuer or a venue authority covering the area can remove a team member immediately, with a reason. The permit does not need to be suspended (Q107), unless the exclusion leaves the team below a minimum the class requires.
- **Supervisor change.** The supervisor counts as critical personnel. Changing them needs an issuer's decision **and** acceptance by the new supervisor (re-brief, acknowledge conditions). The permit is suspended between the two, so there is never a live permit without an accepted supervisor. This does not require a full re-review **[P6-6]**.

The team history is append-only. A removed member keeps their record with the time and the reason.

---

## 7. Revalidation (Q112)

Classes can require a periodic confirmation through `revalidation: none | {every, at_shift_start}`, which must be chosen. The supervisor confirms that the work, conditions and controls are unchanged. For weather-sensitive classes they also record the conditions checked against the class's thresholds (Q158). Those thresholds are configuration, with no default.

When a revalidation is due and missed, the permit is **not** suspended automatically, because a status change needs a decision. The live view, the issuer's board and the read API all say "Revalidation overdue — work must not continue until the supervisor confirms", with the owner and how long it has been overdue. In phase 7 the gate treats an overdue revalidation as "Check with [issuer]". **[P6-7]**

---

## 8. Physical controls (Q118, Q130–Q148, Q160)

Each control is its own record with its own owner, lifecycle and version column. It is linked to permits rather than owned by them, so it can outlive the permit (invariant 8). Every lifecycle step is a recorded decision through `core.transition()`, with an idempotency key.

**Configuration.** The class configuration's boolean `requires_physical_controls` becomes `physical_controls`, a list of required control kinds, each with the kind's own settings. For example:
- `isolation`;
- `impairment`;
- `fire_watch` with during-work and post-work minimum durations;
- `exclusion_zone`.

Which **systems** a given job isolates or impairs is declared on the permit by the applicant. Reviewers check it. The venue's isolation authority authorises it.

Each settings value must be chosen. Existing class versions are converted by the migration into a list that marks every kind as **not yet chosen**. A class in that state cannot be issued until a new version is approved. That keeps the P5-11 block in place until the venue configures the class **[P6-8]**.

### 8.1 Isolations (Q142–Q148)

Lifecycle: `requested → authorised → applied → proved → in place → removal requested → removed → returned to service`.
Side states: `refused` and `transferred` (continuing, §10).

| Step | Who | What is recorded |
|---|---|---|
| Request | The applicant or supervisor, linked to one or more permits | System and points, reason, the planned window |
| Authorise | An isolation authority: an appointment scoped to the system through the `system_ownership` register. Not the requester. | Isolation boundary and points approved, method, conditions |
| Apply | An authorised person (an appointment with `isolation.apply` for that system) | Isolation certificate reference, lock and key references, lock box, time |
| Prove | A competent person (`isolation.prove`) | Test-for-dead or zero-energy evidence: instrument reference, method, result, time |
| Remove | An authorised person with `isolation.remove` for the system, once nothing that depends on it is live | Locks removed, keys returned |
| Return to service | An authorised person (configurable: witness required or not) | Reinstatement evidence (Q148) |

- **Apply and prove.** Whether the same person may apply and prove, and whether proving needs a witness, is set per system type: `prove_by: same_person_allowed | different_person`, `witness: required | not_required`, both chosen **[P6-9]**.
- **Group isolation (Q145).** An isolation can carry a **personal lock roster**: each worker's lock on and off, with times. Removal is refused while any personal lock is still on.
  - **Absent lock holder (Q146).** If the person who applied a lock is unavailable, the isolation authority can record removing it on their behalf. This needs a reason, a confirmation that the person is not in the area, and the identity of the person who removed it.
  - **No override.** It is never available to a platform or tenant administrator (invariant 9).
- **Dependent permits.** Removal is refused while any linked permit is `active` or `suspended`, or while any other live isolation depends on it.
- **No administrator override** at any step (Q147 register note; invariant 9).

### 8.2 Impairments (Q135–Q141)

Lifecycle: `requested → authorised → impaired → reinstatement tested → restored`.
Side states: `refused`, `overdue` (computed, not a status), `transferred`.

| Step | What is recorded |
|---|---|
| Authorise | System authority (an appointment scoped to the system). System, zones, planned start and end, **maximum approved duration** (from the system type's configuration, must be chosen, no default; Q139), required compensatory measures, required notifications (Q137). |
| Impair | Competent person, actual time. Refused until each required compensatory measure has been recorded as in place by a named person, and each required notification has been recorded as given (who, to whom, how, when). |
| Reinstatement test | Tester and witness: two different people (Q140). Result. |
| Restore | System authority confirms the system is back in service. |

- **Overrunning (Q141).** Passing the planned end or the maximum duration does not restore anything or approve anything. The impairment shows as **overdue**, with its owner, on the controls desk and on every permit linked to it.
- **Extending.** Continuing past the maximum duration needs a fresh authorisation decision, which records a new maximum and a reason (invariant 10).

### 8.3 Fire watch (Q130, Q134)

- **When.** One during the work and one after it. The minimum durations come from the class settings (must be chosen; no default).
- **What is recorded.** The named watcher (a team member or venue staff), the actual start and end, periodic checks if the class requires them, and findings.
- **Closing the post-work watch.**
  - The watcher records the final check.
  - The watch cannot end before its minimum duration has passed, measured from the actual end of the hot work.
  - The permit cannot close while the post-work watch is open (Q134).

### 8.4 Exclusion zones and custody items (Q118, Q160)

- **Exclusion zone.** An area or a described zone, with who set it up and when, and who removed it and when.
- **Custody item.** A per-venue register of keys, passes, roof hatches, lock-box keys and isolation certificates. Each issue and return records the holder, the permit, the time and who handed it over. An item still out blocks hand-back closure, and is shown with its current holder.

### 8.5 Wiring into issue, acceptance and resumption

`core.issue_blockers` replaces the P5-11 block with a real check: every control kind the class requires is linked and in place:
- isolations `proved`;
- impairments `impaired` with their compensatory measures recorded;
- fire watch arranged, with a named watcher;
- exclusion zone set up.

Acceptance and re-acceptance run the same check at that moment.

**Control failure.** A control that fails while in use suspends every permit that depends on it. Examples are a lock found removed or a compensatory measure that has lapsed. The owner of that suspension is the control's authority.

---

## 9. Emergency and urgent make-safe work (Q91, Q92, Q94–Q97, P5-9)

**Starting it.** Emergency work cannot wait for the route. An appointed authority with `emergency.authorise` for the venue and area records an **emergency work decision**. It records:
- which category it is, from the venue's configured definitions (Q91), with no built-in definition;
- why the work could not wait;
- area, systems, organisation, people, and the controls applied at the time.

Work may proceed on that decision. It is a recorded authority, not a permit, and it is shown everywhere as "Emergency work — retrospective permit due [time]".

**The retrospective permit (Q97).**
- **Deadline.** It must be submitted by a deadline set in the venue's configuration, which must be chosen.
- **Contents.** It is a normal permit created from the emergency record.
- **Controls.** Controls applied during the emergency transfer to it.
- **Who reviews.** The normal route reviews it, and the person who authorised the emergency cannot decide its steps (no self-approval).

**Overdue.** Missing the deadline approves nothing. It shows as overdue with its owner (invariant 10).

**Misuse (Q96).** Every emergency decision is listed per organisation and per authority, so repeated use is visible. Thresholds and reporting are phase 8, subject to the pilot.

**Recommendation [P6-11]:** emergency work is in scope for 6c. However, the `emergency.authorise` appointment type should not be created in the seed or the pilot configuration until the technical authority has defined the categories (Q91, Q92). Until then the route exists but nobody holds it.

---

## 10. Hand-back and closure (Q113–Q118, invariant 8)

**Submitting hand-back.** The supervisor submits hand-back:
- the class's **hand-back declaration**, from configuration, which must be chosen (Q113);
- whether the work is complete or incomplete, with what remains;
- the state the area is left in;
- that all workers are out.

The permit moves to `hand_back_pending`.

**Outstanding duties.** The database computes the list from the records, so it is not a checklist anyone can tick:
- isolations not removed or transferred;
- impairments not restored or transferred;
- open fire watches;
- exclusion zones not removed;
- custody items still out;
- child permits not closed;
- personal locks still on.

**Accepting hand-back (Q114).**
- **Who.** An appointment with `permit.hand_back_accept` for the class and area. Not the supervisor who submitted it, nor anyone on the team (no self-approval).
- **Inspection.** Inspection in person or remotely is set by the class configuration `hand_back_inspection: in_person | remote_allowed`, which must be chosen. The method used is recorded.
- **Outcome.** Accepting moves the permit to `closed`. A trigger refuses closure while the outstanding list is not empty, whoever asks. The route is the same for a platform administrator.

**Continuing isolation (Q147).** An isolation that must stay in place after the work does not block closure for ever, and must not disappear. It is **transferred**:
- a new owner, an isolation authority for the system, accepts it with a reason and a review date;
- it is then unlinked from the permit and becomes a separately owned live isolation, which appears on the controls desk.

Impairments that cannot be restored are transferred in the same way, which is where Q141 ends up.

**Partial hand-back (Q115) [P6-12].**
- **A child permit** hands back and closes on its own, while the Work Approval stays live.
- **The Work Approval** cannot close while any child is open.
- **Returning some areas.** The supervisor can hand back areas while work continues elsewhere. This is a recorded narrowing of the live scope, which needs no new approval because the scope only gets smaller. Any control, fire watch or custody item tied to a returned area must be resolved first. The hand-back acceptor accepts the returned areas.
- **Releasing workers** is the exclusion route in §6.

**The close-out snapshot.** Closure freezes a **close-out snapshot** with a SHA-256 hash, like the issue snapshot. It records:
- every issue and addendum snapshot;
- suspensions and lifts;
- team history;
- each control with its full lifecycle;
- custody;
- the hand-back declaration and acceptance.

The final pack and export (Q119) are built from it in phase 8.

---

## 11. Expired, cancelled and abandoned (Q116, Q117)

| Outcome | Meaning | Who |
|---|---|---|
| Closed | Handed back, accepted, nothing outstanding | Hand-back acceptor |
| Cancelled | Withdrawn before any work was authorised, or issued but cancelled before acceptance with no control applied | Applicant (before issue), issuer (after issue) |
| Expired | The window ended before hand-back. The authority to work has ended; controls and duties have not | Expiry job (a service purpose) |
| Abandoned (flag) | A suspended or expired job that will not resume; still has to be closed out | Venue authority |

**Close-out [P6-10].** An expired or suspended permit that has outstanding duties goes through the same hand-back route (`→ hand_back_pending → closed`). Close-out can be submitted by the supervisor, or by the issuer if the contractor has gone. It is accepted by the hand-back acceptor. The closed record keeps "expired before hand-back" or "abandoned".

An expired permit with nothing outstanding and nothing ever applied may stay `expired` as its final outcome.

Until close-out, every such permit appears on the issuer's live board as "Expired — controls outstanding", with each duty and its owner.

---

## 12. Authority and actions (summary)

About 35 new actions, each with exactly one basis, as in phases 4 and 5:

- **Permit, supervisor or team part:** suspend, re-accept, add or brief a worker, revalidate, submit hand-back.
- **Issuer appointment:** extend, lift, approve a worker, change the supervisor, cancel an issued permit.
- **Venue authority:** stop an area, lift an area stop, flag abandonment.
- **System-scoped appointments,** through `authz.capacities` `system_ids` / `covers_all`:
  - isolation authorise, apply, prove, remove, return, transfer accept, remove on behalf;
  - impairment authorise, impair, test, witness, restore, re-authorise.
- **Class appointments:** fire watch, as watcher and the person who records the final check.
- **Hand-back acceptance:** hand-back accept.
- **Emergency:** emergency authorise.
- **Service purpose:** the existing `permit_expiry` covers expiry. No new automated actions are added; nothing automated may suspend, lift, restore or close.

The super-admin negative test is extended to cover suspension lifts, closure, isolation removal and impairment restoration.

**Part-based basis [P6-2].** Actions taken because of a part in the permit (the supervisor and team) use a new basis: **permit part**. It is resolved by `authz.evaluate` from the issued team, never from a job title. Phase 5 resolved acceptance this way, inside the RPC. Phase 6 moves that check into `authz.evaluate`, so there is still one authorisation service.

---

## 13. Screens (6d)

- **Live permit view (mobile, supervisor and team).** Everything CLAUDE.md §6 lists, at a glance:
  - status in words (Active / Stopped — [reason], owner), the exact scope and limits, location, and time remaining in venue time;
  - the team, current conditions, required child permits and their state, and linked controls and their state;
  - emergency contacts;
  - outstanding hand-back duties, and revalidation due or overdue.

  The actions are a large **Stop work** button, re-accept, add a worker, revalidate and hand back. The page shows "Status as of [time]" and refreshes. Every action re-checks the record's version on the server, so a stale page cannot act on old status.
- **Controls desk (isolation and impairment authorities).** Requests to authorise, controls in place by system, overdue impairments, continuing isolations and their review dates, and removals waiting. Actions, owners and deadlines, not counts.
- **Issuer's live board.** Live permits by area, suspensions waiting on this person's lift, extensions requested, expired permits with controls outstanding, hand-backs to accept, and emergency records awaiting a retrospective permit.
- **Hand-back flow.** The declaration, the outstanding list computed by the database, which links each item to its record, and acceptance.

As in phase 5, these use the shared action helper. Every refusal states what is unavailable, why, what is missing and who can resolve it.

---

## 14. Proof

**Database (pgTAP), positive and negative:**
- Suspension:
  - anyone with a part can stop;
  - someone with no part cannot;
  - a stopped parent suspends its children;
  - a suspended required child suspends the parent, and the parent cannot resume until the child is active.
- Lift:
  - only the owning authority or a valid delegate can lift;
  - the stopper without that appointment cannot;
  - a super-admin cannot;
  - a lift without re-acceptance leaves the permit suspended;
  - re-acceptance re-runs the readiness checks.
- Material change:
  - a material job revision suspends live permits;
  - reissue produces a new version and snapshot, with the old snapshot unchanged;
  - controls stay linked.
- Extension:
  - limits are enforced;
  - a class with no chosen limits cannot be extended;
  - there is no extension after expiry or beyond the job window;
  - the checks are re-run against the new end;
  - an addendum snapshot is created.
- Workers:
  - a person failing a check cannot be added;
  - an added person is not part of the team until briefed;
  - a supervisor change suspends the permit until the new supervisor accepts.
- Isolations:
  - each step requires its scoped appointment;
  - the requester cannot authorise;
  - apply and prove follow the system type's setting;
  - removal is refused with a dependent permit live or a personal lock on;
  - removal on behalf of an absent holder is recorded;
  - a super-admin cannot do any step.
- Impairments:
  - impair is refused until compensatory measures and notifications are recorded;
  - the tester and witness must be different people;
  - passing the maximum duration restores nothing and approves nothing.
- Fire watch: it cannot end before its minimum, and closure is refused while it is open.
- Closure is refused with each kind of outstanding duty (one test per kind), including by a super-admin. A continuing isolation transfers and the permit then closes.
- Partial hand-back: a child closes while the parent stays live, and a returned area with an open control is refused.
- Expired close-out runs through hand-back.
- Idempotency on suspension, lift, re-acceptance, extension, worker change and hand-back.
- Concurrent edits on a live permit, an isolation and an impairment are refused by the version check.
- **Suspension after the last device sync.** A re-acceptance, worker addition or hand-back submitted with the pre-suspension version is refused.
- Cross-tenant and cross-venue reads and writes are refused for every new table.
- Mutation testing on the 6a and 6b triggers and RPCs, as in phases 4 and 5.

**End to end:**
- Scenario 5: live suspension or worker change, continuing controls, hand-back, and evidence (close-out snapshot), run on the local stack.
- A hot works permit with a fire watch.
- An isolation permit with a group lock, through to return to service.

**Browser:** a walkthrough of the live view on a phone-sized viewport, the controls desk and the hand-back flow.

---

## 15. Decisions needed

| # | Question | Recommendation |
|---|---|---|
| P6-1 | Split into 6a (live lifecycle), 6b (physical controls), 6c (hand-back, closure, emergency), 6d (screens)? | **Yes.** Each has its own tested increment; 6b depends on 6a's suspension model, 6c on both. |
| P6-2 | Anyone with a part in the permit (team, supervisor), the issuer, a venue authority covering the area, and the job's occupier or landlord parties can stop work — through a new *permit part* basis inside `authz.evaluate`? | **Yes.** Stopping only reduces risk, and a narrow stop right is the more dangerous failure. The part basis keeps one authorisation service. |
| P6-3 | Resumption needs both the owner's recorded lift and the supervisor's re-acceptance (re-brief, readiness re-checked), keeping `suspended → active` as the only resume transition? | **Yes.** Invariant 7 and "renewed readiness checks" both need it. Two people, each accountable for their part. |
| P6-4 | Every material change to a live job suspends its live permits and requires a reissue (new version, re-review with previous decisions shown, new snapshot), with no minor-amendment route in the pilot; this adds `suspended → submitted` to CLAUDE.md §4? | **Yes.** Q105 is unvalidated. Treating everything material as a reissue is the safe default; the technical authority can later approve narrower amendment routes as configuration. |
| P6-5 | Extension by an issuer only, within limits that each class must choose (unchosen = not extendable), never beyond the job window or after expiry, re-running the time-dependent checks with an addendum snapshot? | **Yes.** No silent default (§9). The original snapshot stays untouched. |
| P6-6 | Worker addition by the supervisor, with a per-class choice of whether the issuer must approve; a person counts only once briefed; supervisor change needs an issuer decision plus acceptance by the new supervisor, with the permit suspended between the two? | **Yes.** Never a live permit without an accepted supervisor, and nobody on the team who has not been briefed. |
| P6-7 | Missed revalidation shows "Revalidation overdue — work must not continue" everywhere, without changing status? | **Yes.** A status change needs a decision; the gate (phase 7) treats it as "Check with [issuer]". If the technical authority prefers automatic suspension, that would need its own service purpose and would be the only automatic stop. |
| P6-8 | Replace `requires_physical_controls` with a `physical_controls` list per class; migrate existing versions to "not yet chosen", so they stay unissuable until a new version is approved? | **Yes.** This lifts P5-11 only where the venue has configured the controls, and never silently. |
| P6-9 | Isolation lifecycle as in §8.1, with apply-and-prove and witness rules chosen per system type, a personal lock roster for group isolation, and recorded removal on behalf of an absent holder by the isolation authority? | **Yes,** as the machinery. The rules themselves (Q143, Q145, Q146) are configuration awaiting the technical authority. |
| P6-10 | Expired and suspended permits with outstanding duties close out through the same hand-back route (`expired → hand_back_pending` added to §4), with "expired before hand-back" kept on the record? | **Yes.** Otherwise an expired permit would orphan its controls (launch gate). |
| P6-11 | Build the emergency route in 6c, but create no `emergency.authorise` appointment type in the seed or pilot configuration until Q91 and Q92 are defined? | **Yes.** The machinery can be tested; nobody holds it until a competent owner exists (launch gate, "enabled specialist class"). |
| P6-12 | Partial hand-back includes child permits, returned areas (scope narrowing, accepted by the hand-back acceptor) and worker release? | **Yes.** Q115 names areas. Narrowing scope needs no new approval, but controls in the returned area must be resolved first. |
| P6-13 | Notifications required by the procedures (Q111, Q137) are recorded as given by a person in phase 6, and blocking where the configuration requires them (impairment), with automatic sending deferred to phase 8? | **Yes.** It keeps phase 6 honest about what is sent: nothing. |
| P6-14 | Access authorisations (Q120–Q126) and roof access without work (Q162) move to phase 7 with the gate? | **Yes.** They are about entry, not work, and belong with the gate's eligibility model. |

Still open from earlier phases, and not blocking phase 6:
- **N2:** notice values.
- **N1:** rigging.
- **G11:** privacy wording.
- **I1 and E1.**
- Scheduling of the expiry job at deployment.

All the phase 6 content values listed at the top of this document go to the technical authority. They are listed in the register under their question numbers.

---

## 16. As built (phase 6a, 25 October 2026)

Implemented in `supabase/migrations/20261025000038` (catalogue, states, tables, rules) and `…39` (API). Proved by pgTAP `30_live_permits` (144 assertions; 930 in the whole suite) and by mutation testing: eighteen deliberate weakenings were each caught. One was first caught only indirectly, by the invariant 4 trigger; the database-guard tests now check the exact refusal, so each guard is proved on its own. No screens yet (6d).

| Area | As built | Note |
|---|---|---|
| Permit-part basis (P6-2) | `permit_part` in `authz.evaluate`: the actor must be on the permit's live team in a role the action allows (`core.part_action`). Stop: supervisor or operative. Re-accept, add, brief, remove, acknowledge an extension, revalidate: the supervisor. | Acceptance (phase 5) keeps its `subject` basis against the snapshot's supervisor. A supervisor change goes through suspension and re-acceptance, so acceptance never needs the live team's supervisor. |
| Stopping work | `api.stop_work` picks the route by who is asking: team member (`permit.stop`), administrator of the job's occupier or landlord (`permit.stop_as_party`), or a venue appointee (`permit.stop_as_authority`). A stop always stops the whole job: the stopped permit gets a `stop` suspension, and every other live permit on the job gets a `job_stop` that is lifted with it (derived decisions). Works on issued, active and already-suspended permits. | **Stop categories are fixed in code, not venue configuration** (design §3 said configured): a stop must never be blocked by missing configuration. Categories: unsafe act, change in conditions, control failure, emergency, weather, instruction, other. See 6a-2. |
| Area stop | `api.stop_area` by a `permit.stop_area` appointee for the area: every live permit on a job touching the area or anything inside it. Lifted once, as a whole, by a `permit.lift_area_stop` appointee for the area. | |
| Lifting (invariant 7) | `api.lift_suspension` lifts only a `stop`, by a `permit.lift_suspension` appointee covering the permit's class and every area of the job. Everyone connected with the job is excluded, as at issue (P5-10), so a supervisor cannot lift a stop on their own job. Other kinds say where they are lifted: at the origin, the area stop, by reissue, or by hand-back. Lifting restarts nothing. | |
| Re-acceptance (P6-3) | `api.reaccept_permit` by the live supervisor. Refused, each with who can resolve it, while: any suspension holds; the Work Approval is not active (child); a permit on the job is held (Work Approval); the live checks fail now (window, engagement and evidence, team, inductions, competencies, restrictions); a condition from the snapshot or a lift is unacknowledged; or the re-briefing is not after the latest suspension and lift. Taken on the version the page loaded: a stale page is refused. | Also used for a permit stopped before it was ever accepted: the re-acceptance is then its first acceptance. |
| Database guards | **Invariant 7:** leaving Suspended for Active needs nothing holding and a re-acceptance under the same decision. Leaving it for Submitted needs a material change to be all that holds it. **Invariant 4, live:** a child is Active only while its Work Approval is; a Work Approval is Active only while no permit on the job is held. This is a constraint trigger checked when each decision completes. | Proved by forcing the decision machinery past the API. |
| Material change (invariant 6, P6-4) | `api.revise_work_package` no longer refuses: a material change suspends every live permit (`material_change`, derived decisions); permits not yet issued return to draft as before. A material change cannot be lifted. The permit is prepared and submitted again (Suspended → Submitted), which resolves the suspension (`via = reissue`), runs the full route with the previous decisions shown (P5-7), and is issued under a new snapshot that names the one it replaces. The old snapshot is unchanged. | A stop on top of a material change must be lifted before the permit can be prepared or submitted again. |
| Team after issue (P6-6) | Additions by the supervisor, with the same per-person checks as issue. They count only once briefed, and approved first where the class says an issuer approves (`issuer_approval`). Removal by the supervisor, or by an appointee, with a reason, without suspending the permit. Approval, briefing and removal are each recorded once. The supervisor changes only by an issuer's decision (`api.change_supervisor`): the permit is suspended (`supervisor_change`, lifted by the change itself) until the new supervisor re-accepts. | The design's "minimum team the class requires" is not built: no class sets a minimum. See 6a-3. |
| Extension (P6-5) | `api.extend_permit` by a `permit.extend` appointee; the job's people are excluded. Active or suspended, before the window ends, never while a reissue or hand-back is pending, one pending extension at a time. Within the class's count and total hours, the job's dates, and (for a child) its Work Approval's end. Notice for the extra time is measured from now, with no exception. The organisation, team, inductions, competencies and restrictions are re-checked for the extra time. Each extension is an addendum with its own SHA-256, naming the issue snapshot. The extra time counts only once the supervisor acknowledges it before the current end. | A reissue starts afresh: extensions of the old issue do not carry over. |
| Revalidation (P6-7) | Class configuration chooses `none` or every N hours. Due time and overdue are computed and shown in the permit's detail; nothing changes status. The supervisor records each revalidation, with an optional note on conditions. | "At shift start" (design §7) is not built: Octra has no shifts yet. |
| Configuration | `extension`, `worker_add` and `revalidation` must each be chosen before a class version can be approved. Earlier approved versions lack them, so those classes refuse extensions and additions until a new version is approved. The venue's set-up screen has the three fields. | |
| Expiry | Uses the extended end, and now also expires suspended permits. When a Work Approval ends, its active permits are suspended (`parent_ended`), held until hand-back (6c). | Expiry of a child does not stop its Work Approval. See 6a-1. |
| Reads | `api.permit_detail` adds the live state: window end, suspensions with who lifts each and the lift, lifts awaiting acknowledgement, the live team with each member's state and history, extensions, revalidation, re-acceptances. New read views for every table. Tenant administrators, venue appointees and the permit's own parties see these records; another tenant sees none. | |

Also fixed: on the venue's permit set-up page, a dropdown showed its old value straight after a successful save until the page was reloaded. The form now re-renders from the saved version. This was a phase 5 defect, found while checking the new fields.

### Decisions raised by the 6a build

| # | Question | Recommendation |
|---|---|---|
| 6a-1 | A child permit whose own window ends normally expires without stopping its Work Approval. Is that right? Invariant 4 is enforced live for suspended children, and for expired children only at issue. | **Yes.** A hot-works permit for day one of a three-day job ending is the normal case, not a block on the rest of the job. A child that must outlive its work is extended instead. |
| 6a-2 | Should stop categories be fixed in code (unsafe act, change in conditions, control failure, emergency, weather, instruction, other) rather than venue configuration? | **Yes.** A stop must never depend on configuration being in place. The categories decide nothing about who lifts; the kind of suspension does. |
| 6a-3 | Should a class be able to set a minimum team size that a removal cannot go below? | **Not yet.** Ask the technical authority whether any launch class needs it (for example a rescue cover or a spotter). It can be added later as class configuration. |

---

## 17. As built (phase 6b, 25 October 2026)

Implemented in `supabase/migrations/20261025000040` (catalogue, states, tables, rules) and `…41` (API and wiring). Proved by pgTAP `31_physical_controls` (107 assertions; 1,037 in the whole suite) and by mutation testing: twenty-four deliberate weakenings, all stopped. Twenty-three were caught by the tests. The other weakened the API check that stops a key being issued twice; the database's unique index still refused it. Two assertions were added after the first mutation run let two weakenings through. No screens yet (6d), except the class configuration fields.

| Area | As built | Note |
|---|---|---|
| Class configuration (P6-8) | `physical_controls` is a list: isolation, impairment, exclusion zone, and fire watch (whether during the work, and minutes after). An empty list means none, chosen. It must be present before a version can be approved; the old yes/no flag is refused in new versions. A version without the list, approved before 6b, blocks issue with "has not chosen its physical controls". | Approved versions are immutable, so they are not rewritten: the blocker reads their absence. This replaces the P5-11 block. |
| Rules per system type (P6-9) | `system_control_rule`: immutable versions with an owner, an effective date and a source. **Isolation:** who may prove (the applier, or a different person) and whether return to service is witnessed. **Impairment:** maximum duration, compensatory measures and notifications. None has a default: a system type with no rule cannot have an isolation or impairment authorised. Published by an appointee holding `control_rule.publish` across the venue. | See 6b-1. |
| Isolations (Q142–Q148) | Requested by the supervisor of each linked permit, or an administrator of the performing organisation. The lifecycle is below. Each step is a recorded decision with its own event (certificate, locks, lock box, instrument, method, evidence, witness). Removal is refused while any permit the isolation protects is live, or any personal lock is on. | Steps and authorities are listed in the lifecycle table that follows. |
| Personal locks (Q145, Q146) | Recorded by the holder, or by the supervisor of a linked permit for someone counted on that permit's team, on a proved isolation only. A lock is taken off by the same people. For an absent holder, the isolation authority removes it, with a reason and a confirmation that the holder is not in the area. Each lock is set once and taken off once. | |
| Impairments (Q135–Q141) | Requested and authorised like isolations; authorising records the rule and its maximum. Impairing is refused until every compensatory measure in the rule is recorded in place with a named person, and every notification in the rule is recorded as given (who, how, when, not in the future). The reinstatement test needs a witness who is not the tester; a failed test is recorded and the system stays impaired. Restored only after a passed test. Past its maximum it is **overdue** (computed): nothing is restored or approved, issue, acceptance and re-acceptance are refused, and the controls desk shows it. Only a fresh authorisation with a longer maximum and a reason lets it continue. | Notifications are recorded, not sent (P6-13). |
| Fire watch (Q130, Q134) | Arranged for a permit whose class needs one, with a named watcher, one open watch per phase. The watch during the work starts when the permit is active. The watch after the work cannot end before its minimum, from its actual start. Checks and the final check are recorded with findings. | Recorded by the supervisor on the watcher's word. See 6b-2. Closure waiting for the watch after the work is 6c. |
| Exclusion zones | Set up and removed by the supervisor; removal is refused while the work is issued or active. | |
| Custody (Q118, Q160) | A venue register (tenant administrator), and each issue against a current permit to a named holder, and return, by a `custody.issue` / `custody.return` appointee. An item is out to one holder at a time (also a unique index). | Blocking closure while items are out is 6c. |
| Readiness wiring | `core.control_blockers` is used by issue (replacing P5-11), by acceptance (refused if a control lapsed after issue), and by re-acceptance (through the live checks). The issue snapshot records the controls relied on. | |
| Control failure (design §8.5) | Reported by someone on the team of a protected permit, or a venue authority for the system, for an isolation or impairment in place. Every live job relying on it is suspended: the protected permits are held by the failure (`control_failure`), and the rest of each job by a stop lifted with it. A failed proved isolation goes back to applied and must be proved again. Lifted only by a `control.lift_failure` appointee for the system who is not connected with the jobs, and only once the control is back in place; the lift's conditions are acknowledged at re-acceptance. | See 6b-3. |
| Reads | `api.permit_detail` adds `controls`: what the class needs, what blocks now, and each isolation (with locks and steps), impairment (with its due time and overdue state), fire watch, zone and custody item. `api.controls_desk()` lists live isolations and impairments for those holding control actions at the venue. Read views for every table. Venue administrators and appointees, and anyone who can see a protected permit, can read them; another tenant cannot. | |

Isolation lifecycle:

| Step | Who |
|---|---|
| Authorise or refuse | An isolation authority for the system. Never whoever asked, or anyone connected with the jobs, even if they hold the appointment. |
| Apply | An authorised person. |
| Prove | An authorised person: a different person from the one who applied it, where the rule says so. A test that does not confirm dead or zero energy does not prove it. |
| Remove | The isolation authority. |
| Return to service | The isolation authority, witnessed where the rule says so. |
| Withdraw | The isolation authority, before the isolation is applied. |

Found and fixed while testing: impairing a system was accepted with a notification missing or dated in the future whenever every compensatory measure was recorded. Two lists were being joined, and an empty one made the whole result empty.

### Decisions raised by the 6b build

| # | Question | Recommendation |
|---|---|---|
| 6b-1 | Should isolation and impairment rules be published in one step by an appointed technical authority? The alternative is the two-step draft-and-approve used for class configurations. | **Yes, for the pilot.** Each version has an owner, an effective date and its source, and only an appointee can publish. If the technical authority wants a second person, the class configuration's two-step route can be reused. |
| 6b-2 | Should fire watch starts, checks and the final check be recorded by the supervisor, naming the watcher, rather than signed by the watcher? | **Yes, for now.** Watchers are often venue staff or operatives without an account. Revisit when the gate and mobile work gives operatives a simple sign-in (phase 7). |
| 6b-3 | Should control failure apply only to isolations and impairments? A failed fire watch or a breached exclusion zone would then be an ordinary stop that the issuer lifts. | **Yes.** Those controls belong to one permit and its issuer; system controls belong to the system's authority, which is who must restore them. |
| 6b-4 | Should isolations and impairments be asked for only against permits? Venue-originated isolations (no permit) would come with emergency work and continuing isolations (6c). | **Yes.** It keeps every 6b control tied to the work it protects. |

---

## 18. As built (phase 6c, 26 October 2026)

Implemented in `supabase/migrations/20261025000042` (catalogue, states, tables, rules) and `…43` (API). Proved by pgTAP `32_hand_back` (94 assertions; 1,131 in the whole suite, through both test runners) and by mutation testing: twenty-two of twenty-three deliberate weakenings were caught. The one not caught removes the duty that asks for a completed fire watch after the work. No route can reach that state: hot works cannot be issued without that watch arranged, and an arranged watch that has not finished is already a duty. It stays as a backstop. One test was changed after the first run: it had passed for the wrong reason (the state table, not the closure rule, refused it) and now checks the closure rule's own message. The control authorities of 6b moved into a shared fixture (`_phase6b.psql`). No screens yet (6d), except the class configuration fields.

| Area | As built | Note |
|---|---|---|
| States (CLAUDE.md §4, P6-10) | Active, Suspended or Expired → Hand-back pending (supervisor). Suspended or Expired → Hand-back pending (issuer close-out). Hand-back pending → Closed (accepted), or back to Active, Suspended or Expired (rejected). Issued awaiting acceptance → Cancelled. | Abandoned is a flag (`permit_abandonment`), not a state. |
| Configuration | `hand_back_declaration` (wording) and `hand_back_inspection` (`in_person` or `remote_allowed`) must be chosen before a class version is approved. The venue's set-up screen has both fields. | |
| Hand-back (Q113) | Submitted by the live supervisor, with the class's declaration (hashed), whether the work is complete (and what remains if not), the state of the area, and confirmation everyone is out. Taken on the version the page loaded. A Work Approval is handed back only after the permits under it are no longer issued or active. The reply lists the outstanding duties. | |
| Close-out by an issuer (Q116) | For a stopped or expired permit whose contractor has gone, an appointee holding `permit.close_out_for_issuer` starts the hand-back. The job's people are excluded. Never for an active permit. | |
| Outstanding duties (invariant 8) | Computed by `core.hand_back_duties`, never ticked: an isolation not removed, withdrawn or transferred; an impairment not restored, withdrawn or transferred; a personal lock on; a fire watch not finished, or none completed after hot work; an exclusion zone in place; a key, pass or certificate out; and, for a Work Approval, any permit under it not closed. A permit that expired without ever being accepted, with nothing left, does not block. | |
| Acceptance (Q114) | By an appointee holding `permit.hand_back_accept` for the class and area, never anyone connected with the job, nor whoever submitted the hand-back. Inspection is in person, or remote where the class allows it, and is recorded. Accepting is refused while duties remain. A rejected hand-back goes back to where it was, or to Expired if the window has ended, or to Suspended for a Work Approval with a held permit under it. | |
| Closure guard (invariant 8, invariant 9) | The closing write itself is refused by a trigger while any duty is outstanding, and unless an accepted hand-back is recorded under the same decision. Proved by forcing the decision machinery past the API. Platform and tenant administrators cannot close. | |
| Close-out snapshot (invariant 5) | Frozen on closure with a SHA-256. It contains: every issue snapshot, acceptance and extension; the live record (suspensions, lifts, re-acceptances, team history); controls with every link ever made and each step taken; returned areas; every hand-back and decision; abandonment; any emergency record. | The basis for the final pack (Q119, phase 8). |
| Continuing controls (Q141, Q147) | `api.transfer_control` by an isolation or impairment authority for the system, not connected with the jobs. Only for a control in place, only once no permit it protects is live, never with a personal lock on, and with a reason and a review date. The control stays in place with a named owner (`control_ownership`). Its links end, but are kept in `control_link_record`. `core.control_link` now shows current links only. The controls desk shows the owner and review date, and flags an overdue review. | |
| Partial hand-back (Q115, P6-12) | Areas: the supervisor returns some, never all, of the live areas, only with any exclusion zone and key or pass for them resolved, and one return at a time. The hand-back acceptor accepts or rejects. Accepted returns narrow the live scope (`live_area_ids`). Children close on their own; workers are released by removal (6a). | Area stops and restriction checks still use the job's full areas. See 6c-3. |
| Cancelled (Q117) | An issued permit not yet accepted is cancelled by an appointee holding `permit.cancel_issued`, not connected with the job, with a reason. Refused while any duty is outstanding, including an open permit under a Work Approval. Once accepted, a permit is handed back, never cancelled. | |
| Abandoned (Q117) | A flag with a reason on a stopped or expired permit, by an appointee holding `permit.flag_abandoned`. It closes nothing, removes nothing, and is kept in the close-out snapshot. | |
| Emergency work (Q91, Q92, Q94–Q97, P6-11) | The venue's own categories and retrospective deadline are versioned configuration with no default (`emergency_config.publish`). Emergency work starts on an `emergency.authorise` decision covering every area and system it touches, recording: category, why it could not wait, areas, systems, organisation, people and the controls applied. It gets an `EM-` reference and a deadline. The organisation's administrator (or the venue) links the retrospective job. The emergency's authoriser then counts as one of the job's people, so cannot decide its steps or issue it. `api.emergency_register()` lists every record with whether the retrospective permit is in and whether it is overdue; nothing is approved by the deadline passing. | No `emergency.authorise` appointment exists in the seed (P6-11). See 6c-1. |
| Fire watch | The watch after the work can now start while the permit waits for hand-back, which is when it usually runs. | Found while writing the tests. |

### Decisions raised by the 6c build

| # | Question | Recommendation |
|---|---|---|
| 6c-1 | Should controls applied during emergency work be recorded as text on the emergency record for now? The design had them transfer to the retrospective permit; isolations and impairments would be requested against that permit once it exists. | **Yes, until Q91 and Q92 are defined.** Nobody is appointed to authorise emergency work yet (P6-11). When the technical authority defines the categories, build emergency-owned controls that transfer to the retrospective permit, using the 6c transfer route. |
| 6c-2 | A rejected hand-back goes back to the state it came from, or to Expired if the window has ended, or to Suspended for a Work Approval with a held permit under it. Is that right? | **Yes.** It never restarts work that the record does not support. |
| 6c-3 | Should area stops, restriction checks and the gate keep using the job's full areas after a partial return of areas? | **Yes, for now.** It errs towards stopping. Phase 7's gate should use the narrowed live scope for who may be where. |

---

## 19. As built (phase 6d, 26 October 2026)

Screens for live control. Migration `20261025000044` adds the reads the screens need, venue emergency contacts, and one fix. Proved by pgTAP `33_live_screens` (12 assertions; 1,144 in the whole suite, through both test runners), the unit and end-to-end tests, and a browser walkthrough.

| Screen | Who | What |
|---|---|---|
| Live permit (`/permits/[id]`, phone first) | The supervisor and team; each authority sees its own actions | Status in words, with what it means for the work. What holds the permit and who lifts it. A Stop work form. Scope and limits, live areas, time left in venue time, the team that counts, every condition (including those set when a stop was lifted), linked permits, physical controls and what blocks them, revalidation due, emergency contacts, and who issued it. Actions by role: accept, re-brief and re-accept, revalidate, acknowledge an extension, add, brief or remove a team member, lock on or off, arrange and record fire watches, set up or remove an exclusion zone, ask for an isolation or impairment, report a failed control, hand back all or some areas. Authorities can also lift a stop, extend, approve an addition, change the supervisor, accept or reject a hand-back or a return of areas, cancel before acceptance, and flag a job abandoned. A permit waiting for reissue shows the request form to prepare it again. |
| Home | Everyone | "Your live permits": the permits the person is on the team of, with state, areas and time left, so a supervisor finds theirs on a phone. Links to the new screens. |
| Live board (`/live`) | Venue appointees and administrators | Live permits ordered by what needs action, each with what it needs and who owns it (stops and who lifts them, hand-backs to accept, expired with duties, extensions to acknowledge, revalidation overdue, areas returned). Area stops in force with a lift form. A form to stop an area. Emergency work whose retrospective permit is overdue. |
| Controls desk (`/controls`) | Isolation and impairment authorities, authorised persons, administrators | Each isolation and impairment with the step it is waiting for, and the form for that step. Failures to lift once restored. Personal locks to remove for an absent holder. Taking ownership of a continuing control. Overdue impairments to authorise to continue. The custody register (add, issue against a permit, return). The rules per system type, and a form to publish them. |
| Emergency work (`/emergency`) | Venue authorities, administrators, contractor administrators | The register with each record's retrospective permit state (in, due or overdue, with who acts). Authorising emergency work, only once the venue has defined it. Linking the retrospective job (the contractor). The venue's definitions. The venue's emergency contacts. |

| Area | As built | Note |
|---|---|---|
| Emergency contacts (CLAUDE.md §6) | `venue_emergency_contacts`: immutable versions of venue numbers (label and phone), published by a tenant administrator with a reason. Shown on every live permit to everyone who can see it. Until published, the live view says the venue has not published them. There is no default number. | New configuration. See 6d-1. |
| Reads | `api.my_live_permits()`, `api.live_board()`, and `core.permit_summary` behind both. Personal locks in `permit_detail` now carry the holder, so a holder can take their own lock off. | |
| Fix (6b) | The impairment refusal put its list of missing measures in the `missing` field, overwriting the "what is missing" wording every refusal screen shows. The list now travels as `items`. | Found while wiring the screens; test 31 now checks both. |
| Demo seed | Two demo system types and systems (HV ring, fire alarm panel), a controls authority (Iris) and an authorised person (Alan), demo isolation and impairment rules, demo emergency contacts, and a roof hatch key. The issuer (Ian) can also accept hand-backs and stop or lift area stops. Still no emergency authority, and no emergency definitions (P6-11). | All marked as demo content. |

**Browser walkthrough** (local stack, demo seed). A scratch script, not committed, used the real API to take one job to live permits: Work Approval and work at height active, and an isolation permit waiting on its isolation. Then, in the browser:
- **Cara (supervisor, phone width):** found her live permits on the home page, opened the work-at-height permit, and stopped work. Both permits showed Stopped, with who lifts each stop.
- **Ian (issuer, desktop):** saw both permits on the live board with what each needs, and lifted the stop with a condition.
- **Cara:** re-accepted the Work Approval, then the work-at-height permit, acknowledging the new condition, and handed the work-at-height permit back.
- **Iris (controls authority):** the controls desk showed the isolation as applied, not proved. Proving it was refused, with the full explanation, because her appointment does not cover proving.
- **Ian:** accepted the hand-back, and the permit closed.

The emergency page rendered correctly for a venue with no definitions. No console errors.

Not exercised in the browser, though each has database tests: the team, extension, fire watch, exclusion zone, custody, area return, transfer and emergency forms.

Found and fixed during the walkthrough:
- Wording: who lifts a stop, a lifted condition's origin, and the state between a lift and re-acceptance.
- The home page's links no longer read as part of the live permits list.
- Custody times were shown in the server's time zone.

### Decisions raised by the 6d build

| # | Question | Recommendation |
|---|---|---|
| 6d-1 | Should venue emergency contacts be versioned venue configuration, published by a tenant administrator and shown on every live permit? | **Yes.** CLAUDE.md §6 requires them on the live view, and they are venue numbers, not personal data. The pilot venue should publish them before go-live. |
| 6d-2 | Should a reviewer whose appointment covers areas but not systems be refused a job that names a system? In the walkthrough, the demo technical authority could not review a job naming HV1. | **Keep it strict.** Appoint the pilot's reviewers with the systems they review. An area appointment should not silently cover the building systems in it (D-008). |
