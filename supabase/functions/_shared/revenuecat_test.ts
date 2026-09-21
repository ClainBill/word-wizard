import { assertEquals } from "jsr:@std/assert@1";
import { deriveEntitlement, founderTransactions } from "./revenuecat.ts";

const now = new Date("2026-09-16T12:00:00Z");

Deno.test("no premium entitlement → not premium; free unless something was once bought", () => {
  assertEquals(deriveEntitlement({}, now).premium, false);
  assertEquals(deriveEntitlement({}, now).access, "free");
  assertEquals(deriveEntitlement({ entitlements: {} }, now).premium, false);
  const lapsed = deriveEntitlement({ entitlements: {}, subscriptions: { premium_monthly_v1: { store: "app_store", expires_date: "2026-08-01T00:00:00Z", unsubscribe_detected_at: null, billing_issues_detected_at: null } } }, now);
  assertEquals(lapsed.access, "expired");
});

Deno.test("an active subscription is premium and renewing", () => {
  const row = deriveEntitlement({
    entitlements: { premium_active: { expires_date: "2026-10-16T12:00:00Z", product_identifier: "lexery_monthly", purchase_date: "2026-09-16T00:00:00Z" } },
    subscriptions: { lexery_monthly: { store: "app_store", expires_date: "2026-10-16T12:00:00Z", unsubscribe_detected_at: null, billing_issues_detected_at: null } },
  }, now);
  assertEquals(row.premium, true);
  assertEquals(row.access, "subscription");
  assertEquals(row.will_renew, true);
  assertEquals(row.store, "app_store");
  assertEquals(row.billing_issue, false);
  assertEquals(row.founder, false);
});

Deno.test("cancelled but not yet expired stays premium, not renewing", () => {
  const row = deriveEntitlement({
    entitlements: { premium_active: { expires_date: "2026-10-16T12:00:00Z", product_identifier: "lexery_monthly", purchase_date: "2026-09-16T00:00:00Z" } },
    subscriptions: { lexery_monthly: { store: "play_store", expires_date: "2026-10-16T12:00:00Z", unsubscribe_detected_at: "2026-09-20T00:00:00Z", billing_issues_detected_at: null } },
  }, now);
  assertEquals(row.premium, true);
  assertEquals(row.will_renew, false);
});

Deno.test("expired is not premium", () => {
  const row = deriveEntitlement({
    entitlements: { premium_active: { expires_date: "2026-09-01T12:00:00Z", product_identifier: "lexery_monthly", purchase_date: "2026-08-01T00:00:00Z" } },
  }, now);
  assertEquals(row.premium, false);
  assertEquals(row.expires_at, "2026-09-01T12:00:00.000Z");
});

Deno.test("lifetime (no expiry) is premium; a refund revokes it", () => {
  const base = {
    entitlements: { premium_active: { expires_date: null, product_identifier: "lexery_lifetime", purchase_date: "2026-09-16T00:00:00Z" } },
  };
  assertEquals(deriveEntitlement(base, now).premium, true);
  const refunded = {
    ...base,
    subscriptions: { lexery_lifetime: { store: "app_store", expires_date: null, unsubscribe_detected_at: null, billing_issues_detected_at: null, refunded_at: "2026-09-17T00:00:00Z" } },
  };
  assertEquals(deriveEntitlement(refunded, now).premium, false);
});

Deno.test("a billing problem is flagged while the entitlement still runs", () => {
  const row = deriveEntitlement({
    entitlements: { premium_active: { expires_date: "2026-09-20T12:00:00Z", product_identifier: "lexery_monthly", purchase_date: "2026-08-20T00:00:00Z" } },
    subscriptions: { lexery_monthly: { store: "play_store", expires_date: "2026-09-20T12:00:00Z", unsubscribe_detected_at: null, billing_issues_detected_at: "2026-09-15T00:00:00Z" } },
  }, now);
  assertEquals(row.premium, true);
  assertEquals(row.billing_issue, true);
  assertEquals(row.access, "grace_period");
});

Deno.test("the Founding Member product is lifetime, marks the cohort, and counts its transaction", () => {
  const subscriber = {
    entitlements: { premium_active: { expires_date: null, product_identifier: "premium_founder_lifetime_v1", purchase_date: "2026-09-19T00:00:00Z" } },
    non_subscriptions: { premium_founder_lifetime_v1: [{ id: "rc-1", store: "play_store", purchase_date: "2026-09-19T00:00:00Z", store_transaction_id: "GPA.1234" }] },
  };
  const row = deriveEntitlement(subscriber, now);
  assertEquals(row.access, "lifetime");
  assertEquals(row.founder, true);
  assertEquals(row.founder_cohort, "founder_cohort_2026");
  assertEquals(row.store, "play_store");
  assertEquals(founderTransactions(subscriber, row), [{ id: "GPA.1234", refunded: false }]);
});

Deno.test("a refunded founder purchase hands its place back", () => {
  const subscriber = {
    entitlements: {},
    non_subscriptions: { premium_founder_lifetime_v1: [{ id: "rc-1", store: "app_store", purchase_date: "2026-09-19T00:00:00Z" }] },
  };
  const row = deriveEntitlement(subscriber, now);
  assertEquals(row.access, "expired");
  assertEquals(row.founder, false);
  assertEquals(founderTransactions(subscriber, row), [{ id: "rc-1", refunded: true }]);
});

Deno.test("Play's base-plan suffix doesn't hide the product", () => {
  const row = deriveEntitlement({
    entitlements: { premium_active: { expires_date: null, product_identifier: "premium_founder_lifetime_v1:lifetime", purchase_date: "2026-09-19T00:00:00Z" } },
  }, now);
  assertEquals(row.founder, true);
});
