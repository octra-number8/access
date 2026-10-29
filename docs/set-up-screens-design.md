# S1 — venue set-up screens: design for approval

**Status:** Approved 28 October 2026 (D-026). Decisions are in §12.
Raised by the P4 build (D-025). The venue set-up page shows "No screen yet" for the pieces below. Each has a tested API that only the seed script has ever called. Until these screens exist, a real venue cannot be set up without a developer, and the P7 rehearsal cannot happen.

Source questions:
- Q13–Q16 (appointments and separation of duties).
- Q20–Q23 (venue onboarding, appointment types).
- Q26–Q31 (organisations, engagements, evidence).
- D-002 (root ceremony), D-007 (separation of duties), D-008 (system scope), D-009 (acknowledgement), D-011 (type versions).

Three things these screens must not do:
- **Administration never becomes authority** (invariant 9, D-002). A tenant administrator *records* a root appointment the duty holder made; they never grant one. Every other appointment is granted by an appointee, under their own appointment, within its scope.
- **The screen never decides.** Choices offered are a convenience. For example, only types the appointer may grant, and only scopes inside the appointer's own. The database re-checks everything and refuses in words.
- **No safety meaning in a state.** "In force" means the appointment is recorded, confirmed and acknowledged. It does not mean the person is competent (CLAUDE.md §1).

---

## 1. What is missing

| Piece | API | Screen | Gap in the API too |
|---|---|---|---|
| Venue staff logins | `create_person`, `link_user_account` | none | **Yes.** Linking needs an auth user that only the platform operator can create. Person invitations work only for contractor organisations. |
| Tenant administrators | `grant_tenant_admin` | none | **Yes.** There is no way to revoke one. |
| Root appointment | record, confirm, revoke | none | No |
| Acknowledging an appointment | `acknowledge_appointment` | none | No. No appointee can acknowledge in the app today, so no appointment made through a screen could come into force. |
| Appointments | grant, revoke | none | No |
| Delegations | grant, revoke | none | No |
| Areas and area kinds | create, retire | none | **Yes.** Retiring checks nothing (§6). |
| System types, systems, links, ownership | create, link, record | none | **Yes.** Systems cannot be retired, and ownership cannot be ended. |
| Events and phases | `create_event`, `add_event_phase` | none | No |
| Document types, review criteria, evidence requirements | create, publish | none | No |

## 2. Split [S1-1]

Three increments, each tested and committed separately, in the order the venue needs them:

- **S1a — people and authority:** staff invitations, tenant administrators, the root ceremony, acknowledgement, appointments, delegations.
- **S1b — places and systems:** areas and kinds, the area retirement checks, system types and systems, area links, the ownership register.
- **S1c — events and evidence settings:** events and phases, document types, review criteria, evidence requirements.

Each increment adds only the API its screens need (§1), with pgTAP, mutation checks, a browser walk-through as each role, and the negative cases in §11.

## 3. Venue staff logins (S1a) [S1-2]

Venue staff are the customer's own people: administrators, appointees and gate staff. Today they exist only if the platform operator creates their login by hand.

Proposed: a third invitation kind, `staff`, sent by a tenant administrator to a person record they have created. It works like the existing person invitation:
- an email link;
- sign-in by email code;
- the privacy notice;
- acceptance, which links the login to that person record.

An invitation grants nothing; the person can sign in and see only what their records allow. It expires, can be cancelled, and is recorded in the audit log like the others.

A tenant administrator can also:
- disable a login (the API exists);
- grant and revoke tenant administration.

Revoking is new [S1-3]. A customer must always keep at least one tenant administrator, and no one can revoke their own role.

## 4. The root appointment (S1a)

The root ceremony (D-002) is a page under Venue administration → Authority. Its steps:

1. **Record (tenant administrator A):**
   - the appointee, and the duty holder who made the appointment;
   - an appointment type version marked root-eligible;
   - permit classes, and scopes (areas, systems);
   - the dates it applies, and when it is due for review;
   - limitations;
   - the reference to the letter of appointment [S1-4].
2. **Confirm (tenant administrator B):** A cannot confirm, and neither can the appointee. B sees exactly what A recorded.
3. **Acknowledge (the appointee):** done on their own "Your appointments" page (§5). Until then it is not in force.

