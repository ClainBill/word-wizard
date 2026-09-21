import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/app/providers.dart';
import 'package:word_wizard/domain/premium/premium.dart';
import 'package:word_wizard/services/ads_service.dart';
import 'package:word_wizard/services/purchases_service.dart';
import 'package:word_wizard/widgets/ad_banner.dart';

void main() {
  testWidgets('free: the banner; premium: nothing, and it goes the moment premium arrives',
      (tester) async {
    final purchases = FakePurchasesService();
    final ads = FakeAdsService(isPremium: () => purchases.current.isPremium)
      ..bannerBuilder = () => PlaceholderBanner('AD HERE');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          purchasesServiceProvider.overrideWithValue(purchases),
          adsServiceProvider.overrideWithValue(ads),
        ],
        child: const MaterialApp(home: Scaffold(bottomNavigationBar: AdBanner())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('AD HERE'), findsOneWidget);
    expect(ads.bannersLoaded, 1);
    // In the Scaffold's bottom slot it takes its own height, not the screen's.
    expect(tester.getSize(find.byType(AdBanner)).height, 50);

    purchases.status = const PremiumStatus(access: PremiumAccess.lifetime, product: PremiumProduct.founder);
    await tester.pumpAndSettle();
    expect(find.text('AD HERE'), findsNothing);
  });

  testWidgets('no ad service: no space reserved', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [purchasesServiceProvider.overrideWithValue(FakePurchasesService())],
        child: const MaterialApp(home: Scaffold(body: Column(children: [AdBanner()]))),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(AdBanner)).height, 0);
  });
}
