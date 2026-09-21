import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:word_wizard/app/providers.dart';
import 'package:word_wizard/domain/models/study_dashboard.dart';
import 'package:word_wizard/domain/premium/premium.dart';
import 'package:word_wizard/features/games/games_screen.dart';
import 'package:word_wizard/services/purchases_service.dart';

Future<void> pump(WidgetTester tester, PurchasesService purchases) async {
  tester.view.physicalSize = const Size(800, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  final router = GoRouter(
    initialLocation: '/games',
    routes: [
      GoRoute(path: '/games', builder: (_, _) => const GamesScreen()),
      GoRoute(
        path: '/premium',
        builder: (_, state) => Scaffold(
          body: Text('paywall from ${state.uri.queryParameters['source']} '
              'to ${state.uri.queryParameters['next']}'),
        ),
      ),
      GoRoute(path: '/games/hunt', builder: (_, _) => const Scaffold(body: Text('hunt'))),
      GoRoute(
        path: '/games/crossword/:d',
        builder: (_, state) => Scaffold(body: Text('crossword ${state.pathParameters['d']}')),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        purchasesServiceProvider.overrideWithValue(purchases),
        studyStatsProvider.overrideWith(
          (ref) => Stream.value(
            const StudyDashboardStats(dueToday: 0, mastered: 0, learning: 12, reviewing: 0, total: 12),
          ),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('free: locked cards, a labelled sample, and the friend-group card', (tester) async {
    await pump(tester, FakePurchasesService());

    expect(find.text('You have 12 words ready to play. Premium turns them into daily games; the sample below is free.'),
        findsOneWidget);
    expect(find.text('Sample · free'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsWidgets);
    expect(find.text('Build a shared word world'), findsOneWidget);
    expect(find.text('Unlock friend groups'), findsOneWidget);

    // A locked game opens the paywall with itself as the destination.
    await tester.tap(find.text('Daily board'));
    await tester.pumpAndSettle();
    expect(find.text('paywall from games_hunt to /games/hunt'), findsOneWidget);
  });

  testWidgets('free: the sample plays without a paywall', (tester) async {
    await pump(tester, FakePurchasesService());
    await tester.tap(find.text(sampleCrossword.label));
    await tester.pumpAndSettle();
    expect(find.text('crossword ${sampleCrossword.storageKey}'), findsOneWidget);
  });

  testWidgets('premium: nothing locked, no selling', (tester) async {
    await pump(
      tester,
      FakePurchasesService(
        status: const PremiumStatus(access: PremiumAccess.subscription, product: PremiumProduct.monthly),
      ),
    );
    expect(find.byIcon(Icons.lock_outline), findsNothing);
    expect(find.text('Sample · free'), findsNothing);
    expect(find.text('See Premium'), findsNothing);
    expect(find.text('Build a shared word world'), findsNothing);
    await tester.tap(find.text('Daily board'));
    await tester.pumpAndSettle();
    expect(find.text('hunt'), findsOneWidget);
  });

  test('which game routes a free account may open', () {
    expect(gameRouteIsFree('/games/crossword/${sampleCrossword.storageKey}'), isTrue);
    expect(gameRouteIsFree('/games/crossword/${sampleCrossword.storageKey}?puzzle=3'), isTrue);
    expect(gameRouteIsFree('/games/hunt'), isFalse);
    expect(gameRouteIsFree('/games/hunt/history'), isTrue);
    expect(gameRouteIsFree('/games/crossword/standard'), isFalse);
  });
}