Revoking a root appointment needs a reason and an evidence reference, as the API already requires.

The page shows every root appointment at the venue, with its state in words and who must act next. It is the same wording the set-up page uses.

## 5. Appointments and acknowledgement (S1a)

**"Your appointments"** (on `/me`) is for every person who holds or is offered an appointment. For each appointment it shows:
- its type;
- what it allows, as the action descriptions in plain English (not codes);
- its scope, classes and dates;
- its limitations;
- who appointed them, and under which appointment.

A pending appointment has an **Acknowledge** step with a declaration [S1-5]. Delegations the person holds or has given are listed beside it.

**Granting** is done from an appointee's own appointment, by someone whose appointment allows `appointment.grant`. The form offers:
- **Appointee:** a person of the customer.
- **Type:** only the types this appointment may grant (`grantable_type_ids`), each showing what it allows.
- **Permit classes:** only those in both the type and the appointer's appointment.
- **Scope:**
  - Areas come from the venue's area tree, each with "and everything below it". Only areas within the appointer's own scope are offered.
  - Systems, optionally limited to an area (D-008).
- **Dates:** inside the appointer's own; the end date is required [S1-6].
- **Review date, limitations, and a competence evidence reference.** The reference is required when the type requires it.
- **Acting as:** when the appointer holds more than one appointment that could grant this, they choose which (`acting_appointment_id`). It is recorded on the decision.

Revoking needs a reason. It is offered to anyone whose appointment allows `appointment.revoke` over the appointment's scope; the database decides.

**Delegations** [S1-7] are granted from the delegator's appointment page. The delegate must hold their own in-force appointment (invariant 7). Actions, classes and scope are offered only where both appointments allow them. The delegator, or anyone the API allows, can withdraw a delegation.

## 6. Areas (S1b)

The area tree shows each area's kind and code. A tenant administrator can add a child area and add area kinds.

**Retiring an area [S1-8]** is refused with the reasons listed while anything still depends on it:
- an area below it that has not been retired;
- an open job or permit that names it;
- an isolation, impairment, fire watch or exclusion zone that is not closed;
- an area stop that has not been lifted;
- a gate point in it;
- a current occupation;
- an appointment or delegation in force whose only scope is that area.

Retiring is otherwise a single administrative step. It never touches issued records, which keep the area as it was when they were frozen.

## 7. Systems (S1b)

Tenant administrators can:
- add system types and systems;
- link a system to the areas it serves;
- record ownership (owns, maintains, operates; an organisation, optionally its engagement; dates; an evidence reference).

**New in the API [S1-9]:**
- Retiring a system, refused while an isolation or impairment on it is not closed, or an appointment in force is scoped only to it.
- Ending an ownership record from a date, with a reason.

System types are not retired in the pilot. A type with no systems simply drops off the set-up page.

## 8. Events and phases (S1c)

Tenant administrators can create an event (code, name, dates) and add build, live and breakdown phases within those dates. Entry rules, inductions and work packages already refer to events and phases. No new API is needed.

## 9. Evidence settings (S1c)

Tenant administrators can:
- add document types, each with the level its documents belong to (organisation or person);
- publish review criteria for each type: a versioned list with an owner, an effective date and a change reason;
- define evidence requirements and publish their versions.

These already drive the engagement evidence check, the review page and the permit evidence lists. Nothing gets a default: a venue with no requirements asks for no evidence. The set-up page will list evidence requirements as an item once this screen exists, so that is a visible choice rather than an oversight [S1-10].

## 10. Where the screens live

- **Venue administration → Authority:** root appointments, appointments by type, delegations, tenant administrators, staff invitations.
- **Venue administration → Places and systems:** the area tree, system types and systems, the ownership register.
- **Venue administration → Events.**
- **Venue administration → Evidence settings.**
- **`/me` → Your appointments:** acknowledgement, and what you hold.

The set-up page's "Open" links point to each screen as it is built, and "No screen yet" disappears from the matching items.

Desktop is the main layout (administrators and appointees), but every screen works at 375 px.

## 11. Proof

