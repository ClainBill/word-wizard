import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:word_wizard/app/providers.dart';
import 'package:word_wizard/domain/models/study_dashboard.dart';
import 'package:word_wizard/domain/premium/premium.dart';
import 'package:word_wizard/features/premium/paywall_screen.dart';
import 'package:word_wizard/services/founder_service.dart';
import 'package:word_wizard/services/premium_prompts.dart';
import 'package:word_wizard/services/purchases_service.dart';

const _stats = StudyDashboardStats(dueToday: 3, mastered: 4, learning: 20, reviewing: 13, total: 37);

/// The paywall inside a router (it pops itself and pushes the legal
/// pages), over a home page that records where a purchase lands.
Future<GoRouter> pump(
  WidgetTester tester, {
  required PurchasesService purchases,
  FounderService? founders,
  String? next,
}) async {
  tester.view.physicalSize = const Size(800, 2200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  final query = {'source': 'test', 'next': ?next};
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, _) => const Scaffold(body: Text('home'))),
      GoRoute(path: '/games', builder: (_, _) => const Scaffold(body: Text('games tab'))),
      GoRoute(path: '/games/hunt', builder: (_, _) => const Scaffold(body: Text('hunt'))),
      GoRoute(path: '/legal/terms', builder: (_, _) => const Scaffold(body: Text('terms page'))),
      GoRoute(path: '/legal/privacy', builder: (_, _) => const Scaffold(body: Text('privacy page'))),
      GoRoute(
        path: '/premium',
        builder: (_, state) => PaywallScreen(
          source: state.uri.queryParameters['source']!,
          next: state.uri.queryParameters['next'],
        ),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        purchasesServiceProvider.overrideWithValue(purchases),
        founderServiceProvider.overrideWithValue(founders ?? FakeFounderService(remaining: 137)),
        studyStatsProvider.overrideWith((ref) => Stream.value(_stats)),
        premiumPromptsProvider.overrideWithValue(PremiumPrompts.inMemory()),
      ],
      // The preview loops forever; reduced motion holds it still so
      // pumpAndSettle can settle.
      child: MaterialApp.router(
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  router.push(Uri(path: '/premium', queryParameters: query).toString());
  await tester.pumpAndSettle();
  return router;
}

Finder button(String label) => find.widgetWithText(FilledButton, label);

