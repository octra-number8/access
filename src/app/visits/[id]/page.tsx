import { randomUUID } from "node:crypto";
import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { type Purpose, visitState } from "@/lib/gate";
import { venueTime } from "@/lib/permits";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { organisationPeople } from "../../jobs/data";
import { approveAddition, cancelAccess, changeRoster, consentAccess, decideAccess, linkWorkRequest } from "../actions";

export const metadata = { title: "Visit" };

interface Consent { area_id: string; area: string; organisation_id: string | null; organisation: string | null; state: "given" | "refused" | "waiting" }

// One visit (Q121–Q126). Forms are offered by what the visit's state allows; whether this
// user may act is decided by the database when they try, and refusals say why.
export default async function VisitPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ link_failed?: string }> }) {
  const session = await getSession();
  const { id } = await params;
  if (!session) redirect(`/sign-in?next=/visits/${id}`);
  const db = await supabaseServer();
  const { data: v } = await db.from("access_authorisation").select("*").eq("id", id).maybeSingle();
  if (!v) notFound();
  const [{ data: venue }, { data: org }, { data: config }, { data: roster }, { data: consentRows }, { data: attendance }, { data: links }, { data: areaRows }, consents] = await Promise.all([
    db.from("venue").select("id, name, timezone").eq("id", v.venue_id).single(),
    db.from("organisation").select("id, legal_name").eq("id", v.organisation_id).maybeSingle(),
    db.from("venue_config_version").select("content").eq("id", v.purpose_config_id).maybeSingle(),
    db.from("access_roster_member").select("id, person_id, added_after_approval, approved_at, removed_at, removal_reason").eq("authorisation_id", id).order("created_at"),
    db.from("access_consent").select("area_id, outcome, reason, decider_person_id, created_at").eq("authorisation_id", id),
    db.from("visit_attendance").select("id, person_id, arrived_at, left_at").eq("authorisation_id", id).order("arrived_at", { ascending: false }),
    db.from("access_work_request").select("work_package_id").eq("authorisation_id", id),
    db.from("area").select("id, name").in("id", v.area_ids as string[]),
    db.rpc("access_consents_needed", { p_authorisation_id: id }).then((r) => (r.data as Consent[] | null) ?? []),
  ]);
  const tz = venue?.timezone ?? "Europe/London";
  const purpose = ((config?.content as { purposes?: Purpose[] } | undefined)?.purposes ?? []).find((p) => p.key === v.purpose_key);
  const personIds = [...new Set([...(roster ?? []).map((m) => m.person_id), ...(attendance ?? []).map((a) => a.person_id), v.requested_by_person_id,
    v.decided_by_person_id, ...(consentRows ?? []).map((c) => c.decider_person_id)].filter(Boolean) as string[])];
  const [{ data: people }, { data: jobs }] = await Promise.all([
    db.from("person").select("id, given_name, family_name").in("id", personIds),
    db.from("work_package").select("id, reference, status, venue_id, performing_organisation_id").eq("venue_id", v.venue_id)
      .eq("performing_organisation_id", v.organisation_id).order("created_at", { ascending: false }),
  ]);
  const name = (pid: string | null) => {
    const p = (people ?? []).find((x) => x.id === pid);
    return p ? `${p.given_name} ${p.family_name}` : "Someone";
  };
  const linked = new Set((links ?? []).map((l) => l.work_package_id));
  const conditions = v.conditions as { escort?: string | null; no_photography?: boolean; confidentiality?: boolean; other?: string | null };
  const current = (roster ?? []).filter((m) => !m.removed_at);
  const ended = new Date(v.ends_at).getTime() < Date.now();
  const open = v.status === "requested" || (v.status === "approved" && !ended);
  const isOrgAdmin = session.organisationAdmin.some((o) => o.organisation_id === v.organisation_id);
  const isVenueSide = session.tenantAdminCustomerIds.includes(v.customer_id) || session.appointmentVenueIds.includes(v.venue_id);
  const addable = isOrgAdmin || isVenueSide ? (await organisationPeople(db, v.organisation_id)).filter((p) => !current.some((m) => m.person_id === p.id)) : [];
  const { link_failed: linkFailed } = await searchParams;
  const k = () => randomUUID();

  return (
    <>
      <p><Link href="/visits">All visits</Link></p>
      <h1>Visit {v.reference}</h1>
      <p><strong>{visitState(v.status, v.ends_at)}</strong>{v.decision_reason ? <span className="muted"> · {name(v.decided_by_person_id)}: {v.decision_reason}</span> : null}</p>
      {linkFailed ? (
        <p className="notice notice-blocked">The job {(jobs ?? []).find((j) => j.id === linkFailed)?.reference ?? ""} was saved, but it could not be linked to this visit. Link it below, or ask the venue.</p>
      ) : null}
      <dl className="facts">
        <dt>Organisation</dt><dd>{org?.legal_name ?? "—"}</dd>
        <dt>Venue</dt><dd>{venue?.name}</dd>
        <dt>Purpose</dt><dd>{purpose ? <>{purpose.name}. Allows: {purpose.allows}. Not allowed: {purpose.prohibits}.</> : v.purpose_key}</dd>
        <dt>About</dt><dd>{v.description}</dd>
        <dt>Where</dt><dd>{(areaRows ?? []).map((a) => a.name).join(", ")}</dd>
        <dt>When</dt><dd>{venueTime(v.starts_at, tz)} to {venueTime(v.ends_at, tz)}</dd>
        <dt>Asked by</dt><dd>{name(v.requested_by_person_id)}, {venueTime(v.created_at, tz)}</dd>
        {v.status === "approved" ? (
          <><dt>Conditions</dt><dd>{[conditions.escort ? `Escort: ${conditions.escort}` : purpose?.escort === "always" ? "Escorted" : null,
            conditions.no_photography ? "No photography" : null, conditions.confidentiality ? "Confidential" : null, conditions.other || null]
            .filter(Boolean).join("; ") || "None"}</dd></>
        ) : null}
      </dl>
      <p className="muted">This visit is not permission to work.</p>

      {consents.length ? (
        <>
          <h2>Occupier consent</h2>
          <ul>{consents.map((c) => {
            const rec = (consentRows ?? []).find((r) => r.area_id === c.area_id);
            return (
              <li key={c.area_id}>{c.area}{c.organisation ? ` (${c.organisation})` : ""}: {c.state === "waiting" ? "waiting" : c.state === "given" ? "consent given" : "consent refused"}
                {rec ? <span className="muted"> · {name(rec.decider_person_id)}: {rec.reason}</span> : null}
                {c.state === "waiting" && c.organisation_id && v.status === "requested" ? (
                  <details><summary>Record the occupier&apos;s decision</summary>
                    {(["given", "refused"] as const).map((outcome) => (
                      <ActionForm key={outcome} action={consentAccess} what={outcome === "given" ? "Giving consent" : "Refusing consent"}
                        submitLabel={outcome === "given" ? "Consent" : "Refuse consent"} secondary={outcome === "refused"}>
                        <input type="hidden" name="key" value={k()} />
                        <input type="hidden" name="id" value={v.id} />
                        <input type="hidden" name="area_id" value={c.area_id} />
                        <input type="hidden" name="organisation_id" value={c.organisation_id!} />
                        <input type="hidden" name="outcome" value={outcome} />
                        <label>Reason<input name="reason" required /></label>
                      </ActionForm>
                    ))}
                  </details>
                ) : null}
              </li>
            );
          })}</ul>
        </>
      ) : null}

      {v.status === "requested" && isVenueSide ? (
        <>
          <h2>Decision</h2>
          <ActionForm action={decideAccess} what="Approving this visit" submitLabel="Approve">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="id" value={v.id} />
            <input type="hidden" name="row_version" value={v.row_version} />
            <input type="hidden" name="outcome" value="approve" />
            <label>Escort{purpose?.escort === "always" ? " (required for this purpose)" : " (optional)"}<input name="escort" placeholder="Name or role" /></label>
            <label className="inline"><input type="checkbox" name="no_photography" /> No photography</label>
            <label className="inline"><input type="checkbox" name="confidentiality" /> Confidential</label>
            <label>Other conditions<input name="other" /></label>
            <label>Reason<input name="reason" required /></label>
            <p className="muted">You cannot approve a visit you asked for, or one by an organisation you work with. Every area must be within your appointment.</p>
          </ActionForm>
          <ActionForm action={decideAccess} what="Refusing this visit" submitLabel="Refuse" secondary>
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="id" value={v.id} />
            <input type="hidden" name="row_version" value={v.row_version} />
            <input type="hidden" name="outcome" value="refuse" />
            <label>Reason<input name="reason" required /></label>
          </ActionForm>
        </>
      ) : null}

      <h2>Who is coming</h2>
      <ul>{(roster ?? []).map((m) => (
        <li key={m.id}>{name(m.person_id)}
          {m.removed_at ? <span className="muted"> · removed: {m.removal_reason}</span>
            : m.added_after_approval && !m.approved_at ? <span className="tag">Added after approval: not yet approved, cannot enter on this visit</span> : null}
          {m.added_after_approval && !m.approved_at && !m.removed_at && isVenueSide && v.status === "approved" && !ended ? (
            <ActionForm action={approveAddition} what="Approving this addition" submitLabel="Approve this addition">
              <input type="hidden" name="key" value={k()} />
              <input type="hidden" name="member_id" value={m.id} />
            </ActionForm>
          ) : null}
        </li>
      ))}</ul>
      {open && (isOrgAdmin || isVenueSide) ? (
        <details><summary>Change who is coming</summary>
          <ActionForm action={changeRoster} what="Changing the roster" submitLabel="Change roster">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="id" value={v.id} />
            {current.length ? <fieldset className="stack"><legend>Remove (takes effect at once)</legend>
              {current.map((m) => <label className="inline" key={m.id}><input type="checkbox" name="remove" value={m.id} /> {name(m.person_id)}</label>)}
            </fieldset> : null}
            {addable.length ? <fieldset className="stack"><legend>Add{v.status === "approved" ? " (needs approval before they can enter)" : ""}</legend>
              {addable.map((p) => <label className="inline" key={p.id}><input type="checkbox" name="add" value={p.id} /> {p.name}</label>)}
            </fieldset> : null}
            <label>Reason<input name="reason" required /></label>
            <p className="muted">Changing the purpose, places or times needs a new request.</p>
          </ActionForm>
        </details>
      ) : null}

      <h2>Arrivals and departures</h2>
      {(attendance ?? []).length === 0 ? <p>None recorded.</p> : (
        <ul>{(attendance ?? []).map((a) => (
          <li key={a.id}>{name(a.person_id)}: arrived {venueTime(a.arrived_at, tz)}{a.left_at ? `, left ${venueTime(a.left_at, tz)}` : ", not recorded as leaving"}</li>
        ))}</ul>
      )}

      <h2>Work raised from this visit</h2>
      <p className="muted">A visit never becomes a permit. A job started from it follows the normal screening and permit route.</p>
      {(jobs ?? []).filter((j) => linked.has(j.id)).length === 0 ? <p>None.</p> : (
        <ul>{(jobs ?? []).filter((j) => linked.has(j.id)).map((j) => <li key={j.id}><Link href={`/jobs/${j.id}`}>{j.reference}</Link></li>)}</ul>
      )}
      {v.status === "approved" && isOrgAdmin ? (
        <>
          <p><Link href={`/jobs/new?visit=${v.id}`} className="button secondary">Start a job from this visit</Link></p>
          {(jobs ?? []).filter((j) => !linked.has(j.id)).length ? (
            <details><summary>Link an existing job</summary>
              <ActionForm action={linkWorkRequest} what="Linking this job" submitLabel="Link job">
                <input type="hidden" name="key" value={k()} />
                <input type="hidden" name="id" value={v.id} />
                <label>Job<select name="work_package_id" required>{(jobs ?? []).filter((j) => !linked.has(j.id)).map((j) => (
                  <option key={j.id} value={j.id}>{j.reference}</option>))}</select></label>
              </ActionForm>
            </details>
          ) : null}
        </>
      ) : null}

      {open && (isOrgAdmin || isVenueSide) ? (
        <>
          <h2>{v.status === "requested" ? "Withdraw the request" : "Cancel the visit"}</h2>
          <ActionForm action={cancelAccess} what={v.status === "requested" ? "Withdrawing this request" : "Cancelling this visit"}
            submitLabel={v.status === "requested" ? "Withdraw" : "Cancel visit"} secondary>
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="id" value={v.id} />
            <input type="hidden" name="row_version" value={v.row_version} />
            <label>Reason<input name="reason" required /></label>
          </ActionForm>
        </>
      ) : null}
    </>
  );
}
