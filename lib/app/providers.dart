import 'dart:math';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../data/app_databases.dart';
import '../data/repositories/backup_repository.dart';
import '../data/repositories/crossword_repository.dart';
import '../data/repositories/hunt_repository.dart';
import '../data/repositories/list_repository.dart';
import '../data/repositories/notes_repository.dart';
import '../data/repositories/progress_repository.dart';
import '../data/repositories/reader_repository.dart';
import '../data/repositories/score_repository.dart';
import '../data/repositories/search_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../data/repositories/study_repository.dart';
import '../domain/board/word_board.dart';
import '../domain/crossword/crossword_models.dart';
import '../domain/models/daily_word.dart';
import '../domain/models/progress.dart';
import '../domain/models/reader_document.dart';
import '../domain/models/study_dashboard.dart';
import '../domain/games/scoring.dart';
import '../domain/groups/group_models.dart';
import '../domain/models/study_direction.dart';
import '../domain/premium/premium.dart';
import '../domain/reader/reader_analysis.dart';
import '../services/ads_service.dart';
import '../services/api_key_store.dart';
import '../services/auth_service.dart';
import '../services/clipboard_service.dart';
import '../services/feedback_service.dart';
import '../services/founder_service.dart';
import '../services/group_puzzle_service.dart';
import '../services/groups_api.dart';
import '../services/leaderboard_api.dart';
import '../services/score_sync.dart';
import '../services/premium_prompts.dart';
import '../services/purchases_service.dart';
import '../services/notification_service.dart';
import '../services/screen_capture.dart';

/// Overridden with a real, already-opened [AppDatabases] in `main()` before
/// [runApp] — every provider below assumes the databases are ready.
final appDatabasesProvider = Provider<AppDatabases>(
  (ref) => throw UnimplementedError('appDatabasesProvider must be overridden in main()'),
);

final searchRepositoryProvider = Provider<SearchRepository>(
  (ref) => SearchRepository(ref.watch(appDatabasesProvider).dictionary),
);

final listRepositoryProvider = Provider<ListRepository>(
  (ref) => ListRepository(ref.watch(appDatabasesProvider).user),
);

final studyRepositoryProvider = Provider<StudyRepository>(
  (ref) => StudyRepository(ref.watch(appDatabasesProvider).user),
);

final backupRepositoryProvider = Provider<BackupRepository>(
  (ref) => BackupRepository(ref.watch(appDatabasesProvider).user),
);

final notesRepositoryProvider = Provider<NotesRepository>(
  (ref) => NotesRepository(ref.watch(appDatabasesProvider).user),
);

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepository(ref.watch(appDatabasesProvider).user),
);

final remindersEnabledProvider = StreamProvider<bool>(
  (ref) => ref.watch(settingsRepositoryProvider).watchRemindersEnabled(),
);

final wordOfTheDayEnabledProvider = StreamProvider<bool>(
  (ref) => ref.watch(settingsRepositoryProvider).watchWordOfTheDayEnabled(),
);

/// The featured word for one calendar day, keyed by the day so the Search
/// tab — alive across tab switches — moves on at midnight rather than
/// keeping yesterday's.
final wordOfTheDayProvider = FutureProvider.family<DailyWord?, DateTime>(
  (ref, day) => ref.watch(searchRepositoryProvider).wordOfTheDay(day),
);

/// Every Lexery word by headword and how far along it is — what the
/// landing board tints its tiles by. A stream, so a word added from the
/// board is tinted by the time they're back on it.
final familiarityProvider = StreamProvider<Map<String, Familiarity>>(
  (ref) => ref.watch(studyRepositoryProvider).watchFamiliarity(),
);

/// A fresh draw of words for the landing board, with a few of the
/// person's own Lexery words mixed in so some tiles are familiar from
/// the start. Not autoDispose: the Search tab stays alive across tab
/// switches and the board should keep the words it has; "shuffle"
/// invalidates it.
final boardWordsProvider = FutureProvider<List<String>>((ref) async {
  final random = Random();
  final words = await ref.watch(searchRepositoryProvider).boardWords();
  final own = (await ref.watch(familiarityProvider.future)).keys.where(isBoardable).toList()
    ..shuffle(random);
  final mixed = [...own.take(14), ...words]..shuffle(random);
  return mixed;
});

/// Light, dark or system — what `MaterialApp.themeMode` follows.
final themeModeProvider = StreamProvider<ThemeMode>(
  (ref) => ref.watch(settingsRepositoryProvider).watchThemeMode(),
);