**Positive:** S1 ends with the full ceremony done from screens alone. A new venue goes from no appointments to an in-force root appointee, who grants an appointment that the appointee acknowledges and then uses. Nothing is seeded.

**Negative, in pgTAP and the browser:**
- A tenant administrator confirming their own recorded root appointment.
- The appointee confirming it.
- Acknowledging someone else's appointment.
- Granting a type outside `grantable_type_ids`.
- Granting a scope, class or date range wider than the appointer's own.
- Self-appointment and self-delegation.
- A delegation wider than either appointment.
- A super-admin recording, confirming or granting anything.
- Retiring an area with a live permit, an open isolation or a gate point.
- Retiring a system with an open isolation.
- Revoking the last tenant administrator.
- A staff invitation accepted by a different email address, or after it was cancelled.
- Cross-tenant reads and writes on every new read.
- Repeating the same request (idempotency).
- Concurrent edits: a stale version is refused.

## 12. Decisions

| Ref | Question | Recommendation |
|---|---|---|
| S1-1 | Split into S1a (people and authority), S1b (places and systems), S1c (events and evidence settings)? | **Yes.** S1a unblocks everything else, because no appointment can come into force without acknowledgement on screen. |
| S1-2 | Add a `staff` invitation kind, so a tenant administrator can give venue staff a login without the platform operator? | **Yes.** Otherwise the operator touches every customer's staff list, which works against invariant 9 and does not scale. |
| S1-3 | Add revoking a tenant administrator, keeping at least one and never revoking yourself? | **Yes.** Offboarding is a security control; today it needs a database change. |
| S1-4 | The letter of appointment: a reference (where the signed letter is kept) or an uploaded file? D-002 says "uploaded"; the build has a reference. | **Reference for the pilot**, with the D-002 wording corrected to match. Uploading would add a new document owner kind, and the venue's own records already hold the signed letter. Revisit with G11. |
| S1-5 | The acknowledgement declaration: fixed product wording, or venue configuration? | **Fixed wording for the pilot:** "I have read the scope and limitations of this appointment and accept it. I will act only within them." The venue's technical authority can ask for its own wording later (Q14). |
| S1-6 | Must every appointment made on screen have an end date? The API allows open-ended ones. | **Yes on screen, for non-root appointments**, with a review date encouraged. Root appointments stay as the duty holder's letter says. It limits forgotten authority; the database rule is unchanged. |
| S1-7 | Delegations in S1a, or later? | **In S1a.** They are part of invariant 7 (a formally delegated equivalent lifting a suspension), and the API and tests already exist. |
| S1-8 | Refuse retiring an area while anything listed in §6 still depends on it? | **Yes.** Retiring today checks nothing, so it could orphan a live control (launch gate). This changes a safety-relevant rule, so it needs your approval. |
| S1-9 | Add retiring a system and ending an ownership record, with the same kind of checks? | **Yes.** Otherwise a removed system stays selectable for isolations and appointments for ever. |
| S1-10 | Add "Evidence requirements" to the set-up page once S1c is built ("None defined" is a valid, visible state)? | **Yes.** |

---

## 13. As built (S1a, 29 October 2026)

**Built**
- Migration `20261025000066_people_and_authority`:
  - Staff invitations: `api.create_staff_invitation`, a `staff` kind naming an existing person, one pending per person. Accepting (`api.accept_invitation`, patched) links the login to that person and does nothing else. The preview names the customer and person; `cancel_invitation` handles the new kind.
  - `api.revoke_tenant_admin`: needs a reason; never yourself (the separation-of-duties floor); never the last current administrator, with revocations serialised per customer so two administrators cannot remove each other at once.
  - Reads: `api.authority_overview(venue)`, `api.my_appointments()` and `api.grant_options(appointment)`. Appointments are summarised in words (scope, classes, dates, who made them and under which appointment, state, next step). "Revoke" is offered only where `authz.capacities` says the database would allow it.
  - The set-up page's root appointment item now links to the Authority page.
