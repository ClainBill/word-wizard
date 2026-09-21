// POST /founder-reserve  (signed-in user, empty body)
//   → 200 { reservation_id, expires_in_minutes }
//   → 409 { error: "sold_out" }   no place left (or campaign closed)
//   → 401                         not signed in
//
// Called right before the app opens the store sheet for the Founding
// Member product (spec §6.3). Holds one place for ten minutes; the
// webhook converts it when RevenueCat reports the purchase, and an
// unconverted hold simply lapses.

import { error, json, preflight } from "../_shared/http.ts";
import { callerOf, serviceClient } from "../_shared/supabase.ts";

const holdMinutes = 10;

Deno.serve(async (req) => {
  const early = preflight(req);
  if (early) return early;
  const user = await callerOf(req);
  if (!user) return error(401, "unauthenticated");
  const { data, error: rpcError } = await serviceClient().rpc("founder_reserve", {
    p_user: user.id,
    p_minutes: holdMinutes,
  });
  if (rpcError) {
    console.error("founder_reserve", rpcError);
    return error(500, "reserve_failed");
  }
  if (!data) return error(409, "sold_out");
  return json({ reservation_id: data, expires_in_minutes: holdMinutes });
});
