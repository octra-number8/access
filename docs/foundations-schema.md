# Foundations schema (build phase 1) — for approval

**Status:** Approved 24 October 2026 (D-009).
Incorporates decisions D-002 to D-008 in [decisions.md](decisions.md). The three choices formerly marked for decision are resolved as recorded in D-009.

Phase 1 covers: tenancy, venue, area hierarchy, building systems, organisation, engagement, person, identity, appointment, delegation, acting capacity (decision context), state transitions, audit, RLS. Per D-004, later phases add their own tables; nothing for documents, inductions, permits, controls or the gate is created now.

---

## 1. Conventions

- **Keys:** `uuid` primary keys (`gen_random_uuid()`).
- **Tenancy columns:** every tenant row carries `customer_id`; venue-scoped rows also carry `venue_id`. Cross-references use composite foreign keys, e.g. `(customer_id, venue_id, area_id)`, so a row cannot point across tenants or venues even by mistake.
- **Time:** `timestamptz` only. Validity windows are `valid_during tstzrange` (`[start, end)`, end may be open). Each venue stores an IANA timezone for display; stored values are instants.
- **Validity is derived:** "current" means `now() <@ valid_during` and not revoked, evaluated at read time. No job flips a stored flag (invariants 10, 11).
- **No in-place edits of authority records:** change = revoke + insert, linked by `supersedes_id`.
- **Concurrency:** mutable rows carry `row_version int`; RPCs take the expected version and fail on mismatch.
- **Housekeeping columns** on every table: `created_at`, `created_by_user_id`. Updates are recorded in audit, not in `updated_*` columns.
- **Text identifiers** (`code`) are unique per venue and immutable once referenced.

## 2. Schemas and roles

| Schema | Holds | Exposed to clients |
|---|---|---|
| `core` | All tables | No |
| `authz` | Authorisation functions | No |
| `audit` | Audit log | No |
| `api` | Read views and `SECURITY DEFINER` RPCs | **Yes — the only exposed schema** |

- PostgREST is configured to expose `api` only.
- Every `SECURITY DEFINER` function sets `search_path = ''` and schema-qualifies every name.
- Tables are owned by a dedicated `octra_owner` role that no client or job connects as. `authenticated` and `anon` have no table privileges at all, only `EXECUTE` on `api` functions and `SELECT` on `api` views.
- The service role is used by migrations and background jobs only, never on a request path.

---

## 3. Tables

### 3.1 Tenancy and administration

**`customer`**: id, name, status (`active` / `closed`).

**`venue`**: id, customer_id, code, name, timezone, status (`onboarding` / `live` / `closed`).
Going `live` is a phase 2/onboarding concern (Q21 joint readiness), so the transition is seeded but not exposed in phase 1.

**`platform_admin`**: auth_user_id, granted_by, granted_at, revoked_at.
**`tenant_admin`**: customer_id, person_id, granted_by, valid_during, revoked_at.

Administrators manage master data and *record* appointments. `authz.evaluate` never reads these tables when deciding an operational action (invariant 9).

**Platform admin access to tenant data (D-009):** none by default. Support access is a break-glass grant with a reason, a customer-visible audit event and a short expiry (e.g. hours).

### 3.2 Place

**`area_kind`**: venue_id, code, label, retired_at. Venue lookup (site, zone, hall, demise, plant room, roof, asset, public space…).

**`area`**: id, customer_id, venue_id, parent_id, area_kind_id, code, name, `path ltree`, valid_during, retired_at, row_version.
- Parent in the same venue (composite FK). Exactly one root per venue.
- `path` maintained by trigger; GiST index for "is X within Y" checks.
- **Re-parenting is blocked once anything references the area.** Restructure = retire and create.
- Retiring an area that an in-force appointment scope references is blocked; the appointment must be revoked or superseded first.

**`system_type`**: venue_id, code, label, retired_at. Venue lookup (fire alarm, sprinklers, smoke control, HV, LV, gas, BMS, lifts…).

**`system`** (D-008): id, customer_id, venue_id, system_type_id, code, name, description, valid_during, retired_at, row_version.

