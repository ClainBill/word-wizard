import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../data/repositories/crossword_repository.dart';
import '../data/repositories/study_repository.dart';
import '../data/user/user_database.dart';
import '../domain/crossword/crossword_models.dart';
import '../domain/groups/group_models.dart';
import 'groups_api.dart';

/// The moving parts of a group puzzle on this device: getting today's
/// grid (downloading the published one, or generating and publishing it
/// when nobody has yet), keeping the leaderboard told, and sending up
/// the words this person agreed to share.
class GroupPuzzleService {
  final GroupsApi _api;
  final CrosswordRepository _crosswords;
  final StudyRepository _study;
  final UserDatabase _db;

  GroupPuzzleService(this._api, this._crosswords, this._study, this._db);

  /// The one size groups play at, for now.
  static const CrosswordDifficulty difficulty = CrosswordDifficulty.midi;

  /// The same local date the personal puzzles key on.
  static String today() => CrosswordRepository.today();

  /// FNV-1a, so every member derives the same seed from the same group
  /// and date — `String.hashCode` isn't promised to be stable.
  @visibleForTesting
  static int seedFor(String groupId, String date) {
    var hash = 0x811c9dc5;
    for (final unit in '$groupId|$date'.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0x7fffffff;
    }
    return hash;
  }

  /// The local `crossword_puzzles` id of today's group puzzle, fetching,
  /// or generating and publishing it, as needed. Throws [GroupsException]
  /// with something the person can read.
  Future<int> openToday(String groupId) async {
    final date = today();
    final link = await (_db.select(
      _db.groupPuzzleLinks,
    )..where((t) => t.groupId.equals(groupId) & t.puzzleDate.equals(date))).getSingleOrNull();
    if (link != null) {
      if (await _crosswords.playState(link.localPuzzleId) != null) return link.localPuzzleId;
      await (_db.delete(_db.groupPuzzleLinks)..where((t) => t.remoteId.equals(link.remoteId))).go();
    }

    var remote = await _api.puzzle(groupId, date: date);
    if (remote == null) {
      final pool = await _api.pool(groupId);
      if (pool.isEmpty) {
        throw const GroupsException(
          'The group has no shared words yet. Switch on "Share my words" — or ask the others to.',
        );
      }
      final puzzle = await _crosswords.generateFromPool(
        difficulty,
        [for (final w in pool) (headword: w.headword, gloss: w.gloss)],
        date: date,
        seed: seedFor(groupId, date),
      );
      if (puzzle == null) {
        throw const GroupsException(
          'Couldn\'t build a grid from the group\'s words just now. Try again in a moment.',
        );
      }
      remote = await _api.publishPuzzle(
        groupId: groupId,
        date: date,
        kind: 'crossword',
        difficulty: difficulty.storageKey,
        seed: puzzle.seed,
        grid: puzzle.toJson(),
        anchors: puzzle.anchors,
      );
    }

    final grid = CrosswordPuzzle.fromJson(remote.grid);
    final size =
        CrosswordDifficulty.values.where((d) => d.storageKey == remote!.difficulty).firstOrNull ??
        difficulty;
    final localId = await _crosswords.importPuzzle(size, date, grid);
    await _db
        .into(_db.groupPuzzleLinks)
        .insertOnConflictUpdate(
          GroupPuzzleLinksCompanion.insert(
            remoteId: remote.id,
            groupId: groupId,
            puzzleDate: date,
            localPuzzleId: localId,
          ),
        );
    return localId;
  }

  /// Today's puzzle on the server, if it exists, without generating.
  Future<GroupPuzzle?> todayPuzzle(String groupId) => _api.puzzle(groupId, date: today());

  /// Uploads this person's progress on the group's recent puzzles when it
  /// has changed. Quiet on failure: the leaderboard catches up next time.
  Future<void> syncScores(String groupId, {required String userId}) async {
    final links =
        await (_db.select(_db.groupPuzzleLinks)
              ..where((t) => t.groupId.equals(groupId))
              ..orderBy([(t) => OrderingTerm.desc(t.puzzleDate)])
              ..limit(7))
            .get();
    for (final link in links) {
      final state = await _crosswords.playState(link.localPuzzleId);
      if (state == null) continue;
      final score = GroupScore(
        puzzleId: link.remoteId,
        userId: userId,
        solvedWords: state.solvedWords,
        totalWords: state.totalWords,
        completed: state.completed,
        activeMs: state.activeMs ?? 0,
        aided: state.aided,
        updatedAt: DateTime.now(),
      );
      if (score.stamp == link.lastUploaded) continue;
      if (score.solvedWords == 0 && !score.completed) continue;
      try {
        await _api.submitScore(score);
        await (_db.update(_db.groupPuzzleLinks)..where((t) => t.remoteId.equals(link.remoteId)))
            .write(GroupPuzzleLinksCompanion(lastUploaded: Value(score.stamp)));
      } catch (e) {
        debugPrint('group score upload: $e');
      }
    }
  }

  /// Sends up the headwords this person is studying (with the card's
  /// gloss for the clue), replacing what was there. Returns how many.
  Future<int> syncMyWords(String groupId, {required String userId}) async {
    final cards = await _study.allStudyingCards(limit: 500);
    final seen = <String>{};
    final words = <GroupWord>[
      for (final card in cards)
        if (seen.add(card.headword.toLowerCase()))
          GroupWord(headword: card.headword, gloss: card.gloss, userId: userId),
    ];
    await _api.replaceMyWords(groupId, userId: userId, words: words);
    return words.length;
  }
}
