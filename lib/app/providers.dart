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
  ),
);

/// Which difficulty and which day — `date` is a 'YYYY-MM-DD' string, either
/// today's (generates on first read if missing) or a past day from history
/// (never generates; `null` session means no puzzle exists for that day).
typedef CrosswordSessionKey = ({CrosswordDifficulty difficulty, String date});

final crosswordSessionProvider = FutureProvider.family<CrosswordSession?, CrosswordSessionKey>((ref, key) {
  final repo = ref.watch(crosswordRepositoryProvider);
  return key.date == CrosswordRepository.today()
      ? repo.loadOrGenerate(key.difficulty)
      : repo.loadForDate(key.difficulty, key.date);
});

/// Every day a puzzle's been generated for one difficulty, most recent
/// first — backs the history list.
final crosswordHistoryProvider = FutureProvider.family<List<CrosswordHistoryEntry>, CrosswordDifficulty>(
  (ref, difficulty) => ref.watch(crosswordRepositoryProvider).history(difficulty),
);
