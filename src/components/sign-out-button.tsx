"use client";

import { signOut } from "@/app/actions";
import { clearGateDevice } from "@/lib/gate-device";

// Signing out also clears what this device kept for the gate (7d-2): see clearGateDevice.
export function SignOutButton() {
  return (
    <form action={async () => { await clearGateDevice(); await signOut(); }}>
      <button type="submit" className="secondary">Sign out</button>
    </form>
  );
}
