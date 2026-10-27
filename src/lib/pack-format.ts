// The permit pack's files (Q213, Q215, P8-10): a PDF of the index, the record and the
// chronology, the frozen content exactly as hashed (pack.json), the evidence files, and a
// manifest of every file's SHA-256, in one ZIP. Everything shown comes from the pack's content,
// which the database fixed when the pack was requested; this file only lays it out.

import { createHash } from "node:crypto";
import fontkit from "@pdf-lib/fontkit";
import { zipSync } from "fflate";
import { PDFDocument, type PDFFont, type PDFPage, rgb } from "pdf-lib";
import { humanCode, stateWords } from "./labels";
import { PERMIT_STATE } from "./permits";

type Json = string | number | boolean | null | Json[] | { [k: string]: Json };
type Obj = { [k: string]: Json };

export interface PackContent {
  format: string; export_id: string; reference: string;
  venue: { id: string; name: string; timezone: string };
  made_at: string; made_by: { person_id: string; capacity: string | null };
  purpose: string; recipient: string; profile: "external" | "internal";
  statement: string; profile_rules: string[]; never_removed: string;
  omissions: Array<{ item: string; what: string; reason: string }>;
  redactions?: { fields: number; email_addresses: number; phone_numbers: number };
  job: Obj;
  permits: Array<{ id: string; class: string; kind: string; state_when_made: string; closed: boolean;
                   issue_snapshots: Array<{ id: string; issued_at: string; sha256: string; content: Obj }>;
                   close_out: { id: string; at: string; sha256: string; content: Obj } | null }>;
  not_issued: Array<{ id: string; class: string; state_when_made: string }>;
  files: Array<{ version_id: string; title: string; type: string; version_no: number; owner: string; owner_kind: string; media_type: string;
                 bytes: number; sha256: string; scan_status: string; included: boolean; omitted_reason: string | null; name_in_pack: string | null }>;
  corrections: Array<{ about: string; was: string; corrected: string; reason: string; evidence: string; by: string; at: string; target_type: string; permit_id: string }>;
  contacts: { people: Array<{ role: string; person_id: string; email: string | null; phone: string | null }>; venue_emergency_contacts: Json } | null;
  chronology: Array<{ at: string; action: string; what: string; who: string; capacity: string; reason: string | null;
                      changes: Array<{ record: string; from: string | null; to: string }>; seq: number | null; hash: string | null }>;
  verification: { checked_at: string; events_in_chain: number; events_in_pack: number; problems: Array<{ seq: number; problem: string }> };
  names: { people: Record<string, string>; appointments: Record<string, { type: string; holder: string }>; areas: Record<string, string>;
           organisations: Record<string, string>; permits: Record<string, string> };
}

export interface PackFile { name: string; sha256: string; bytes: number }

export const sha256Hex = (b: Uint8Array) => createHash("sha256").update(b).digest("hex");

// Recorded states, worded as on screen: a status means a decision was recorded, nothing more.
const STATE = PERMIT_STATE;
const LABEL: Record<string, string> = {
  no: "Version", answers: "Answers", window_from: "Window from", window_to: "Window to", declaration: "Declaration", declared_by: "Declared by",
  documents: "Documents", sha256: "SHA-256", acceptance_declaration: "Acceptance declaration", scope_wording: "Scope wording", decider: "Decided by",
  at: "At", by: "By", issued_at: "Issued at", closed_at: "Closed at", work_complete: "Work complete", remaining_work: "Remaining work",
  area_state: "State of the area", from: "From", to: "To", route: "Route", previous_end: "Previous end", new_end: "New end",
  acknowledged_at: "Acknowledged at", briefed: "Briefed", unlinked_at: "Unlinked at", unlinked_reason: "Reason unlinked", linked_at: "Linked at",
  control_id: "Control", closing_decision: "Closing decision", performing_organisation_id: "Performing organisation", areas: "Areas",
  person_id: "Person", appointment_id: "Appointment", delegation_id: "Delegation", parent_permit_id: "Part of", issue_snapshots: "Issue snapshots",
  decider_person_id: "Decided by", submitted_by_person_id: "Submitted by", created_at: "At", supervisor_person_id: "Supervisor",
};
const SKIP = new Set(["id", "customer_id", "venue_id", "created_by_user_id", "row_version", "decision_context_id", "revision_id", "hand_back_id"]);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/;

