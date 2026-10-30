"use client";

import Image from "next/image";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import { currentHref, type NavGroup } from "@/lib/navigation";
import { SignOutButton } from "./sign-out-button";

// The navigation shell: a sidebar on wide screens, a top bar with a Menu button on phones.
// Which pages appear is decided on the server (lib/navigation.ts); this only draws them.
export function SideNav({ groups, who, roles, unread }: { groups: NavGroup[]; who: string; roles: string[]; unread: number }) {
  const path = usePathname();
  const [open, setOpen] = useState(false);
  const here = currentHref(groups, path);

  // A page change closes the phone menu.
  useEffect(() => setOpen(false), [path]);
  useEffect(() => {
    if (!open) return;
    const close = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    document.addEventListener("keydown", close);
    return () => document.removeEventListener("keydown", close);
  }, [open]);

  return (
    <div className="shell-nav">
      <div className="shell-bar">
        <Link href="/" className="shell-brand">
          <Image src="/brand/octra-mark.png" alt="OCTRA" width={71} height={17} priority />
          <span>Access</span>
        </Link>
        <Link href="/inbox" className="shell-bar-link">Inbox{unread ? <span className="shell-count">{unread} new</span> : null}</Link>
        <button type="button" className="shell-menu" aria-expanded={open} aria-controls="site-nav" onClick={() => setOpen((o) => !o)}>
          {open ? "Close" : "Menu"}
        </button>
      </div>
      <nav id="site-nav" aria-label="Main" className="shell-panel" data-open={open}>
        {groups.map((g) => (
          <div key={g.label} className="shell-group">
            <h2 className="shell-group-label">{g.label}</h2>
            <ul>
              {g.items.map((i) => (
                <li key={i.href}>
                  <Link href={i.href} className="shell-link" aria-current={i.href === here ? "page" : undefined}>
                    <span>{i.label}</span>
                    {i.badge ? <span className="shell-count">{i.badge} new</span> : null}
                  </Link>
                </li>
              ))}
            </ul>
          </div>
        ))}
        <div className="shell-who">
          <p className="shell-who-name">{who}</p>
          {roles.length ? <p className="shell-who-roles">{roles.join(" · ")}</p> : null}
          <SignOutButton />
        </div>
      </nav>
    </div>
  );
}
