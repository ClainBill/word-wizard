import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/data/dictionary/dictionary_database.dart';
import 'package:word_wizard/data/repositories/crossword_repository.dart';
import 'package:word_wizard/data/repositories/hunt_repository.dart';
import 'package:word_wizard/data/repositories/search_repository.dart';
import 'package:word_wizard/data/repositories/settings_repository.dart';
import 'package:word_wizard/data/repositories/study_repository.dart';
import 'package:word_wizard/data/user/user_database.dart';
import 'package:word_wizard/domain/crossword/crossword_models.dart';
import 'package:word_wizard/domain/crossword/editorial.dart';
import 'package:word_wizard/domain/games/scoring.dart';
import 'package:word_wizard/domain/groups/group_models.dart';
import 'package:word_wizard/services/crossword_review_service.dart';
import 'package:word_wizard/services/group_puzzle_service.dart';
import 'package:word_wizard/services/groups_api.dart';

/// The server, as far as the service can tell: one pool, first writer
/// wins, scores kept per puzzle.
class _FakeServer extends NoGroupsApi {
  final List<GroupWord> words;
  final published = <String, GroupPuzzle>{};
  final submitted = <GroupScore>[];
  int poolReads = 0;

  /// When set, another member holds the build claim and publishes this
  /// grid after [buildingPolls] polls.
  Map<String, dynamic>? othersGrid;
  int buildingPolls = 2;

  /// When set, another member's grid lands just as this device publishes.
  Map<String, dynamic>? racingGrid;
  _FakeServer(this.words);

  GroupPuzzle _row(
    String groupId,
    String date,
    String kind,
    String difficulty,
    Map<String, dynamic> grid,
  ) => GroupPuzzle(
    id: 'remote-$groupId-$kind',
    groupId: groupId,
    date: date,
    kind: kind,
    difficulty: difficulty,
    seed: 1,
    grid: grid,
    anchors: const [],
  );

  @override
  Future<GroupBuildClaim> claimBuild(
    String groupId, {
    required String date,
    required String kind,
  }) async {
    if (published.containsKey('$groupId|$date|$kind')) {
      return const GroupBuildClaim(GroupBuildStatus.published);
    }
    if (othersGrid != null) {
      if (buildingPolls-- <= 0) {
        published['$groupId|$date|$kind'] = _row(
          groupId,
          date,
          kind,
          'mini',
          othersGrid!,
        );
        return const GroupBuildClaim(GroupBuildStatus.published);
      }
      return const GroupBuildClaim(GroupBuildStatus.building, by: 'Priya');
    }
    return const GroupBuildClaim(GroupBuildStatus.claimed);
  }

  @override
  bool get available => true;
  @override
  Future<List<GroupWord>> pool(String groupId) async {
    poolReads++;
    return words;
  }

  @override
  Future<GroupPuzzle?> puzzle(
    String groupId, {
    required String date,
    String kind = 'crossword',
  }) async => published['$groupId|$date|$kind'];
  @override
  Future<GroupPuzzle> publishPuzzle({
    required String groupId,
    required String date,
    required String kind,
    required String difficulty,
    required int seed,
    required Map<String, dynamic> grid,
    required List<String> anchors,
  }) async {
    if (racingGrid != null) {
      published.putIfAbsent(
        '$groupId|$date|$kind',
        () => _row(groupId, date, kind, difficulty, racingGrid!),
      );
    }
    return published.putIfAbsent(
      '$groupId|$date|$kind',
      () => GroupPuzzle(
        id: 'remote-$groupId-$kind',
        groupId: groupId,
        date: date,
        kind: kind,
        difficulty: difficulty,
        seed: seed,
        grid: grid,
        anchors: anchors,
      ),
    );
  }

  @override
  Future<void> submitScore(GroupScore score) async => submitted.add(score);
}

/// The AI editor, as far as the repository can tell: always configured,
/// never edits, and remembers what it was asked.
class _FakeEditor extends CrosswordReviewService {
  final calls =
      <({String? key, CrosswordDifficulty? difficulty, bool group})>[];
  _FakeEditor();

  @override
  bool get isConfigured => true;

  @override
  Future<CrosswordReviewResult> review(
    CrosswordPuzzle puzzle, {
    required int weekday,
    String? puzzleKey,
    CrosswordDifficulty? difficulty,
    bool group = false,
  }) async {
    calls.add((key: puzzleKey, difficulty: difficulty, group: group));
    return (
      verdict: const EditorialVerdict(),
      model: 'fake',
      promptTokens: 1,
      completionTokens: 1,
      reasoningTokens: 0,
      latencyMs: 1,
      error: '',
    );
  }
}

