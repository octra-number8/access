import { type ClassConfig, noticeText, STEP_KIND } from "@/lib/permits";
import { answersOf } from "@/lib/screening/content";

const yesNo = (v: boolean | undefined) => (v === undefined ? "Not chosen" : v ? "Yes" : "No");

/** A class configuration in plain English, for the author and for the authority deciding it. */
export function ConfigView({ config, names }: { config: ClassConfig; names: Map<string, string> }) {
  const groups = [...new Set(config.route.map((s) => s.group))].sort((a, b) => a - b);
  return (
    <div className="stack">
      <div>
        <h4 className="m-0">Approval route</h4>
        {config.route.length === 0 ? <p>No steps yet.</p> : groups.map((g) => (
          <p key={g} className="m-0">Group {g}{g > 1 ? " (after group " + (g - 1) + ")" : ""}: {config.route.filter((s) => s.group === g)
            .map((s) => `${s.name} (${STEP_KIND[s.kind] ?? s.kind}${s.when ? `, only when the job touches ${names.get(s.when.system_type_id) ?? "a system type"}` : ""})`).join("; ")}</p>
        ))}
      </div>
      <div>
        <h4 className="m-0">Questions for the applicant</h4>
        {config.questions.length === 0 ? <p className="m-0">None.</p> : (
          <ul>{config.questions.map((q) => <li key={q.key}>{q.text} <span className="muted">({answersOf(q).map((o) => o.text).join(" / ")})</span></li>)}</ul>
        )}
      </div>
      <p className="m-0"><strong>Notice:</strong> {noticeText(config.notice)}</p>
      <p className="m-0"><strong>Needs physical controls</strong> (isolation, impairment or fire watch): {yesNo(config.requires_physical_controls)}
        {config.requires_physical_controls ? <span className="muted"> — cannot be issued until live controls are available</span> : null}</p>
      <p className="m-0"><strong>Late-notice exceptions prohibited:</strong> {yesNo(config.override_prohibited)}</p>
      <p className="m-0"><strong>Team evidence:</strong> {config.evidence ? (
        [...config.evidence.induction_course_ids.map((i) => `induction: ${names.get(i) ?? "a course"}`),
         ...config.evidence.team_competency_type_ids.map((i) => `everyone: ${names.get(i) ?? "a competency"}`),
         ...config.evidence.supervisor_competency_type_ids.map((i) => `supervisor: ${names.get(i) ?? "a competency"}`)].join("; ") || "None (stated)"
      ) : "Not stated"}</p>
      <div>
        <h4 className="m-0">Submission declaration</h4>
        {config.submission_declaration.length === 0 ? <p className="m-0">Not written.</p> : <ul>{config.submission_declaration.map((d, i) => <li key={i}>{d}</li>)}</ul>}
      </div>
      <div>
        <h4 className="m-0">Acceptance declaration</h4>
        {config.acceptance_declaration.length === 0 ? <p className="m-0">Not written.</p> : <ul>{config.acceptance_declaration.map((d, i) => <li key={i}>{d}</li>)}</ul>}
      </div>
    </div>
  );
}
