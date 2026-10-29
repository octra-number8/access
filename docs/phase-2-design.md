# Build phase 2 — organisations and people: design for approval

**Status:** Approved 24 October 2026 (D-012). Scanner product deferred to before 2b.
Builds on the phase 1 foundations ([foundations-schema.md](foundations-schema.md)) and decisions D-001 to D-011 ([decisions.md](decisions.md)). Decisions needed are in §9.

Source questions: Q18, Q26–Q40, Q219–Q220. All are Proposed or Requires specialist validation in the [register](requirements-register.md); this phase builds mechanisms, and every number or rule that varies by venue is configuration with no default (CLAUDE.md §9).

---

## 1. What phase 2 delivers

A venue can invite a contractor; the contractor's own administrator sets up their organisation, people and evidence; the venue reviews documents and verifies competencies against declared criteria; and the venue approves the engagement only when the evidence that engagement actually needs is in place. People and organisations can be restricted at a venue, and a restriction has real effects.

**Proposed split (decision P2-1):**
- **2a — database and API**, proved with pgTAP, exactly like phase 1.
- **2b — first screens**: Next.js scaffold, sign-in, invitation acceptance, contractor administration, document upload, reviewer queue. This is the first time a person can complete a workflow end to end, so it also brings in email delivery and file storage.

## 2. Contractor administration (Q28, Q33)

Contractors administer their own organisation. That is still administration, not operational authority (invariant 9).

- New action basis **`organisation_admin`**: a person who is a current accountable administrator of the organisation the record belongs to.
- **`organisation_admin`** table: organisation, person, role (`accountable` / `deputy`), valid window, granted by, revoked.
  - Exactly one current `accountable` administrator; at most one `deputy` (Q28 "a second named administrator for continuity").
  - Changing the accountable administrator: by the current accountable administrator or a tenant administrator, never by Octra support on an unverified request (Q28 risk).
- What organisation administrators can do, for their own organisation only:
  - invite and manage their people's relationships (§3)
  - upload organisation and person documents (§5)
  - declare their people's competencies (§6)
  - see their own engagements, evidence status and review outcomes
- What people can do for themselves (`subject` basis): maintain their name, preferred language and contact details; accept or decline a relationship; declare their own qualifications (Q33).

## 3. Invitations and relationships (Q26, Q27, Q32, Q40)

**`invitation`** — one table, two kinds:

| Kind | Sent by | Accepting it |
|---|---|---|
| `organisation` | A tenant administrator for the venue | Creates (or links, see below) the organisation, makes the acceptor its accountable administrator, and creates a **proposed** engagement |
| `person` | An organisation administrator | Links the acceptor's login to their person record and activates the relationship |