/// The chosen pronunciation voice, or null for the device default.
final ttsVoiceProvider = StreamProvider<TtsVoiceChoice?>(
  (ref) => ref.watch(settingsRepositoryProvider).watchTtsVoice(),
);

/// The user's own OpenAI key. A ChangeNotifier so Settings (and the
/// crossword's "AI editor" switch) follow a save or removal immediately.
final apiKeyStoreProvider = ChangeNotifierProvider<ApiKeyStore>((ref) => ApiKeyStore.instance);

final notificationServiceProvider = Provider<NotificationService>(
  (ref) => NotificationService.instance,
);

/// Which direction(s) reviews are asked in. Every study query below filters
/// on it, so changing it in the options sheet re-scopes the due count, the
/// dashboard and the forecast at once.
final studyDirectionModeProvider = StreamProvider<StudyDirectionMode>(
  (ref) => ref.watch(settingsRepositoryProvider).watchStudyDirectionMode(),
);

/// The synchronous read the study queries need. Falls back to the default
/// mode for the one frame before the setting's first value arrives from the
/// database — which is also the correct answer for anyone who has never
/// changed it.
final studyDirectionsProvider = Provider<Set<StudyDirection>>((ref) {
  final mode = ref.watch(studyDirectionModeProvider).valueOrNull ??
      StudyDirectionMode.defaultMode;
  return mode.directions;
});

final dueCountProvider = StreamProvider<int>(
  (ref) => ref.watch(studyRepositoryProvider).watchDueCount(ref.watch(studyDirectionsProvider)),
);

final studyStatsProvider = StreamProvider<StudyDashboardStats>(
  (ref) => ref.watch(studyRepositoryProvider).watchStats(ref.watch(studyDirectionsProvider)),
);

final studyForecastProvider = StreamProvider<List<int>>(
  (ref) => ref.watch(studyRepositoryProvider).watchForecast(ref.watch(studyDirectionsProvider)),
);

final studyStreakProvider = StreamProvider<int>(
  (ref) => ref.watch(studyRepositoryProvider).watchStreak(),
);

// ---------------------------------------------------------------------------
// Progress: the bar at the top of the Study tab and the screen behind it.
// ---------------------------------------------------------------------------

final progressRepositoryProvider = Provider<ProgressRepository>(
  (ref) => ProgressRepository(ref.watch(appDatabasesProvider).user),
);

final progressOverviewProvider = StreamProvider<ProgressOverview>(
  (ref) =>
      ref.watch(progressRepositoryProvider).watchOverview(ref.watch(studyDirectionsProvider)),
);

final progressSummaryProvider = StreamProvider.autoDispose<ProgressSummary>(
  (ref) =>
      ref.watch(progressRepositoryProvider).watchSummary(ref.watch(studyDirectionsProvider)),
);

final progressActivityProvider = StreamProvider.autoDispose<List<ActivityDay>>(
  (ref) => ref.watch(progressRepositoryProvider).watchActivity(),
);

final recentSearchesProvider = StreamProvider<List<String>>(
  (ref) => ref.watch(progressRepositoryProvider).watchRecentSearches(),
);

/// Which of a word's senses its study card carries — `dict.senses` ids,
/// keyed by canonical entry id. Empty means the default first sense.
final chosenSensesProvider = StreamProvider.family<Set<int>, int>(
  (ref, entryId) => ref.watch(studyRepositoryProvider).watchChosenSenses(entryId),
);

/// Pinned *and* excluded senses for one word — what the entry screen's
/// meaning rows show.
final senseChoicesProvider = StreamProvider.family<SenseChoices, int>(
  (ref, entryId) => ref.watch(studyRepositoryProvider).watchSenseChoices(entryId),
);

final ttsProvider = Provider<FlutterTts>((ref) {
  final tts = FlutterTts();
  tts.setLanguage('en-US');
  // The voice setting is applied to this one engine as it changes rather
  // than watched, which would rebuild the engine — and every speaker
  // button holding it — on each change.
  ref.listen<AsyncValue<TtsVoiceChoice?>>(
    ttsVoiceProvider,
    (_, next) => next.whenData((voice) => applyTtsVoice(tts, voice)),
    fireImmediately: true,
  );
  ref.onDispose(tts.stop);
  return tts;
});

