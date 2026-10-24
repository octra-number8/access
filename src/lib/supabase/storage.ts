import "server-only";
import { createClient } from "@supabase/supabase-js";
import { publicEnv, serverEnv } from "../env";

// The service-role key is used for Storage only: to store a file the database has
// already registered, and to sign a short-lived link after api.document_access has
// authorised and audited the release. It never makes a decision.
export function documentsBucket() {
  return createClient(publicEnv.supabaseUrl, serverEnv().serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  }).storage.from("documents");
}
