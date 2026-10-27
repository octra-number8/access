# Build phase 7 — gate: design for approval

**Status:** Approved 26 October 2026 (D-020), P7-14 to follow with the venue. Decisions are in §14.
Builds on phases 1–6: appointments and the authorisation service, organisations, engagements, restrictions and evidence, inductions, jobs, and permits through to closure.

Source questions:
- Q120–Q126 (access authorisations) and Q162 (roof access without work), moved here by P6-14.
- Q190–Q197 (the gate decision).
- Q198–Q203 (offline and reconciliation).

Also:
- CLAUDE.md §7 item 7; §8 scenarios 1 and 6; invariant 11.
- The colour rule (D-005).
- The open decision P5 (offline scope).
- 6c-3 (the gate uses the narrowed live scope).
- 6b-2 (operatives who have no account).

All but Q190 are **Requires specialist validation**. Q190, the audiences, cites your earlier direction and is a candidate for Confirmed. As in phases 4–6, this phase builds the machinery and the decision records. It never decides the content. These are venue configuration with no silent default:
- what each audience needs to enter;
- the maximum age of an offline manifest;
- which refusals can never be overridden;
- access purposes and their conditions;
- the outage procedure.

Entry is permission to be in a place at a time. It is never permission to work (CLAUDE.md §1). The gate never shows a permit as a reason to admit, and never shows entry in a way that could be mistaken for permission to work (launch gate).

---

## 1. What phase 7 delivers

**A person arrives at a gate.** The operator scans their pass, or finds them by pass number. Octra evaluates, at that moment, against the live record, whether they may enter that place now. The answer is in words:
- **Admit**;
- **Admit with escort**;
- **Check with [owner]**;
- **Do not admit**.

Each answer has its reasons and who can resolve each one. The operator checks identity, records what they did, and the evaluation and the scan are kept.

**A specifically appointed access authority** can record a documented exception to a refusal, within its scope. Some refusals can never be overridden.

**Visits:** an organisation can ask for an access authorisation. This is a visit, or a series of visits, for a named roster, a purpose, places and times, with conditions. An appointed access authority approves it. It never becomes a work permit. A linked work request can be raised from it.

**When the gate loses its connection,** the device shows a persistent **"OFFLINE — status last updated [time]"** banner. It can look people up in the last manifest it downloaded, but that is never treated as current authorisation (invariant 11). Every entry while offline is a **manual fallback entry**, under the venue's outage procedure. On reconnection, every offline entry is checked again against the live record. Anything that would have been refused, including a suspension after the last sync, becomes a **reconciliation exception** with an owner.

**What it does not do:**
- **Hardware integration.** There are no turnstiles, door controllers or vendor ID scanners. The gate is a phone or tablet browser.
- **Biometrics, or photographs taken by Octra** (see P7-4).
- **Notifications.** For example, telling a suspension's owner that someone was admitted offline (phase 8, P6-13). The exception is shown with its owner; nothing is sent.
- **Visitor management for the public, delegates or attendees.** Q190 limits the gate to contractor operatives, event crews and exhibitors.

Proposed split **[P7-1]**:
- **7a:** entry rules, passes, the eligibility evaluation, scan events and overrides (database, API, tests).
- **7b:** access authorisations and visit attendance.
- **7c:** screens: the gate (phone first), the person's own pass, the entry rule and visit screens.
- **7d:** offline: the manifest, manual fallback, reconciliation, and the gate device's offline mode.

---

## 2. Who the gate decides for (Q190)

**Audiences.** Contractor operatives, event crews and exhibitors. In the data, each is a person with an active relationship to an organisation that has an engagement at the venue. The audience comes from the engagement's capacity (performing contractor, principal contractor, service provider, promoter, exhibitor) and the relationship kind. Venue staff and visitors outside these audiences are not decided by Octra. If they are scanned, the result is "Check with the control room", with no record beyond the scan.

**A person's reason to be there now** (Q191). One of:
- an active, unrestricted engagement of an organisation they currently work with, covering this venue and time;
- an approved access visit that names them, covering this place and time (7b).

That is a reason to **enter**. Being on a live permit's team is shown only as information for the gate's "cannot join that task" notices (Q194). It is never a reason to admit.

---

## 3. Entry rules (Q191, Q192, P7-2)

What each audience needs is venue configuration, versioned and approved, with no default. It follows the pattern of class configuration: a tenant administrator drafts and proposes, and an appointee holding `entry_rule.approve` approves.

| Setting | Meaning | Default |
|---|---|---|
| Audience | Engagement capacities and relationship kinds the rule applies to | None: a person matched by no approved rule is "Check with the venue's access authority" |
| Required inductions | Course(s) whose completion must be valid at the time of entry | Must be chosen (may be none, stated) |
| Event phases | Whether the rule applies only during an event's build, live or breakdown phase, with different inductions per phase | Optional |
| Escort | Never, always, or for named areas | Must be chosen |
| Areas | The areas this audience may enter; the gate shows them | Must be chosen |
| Never overridable | Refusal reasons no override can set aside, in addition to the fixed floor in §6 | Must be chosen (may be none beyond the floor) |

