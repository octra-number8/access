import type { Metadata } from "next";
import { Hanken_Grotesk } from "next/font/google";
import Image from "next/image";
import Link from "next/link";
import { supabaseServer } from "@/lib/supabase/server";
import { signOut } from "./actions";
import "./globals.css";

// Self-hosted at build time by next/font: browsers never contact Google. (From OCTRA Induct.)
const hanken = Hanken_Grotesk({ subsets: ["latin"], variable: "--font-hanken", display: "swap" });

export const metadata: Metadata = {
  title: { default: "Octra Access", template: "%s · Octra Access" },
  description: "Contractor access, inductions and permit-to-work records",
  icons: { icon: "/brand/octra-favicon.png" },
};

export default async function RootLayout({ children }: { children: React.ReactNode }) {
  const { data: auth } = await (await supabaseServer()).auth.getUser();
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
            {auth.user ? <form action={signOut} className="ml-auto"><button type="submit" className="secondary">Sign out</button></form> : null}
          </div>
        </header>
        <main id="main" className="mx-auto max-w-5xl px-4 py-6">{children}</main>
      </body>
    </html>
  );
}