const words = (k: string) => LABEL[k] ?? (k.charAt(0).toUpperCase() + k.slice(1).replace(/_/g, " "));
/** A recorded code ("late_notice", "in_person") or state, in words. */
const human = (v: string) => STATE[v] ?? humanCode(v);

export function venueWhen(iso: string, tz: string): string {
  return new Intl.DateTimeFormat("en-GB", { timeZone: tz, day: "numeric", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit", timeZoneName: "short" })
    .format(new Date(iso));
}

/** A value as a person would read it: identifiers named from the pack's dictionaries, times in venue time. */
export function readable(v: Json, c: PackContent): string {
  if (v === null || v === undefined) return "—";
  if (typeof v === "boolean") return v ? "Yes" : "No";
  if (typeof v === "number") return String(v);
  if (typeof v === "string") {
    if (UUID.test(v)) {
      const n = c.names;
      const a = n.appointments[v];
      return n.people[v] ?? (a ? `${a.type} (${a.holder})` : null) ?? n.areas[v] ?? n.organisations[v] ?? n.permits[v]
        ?? c.files.find((f) => f.version_id === v)?.title ?? `record ${v.slice(0, 8)}`;
    }
    if (ISO.test(v)) return venueWhen(v, c.venue.timezone);
    return human(v);
  }
  if (Array.isArray(v)) {
    if (!v.every((x) => typeof x !== "object" || x === null)) return `${v.length} item(s)`;
    if (!v.length) return "None";
    const parts = v.map((x) => readable(x, c));
    // Listed sentences read as sentences; anything else as a list.
    return parts.join(parts.every((p) => /[.!?]$/.test(p)) ? " " : ", ");
  }
  return "";
}

// ---- Layout ------------------------------------------------------------------------------------

const A4 = { w: 595.28, h: 841.89 };
const M = 50;
const INK = rgb(0.1, 0.1, 0.1);
const GREY = rgb(0.38, 0.38, 0.38);

class Writer {
  pages: PDFPage[] = [];
  page!: PDFPage;
  y = 0;
  private chars: Set<number>;
  constructor(private doc: PDFDocument, private font: PDFFont) { this.chars = new Set(font.getCharacterSet()); this.newPage(); }

  newPage() { this.page = this.doc.addPage([A4.w, A4.h]); this.pages.push(this.page); this.y = A4.h - M; }

  /** Characters the font cannot draw are shown as "?"; pack.json holds the exact text. */
  clean(s: string): string {
    let out = "";
    for (const ch of s.replace(/\t/g, " ")) {
      const cp = ch.codePointAt(0)!;
      out += cp < 32 ? " " : this.chars.has(cp) ? ch : "?";
    }
    return out;
  }

  wrap(s: string, size: number, width: number): string[] {
    const lines: string[] = [];
    for (const para of this.clean(s).split(/\r?\n/)) {
      let line = "";
      for (const word of para.split(/ +/)) {
        const next = line ? `${line} ${word}` : word;
        if (this.font.widthOfTextAtSize(next, size) <= width) { line = next; continue; }
        if (line) lines.push(line);
        // A single word wider than the line (a hash, a long reference) is broken.
        let w = word;
        while (this.font.widthOfTextAtSize(w, size) > width) {
          let n = w.length;
          while (n > 1 && this.font.widthOfTextAtSize(w.slice(0, n), size) > width) n -= 1;
          lines.push(w.slice(0, n)); w = w.slice(n);
        }
        line = w;
      }
      lines.push(line);
    }
    return lines;
  }

  text(s: string, { size = 9.5, indent = 0, colour = INK, gap = 2 }: { size?: number; indent?: number; colour?: typeof INK; gap?: number } = {}) {
    for (const line of this.wrap(s, size, A4.w - 2 * M - indent)) {
      if (this.y - size < M + 20) this.newPage();
      this.page.drawText(line, { x: M + indent, y: this.y - size, size, font: this.font, color: colour });
      this.y -= size + gap;
    }
  }

  heading(s: string, size = 13) {
    if (this.y < M + 80) this.newPage();
    this.y -= 8;
    this.text(s, { size, gap: 4 });
    this.page.drawLine({ start: { x: M, y: this.y }, end: { x: A4.w - M, y: this.y }, thickness: 0.5, color: GREY });
    this.y -= 6;
  }

  field(label: string, value: string, indent = 0) { this.text(`${label}: ${value}`, { indent }); }
  space(n = 6) { this.y -= n; }
}

/** Any frozen structure, as labelled lines: objects nest, lists are numbered. */
function tree(w: Writer, c: PackContent, v: Json, indent: number) {
  if (v === null || typeof v !== "object") { w.text(readable(v, c), { indent }); return; }
  if (Array.isArray(v)) {
    if (v.every((x) => typeof x !== "object" || x === null)) { w.text(readable(v, c), { indent }); return; }
    if (!v.length) { w.text("None", { indent }); return; }
    v.forEach((x, i) => { w.text(`${i + 1}.`, { indent, colour: GREY }); tree(w, c, x, indent + 12); });
    return;
  }
  for (const [k, x] of Object.entries(v)) {
    if (SKIP.has(k)) continue;
    // An internal identifier the pack cannot name says nothing to a reader.
    if (k.endsWith("_id") && typeof x === "string" && readable(x, c).startsWith("record ")) continue;
    if (x !== null && typeof x === "object" && !(Array.isArray(x) && x.every((y) => typeof y !== "object" || y === null))) {
      w.text(words(k), { indent, colour: GREY });
      tree(w, c, x, indent + 12);
    } else {
      w.field(words(k), readable(x, c), indent);
    }
  }
}

function snapshot(w: Writer, c: PackContent, s: Obj) {
  const v = (s.version ?? {}) as Obj;
  w.field("Version", readable(v.no ?? null, c));
  w.field("Window", `${readable(v.window_from ?? null, c)} to ${readable(v.window_to ?? null, c)}`);
  const cv = (s.class_version ?? {}) as Obj;
  w.field("Permit class rules", `version ${readable(cv.no ?? null, c)}, SHA-256 ${readable(cv.sha256 ?? null, c)}`);
  w.field("Declared by", readable(v.declared_by ?? null, c));
  if (v.declaration) { w.text("Declaration", { colour: GREY }); tree(w, c, v.declaration, 12); }
  w.text("Answers", { colour: GREY });
  if (typeof v.answers === "string") w.text(v.answers, { indent: 12 }); else tree(w, c, (v.answers ?? {}) as Json, 12);
  w.field("Documents", readable((v.documents ?? []) as Json, c));
  w.text("Approval steps and decisions", { colour: GREY });
  for (const st of (s.steps ?? []) as Obj[]) {
    const d = st.decision as Obj | null;
    w.text(`${readable(st.name ?? null, c)} (${readable(st.kind ?? null, c)})`, { indent: 12 });
    if (!d) { w.text("No decision recorded", { indent: 24 }); continue; }
    w.field("Outcome", readable(d.outcome ?? null, c), 24);
    w.field("Decided by", `${readable(d.decider ?? null, c)}, ${readable(d.at ?? null, c)}`, 24);
    w.field("Reason", readable(d.reason ?? null, c), 24);
    w.field("Scope wording", readable(d.scope_wording ?? null, c), 24);
    for (const k of (d.conditions ?? []) as Obj[]) w.text(`Condition: ${readable(k.text ?? null, c)}${k.acknowledge ? " (acknowledged at acceptance)" : ""}`, { indent: 24 });
  }
  if (((s.exceptions ?? []) as Json[]).length) { w.text("Exceptions", { colour: GREY }); tree(w, c, s.exceptions!, 12); }
  w.text("Team", { colour: GREY });
  for (const m of (s.team ?? []) as Obj[]) w.text(`${readable(m.name ?? m.person_id ?? null, c)} — ${human(String(m.role ?? ""))}`, { indent: 12 });
  const iss = (s.issuer ?? {}) as Obj;
  w.field("Issued by", `${readable(iss.person_id ?? null, c)}${iss.appointment_id ? `, under appointment as ${readable(iss.appointment_id, c)}` : ""}${iss.delegation_id ? ", under a delegation" : ""}`);
  w.field("Issued at", readable(s.issued_at ?? null, c));
}

/** The PDF: cover, index, the record, files, corrections, chronology and verification. */
export async function renderPackPdf(c: PackContent, contentSha256: string, fontBytes: Uint8Array): Promise<Uint8Array> {
  const doc = await PDFDocument.create();
  doc.registerFontkit(fontkit);
  const font = await doc.embedFont(fontBytes, { subset: true });
  const made = new Date(c.made_at);
  doc.setTitle(`Permit pack ${c.reference}`);
  doc.setAuthor("Octra Access");
  doc.setCreator("Octra Access");
  doc.setProducer("Octra Access");
  doc.setCreationDate(made);
  doc.setModificationDate(made);
  const w = new Writer(doc, font);
  const tz = c.venue.timezone;
  const index: Array<{ title: string; page: number }> = [];
  const section = (title: string) => { w.newPage(); index.push({ title, page: w.pages.length }); w.heading(title, 15); };

  // Cover.
  w.text(`Permit pack ${c.reference}`, { size: 20, gap: 8 });
  w.text(`${c.venue.name} · job ${readable(c.job.reference ?? null, c)}${c.job.title ? ` — ${readable(c.job.title, c)}` : ""}`, { size: 11, gap: 10 });
  w.field("Made", `${venueWhen(c.made_at, tz)} by ${readable(c.made_by.person_id, c)}${c.made_by.capacity ? ` (${c.made_by.capacity})` : ""}`);
  w.field("Purpose", c.purpose);
  w.field("For", c.recipient);
  w.field("Profile", c.profile === "external" ? "External (contact and personal details removed)" : "Internal (the venue's own investigation)");
  w.field("Content SHA-256", contentSha256);
  w.space();
  w.text(c.statement, { colour: GREY });
  w.space();
  w.text("What this profile does", { colour: GREY });
  for (const r of c.profile_rules) w.text(`• ${r}`, { indent: 8 });
  w.text(`Never removed: ${c.never_removed}`, { indent: 8 });
  if (c.redactions) w.text(`Removed by the profile: ${c.redactions.fields} field(s), ${c.redactions.email_addresses} email address(es), ${c.redactions.phone_numbers} telephone number(s).`, { indent: 8 });
  w.space();
  w.text("Left out by the person who made the pack", { colour: GREY });
  if (!c.omissions.length) w.text("Nothing.", { indent: 8 });
  for (const o of c.omissions) w.text(`• ${o.what}: ${o.reason}`, { indent: 8 });
  w.space();
  w.text("How to check this pack: pack.json is the content exactly as recorded when the pack was made, and its SHA-256 is the content SHA-256 above. "
    + "manifest.json lists the SHA-256 of every file. The venue holds the same hashes, and each chronology entry's place and hash in its audit log.", { size: 8.5, colour: GREY });

  // The index is written once every section's page is known.
  w.newPage();
  const indexPage = w.page;

  section("1. The job");
  tree(w, c, c.job, 0);

  let n = 2;
  for (const p of c.permits) {
    section(`${n++}. ${p.class}${p.kind === "work_approval" ? "" : " permit"}`);
    w.field("Recorded state when the pack was made", STATE[p.state_when_made] ?? p.state_when_made);
    if (!p.closed) w.text("This permit was not closed when the pack was made. Only the records frozen so far are included; later decisions are not in this pack.", { colour: GREY });
    p.issue_snapshots.forEach((s, i) => {
      w.heading(`As issued${p.issue_snapshots.length > 1 ? ` (${i + 1} of ${p.issue_snapshots.length})` : ""}, ${venueWhen(s.issued_at, tz)}`, 11);
      w.text(`Snapshot SHA-256 as recorded: ${s.sha256}${c.profile === "external" || c.omissions.length ? " (content shown here may be redacted or shortened, as stated on the cover)" : ""}`, { size: 8, colour: GREY });
      snapshot(w, c, s.content);
    });
    if (p.close_out) {
      w.heading(`Closed, ${venueWhen(p.close_out.at, tz)}`, 11);
      w.text(`Close-out snapshot SHA-256 as recorded: ${p.close_out.sha256}`, { size: 8, colour: GREY });
      tree(w, c, p.close_out.content, 0);
    }
  }
  if (c.not_issued.length) {
    section(`${n++}. Permits not issued`);
    w.text("These permits on the job were never issued, so nothing about them was frozen.", { colour: GREY });
    for (const p of c.not_issued) w.text(`• ${p.class}: ${STATE[p.state_when_made] ?? p.state_when_made}`, { indent: 8 });
  }

  section(`${n++}. Corrections`);
  if (!c.corrections.length) w.text("No corrections were recorded beside these records when the pack was made.");
  for (const k of c.corrections) {
    w.text(`Corrected on ${venueWhen(k.at, tz)} by ${readable(k.by, c)}: ${k.about}`);
    w.field("The record says", k.was, 12); w.field("Correct value", k.corrected, 12);
    w.field("Reason", k.reason, 12); w.field("Evidence", k.evidence, 12);
    w.text("The original record is unchanged; this correction is recorded beside it (Q216).", { indent: 12, colour: GREY });
    w.space(4);
  }

  if (c.contacts) {
    section(`${n++}. Contact details recorded for the job`);
    w.text("Internal pack: kept for the venue's own investigation.", { colour: GREY });
    for (const p of c.contacts.people) w.text(`${p.role}: ${readable(p.person_id, c)} — ${p.email ?? "no email recorded"}, ${p.phone ?? "no telephone recorded"}`);
    if (c.contacts.venue_emergency_contacts) { w.text("Venue emergency contacts", { colour: GREY }); tree(w, c, c.contacts.venue_emergency_contacts, 12); }
  }

  section(`${n++}. Evidence files`);
  if (!c.files.length) w.text("The issued permits named no documents.");
  for (const f of c.files) {
    w.text(`${f.title} (${f.type}, version ${f.version_no}) — ${f.owner}`);
    w.field(f.included ? "In this pack as" : "Not in this pack", f.included ? f.name_in_pack ?? "" : f.omitted_reason ?? "", 12);
    w.field("SHA-256", f.sha256, 12);
    if (f.included) w.field("Malware check", f.scan_status === "clean" ? "Scanned clean" : "Not scanned: malware scanning was off when it was uploaded", 12);
    w.space(3);
  }

  section(`${n++}. Chronology`);
  w.text(`Each decision recorded on these records, from the audit log (${c.chronology.length} entries). Times are ${tz}.`, { colour: GREY });
  for (const e of c.chronology) {
    w.space(3);
    w.text(`${venueWhen(e.at, tz)} — ${e.what}`);
    w.text(`${e.who}, as ${e.capacity}`, { indent: 12, colour: GREY });
    for (const ch of e.changes) w.text(`Recorded state of the ${ch.record.replace(/_/g, " ")}: ${ch.from ? stateWords(ch.from, STATE) : "new"} → ${stateWords(ch.to, STATE)}`, { indent: 12 });
    if (e.reason) w.text(`Reason: ${e.reason}`, { indent: 12 });
    if (e.seq !== null) w.text(`Audit entry ${e.seq}, hash ${e.hash}`, { indent: 12, size: 7.5, colour: GREY });
  }

  section(`${n++}. Verification of the audit log`);
  w.field("Checked", venueWhen(c.verification.checked_at, tz));
  w.field("Entries in the audit chain checked", String(c.verification.events_in_chain));
  w.field("Entries in this pack's chronology", String(c.verification.events_in_pack));
  if (!c.verification.problems.length) w.text("Every entry's hash and sequence matched when the pack was made: no inconsistencies were found.");
  else for (const p of c.verification.problems) w.text(`Inconsistency at entry ${p.seq}: ${p.problem}`);

  // Index, then page footers.
  const keep = { page: w.page, y: w.y, pages: w.pages };
  w.page = indexPage; w.y = A4.h - M;
  w.heading("Index", 15);
  for (const s of index) w.text(`${s.title} ......... page ${s.page}`);
  w.page = keep.page; w.y = keep.y;
  const total = w.pages.length;
  w.pages.forEach((pg, i) => pg.drawText(w.clean(`${c.reference} · page ${i + 1} of ${total} · content SHA-256 ${contentSha256.slice(0, 16)}…`),
    { x: M, y: M - 20, size: 7.5, font, color: GREY }));
  return doc.save({ useObjectStreams: false });
}

/** The ZIP: pack.pdf, pack.json (the content exactly as hashed), the evidence files and a manifest. */
export function assemblePack(reference: string, contentText: string, contentSha256: string, pdf: Uint8Array,
                             evidence: Array<{ name: string; bytes: Uint8Array }>, madeAt: Date)
  : { zip: Uint8Array; files: PackFile[]; sha256: string } {
  const json = new TextEncoder().encode(contentText);
  const entries: Array<{ name: string; bytes: Uint8Array }> = [{ name: "pack.pdf", bytes: pdf }, { name: "pack.json", bytes: json }, ...evidence];
  const files: PackFile[] = entries.map((e) => ({ name: e.name, sha256: sha256Hex(e.bytes), bytes: e.bytes.length }));
  const manifest = new TextEncoder().encode(JSON.stringify({ reference, content_sha256: contentSha256, files }, null, 2));
  files.push({ name: "manifest.json", sha256: sha256Hex(manifest), bytes: manifest.length });
  const zip = zipSync(Object.fromEntries([...entries, { name: "manifest.json", bytes: manifest }]
    .map((e) => [e.name, [e.bytes, { mtime: madeAt }]])), { level: 6 });
  return { zip, files, sha256: sha256Hex(zip) };
}