void main() {
  testWidgets('leads with the outcome, the person\'s words, and live prices', (tester) async {
    await pump(tester, purchases: FakePurchasesService());

    expect(find.text('Make your words playable'), findsOneWidget);
    expect(find.text('You have 37 words ready to play.'), findsOneWidget);
    for (final benefit in premiumBenefits) {
      expect(find.text(benefit), findsOneWidget);
    }
    // The three options, with the store's strings.
    expect(find.text('Founding Member'), findsOneWidget);
    expect(find.text('Annual'), findsOneWidget);
    expect(find.text('Monthly'), findsOneWidget);
    expect(find.text(r'$34.99'), findsOneWidget);
    expect(find.text(r'$29.99'), findsOneWidget);
    expect(find.text(r'$4.99'), findsOneWidget);
    expect(find.textContaining('Save about 50%'), findsOneWidget);
    expect(find.textContaining(r'Equivalent to $2.50 a month'), findsOneWidget);
    // Founder featured and selected while places remain, with the count.
    expect(find.text('Become a Founding Member'), findsWidgets);
    expect(find.textContaining('137 of 500'), findsWidgets);
    expect(find.text(r'One-time purchase of $34.99. No subscription.'), findsOneWidget);
    // Trust elements always present.
    expect(find.text('Restore Purchases'), findsOneWidget);
    expect(find.text('Terms'), findsOneWidget);
    expect(find.text('Privacy'), findsOneWidget);
    expect(find.byTooltip('Not now'), findsOneWidget);
  });

  testWidgets('selecting an option changes the button and its small print', (tester) async {
    await pump(tester, purchases: FakePurchasesService());

    await tester.tap(find.text('Annual'));
    await tester.pumpAndSettle();
    expect(button('Start Annual Premium'), findsOneWidget);
    expect(find.text(r'$29.99 per year. Renews yearly until cancelled.'), findsOneWidget);

    await tester.tap(find.text('Monthly'));
    await tester.pumpAndSettle();
    expect(button('Start Monthly Premium'), findsOneWidget);
    expect(find.text(r'$4.99 per month. Renews monthly until cancelled.'), findsOneWidget);
  });

  testWidgets('a founder purchase reserves a place, succeeds, and opens the destination',
      (tester) async {
    final purchases = FakePurchasesService();
    final founders = FakeFounderService(remaining: 137);
    await pump(tester, purchases: purchases, founders: founders, next: '/games/hunt');

    await tester.tap(button('Become a Founding Member'));
    await tester.pumpAndSettle();

    expect(founders.reservations, 1);
    expect(purchases.purchases, [PremiumProduct.founder]);
    expect(purchases.current.founder, isTrue);
    expect(find.text('Welcome, Founding Member'), findsOneWidget);
    expect(find.text('Premium is ready. Your games are being prepared.'), findsOneWidget);

    await tester.tap(button('Start playing'));
    await tester.pumpAndSettle();
    expect(find.text('hunt'), findsOneWidget);
  });

  testWidgets('cancelling in the store sheet returns quietly', (tester) async {
    final purchases = FakePurchasesService()..nextOutcome = (_) => const PurchaseCancelled();
    await pump(tester, purchases: purchases);

    await tester.tap(find.text('Monthly'));
    await tester.pumpAndSettle();
    await tester.tap(button('Start Monthly Premium'));
    await tester.pumpAndSettle();

    expect(button('Start Monthly Premium'), findsOneWidget);
    expect(find.textContaining('didn\'t go through'), findsNothing);
    expect(purchases.current.isPremium, isFalse);
  });

  testWidgets('a failure the person can act on is shown; one they can\'t is softened',
      (tester) async {
    final purchases = FakePurchasesService()
      ..nextOutcome = (_) => const PurchaseFailed('No connection. Check your network and try again.',
          code: 'networkError');
    await pump(tester, purchases: purchases);
    await tester.tap(find.text('Annual'));
    await tester.pumpAndSettle();
    await tester.tap(button('Start Annual Premium'));
    await tester.pumpAndSettle();
    expect(find.text('No connection. Check your network and try again.'), findsOneWidget);

    purchases.nextOutcome =
        (_) => const PurchaseFailed('internal 0x8badf00d', code: 'unknownError', actionable: false);
    await tester.tap(button('Start Annual Premium'));
    await tester.pumpAndSettle();
    expect(find.textContaining('didn\'t go through'), findsOneWidget);
    expect(find.textContaining('0x8badf00d'), findsNothing);
  });

  testWidgets('a pending purchase says so and offers a status refresh', (tester) async {
    final purchases = FakePurchasesService()..nextOutcome = (_) => const PurchasePending();
    await pump(tester, purchases: purchases);
    await tester.tap(find.text('Monthly'));
    await tester.pumpAndSettle();
    await tester.tap(button('Start Monthly Premium'));
    await tester.pumpAndSettle();
    expect(find.textContaining('still confirming'), findsOneWidget);
    expect(find.text('Refresh status'), findsOneWidget);
  });

  testWidgets('sold out: no founder card, a thank-you, Annual featured', (tester) async {
    await pump(
      tester,
      purchases: FakePurchasesService(),
      founders: FakeFounderService(remaining: 0),
    );
    expect(find.text('Founding offer has ended'), findsOneWidget);
    expect(find.text('Founding Member'), findsNothing);
    expect(button('Start Annual Premium'), findsOneWidget);
  });

  testWidgets('selling out under the buyer\'s finger is handled', (tester) async {
    final founders = FakeFounderService(remaining: 137);
    await pump(tester, purchases: FakePurchasesService(), founders: founders);
    founders.remaining = 0;
    await tester.tap(button('Become a Founding Member'));
    await tester.pumpAndSettle();
    expect(find.text('Founding offer has ended'), findsOneWidget);
    expect(button('Start Annual Premium'), findsOneWidget);
  });

  testWidgets('an unknown count is never shown as one, and blocks the sale', (tester) async {
    await pump(
      tester,
      purchases: FakePurchasesService(),
      founders: FakeFounderService(remaining: null),
    );
    expect(find.textContaining('of 500 places remain'), findsNothing);
    expect(find.textContaining('Limited to 500 completed purchases'), findsWidgets);
    // The option is there, but can't be bought until the count is known.
    final buy = tester.widget<FilledButton>(button('Become a Founding Member'));
    expect(buy.onPressed, isNull);
    expect(find.text('Check again'), findsOneWidget);
    // The subscriptions still can be.
    await tester.tap(find.text('Annual'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(button('Start Annual Premium')).onPressed, isNotNull);
  });

  testWidgets('store unavailable: an explanation and a retry, no guessed prices', (tester) async {
    final purchases = FakePurchasesService(offers: StoreOffers.empty);
    await pump(tester, purchases: purchases);
    expect(find.text('Purchasing is temporarily unavailable'), findsOneWidget);
    expect(find.text(r'$4.99'), findsNothing);
    expect(find.text('Try again'), findsOneWidget);
    // Fixing the store and retrying brings the options back.
    purchases.offersForSale = FakePurchasesService.sampleOffers;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text(r'$4.99'), findsOneWidget);
  });

  testWidgets('already entitled: nothing to sell, straight to the games', (tester) async {
    final purchases = FakePurchasesService(
      status: const PremiumStatus(access: PremiumAccess.subscription, product: PremiumProduct.annual),
    );
    await pump(tester, purchases: purchases);
    expect(find.text('You already have Premium'), findsOneWidget);
    expect(find.text(r'$4.99'), findsNothing);
    await tester.tap(button('Start playing'));
    await tester.pumpAndSettle();
    expect(find.text('games tab'), findsOneWidget);
  });

  testWidgets('restore finds a purchase and unlocks', (tester) async {
    final purchases = FakePurchasesService();
    await pump(tester, purchases: purchases);
    purchases.status = const PremiumStatus(access: PremiumAccess.lifetime, product: PremiumProduct.founder, founder: true);
    await tester.tap(find.text('Restore Purchases'));
    await tester.pumpAndSettle();
    expect(find.text('Premium is ready. Your games are being prepared.'), findsOneWidget);
  });

  testWidgets('the terms and privacy links open the bundled pages', (tester) async {
    await pump(tester, purchases: FakePurchasesService());
    await tester.tap(find.text('Terms'));
    await tester.pumpAndSettle();
    expect(find.text('terms page'), findsOneWidget);
  });

  testWidgets('a founder place needs an account: the button asks for the sign-in first',
      (tester) async {
    await pump(
      tester,
      purchases: FakePurchasesService(),
      founders: FakeFounderService(remaining: 137, needsAccount: true),
    );
    expect(button('Sign in to continue'), findsOneWidget);
    expect(find.textContaining('tied to your account'), findsOneWidget);
    // Subscriptions don't need one.
    await tester.tap(find.text('Monthly'));
    await tester.pumpAndSettle();
    expect(button('Start Monthly Premium'), findsOneWidget);
  });
}
