import 'package:flutter/widgets.dart' show BuildContext;
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:go_router/go_router.dart';

import '../domain/crossword/crossword_models.dart';
import '../services/feedback_service.dart' show FeedbackKind;
import '../features/entry/entry_detail_screen.dart';
import '../features/games/crossword_banned_answers_screen.dart';
import '../features/games/crossword_history_screen.dart';
import '../features/games/crossword_screen.dart';
import '../features/games/games_screen.dart';
import '../features/games/hunt_history_screen.dart';
import '../features/games/hunt_screen.dart';
import '../features/groups/group_screen.dart';
import '../features/groups/groups_screen.dart';
import '../features/leaderboard/leaderboard_screen.dart';
import '../features/lists/list_detail_screen.dart';
import '../features/premium/legal_screen.dart';
import '../features/premium/paywall_screen.dart';
import '../features/lists/lists_screen.dart';
import '../features/reader/reader_edit_screen.dart';
import '../features/reader/reader_history_screen.dart';
import '../features/reader/reader_screen.dart';
import '../features/search/search_screen.dart';
import '../features/settings/feedback_screen.dart';
import '../features/settings/licences_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/slang/slang_editor_screen.dart';
import '../features/slang/slang_stack_screen.dart';
import '../features/progress/progress_screen.dart';
import '../features/study/manage_study_screen.dart';
import '../features/study/study_screen.dart';
import '../features/study/study_session_screen.dart';
import 'providers.dart' show isPremiumProvider;
import 'shell.dart';

/// Premium games are reachable only with Premium: a free account that
/// lands on one — from a notification, a history link, a stale route —
/// gets the paywall with the game as its destination (spec §3.2).
String? _premiumGate(BuildContext context, GoRouterState state) {
  final location = state.uri.toString();
  if (gameRouteIsFree(location)) return null;
  if (ProviderScope.containerOf(context, listen: false).read(isPremiumProvider)) return null;
  return Uri(path: '/premium', queryParameters: {'source': 'route', 'next': location}).toString();
}

const String _home = String.fromEnvironment('INITIAL_ROUTE', defaultValue: '/search');

final appRouter = GoRouter(
  // `--dart-define=INITIAL_ROUTE=/games/hunt` opens straight onto a screen,
  // for testing on a device without tapping through.
  initialLocation: _home,
  // Nothing outside the app should be able to strand it on an error page.
  // A location the router doesn't know — a deep link that slipped through,
  // the platform's bare "/" on a cold start from a link — goes home.
  onException: (_, state, router) => router.go(_home),
  routes: [
    // Entry Detail is reachable from every tab, so it's pushed on the root
    // navigator rather than nested inside a single shell branch.
    GoRoute(
      path: '/entry/:headword',
      builder: (context, state) => EntryDetailScreen(
        headword: Uri.decodeComponent(state.pathParameters['headword']!),
        // A search result or a tile on the landing board: both are the
        // person choosing a word, which is what a lookup is.
        fromSearch: const {'search', 'board'}.contains(state.uri.queryParameters['from']),
      ),
    ),
    // Adding to or editing the Slang Stack: a full-screen form over
    // whatever opened it — search, a card, the stack itself.
    GoRoute(
      path: '/slang/edit',
      builder: (context, state) => SlangEditorScreen(
        headword: state.uri.queryParameters['headword'],
        fromCard: state.uri.queryParameters['from'] == 'card',
      ),
    ),
    GoRoute(
      path: '/study/session',
      builder: (context, state) {
        final listId = state.uri.queryParameters['listId'];
        return StudySessionScreen(listId: listId == null ? null : int.parse(listId));
      },
    ),
    // Report a bug / suggest a feature. On the root navigator, full
    // screen: it's a form, and the tab bar would only take space from it.
    GoRoute(
      path: '/feedback',
      builder: (context, state) => FeedbackScreen(
        initialKind: state.uri.queryParameters['kind'] == 'feature'
            ? FeedbackKind.feature
            : FeedbackKind.bug,
      ),
    ),
    // The paywall: full screen, on the root navigator, over whatever asked
    // for it. `next` is the game a purchase should open.
    GoRoute(
      path: '/premium',
      builder: (context, state) => PaywallScreen(
        source: state.uri.queryParameters['source'] ?? 'unknown',
        next: state.uri.queryParameters['next'],
      ),
    ),
    GoRoute(path: '/legal/terms', builder: (context, state) => const LegalScreen.terms()),
    GoRoute(path: '/legal/privacy', builder: (context, state) => const LegalScreen.privacy()),
    GoRoute(
      path: '/study/manage',
      builder: (context, state) => const ManageStudyScreen(),
    ),
    GoRoute(
      path: '/study/progress',
      builder: (context, state) => const ProgressScreen(),
    ),
    GoRoute(
      path: '/games/crossword/:difficulty',
      redirect: _premiumGate,
      builder: (context, state) => CrosswordScreen(
        difficulty: CrosswordDifficulty.fromStorageKey(state.pathParameters['difficulty']!),
        // A specific past generation opened from history; absent means the
        // current puzzle for today.
        puzzleId: int.tryParse(state.uri.queryParameters['puzzle'] ?? ''),
      ),
    ),
    // Debug: the crossword's ban list. Not under a difficulty — a ban applies
    // to every size.
    GoRoute(
      path: '/games/crossword-bans',
      builder: (context, state) => const CrosswordBannedAnswersScreen(),
    ),
    GoRoute(
      path: '/games/hunt',
      redirect: _premiumGate,
      builder: (context, state) => HuntScreen(
        puzzleId: int.tryParse(state.uri.queryParameters['puzzle'] ?? ''),
      ),
    ),
    // Group puzzles. Open to free accounts too — joining an invite is the
    // free tier's look at the feature; *playing* goes through the
    // crossword route and its gate.
    GoRoute(path: '/games/leaderboard', builder: (context, state) => const LeaderboardScreen()),
    GoRoute(path: '/games/groups', builder: (context, state) => const GroupsScreen()),
    GoRoute(
      path: '/games/groups/:id',
      builder: (context, state) => GroupScreen(groupId: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/games/hunt/history',
      builder: (context, state) => const HuntHistoryScreen(),
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
          GoRoute(
            path: '/reader',
            builder: (context, state) => const ReaderScreen(),
            routes: [
              GoRoute(
                path: 'history',
                builder: (context, state) => const ReaderHistoryScreen(),
              ),
              // Type or paste text by hand; `doc` edits an existing document's
              // text in place instead of creating a new one.
              GoRoute(
                path: 'edit',
                builder: (context, state) => ReaderEditScreen(
                  documentId: int.tryParse(state.uri.queryParameters['doc'] ?? ''),
                ),
              ),
            ],
          ),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(
            path: '/lists',
            builder: (context, state) => const ListsScreen(),
            routes: [
              // Before ':id', which would otherwise try to parse it.
              GoRoute(path: 'slang', builder: (context, state) => const SlangStackScreen()),
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
          GoRoute(
            path: '/settings',
            builder: (context, state) => const SettingsScreen(),
            routes: [
              GoRoute(
                path: 'licences',
                builder: (context, state) => const LicencesScreen(),
              ),
            ],
          ),
        ]),
      ],
    ),
  ],
);
