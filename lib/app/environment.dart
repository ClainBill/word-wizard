/// Which backend the build talks to. Selected at build time:
///
/// ```
/// flutter run --dart-define=ENV=dev      # the default
/// flutter build appbundle --dart-define=ENV=prod
/// ```
///
/// The anon key is public by design — it identifies the project, and
/// row-level security is what protects the data — so both keys live here
/// rather than in a secret. The service-role key and every provider key
/// stay on the server (`supabase/.env.example`).
library;

import 'package:flutter/foundation.dart' show kDebugMode;

enum AppEnv { dev, prod }

class AppEnvironment {
  final AppEnv env;
  final String supabaseUrl;
  final String supabaseAnonKey;

  /// RevenueCat's *public* SDK keys, one per store (Project → API keys).
  /// Public by design, like the anon key; the secret key stays on the
  /// server. Empty until the RevenueCat project exists: a debug build then
  /// uses an in-memory store, a release build sells nothing.
  final String revenueCatAppleKey;
  final String revenueCatGoogleKey;

  /// Google Cloud OAuth client ids for native Google sign-in: the *web*
  /// client (what Supabase verifies id tokens against, and Android's
  /// `serverClientId`) and the iOS client (whose reversed id also goes in
  /// Info.plist as a URL scheme). Public identifiers. Empty until the
  /// Google Cloud project exists — Google sign-in then goes through the
  /// browser via Supabase's OAuth flow instead, which needs only the
  /// provider set up in the Supabase dashboard.
  final String googleWebClientId;
  final String googleIosClientId;

  const AppEnvironment({
    required this.env,
    required this.supabaseUrl,
    required this.supabaseAnonKey,
    this.revenueCatAppleKey = '',
    this.revenueCatGoogleKey = '',
    this.googleWebClientId = const String.fromEnvironment('GOOGLE_WEB_CLIENT_ID'),
    this.googleIosClientId = const String.fromEnvironment('GOOGLE_IOS_CLIENT_ID'),
  });

  static const _dev = AppEnvironment(
    env: AppEnv.dev,
    supabaseUrl: 'https://pnbenhthybmszavtonrj.supabase.co',
    supabaseAnonKey:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBuYmVuaHRoeWJtc3phdnRvbnJqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODk2MTM2NTMsImV4cCI6MjEwNTE4OTY1M30.gRVa79LCVg5wgECOTDksIQ6Qn1p2GR21B2s0-XxbiyE',
  );

  /// Fill in once the lexery-prod project exists (supabase/README.md).
  static const _prod = AppEnvironment(env: AppEnv.prod, supabaseUrl: '', supabaseAnonKey: '');

  static const String _selected = String.fromEnvironment('ENV', defaultValue: 'dev');

  /// Whether the developer conveniences are in this build: the in-memory
  /// store with the fake-Premium switch, the fake founder count, the
  /// `.env` OpenAI key, the debug tiles in Settings. On in every debug
  /// build; a release build gets them with `--dart-define=DEV_TOOLS=true`
  /// — a fast, compressed build for testing on a phone, never for the
  /// stores.
  static const bool devTools = bool.fromEnvironment('DEV_TOOLS', defaultValue: kDebugMode);

  static const AppEnvironment current = _selected == 'prod' ? _prod : _dev;

  bool get isConfigured => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  /// The store key for this platform, or empty if there isn't one.
  String revenueCatKey({required bool ios}) => ios ? revenueCatAppleKey : revenueCatGoogleKey;

  Uri functionUrl(String name) => Uri.parse('$supabaseUrl/functions/v1/$name');
}