Group _group(
  String id,
  GroupPuzzleKind kind, {
  CrosswordDifficulty size = CrosswordDifficulty.midi,
}) => Group(
  id: id,
  name: id,
  ownerId: 'o',
  inviteCode: 'ABCDEFGH',
  createdAt: DateTime(2026),
  puzzleKind: kind,
  crosswordSize: size,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late UserDatabase user;
  late DictionaryDatabase dict;
  late CrosswordRepository crosswords;
  late HuntRepository hunts;
  late _FakeServer server;
  late _FakeEditor editor;
  late GroupPuzzleService service;

  setUp(() async {
    user = UserDatabase(NativeDatabase.memory());
    dict = DictionaryDatabase(NativeDatabase.memory());
    // The study queries join an attached dictionary; the personal puzzles
    // read them (an empty study pool here).
    await user.customStatement("ATTACH DATABASE ':memory:' AS dict");
    for (final ddl in const [
      'CREATE TABLE entries (id INTEGER PRIMARY KEY, headword TEXT NOT NULL, pos TEXT NOT NULL, '
          'frequency_rank INTEGER, etymology TEXT)',
      'CREATE TABLE senses (id INTEGER PRIMARY KEY, entry_id INTEGER NOT NULL, gloss TEXT NOT NULL, '
          'sense_order INTEGER NOT NULL)',
      'CREATE TABLE examples (id INTEGER PRIMARY KEY, sense_id INTEGER NOT NULL, text TEXT NOT NULL, '
          'source TEXT)',
      'CREATE TABLE pronunciations (entry_id INTEGER PRIMARY KEY, ipa TEXT, audio_hint TEXT)',
      'CREATE TABLE forms (id INTEGER PRIMARY KEY, entry_id INTEGER NOT NULL, form_text TEXT NOT NULL, '
          'form_type TEXT NOT NULL)',
      'CREATE TABLE spelling_variants (variant TEXT NOT NULL, headword TEXT NOT NULL, label TEXT NOT NULL, '
          'PRIMARY KEY (variant, headword))',
    ]) {
      await dict.customStatement(ddl);
      await user.customStatement(
        ddl.replaceFirst('CREATE TABLE ', 'CREATE TABLE dict.'),
      );
    }
    final study = StudyRepository(user);
    editor = _FakeEditor();
    crosswords = CrosswordRepository(
      user,
      study,
      SearchRepository(dict),
      SettingsRepository(user),
      reviewService: editor,
    );
    hunts = HuntRepository(user, study);
    server = _FakeServer(const [
      GroupWord(headword: 'melody', gloss: 'a tune', userId: 'a'),
      GroupWord(headword: 'cadence', gloss: 'a rhythmic flow', userId: 'b'),
      GroupWord(
        headword: 'glint',
        gloss: 'a brief flash of light',
        userId: 'a',
      ),
      GroupWord(
        headword: 'muse',
        gloss: 'a source of inspiration',
        userId: 'b',
      ),
    ]);
    service = GroupPuzzleService(server, crosswords, hunts, study, user);
  });

  tearDown(() async {
    await user.close();
    await dict.close();
  });

  test(
    'a Mini group builds, publishes and plays a Mini — without taking over my own Mini',
    () async {
      final group = _group(
        'g-mini',
        GroupPuzzleKind.crossword,
        size: CrosswordDifficulty.mini,
      );
      final local = await service.openToday(group);
      expect(local.kind, GroupPuzzleKind.crossword);
      expect(local.size, CrosswordDifficulty.mini);

      final remote = server.published.values.single;
      expect((remote.kind, remote.difficulty), ('crossword', 'mini'));

      // Opening again reuses the downloaded copy.
      expect((await service.openToday(group)).localId, local.localId);

      // My own daily Mini is still mine to generate, and the group's copy
      // doesn't count against today's allowance.
      expect(await crosswords.puzzlesToday(CrosswordDifficulty.mini), 0);
      final mine = await crosswords.loadOrGenerate(CrosswordDifficulty.mini);
      expect(mine, isNotNull);
      expect(mine!.id, isNot(local.localId));
      expect(await crosswords.puzzlesToday(CrosswordDifficulty.mini), 1);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'the builder has the AI editor review a group crossword before publishing it',
    () async {
      final group = _group(
        'g-ed',
        GroupPuzzleKind.crossword,
        size: CrosswordDifficulty.mini,
      );
      final statuses = <String>[];
      await service.openToday(group, onStatus: statuses.add);

      // One review, on the group's allowance, keyed by group and day.
      expect(editor.calls, hasLength(1));
      expect(editor.calls.single.group, isTrue);
      expect(
        editor.calls.single.key,
        'group-g-ed-${GroupPuzzleService.today()}',
      );
      expect(editor.calls.single.difficulty, CrosswordDifficulty.mini);
      expect(statuses.last, contains('AI editor'));

      // What everyone plays is the reviewed grid.
      final grid = CrosswordPuzzle.fromJson(
        server.published.values.single.grid,
      );
      expect(grid.reviewed, isTrue);

      // Opening it again spends nothing more.
      await service.openToday(group);
      expect(editor.calls, hasLength(1));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'while someone else builds, others wait for theirs instead of building',
    () async {
      final theirs = (await crosswords.generateFromPool(
        CrosswordDifficulty.mini,
        [(headword: 'glint', gloss: 'a brief flash')],
        date: GroupPuzzleService.today(),
        seed: 7,
      ))!;
      server.othersGrid = theirs.toJson();
      final statuses = <String>[];
      final local = await service.openToday(
        _group(
          'g-wait',
          GroupPuzzleKind.crossword,
          size: CrosswordDifficulty.mini,
        ),
        onStatus: statuses.add,
        pollEvery: Duration.zero,
      );
      expect(statuses, contains('Priya is building today\'s puzzle…'));
      expect(server.poolReads, 0, reason: 'a waiting member never generates');
      expect(editor.calls, isEmpty, reason: 'nor pays for an edit');
      final session = (await crosswords.loadPuzzle(local.localId))!;
      expect(session.puzzle.seed, theirs.seed);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'losing the publishing race plays the winner\'s grid and hides the loser',
    () async {
      final theirs = (await crosswords.generateFromPool(
        CrosswordDifficulty.mini,
        [(headword: 'glint', gloss: 'a brief flash')],
        date: GroupPuzzleService.today(),
        seed: 99,
      ))!;
      server.racingGrid = theirs.toJson();
      final local = await service.openToday(
        _group(
          'g-race',
          GroupPuzzleKind.crossword,
          size: CrosswordDifficulty.mini,
        ),
      );
      expect((await crosswords.loadPuzzle(local.localId))!.puzzle.seed, 99);
      // Neither the winner's copy nor this device's discarded build is "my Mini".
      expect(await crosswords.puzzlesToday(CrosswordDifficulty.mini), 0);
      // And the discarded build is never uploaded as a score.
      await service.syncScores('g-race', userId: 'me');
      expect(
        server.submitted.where((s) => s.puzzleId.startsWith('pending-')),
        isEmpty,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a Word Hunt group builds its board from the pool and scores it with points',
    () async {
      final group = _group('g-hunt', GroupPuzzleKind.hunt);
      final local = await service.openToday(group);
      expect(local.kind, GroupPuzzleKind.hunt);

      final remote = server.published.values.single;
      expect((remote.kind, remote.difficulty), ('hunt', 'daily'));
      expect(remote.anchors, isNotEmpty);
      expect(
        remote.anchors.every(
          (a) => ['melody', 'cadence', 'glint', 'muse'].contains(a),
        ),
        isTrue,
      );

      // Not "today's board" for my own Word Hunt, and not counted.
      expect(await hunts.boardsToday(), 0);

      // Find one required word and finish nothing: the upload carries it.
      final session = (await hunts.loadPuzzle(local.localId))!;
      final word = session.puzzle.main.keys.first;
      await hunts.saveProgress(
        local.localId,
        found: {word},
        revealed: const {},
        hinted: false,
        completed: false,
      );
      await service.syncScores(group.id, userId: 'me');
      final score = server.submitted.single;
      expect(score.puzzleId, remote.id);
      expect(score.solvedWords, 1);
      expect(
        score.points,
        huntLeaderboardScore(boardScore: word.length, completed: false),
      );

      // Unchanged progress isn't sent twice.
      await service.syncScores(group.id, userId: 'me');
      expect(server.submitted, hasLength(1));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'two personal puzzles a day per kind, then no more',
    () async {
      await crosswords.loadOrGenerate(CrosswordDifficulty.mini);
      expect(await crosswords.canStartNew(CrosswordDifficulty.mini), isTrue);
      await crosswords.regenerate(CrosswordDifficulty.mini);
      expect(await crosswords.canStartNew(CrosswordDifficulty.mini), isFalse);
      await expectLater(
        crosswords.regenerate(CrosswordDifficulty.mini),
        throwsA(isA<Exception>()),
      );
      // Each size has its own allowance.
      expect(await crosswords.canStartNew(CrosswordDifficulty.midi), isTrue);

      await hunts.loadOrGenerate();
      await hunts.regenerate();
      expect(await hunts.canStartNew(), isFalse);
      await expectLater(hunts.regenerate(), throwsA(isA<Exception>()));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
