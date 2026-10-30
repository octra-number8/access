import { describe, expect, it } from "vitest";
import { buildNavigation, currentHref, type NavInput } from "./navigation";

const base: NavInput = { personLinked: true, tenantAdmin: false, organisations: [], platformAdmin: false, actions: [], unread: 0 };
const hrefs = (n: Partial<NavInput>) => buildNavigation({ ...base, ...n }).flatMap((g) => g.items.map((i) => i.href));

describe("buildNavigation", () => {
  it("shows a permit issuer the work pages but no venue set-up or gate", () => {
    const h = hrefs({ actions: ["permit.issue", "permit_step.decide", "permit.lift_suspension"] });
    expect(h).toEqual(expect.arrayContaining(["/review", "/live", "/jobs", "/dashboard"]));
    expect(h.filter((x) => x.startsWith("/venue") || x.startsWith("/gate"))).toEqual([]);
  });

  it("shows a gate operator the gate, and overrides only with the override action", () => {
    expect(hrefs({ actions: ["gate.operate"] })).toContain("/gate");
    expect(hrefs({ actions: ["gate.operate"] })).not.toContain("/gate/overrides");
    expect(hrefs({ actions: ["gate.operate", "gate.override"] })).toContain("/gate/overrides");
  });

  it("shows a controls authority the controls desk", () => {
    expect(hrefs({ actions: ["isolation.authorise"] })).toEqual(expect.arrayContaining(["/controls", "/live"]));
  });

  it("shows a tenant administrator venue set-up but not the gate, which needs an appointment", () => {
    const h = hrefs({ tenantAdmin: true });
    expect(h).toEqual(expect.arrayContaining(["/venue/setup", "/venue", "/venue/authority", "/venue/places"]));
    expect(h).not.toContain("/gate");
    expect(h).not.toContain("/review");
  });

  it("shows a contractor administrator their organisation and jobs only", () => {
    const h = hrefs({ organisations: [{ id: "o1", role: "primary" }] });
    expect(h).toEqual(expect.arrayContaining(["/organisation/o1", "/jobs", "/me"]));
    expect(h.filter((x) => x.startsWith("/venue") || x === "/review" || x === "/live")).toEqual([]);
  });

  it("lists platform operations only for a platform administrator", () => {
    expect(hrefs({})).not.toContain("/operations");
    expect(hrefs({ platformAdmin: true })).toContain("/operations");
  });

  it("carries the unread count on the inbox", () => {
    const inbox = buildNavigation({ ...base, unread: 3 }).flatMap((g) => g.items).find((i) => i.href === "/inbox");
    expect(inbox?.badge).toBe(3);
  });
});

describe("currentHref", () => {
  const groups = buildNavigation({ ...base, tenantAdmin: true, actions: ["gate.operate", "gate.override"] });
  it("picks the most specific page", () => {
    expect(currentHref(groups, "/venue/places")).toBe("/venue/places");
    expect(currentHref(groups, "/venue")).toBe("/venue");
    expect(currentHref(groups, "/gate/overrides")).toBe("/gate/overrides");
    expect(currentHref(groups, "/jobs/123")).toBe("/jobs");
  });
  it("matches home only on the home page", () => {
    expect(currentHref(groups, "/")).toBe("/");
    expect(currentHref(groups, "/permits/1")).toBeNull();
  });
});
