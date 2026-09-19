// POST /delete-account
//   Signed in, body {} or { confirm: true }:
//     deletes the auth user; every table references auth.users with
//     on delete cascade (profiles, entitlements, ai_*), and feedback keeps
//     the report with user_id nulled. → 200 { ok: true, deleted: true }
//   Not signed in, body { email, note? }:
//     the route Google requires outside the app (supabase/web/delete-
//     account.html). Records a deletion request for the developer to
//     verify and act on. → 200 { ok: true, requested: true }
//
// A store subscription is not cancelled by either: the app and the web
// page both say so, and point at the store's subscription settings.

import { error, json, preflight, readJson } from "../_shared/http.ts";
import { callerOf, serviceClient } from "../_shared/supabase.ts";

Deno.serve(async (req) => {
  const early = preflight(req);
  if (early) return early;

  const body = (await readJson<Record<string, unknown>>(req, 10_000)) ?? {};
  const db = serviceClient();
  const user = await callerOf(req);

  if (user) {
    const { error: deleteError } = await db.auth.admin.deleteUser(user.id);
    if (deleteError) {
      console.error("deleteUser", deleteError);
      return error(500, "delete_failed");
    }
    return json({ ok: true, deleted: true });
  }

  const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 200) {
    return error(400, "invalid_email");
  }
  const note = typeof body.note === "string" ? body.note.slice(0, 2000) : null;
  const { error: insertError } = await db.from("deletion_requests").insert({ email, note });
  if (insertError) {
    console.error("deletion_requests insert", insertError);
    return error(500, "storage_failed");
  }
  return json({ ok: true, requested: true });
});
