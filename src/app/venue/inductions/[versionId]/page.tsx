import { randomUUID } from "node:crypto";
import Link from "next/link";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { Blocked, type Denial } from "@/components/Blocked";
import { BlockView } from "@/components/learner/block-view";
import type { LearnerBlock } from "@/components/learner/types";
import type { CourseContent } from "@/lib/induction/content";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { attachMedia, decideVersion, importContent, resolveOpenPoint, saveSettings, saveStructure, submitVersion } from "../actions";

export const metadata = { title: "Induction version" };

export default async function Version({ params }: { params: Promise<{ versionId: string }> }) {
  const { versionId } = await params;
  const session = await getSession();
  if (!session) redirect(`/sign-in?next=/venue/inductions/${versionId}`);
  const db = await supabaseServer();
  const { data: cc } = await db.rpc("course_content", { p_version_id: versionId });
  if (!cc?.ok) return <Blocked what="This induction" denial={cc as Denial} />;
  const content = cc.content as CourseContent;
  const problems = (cc.problems ?? []) as string[];
  const [{ data: v }, { data: points }] = await Promise.all([
    db.from("course_version").select("*").eq("id", versionId).single(),
    db.from("course_open_point").select("*").eq("course_version_id", versionId).order("created_at"),
  ]);
  const { data: course } = await db.from("induction_course").select("id, title, venue_id").eq("id", v!.course_id).single();
  const draft = v!.status === "draft";
  const k = () => randomUUID();

  return (
    <>
      <p>{session.tenantAdminCustomerIds.includes(v!.customer_id)
        ? <Link href="/venue/inductions">All inductions</Link> : <Link href="/review">Decisions waiting for you</Link>}</p>
      <h1>{course?.title} — version {v!.version_no}</h1>
      <p>Recorded state: <strong>{v!.status.replace("_", " ")}</strong>{v!.return_reason && draft ? <> · Returned: {v!.return_reason}</> : null}</p>

      {problems.length > 0 && (draft || v!.status === "in_review") ? (
        <div className="notice notice-blocked">
          <p className="notice-title">Before this can be reviewed and published</p>
          <ul>{problems.map((p) => <li key={p}>{p}</li>)}</ul>
        </div>
      ) : null}

      {draft ? (
        <>
          <h2>Import content</h2>
          <p className="muted">An induction brief (.md) or an OCTRA Induct starter template (.json). Importing replaces this draft&apos;s content. Anything the source does not decide becomes an open point.</p>
          <ActionForm action={importContent} what="Importing" submitLabel="Import">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="version_id" value={versionId} />
            <label>File<input name="file" type="file" accept=".md,.json,text/markdown,application/json" required /></label>
          </ActionForm>
        </>
      ) : null}

      <h2>Open points</h2>
      {(points ?? []).length === 0 ? <p className="muted">None.</p> : null}
      {(points ?? []).map((p) => (
        <div className="panel" key={p.id}>
          <p className="mt-0">{p.text}{p.owner_text ? <span className="muted"> — to decide: {p.owner_text}</span> : null}</p>
          {p.resolved_at ? <p className="muted">Resolved: {p.resolution}</p> : draft ? (
            <ActionForm action={resolveOpenPoint} what="Resolving this point" submitLabel="Record resolution">
              <input type="hidden" name="key" value={k()} />
              <input type="hidden" name="open_point_id" value={p.id} />
              <input type="hidden" name="row_version" value={p.row_version} />
              <label>How it was resolved<textarea name="resolution" required rows={2} /></label>
            </ActionForm>
          ) : null}
        </div>
      ))}

      {draft && content.modules.length > 0 ? (
        <>
          <h2>Reading times and safety-critical questions</h2>
          <ActionForm action={saveStructure} what="Saving" submitLabel="Save">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="version_id" value={versionId} />
            {content.modules.map((m) => (
              <fieldset key={m.key}><legend>{m.title}</legend>
                <label>Minimum reading time (seconds)<input name={`min_${m.key}`} type="number" min={0} required defaultValue={m.min_seconds} /></label>
                <label>Applies to
                  <select name={`kind_${m.key}`} defaultValue={m.kind}>
                    <option value="core">Everyone</option><option value="role">A role</option>
                    <option value="area">An area</option><option value="event_phase">An event phase</option>
                  </select>
                </label>
              </fieldset>
            ))}
            <fieldset><legend>Safety-critical questions</legend>
              <p className="muted">If the settings require it, getting any of these wrong fails the attempt whatever the score.</p>
              {content.questions.map((q) => (
                <label className="inline" key={q.key}><input type="checkbox" name={`critical_${q.key}`} defaultChecked={q.safety_critical} /> {q.stem}</label>
              ))}
            </fieldset>
          </ActionForm>
        </>
      ) : null}

      {draft ? (
        <>
          <h2>Assessment and validity</h2>
          <p className="muted">Set by the venue. There are no defaults. The source review proposed a pass mark of 80% with every safety-critical question right, three attempts and 12 months&apos; validity (Q44, Q45); those are suggestions only.</p>
          <ActionForm action={saveSettings} what="Saving the settings" submitLabel="Save settings">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="version_id" value={versionId} />
            <label>Pass mark (%)<input name="pass_mark" type="number" min={1} max={100} defaultValue={v!.pass_mark_percent ?? ""} /></label>
            <label>Every safety-critical question must be right
              <select name="all_critical" defaultValue={v!.all_critical_required === null ? "" : v!.all_critical_required ? "yes" : "no"}>
                <option value="">— Choose —</option><option value="yes">Yes</option><option value="no">No</option>
              </select>
            </label>
            <label>Attempts before an assisted review<input name="max_attempts" type="number" min={1} max={20} defaultValue={v!.max_attempts ?? ""} /></label>
            <label>Wait between attempts (minutes)<input name="retry_delay" type="number" min={0} max={10080} defaultValue={v!.retry_delay_minutes ?? ""} /></label>
            <label>Shuffle answer options
              <select name="shuffle" defaultValue={v!.shuffle_options === null ? "" : v!.shuffle_options ? "yes" : "no"}>
                <option value="">— Choose —</option><option value="yes">Yes</option><option value="no">No</option>
              </select>
            </label>
            <label>A completion stays valid
              <select name="validity_mode" defaultValue={v!.validity_mode ?? ""}>
                <option value="">— Choose —</option><option value="days_from_completion">For a number of days</option><option value="fixed_date">Until a date</option>
              </select>
            </label>
            <label>Number of days (if for a number of days)<input name="validity_days" type="number" min={1} max={3660} defaultValue={v!.validity_days ?? ""} /></label>
            <label>Date (if until a date)<input name="validity_until" type="date" defaultValue={v!.validity_until ? String(v!.validity_until).slice(0, 10) : ""} /></label>
            <label>Declaration signed with
              <select name="signature_mode" defaultValue={v!.signature_mode ?? ""}>
                <option value="">— Choose —</option><option value="typed">Typed name</option>
              </select>
            </label>
          </ActionForm>
        </>
      ) : null}

      <h2>Preview</h2>
      {content.modules.map((m, mi) => (
        <div className="panel" key={m.key}>
          <p className="muted mt-0">Section {mi + 1} · minimum {m.min_seconds}s</p>
          <h3 className="mt-0">{m.title}</h3>
          <div className="flex flex-col gap-3">
            {m.blocks.map((b, bi) => {
              const missing = ["image", "video", "document"].includes(b.type) && !(b as { media_id: string | null }).media_id;
              const needsCaptions = b.type === "video" && !b.caption_media_id;
              return (
                <div key={bi}>
                  <BlockView block={b as LearnerBlock} courseId={course!.id} />
                  {draft && (missing || needsCaptions) ? (
                    <ActionForm action={attachMedia} what="Attaching this file" submitLabel={missing ? "Upload file" : "Upload captions"}>
                      <p className="muted">{missing ? `This ${b.type} needs its file${"source_file" in b && b.source_file ? ` (${b.source_file})` : ""}.` : "This video needs a captions file (WebVTT)."}</p>
                      <input type="hidden" name="key" value={k()} />
                      <input type="hidden" name="version_id" value={versionId} />
                      <input type="hidden" name="venue_id" value={course!.venue_id} />
                      <input type="hidden" name="module_key" value={m.key} />
                      <input type="hidden" name="block_index" value={bi} />
                      <input type="hidden" name="field" value={missing ? "media_id" : "caption_media_id"} />
                      <label>File<input name="file" type="file" required /></label>
                    </ActionForm>
                  ) : null}
                </div>
              );
            })}
          </div>
          {content.questions.filter((q) => q.module_key === m.key).map((q) => (
            <div key={q.key} className="mt-3 rounded-md border border-line px-4 py-3">
              <p className="mt-0 font-semibold text-ink">{q.stem}{q.safety_critical ? <> <span className="tag ml-2">Safety-critical</span></> : null}
                <span className="muted text-sm font-normal"> ({q.placement === "module" ? "after this section" : "at the end"})</span></p>
              <ul>{q.options.map((o) => <li key={o.key}>{o.text}{o.correct ? <strong> — correct</strong> : null}</li>)}</ul>
              <p className="muted text-sm">Explanation: {q.explanation || "—"}</p>
            </div>
          ))}
        </div>
      ))}
      {content.declaration.length > 0 ? (
        <div className="panel"><h3 className="mt-0">Declaration</h3><ul>{content.declaration.map((d) => <li key={d.key}>{d.text}</li>)}</ul></div>
      ) : null}

      {draft ? (
        <>
          <h2>Submit for review</h2>
          <ActionForm action={submitVersion} what="Submitting for review" submitLabel="Submit to the H&S authority">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="version_id" value={versionId} />
          </ActionForm>
        </>
      ) : null}

      {v!.status === "in_review" ? (
        <>
          <h2>Decision</h2>
          <p className="muted">For the venue&apos;s H&amp;S authority. The person who wrote or submitted this version cannot publish it.</p>
          <ActionForm action={decideVersion} what="Publishing" submitLabel="Publish this version">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="version_id" value={versionId} />
            <input type="hidden" name="decision" value="publish" />
          </ActionForm>
          <h3>Or return it</h3>
          <ActionForm action={decideVersion} what="Returning this version" submitLabel="Return to the author" secondary>
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="version_id" value={versionId} />
            <input type="hidden" name="decision" value="return" />
            <label>Why it is being returned<textarea name="reason" required rows={2} /></label>
          </ActionForm>
        </>
      ) : null}
    </>
  );
}
