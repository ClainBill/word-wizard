import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/app/providers.dart';
import 'package:word_wizard/domain/games/scoring.dart';
import 'package:word_wizard/features/leaderboard/leaderboard_screen.dart';
import 'package:word_wizard/services/auth_service.dart';
import 'package:word_wizard/services/leaderboard_api.dart';
import 'package:word_wizard/services/score_sync.dart';
import 'package:word_wizard/data/repositories/score_repository.dart';
import 'package:word_wizard/data/user/user_database.dart';
import 'package:drift/native.dart';

class _Auth extends NoAuthService {
  final AuthUser? user;
  const _Auth(this.user);
  @override
  AuthUser? get currentUser => user;
  @override
  Stream<AuthUser?> get changes => Stream.value(user);
}

class FakeApi extends NoLeaderboardApi {
  LeaderboardProfile profileValue = const LeaderboardProfile();
  final submitted = <PuzzlePlay>[];
  @override
  bool get available => true;
  @override
  Future<LeaderboardProfile> profile() async => profileValue;
  @override
  Future<void> setProfile({required String? publicName, required bool optIn}) async =>
      profileValue = LeaderboardProfile(publicName: publicName, optIn: optIn);
  @override
  Future<void> submit(List<PuzzlePlay> plays, {required String userId}) async => submitted.addAll(plays);
  @override
  Future<List<LeaderboardEntry>> top({required String period, int limit = 50}) async => [
        const LeaderboardEntry(rank: 1, name: 'Ada', score: 900, puzzles: 9, isMe: false),
        const LeaderboardEntry(rank: 2, name: 'Will', score: 420, puzzles: 5, isMe: true),
      ];
  @override
  Future<MyRank?> myRank({required String period}) async =>
      profileValue.visible ? const MyRank(rank: 2, score: 420, puzzles: 5, players: 31) : null;
}

Future<void> pump(WidgetTester tester, {required FakeApi api, AuthUser? user}) async {
  final db = UserDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        leaderboardApiProvider.overrideWithValue(api),
        authServiceProvider.overrideWithValue(_Auth(user)),
        scoreSyncProvider.overrideWithValue(ScoreSync(ScoreRepository(db), api)),
      ],
      child: const MaterialApp(home: LeaderboardScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  const me = AuthUser(id: 'me', email: 'me@example.com');

  testWidgets('signed out: the board shows, and joining it means signing in', (tester) async {
    await pump(tester, api: FakeApi());
    expect(find.text('Ada'), findsOneWidget);
    expect(find.textContaining('Sign in to put your'), findsOneWidget);
    expect(find.text('Sign in to join'), findsOneWidget);
    expect(find.text('Join the board'), findsNothing);
    expect(find.textContaining('#2'), findsNothing);
  });

  testWidgets('not opted in: the board shows, with the invitation and no own rank', (tester) async {
    await pump(tester, api: FakeApi(), user: me);
    expect(find.text('Ada'), findsOneWidget);
    expect(find.text('Will (you)'), findsOneWidget);
    expect(find.textContaining('not on the board'), findsOneWidget);
    expect(find.text('Join the board'), findsOneWidget);
    expect(find.textContaining('on the board', skipOffstage: false).evaluate().length, greaterThan(0));
  });

  testWidgets('opting in sets the name and shows your standing', (tester) async {
    final api = FakeApi();
    await pump(tester, api: api, user: me);
    await tester.tap(find.text('Join the board'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Public name'), 'Will');
    await tester.tap(find.text('Show me on the leaderboard'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(api.profileValue.visible, isTrue);
    expect(find.text('You\'re on the board as "Will".'), findsOneWidget);
    expect(find.textContaining('#2'), findsOneWidget);
    expect(find.textContaining('31 on the board'), findsOneWidget);
    expect(find.text('Your name'), findsOneWidget);
  });
}