**Outcomes.** Each reason is computed from the records, never ticked:

| Outcome | When |
|---|---|
| **Do not admit** | No valid pass; no reason to be there now; a required induction missing, expired or invalidated; the person or their organisation is restricted at the venue; the person is deactivated |
| **Check with [owner]** | Only for an actionable condition that does not itself prohibit entry (Q192). For example: no approved rule for the person's audience; an access visit whose escort is not yet recorded; an identity dispute the operator records (Q197). |
| **Admit with escort** | Everything required is in place and the rule or visit requires an escort |
| **Admit** | Everything required is in place |

Each reason names its owner, for example:
- "Induction *Site safety* expired — the person, by completing it";
- "Restricted at this venue — the authority that imposed it".

Colour is only a secondary cue to the words (D-005). The gate never shows a percentage or a score.

**Permits at the gate (Q193, Q194).**
- A suspended permit stops the work, not entry.
- A person removed from a permit's team, or on a permit that is suspended or held, is shown a notice: "Not on the work-at-height permit for WP-00001: cannot join that task", or "WP-00001's work is stopped: do not start it". These are notices beside the entry result, and never change it.
- No permit is ever shown as a green or as a reason to admit.

---

## 4. Passes (Q197, P7-3)

- **Phone pass.** A person signed in on their phone opens `/pass`. It shows a QR code holding a pass reference and a code that changes every 30 seconds. The code is computed in the database from a per-pass secret that never leaves it, so a screenshot is useless within a minute.
- **Card pass.** For people without a smartphone or an account (6b-2), the venue issues a printed card with a static reference, from a tenant administrator's screen. It can be revoked, and a lost card is revoked and reissued.
- Every pass is one person at one venue. Passes can be revoked with a reason, and a revoked pass always gives Do not admit.
- **Manual lookup.** The operator can find a person by pass number when a code will not scan. The lookup is recorded as such.

---

## 5. The evaluation and the scan (Q191–Q197)

- `core.entry_evaluation(person, venue, gate point, at)` is the single place eligibility is decided. It returns:
  - the outcome;
  - the reasons, each with its owner;
  - the basis: the engagement or visit and the rule version;
  - the areas and times allowed;
  - the escort requirement;
  - the notices (§3).

  It reads only current records.
- Every scan writes an append-only `entry_eligibility_evaluation` and a `scan_event`. The scan event records:
  - the gate point and the operator;
  - in or out;
  - how identity was checked (§7);
  - what the operator did (admitted, refused, referred);
  - any override used.
- `visit_attendance` records arrivals and departures against an access visit.
- Scanning needs an appointment holding `gate.operate` for the gate point's area (P7-5). Platform and tenant administrators cannot operate a gate as such (invariant 9).

---

## 6. Overrides (Q195, P7-6)

- Only an appointee holding `gate.override`, covering the gate point's area, can set aside a refusal. The record states:
  - the reason and purpose;
  - its duration: for today, or for a stated period, never open-ended;
  - any escort or area limit.
- An override covers one person and the reasons it names. A new reason arising later is not covered.
- **Fixed floor**, never overridable whatever the configuration:
  - a restriction on the person or their organisation (lifted only through its own route, D-010);
  - a revoked pass;
  - a deactivated person.
- The venue's rule can add reasons to the never-overridable list.
- The operator cannot override their own refusal unless they also hold `gate.override`, and the record names who did.

---

## 7. What the gate shows (Q196, Q197, P7-4)

**Shown:**
- the outcome in words;
- name and organisation;
- the reason they are there (engagement or visit purpose);
- permitted areas and times;
- induction status in words ("Site safety: valid until 12/01/2027");
- any restriction **as a fact without its grounds** ("Restricted at this venue — check with the access authority");
- the escort requirement;
- the permit notices;
- the reasons and their owners.

**Never shown at the gate:** RAMS or method detail, identity documents, contact details, medical information, the grounds of a restriction, or any document.

**Identity.** Octra holds no photographs. The operator checks the person against a photo identity document they show, and records only how identity was checked ("photo ID seen", or "known to the operator") — never the document's details. A mismatch, a shared pass, or a disputed result (Q197) is recorded objectively, admission pauses, and the result is "Check with [access authority]". Photos on passes are a privacy decision (G11) and are not proposed for the pilot.

---

## 8. Access authorisations (Q120–Q126, Q162, P7-7)

A separate, lighter workflow linked to the same organisation, engagement and people records (Q120).

- **Request:** an administrator of an organisation with an active engagement asks for a visit or a visit series. The request names:
  - a roster of the organisation's people;
  - a purpose, from the venue's configured list;
  - the areas;
  - the dates and times;
  - any requested conditions.