- Screens:
  - `/venue/authority`: root appointments (record, confirm, record a revocation); other appointments (revoke where allowed); delegations in force; tenant administrators (add, end); people and logins (add staff, invite to sign in, cancel, disable a login).
  - `/me` → Your appointments: each appointment in words; acknowledging with the fixed declaration (S1-5); delegations received and given (withdraw).
  - `/appointments/[id]`: appointing and delegating from one of your own appointments in force, offering only the types, classes, areas, systems, people and delegates the database would accept. End dates are required on screen (S1-6). An end before the start is refused in words.
  - The invitation page has a staff branch.

**Tested**
- pgTAP `45_people_and_authority` (69 assertions); 12 of 12 deliberate weakenings caught.
- Full suite on the test runner: 1,929 assertions, 0 failures.
- Browser walk-through on a new venue, with no seeded appointments, on the production build: an administrator adds a staff member and invites them to sign in; they accept by email link; the administrator records their root appointment; a second administrator confirms it (the recorder is not offered confirmation); the appointee acknowledges it (refused without the declaration); the appointee appoints a gate supervisor, who acknowledges it; the appointee delegates one action. As an appointee, the Authority page shows no people list and no root form. Checked at 375 px.

**Not built here, or limits**
- The acknowledgement declaration is checked by the app, not the database: `acknowledge_appointment` records the act, as before.
- The venue and its two appointment types for the walk-through were created through the API. The venue page's type form exists, but it cannot set a type's eligible classes or system types; venues themselves have no creation screen (platform set-up).
- After a successful action, a form that disappears took its success message with it (the known 2b feedback gap; fixed 29 October 2026, see phase-2-design.md).

---

## 14. As built (S1b, 29 October 2026)

**Built**
- Migration `20261025000067_places_and_systems`:
  - `core.area_retire_blockers` lists, in words, everything still depending on an area: areas below it not retired; open jobs naming it (not cancelled, and either their window has not passed or a permit is still open); isolations not returned and impairments not restored on a system serving it; fire watches not ended for work in it; exclusion zones not removed; stops not lifted; gate points; current occupations; access visits not ended; restriction windows not ended; keys or passes for it not retired; appointments and delegations scoped to it.
  - `core.system_retire_blockers` does the same for a system: isolations not returned, impairments not restored, open jobs naming it, appointments and delegations scoped to it.
  - `api.retire_area` (patched) and the new `api.retire_system` return those as a refusal with the list (`in_use`). The triggers on `retired_at` refuse the same update by any other path. The venue's root area is refused first.
  - Retiring is one way: an area or system cannot be un-retired.
  - A retired area or system cannot be newly referred to by an appointment or delegation scope, a system link, an ownership record, an isolation, an impairment, a gate point, an exclusion zone, a key or pass, or an occupation. Issued records keep what they named.
  - `api.end_system_ownership`: ends a record from a date after its start, with a reason, recording who ended it; once only, and the ending cannot be moved. Ownership records that cite an engagement must cite that organisation's engagement at the same venue (previously unchecked).
  - `api.places_overview(venue)` for the screen: the area tree in order, kinds, system types, systems with the areas they serve and their ownership records. Readable by the venue's tenant administrators and appointees; only administrators are offered changes and the organisation list.
  - The set-up page's Areas and Building systems items link to the screen.
  - `api.retire_gate_point`: a gate point blocks retiring its area, and there was no way to retire one, so retiring an area with a gate point was a dead end. Scans at a retired gate point were already refused. It cannot be un-retired.
  - Three catalogue actions: `system.retire`, `system_ownership.end`, `gate_point.retire` (tenant administration; no operational authority).
- Screen `/venue/places`: the area tree with add-below and retire on each row; area kinds; each system with the areas it serves, its responsibility records (record, end) and retire; register a system; system types. A refused retirement shows why, what is missing, who can resolve it, and each item in the way. Linked from Venue administration.
- `/venue/entry`: each gate point can be retired. The page also gains a venue chooser: it always showed the first venue, so a second venue's entry set-up and gate points could not be reached (defect fix).

