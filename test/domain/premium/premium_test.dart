import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/domain/premium/premium.dart';

StoreOffer offer(PremiumProduct p, String s, double price, [String currency = 'USD']) =>
    StoreOffer(product: p, priceString: s, price: price, currencyCode: currency);

void main() {
  group('StoreOffers', () {
    test('annual saving comes from the live prices only', () {
      final offers = StoreOffers([
        offer(PremiumProduct.monthly, r'$4.99', 4.99),
        offer(PremiumProduct.annual, r'$29.99', 29.99),
      ]);
      expect(offers.annualSavingPercent, 50);
      expect(offers.annualPerMonth, r'$2.50');
    });

    test('no saving claimed when a year is not cheaper, or currencies differ', () {
      expect(
        StoreOffers([
          offer(PremiumProduct.monthly, r'$1.00', 1),
          offer(PremiumProduct.annual, r'$12.00', 12),
        ]).annualSavingPercent,
        isNull,
      );
      expect(
        StoreOffers([
          offer(PremiumProduct.monthly, r'$4.99', 4.99, 'USD'),
          offer(PremiumProduct.annual, '£29.99', 29.99, 'GBP'),
        ]).annualSavingPercent,
        isNull,
      );
      expect(StoreOffers([offer(PremiumProduct.annual, r'$29.99', 29.99)]).annualSavingPercent, isNull);
    });

    test('per-month figure keeps the store\'s own formatting', () {
      expect(reformatPrice('£29.99', 29.99, 29.99 / 12), '£2.50');
      expect(reformatPrice('29,99 €', 29.99, 29.99 / 12), '2,50 €');
      expect(reformatPrice('¥3,000', 3000, 250), '¥250');
      expect(reformatPrice('CA\$1,234.56', 1234.56, 1234.56 / 12), 'CA\$102.88');
      expect(reformatPrice('free', 0, 1), isNull);
    });
  });

  test('store ids match with and without a Play base-plan suffix', () {
    expect(PremiumProduct.fromStoreId('premium_annual_v1'), PremiumProduct.annual);
    expect(PremiumProduct.fromStoreId('premium_annual_v1:yearly'), PremiumProduct.annual);
    expect(PremiumProduct.fromStoreId('premium_founder_lifetime_v1'), PremiumProduct.founder);
    expect(PremiumProduct.fromStoreId('something_else'), isNull);
    expect(PremiumProduct.fromStoreId(null), isNull);
  });

  test('founder status is only fresh for ten minutes', () {
    final t = DateTime(2026, 9, 19, 12);
    final status = FounderStatus(
      active: true,
      cap: 500,
      sold: 480,
      remaining: 20,
      version: 3,
      lastUpdatedAt: t,
      fetchedAt: t,
    );
    expect(status.isFresh(t.add(const Duration(minutes: 9))), isTrue);
    expect(status.isFresh(t.add(const Duration(minutes: 11))), isFalse);
    expect(status.soldOut, isFalse);
    expect(status.remainingBucket, '1-24');
    expect(
      FounderStatus.fromJson({'active': false, 'cap': 500, 'sold': 500, 'remaining': 0, 'version': 9}).soldOut,
      isTrue,
    );
  });

  test('premium status survives a JSON round trip', () {
    final status = PremiumStatus(
      access: PremiumAccess.gracePeriod,
      product: PremiumProduct.monthly,
      expiresAt: DateTime.utc(2026, 10, 1),
      willRenew: true,
      billingIssue: true,
      verifiedAt: DateTime.utc(2026, 9, 19),
    );
    final back = PremiumStatus.fromJson(status.toJson());
    expect(back.access, PremiumAccess.gracePeriod);
    expect(back.product, PremiumProduct.monthly);
    expect(back.expiresAt, DateTime.utc(2026, 10, 1));
    expect(back.billingIssue, isTrue);
    expect(back.isPremium, isTrue);
    expect(PremiumAccess.billingRetry.isPremium, isFalse);
    expect(PremiumAccess.expired.isPremium, isFalse);
  });

  test('labels', () {
    expect(PremiumStatus.free.label, 'Free');
    expect(
      const PremiumStatus(access: PremiumAccess.lifetime, product: PremiumProduct.founder, founder: true).label,
      'Founding Member',
    );
    expect(
      const PremiumStatus(access: PremiumAccess.subscription, product: PremiumProduct.annual).label,
      'Premium, annual',
    );
  });
}
