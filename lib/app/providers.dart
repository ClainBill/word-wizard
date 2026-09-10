import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../data/app_databases.dart';
import '../data/repositories/crossword_repository.dart';
import '../data/repositories/list_repository.dart';
import '../data/repositories/notes_repository.dart';
import '../data/repositories/search_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../data/repositories/study_repository.dart';
import '../domain/crossword/crossword_models.dart';
import '../domain/models/study_dashboard.dart';
import '../services/notification_service.dart';

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

final notesRepositoryProvider = Provider<NotesRepository>(
  (ref) => NotesRepository(ref.watch(appDatabasesProvider).user),
);

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepository(ref.watch(appDatabasesProvider).user),
);

final remindersEnabledProvider = StreamProvider<bool>(
  (ref) => ref.watch(settingsRepositoryProvider).watchRemindersEnabled(),
);

final notificationServiceProvider = Provider<NotificationService>(
  (ref) => NotificationService.instance,
);

final dueCountProvider = StreamProvider<int>(
  (ref) => ref.watch(studyRepositoryProvider).watchDueCount(),
);

final studyStatsProvider = StreamProvider<StudyDashboardStats>(
  (ref) => ref.watch(studyRepositoryProvider).watchStats(),
);

final studyForecastProvider = StreamProvider<List<int>>(
  (ref) => ref.watch(studyRepositoryProvider).watchForecast(),
);

final studyStreakProvider = StreamProvider<int>(
  (ref) => ref.watch(studyRepositoryProvider).watchStreak(),
);

final ttsProvider = Provider<FlutterTts>((ref) {
  final tts = FlutterTts();
  tts.setLanguage('en-US');
  ref.onDispose(tts.stop);
  return tts;
});

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
/// first, with the editorial runs against it — backs the history list.
final crosswordHistoryProvider = FutureProvider.family<List<CrosswordHistoryEntry>, CrosswordDifficulty>(
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
