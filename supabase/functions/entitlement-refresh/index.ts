// POST /entitlement-refresh  (signed-in user, empty body)
//   → 200 { premium, expires_at, will_renew, billing_issue, product_id }
//
// The app calls this after a purchase or restore, and on launch when its
// cached status is old, so a delayed or missed webhook never leaves a
// paying user locked out. Rate: RevenueCat allows plenty, but the app
// should not call this more than once a minute per user.

import { error, json, preflight } from "../_shared/http.ts";
import { callerOf, serviceClient } from "../_shared/supabase.ts";
import { reconcileUser } from "../_shared/revenuecat.ts";

Deno.serve(async (req) => {
  const early = preflight(req);
  if (early) return early;
  const user = await callerOf(req);
  if (!user) return error(401, "unauthenticated");
  const row = await reconcileUser(serviceClient(), user.id);
  if (!row) return error(503, "revenuecat_unavailable");
  return json(row);
});