**`system_area`**: system_id, area_id, valid_during. Many-to-many: which areas a system serves. Exclusion constraint prevents overlapping duplicate rows.

**`system_ownership`**: id, system_id, organisation_id, engagement_id (nullable), responsibility (`owner` / `maintainer` / `operator` / `monitoring`), valid_during, evidence_ref, revoked_at.
- A register of responsibility, not authority: it routes decisions later (Q9) but grants nothing. Authority over a system still comes only from an appointment.

### 3.3 Parties and identity

**`organisation`** (D-006: per customer): id, customer_id, legal_name, trading_name, company_number, status (`active` / `inactive`), row_version.
Unique `(customer_id, company_number)` where present. Never merged automatically (Q11).

**`engagement_capacity`**: code, label. **Product-seeded, not venue config**, because capacity drives product behaviour: occupier, performing_contractor, principal_contractor, service_provider, promoter, exhibitor.

**`engagement`**: id, customer_id, venue_id, organisation_id, capacity_code, valid_during, engaged_via_organisation_id (subcontract chain), accountable_admin_person_id, status, row_version.
- An organisation may hold several capacities at one venue at once (several rows).
- `event_id` is added when events exist (phase 4/5).
- Ending an engagement never removes or orphans anything (Q10); later phases block ending while that organisation has live work or controls.

**`person`** (D-006: per customer): id, customer_id, given_name, family_name, preferred_name, preferred_language, status (`active` / `inactive`), row_version.
No date of birth, photo, medical or identity-document fields here; later phases add those in separate, restricted tables.

**`person_contact`**: person_id, email, phone, row_version. Separate table so RLS can withhold contact details from gate and peer views.

**`user_account`**: auth_user_id, person_id, customer_id, disabled_at. Links a Supabase login to a person. One login may link to people in several customers; a person may have no login (facilitated inductions). Disabling the account makes every `authz` check deny for that user immediately.

**`person_organisation_relationship`**: id, person_id, organisation_id, kind (`employee` / `agency` / `self_employed` / `volunteer` / `subcontractor` / `exhibitor`), valid_during, supervisor_person_id, evidence_responsible_organisation_id, revoked_at.

### 3.4 Authority

**`authority_action`**: code, description, target_type. **Product-seeded by migration; never configurable.** Phase 1 seeds only the actions phase 1 uses:

| Code | Meaning |
|---|---|
| `appointment.grant` | Make an appointment within one's own scope |
| `appointment.revoke` | Revoke an appointment within one's own scope |
| `appointment.confirm_root` | Second-person confirmation of a root appointment (D-002) |
| `delegation.grant` / `delegation.revoke` | Delegate from, or withdraw, one's own appointment |
| `engagement.suspend` / `engagement.reinstate` | Restrict or reinstate an engagement (Q18) |

Later phases add their own verbs (`document.review`, `permit.issue`, …) in their own migrations.

**`permit_class`**: id, venue_id, code, name, retired_at. A minimal stub so appointments can name classes; the full class configuration arrives in phase 5. No classes are seeded; the launch list is still Proposed (Q233).

**`appointment_type`** + **`appointment_type_version`**: venue configuration with owner, version and effective date.
- Version columns: appointment_type_id, version_no, allowed_action_codes[], eligible_permit_class_ids[], eligible_system_type_ids[], requires_competence_evidence, owner_person_id, effective_from, superseded_at, change_reason.
- Holding a type grants nothing; it is a template that appointment instances may narrow but never widen.
- Example: "Authorised Person (Fire Systems)", allowed `appointment.grant` within fire-system scope.

**`appointment`**: id, customer_id, venue_id, appointee_person_id, appointment_type_version_id, appointed_by_person_id, appointed_under_appointment_id (null only for root), is_root, limitations_text, limitations jsonb, competence_evidence_ref, valid_during, review_due_on, status, recorded_by_user_id, confirmed_by_person_id, acknowledged_at, revoked_at, revoked_by_person_id, revoked_reason, supersedes_id.

