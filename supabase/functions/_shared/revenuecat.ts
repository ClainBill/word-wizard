// Premium status comes from RevenueCat, and only from RevenueCat: the
// webhook tells us *something changed* for a user, and this fetches the
// subscriber and rewrites their entitlements row from it. Deriving the
// state from a fresh fetch rather than from the event's fields is what
// makes a missed, late or out-of-order webhook harmless — any later event,
// or the app asking for a refresh, produces the same correct row.

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { env } from "./http.ts";

/** The entitlement id configured in RevenueCat that means "premium". */
export const premiumEntitlementId = "premium";

export type Subscriber = {
  entitlements?: Record<string, {
    expires_date: string | null;
    product_identifier: string;
    purchase_date: string;
  }>;
  subscriptions?: Record<string, {
    store: string;
    expires_date: string | null;
    unsubscribe_detected_at: string | null;
    billing_issues_detected_at: string | null;
    refunded_at?: string | null;
  }>;
};

export type EntitlementRow = {
  premium: boolean;
  product_id: string | null;
  store: string | null;
  expires_at: string | null;
  will_renew: boolean | null;
  billing_issue: boolean;
};

/** Pure: a subscriber object → the row we store. Tested in _shared/revenuecat_test.ts. */
export function deriveEntitlement(subscriber: Subscriber, now = new Date()): EntitlementRow {
  const entitlement = subscriber.entitlements?.[premiumEntitlementId];
  if (!entitlement) {
    return { premium: false, product_id: null, store: null, expires_at: null, will_renew: null, billing_issue: false };
  }
  const expires = entitlement.expires_date ? new Date(entitlement.expires_date) : null;
  const active = expires === null || expires.getTime() > now.getTime();
  const subscription = subscriber.subscriptions?.[entitlement.product_identifier];
  const refunded = !!subscription?.refunded_at;
  return {
    premium: active && !refunded,
    product_id: entitlement.product_identifier,
    store: subscription?.store ?? null,
    expires_at: expires ? expires.toISOString() : null,
    will_renew: subscription ? subscription.unsubscribe_detected_at === null : null,
    billing_issue: !!subscription?.billing_issues_detected_at,
  };
}

/** GET /v1/subscribers/{id} with the secret API key. Null on any failure. */
export async function fetchSubscriber(appUserId: string): Promise<Subscriber | null> {
  const response = await fetch(
    `https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(appUserId)}`,
    { headers: { Authorization: `Bearer ${env("REVENUECAT_API_KEY")}` } },
  );
  if (!response.ok) {
    console.error(`revenuecat subscriber fetch ${response.status}`);
    return null;
  }
  const body = await response.json();
  return (body?.subscriber ?? null) as Subscriber | null;
}

/**
 * Refreshes one user's entitlements row from RevenueCat. The app user id
 * *is* the Supabase user id (the SDK is configured with it at sign-in), so
 * no mapping table is needed. Returns the row written, or null.
 */
export async function reconcileUser(db: SupabaseClient, userId: string): Promise<EntitlementRow | null> {
  const subscriber = await fetchSubscriber(userId);
  if (!subscriber) return null;
  const row = deriveEntitlement(subscriber);
  const { error } = await db.from("entitlements").upsert({
    user_id: userId,
    ...row,
    rc_app_user_id: userId,
    raw: subscriber,
  });
  if (error) {
    console.error("entitlements upsert", error);
    return null;
  }
  return row;
}

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const isUuid = (s: string) => uuid.test(s);