/// Points [tts] at [voice], or back at the default English voice for null.
/// A voice that has since disappeared from the device (an uninstalled
/// language pack) is rejected by the engine, and the default is used.
Future<void> applyTtsVoice(FlutterTts tts, TtsVoiceChoice? voice) async {
  if (voice == null) {
    await tts.setLanguage('en-US');
    return;
  }
  await tts.setVoice({'name': voice.name, 'locale': voice.locale});
}

// ---------------------------------------------------------------------------
// Reader
// ---------------------------------------------------------------------------

final readerRepositoryProvider = Provider<ReaderRepository>(
  (ref) => ReaderRepository(ref.watch(appDatabasesProvider).user),
);

final clipboardServiceProvider = Provider<ClipboardService>((ref) => ClipboardService());

final readerHistoryProvider = StreamProvider<List<ReaderDocumentSummary>>(
  (ref) => ref.watch(readerRepositoryProvider).watchHistory(),
);

/// The document on the page — the most recently opened one.
final readerCurrentDocumentProvider = StreamProvider<ReaderDocument?>(
  (ref) => ref.watch(readerRepositoryProvider).watchCurrent(),
);

/// Every word of one document resolved against the dictionary. Keyed by
/// content hash as well as id so an edit re-analyzes but a rename doesn't.
typedef ReaderAnalysisKey = ({int id, String contentHash});

final readerAnalysisProvider =
    FutureProvider.autoDispose.family<ReaderAnalysis, ReaderAnalysisKey>((ref, key) async {
  final repo = ref.watch(readerRepositoryProvider);
  final doc = await repo.getDocument(key.id);
  if (doc == null) return const ReaderAnalysis([]);
  return repo.analyze(doc.blocks);
});

/// Which entries are in lists / under study — the live layer over the
/// analysis, so a word added from the page lights up at once.
final readerMarksProvider = StreamProvider<WordMarks>(
  (ref) => ref.watch(readerRepositoryProvider).watchMarks(),
);

final readerListIndexProvider = StreamProvider<Map<int, ReaderListInfo>>(
  (ref) => ref.watch(readerRepositoryProvider).watchListIndex(),
);

final readerPrefsProvider = StreamProvider<ReaderPrefs>(
  (ref) => ref.watch(settingsRepositoryProvider).watchReaderPrefs(),
);

/// Bumped by the nav shell each time the Reader tab is selected. The tab's
/// screen stays alive in the indexed stack across tab switches, so this is
/// how it knows to look at the clipboard again.
final readerTabVisitsProvider = StateProvider<int>((ref) => 0);

final crosswordRepositoryProvider = Provider<CrosswordRepository>(
  (ref) => CrosswordRepository(
    ref.watch(appDatabasesProvider).user,
    ref.watch(studyRepositoryProvider),
    ref.watch(searchRepositoryProvider),
    ref.watch(settingsRepositoryProvider),
  ),
);

/// Which puzzle to show. A null [puzzleId] means "the current one" — the
/// newest generated for today, built on first read if today has none. A
/// non-null id is a specific past generation opened from history, which is
/// never generated on demand.
typedef CrosswordSessionKey = ({CrosswordDifficulty difficulty, int? puzzleId});

final crosswordSessionProvider =
    FutureProvider.autoDispose.family<CrosswordSession?, CrosswordSessionKey>((ref, key) {
  final repo = ref.watch(crosswordRepositoryProvider);
  final id = key.puzzleId;
  return id == null ? repo.loadOrGenerate(key.difficulty) : repo.loadPuzzle(id);
});

/// **Debug.** The editorial runs against one specific puzzle, so the solving
/// screen can say whether the AI editor touched this grid.
final crosswordPuzzleReviewsProvider =
    FutureProvider.family<List<CrosswordReviewRun>, int>(
  (ref, puzzleId) => ref.watch(crosswordRepositoryProvider).reviewRunsForPuzzle(puzzleId),
);

/// Every day a puzzle's been generated for one difficulty, most recent
/// first, with how far each got and the editorial runs against it — backs
/// the history list.
///
/// `autoDispose`, for the same reason `crosswordSessionProvider` is: a
/// plain family provider would cache the first visit's list for the life of
/// the app, so a puzzle finished after that would still show as "3 of 10
/// words" the next time history was opened.
final crosswordHistoryProvider =
    FutureProvider.autoDispose.family<List<CrosswordHistoryEntry>, CrosswordDifficulty>(
  (ref, difficulty) => ref.watch(crosswordRepositoryProvider).history(difficulty),
);

