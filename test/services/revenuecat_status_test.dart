import 'package:flutter_test/flutter_test.dart';
import 'package:purchases_flutter/models/customer_info_wrapper.dart';
import 'package:purchases_flutter/models/entitlement_info_wrapper.dart';
import 'package:purchases_flutter/models/entitlement_infos_wrapper.dart';
import 'package:word_wizard/domain/premium/premium.dart';
import 'package:word_wizard/services/revenuecat_purchases_service.dart';

CustomerInfo info({
  EntitlementInfo? entitlement,
  List<String> everBought = const [],
}) =>
    CustomerInfo(
      EntitlementInfos(
        entitlement == null ? const {} : {premiumEntitlementId: entitlement},
        entitlement != null && entitlement.isActive ? {premiumEntitlementId: entitlement} : const {},
      ),
      const {},
      const [],
      everBought,
      const [],
      '2026-09-01T00:00:00Z',
      'user-1',
      const {},
      '2026-09-19T12:00:00Z',
    );

EntitlementInfo entitlement({
  required String product,
  bool active = true,
  bool willRenew = true,
  String? expires = '2027-09-19T12:00:00Z',
  String? billingIssue,
}) =>
    EntitlementInfo(
      premiumEntitlementId,
      active,
      willRenew,
      '2026-09-19T12:00:00Z',
      '2026-09-19T12:00:00Z',
      product,
      false,
      expirationDate: expires,
      billingIssueDetectedAt: billingIssue,
    );

void main() {
  final from = RevenueCatPurchasesService.statusFrom;

  test('nothing bought is free; something bought and gone is expired', () {
    expect(from(info()).access, PremiumAccess.free);
    expect(from(info(everBought: ['premium_monthly_v1'])).access, PremiumAccess.expired);
    expect(from(info(everBought: ['unrelated'])).access, PremiumAccess.free);
  });

  test('an active subscription', () {
    final s = from(info(entitlement: entitlement(product: 'premium_annual_v1')));
    expect(s.access, PremiumAccess.subscription);
    expect(s.product, PremiumProduct.annual);
    expect(s.willRenew, isTrue);
    expect(s.expiresAt, DateTime.parse('2027-09-19T12:00:00Z'));
    expect(s.isPremium, isTrue);
    expect(s.founder, isFalse);
  });

  test('the founder product is lifetime and marks the cohort', () {
    final s = from(info(entitlement: entitlement(product: 'premium_founder_lifetime_v1', expires: null)));
    expect(s.access, PremiumAccess.lifetime);
    expect(s.founder, isTrue);
    expect(s.label, 'Founding Member');
  });

  test('billing trouble: grace while still active, retry once not', () {
    final grace = from(info(
      entitlement: entitlement(product: 'premium_monthly_v1', billingIssue: '2026-09-18T00:00:00Z'),
    ));
    expect(grace.access, PremiumAccess.gracePeriod);
    expect(grace.isPremium, isTrue);
    final retry = from(info(
      entitlement: entitlement(
        product: 'premium_monthly_v1',
        active: false,
        billingIssue: '2026-09-18T00:00:00Z',
      ),
    ));
    expect(retry.access, PremiumAccess.billingRetry);
    expect(retry.isPremium, isFalse);
  });

  test('an inactive entitlement without billing trouble is simply expired', () {
    final s = from(info(entitlement: entitlement(product: 'premium_monthly_v1', active: false)));
    expect(s.access, PremiumAccess.expired);
    expect(s.product, PremiumProduct.monthly);
  });
}
