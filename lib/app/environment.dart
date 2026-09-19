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

enum AppEnv { dev, prod }

class AppEnvironment {
  final AppEnv env;
  final String supabaseUrl;
  final String supabaseAnonKey;

  const AppEnvironment({
    required this.env,
    required this.supabaseUrl,
    required this.supabaseAnonKey,
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

  static const AppEnvironment current = _selected == 'prod' ? _prod : _dev;

  bool get isConfigured => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  Uri functionUrl(String name) => Uri.parse('$supabaseUrl/functions/v1/$name');
}
