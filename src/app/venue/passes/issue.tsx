"use client";

import { useActionState } from "react";
import { Blocked } from "@/components/Blocked";
import { Qr } from "@/components/Qr";
import { type IssuedCard, issueCard } from "../entry/actions";

// Issuing a printed card (P7-3, 6b-2). Its code exists only in this response: print it now.
// Reloading the page loses it, and the card must then be revoked and issued again.
export function IssueCard({ venueId, people, newKey }: { venueId: string; people: Array<{ id: string; name: string }>; newKey: string }) {
  const [result, run, pending] = useActionState<IssuedCard, FormData>(issueCard, null);
  const card = result?.ok === true && "payload" in result ? result : null;
  return (
    <>
      <form action={run} className="stack no-print">
        <input type="hidden" name="key" value={newKey} />
        <input type="hidden" name="venue_id" value={venueId} />
        <label>Person<select name="person_id" required defaultValue="">
          <option value="">— Choose —</option>
          {people.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
        </select></label>
        <button type="submit" disabled={pending || !!card}>{pending ? "Working…" : "Issue card"}</button>
        <div aria-live="polite">{result?.ok === false ? <Blocked what="Issuing this card" denial={result} /> : null}</div>
      </form>
      {card ? (
        <>
          <p className="notice notice-done no-print">{card.message}. Print it now: the code is shown only once and is not kept. <button type="button" onClick={() => window.print()}>Print card</button>{" "}
            <a href="/venue/passes">Issue another</a></p>
          <div className="panel" style={{ width: "85.6mm", minHeight: "54mm", padding: "4mm", display: "flex", gap: "4mm", alignItems: "center", background: "#fff", color: "#000" }}>
            <Qr value={card.payload} label={`Pass ${card.pass_number}`} size={150} />
            <div>
              <p style={{ fontWeight: 800, margin: 0 }}>{card.person}</p>
              <p style={{ margin: 0 }}>{card.venue}</p>
              <p style={{ fontWeight: 800, fontSize: "1.25rem", margin: ".25rem 0" }}>{card.pass_number}</p>
              <p style={{ fontSize: ".7rem", margin: 0 }}>Entry pass only. Not permission to work. Show photo ID with this card. If found, return to the venue.</p>
            </div>
          </div>
        </>
      ) : null}
    </>
  );
}
