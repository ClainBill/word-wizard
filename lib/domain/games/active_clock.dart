import 'dart:async';

/// A stopwatch for time actually spent on a puzzle: it runs while the
/// screen is in front *and* the person is doing something. [touch] on
/// every input keeps it going; after [idleAfter] with no touch it pauses
/// itself, and the next touch restarts it. A board left open on a desk —
/// or an emulator that never locks — then logs minutes, not hours.
class ActiveClock {
  final Duration idleAfter;
  final Stopwatch _watch = Stopwatch();
  Timer? _idle;

  /// Whether [start] was called and [stop] wasn't — an idle pause keeps
  /// this true, so a touch can resume without the owner knowing.
  bool _wanted = false;

  ActiveClock({this.idleAfter = const Duration(minutes: 3)});

  int get elapsedMilliseconds => _watch.elapsedMilliseconds;
  bool get isRunning => _watch.isRunning;

  void start() {
    _wanted = true;
    _watch.start();
    _armIdle();
  }

  void stop() {
    _wanted = false;
    _idle?.cancel();
    _watch.stop();
  }

  /// Back to zero, keeping whether it's running.
  void reset() => _watch.reset();

  /// Input happened: keep counting, or resume if idleness had paused it.
  void touch() {
    if (!_wanted) return;
    if (!_watch.isRunning) _watch.start();
    _armIdle();
  }

  void _armIdle() {
    _idle?.cancel();
    _idle = Timer(idleAfter, _watch.stop);
  }

  void dispose() {
    _idle?.cancel();
    _watch.stop();
  }
}