Constraints and triggers:
- `appointee ≠ appointed_by` (self-appointment floor, D-007).
- Non-root: `appointed_under` must be in force at insert time, held by `appointed_by`, carry `appointment.grant`, and cover a scope ⊇ the new appointment's scope, classes and window (no widening).
- Root (D-002): `appointed_by` is the customer's named duty holder; `confirmed_by ∉ {appointee, recorder}`; evidence reference required; dedicated audit event.
- Actions, classes and system types ⊆ the type version's.
- Immutable after it takes effect, except revocation and acknowledgement columns.

States (seeded transitions): `pending_confirmation` → `in_force` → `revoked`, plus `pending_confirmation` → `withdrawn`. Expiry is derived from `valid_during`, not a state.

**Appointee acknowledgement (D-009):** an appointment is not in force until the appointee acknowledges it in-app (`acknowledged_at`).

**Appointment suspension (D-009):** not in phase 1; revoke and re-issue.

**`appointment_permit_class`**: appointment_id, permit_class_id.

**`appointment_scope`** (D-008): id, appointment_id, area_id, include_descendants, system_id, restrict_to_area_id.
- Check: exactly one of `area_id` / `system_id` is set.
- **Area scope** matches a target area if it equals `area_id`, or lies beneath it when `include_descendants`.
- **System scope** matches a target system if it equals `system_id`; if `restrict_to_area_id` is set, the target's area must also lie within that area (e.g. "fire alarm, Hall 3 only").
- **Targets that name a system require a system-scope match.** Targets naming only an area require an area-scope match. A hot-works permit in Hall 3 needs area authority; the fire-alarm impairment it depends on needs fire-alarm system authority. Neither substitutes for the other.

**`delegation`**: id, customer_id, venue_id, delegator_person_id, delegator_appointment_id, delegate_person_id, delegate_appointment_id, action_codes[], permit_class_ids[], scope (same shape as `appointment_scope`, in `delegation_scope`), target_type, target_id (optional, for a single record), valid_during, reason, revoked_at, revoked_by_person_id.
- `delegator ≠ delegate`.
- Delegated actions, classes and scope ⊆ delegator's appointment **and** ⊆ delegate's own appointment (invariant 7).
- No re-delegation: `delegator_appointment_id` must be an appointment, never a delegation.
- Lapses automatically, by derivation, the moment either appointment is revoked or expires.

### 3.5 Acting capacity, idempotency and decisions

**`decision_context`**: id, customer_id, venue_id, actor_user_id, actor_person_id, action_code, target_type, target_id, acting_appointment_id, acting_delegation_id, evaluated_at (database clock), evaluation jsonb (every check run and its result), idempotency_key, request_hash.
- Written only by `authz.require`. Every consequential row (and later every review, issue, acceptance…) carries a foreign key to its context, recording the capacity chosen.
- Unique `(actor_user_id, action_code, idempotency_key)`.
- A repeat with the same key and same `request_hash` returns the original result. The same key with a different payload is rejected.

**Capacity selection (Q16):** the RPC takes an optional `acting_appointment_id` / `acting_delegation_id`. If exactly one current capacity covers the action, it is used automatically. If several do and none is chosen, the call is refused with "choose the capacity you are acting in".

---

## 4. Authorisation service (`authz`)

Every target resolves to a **scope tuple**: `(customer_id, venue_id, area_id?, system_id?, permit_class_id?, record author/submitter person ids)`.

`authz.evaluate(action, target_type, target_id, acting_capacity?)` returns `{allowed, capacity_used, checks[], missing, resolvable_by}` and checks, in order:

1. The user account is active and linked to a person in the target's customer.
2. The action exists and applies to this target type.
3. **Separation-of-duties floor** (D-007): the actor is not the submitter, declarer or author of the target.
4. Venue-configured separation rules, where configured (none in phase 1).
5. A current appointment, or a current delegation backed by the delegate's own appointment, whose actions, class, scope (§3.4 matching rules) and window cover the target at `now()`.
6. The selected capacity, if given, is one of those found; otherwise exactly one was found.

`authz.require(...)` runs `evaluate`, raises a structured error on denial and, on success, writes the `decision_context` row and returns its id.

