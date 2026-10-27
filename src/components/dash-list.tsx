import Link from "next/link";
import type { DashItem } from "@/lib/dashboard";
import { venueTime } from "@/lib/permits";

/** A group of actions: what, who owns it, and when. "Nothing due" when empty; never a count. */
export function DashList({ heading, items, tz, empty = "Nothing due.", level = 2 }: { heading: string; items: DashItem[]; tz: string; empty?: string; level?: 2 | 3 }) {
  const H = level === 2 ? "h2" : "h3";
  const id = `h-${heading.toLowerCase().replace(/[^a-z0-9]+/g, "-")}`;
  return (
    <section aria-labelledby={id}>
      <H id={id}>{heading}</H>
      {items.length === 0 ? <p>{empty}</p> : (
        <div className="table-wrap"><table className="stacked">
          <thead><tr><th scope="col">Record</th><th scope="col">What is needed</th><th scope="col">Who</th><th scope="col">When</th></tr></thead>
          <tbody>{items.map((i, n) => (
            <tr key={n}>
              <td data-label="Record"><Link href={i.link}>{i.title}</Link></td>
              <td data-label="Needed">{i.overdue ? <strong>Overdue: </strong> : null}{i.what}
                {i.items?.length ? <ul className="m-0">{i.items.map((q, k) => <li key={k}>{q}</li>)}</ul> : null}</td>
              <td data-label="Who">{i.who}</td>
              <td data-label="When">{i.at ? <>{i.at_label} {venueTime(i.at, tz)}</> : "—"}</td>
            </tr>
          ))}</tbody>
        </table></div>
      )}
    </section>
  );
}
