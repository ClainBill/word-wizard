import 'package:flutter/foundation.dart';

/// The events spec §8.1 asks for, with the properties it lists — and none
/// of the things it forbids (no vocabulary, receipts or full transaction
/// ids). There is no analytics SDK in the app yet; this is the seam one
/// plugs into. The default logs in debug builds and drops in release.
class PremiumAnalytics {
  static PremiumAnalytics instance = PremiumAnalytics();

  final void Function(String event, Map<String, Object?> properties)? _sink;

  PremiumAnalytics([this._sink]);

  void log(String event, [Map<String, Object?> properties = const {}]) {
    final sink = _sink;
    if (sink != null) {
      sink(event, properties);
    } else if (kDebugMode) {
      debugPrint('analytics: $event $properties');
    }
  }
}