- **Purposes** (Q121) are venue configuration, with what each allows and prohibits, for example: escorted survey, visual inspection, measurement, meeting. A purpose never includes work. Roof access without work (Q162) is a purpose whose use the venue's technical authority must approve, with its conditions.
- **Approval** (Q123): by an appointee holding `access.approve` covering every area, never anyone connected with the requesting organisation. Approval can add the conditions in the next bullet. Occupier or landlord consent for their areas, if the venue requires it, is an approval step like a permit's occupier step (reusing the area occupation register, P5-6).
- **Conditions** (Q124): escort (named or by role), keys and passes (custody, 6b), no photography, confidentiality.
- **Repeat visits** (Q126): a series is valid only within its purpose, areas and dates. Each attendance is recorded against it, and nothing renews it automatically.
- **Changes:** the roster can be changed: additions are approved like the original, removals take effect at once. Any change to purpose, areas or dates is a new request.
- **A visit is never converted into a work permit** (Q122). A linked work request can be raised from it, which starts a draft job carrying only the verified organisation, location and visit information.

---

## 9. Offline (Q198–Q203, P5, P7-8 to P7-10)

The pilot scope recommended in P5 is: a read-only manifest with an age warning, the manual fallback log, and reconciliation. A fully offline app is later.

- **Manifest.** When online, a gate device downloads, for its gate point, a manifest of the people expected today. For each person it holds:
  - the evaluation at that moment;
  - the reasons;
  - the areas.

  The manifest is stamped with when it was made and by whom. The device keeps it in the browser. The **maximum age** after which the manifest is unusable is venue configuration with no default (Q198). Past it, the device shows "manifest too old: use the manual procedure only".
- **Offline mode.** When the device cannot reach Octra:
  - It shows the persistent **"OFFLINE — status last updated [time]"** banner, with the manifest's age, the checks it cannot make, and the venue's outage instruction (Q199).
  - Looking someone up shows what the manifest said at that time, labelled as such. Never "Admit".
  - The only action is to record a **manual fallback entry** (Q200): who, as far as known; the organisation; the purpose; who was contacted (supervisor or access authority); the decision the operator took under the outage procedure; the time; any notes. Entries are kept on the device.
  - Issue, acceptance, approvals and changes to eligibility are never possible offline.
- **Outage procedure** (Q201): the venue's own, approved and versioned, and shown on the offline screen. It is led by the control room.
- **Reconnection** (Q202, Q203):
  - Fallback entries upload with their device time and the manifest they relied on.
  - Each entry is evaluated again against the record as it stood at the time of entry.
  - Where the live result would have been different, a **reconciliation exception** is raised for the venue's access administrator: a suspension after the last sync, a restriction, a lapsed induction, or an unknown person.
  - Exceptions about work go to the permit's issuer.
  - Exceptions are resolved with a recorded note, never auto-closed (invariant 10).
  - The suspension's owner must still use the venue's direct route to the supervisor and control room (Q203). Octra shows the exception; it does not send anything (phase 8).

---

## 10. Authority and actions (summary)

About 25 new actions:

| Area | Actions |
|---|---|
| Entry rules | Draft and propose (tenant administrator); approve (appointment). |
| Gate points | Create (tenant administrator). |
| Passes | Issue and revoke a card (tenant administrator); open my phone pass (subject); revoke a pass (appointment). |
| Gate | Operate a gate (appointment, area scope); override (appointment, area scope). |
| Access | Request, change the roster or cancel (organisation administrator, with a venue form); approve or refuse (appointment, areas covered); occupier consent (appointment); record attendance (appointment). |
| Offline | Download a manifest (appointment); submit fallback entries (appointment); resolve an exception (appointment). |
| Configuration | Purposes and outage procedure (tenant administrator draft, appointment approve). |

The negative suite gains:
- a super-admin operating a gate, overriding a refusal or approving a visit;
- an override on a floor reason;
- a scan after a pass is revoked;
- a manifest past its age;
- an offline entry for someone suspended after the last sync, which must create an exception.

---

## 11. Screens (7c, 7d)

| Screen | Who | What |
|---|---|---|
| Gate (`/gate`, phone first) | Gate operators | Choose the gate point. Scan with the camera, or enter the pass number. The result in large words, with reasons, owners and notices. Record how identity was checked and what you did. Request an override (it notifies nobody: it shows who can override). |
| Override | Access authorities | The refusals waiting at their gates, with an override form. |
| My pass (`/pass`) | Anyone with a pass | The changing QR code, and their own entry result now, with its reasons. |
| Passes | Tenant administrators | Issue, print and revoke card passes. |
| Visits | Contractor administrators, access authorities | Request a visit, see its state and attendance, change the roster; the authority's queue to approve. |
| Entry set-up | Tenant administrators, approvers | Entry rules, gate points, purposes and the outage procedure, drafted and approved like class configuration. |
| Offline | Gate operators | The banner, manifest look-up and fallback entry form; reconciliation exceptions for the access administrator. |

Camera scanning uses the browser's built-in barcode reader, where available, with the pass number as the fallback. No new library is needed unless the pilot's devices lack the reader (P7-11).

---

## 12. Proof

