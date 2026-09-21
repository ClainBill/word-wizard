// POST /founder-status  (anon key or a user; empty body)
//   → 200 { active, cap, sold, reserved, remaining, version,
//           last_updated_at, config: { founding_visible, paywall_variant, prompts } }
//
// The one place the app gets a Founding Member count from (spec §1.4:
// "only X left" only from an authoritative backend). Public, cheap, and
// cacheable for a few minutes on the client — never persisted as live.

import { error, json, preflight } from "../_shared/http.ts";
import { serviceClient } from "../_shared/supabase.ts";

Deno.serve(async (req) => {
  const early = preflight(req);
  if (early) return early;
  const db = serviceClient();
  const [{ data: status, error: statusError }, { data: config }] = await Promise.all([
    db.rpc("founder_status"),
    db.from("app_config").select("value").eq("key", "premium_offers").maybeSingle(),
  ]);
  if (statusError || !status) {
    console.error("founder_status", statusError);
    return error(503, "status_unavailable");
  }
  const offers = (config?.value ?? {}) as Record<string, unknown>;
  // The campaign can also be hidden from the dashboard without touching
  // inventory: founding_visible false reads as sold out to the app.
  const visible = offers.founding_visible !== false;
  return json({
    ...status,
    active: visible && status.active,
    config: offers,
  });
});