/// **Debug.** What the editorial pass has cost so far at one size.
final crosswordReviewTotalsProvider =
    FutureProvider.family<CrosswordReviewTotals, CrosswordDifficulty>(
  (ref, difficulty) => ref.watch(crosswordRepositoryProvider).reviewTotals(difficulty),
);

/// **Debug.** Answers the editorial pass has rejected as unfair, which are
/// kept out of every future puzzle until unbanned.
final crosswordBannedAnswersProvider = FutureProvider<List<CrosswordBannedAnswer>>(
  (ref) => ref.watch(crosswordRepositoryProvider).bannedAnswers(),
);

/// **Debug.** Whether the editorial pass may spend money. See
/// `SettingsRepository.crosswordReviewKey`.
final crosswordReviewEnabledProvider = StreamProvider<bool>(
  (ref) => ref.watch(settingsRepositoryProvider).watchCrosswordReviewEnabled(),
);

// ---------------------------------------------------------------------------
// Word Hunt
// ---------------------------------------------------------------------------

final huntRepositoryProvider = Provider<HuntRepository>(
  (ref) => HuntRepository(
    ref.watch(appDatabasesProvider).user,
    ref.watch(studyRepositoryProvider),
  ),
);

/// Which board to show: null is today's (built on first read), a non-null
/// id is a past generation opened from history. `autoDispose` for the same
/// reason as the crossword's — a cached session would go stale under play.
final huntSessionProvider = FutureProvider.autoDispose.family<HuntSession?, int?>((ref, puzzleId) {
  final repo = ref.watch(huntRepositoryProvider);
  return puzzleId == null ? repo.loadOrGenerate() : repo.loadPuzzle(puzzleId);
});

final huntHistoryProvider = FutureProvider.autoDispose<List<HuntHistoryEntry>>(
  (ref) => ref.watch(huntRepositoryProvider).history(),
);

// ---------------------------------------------------------------------------
// Feedback
// ---------------------------------------------------------------------------

final feedbackServiceProvider = Provider<FeedbackService>((ref) => FeedbackService.instance);

/// Reports written offline and waiting in the outbox; the Settings tile
/// says so. Invalidated after every submit and flush.
final feedbackPendingProvider = FutureProvider<int>(
  (ref) => ref.watch(feedbackServiceProvider).pendingCount(),
);

/// The last few screens, for the report form's thumbnails. A
/// ChangeNotifierProvider so the form rebuilds as captures arrive.
final screenCaptureProvider = ChangeNotifierProvider<ScreenCapture>((ref) => ScreenCapture.instance);

// ---------------------------------------------------------------------------
// Account
// ---------------------------------------------------------------------------

/// Overridden in `main` with the Supabase-backed service when the build has
/// a backend; the default is signed-out forever (tests, or no backend).
final authServiceProvider = Provider<AuthService>((ref) => const NoAuthService());

/// The signed-in user, live. Null when signed out.
final authUserProvider = StreamProvider<AuthUser?>(
  (ref) => ref.watch(authServiceProvider).changes,
);

// ---------------------------------------------------------------------------
// Premium
// ---------------------------------------------------------------------------

/// Overridden in `main`: RevenueCat when the build has a key, the in-memory
/// fake in debug builds without one. The default has no store at all.
final purchasesServiceProvider = Provider<PurchasesService>((ref) => const NoPurchasesService());

/// The person's premium standing, live: a purchase, restore or expiry
/// changes it and every gate below follows without a restart.
final premiumStatusProvider = StreamProvider<PremiumStatus>(
  (ref) => ref.watch(purchasesServiceProvider).changes,
);

/// The synchronous answer the Games tab and the routes need. Falls back
/// to the service's last known standing for the frame before the stream's
/// first value.
final isPremiumProvider = Provider<bool>((ref) {
  final status = ref.watch(premiumStatusProvider).valueOrNull;
  return (status ?? ref.watch(purchasesServiceProvider).current).isPremium;
});

/// The live store prices. `autoDispose` so a paywall opened after a
/// store hiccup asks again rather than showing the cached failure.
final storeOffersProvider = FutureProvider.autoDispose<StoreOffers>(
  (ref) => ref.watch(purchasesServiceProvider).offers(),
);