- Columns: kind, customer, venue, organisation (person invitations), capacity (organisation invitations), invitee name and email, **named owner** (Q32), explicit expiry (no default), token hash, status.
- States: `pending` → `accepted` / `declined` / `expired` / `cancelled`; delivery failures are recorded on the invitation (`delivery_failed_at`) without changing state, so it can be reissued.
- The token is never stored, only its SHA-256; acceptance requires the token **and** a signed-in user. Expiry is derived from the date, like appointments.
- **Duplicate organisations (Q26):** if the accepting organisation's company number matches an existing organisation in the customer, acceptance does not merge. It records a `pending_match` that a tenant administrator resolves (link or create new). Nothing about the existing organisation's relationships is disclosed to the acceptor.
- **Reminders** at intervals (Q32's "two and five working days") are venue configuration with no default, and are sent by the notifications phase; until then the owner sees pending and expired invitations.

**Relationships gain a state:** `invited` → `active` → `ended`. A relationship becomes active only when the person accepts it (decision P2-8). Changing employer (Q40) is: the old organisation (or the person) ends the old relationship, the new organisation invites, the person accepts. The new organisation never sees documents the old one owned.

## 4. Engagement approval (Q31) — changes phase 1 behaviour

Today a tenant administrator creates an engagement directly as `active`. Proposed (decision P2-2):

- New initial state **`proposed`**; `engagement.create` and invitation acceptance both create `proposed`.
- New transition `proposed` → `active` by **`engagement.approve`**, an appointment-basis action (a venue compliance authority, configurable through appointment types).
- `engagement.approve` succeeds only when the evidence evaluation (§7) finds every requirement for that engagement satisfied for its dates, and no restriction (§8) applies to the organisation at the venue.
- New transition `proposed` → `withdrawn` (`engagement.withdraw`, tenant admin) for engagements that never start.
- Existing `active` engagements are untouched; the migration changes no rows.

## 5. Documents (Q36, Q37, CLAUDE.md §5)

| Table | Holds |
|---|---|
| `document_type` | Venue configuration: code, label, owner level (`organisation` / `person`), whether review is needed. Versioned with owner and effective date. |
| `document` | Owner (organisation or person), document type, title. A logical document. |
| `document_version` | Immutable. Storage path, SHA-256, media type, size, issuer, reference, declared valid-from and expiry, uploaded by, scan status. A change is a new version. |
| `review_criteria` | Venue configuration, versioned: the declared criteria a reviewer applies to a document type (Q37: received and readable, current, relevant to scope, acceptable for stated purpose). |
| `review_decision` | Immutable. Document version, criteria version, reviewer, acting capacity, outcome (`reviewed_no_further_comments` / `more_information_required` / `not_accepted`), conditions, **scope wording**, decision context. |

- Review is an appointment-basis action, **`document.review`**, scoped to the venue (and later to permit class). It is separate from issuing anything (invariant 2).
- **Separation of duties:** the uploader, and anyone currently related to the owning organisation, cannot review it (decision P2-4).
- Wording is always scoped: "reviewed for [scope] with no further comments". Never "approved", never "verified" (Q37, CLAUDE.md §1).
- **Storage:** a private Supabase Storage bucket. Uploads go through the server, which validates media type and size, computes the hash, and stores the object at `customer/document/version`. Downloads: the server asks `api.document_access(version)`, which applies the same visibility rules as RLS, and only then signs a URL valid for 60 seconds, served as an attachment from the storage domain, never inline from the app's origin.
- **Malware scanning (decision P2-5):** a new version starts `scan_pending` and cannot be downloaded until a scanner records `clean`. `infected` versions are never served.

## 6. Competencies and verification (Q38)

| Table | Holds |
|---|---|
| `competency_type` | Venue configuration: e.g. CSCS card, IPAF, 18th Edition. Versioned. |
| `competency` | Person, type, issuer, number, declared expiry, supporting document version. Declared by the person or their organisation administrator. |
| `competency_verification` | Immutable. Verifier and acting capacity (`competency.verify`, appointment basis), method (`issuer_register`, `original_seen`, `issuer_confirmation`), source checked, holder match, scope, valid until, outcome. |

- Verification is a separate act from document review and from receipt (CLAUDE.md §3). An in-date certificate is not a verification.
- The phase 1 free-text `competence_evidence_ref` on appointments stays, and an appointment may also cite a `competency_verification`.

## 7. Evidence requirements and relevance (Q39)

The rule from CLAUDE.md §7: expiry is judged against actual planned work, area and appointment — never a blanket red person status.

- **`evidence_requirement`** — venue configuration, versioned with owner and effective date: *for* an engagement capacity or an appointment type (later: permit class, area), *require* a document type (reviewed) or a competency type (verified), *held by* the organisation or the person.
- **`evidence.evaluate(subject, decision, window)`** returns one line per applicable requirement: `satisfied`, `missing`, `not_reviewed`, `more_information_required`, `expires_within_window` (with the date), or `scan_pending`, each with who can resolve it.
- It is used by `engagement.approve` and `appointment.grant` in phase 2, and by permits later. Nothing stores a person-level or organisation-level status; there is no column to turn red.
- An expired certificate that no current or planned decision requires produces nothing at all.

## 8. Restrictions on people and organisations (Q18, D-010)

- **`restriction`**: subject (person or organisation), venue, reason, imposing decision, state `active` → `lifted`. A subject may have several, each with its own owner.
- `person.restrict` / `organisation.restrict` and `…lift` are appointment-basis; lifting follows D-010 (owner, equivalent, or owner's delegate; people from the restricted organisation excluded).
- **Effects in phase 2 (decision P2-7):**
  - a restricted person's appointment-based actions at that venue are refused by `authz.evaluate`;
  - a restricted organisation cannot have an engagement approved, an invitation accepted, or a new engagement created at that venue.
  - Gate effects arrive in phase 7.

## 9. Decisions needed

| Ref | Decision | Recommendation |
|---|---|---|
| P2-1 | Split phase 2 into 2a (database and API) and 2b (first screens, email, storage)? | **Yes.** 2a is proved the same way as phase 1; 2b needs P2-5, P2-6 and an email route. |
| P2-2 | Engagements start `proposed` and need an appointment-based approval against evidence (§4)? | **Yes.** Q31 says checks come before engagement; today an administrator can make an engagement active with no checks. |
| P2-3 | Contractor administrators: one accountable plus at most one deputy (§2)? | **Yes**, per Q28. |
| P2-4 | Uploader and anyone in the owning organisation are excluded from reviewing its documents? | **Yes**, extending D-007 the same way D-010 does. |
| P2-5 | Malware scanning: downloads blocked until a scanner records `clean`. Which scanner? | **Block until clean.** Scanner choice needed before 2b; options are a self-hosted ClamAV service or a hosted scanning API. No development bypass in production. |
| P2-6 | File limits (types, maximum size). | Venue-independent platform setting: PDF, JPEG, PNG; 20 MB. Confirm. |
| P2-7 | Person and organisation restrictions have the effects in §8? | **Yes.** A restriction with no effect would be a button that does nothing (CLAUDE.md §12). |
| P2-8 | A relationship becomes active only when the person accepts it? | **Yes.** An organisation should not be able to claim a person, and it gives Q40's employer change a verified step. |
| P2-9 | Appointment type versions: from now on `proposed` → `approved` by an in-force root appointee (D-011)? | **Yes**, as decided; bootstrap path only while a venue has no root appointment. |

Still open from before and not blocking 2a: privacy notice content and the controller/processor split (G11, Q218–Q220) block **pilot data**, not this build. Phase 2a records which notice version a person was shown at collection; the wording must come from the privacy adviser.

## 10. Phase 2a proof (pgTAP)

- Invitation: token required; wrong user, expired, cancelled or reused tokens refused; duplicate company number held for administrator resolution; nothing disclosed about the existing organisation.
- Contractor administrators: can manage only their own organisation; cannot see another organisation's people or documents; cannot approve their own engagement; hold no operational authority.
- Relationships: inactive until the person accepts; employer change does not expose the former organisation's documents.
- Documents: versions immutable; review refused for uploader and the owning organisation's people; review outcome wording is scoped; downloads refused while `scan_pending` or `infected`; cross-tenant and cross-organisation access refused.
- Verification: refused without `competency.verify`; recorded separately from review.
- Evidence evaluation: an unrelated expired certificate produces no warning; a required one blocks approval with a plain reason and owner; an expiry inside the engagement window is reported as such.
- Engagement approval: refused with missing evidence, refused for a restricted organisation, refused for an administrator; succeeds with evidence and appointment.
- Restrictions: a restricted person's appointment-based actions are refused; lifting follows D-010.
- All phase 1 tests still pass.

---

## 11. As built (phase 2a, 24 October 2026)

Implemented in `supabase/migrations/20261024000013…18`; proved by `supabase/tests/10…15` plus the updated phase 1 suite (364 pgTAP assertions in total). Differences from §1–§10, and anything a reviewer should know:

| Area | As built | Note |
|---|---|---|
| Relationship `invited` state | Used only for relationships an administrator records. An invitation *is* the pending consent: accepting it creates the relationship directly as `active`. | Same rule (P2-8): nothing becomes active without the person's acceptance, self or facilitated. |
| Facilitated acceptance | A tenant administrator records it with a note of at least 10 characters saying how it was obtained; never the organisation itself. | Q33/Q34 people without logins. |
| Derived decisions | Accepting an invitation creates the engagement and relationship as child decision contexts (`authz.derive`), each single-use, each audited, linked to the parent. | Lets one request create several state-controlled records without weakening the status guard. |
| Invitation tokens | Generated in the database (two random UUIDs, 244 bits), returned once, stored only as SHA-256; the hash is unreadable to clients even at column level. Acceptance requires the token **and** a login whose email matches. | |
| Privacy notice | Accepting an invitation requires the customer's current privacy notice version to have been shown; the showing is recorded. With no notice published, nobody can accept. | Wording still needed from the privacy adviser (G11); tests use placeholder wording. |
| Duplicate organisation | "Separate" resolution creates the new organisation without the registration number (it must stay unique). | |
| Engagement approval | People working with the organisation are excluded from approving it. | Same rule as D-010. |
| Evidence | Uses the **latest submitted version** of a required document: a newer version awaiting scan or review blocks, even if an older one was reviewed. | **[decide C2]** Conservative; alternative is "best currently reviewed version". |
| Expiry | `expired` (blocking) if it ends before the later of now and the decision's start; `expires_within_window` (reported, not blocking) if it ends during the decision's window. | Q39. |
| Who sees documents | Owner; the organisation's administrators (organisation documents, and person documents they provided while the person stays with them); tenant administrators; holders of `document.review` at a venue where the owner is engaged. Self-provided person documents are shared with no organisation. Not break-glass. | Explicit sharing (Q30, Q220) is later. |
| Contact details | An organisation's administrators can see the contact details of people actively working with them. | **[decide C3]** Privacy adviser to confirm. |
| Review wording | Database check refuses scope wording containing approv-, certif-, verif-, guarant-, complian- or "safe to". | CLAUDE.md §1. |
| Restrictions | Venue-wide only. A restricted person's appointment-based actions at the venue are refused; a restricted organisation cannot be engaged, approved or linked at the venue. | Area-limited restrictions and gate effects are later. |
| Accountable administrator leaving | Ending their relationship ends their role; the organisation then has no accountable administrator until a tenant administrator sets one. | **[decide C1]** |
| Bootstrap publication | Closed once the venue has any root appointment that is not revoked, including one still pending. | D-011. |
| Not built in 2a | Reminders (notifications phase), the upload/download server, the scanner itself, email delivery — all 2b. | |

---

## 12. As built (phase 2b, 24 October 2026)

**Built and tested**
- Migrations `…19_scanner` (leased scan jobs, heartbeats, `rejected`, documents bucket with platform limits, scanner-only storage read of pending files, unambiguous "latest submission" ordering) and `…20_review_wording_message` (plain-language refusal of approval wording).
- Scanner service (`services/scanner`): TypeScript worker plus ClamAV 1.4 (`clamav/clamav-debian`, multi-architecture), pull-based, fail-closed; Fargate task definition and runbook in `infra/aws` (not deployed).
- Next.js 16 app (`src/`): sign-in by 6-digit email code; invitation preview and acceptance with the privacy notice; venue administration (invite an organisation; invitations; engagements with the evidence each needs); a contractor's organisation page (engagement evidence, documents, upload, invite people); a decisions page for appointees (document review against declared criteria, engagement approval); downloads only through `api.document_access` and 60-second attachment links.
- Every refusal on screen states what is unavailable, why, what is missing and who can resolve it; raw database errors are never shown.

**Tests**
- 387 pgTAP assertions through the official CLI (`supabase test db`), 13 app unit tests, 16 scanner tests (4 against a real clamd: EICAR detected, oversize not called clean), and a 6-step end-to-end test against the full local stack with the real scanner (including a file whose stored bytes were swapped after registration, which the scanner rejected).
- A walkthrough in the browser as the venue administrator, the contractor and the Authorising Engineer, with real sign-in codes from Mailpit: invite → email → sign-up by code → accept → upload → scanned clean → approval refused with its reason → review (approval wording refused in plain English) → approval → engagement active, audit chain verified.

**Found and fixed during 2b**
- clamd kept old signatures in memory after an update at start-up; the fail-closed rule caught it. The worker now asks clamd to reload when signatures are stale.
- The scanner was not bound to the `api` schema.
- "Latest submission" tied for two documents submitted in one transaction.
- `rejected` would have counted as usable evidence.
- Raw constraint text reached the screen; pages did not refresh after actions; "Decline" looked like "Accept".

**Not built in 2b (API exists and is tested; no screens yet)**
Deputy and accountable-administrator changes, accepting or declining an administrator-recorded relationship, facilitated acceptance, competency declaration and verification, restrictions, appointment-type proposals and approval, resolving a duplicate organisation, cancelling invitations, the scanner-status view for operations. There are no buttons for these yet, rather than buttons that do nothing. **Built in phase 3b-2** (see phase-3-design.md §13).

**Known gaps**
- The approval confirmation disappears when the approved item leaves the list (the result is correct; the feedback is lost). **Fixed 29 October 2026:** a form removed by the refreshed page hands its success message to a bar at the foot of the screen (`src/components/Flash.tsx`), kept on that page until dismissed or the person leaves it.
- No formal WCAG 2.1 AA audit yet; layout is responsive but not tested on devices.
- Production email needs an SMTP provider (E1); the scanner needs the AWS account (S1).

**Update, D-014 (24 October 2026):** malware scanning is held off. Uploads are recorded as `not_scanned` and usable at once, labelled on screen; migration `…21_scanning_setting` adds the platform setting, changeable only by migration. The scanner remains built and tested for when it is switched on.