`resolvable_by` names a **role or capacity** (e.g. "an Authorised Person (Fire Systems) for Hall 3"), never a person's private details (CLAUDE.md §6).

Administrator rights are not an input to any step.

---

## 5. State transitions

- **`core.state_machine`** (code) and **`core.state_transition`** (machine, from_state, to_state, required_action_code). Seeded by migration: these are product rules, not venue configuration.
- **`core.transition(machine, record_id, to_state, decision_context_id)`** is the only path that changes a status. It sets a transaction-local marker binding the decision context to this record and transition.
- A generic **`BEFORE INSERT OR UPDATE OF status`** trigger on every stateful table rejects the write unless:
  - the marker is present and matches this record,
  - the transition exists,
  - the context's action equals the transition's required action.
  Inserts must use the machine's initial state.
- Every transition writes a `core.status_history` row and an audit event.
- Phase 1 machines: `appointment`, `engagement` (`active` ↔ `suspended`, `active` → `ended`), `venue` (seeded only).

## 6. Audit

**`audit.audit_event`**: id (bigint identity), occurred_at (database clock), customer_id, venue_id, actor_user_id, actor_person_id, actor_kind (`user` / `admin` / `system` / `break_glass`), acting_appointment_id, acting_delegation_id, decision_context_id, action, target_table, target_id, reason, change jsonb, request_id, prev_hash, hash.

- **Writers:** a generic row trigger on every `core` table (insert/update/delete diffs) plus explicit semantic events from `authz` and RPCs (e.g. `appointment.root_confirmed`, `authz.denied`).
- **Denied attempts are audited too**, so the super-admin and self-approval tests leave evidence.
- **Append-only:** no UPDATE, DELETE or TRUNCATE privilege for any application role; a trigger raises on UPDATE and DELETE regardless of role; the table is owned by a role nothing connects as.
- **Personal data:** payloads hold ids and changed field names. Contact-detail values are excluded, so a person can later be pseudonymised without breaking the chain (Q220).
- **Tamper evidence:** per-customer hash chain (`hash = sha256(prev_hash || canonical row)`), with a verification function. Cheap now, valuable for evidence packs (phase 8).

## 7. Row Level Security

- RLS **enabled and forced** on every table in the migration that creates it. A pgTAP check fails if any `core`/`audit` table lacks it.
- The JWT supplies only `auth.uid()`. Membership is looked up live through `STABLE SECURITY DEFINER` helpers (`authz.my_person_ids()`, `authz.my_admin_customer_ids()`, `authz.my_venue_ids()`), wrapped as `(select …)` so each runs once per statement.
- **No INSERT/UPDATE/DELETE policies exist for clients.** All writes go through `api` RPCs.

Phase 1 read visibility:

| Data | Visible to |
|---|---|
| customer, venue, area, system, system ownership | Tenant admins; people with an in-force appointment or a current engagement relationship at that venue |
| organisation, engagement | Tenant admins; venue appointees for organisations engaged at their venue; the organisation's own people |
| person | The person; tenant admins; venue appointees for people related to an organisation engaged at their venue |
| person_contact | The person; tenant admins |
| appointment (summary view: who, type, scope, window) | Anyone with venue visibility, so "who can resolve this" can be answered |
| appointment detail (limitations, competence evidence ref) | Appointee, appointer chain, tenant admins |
| delegation | Delegator, delegate, tenant admins |
| decision_context, audit | Tenant admins; the actor for their own entries |

Platform admins see nothing by default; break-glass grants are audited (§3.1).

## 8. Master-data writes

Creating and editing customers, venues, areas, systems, organisations, people and engagements is **administration**, done through `api` RPCs that check `tenant_admin` (or `platform_admin` for customers). These actions:
- are audited with `actor_kind = admin`,
- grant no operational authority,
- cannot touch appointments, delegations or any status except through `core.transition` with a decision context, which administrators cannot obtain for operational actions.

Recording a root appointment is an administrative act; it has no effect until confirmed (D-002)  and acknowledged.

## 9. Configuration versioning