/// Overridden in `main` with the backend-backed service; the default
/// can't say how many places remain, so the paywall never shows a number.
final founderServiceProvider = Provider<FounderService>(
  (ref) => FakeFounderService(remaining: null),
);

/// The Founding Member allocation, fetched when a paywall opens. Null when
/// the backend couldn't say. `autoDispose`: a count is only shown fresh.
final founderStatusProvider = FutureProvider.autoDispose<FounderStatus?>(
  (ref) => ref.watch(founderServiceProvider).status(),
);

/// The unsolicited-prompt bookkeeping. Created once and kept: its session
/// count and "shown this session" flag must outlive any screen.
final premiumPromptsProvider = Provider<PremiumPrompts>(
  (ref) => PremiumPrompts(ref.watch(settingsRepositoryProvider)),
);

// ---------------------------------------------------------------------------
// Ads (free tier only)
// ---------------------------------------------------------------------------

/// Overridden in `main` with the AdMob-backed service on Android/iOS.
/// The default shows nothing.
final adsServiceProvider = Provider<AdsService>((ref) => const NoAdsService());

// ---------------------------------------------------------------------------
// Group puzzles (v1.1)
// ---------------------------------------------------------------------------

/// Overridden in `main` with the Supabase-backed API when the build has a
/// backend.
final groupsApiProvider = Provider<GroupsApi>((ref) => const NoGroupsApi());

final groupPuzzleServiceProvider = Provider<GroupPuzzleService>(
  (ref) => GroupPuzzleService(
    ref.watch(groupsApiProvider),
    ref.watch(crosswordRepositoryProvider),
    ref.watch(huntRepositoryProvider),
    ref.watch(studyRepositoryProvider),
    ref.watch(appDatabasesProvider).user,
  ),
);

/// The groups this person belongs to. Re-fetched on every visit, and
/// after anything that changes the list.
final myGroupsProvider = FutureProvider.autoDispose<List<Group>>(
  (ref) => ref.watch(groupsApiProvider).myGroups(),
);

final groupProvider = FutureProvider.autoDispose.family<Group?, String>(
  (ref, id) => ref.watch(groupsApiProvider).group(id),
);

final groupMembersProvider = FutureProvider.autoDispose.family<List<GroupMember>, String>(
  (ref, id) => ref.watch(groupsApiProvider).members(id),
);

final groupPoolProvider = FutureProvider.autoDispose.family<List<GroupWord>, String>(
  (ref, id) => ref.watch(groupsApiProvider).pool(id),
);

/// Today's published puzzle for a group, or null if nobody has opened it
/// yet today.
final groupTodayPuzzleProvider = FutureProvider.autoDispose.family<GroupPuzzle?, String>(
  (ref, id) async {
    final group = await ref.watch(groupProvider(id).future);
    if (group == null) return null;
    return ref.watch(groupPuzzleServiceProvider).todayPuzzle(group);
  },
);

final groupScoresProvider = FutureProvider.autoDispose.family<List<GroupScore>, String>(
  (ref, puzzleId) => ref.watch(groupsApiProvider).scores(puzzleId),
);

/// A group's standings — every member's points summed — this week or
/// all time.
final groupStandingsProvider = FutureProvider.autoDispose
    .family<List<GroupStanding>, (String, GroupStandingsPeriod)>(
      (ref, key) => ref
          .watch(groupsApiProvider)
          .standings(key.$1, since: key.$2.since(DateTime.now())),
    );

// ---------------------------------------------------------------------------
// Global leaderboard
// ---------------------------------------------------------------------------

/// Overridden in `main` with the Supabase-backed API when there's a backend.
final leaderboardApiProvider = Provider<LeaderboardApi>((ref) => const NoLeaderboardApi());

final scoreSyncProvider = Provider<ScoreSync>(
  (ref) => ScoreSync(ScoreRepository(ref.watch(appDatabasesProvider).user), ref.watch(leaderboardApiProvider)),
);

final leaderboardProfileProvider = FutureProvider.autoDispose<LeaderboardProfile>(
  (ref) => ref.watch(leaderboardApiProvider).profile(),
);

/// 'week' or 'all'.
final leaderboardProvider = FutureProvider.autoDispose.family<List<LeaderboardEntry>, String>(
  (ref, period) => ref.watch(leaderboardApiProvider).top(period: period),
);

final myRankProvider = FutureProvider.autoDispose.family<MyRank?, String>(
  (ref, period) => ref.watch(leaderboardApiProvider).myRank(period: period),
);
