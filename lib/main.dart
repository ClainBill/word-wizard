import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;

import 'app/environment.dart';
import 'app/providers.dart';
import 'app/router.dart';
import 'app/theme.dart';
import 'data/app_databases.dart';
import 'data/repositories/search_repository.dart';
import 'data/repositories/settings_repository.dart';
import 'data/repositories/study_repository.dart';
import 'features/settings/licences_screen.dart' show registerDataLicences;
import 'services/ai_gateway.dart';
import 'services/api_key_store.dart';
import 'services/auth_service.dart';
import 'services/feedback_config.dart' show feedbackEndpoint;
import 'services/feedback_service.dart';
import 'services/notification_service.dart';
import 'services/screen_capture.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerDataLicences();
  // The user's own OpenAI key (if any) has to be in memory before the first
  // frame so the services can check it synchronously; reading it from the
  // keystore takes up to a second on a slow device, so it overlaps the
  // database open rather than following it.
  final env = AppEnvironment.current;
  final (databases, _, auth) = await (
    AppDatabases.open(),
    ApiKeyStore.instance.load(),
    _connectBackend(env),
  ).wait;
  _configureFeedback(env, auth);
  // Snapshots the screen being left on every navigation, so a bug report
  // can attach the screen the bug was seen on.
  ScreenCapture.instance.watch(appRouter);
  runApp(
    ProviderScope(
      overrides: [
        appDatabasesProvider.overrideWithValue(databases),
        authServiceProvider.overrideWithValue(auth),
      ],
      child: const LexeryApp(),
    ),
  );
  // Reports written offline go out on the next launch that can send them.
  unawaited(FeedbackService.instance.flush());

  // Fire-and-forget: refreshes today/tomorrow's reminder and word-of-the-
  // day notifications on every launch (see NotificationService's doc
  // comment for why) without blocking the first frame on permission
  // dialogs or database queries.
  final settings = SettingsRepository(databases.user);
  final notifications = NotificationService.instance;
  // A tapped notification opens what it was about: the word's card.
  notifications.onOpen = appRouter.push;
  final launchRoute = await notifications.launchRoute();
  if (launchRoute != null) {
    // After the first frame, so the shell the route sits on top of exists.
    WidgetsBinding.instance.addPostFrameCallback((_) => appRouter.push(launchRoute));
  }
  final remindersEnabled = await settings.watchRemindersEnabled().first;
  final wordOfTheDayEnabled = await settings.watchWordOfTheDayEnabled().first;
  if (remindersEnabled || wordOfTheDayEnabled) await notifications.requestPermissions();
  if (remindersEnabled) {
    await notifications.scheduleDailyReminders(StudyRepository(databases.user));
  }
  if (wordOfTheDayEnabled) {
    await notifications.scheduleWordOfTheDay(
      SearchRepository(databases.dictionary).wordOfTheDay,
    );
  }
}

/// Accounts and the AI gateway, when the build has a backend. Without one
/// (a prod build before lexery-prod exists, or a stripped build) the app is
/// what it was: offline, signed out, AI only with a developer key.
Future<AuthService> _connectBackend(AppEnvironment env) async {
  if (!env.isConfigured) return const NoAuthService();
  // The legacy anon key rather than the newer publishable key, on purpose:
  // the Edge Functions' gateway JWT check (`verify_jwt`) accepts the anon
  // key — it is a JWT — for signed-out calls to `feedback` and
  // `delete-account`, and a publishable key is not one. Moving to
  // publishable keys means `verify_jwt = false` on those two and
  // validating inside them, which they already do; a follow-up.
  // ignore: deprecated_member_use
  await Supabase.initialize(url: env.supabaseUrl, anonKey: env.supabaseAnonKey);
  final auth = SupabaseAuthService(Supabase.instance.client, env);
  AiGateway.instance = AiGateway(
    env: env,
    hasSession: () => auth.isSignedIn,
    accessToken: auth.accessToken,
  );
  return auth;
}

/// Reports go to the backend's `feedback` function, or to the Apps Script
/// relay if a `FEEDBACK_ENDPOINT` define names one, or wait in the outbox.
void _configureFeedback(AppEnvironment env, AuthService auth) {
  final FeedbackSender? sender;
  if (feedbackEndpoint.isNotEmpty) {
    sender = HttpFeedbackSender(Uri.parse(feedbackEndpoint));
  } else if (env.isConfigured) {
    sender = HttpFeedbackSender(
      env.functionUrl('feedback'),
      headers: () async => {
        'apikey': env.supabaseAnonKey,
        'Authorization': 'Bearer ${await auth.accessToken() ?? env.supabaseAnonKey}',
      },
    );
  } else {
    sender = null;
  }
  FeedbackService.instance = FeedbackService.standard(sender: sender);
}

class LexeryApp extends ConsumerWidget {
  const LexeryApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // System until the setting's first value arrives, which is also the
    // answer for anyone who has never changed it.
    final themeMode = ref.watch(themeModeProvider).valueOrNull ?? ThemeMode.system;
    return MaterialApp.router(
      title: 'Lexery',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      routerConfig: appRouter,
      // Everything, dialogs and sheets included, inside the boundary the
      // screen capture snapshots.
      builder: (context, child) =>
          RepaintBoundary(key: ScreenCapture.instance.boundaryKey, child: child!),
    );
  }
}