**Database (pgTAP), positive and negative:**
- every outcome and reason from §3, each with its owner;
- the fixed floor and the configured never-overridable list;
- an override's scope and expiry;
- passes, including rotation, a reused code, and revocation;
- visit approval, conditions, roster changes and attendance;
- a visit never converting into a permit;
- manifests, fallback entries and reconciliation exceptions, including a suspension after the last sync;
- tenant and venue separation;
- a super-admin blocked at every step.

**End to end:**
- **Scenario 1:** invite a contractor, complete the induction, check entry eligibility, and scan at the gate.
- **Scenario 6:** an outage exercise. The device goes offline, then fallback entries are made, including one for a person suspended after the sync. The device reconnects, and exceptions are raised and resolved.

**Browser:** the gate on a phone, offline mode, a visit, and the person's pass.

---

## 13. What phase 7 leaves

- **Phase 8:** notifications (for example to a suspension's owner after an offline admission), the critical notification class, gate and attendance reports, retention of scan events (venue configuration, Q-series retention, no default) and legal holds.
- **Later:** a fully offline app; hardware integration; photographs on passes (only after G11 and a specific decision).

---

## 14. Decisions needed

| # | Question | Recommendation |
|---|---|---|
| P7-1 | Split into 7a (rules, passes, evaluation, scans, overrides), 7b (access visits), 7c (screens), 7d (offline)? | **Yes.** Each is a tested increment; 7d needs 7a's evaluation and 7c's gate. |
| P7-2 | Entry rules per audience as venue configuration (inductions, event phases, escort, areas, extra never-overridable reasons), drafted by the venue and approved by an `entry_rule.approve` appointee, with no default? | **Yes.** It is the class-configuration pattern; Q191 and Q192 need specialist validation, so the venue's authority owns the content. |
| P7-3 | A phone pass with a code that changes every 30 seconds, plus a revocable printed card for people without a phone or account? | **Yes.** It defeats screenshots without hardware, and covers operatives without accounts (6b-2). |
| P7-4 | No photographs held by Octra for the pilot; the operator checks a photo ID shown in person and records only how identity was checked? | **Yes.** It avoids a new category of personal data before G11; revisit with the privacy adviser if the venue wants photo passes. |
| P7-5 | Gate operators need a `gate.operate` appointment for the gate point's area, so security staff and contractors' security firms are appointed like any other authority? | **Yes.** Invariant 1, and it lets the venue scope a security contractor to its own gates. |
| P7-6 | Overrides only by a `gate.override` appointee, time-limited, naming the reasons they cover, with a fixed floor (restriction, revoked pass, deactivated person) never overridable plus the venue's own list? | **Yes.** Q195. A restriction is lifted through its own route (D-010), never at a gate. |
| P7-7 | Access visits as a separate, lighter workflow (organisation asks, appointed access authority approves, optional occupier consent), never converting into a permit, with a "raise a linked work request" route? | **Yes.** Q120, Q122, Q125. |
| P7-8 | Offline for the pilot: a read-only manifest with a venue-set maximum age, the persistent banner, manual fallback entries only, and reconciliation on reconnection; no offline admission by Octra and no full offline app? | **Yes.** Confirms P5, invariant 11 and Q198–Q200. |
| P7-9 | Reconciliation exceptions go to the venue's access administrator (attendance) and the permit's issuer (work), each resolved with a recorded note, never auto-closed? | **Yes.** Q202, invariant 10. |
| P7-10 | The venue's outage procedure is versioned configuration shown on the offline screen, with no default? | **Yes.** Q201; the venue must have one before the pilot (launch gate). |
| P7-11 | Camera scanning with the browser's built-in barcode reader and a typed pass number as fallback, adding a QR library only if the pilot devices lack the reader? | **Yes.** No new dependency unless needed; check the pilot's devices first. |
| P7-12 | Permits appear at the gate only as notices (excluded from a task, work stopped), never as a reason to admit or a green? | **Yes.** Launch gate: entry must not be mistaken for work permission. Q193, Q194. |
| P7-13 | People outside the three audiences (venue staff, the public) are not decided by Octra: a scan shows "Check with the control room"? | **Yes.** Q190. |
| P7-14 | Gate operators, overrides and visit approvals at the pilot venue: who holds them (security contractor, control room, venue operations)? | **Needs your input**, with the venue. The machinery does not depend on the answer, but the pilot does. |

Still open from earlier phases, and not blocking phase 7:
- **6a-1 to 6d-2:** the phase 6 build decisions.
- **N1:** rigging. **N2:** notice values.
- **G11:** privacy wording. It blocks pilot data, and bears on P7-4.
- **I1, E1.**
- Scheduling of the expiry job.

The Q190 audiences cite your earlier direction and can move to Confirmed when you say so.

---

## 15. As built (phase 7a, 26 October 2026)

Implemented in `supabase/migrations/20261025000045` (catalogue, tables, the evaluation) and `…46` (API). Proved by pgTAP `34_gate` (64 assertions; 1,208 in the whole suite, through both test runners) and by mutation testing. Seventeen of eighteen deliberate weakenings were caught. The one not caught removes a check that a second check repeats: the fixed-floor reasons are not in the overridable list, and the table refuses them too. No screens yet (7c).

| Area | As built | Note |
|---|---|---|
| Entry rules (P7-2) | One versioned document per venue holding every audience. For each audience: engagement capacities, relationship kinds, event phase or none, required inductions, escort (never or always) and areas. Plus the venue's never-overridable reasons. Drafted and proposed by a tenant administrator. Approved by an `entry_rule_version.approve` appointee, never the author or proposer; approval supersedes the previous version. Every setting must be stated; nothing has a default. | Escort by area is not built: escort is never or always per audience. See 7a-2. |
| Evaluation | `core.entry_evaluation(person, venue, gate point)` is the single place entry is decided. **Fixed floor (Do not admit, never overridable):** a deactivated record, a person restricted here, an unknown or revoked pass. A person whose only organisation is restricted is also refused. **A reason to be here:** an active relationship with an organisation holding an active, unrestricted engagement here now. The most favourable matching audience is used (nothing missing first, then without an escort). Missing inductions give Do not admit. No approved rules, or no rule for the role, gives Check with the venue's access authority. | Every reason carries its words, its owner and whether it can be overridden. The result always says it is entry only, not permission to work. |
| Permits at the gate (P7-12) | Notices only: "Not on the X permit for WP: cannot join that task" for someone removed from a live permit's team, and "The X work for WP is stopped: do not start it" for a suspended or handed-back permit. Neither changes the result. | |
| Passes (P7-3) | **Phone:** created by the person, with a 6-digit code from a per-pass secret and the 30-second step; the current and previous codes are accepted. **Card:** issued by a tenant administrator; the token is shown once for printing and only its hash is kept. Neither the secret nor the hash is readable by any user (column grants), and audit redacts them. One live card and one live phone pass per person per venue. Revocation by an appointee or the venue. | A code that does not verify gives Check, never Admit: look up by number and check identity (Q197). |
| Scanning | `scan_entry` reads the code; `lookup_entry` takes a typed pass number. Both need a `gate.operate` appointment covering the gate point's area, and both record the evaluation shown. `record_gate_action` then records direction, how identity was checked, and what the operator did. It is refused when: the result is more than 5 minutes old; the operator is admitting on Do not admit; admitting on Check without a note; admitting with an escort required but no escort named; or admitting without an identity check. One action per scan. | The 5-minute limit is fixed, not venue configuration: it guards invariant 11 rather than expressing a venue choice. See 7a-1. |
| Overrides (P7-6) | By a `gate.override` appointee covering the gate point's area. Never the person, nor anyone working with their organisations. Each names the reasons it covers, a purpose, a reason, an end (never open-ended) and an optional escort. It applies only in that area, only while in force, and never to the fixed floor or the venue's never-overridable reasons, including when the venue adds a reason later. An override with an escort makes the result Admit with escort. | |
| Reads | `api.my_entry(venue)`: a person's own result now, recording nothing (for the pass screen, 7c). `api.phone_pass_code(venue)`: their current code. Gate records are visible to the person themselves, the venue's administrators, and those who operate or override its gates; never to other contractors or another tenant. | |

### Decisions raised by the 7a build

| # | Question | Recommendation |
|---|---|---|
| 7a-1 | Should an operator act on a gate result only within 5 minutes of the scan, fixed in code rather than set by the venue? | **Yes.** It enforces invariant 11 at the gate; a venue that wants it shorter can ask, but it should never be longer. |
| 7a-2 | Escort is "never" or "always" per audience; escort by area (for example plant rooms only) is not built. Is that enough for the pilot? | **Yes, for now.** A plant-room audience with "always" covers it. Revisit with the venue's access matrix (Q123, Q124). |
| 7a-3 | A person with several engagements is admitted on the most favourable one that fully qualifies. Is that right? | **Yes.** Each engagement is a separate, legitimate reason to be there; the gate shows which one it used. |

---

## 16. As built (phase 7b, 26 October 2026)

Implemented in `supabase/migrations/20261025000047` (catalogue, tables, consent) and `…48` (API, the evaluation restated, attendance). Proved by pgTAP `35_access_visits` (45 assertions; 1,253 in the whole suite, through both test runners). Mutation testing caught all fourteen deliberate weakenings, one after a test was made more specific. The gate tests (34) pass unchanged against the restated evaluation. No screens yet (7c).

| Area | As built | Note |
|---|---|---|
| Purposes (Q121, Q162) | A versioned venue configuration document of kind `access_purposes`, with the same draft, propose and approve route as entry rules. The approver holds `venue_config.approve` and is never the author. For each purpose: name, what it allows, what it prohibits, inductions needed (may be none, stated), escort (never or always), and whether an occupier must consent. No visit can be requested until purposes are approved. | The same document type will carry the outage procedure (7d). Roof access without work is a purpose the venue's technical authority defines and approves like any other. |
| Visit request (Q125) | By an administrator of the organisation (or the venue). For a purpose, a description, areas, a window (one visit or a series) and a roster of people who currently work with the organisation. The organisation needs an active, unrestricted engagement covering the dates. Each visit gets an `AV-` reference. | |
| Occupier consent (Q123) | Where the purpose needs it: for every area in the visit that another organisation occupies during it (the area occupation register, P5-6), by an appointee holding `access.consent_occupier` for that area. Given or refused, with a reason. | |
| Approval (Q123, Q124) | By an appointee holding `access.approve` covering every area, never anyone working with the organisation, nor whoever asked. Refused while a consent is pending or refused. A purpose that is always escorted needs the escort named. Conditions recorded: escort, no photography, confidentiality, other. Can also be refused. | |
| Roster (Q125) | Removals take effect at once. People added after approval count only once approved, like the original. | |
| Cancellation | The organisation or venue can withdraw a request or cancel an approved visit; an access authority can cancel an approved one. | |
| At the gate | The evaluation now also accepts an approved visit naming the person, in force now, with the organisation's engagement still active, as a reason to be there. The purpose's inductions apply, and an escort from the purpose or the conditions makes it Admit with escort. The result names the visit, its purpose and conditions, with the notice "Visit only: [allows]. Not allowed: [prohibits]." Admitted scans record arrivals and departures against the visit (`visit_attendance`). | The evaluation was restated in full; its engagement logic is unchanged. |
| Linked work request (Q122) | A job by the visiting organisation at the same venue can be linked to an approved visit. The visit is unchanged and no permit is created: the job follows the normal route. | The screens (7c) will prefill a new job from the visit. |
| Visibility | The requesting organisation, people on the roster, the venue's administrators and appointees. Another organisation (including the occupier) or another tenant cannot see visits. | |

### Decisions raised by the 7b build

| # | Question | Recommendation |
|---|---|---|
| 7b-1 | Attendance is recorded from gate scans only. Should an escort also be able to record arrivals inside the venue, for visits that do not pass a scanning gate? | **Not for the pilot.** Every visit should enter through a gate point. Revisit if the venue has unscanned entrances for visitors. |
| 7b-2 | Can an occupier's representative see the visit they consent to only through their appointment (as a venue appointee), never as their organisation? | **Yes.** The occupier's organisation does not see other organisations' visits (privacy, G11). Its appointed representative sees what they decide. |

---

## 17. As built (phase 7c, 27 October 2026)

The screens for 7a and 7b, plus two read functions in `supabase/migrations/20261025000049`. Proved by pgTAP `36_gate_screens` (11 assertions; 1,264 in the whole suite, through both test runners). Mutation testing caught all five deliberate weakenings, one only after a test was added. Also proved by a browser walk-through on the local stack, as the venue administrator, the access authority (Ava) and the contractor (Cara), described below. The seed adds an access authority (Ava) and a gate operator (Gil). It approves no entry rules or purposes: those were created through the screens.

| Screen | As built | Note |
|---|---|---|
| Gate (`/gate`) | Phone-first. Choose the gate point (skipped when there is one). Type the pass number, or let a handheld scanner type the code; the camera uses the browser's built-in barcode reader where available. The result shows: the outcome in large words, then name and organisation, "permission to be here, not permission to work", the reasons with who can resolve each, why they are here, the areas, the escort, inductions in words, visit conditions, overrides in force and permit notices. Where an access authority could set a reason aside, they are named, with "Octra has not told them". The operator records direction, how identity was checked (never the document's details) and what they did, within 5 minutes. After that, the result is hidden and the operator must scan again. On a Do not admit coming in, the "let them in" option is not offered; the database refuses it anyway. | Colour is a side edge that repeats the words. "Check with [owner]" names who to check with. The operator's own checks, such as an unverified code, say only "Check". |
| Overrides (`/gate/overrides`) | Today's results at the venue's gates not yet let through or refused, with only the reasons that can be set aside offered as choices. Required: purpose, reason, and an end in the venue's time zone (defaults to the end of today; never open-ended). Optional: an escort. Overrides in force are listed with who granted them. | |
| My pass (`/pass`) | Create a phone pass, then a QR code fetched fresh every 30 seconds. If it cannot refresh, the code is hidden after a minute, and the page gives the pass number and asks for photo ID instead. Also the person's own entry result now, from the same evaluation the gate runs, recording nothing. | |
| Card passes (`/venue/passes`) | Issue a printed card. The code is shown once, on a card-sized print layout, and is not kept. Revoke any pass with a reason; revoked passes are listed. | |
| Entry set-up (`/venue/entry`) | The entry rules and visit purposes are drafted, proposed, and shown read-only once proposed or approved, like a permit class configuration. For each audience or purpose: "no inductions" and "no escort" must be chosen explicitly, never inferred from empty boxes. Which refusals can never be overridden must be saved before proposing. Gate points are added here too. | |
| Decisions (`/review`) | Entry rules and purposes to approve or reject, and visits waiting for a decision. | |
| Visits (`/visits`, `/visits/new`, `/visits/[id]`) | Asking for a visit: purpose, with what it allows and prohibits; areas; times in the venue's zone; and a roster from the organisation's people. The visit page shows: occupier consent per area, the decision with conditions, roster changes and approving additions, arrivals and departures, work raised, and withdraw or cancel. | The occupier's name is shown to the venue's side only (P5-6), via `api.access_consents_needed`. |
| Job from a visit (`/jobs/new?visit=`) | Prefilled with the visit's engagement, areas, dates and description. On saving, the job is linked to the visit. If linking fails, the user is taken to the visit with a notice that the job exists but is not linked. | The visit is unchanged and no permit is created (Q122). |

