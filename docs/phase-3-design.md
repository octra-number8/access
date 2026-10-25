# Build phase 3 — inductions: design for approval

**Status:** Approved 25 October 2026 (D-016).
Builds on phases 1–2 and D-015: OCTRA Induct's design, journey and content format, built on Access's data model. Decisions needed are in §10.

Source questions: Q41–Q47 (all Proposed or Requires specialist validation in the [register](requirements-register.md)). Every number that varies by venue — pass mark, attempts, retry delay, validity — is venue configuration with **no default** (CLAUDE.md §9).

---

## 1. What phase 3 delivers

A venue authors (or imports) an induction, its H&S authority publishes it, and an invited operative completes it on their phone — or with a facilitator — leaving an immutable completion record bound to that person, venue, course version, language and method. That record is what the gate phase (7) will use for entry eligibility; phase 3 does not decide entry.

Proposed split, as in phase 2 (decision P3-1):
- **3a** — database, API, importer, pgTAP.
- **3b** — the Induct look across the app, the learner journey, authoring and publishing screens, facilitation, and the phase 2 screens deferred under E3.

## 2. What comes from OCTRA Induct (D-015)

| From Induct | Into Access |
|---|---|
| Design tokens (`src/app/globals.css`): ink/body/muted, `#c25e00` brand fill, `#ee7d00` mark-only accent, status colours, 16px cards, 2px focus ring, reduced motion | Replaces Access's current tokens; the whole app takes the Induct look (P3-7) |
| Hanken Grotesk via `next/font`, brand files in `public/brand/` | Copied |
| Tailwind v4 (`@theme inline`, no config file) | Added to Access so the components carry over with minimal change |
| Learner components: section step (sticky Next, minimum time), block view (text, callout, image, video, document), question step, result step, declaration step, signature pad | Copied and adapted to Access's API and data; provenance noted in each file |
| Journey: one task per screen, 360px-first, 44px targets, progress saved on the server, "your progress is kept" | Kept |
| Content format: sections → blocks; questions (single choice, multi-select, true/false) with options, correct answers, explanation, linked section; declaration items | Becomes Access's course-version format; Induct starter JSON and the brief markdown both import into it (§7) |
| Captions (WebVTT) required for video at publish, transcript disclosure, alt text required (or marked decorative) | Kept, and enforced in the database at publish |
| Published versions immutable, with a content snapshot and hash | Kept |

