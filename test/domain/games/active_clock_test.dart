import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/domain/games/active_clock.dart';

void main() {
  test('the clock pauses after idleAfter and a touch resumes it', () {
    fakeAsync((async) {
      final clock = ActiveClock(idleAfter: const Duration(minutes: 3));
      clock.start();
      async.elapse(const Duration(minutes: 2));
      expect(clock.isRunning, isTrue);
      clock.touch();
      async.elapse(const Duration(minutes: 2));
      expect(clock.isRunning, isTrue, reason: 'the touch re-armed the idle timer');
      async.elapse(const Duration(minutes: 2));
      expect(clock.isRunning, isFalse, reason: 'idle for three minutes');
      clock.touch();
      expect(clock.isRunning, isTrue);
      clock.stop();
      clock.touch();
      expect(clock.isRunning, isFalse, reason: 'a stopped clock ignores touches');
      clock.dispose();
    });
  });
}
