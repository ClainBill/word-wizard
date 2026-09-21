import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Ads for the free tier: a banner on every word card and an interstitial
/// when a spaced-review session ends. Premium removes both (spec §7.3):
/// the banner widget rebuilds away the moment the entitlement changes, and
/// an interstitial is never shown to a premium account.
///
/// Behind an interface so tests and key-less builds use [NoAdsService]
/// and the real one ([GoogleAdsService]) is the only file that imports
/// the SDK.
abstract class AdsService {
  /// Whether the SDK is wired and allowed to request ads (initialised,
  /// consent gathered where required). Can flip to true a few seconds
  /// after launch — initialisation never holds up the first frame — so
  /// banners listen to [availability].
  bool get available;

  /// Notifies when [available] changes.
  Listenable get availability;

  /// A banner for one screen, sized to [width] logical pixels, or null
  /// when there's nothing to show. The caller owns the returned handle
  /// and must [BannerHandle.dispose] it.
  Future<BannerHandle?> loadBanner({required int width});

  /// Shows a full-screen ad if one is ready and the gate allows.
  /// Completes when the ad is dismissed (or at once if none showed).
  /// Returns whether one was shown.
  Future<bool> showInterstitial({required String placement});
}

/// One loaded banner: the widget to place and its height.
abstract class BannerHandle {
  Widget get widget;
  double get height;
  void dispose();
}

/// No SDK in this build (tests, or an unsupported platform).
class NoAdsService implements AdsService {
  const NoAdsService();

  static final _never = ValueNotifier<bool>(false);

  @override
  bool get available => false;
  @override
  Listenable get availability => _never;
  @override
  Future<BannerHandle?> loadBanner({required int width}) async => null;
  @override
  Future<bool> showInterstitial({required String placement}) async => false;
}

/// Decides whether an interstitial may show now (spec §5.2/§7.3 spirit —
/// one monetisation surface per moment, never back to back). Pure, so
/// it's tested; [GoogleAdsService] consults it.
class InterstitialGate {
  /// Shortest gap between two interstitials.
  final Duration minInterval;
  DateTime? _lastShownAt;

  InterstitialGate({this.minInterval = const Duration(minutes: 3)});

  bool allows({required bool isPremium, required bool adReady, DateTime? now}) {
    if (isPremium || !adReady) return false;
    final last = _lastShownAt;
    if (last != null && (now ?? DateTime.now()).difference(last) < minInterval) return false;
    return true;
  }

  void markShown([DateTime? at]) => _lastShownAt = at ?? DateTime.now();
}

/// A stand-in that records calls and can pretend to show — tests and the
/// debug "no key" path use it.
class FakeAdsService implements AdsService {
  final bool Function() isPremium;
  final InterstitialGate gate;
  final List<String> interstitials = [];
  int bannersLoaded = 0;

  /// What [loadBanner] hands back; null means "no fill".
  BannerHandle Function()? bannerBuilder;

  FakeAdsService({required this.isPremium, InterstitialGate? gate})
    : gate = gate ?? InterstitialGate();

  final ValueNotifier<bool> _available = ValueNotifier(true);

  @override
  bool get available => _available.value;
  set available(bool value) => _available.value = value;
  @override
  Listenable get availability => _available;

  @override
  Future<BannerHandle?> loadBanner({required int width}) async {
    if (isPremium()) return null;
    bannersLoaded++;
    return bannerBuilder?.call();
  }

  @override
  Future<bool> showInterstitial({required String placement}) async {
    if (!gate.allows(isPremium: isPremium(), adReady: true)) return false;
    gate.markShown();
    interstitials.add(placement);
    return true;
  }
}

/// A placeholder banner for the fake: a labelled box of the standard
/// height, so layouts can be checked without the SDK.
class PlaceholderBanner implements BannerHandle {
  final String label;
  PlaceholderBanner([this.label = 'Test banner']);

  @override
  double get height => 50;

  @override
  Widget get widget => SizedBox(
    height: height,
    child: Center(child: Text(label, style: const TextStyle(fontSize: 12))),
  );

  @override
  void dispose() {}
}

/// Logs to the console in debug builds; a seam for analytics later.
void adsLog(String message) {
  if (kDebugMode) debugPrint('ads: $message');
}