Two tiers:
- **Safety-relevant configuration** (appointment types now; permit classes, screening rules, notice rules later): versioned rows with owner, version number, effective date, change reason. Decisions reference the exact version in force.
- **Descriptive lookups** (area kinds, system types): plain rows with `retired_at`, changes audited, no versioning.

No safety-relevant setting has a silent default (CLAUDE.md §9). Where a required setting is missing, `authz.evaluate` returns "This venue has not configured X; owner: Y" (P4).

## 10. Migrations

Forward-only, one concern per file. Each file header states its recovery plan. Until pilot data exists, recovery is resetting the local or development database; afterwards it is a forward fix migration.

| # | File | Contents |
|---|---|---|
| 0001 | `extensions_schemas_roles` | `ltree`, `btree_gist`, `pgcrypto`; schemas; roles; revoke default privileges |
| 0002 | `audit` | `audit.audit_event`, append-only enforcement, hash chain, generic row trigger function |
| 0003 | `state_machine` | `state_machine`, `state_transition`, `status_history`, `core.transition`, guard trigger |
| 0004 | `tenancy` | `customer`, `venue`, `platform_admin`, `tenant_admin` |
| 0005 | `place` | `area_kind`, `area`, `system_type`, `system`, `system_area`, `system_ownership` |
| 0006 | `parties` | `organisation`, `engagement_capacity`, `engagement`, `person`, `person_contact`, `user_account`, `person_organisation_relationship` |
| 0007 | `authority_catalogue` | `authority_action` (phase 1 verbs), `permit_class` stub, `appointment_type`(+version) |
| 0008 | `appointments` | `appointment`, `appointment_permit_class`, `appointment_scope`, `delegation`, `delegation_scope` |
| 0009 | `decision_context` | `decision_context`, idempotency handling |
| 0010 | `authz` | membership helpers, `evaluate`, `require` |
| 0011 | `api` | views and RPCs |

Every table-creating migration also enables RLS, adds its policies and attaches the audit trigger.

## 11. Phase 1 proof (pgTAP, `supabase test db`)

Each is a test that must pass before phase 2 starts.

**Structure**
- Every `core`/`audit` table has RLS enabled and forced; no client role has table privileges; only `api` is exposed.

**Tenancy**
- Cross-customer read and write denied on every table, for every role.
- Cross-venue read denied within a customer for a venue-only appointee.

**Administration grants no authority (invariant 9)**
- Platform admin and tenant admin each attempt: grant appointment, revoke appointment, confirm a root appointment they recorded, delegate, suspend and reinstate an engagement. All denied and audited.

**Appointments**
- Expired, revoked, not-yet-effective and unacknowledged appointments deny.
- Area scope: in area allowed; descendant allowed only with `include_descendants`; sibling denied.
- System scope: correct system allowed; other system denied; area restriction honoured; area authority does not satisfy a system target and vice versa.
- Granting wider than one's own appointment (scope, class, action, window) denied.
- Self-appointment denied.
- Root: confirmer equal to appointee or recorder denied.

**Delegation**
- Delegation outside the delegate's own appointment denied; re-delegation denied; delegation stops working the moment the delegator's appointment is revoked.

**Capacity**
- Two covering appointments and no selection → refused with the capacity message; a non-covering selection → denied.

**Transitions and integrity**
- Direct `UPDATE … SET status` denied, including from inside a `SECURITY DEFINER` function that skips `core.transition`.
- Undefined transition denied; wrong action for transition denied.
- Audit UPDATE and DELETE denied for every role; hash chain verifies; a tampered row is detected.
- Idempotency: same key and payload returns the original result; same key with a different payload rejected.
- Stale `row_version` rejected.
- Re-parenting a referenced area denied; retiring an area referenced by an in-force scope denied.

A small TypeScript test also proves the wrapper passes `evaluate` results through unchanged. There is no UI in phase 1.

## 12. Deliberately not in phase 1

Venue calendar, events and phases, documents and storage, competencies, inductions, work packages, permits, controls, access authorisations, gate, retention rules and legal holds, notifications. Person and organisation suspension (Q18) arrives in phase 2 with the people workflows.

