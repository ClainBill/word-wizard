import 'package:go_router/go_router.dart';

import '../domain/crossword/crossword_models.dart';
import '../features/entry/entry_detail_screen.dart';
import '../features/games/crossword_history_screen.dart';
import '../features/games/crossword_screen.dart';
import '../features/games/games_screen.dart';
import '../features/lists/list_detail_screen.dart';
import '../features/lists/lists_screen.dart';
import '../features/reader/reader_screen.dart';
import '../features/search/search_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/study/manage_study_screen.dart';
import '../features/study/study_screen.dart';
import '../features/study/study_session_screen.dart';
import 'shell.dart';

final appRouter = GoRouter(
  initialLocation: '/search',
  routes: [
    // Entry Detail is reachable from every tab, so it's pushed on the root
    // navigator rather than nested inside a single shell branch.
    GoRoute(
      path: '/entry/:headword',
      builder: (context, state) => EntryDetailScreen(
        headword: Uri.decodeComponent(state.pathParameters['headword']!),
      ),
    ),
    GoRoute(
      path: '/study/session',
      builder: (context, state) {
        final listId = state.uri.queryParameters['listId'];
        return StudySessionScreen(listId: listId == null ? null : int.parse(listId));
      },
    ),
    GoRoute(
      path: '/study/manage',
      builder: (context, state) => const ManageStudyScreen(),
    ),
    GoRoute(
      path: '/games/crossword/:difficulty',
      builder: (context, state) => CrosswordScreen(
        difficulty: CrosswordDifficulty.fromStorageKey(state.pathParameters['difficulty']!),
        date: state.uri.queryParameters['date'],
      ),
    ),
    GoRoute(
      path: '/games/crossword/:difficulty/history',
      builder: (context, state) => CrosswordHistoryScreen(
        difficulty: CrosswordDifficulty.fromStorageKey(state.pathParameters['difficulty']!),
      ),
    ),
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) => AppShell(navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(routes: [
          GoRoute(path: '/search', builder: (context, state) => const SearchScreen()),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(path: '/reader', builder: (context, state) => const ReaderScreen()),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(
            path: '/lists',
            builder: (context, state) => const ListsScreen(),
            routes: [
              GoRoute(
                path: ':id',
                builder: (context, state) => ListDetailScreen(
                  listId: int.parse(state.pathParameters['id']!),
                  listName: state.extra as String?,
                ),
              ),
            ],
          ),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(path: '/study', builder: (context, state) => const StudyScreen()),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(path: '/games', builder: (context, state) => const GamesScreen()),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(path: '/settings', builder: (context, state) => const SettingsScreen()),
        ]),
      ],
    ),
  ],
);
