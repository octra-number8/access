import type { Metadata } from "next";
import Link from "next/link";
import "./globals.css";

export const metadata: Metadata = {
  title: "Octra Access",
  description: "Contractor access and permit-to-work records",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en-GB">
      <body>
        <a className="skip" href="#main">Skip to content</a>
        <header className="site-header">
          <Link href="/" className="brand">Octra Access</Link>
        </header>
        <main id="main">{children}</main>
      </body>
    </html>
  );
}