**Not taken from Induct** (they belong to other phases or conflict with Access's model):
anonymous public event links with self-registration and bot check (identity is unverified — see P3-2); the gate photograph step (gate phase, privacy Q35); QR passes and wallet passes (gate phase); event-scoped participants (Access binds completions to a person).

## 3. Data model (Access's, per CLAUDE.md §3)

| Table | Holds |
|---|---|
| `induction_course` | Venue (required), optional event (P3-3), code, title, audience note. |
| `course_version` | Version number, language, status (`draft` → `in_review` → `published` → `superseded` / `withdrawn`), content snapshot and SHA-256 at publish, **assessment settings** (below), author, publisher, decision context. Published versions are immutable. |
| `course_module` | Position, title, kind (`core` or `role` / `area` / `event_phase` module, Q43), minimum seconds, stable key. |
| `content_block` | Module, position, type (`rich_text`, `callout`, `image`, `video`, `document`), text, media, alt text or decorative flag, caption track, transcript. |
| `question` | Version, linked module, type, stem, explanation, **`safety_critical`** flag (Q44, not in Induct), weight. |
| `answer_option` | Question, text, `is_correct` — never readable by learners. |
| `declaration_item` | Version, position, wording. |
| `course_open_point` | Version, text, owner, `resolved_at`, resolution. Imported "Open points" land here; **a version cannot be published while any is unresolved.** |
| `induction_media` | Content-addressed media (SHA-256), private bucket, released to learners by signed URL. |
| `induction_attempt` | Person, course version, language, method, started, finished, score, critical failures, result. One open attempt per person and version. |
| `module_progress` | Attempt, module, `started_at` (set once, server time), `completed_at` — enforces minimum time. |
| `question_response` | Attempt, question, chosen options, correct — insert-only. |
| `induction_completion` | **Immutable.** Person, venue, course version, language, method (`self`, `assisted`, `facilitated`), facilitator and their decision context (assisted/facilitated), understanding check, declaration wording hash and signature, `completed_at`, `valid_until` (computed from the version's validity setting), evidence snapshot hash. |
| `completion_invalidation` | Completion, reason (`content_change`, `venue_instruction`, `breach_review`), decision context. Invalidation is a separate record; the completion never changes (Q45). |

**Assessment settings on each course version** (all required before publish, no defaults, set by the venue — P3-5):
pass mark %, whether every safety-critical question must be correct, maximum attempts before assisted review, retry delay, shuffle options, and validity (`days_from_completion` with a number, or `fixed_date`).

"Current induction" for a person is derived (latest valid, non-invalidated completion for a course at the venue); nothing stores a person-level status (Q39).

## 4. Authority and actions

| Action | Basis | Notes |
|---|---|---|
| `induction.author` (create course, edit draft, import) | tenant admin | Drafts only. |
| `induction.submit_for_review` | tenant admin | Draft → in review; checks captions, alt text, settings, no open points. |
| `induction.publish` / `induction.return` | appointment | The venue's H&S authority (Q44: approves the question bank, pass logic and validity). **The author and the submitter are excluded.** |
| `induction.withdraw` | appointment | Same authority; existing completions stay, marked by a withdrawal record if invalidated. |
| `induction.facilitate` | appointment | Venue-appointed facilitator records assisted or facilitated completion (Q47). Facilitator ≠ learner. |
| `induction.invalidate` | appointment | Records a `completion_invalidation`. |
| `induction.start` / `answer` / `complete` | subject | The learner, for themselves. |
| `induction.send_link` | tenant admin or organisation admin | Issues a personal induction link (P3-2). |

## 5. How a learner gets in (Q41, decision P3-2)

- **Personal induction link**: issued to one known person (by the venue, or by their organisation administrator for their own people), single-use per person and course, expiring, stored only as a hash, opened without a password. It proves control of the email it was sent to. Completion binds to that person.
- **Email code sign-in** (already built) for people with an Octra account.
- **Facilitated route** for people without email or a phone (Q46, Q47): a facilitator records the completion with identity check, language, method and understanding check.
- **Not proposed for v1:** Induct's anonymous public event link with self-registration — identity would be unverified, which CLAUDE.md §3 does not allow for completion records.

## 6. The learner journey (Induct's, adapted)

Welcome → modules in order (each with its minimum time, progress saved) → questions (section questions after their module; final questions at the end) → result (score, any safety-critical question missed, attempts left, retry delay; explanations and a link back to the relevant module) → declaration (each item confirmed; typed name or drawn signature) → completion confirmation (course, version, valid until). No pass/QR screen until the gate phase.

The result screen states what was recorded, never "safe" or "compliant" (D-005).

## 7. Importing existing content (D-015)

- **Induct starter JSON** (`sections`, `blocks`, `min_seconds`, `final_questions`, `options`, `correct`, `explanation`, `declaration`).
- **Induction brief markdown** (the `Induction briefs` format, e.g. VodafoneThree): `### ` sections under "Sections"; questions with `Section:`, `Type:`, `Question:`, `- [x]`/`- [ ]` options, `Explanation:`; declaration items; images as `file | section | alt text` (with "to supply" entries becoming open points); "Open points" becoming `course_open_point` rows that block publishing; "Extra registration fields" listed for review, not imported as data collection (privacy).
- Imports always create a **draft** for the venue's H&S authority to review and publish. Nothing imported is live.
- **Olympia:** the folder has 11 section headings and images but no text or questions; the source PDF ("Olympia Building Induction — v3 · published 2026-07-16") is needed before it can be drafted.

## 8. The phase 2 screens deferred under E3 (3b)

Relationship accept/decline, facilitated relationship acceptance, deputy and accountable administrator changes, competency declaration and verification, restrictions (impose and lift), appointment type proposal and approval, duplicate organisation resolution, invitation cancellation, scanner/setting status for platform operations.

## 9. Proof

- pgTAP: publication refused for the author, with unresolved open points, without captions or alt text, or without settings; learners cannot read correct answers; minimum time enforced server-side; attempts and retry delay enforced; a missed safety-critical question fails regardless of score (when the venue requires it); completions immutable; invalidation as a separate record; facilitator cannot complete for themselves; personal links single-person, expiring, hash-only; cross-tenant and cross-venue denial for every new table.
- Importer tests against the VodafoneThree brief (19 sections, 12 questions, 5 declaration items, 6 images, 4 "to supply" images and the open points becoming blocking items).
- End-to-end: invite → personal link → induction on a phone-sized viewport → completion record; a failed attempt with retry; a facilitated completion.
- Browser walkthrough at 360px and desktop; accessibility checks (keyboard, screen reader labels, captions present).

## 10. Decisions needed

| Ref | Decision | Recommendation |
|---|---|---|
| P3-1 | Split into 3a (database, API, importer) and 3b (screens, Induct look, E3 screens)? | **Yes**, as in phase 2. |
| P3-2 | Learners get in by personal induction link, email code or facilitation — not Induct's anonymous public event link | **Yes.** Completion records must be bound to a verified person (CLAUDE.md §3). A public link with self-registration can be revisited for high-volume event crews. |
| P3-3 | Courses belong to a venue, optionally to an event. Add a minimal `event` (venue, name, dates, build/live/breakdown phases) now so event inductions like VodafoneThree are scoped properly? | **Yes**, minimal `event` and `event_phase` now; their wider use arrives in phases 4–5. |
| P3-4 | Publication by an appointed H&S authority; author and submitter excluded | **Yes** (Q44). |
| P3-5 | Pass mark, critical-question rule, attempts, retry delay and validity set per course version, required before publish, no pre-filled values | **Yes** (CLAUDE.md §9). The source's proposals (80%, all critical correct, 3 attempts, 12 months) are shown as guidance text only. |
| P3-6 | Safety-critical flag on questions (Induct has none) | **Yes** (Q44). |
| P3-7 | The whole app takes Induct's look, light-only (Induct has no dark mode) | **Yes, light-only**, matching Induct. Dark tokens can be added later. |
| P3-8 | Signature: typed name, or drawn signature as in Induct | **Typed name plus confirmation by default**; drawn signature optional per venue. A drawn signature is more personal data for little extra evidential value; privacy adviser to confirm (G11). |
| P3-9 | English only for now; language recorded on every version and completion; translations later as separately reviewed versions, never machine-translated (Q46) | **Yes.** |
| P3-10 | Copy Induct components into Access (same owner), with provenance comments, rather than share a package | **Yes.** The two products evolve separately (D-015). |

---

## 11. As built (phase 3a, 25 October 2026)

Implemented in `supabase/migrations/20261025000022…24`, the importer in `src/lib/induction/`, proved by pgTAP files `18_induction_authoring` and `19_induction_learner` (488 assertions in the whole suite), importer unit tests, and an end-to-end import against the local stack (including the real VodafoneThree brief).

| Area | As built | Note |
|---|---|---|
| Content storage | One validated content document per version (as Induct's `content_snapshot`), not separate module/block/question/option tables | Drafts are editable while every core table still refuses deletes; publication freezes content and settings with a SHA-256; learners receive content only via `api.learner_course`, which strips correct answers; the content column is withheld from clients at column level. Attempts, progress, responses and completions are relational. |
| Validation | `core.validate_course_content`: structural checks on every save; strict checks (captions, transcripts, alt text, explanations, files present and released, declaration, settings, open points) before submission and again at publication | Problems are listed in plain English. A refused save or submission records no decision. |
| Personal links | Opening a link needs the person to be signed in with the email it was sent to (6-digit code); first use links the new login to the person | One extra step, but it proves control of the address every time, not just at sending. |
| Order and timing | Modules in order; minimum time measured on the server; module questions after their module; final questions after all modules | |
| Scoring | Weighted percentage; fails if any safety-critical question is wrong when the version requires it; wrong answers explained with a link back to the module, correct options never revealed | |
| Attempts | Max attempts then "assisted review required"; retry delay shown in the venue's time zone | |
| Completion | Immutable; records version, language, method, signature kind, declaration hash and an evidence hash over the responses | |
| Facilitated completion | Recorded by an appointed facilitator without a learner attempt, with identity and understanding checks and the person's acknowledgement | Also the route after "assisted review required". |
| Invalidation | Separate record; the completion row never changes; visible in `api.induction_completion` as `invalidated_for` | |
| Importer | Brief markdown and Induct starter JSON → draft content, open points, image list, notes | Reading times and safety-critical flags are never invented: imported as 0 s / not critical with open points that block publication. Extra registration fields are listed, not imported (privacy, G11). |
| Media | `induction_media` (images, PDF, WebVTT up to 20 MB; MP4 up to 200 MB **[decide I1]**), recorded as not scanned while D-014 holds | Upload and signed delivery screens are 3b. |
| Shuffle | Stored as a setting; the learner screen shuffles the display order (3b) | |

## 12. As built (phase 3b-1, 25 October 2026)

Screens for authoring, publishing, personal links, the learner journey and facilitation, in Induct's look (light only, P3-7). Migration `20261025000025` adds what the screens need; the rules from 3a are unchanged.

| Area | As built | Note |
|---|---|---|
| Look | Induct's tokens, font and logo; existing Access classes re-implemented on them | Copied components carry a note of their source (P3-10). |
| Authoring (`/venue/inductions`) | Course list, new course, start a version; per version: problems, import, open points, reading times and safety-critical flags, settings, preview with media upload, submit, publish or return | Settings fields start empty and say the source's figures are suggestions only (P3-5). No in-page text editor: changes are made by re-importing **[outstanding]**. |
| Publishing | Shown to everyone on the version page; the server refuses the author, the submitter and anyone without the publish appointment, with the four-part explanation | Seen in the walkthrough: the author was refused; the authorising engineer published. |
| Media | Upload is checked by content sniffing (PDF, PNG, JPEG, WebVTT, MP4), stored in the private `induction-media` bucket and served through `/api/induction-media/{id}` as a 300-second signed URL after `api.induction_media_access` | Learners get only files that their current link's published version uses. |
| Links | "Send a personal induction link" on the inductions list and on an organisation's page; the email names the address to sign in with | |
| Learner journey (`/induction/{token}` → `/learn/{course}`) | Welcome, sections with a server-timed countdown, questions, result with explanations of wrong answers, retry, declaration (typed name), done | Everything is worked out on the server again on reload, so leaving and coming back resumes at the same point with the same remaining time. The done screen says completion is not permission to enter or to work. |
| Proof | pgTAP `20_learner_state_and_media` (27 assertions; 515 in the whole suite): media released only to authors, the publishing authority, or a learner holding a current link to a version that uses the file; resume state; explanations without correct options. Two deliberate weakenings were each caught. Browser walkthrough from import to completion, learner at 375 and 360 px. | |
| Facilitation (`/facilitate`) | Record a facilitated completion | Not walked through in the browser in 3b-1; covered by pgTAP. |
| Sign in | The code form reuses the address typed for the code | The address is never put in the URL. |
| Validation messages | Name sections by title; "The image in …" | Restated `core.validate_course_content` in 0025; checks unchanged. |
| Drawn signature | Not offered | Only "typed" can be chosen until a drawn signature is stored as evidence **[outstanding]**. |
