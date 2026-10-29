import type { Metadata } from "next";
import { Hanken_Grotesk } from "next/font/google";
import Image from "next/image";
import Link from "next/link";
import { supabaseServer } from "@/lib/supabase/server";
import { FlashProvider } from "@/components/Flash";
import { SignOutButton } from "@/components/sign-out-button";
import "./globals.css";

// Self-hosted at build time by next/font: browsers never contact Google. (From OCTRA Induct.)
const hanken = Hanken_Grotesk({ subsets: ["latin"], variable: "--font-hanken", display: "swap" });

export const metadata: Metadata = {
  title: { default: "Octra Access", template: "%s · Octra Access" },
  description: "Contractor access, inductions and permit-to-work records",
  icons: { icon: "/brand/octra-favicon.png" },
};

export default async function RootLayout({ children }: { children: React.ReactNode }) {
  const db = await supabaseServer();
  const { data: auth } = await db.auth.getUser();
  const unread = auth.user ? (await db.from("notification").select("id", { count: "exact", head: true }).is("read_at", null)).count ?? 0 : 0;
  return (
    <html lang="en-GB" className={hanken.variable}>
      <body className="min-h-dvh font-sans antialiased">
        <a className="skip" href="#main">Skip to content</a>
        <header className="border-b border-line bg-surface">
          <div className="mx-auto flex max-w-5xl items-center gap-3 px-4 py-3">
            <Link href="/" className="flex items-center gap-2 font-extrabold text-ink no-underline">
              <Image src="/brand/octra-mark.png" alt="" width={28} height={28} priority />
              Octra Access
            </Link>
            {auth.user ? (
              <div className="ml-auto flex items-center gap-4">
                <Link href="/inbox" className="font-semibold text-ink underline underline-offset-4">Inbox{unread ? ` (${unread} new)` : ""}</Link>
                <SignOutButton />
              </div>
            ) : null}
          </div>
        </header>
        <FlashProvider>
          <main id="main" className="mx-auto max-w-5xl px-4 py-6">{children}</main>
        </FlashProvider>
      </body>
    </html>
  );
}
