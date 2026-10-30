// What the navigation shell offers each signed-in person. Display only: it decides which pages are
// worth listing, never what anyone may do. Every page and every action still asks the server, and a
// page left out here is still reachable from the home page and from links elsewhere.
// Appointment-based entries follow the actions the person's in-force appointments allow, so a permit
// issuer is not shown venue set-up and a gate operator sees the gate.

export interface NavItem { href: string; label: string; badge?: number }
export interface NavGroup { label: string; items: NavItem[] }

export interface NavInput {
  personLinked: boolean;
  tenantAdmin: boolean;
  organisations: Array<{ id: string; role: string }>;
  platformAdmin: boolean;
  /** Action codes allowed by the person's in-force appointments, across all venues. */
  actions: string[];
  unread: number;
}

const any = (codes: string[], test: (code: string) => boolean) => codes.some(test);
const prefix = (...ps: string[]) => (code: string) => ps.some((p) => code.startsWith(p));
const exact = (...cs: string[]) => (code: string) => cs.includes(code);

export function buildNavigation(n: NavInput): NavGroup[] {
  const a = n.actions;
  const appointee = a.length > 0;
  const orgAdmin = n.organisations.length > 0;
  const groups: NavGroup[] = [];
  const add = (label: string, items: Array<NavItem | false>) => {
    const kept = items.filter((i): i is NavItem => i !== false);
    if (kept.length) groups.push({ label, items: kept });
  };

  const permitWork = any(a, prefix("permit.", "permit_step.", "work_package.", "screening.", "external_reference."));
  const controls = any(a, prefix("isolation.", "impairment.", "fire_watch.", "exclusion_zone.", "custody", "control."));
  const access = any(a, prefix("access."));

  add("Work", [
    { href: "/", label: "Home" },
    (appointee || n.tenantAdmin || orgAdmin) && { href: "/dashboard", label: "Dashboard" },
    appointee && { href: "/review", label: "Decisions" },
    (permitWork || controls || n.tenantAdmin) && { href: "/live", label: "Live work" },
    (orgAdmin || n.tenantAdmin || permitWork) && { href: "/jobs", label: "Jobs" },
    (controls || n.tenantAdmin) && { href: "/controls", label: "Controls" },
    (access || n.personLinked || n.tenantAdmin) && { href: "/visits", label: "Visits" },
    (any(a, prefix("emergency.")) || n.tenantAdmin || orgAdmin) && { href: "/emergency", label: "Emergency work" },
    (appointee || n.tenantAdmin || orgAdmin) && { href: "/reports", label: "Reports" },
  ]);

  add("Gate", [
    any(a, exact("gate.operate")) && { href: "/gate", label: "Gate" },
    any(a, exact("gate.override")) && { href: "/gate/overrides", label: "Gate overrides" },
    any(a, exact("gate.reconcile", "gate.reconcile_work")) && { href: "/gate/reconcile", label: "Reconciliation" },
    any(a, exact("induction.facilitate")) && { href: "/facilitate", label: "Facilitated induction" },
  ]);

  add("Venue", [
    n.tenantAdmin && { href: "/venue/setup", label: "Set-up checklist" },
    n.tenantAdmin && { href: "/venue", label: "Organisations and people" },
    (n.tenantAdmin || any(a, exact("appointment.grant", "appointment.revoke", "delegation.grant", "appointment_type.approve", "appointment_type.reject")))
      && { href: "/venue/authority", label: "Authority" },
    n.tenantAdmin && { href: "/venue/places", label: "Places and systems" },
    n.tenantAdmin && { href: "/venue/evidence", label: "Evidence" },
    n.tenantAdmin && { href: "/venue/events", label: "Events" },
    (n.tenantAdmin || any(a, prefix("induction_course.", "course_version."))) && { href: "/venue/inductions", label: "Inductions" },
    (n.tenantAdmin || any(a, prefix("screening_set."))) && { href: "/venue/screening", label: "Activity screening" },
    (n.tenantAdmin || any(a, prefix("permit_class_version.", "venue_calendar.", "restriction_window.", "control_rule."))) && { href: "/venue/permits", label: "Permit set-up" },
    (n.tenantAdmin || any(a, prefix("entry_rule_version.", "gate_point."))) && { href: "/venue/entry", label: "Entry set-up" },
    (n.tenantAdmin || any(a, prefix("pass."))) && { href: "/venue/passes", label: "Card passes" },
    n.tenantAdmin && { href: "/venue/chasing", label: "Reminders" },
    (n.tenantAdmin || any(a, prefix("retention."))) && { href: "/venue/retention", label: "Retention" },
    (n.tenantAdmin || any(a, prefix("legal_hold."))) && { href: "/venue/holds", label: "Legal holds" },
  ]);

  add("You", [
    n.personLinked && { href: "/me", label: "Your details" },
    n.personLinked && { href: "/pass", label: "Your pass" },
    ...n.organisations.map((o) => ({ href: `/organisation/${o.id}`, label: n.organisations.length > 1 ? `Organisation (${o.role})` : "Your organisation" })),
    { href: "/inbox", label: "Inbox", badge: n.unread || undefined },
  ]);

  if (n.platformAdmin) add("Platform", [{ href: "/operations", label: "Platform operations" }]);
  return groups;
}

/** The item a path belongs to: the longest matching href, so /venue/places is not also /venue. */
export function currentHref(groups: NavGroup[], path: string): string | null {
  let best: string | null = null;
  for (const g of groups) for (const i of g.items) {
    const hit = i.href === "/" ? path === "/" : path === i.href || path.startsWith(i.href + "/");
    if (hit && (!best || i.href.length > best.length)) best = i.href;
  }
  return best;
}
