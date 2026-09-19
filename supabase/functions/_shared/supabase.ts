// Two clients: one acting as the caller (their JWT, RLS applies) to find out
// who they are, and one with the service role for the writes no user may
// make — entitlements, usage ledgers, feedback rows.

import { createClient, type SupabaseClient, type User } from "jsr:@supabase/supabase-js@2";
import { env } from "./http.ts";

export function serviceClient(): SupabaseClient {
  return createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/**
 * The signed-in user behind a request, or null. The gateway has already
 * checked the JWT's signature when `verify_jwt` is on; this resolves it to a
 * user — and rejects the bare anon key, which is a valid JWT but nobody.
 */
export async function callerOf(req: Request): Promise<User | null> {
  const header = req.headers.get("Authorization") ?? "";
  const token = header.replace(/^Bearer\s+/i, "").trim();
  if (!token) return null;
  const client = createClient(env("SUPABASE_URL"), env("SUPABASE_ANON_KEY"), {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await client.auth.getUser(token);
  if (error || !data.user) return null;
  return data.user;
}
