import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:word_wizard/app/providers.dart';
import 'package:word_wizard/features/settings/feedback_screen.dart';
import 'package:word_wizard/services/feedback_service.dart';
import 'package:word_wizard/services/screen_capture.dart';

/// The form end to end with no relay configured: a report with a captured
/// screen attached lands in the outbox, and the user is told it's saved.
void main() {
  late Directory temp;
  late FeedbackService service;
  late ScreenCapture capture;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('feedback_form_');
    service = FeedbackService(sender: null, outboxDirectory: () async => temp);
    capture = ScreenCapture();
  });

  tearDown(() async {
    capture.clear();
    await temp.delete(recursive: true);
  });

  Future<void> pumpForm(WidgetTester tester) async {
    // Tall enough that the whole form is on screen: no scrolling, so no
    // lazily-unbuilt fields and no overscroll animation to outlive the pop.
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          feedbackServiceProvider.overrideWithValue(service),
          screenCaptureProvider.overrideWith((ref) => capture),
        ],
        child: MaterialApp(
          // The form sits inside the capture boundary like the real app, so
          // the test can take a capture the form then offers.
          builder: (_, child) => RepaintBoundary(key: capture.boundaryKey, child: child!),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(
                    context,
                  ).push(MaterialPageRoute<void>(builder: (_) => const FeedbackScreen())),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('a report with a screenshot is queued and the user told', (tester) async {
    await tester.runAsync(() async {
      await pumpForm(tester);
      // The screen before the form, as the app would have captured it.
      await capture.capture(label: 'Word Hunt');
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Report a bug'), findsOneWidget);
      expect(find.text('Word Hunt'), findsOneWidget, reason: 'the captured screen is offered');
      final send = find.ancestor(of: find.text('Send'), matching: find.bySubtype<FilledButton>());
      expect(tester.widget<FilledButton>(send).onPressed, isNull, reason: 'nothing to send yet');

      await tester.tap(find.text('Feature'));
      await tester.pump();
      expect(find.text('Suggest a feature'), findsOneWidget);
      await tester.tap(find.text('Bug'));
      await tester.pump();

      await tester.enterText(
        find.widgetWithText(TextField, 'What happened?'),
        'The arrow pointed off the board',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Link (optional)'),
        'https://example.com/v',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Your email (optional)'),
        'me@example.com',
      );
      await tester.tap(find.text('Word Hunt'));
      await tester.pump();
      expect(find.byIcon(Icons.check_circle), findsOneWidget);

      await tester.tap(send);
      await tester.pump();
      // Encoding the screenshot and writing the outbox are real I/O.
      for (var i = 0; i < 100 && find.text('open').evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
      expect(find.text('open'), findsOneWidget, reason: 'the form closed');
      // Let the pop finish: mid-transition the snackbar shows in both
      // scaffolds.
      await tester.pumpAndSettle();
      expect(find.textContaining('Saved.'), findsOneWidget);

      expect(await service.pendingCount(), 1);
      final dir = (await temp.list().toList()).whereType<Directory>().single;
      final json =
          jsonDecode(await File(p.join(dir.path, 'report.json')).readAsString())
              as Map<String, dynamic>;
      expect(json['kind'], 'bug');
      expect(json['message'], 'The arrow pointed off the board');
      expect(json['link'], 'https://example.com/v');
      expect(json['email'], 'me@example.com');
      expect((json['app'] as Map)['screen'], matches(RegExp(r'^\d+×\d+ @[\d.]+x$')));
      final attachment = (json['attachments'] as List).single as Map;
      expect(attachment['name'], 'screen-1-word-hunt.png');
      final png = await File(p.join(dir.path, 'screen-1-word-hunt.png')).readAsBytes();
      expect(png.sublist(1, 4), 'PNG'.codeUnits);
    });
  });
}