**Proved in the browser:**
- **Entry rules:**
  - Proposing without choosing the never-overridable refusals is refused, with the reason.
  - The author cannot approve their own rules (separation of duties, shown with why, what is missing and who can resolve it).
  - Ava approves.
- **The card:** the printed QR decodes, through the browser's barcode reader, to the exact code.
- **The gate, before rules:** the card gives "Check with the venue's access authority".
  - Recording "let in" on a Check with no note is refused.
  - A referral is recorded.
- **Override:** Ava sets the reason aside until 23:59. A rescan by typed number (lower case) gives Admit, showing the override.
- **The gate, after approval:** Admit on the engagement, here as Contractors, may enter Hall 1. Also checked at phone width.
- **Phone pass:** the QR decodes, and the code changes after 30 seconds. An expired code at the gate gives Check: "The pass code did not verify".
- **Visit:**
  - Cara's first request is refused because it starts before her engagement. Corrected and resubmitted, it is created as AV-000001.
  - Ava's approval without an escort is refused (always escorted). With the escort named and no photography, it is approved.
- **Job from the visit:** prefilled, saved as WP-00001 (a draft needing screening), and linked to the visit.
- **Console:** no errors in the browser console.

**Fixed in this build:** every `ActionForm` cleared what had been typed when an action was refused. React clears a form passed to `action` whatever the result. The form now submits by hand, and clears only on success. This applies across the application.

