import type { Metadata } from "next";
import { Hanken_Grotesk } from "next/font/google";
import Image from "next/image";
import Link from "next/link";
import { supabaseServer } from "@/lib/supabase/server";
import { FlashProvider } from "@/components/Flash";
import { SideNav } from "@/components/side-nav";
import { buildNavigation } from "@/lib/navigation";
import { getSession, type Session } from "@/lib/session";
import "./globals.css";

// Self-hosted at build time by next/font: browsers never contact Google. (From OCTRA Induct.)
const hanken = Hanken_Grotesk({ subsets: ["latin"], variable: "--font-hanken", display: "swap" });

export const metadata: Metadata = {
  title: { default: "Octra Access", template: "%s · Octra Access" },
  description: "Contractor access, inductions and permit-to-work records",
  icons: { icon: "/brand/octra-favicon.png" },
};

interface AppointmentSummary { state: string; type: string; appointee: string; actions: Array<{ code: string }> }

export default async function RootLayout({ children }: { children: React.ReactNode }) {
  const session = await getSession();
  const content = (
    <FlashProvider>
      <main id="main" className="mx-auto max-w-5xl px-4 py-6">{children}</main>
    </FlashProvider>
  );
  return (
    <html lang="en-GB" className={hanken.variable}>
      <body className="min-h-dvh font-sans antialiased">
        <a className="skip" href="#main">Skip to content</a>
        {session ? (
          <div className="shell">
            <SideNav {...await navigationFor(session)} />
            <div className="shell-main">{content}</div>
          </div>
        ) : (
          <>
            <header className="border-b border-line bg-surface">
              <div className="mx-auto flex max-w-5xl items-center gap-3 px-4 py-3">
                <Link href="/" className="shell-brand">
                  <Image src="/brand/octra-mark.png" alt="OCTRA" width={71} height={17} priority />
                  <span>Access</span>
                </Link>
              </div>
            </header>
            {content}
          </>
        )}
      </body>
    </html>
  );
}

// The shell's contents for this person: their pages, who they are and in what capacities.
async function navigationFor(session: Session) {
  const db = await supabaseServer();
  const [ops, mine, unreadRes] = await Promise.all([
    db.rpc("am_platform_admin"),
    db.rpc("my_appointments"),
    db.from("notification").select("id", { count: "exact", head: true }).is("read_at", null),
  ]);
  const inForce = ((mine.data as { appointments?: AppointmentSummary[] } | null)?.appointments ?? []).filter((a) => a.state === "in_force");
  const unread = unreadRes.count ?? 0;
  const roles = [
    ...(session.tenantAdminCustomerIds.length ? ["Tenant administrator"] : []),
    ...(session.organisationAdmin.length ? ["Organisation administrator"] : []),
    ...new Set(inForce.map((a) => a.type)),
  ];
  return {
    groups: buildNavigation({
      personLinked: session.personIds.length > 0,
      tenantAdmin: session.tenantAdminCustomerIds.length > 0,
      organisations: session.organisationAdmin.map((o) => ({ id: o.organisation_id, role: o.role })),
      platformAdmin: ops.data === true,
      actions: [...new Set(inForce.flatMap((a) => a.actions.map((x) => x.code)))],
      unread,
    }),
    who: inForce[0]?.appointee ?? session.email ?? "Signed in",
    roles,
    unread,
  };
}
