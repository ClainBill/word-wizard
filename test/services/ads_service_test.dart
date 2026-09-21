import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/services/ads_service.dart';

void main() {
  final t0 = DateTime(2026, 9, 20, 10);

  test('the interstitial gate: never premium, never without an ad, never back to back', () {
    final gate = InterstitialGate(minInterval: const Duration(minutes: 3));
    expect(gate.allows(isPremium: true, adReady: true, now: t0), isFalse);
    expect(gate.allows(isPremium: false, adReady: false, now: t0), isFalse);
    expect(gate.allows(isPremium: false, adReady: true, now: t0), isTrue);
    gate.markShown(t0);
    expect(gate.allows(isPremium: false, adReady: true, now: t0.add(const Duration(minutes: 2))), isFalse);
    expect(gate.allows(isPremium: false, adReady: true, now: t0.add(const Duration(minutes: 4))), isTrue);
  });

  test('the fake follows the premium flag live', () async {
    var premium = false;
    final ads = FakeAdsService(isPremium: () => premium)..bannerBuilder = PlaceholderBanner.new;
    expect(await ads.loadBanner(width: 320), isNotNull);
    expect(await ads.showInterstitial(placement: 'review_end'), isTrue);
    premium = true;
    expect(await ads.loadBanner(width: 320), isNull);
    expect(await ads.showInterstitial(placement: 'review_end'), isFalse);
    expect(ads.interstitials, ['review_end']);
  });
}
