// POST /revenuecat-webhook — called by RevenueCat, not by the app.
// `verify_jwt = false` in config.toml; the shared secret in the
// Authorization header is the authentication (set the same value as
// REVENUECAT_WEBHOOK_SECRET in the RevenueCat dashboard's webhook config).
//
// Idempotent: each event id is recorded once. Retry-safe: the handler
// reconciles from a fresh subscriber fetch, so applying an event twice, or
// out of order, converges on the same row.

import { env, error, json } from "../_shared/http.ts";
import { serviceClient } from "../_shared/supabase.ts";
import { isUuid, reconcileUser } from "../_shared/revenuecat.ts";

type Event = {
  id: string;
  type: string;
  app_user_id: string;
  original_app_user_id?: string;
  aliases?: string[];
};

Deno.serve(async (req) => {
  if (req.method !== "POST") return error(405, "method_not_allowed");
  const auth = req.headers.get("Authorization") ?? "";
  if (auth !== `Bearer ${env("REVENUECAT_WEBHOOK_SECRET")}`) return error(401, "unauthorized");

  let body: { event?: Event };
  try {
    body = await req.json();
  } catch {
    return error(400, "invalid_json");
  }
  const event = body.event;
  if (!event?.id || !event.type) return error(400, "invalid_event");

  const db = serviceClient();
  const { error: insertError } = await db.from("revenuecat_events").insert({
    id: event.id,
    type: event.type,
    app_user_id: event.app_user_id,
    payload: body,
  });
  if (insertError) {
    // 23505 = already recorded: a redelivery. Acknowledge it.
    if (insertError.code === "23505") return json({ ok: true, duplicate: true });
    console.error("revenuecat_events insert", insertError);
    return error(500, "storage_failed");
  }

  // Every id RevenueCat associates with this subscriber that is one of
  // our user ids gets refreshed: after a restore or a transfer the
  // premium can move between accounts, and both sides must be rewritten.
  const ids = new Set<string>([event.app_user_id, event.original_app_user_id ?? "", ...(event.aliases ?? [])]);
  const refreshed: string[] = [];
  for (const id of ids) {
    if (!isUuid(id)) continue; // anonymous RevenueCat ids ($RCAnonymousID:…) aren't ours
    if (await reconcileUser(db, id)) refreshed.push(id);
  }
  return json({ ok: true, refreshed });
});