## 13. Remaining assumptions

- Supabase hosted in the EU (London) region (data residency not stated).
- Local development uses the Supabase CLI and Docker; I will confirm both are available before migrating.
- One duty holder per customer for the root ceremony; several venues under one customer each have their own root appointment.

---

## 14. As built (phase 1, 24 October 2026)

Implemented in `supabase/migrations/20261024000001…12` and proved by `supabase/tests/*.test.sql` (206 pgTAP assertions). Where the build differs from §1–§13, the difference and the reason are recorded here. Items marked **[decide]** are listed in [decisions.md](decisions.md) for approval.

| Area | Approved design | As built | Why |
|---|---|---|---|
| Table ownership | Owned by an `octra_owner` role nothing connects as | Owned by `postgres`, the migration role | Supabase runs migrations and `SECURITY DEFINER` functions as `postgres`. Append-only and status guards are triggers, so they still bind `postgres`; the hash chain detects an owner disabling them (tested). |
| Client table privileges | None | `SELECT` only, always RLS-filtered; no write privilege of any kind | `api` views are `security_invoker`, so the caller needs `SELECT` for RLS to apply to them. `core` is still not exposed to the Data API. |
| Area | `valid_during`; re-parenting blocked once referenced | `retired_at`; parent and venue are never changeable | Simpler and stricter. Restructure = retire and create. |
| Appointment states | Included `withdrawn` | Pending appointments are revoked instead | One fewer state with the same meaning. |
| Who may appoint whom | Scope, classes, window may not widen | Plus `grantable_type_ids` on the appointer's type version | Real schemes say which roles appoint which (an AP appoints CPs). Without it, any appointer could create any type. |
| System scope | `system_id`, optional area restriction | Also `system_type_id` ("every fire alarm system") | Lets a root appointment cover systems without listing each one. |
| Delegation | Actions ⊆ both appointments | Actions ⊆ delegator's only; classes and scope ⊆ both | If the delegate had to hold the action already, delegation would add nothing. Invariant 7's "own valid appointment" is met: the delegate's appointment must be in force and must cover the scope. |
| Lifting a restriction **[decide]** | Owner or delegate | Owner, any holder of the **same appointment type**, or a delegate of the owner; people from the restricted organisation are excluded | Q18's "formally appointed equivalent" read as same appointment type. |
| Decision context | Consequential actions | Every API write, including administrative ones; idempotency key required on all | One write path, one audit shape, one idempotency rule. |
| Denials | Raised | Returned as a value and audited; stale versions raise `PT409` (HTTP 409) | A raised error would roll back the audit record of the denied attempt. |
| Single use | — | Each decision context can authorise exactly one status write | Found while testing: a context could otherwise be reused for a second change in the same transaction. |
| Same-state transition | — | Refused (`PT409`) | Found while testing: re-suspending would silently re-own a suspension. |
| Venue-level targets | — | Need authority over the venue's root area | An engagement has no area; only venue-wide authority may restrict it. |
| Break-glass **[decide]** | "Short expiry (e.g. hours)" | Hard limit of 8 hours, reason ≥ 10 characters | A platform security setting, not venue configuration. |
| Appointment types **[decide]** | Owner, version, effective date | Published by a tenant administrator, naming an owner | Chicken-and-egg: the root type must exist before any appointment. |
| Limitations | Text and structured jsonb | Text only | Structured limitations wait until a later phase needs to enforce them. |
| Audit throughput | — | Writes are serialised per customer (advisory lock) to keep the hash chain linear | Fine at pilot scale; revisit before multi-estate load. |

### Bootstrap runbook (platform operator)

1. Create the operator's Supabase Auth user.
2. As the database owner, run `insert into core.platform_admin (auth_user_id) values ('<uuid>');`. This is the only direct insert anywhere, and it is audited.
3. The operator calls `api.create_customer(...)`, which creates the customer, its first person, login and tenant administrator.
4. The tenant administrator creates the venue, people and appointment types, then records the root appointment (D-002); a second tenant administrator confirms it; the appointee acknowledges it (D-009).
