import 'dart:async' show Completer, unawaited;
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;

import 'app/environment.dart';
import 'app/launch_screen.dart';
import 'app/providers.dart';
import 'app/router.dart';
import 'app/theme.dart';
import 'data/app_databases.dart';
import 'data/repositories/search_repository.dart';
import 'data/repositories/settings_repository.dart';
import 'data/repositories/study_repository.dart';
import 'features/settings/licences_screen.dart' show registerDataLicences;
import 'services/ads_config.dart';
import 'services/ads_service.dart';
import 'services/ai_gateway.dart';
import 'services/api_key_store.dart';
import 'services/auth_service.dart';
import 'services/entitlement_sync.dart';
import 'services/feedback_config.dart' show feedbackEndpoint;
import 'services/feedback_service.dart';
import 'services/founder_service.dart';
import 'services/google_ads_service.dart';
import 'services/groups_api.dart';
import 'services/leaderboard_api.dart';
import 'services/notification_service.dart';
import 'services/premium_prompts.dart';
import 'services/purchases_service.dart';
import 'services/revenuecat_purchases_service.dart';
import 'services/screen_capture.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerDataLicences();
  // The first frame goes up before any of the work below: the launch
  // screen, with the mark and — on a first run, while the dictionary is
  // copied out of the asset pack — a progress bar. Everything the app
  // needs opens behind it, and the app replaces it when ready. Doing that
  // work before runApp held the first frame for 30 s+ on a first run,
  // which Android reports as the app not responding.
  final progress = ValueNotifier<LaunchProgress>(const LaunchProgress());
  final ready = Completer<Widget>();
  runApp(LaunchScreen(progress: progress, app: ready.future));

  final _Boot boot;
  try {
    boot = await _boot(progress);
  } catch (e, s) {
    debugPrint('boot failed: $e\n$s');
    progress.value = LaunchProgress(error: '$e');
    return;
  }
  ready.complete(boot.app);
  await _afterLaunch(boot);
}

/// What [_boot] hands back: the app widget and the pieces the post-launch
/// work needs.
class _Boot {
  final Widget app;
  final AppDatabases databases;
  final PremiumPrompts prompts;

  const _Boot({required this.app, required this.databases, required this.prompts});
}

/// Opens everything and builds the app widget. Runs while the launch
/// screen shows; [progress] is what it says meanwhile.
Future<_Boot> _boot(ValueNotifier<LaunchProgress> progress) async {
  // The user's own OpenAI key (if any) has to be in memory before the app's
  // first frame so the services can check it synchronously; reading it
  // from the keystore takes up to a second on a slow device, so it
  // overlaps the database open rather than following it.
  final env = AppEnvironment.current;
  final (databases, _, auth) = await (
    AppDatabases.open(
      onDictionaryProgress: (fraction) => progress.value = LaunchProgress(
        status: 'Setting up the dictionary…',
        fraction: fraction,
      ),
    ),
    ApiKeyStore.instance.load(),
    _connectBackend(env),
  ).wait;
  progress.value = const LaunchProgress();
  _configureFeedback(env, auth);
  final purchases = await _connectStore(env, auth);
  final founders = env.isConfigured
      ? HttpFounderService(env, accessToken: auth.accessToken)
      : FakeFounderService(remaining: AppEnvironment.devTools ? 137 : null);
  final prompts = PremiumPrompts(SettingsRepository(databases.user));
  // Ads are the free tier's; the service asks the store's answer at every
  // request, so going premium ends them without a restart.
  final ads = _connectAds(isPremium: () => purchases.current.isPremium);
  // Snapshots the screen being left on every navigation, so a bug report
  // can attach the screen the bug was seen on.
  ScreenCapture.instance.watch(appRouter);
  final app = ProviderScope(
    overrides: [
      appDatabasesProvider.overrideWithValue(databases),
      authServiceProvider.overrideWithValue(auth),
      purchasesServiceProvider.overrideWithValue(purchases),
      founderServiceProvider.overrideWithValue(founders),
      premiumPromptsProvider.overrideWithValue(prompts),
      adsServiceProvider.overrideWithValue(ads),
      if (env.isConfigured) ...[
        groupsApiProvider.overrideWithValue(SupabaseGroupsApi(Supabase.instance.client)),
        leaderboardApiProvider.overrideWithValue(SupabaseLeaderboardApi(Supabase.instance.client)),
      ],
    ],
    child: WordWizardApp(purchases: purchases),
  );
  return _Boot(app: app, databases: databases, prompts: prompts);
}