**Tested**
- pgTAP `46_places_and_systems` (66 assertions), on the phase 6b fixture with a live job and an isolation: refusals for areas below, gate points, unlifted stops, open jobs, occupations, appointments, isolations on a serving system; the same for systems; direct updates refused by the database; replays; stale versions; un-retiring; no new references to retired places; ending ownership (reason, dates, once, cannot be moved); citing another organisation's engagement; retiring a gate point and then its area; platform administrator, appointee and other-customer refusals; the read's visibility by role.
- 19 of 19 deliberate weakenings caught.
- Full suite on the test runner: 1,995 assertions, 0 failures. Unit tests: 39. Type check passes.
- Tests 08 and 44 updated: retiring an area an appointment relies on is now a refusal in words, and the set-up items link to the screen.
- Browser walk-through on the production build: as a tenant administrator on the rehearsal venue, add an area kind, an area and one below it; retiring the upper one is refused, naming the area below; register a system type and system, link it to an area, record a maintainer and end the record with a reason. On the demo venue, retiring Hall 1 is refused, naming its open job. Back on the rehearsal venue: a gate point is added in the mezzanine on the Entry page; retiring the mezzanine is refused, naming the gate; the gate point is retired; then the mezzanine and Hall A are retired. As the root appointee the page is read-only. Checked at 375 px.

**Stricter than §6 and §7 said (confirmed 29 October 2026)**
- An appointment or delegation blocks retiring an area if any of its scopes names the area, not only when that is its only scope. This is what 0008 already enforced; it errs towards refusing.
- Access visits, restriction windows, and keys or passes also block retiring an area; open jobs and delegations also block retiring a system.
- Retired areas and systems cannot be newly referred to, and retiring cannot be undone.

**Not built here, or limits**
- System types and area kinds cannot be retired (as §7 said for types); system-area links cannot be removed in the pilot.
- Gate points are managed on the Entry page, not here.
- Retiring a gate point has no checks of its own: devices set up for it simply stop being able to record entry there.
- After a successful action, a form that disappears took its success message with it (the known 2b feedback gap; fixed 29 October 2026, see phase-2-design.md), for example when ending an ownership record.


---

## 15. As built (S1c, 29 October 2026)

**Built**
- Migration `20261025000068_events_and_evidence`:
  - An event phase must fall within its event's dates (§8 said so; nothing checked it). A trigger refuses it on any path; `api.add_event_phase` refuses it in words first.
  - Events and phases must have some length: equal start and end passed the existing checks.
  - Refusals in words, instead of a constraint error, for an event or phase ending before it starts, two phases of the same kind overlapping, and a code already used by an event, document type or evidence requirement. Asking an organisation for a competency is refused in words ("organisations hold documents, not competencies").
  - Review criteria: each criterion needs a code and a label that are not blank, and codes are distinct within a version. A reviewer records one result per code, so a repeated code made the results ambiguous.
  - Reads `api.events_overview(venue)` and `api.evidence_settings(venue)`. Both are readable by the venue's tenant administrators and appointees; only administrators are offered changes. The evidence read offers, as owners of a published version, the customer's current tenant administrators and the venue's appointees in force.
  - Set-up page (S1-10): an "Evidence requirements" item in a new "Organisations and evidence" section. With none in force it says **None defined**, a recorded state of its own, not an open item. It lists document types with no review criteria in force, because their documents cannot be reviewed.
  - No new catalogue actions: these are existing tenant administration actions.
- Screen `/venue/events`: current and coming events with their phases, how many jobs and induction courses refer to each, add a phase, create an event; past events collapsed.
- Screen `/venue/evidence`: evidence requirements with their versions (publish a version putting one in or out of force, with owner, date and reason), define a requirement; document types with the criteria in force and other versions, publish criteria (one per line, pre-filled from the latest version), add a document type; competency types (moved here from `/venue`).
- Both linked from Venue administration.

