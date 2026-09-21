/// AdMob identifiers. Google's *test* units by default, so a build with no
/// real ids shows clearly-labelled test ads and never risks an invalid-
/// traffic strike. Real ids at build time:
///
/// ```
/// flutter build appbundle --dart-define=ADMOB_BANNER_ANDROID=ca-app-pub-… \
///   --dart-define=ADMOB_INTERSTITIAL_ANDROID=ca-app-pub-… (and the _IOS pair)
/// ```
///
/// The *app* id lives in AndroidManifest.xml (`com.google.android.gms.ads
/// .APPLICATION_ID`) and Info.plist (`GADApplicationIdentifier`) — the SDK
/// reads it before Dart runs — and is Google's test app id until replaced.
library;

class AdsConfig {
  final String banner;
  final String interstitial;

  const AdsConfig({required this.banner, required this.interstitial});

  static const _android = AdsConfig(
    banner: String.fromEnvironment(
      'ADMOB_BANNER_ANDROID',
      defaultValue: 'ca-app-pub-3940256099942544/6300978111',
    ),
    interstitial: String.fromEnvironment(
      'ADMOB_INTERSTITIAL_ANDROID',
      defaultValue: 'ca-app-pub-3940256099942544/1033173712',
    ),
  );

  static const _ios = AdsConfig(
    banner: String.fromEnvironment(
      'ADMOB_BANNER_IOS',
      defaultValue: 'ca-app-pub-3940256099942544/2934735716',
    ),
    interstitial: String.fromEnvironment(
      'ADMOB_INTERSTITIAL_IOS',
      defaultValue: 'ca-app-pub-3940256099942544/4411468910',
    ),
  );

  static AdsConfig forPlatform({required bool ios}) => ios ? _ios : _android;

  /// Whether these are Google's sample units — shown in Settings so a
  /// release with test ads is caught.
  bool get isTest => banner.startsWith('ca-app-pub-3940256099942544/');
}