/// Everything that can wait until the app is on screen.
Future<void> _afterLaunch(_Boot boot) async {
  final databases = boot.databases;
  // Reports written offline go out on the next launch that can send them.
  unawaited(FeedbackService.instance.flush());
  // This launch counts as a session for the prompt policy (spec §5.2).
  unawaited(boot.prompts.startSession());

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
    // After the frame that swaps the launch screen for the app, so the
    // shell the route sits on top of exists.
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

/// The store. RevenueCat when this platform has a key; otherwise an
/// in-memory stand-in in debug builds (so the paywall and the gate can be
/// worked on) and nothing at all in release, where Settings says so.
///
/// Purchases follow the account: the SDK is told the Supabase user id on
/// sign-in and forgets it on sign-out, and the backend is asked to
/// re-derive the entitlement whenever the store's answer changes.
Future<PurchasesService> _connectStore(AppEnvironment env, AuthService auth) async {
  final key = env.revenueCatKey(ios: Platform.isIOS);
  final PurchasesService purchases;
  if (key.isNotEmpty) {
    try {
      purchases = await RevenueCatPurchasesService.start(apiKey: key, userId: auth.currentUser?.id);
    } catch (e, s) {
      debugPrint('revenuecat: configure failed, no store this launch: $e\n$s');
      return const NoPurchasesService();
    }
  } else if (AppEnvironment.devTools) {
    purchases = FakePurchasesService(latency: const Duration(milliseconds: 600));
  } else {
    return const NoPurchasesService();
  }
  EntitlementSync.instance = EntitlementSync(env: env, accessToken: auth.accessToken);
  String? linked = auth.currentUser?.id;
  auth.changes.listen((user) async {
    if (user?.id == linked) return;
    linked = user?.id;
    if (user == null) {
      await purchases.logOut();
    } else {
      await purchases.logIn(user.id);
      await EntitlementSync.instance.refresh(force: true);
    }
  });
  var wasPremium = purchases.current.isPremium;
  purchases.changes.listen((status) {
    if (status.isPremium != wasPremium) {
      wasPremium = status.isPremium;
      unawaited(EntitlementSync.instance.refresh());
    }
  });
  return purchases;
}

/// AdMob on the phones; nothing elsewhere. Starts in the background —
/// never on the first frame's path. A failure to initialise (no network,
/// consent SDK unhappy) means no ads this launch, not a crash.
AdsService _connectAds({required bool Function() isPremium}) {
  if (!Platform.isAndroid && !Platform.isIOS) return const NoAdsService();
  return GoogleAdsService.start(
    config: AdsConfig.forPlatform(ios: Platform.isIOS),
    isPremium: isPremium,
  );
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

class WordWizardApp extends ConsumerStatefulWidget {
  final PurchasesService purchases;

  const WordWizardApp({super.key, required this.purchases});

  @override
  ConsumerState<WordWizardApp> createState() => _WordWizardAppState();
}

class _WordWizardAppState extends ConsumerState<WordWizardApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Coming back to the foreground re-reads the store's answer, so a
  /// renewal, refund or restore made elsewhere shows up (spec §6.5).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(widget.purchases.refresh());
  }

  @override
  Widget build(BuildContext context) {
    // System until the setting's first value arrives, which is also the
    // answer for anyone who has never changed it.
    final themeMode = ref.watch(themeModeProvider).valueOrNull ?? ThemeMode.system;
    return MaterialApp.router(
      title: 'Word Wizard',
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
