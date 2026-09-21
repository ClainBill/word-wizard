import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'ads_config.dart';
import 'ads_service.dart';

/// [AdsService] over the Google Mobile Ads SDK (AdMob), with the UMP
/// consent flow the SDK requires in the EEA/UK and the ATT prompt on iOS
/// (`NSUserTrackingUsageDescription` in Info.plist).
class GoogleAdsService implements AdsService {
  final AdsConfig _config;
  final bool Function() _isPremium;
  final InterstitialGate _gate;
  final ValueNotifier<bool> _canRequest = ValueNotifier(false);
  InterstitialAd? _interstitial;
  bool _loadingInterstitial = false;

  GoogleAdsService._(this._config, this._isPremium, this._gate);

  static const Duration startDelay = Duration(seconds: 6);

  /// Returns at once and initialises in the background — consent and
  /// SDK start-up take seconds and must never delay the first frame.
  /// Never throws: on any failure the service stays unavailable and the
  /// app shows no ads this launch.
  static GoogleAdsService start({
    required AdsConfig config,
    required bool Function() isPremium,
    InterstitialGate? gate,
  }) {
    final service = GoogleAdsService._(config, isPremium, gate ?? InterstitialGate());
    // A few seconds after launch, not during it: the SDK spins up a
    // WebView and a consent check, which on a slow phone is enough CPU
    // to push the first frame past the ANR threshold.
    unawaited(Future.delayed(startDelay, service._init));
    return service;
  }

  Future<void> _init() async {
    try {
      final allowed = await _gatherConsent();
      if (!allowed) return;
      await MobileAds.instance.initialize();
      _canRequest.value = true;
      _preloadInterstitial();
    } catch (e) {
      adsLog('start failed: $e');
      _canRequest.value = false;
    }
  }

  Future<bool> _gatherConsent() async {
    final completer = Completer<void>();
    ConsentInformation.instance.requestConsentInfoUpdate(
      ConsentRequestParameters(),
      () async {
        // Shows the form only where the law requires one; elsewhere this
        // returns at once.
        await ConsentForm.loadAndShowConsentFormIfRequired((error) {
          if (error != null) adsLog('consent form: ${error.message}');
          if (!completer.isCompleted) completer.complete();
        });
      },
      (error) {
        adsLog('consent info: ${error.message}');
        if (!completer.isCompleted) completer.complete();
      },
    );
    await completer.future.timeout(const Duration(seconds: 8), onTimeout: () {});
    final allowed = await ConsentInformation.instance.canRequestAds();
    adsLog('can request ads: $allowed');
    return allowed;
  }

  @override
  bool get available => _canRequest.value;

  @override
  Listenable get availability => _canRequest;

  @override
  Future<BannerHandle?> loadBanner({required int width}) async {
    if (!_canRequest.value || _isPremium()) return null;
    final size = await AdSize.getLargeAnchoredAdaptiveBannerAdSize(width) ?? AdSize.banner;
    final completer = Completer<BannerHandle?>();
    late final BannerAd ad;
    ad = BannerAd(
      adUnitId: _config.banner,
      size: size,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (_) {
          if (!completer.isCompleted) completer.complete(_GoogleBanner(ad, size.height.toDouble()));
        },
        onAdFailedToLoad: (ad, error) {
          adsLog('banner failed: ${error.code} ${error.message}');
          ad.dispose();
          if (!completer.isCompleted) completer.complete(null);
        },
      ),
    );
    await ad.load();
    return completer.future;
  }

  void _preloadInterstitial() {
    if (_interstitial != null || _loadingInterstitial || !_canRequest.value) return;
    _loadingInterstitial = true;
    InterstitialAd.load(
      adUnitId: _config.interstitial,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          _loadingInterstitial = false;
          _interstitial = ad;
        },
        onAdFailedToLoad: (error) {
          _loadingInterstitial = false;
          adsLog('interstitial failed: ${error.code} ${error.message}');
        },
      ),
    );
  }

  @override
  Future<bool> showInterstitial({required String placement}) async {
    final ad = _interstitial;
    if (!_gate.allows(isPremium: _isPremium(), adReady: ad != null)) {
      // Keep one warm for next time, unless the person went premium.
      if (!_isPremium()) _preloadInterstitial();
      return false;
    }
    _interstitial = null;
    final dismissed = Completer<void>();
    ad!.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        if (!dismissed.isCompleted) dismissed.complete();
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        adsLog('interstitial show failed: ${error.message}');
        ad.dispose();
        if (!dismissed.isCompleted) dismissed.complete();
      },
    );
    _gate.markShown();
    adsLog('interstitial: $placement');
    await ad.show();
    await dismissed.future;
    _preloadInterstitial();
    return true;
  }
}

class _GoogleBanner implements BannerHandle {
  final BannerAd _ad;
  @override
  final double height;

  _GoogleBanner(this._ad, this.height);

  @override
  Widget get widget => SizedBox(
    height: height,
    width: _ad.size.width.toDouble(),
    child: AdWidget(ad: _ad),
  );

  @override
  void dispose() => _ad.dispose();
}
