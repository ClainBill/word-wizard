// Premium status comes from RevenueCat, and only from RevenueCat: the
// webhook tells us *something changed* for a user, and this fetches the
// subscriber and rewrites their entitlements row from it. Deriving the
// state from a fresh fetch rather than from the event's fields is what
// makes a missed, late or out-of-order webhook harmless — any later event,
// or the app asking for a refresh, produces the same correct row.

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { env } from "./http.ts";

/**
 * The entitlement id configured in RevenueCat that every product unlocks
 * (spec §6.1). The app's `domain/premium/premium.dart` names the same one.
 */
export const premiumEntitlementId = "premium_active";

/** The one-time Founding Member product, and the cohort it marks. */
export const founderProductId = "premium_founder_lifetime_v1";
export const founderCohort = "founder_cohort_2026";

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
  non_subscriptions?: Record<string, Array<{
    id: string;
    store: string;
    purchase_date: string;
    store_transaction_id?: string;
  }>>;
};

/** The entitlement states of spec §2.2, as stored. */
export type Access = "free" | "subscription" | "lifetime" | "grace_period" | "billing_retry" | "expired";

export type EntitlementRow = {
  premium: boolean;
  access: Access;
  founder: boolean;
  founder_cohort: string | null;
  product_id: string | null;
  store: string | null;
  expires_at: string | null;
  will_renew: boolean | null;
  billing_issue: boolean;
};

/** A product id with or without Play's `:base-plan` suffix. */
const baseProduct = (id: string) => id.split(":")[0];

/** Pure: a subscriber object → the row we store. Tested in _shared/revenuecat_test.ts. */
export function deriveEntitlement(subscriber: Subscriber, now = new Date()): EntitlementRow {
  const entitlement = subscriber.entitlements?.[premiumEntitlementId];
  const everBought = Object.keys(subscriber.subscriptions ?? {}).length > 0 ||
    Object.keys(subscriber.non_subscriptions ?? {}).length > 0;
  if (!entitlement) {
    return {
      premium: false,
      access: everBought ? "expired" : "free",
      founder: false,
      founder_cohort: null,
      product_id: null,
      store: null,
      expires_at: null,
      will_renew: null,
      billing_issue: false,
    };
  }
  const expires = entitlement.expires_date ? new Date(entitlement.expires_date) : null;
  const active = expires === null || expires.getTime() > now.getTime();
  const subscription = subscriber.subscriptions?.[entitlement.product_identifier];
  const refunded = !!subscription?.refunded_at;
  const billingIssue = !!subscription?.billing_issues_detected_at;
  const premium = active && !refunded;
  const founder = premium && baseProduct(entitlement.product_identifier) === founderProductId;
  const lifetime = premium && (founder || expires === null);
  const access: Access = lifetime
    ? "lifetime"
    : premium
    ? (billingIssue ? "grace_period" : "subscription")
    : (billingIssue ? "billing_retry" : "expired");
  const nonSubscription = subscriber.non_subscriptions?.[entitlement.product_identifier]?.at(-1);
  return {
    premium,
    access,
    founder,
    founder_cohort: founder ? founderCohort : null,
    product_id: entitlement.product_identifier,
    store: subscription?.store ?? nonSubscription?.store ?? null,
    expires_at: expires ? expires.toISOString() : null,
    will_renew: subscription ? subscription.unsubscribe_detected_at === null : null,
    billing_issue: billingIssue,
  };
}

/**
 * Every Founding Member transaction RevenueCat lists for the subscriber,
 * with whether it still counts. A transaction that no longer backs the
 * entitlement (refunded, revoked) hands its place back — while the
 * campaign is active (spec §1.4).
 */
export function founderTransactions(subscriber: Subscriber, row: EntitlementRow): Array<{ id: string; refunded: boolean }> {
  const out: Array<{ id: string; refunded: boolean }> = [];
  for (const [product, purchases] of Object.entries(subscriber.non_subscriptions ?? {})) {
    if (baseProduct(product) !== founderProductId) continue;
    for (const purchase of purchases) {
      const id = purchase.store_transaction_id ?? purchase.id;
      if (id) out.push({ id, refunded: !row.founder });
    }
  }
  return out;
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
  // Founder inventory follows the store's word, one row per transaction.
  for (const sale of founderTransactions(subscriber, row)) {
    const { error: saleError } = await db.rpc("founder_record_sale", {
      p_user: userId,
      p_transaction: sale.id,
      p_refunded: sale.refunded,
    });
    if (saleError) console.error("founder_record_sale", saleError);
  }
  return row;
}

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const isUuid = (s: string) => uuid.test(s);
