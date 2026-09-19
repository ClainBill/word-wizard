import 'dart:math' show min;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// A frame of the app as it looked just before the user navigated away.
class CapturedScreen {
  final ui.Image image;

  /// What the screen was, for the person choosing which one to attach —
  /// "Word Hunt", "Entry: serene" — from [describeLocation].
  final String label;
  final DateTime at;

  const CapturedScreen({required this.image, required this.label, required this.at});

  Future<Uint8List> png() async {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }
}

/// Keeps the last few screens the user was on, so a bug report can attach
/// the one the bug was seen on without them having to reproduce it.
///
/// The whole app sits inside a [RepaintBoundary] keyed by [boundaryKey].
/// Every route change — a push, a pop, a tab switch, all of which go
/// through the router — is announced by the router delegate before the
/// new screen has been built, so a snapshot taken right then is of the
/// screen being left. Nothing is encoded until a report asks for it.
class ScreenCapture extends ChangeNotifier {
  static final ScreenCapture instance = ScreenCapture();

  final GlobalKey boundaryKey = GlobalKey(debugLabel: 'screen capture');

  /// How many screens to keep, newest first.
  static const int keep = 4;

  /// Snapshots are capped at this pixel ratio: enough to read the text,
  /// small enough to send.
  static const double maxPixelRatio = 2.0;

  final List<CapturedScreen> _recent = [];
  List<CapturedScreen> get recent => List.unmodifiable(_recent);

  GoRouter? _router;
  RouteMatchList? _configuration;
  DateTime? _lastAt;

  /// Follows [router]: each change of route snapshots the screen being
  /// left, labelled by where it was.
  void watch(GoRouter router) {
    unwatch();
    _router = router;
    _configuration = router.routerDelegate.currentConfiguration;
    router.routerDelegate.addListener(_onRouteChange);
  }

  void unwatch() {
    _router?.routerDelegate.removeListener(_onRouteChange);
    _router = null;
    _configuration = null;
  }

  void _onRouteChange() {
    final router = _router;
    if (router == null) return;
    final from = _configuration;
    final to = router.routerDelegate.currentConfiguration;
    if (identical(from, to)) return;
    _configuration = to;
    capture(label: describeLocation(from == null ? '' : locationOf(from)));
  }

  /// Where a configuration has the user: the pushed page when there is
  /// one — `push` leaves the configuration's own `uri` at the page
  /// underneath — otherwise the configuration's location.
  @visibleForTesting
  static String locationOf(RouteMatchList configuration) {
    if (configuration.matches.isEmpty) return configuration.uri.toString();
    final last = configuration.last;
    if (last is ImperativeRouteMatch) return last.matches.uri.toString();
    return configuration.uri.toString();
  }

  /// Snapshots the app as last painted. Skipped when nothing has been
  /// painted yet, or when a snapshot was taken a moment ago (a redirect
  /// chain announces several locations for one navigation).
  Future<void> capture({required String label}) async {
    final now = DateTime.now();
    if (_lastAt != null && now.difference(_lastAt!) < const Duration(milliseconds: 300)) {
      return;
    }
    final context = boundaryKey.currentContext;
    final boundary = context?.findRenderObject();
    if (context == null || boundary is! RenderRepaintBoundary) return;
    // In debug builds toImage asserts on a boundary that's waiting to be
    // repainted; in release it just rasterises what's there, which is the
    // frame we want.
    if (kDebugMode && boundary.debugNeedsPaint) return;
    _lastAt = now;
    final ratio = min(View.of(context).devicePixelRatio, maxPixelRatio);
    final ui.Image image;
    try {
      image = await boundary.toImage(pixelRatio: ratio);
    } catch (_) {
      return;
    }
    _recent.insert(0, CapturedScreen(image: image, label: label, at: now));
    while (_recent.length > keep) {
      _recent.removeLast().image.dispose();
    }
    notifyListeners();
  }

  @visibleForTesting
  void clear() {
    for (final s in _recent) {
      s.image.dispose();
    }
    _recent.clear();
    _lastAt = null;
  }
}

/// A route location as the user would name the screen. Falls back to the
/// path itself for anything not listed.
String describeLocation(String location) {
  final uri = Uri.tryParse(location);
  final path = uri?.path ?? location;
  final segments = [
    for (final s in path.split('/'))
      if (s.isNotEmpty) s,
  ];
  if (segments.isEmpty) return 'Start';
  switch (segments.first) {
    case 'search':
      return 'Search';
    case 'reader':
      return switch (segments.elementAtOrNull(1)) {
        'history' => 'Reader history',
        'edit' => 'Reader editor',
        _ => 'Reader',
      };
    case 'lists':
      return segments.length > 1 ? 'List' : 'Lists';
    case 'study':
      return switch (segments.elementAtOrNull(1)) {
        'session' => 'Study session',
        'manage' => 'Manage study',
        'progress' => 'Progress',
        _ => 'Study',
      };
    case 'games':
      return switch (segments.elementAtOrNull(1)) {
        'hunt' => segments.elementAtOrNull(2) == 'history' ? 'Word Hunt history' : 'Word Hunt',
        'crossword' => segments.elementAtOrNull(3) == 'history' ? 'Crossword history' : 'Crossword',
        'crossword-bans' => 'Banned crossword answers',
        _ => 'Games',
      };
    case 'settings':
      return 'Settings';
    case 'feedback':
      return 'Feedback';
    case 'entry':
      final word = segments.elementAtOrNull(1);
      return word == null ? 'Entry' : 'Entry: ${Uri.decodeComponent(word)}';
  }
  return path;
}