**Tested**
- pgTAP `47_events_and_evidence` (60 assertions): who may create events, phases, document types, criteria, requirements and versions (platform administrator, appointee and other customer refused); phases outside the event, overlapping, or with no length; codes reused; replays; direct writes refused by the database; criteria with repeated codes or blank labels; asking an organisation for a competency or a person's document; a requirement with no version, then in force, then with a later version; the engagement evidence check following them; the set-up item in each state; the reads by role.
- 17 of 17 deliberate weakenings caught.
- Tests 18 and 44 updated: overlapping phases are now refused in words, and the set-up page has the new item.
- Full suite on the test runner: 2,055 assertions, 0 failures. Unit tests: 39. Type check passes.
- Browser walk-through on the production build as a tenant administrator on the rehearsal venue: add a document type (a repeated code refused in words); publish criteria (two identical lines refused in words, then three criteria published); define a requirement for performing contractors and put it in force; add a competency type; asking service providers for it is refused in words; create an event with build, live and breakdown phases (a breakdown past the event's end, an overlapping build and an end before a start each refused in words). The set-up page shows the requirement in force; on the demo venue it names the "Skills card" document type as having no criteria in force. As the root appointee both screens are read-only. Checked at 375 px.

**Not built here, or limits**
- Events cannot be renamed, re-dated or cancelled on screen, and phases cannot be removed. Dates are fixed because what refers to them relies on them (the notice on the screen says to create the event again).
- Document types and competency types cannot be retired; a requirement is withdrawn by publishing a version that is not in force.
- A version's effective date may be in the past (the API has always allowed it). It does not change past decisions, which record the version they used; the screen defaults to "now".
- Criteria codes are made from each line's wording, so rewording a criterion gives it a new code in the next version.
- After a successful action, a form that disappears took its success message with it (the known 2b feedback gap; fixed 29 October 2026, see phase-2-design.md).

---

## 16. Platform set-up gaps (29 October 2026)

**Built**
- Migration `20261025000069_venue_and_type_setup`: refusals in words for a venue code already used by the customer, a time zone the database does not know, and an appointment type code already used at the venue. Who may do these is unchanged.
- Venue administration → **Create a venue** (tenant administrators, `venue.create`): name, code and time zone (from the full list, Europe/London selected). The notice says the venue starts with its root area only, and that creating it gives no authority there.
- **Appointment type versions**:
  - The form now sets the permit classes and system types appointments of the type may cover, from that venue's own lists. Before this, every version proposed on screen was saved with none, so a new version silently removed any eligibility the previous one had (defect fix).
  - Every field is filled in from the latest version, including which types it may appoint and the root and evidence answers, which previously had to be chosen again each time.
  - Each version lists its permit classes, system types and the types it may appoint.
  - Each type names its venue when an administrator has more than one, since types at different venues can share a name.
- Review page: a root appointee deciding a version sees its permit classes, system types and the types it may appoint, not only its actions.

**Tested**
- Full suite on the test runner, with T-1: 2,075 assertions, 0 failures. Unit tests: 39. Type check passes.
- pgTAP `48_venue_and_type_setup` (16 assertions): platform administrator, other customer's administrator and appointee refused; replay; code and time zone refusals in words; a new venue has its root area only and no appointments; its set-up page opens for the administrator and not for another customer; the type code refusal; eligibility from another venue refused.
- Browser, production build: as a tenant administrator, a venue code clash is refused in words and a venue is created; the rehearsal venue's Authorising Engineer form is filled in from version 1 and offers only that venue's system type; a version adding Fire alarm is proposed and keeps everything else. As the root appointee, the review page shows the version in full.

**Found, then approved and built (T-1, D-027)**
- A venue could be left unable ever to change its appointment types. Direct publication ends with the first root appointment (D-011), and afterwards versions need `appointment_type.approve`, which comes only from an appointment. The rehearsal venue was in this state: its root type allows appointing, not approving types.
- Migration `20261025000070_root_can_approve_types`: recording a root appointment is refused, in words, if its type version does not allow `appointment_type.approve` and no other root appointment in force at the venue does. A trigger, so it holds on every path; existing appointments are untouched.
- Tested in `48_venue_and_type_setup`: refused with no approving root; a type that can approve is accepted; once that root is in force, a further root of the other type is accepted. Disabling the trigger, or ignoring other roots in force, each fails the test. Two fixtures (tests 40 and 44) gave their first root at a second venue a type that could not approve types; they now can.
- For the rehearsal venue, set up a fresh venue with the new screen rather than add a recovery route.

**Not built here, or limits**
- Customers are still created by the platform operator (`customer.create`); there is no screen for that.
- A venue's name and time zone cannot be changed on screen, and venues cannot be closed.
- Venues have only the status "onboarding"; there is no step marking one as live.
