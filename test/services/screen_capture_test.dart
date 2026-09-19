import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:word_wizard/services/screen_capture.dart';

void main() {
  test('locations get the names the user knows the screens by', () {
    expect(describeLocation('/search'), 'Search');
    expect(describeLocation('/games/hunt'), 'Word Hunt');
    expect(describeLocation('/games/hunt?puzzle=3'), 'Word Hunt');
    expect(describeLocation('/games/hunt/history'), 'Word Hunt history');
    expect(describeLocation('/games/crossword/easy'), 'Crossword');
    expect(describeLocation('/games/crossword/easy/history'), 'Crossword history');
    expect(describeLocation('/entry/serene'), 'Entry: serene');
    expect(describeLocation('/entry/re-enter'), 'Entry: re-enter');
    expect(describeLocation('/study/session?listId=2'), 'Study session');
    expect(describeLocation('/lists/4'), 'List');
    expect(describeLocation('/settings'), 'Settings');
    expect(describeLocation('/somewhere/new'), '/somewhere/new');
    expect(describeLocation(''), 'Start');
  });

  testWidgets('every navigation snapshots the screen being left', (tester) async {
    final capture = ScreenCapture();
    final router = GoRouter(
      initialLocation: '/search',
      routes: [
        GoRoute(
          path: '/search',
          builder: (_, _) => const Scaffold(body: Text('search')),
        ),
        GoRoute(
          path: '/games/hunt',
          builder: (_, _) => const Scaffold(body: Text('hunt')),
        ),
        GoRoute(
          path: '/settings',
          builder: (_, _) => const Scaffold(body: Text('settings')),
        ),
      ],
    );
    capture.watch(router);
    addTearDown(() {
      capture.unwatch();
      capture.clear();
    });
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        builder: (_, child) => RepaintBoundary(key: capture.boundaryKey, child: child!),
      ),
    );
    expect(capture.recent, isEmpty);

    router.go('/games/hunt');
    await tester.pumpAndSettle();
    expect(capture.recent.map((s) => s.label), ['Search']);
    expect(capture.recent.single.image.width, greaterThan(0));

    // Wait out the debounce that folds a redirect chain into one capture.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 350)));
    router.push('/settings');
    await tester.pumpAndSettle();
    expect(capture.recent.map((s) => s.label), ['Word Hunt', 'Search']);

    // Popping a pushed page labels the capture by the page, not by what
    // was underneath it.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 350)));
    router.pop();
    await tester.pumpAndSettle();
    expect(capture.recent.first.label, 'Settings');

    // A pop counts too, and the list is capped, newest first.
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 350)));
      router.go(i.isEven ? '/search' : '/settings');
      await tester.pumpAndSettle();
    }
    expect(capture.recent, hasLength(ScreenCapture.keep));
    expect(capture.recent.first.label, 'Search');

    // A PNG comes out of a capture on demand.
    final png = await tester.runAsync(() => capture.recent.first.png());
    expect(png, isNotNull);
    expect(png!.sublist(1, 4), 'PNG'.codeUnits);
  });
}