**Not covered in the browser (proved in pgTAP):**
- Occupier consent: the seed has no occupier representative.
- A visit as the reason for entry: Cara's engagement is the better basis.
- Roster additions after approval.
- Attendance against a visit.

The camera scanner was not exercised: the browser pane has no camera. Its decoding of these codes was proved on the rendered images.

### Decisions raised by the 7c build

| # | Question | Recommendation |
|---|---|---|
| 7c-1 | A QR encoder was written here (byte mode, level M, versions 1–10, about 200 lines, unit-tested and decoded by the browser's reader) rather than adding a library. Keep it? | **Yes.** It avoids a dependency for a small, fixed job. Replace it with a maintained library if passes ever need more. |
| 7c-2 | An operator or authority with two appointments that both cover a gate's area would be asked to choose a capacity, and the gate screens (like every screen so far) cannot pass one. Add capacity choice now? | **Not for the pilot:** give each gate person one covering appointment (the seed does). Add a capacity chooser to the shared form when any role needs two appointments. |
| 7c-3 | Should a phone show its pass while the venue's gate is offline? | **Covered by 7d.** The phone hides a code it cannot refresh. The gate's offline mode is next. |

---

## 18. As built (phase 7d, 27 October 2026)

Implemented in `supabase/migrations/20261025000050` (catalogue, outage procedure, manifests, fallback entries, exceptions) and `…51` (API). Proved by pgTAP `37_offline_gate` (51 assertions; 1,315 in the whole suite, through both test runners). Mutation testing caught all twenty deliberate weakenings, five only after tests were added. Also walked through in the browser. Four new actions: `gate.download_manifest`, `gate.submit_fallback`, `gate.reconcile` and `gate.reconcile_work`, bringing the catalogue to 269.

| Area | As built | Note |
|---|---|---|
| Outage procedure (Q198, Q199, Q201, P7-10) | A venue configuration document of kind `outage_procedure`: the instruction for the offline banner, the steps, and how long a manifest may be used (1–1440 minutes). None of these has a default: proposing without the age is refused with "there is no default". Approved by an appointee, never the author. Edited on the entry set-up page; approved on the decisions page. | Until it is approved, no manifest can be downloaded: an outage means the manual procedure only. |
| Manifest (Q198) | Downloaded per gate point by a `gate.download_manifest` appointee. It covers everyone with an active engagement now, a visit approved for the next day, or a live pass. For each, it holds the live evaluation at that moment (outcome, reasons and owners, areas, escort, notices), their pass numbers, and the work flags. It never contains a pass code, token or secret. Each manifest is recorded with who made it and when. | The device keeps it in browser storage. Downloads are manual: "Download" or "Refresh the manifest" on the gate page (7d-3). |
| Offline mode (Q199, Q200) | The gate switches to offline mode when a scan cannot reach Octra, or when the browser reports it is offline. **Pinned at the top:** "OFFLINE — status last updated [date, time]". **Below:** what cannot be checked, the venue's instruction and steps, the manifest's age and when it stops being usable, and "Try to reconnect". **Look-up** by name or pass number shows "What the manifest said at [time]. Not a current answer", worded as what was recorded then, never "Admit". Past the manifest's age, or with no manifest: "use the manual procedure only", and look-up is hidden. **Manual entry:** name as given, organisation, pass number, purpose, who was contacted and what they said, direction, identity check, what was decided, notes. Entries are kept on the device. | Issue, acceptance, approvals and eligibility changes are never available offline: the offline screen offers none of them. |
| Upload and reconciliation (Q202, Q203) | On reconnection, entries are uploaded by a `gate.submit_fallback` appointee, with the device's time and the manifest relied on. The upload is all or nothing: entries in the future, earlier than their manifest, missing a purpose, a contact or a name, or letting someone through without an identity check are refused with their entry numbers, and the device keeps them. Each entry records whether its manifest was within age. Uploading the same entries again adds nothing. Each admission is checked against the live record when uploaded. **Entry exceptions:** no matching person; a revoked pass; the live record says Check or Do not admit (with its reasons and owner). **Work exceptions:** a permit stopped, or the person removed from its team, since the manifest was made (or at all, with no manifest), owned by the permit's issuer. A refusal or referral raises nothing. | Checked against the record at upload, not reconstructed at the moment of entry: anything that changed between the entry and the upload is raised too (7d-1). |
| Resolution (Q202, invariant 10) | **Entry exceptions:** resolved by a `gate.reconcile` appointee for the gate's area. **Work exceptions:** resolved by a `gate.reconcile_work` appointee for the permit's class and area. Never by the operator who made the entry, nor the person concerned; never by a tenant or platform administrator. A note is required; an exception is resolved once and never closes by time. Others, including contractors at the same venue, are told the exception was not found, so its existence is not disclosed. Reconciliation page: `/gate/reconcile`. | Octra notifies nobody; the page says the suspension's owner must also use the venue's direct route (Q203). |

**Proved in the browser:**
- **Outage procedure:** admin1 drafts it. Proposing without the manifest age is refused ("there is no default"). Ava approves.
- **Manifest:** Gil downloads it. It holds Cara as admit, with her pass number and no codes.
- **Going offline:**
  - With the dev server stopped, a scan switched the gate to offline mode, with the banner, instruction, steps and age.
  - The rest of the outage was continued through the browser's offline event: the dev server reloads the page once its connection drops (see below).
  - Look-up found Cara and prefilled the form. "Let through" with "not checked" was refused on the device, with the input kept.
  - Two entries were recorded: Cara, and an unknown visitor.
- **Reconnection:** two entries uploaded, one exception (no matching person, owned by the access administrator).
- **Resolution:** Gil, the operator, was refused (separation of duties). Ava resolved it with a note.
- **Phone width:** the pinned bar stays in view without covering the form.

**Fixed during the build:**
- The first offline banner was pinned in full and covered the look-up: now only the headline is pinned.
- The manual form did not prefill from a look-up: it now remounts on choosing a person.
- The look-up said "Recorded then: Admit": now neutral wording.
- After upload, the result was hidden by the panel closing: it now stays open.
- Wording ("1 needs", "Photo ID").

**Not covered:**
- **Reloading offline:** the gate page is not available offline. If a device reloads during an outage, the page will not load (no service worker). Entries already recorded stay in the device's storage and upload when the page next loads online (7d-2).
- **Suspension after sync in the browser:** pgTAP proves it end to end through the API (the walk-through had no live permit).
- **Scenario 6 over HTTP:** not automated in the end-to-end suite yet; pgTAP and the walk-through cover it.
- **A device clock set in the future:** its entries are refused on upload until corrected, and the screen shows which entry. There is no way to correct an entry on the device.

### Decisions raised by the 7d build

| # | Question | Recommendation |
|---|---|---|
| 7d-1 | Reconciliation compares each admission with the live record at upload, not as it stood at the moment of entry. Anything that changed in between is raised too. Accept? | **Yes.** It errs towards raising, which is the safe side. Reconstructing the record at a past moment would need history for every rule, and would hide a problem that is live now. |
| 7d-2 | Should the gate page work after a reload during an outage? This needs a small service worker that caches the gate page. | **Yes, before the pilot.** Today the page must stay open through an outage. Until then, the outage procedure should include a paper log. |
| 7d-3 | Manifests are downloaded by hand. Should a gate device refresh its manifest automatically while online, for example every quarter of its permitted age? | **Yes, with the venue's agreement.** Each manifest is a personal-data record (retention in phase 8), so the frequency belongs in the outage procedure. Until then, refresh at the start of each shift. |
| 7d-4 | Work exceptions are resolved by a separate `gate.reconcile_work` action on the issuer's appointment type, scoped to the permit's class and area, rather than by "the issuer" as a person. Accept? | **Yes.** Authority comes from an appointment (invariant 1); the seed adds it to the permit issuer type. |
