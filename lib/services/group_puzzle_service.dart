import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../data/repositories/crossword_repository.dart';
import '../data/repositories/hunt_repository.dart';
import '../data/repositories/study_repository.dart';
import '../data/user/user_database.dart';
import '../domain/crossword/crossword_models.dart';
import '../domain/games/scoring.dart';
import '../domain/groups/group_models.dart';
import '../domain/hunt/hunt_models.dart';
import 'groups_api.dart';

/// Where today's group puzzle lives on this device: which screen plays it
/// and the local row id that screen opens.
typedef LocalGroupPuzzle = ({GroupPuzzleKind kind, CrosswordDifficulty size, int localId});

/// The moving parts of a group puzzle on this device: getting today's
/// puzzle (downloading the published one, or generating and publishing it
/// when nobody has yet), keeping the leaderboard told, and sending up the
/// words this person agreed to share.
///
/// What gets built is the group's choice, made when it was created: a
/// crossword at one size, or a Word Hunt board.
class GroupPuzzleService {
  final GroupsApi _api;
  final CrosswordRepository _crosswords;
  final HuntRepository _hunts;
  final StudyRepository _study;
  final UserDatabase _db;

  GroupPuzzleService(this._api, this._crosswords, this._hunts, this._study, this._db);

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

  /// Today's group puzzle on this device, fetching, or building and
  /// publishing it, as needed. Throws [GroupsException] with something the
  /// person can read.
  ///
  /// Only one member builds the day's puzzle: whoever gets the claim
  /// generates it, has the AI editor go over a crossword's clues, and
  /// publishes it; anyone who opens it meanwhile waits for that one
  /// rather than building (and paying for) another. There's exactly one
  /// puzzle per group per day — no regenerating. [onStatus] hears what's
  /// happening, for the button to show.
  Future<LocalGroupPuzzle> openToday(
    Group group, {
    void Function(String status)? onStatus,
    Duration pollEvery = const Duration(seconds: 4),
    Duration waitAtMost = const Duration(minutes: 6),
  }) async {
    final date = today();
    final kind = group.puzzleKind;
    final link =
        await (_db.select(_db.groupPuzzleLinks)..where(
              (t) =>
                  t.groupId.equals(group.id) &
                  t.puzzleDate.equals(date) &
                  t.kind.equals(kind.storageKey) &
                  t.remoteId.like('$_pending%').not(),
            ))
            .getSingleOrNull();
    if (link != null) {
      if (await _localExists(kind, link.localPuzzleId)) {
        return (kind: kind, size: group.crosswordSize, localId: link.localPuzzleId);
      }
      await (_db.delete(_db.groupPuzzleLinks)..where((t) => t.remoteId.equals(link.remoteId))).go();
    }

    var remote = await _api.puzzle(group.id, date: date, kind: kind.storageKey);
    final waited = Stopwatch()..start();
    while (remote == null) {
      final claim = await _api.claimBuild(group.id, date: date, kind: kind.storageKey);
      switch (claim.status) {
        case GroupBuildStatus.claimed:
          final built = await _build(group, date, onStatus);
          if (built != null) return built;
          // Someone else's puzzle won the race after all; play theirs.
          remote = await _api.puzzle(group.id, date: date, kind: kind.storageKey);
        case GroupBuildStatus.published:
          remote = await _api.puzzle(group.id, date: date, kind: kind.storageKey);
        case GroupBuildStatus.building:
          if (waited.elapsed > waitAtMost) {
            throw GroupsException(
              '${claim.by ?? 'Someone'} is still building today\'s puzzle. Try again in a minute.',
            );
          }
          onStatus?.call('${claim.by ?? 'Someone'} is building today\'s puzzle…');
          await Future<void>.delayed(pollEvery);
          remote = await _api.puzzle(group.id, date: date, kind: kind.storageKey);
      }
    }
    return _importRemote(group, remote, date);
  }

  /// Link rows for a puzzle this device built but lost the publishing race
  /// with (or is still building): they keep the local copy out of the
  /// personal games and are never uploaded.
  static const _pending = 'pending-';

  Future<LocalGroupPuzzle> _importRemote(Group group, GroupPuzzle remote, String date) async {
    final kind = group.puzzleKind;
    final size =
        CrosswordDifficulty.values.where((d) => d.storageKey == remote.difficulty).firstOrNull ??
        group.crosswordSize;
    final localId = switch (kind) {
      GroupPuzzleKind.crossword => await _crosswords.importPuzzle(
        size,
        date,
        CrosswordPuzzle.fromJson(remote.grid),
      ),
      GroupPuzzleKind.hunt => await _hunts.importPuzzle(date, HuntPuzzle.fromJson(remote.grid)),
    };
    await _link(group.id, date, kind, remoteId: remote.id, localId: localId);
    return (kind: kind, size: size, localId: localId);
  }

  Future<void> _link(
    String groupId,
    String date,
    GroupPuzzleKind kind, {
    required String remoteId,
    required int localId,
  }) => _db
      .into(_db.groupPuzzleLinks)
      .insertOnConflictUpdate(
        GroupPuzzleLinksCompanion.insert(
          remoteId: remoteId,
          groupId: groupId,
          puzzleDate: date,
          kind: Value(kind.storageKey),
          localPuzzleId: localId,
        ),
      );

  Future<bool> _localExists(GroupPuzzleKind kind, int localId) async => switch (kind) {
    GroupPuzzleKind.crossword => await _crosswords.playState(localId) != null,
    GroupPuzzleKind.hunt => await _hunts.playState(localId) != null,
  };

  /// Builds today's puzzle from the pool, has the editor review a
  /// crossword, and publishes it. Returns the local copy — or null when
  /// another member's puzzle was published first, in which case that one
  /// is the group's and the caller fetches it.
  Future<LocalGroupPuzzle?> _build(
    Group group,
    String date,
    void Function(String status)? onStatus,
  ) async {
    final pool = await _api.pool(group.id);
    if (pool.isEmpty) {
      throw const GroupsException(
        'The group has no shared words yet. Switch on "Share my words" — or ask the others to.',
      );
    }
    final words = [for (final w in pool) (headword: w.headword, gloss: w.gloss)];
    final seed = seedFor(group.id, date);
    const failed = GroupsException(
      'Couldn\'t build a puzzle from the group\'s words just now. Try again in a moment.',
    );
    onStatus?.call('Building from the group\'s ${pool.length} words…');

    switch (group.puzzleKind) {
      case GroupPuzzleKind.crossword:
        final size = group.crosswordSize;
        final generated = await _crosswords.generateFromPool(size, words, date: date, seed: seed);
        if (generated == null) throw failed;
        // Stored and linked (as pending) before the review, so the copy
        // being edited never shows up as this person's own puzzle.
        final localId = await _crosswords.importPuzzle(size, date, generated);
        final pendingId = '$_pending$localId';
        await _link(group.id, date, GroupPuzzleKind.crossword, remoteId: pendingId, localId: localId);

        onStatus?.call('The AI editor is checking the clues…');
        final report = await _crosswords.reviewInBackground(
          localId,
          size,
          date,
          generated,
          groupKey: 'group-${group.id}-$date',
        );
        debugPrint('group crossword review: ${report.status}');
        final edited = (await _crosswords.loadPuzzle(localId))?.puzzle ?? generated;

        final remote = await _api.publishPuzzle(
          groupId: group.id,
          date: date,
          kind: GroupPuzzleKind.crossword.storageKey,
          difficulty: size.storageKey,
          seed: edited.seed,
          grid: edited.toJson(),
          anchors: edited.anchors,
        );
        if (jsonEncode(remote.grid) != jsonEncode(edited.toJson())) return null;
        await (_db.delete(_db.groupPuzzleLinks)..where((t) => t.remoteId.equals(pendingId))).go();
        await _link(group.id, date, GroupPuzzleKind.crossword, remoteId: remote.id, localId: localId);
        return (kind: GroupPuzzleKind.crossword, size: size, localId: localId);

      case GroupPuzzleKind.hunt:
        final puzzle = (await _hunts.generateFromPool(words, date: date, seed: seed)).puzzle;
        if (puzzle == null) throw failed;
        final remote = await _api.publishPuzzle(
          groupId: group.id,
          date: date,
          kind: GroupPuzzleKind.hunt.storageKey,
          difficulty: group.puzzleDifficulty,
          seed: puzzle.seed,
          grid: puzzle.toJson(),
          anchors: [for (final a in puzzle.anchors) a.display],
        );
        return _importRemote(group, remote, date);
    }
  }

  /// Today's puzzle on the server, if it exists, without generating.
  Future<GroupPuzzle?> todayPuzzle(Group group) =>
      _api.puzzle(group.id, date: today(), kind: group.puzzleKind.storageKey);

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
      if (link.remoteId.startsWith(_pending)) continue;
      final score = await _scoreFor(link, userId);
      if (score == null) continue;
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

  /// One linked puzzle's play as the group sees it, with its points worked
  /// out by the same rules as the global board.
  Future<GroupScore?> _scoreFor(GroupPuzzleLinkRow link, String userId) async {
    switch (GroupPuzzleKind.fromStorageKey(link.kind)) {
      case GroupPuzzleKind.crossword:
        final state = await _crosswords.playState(link.localPuzzleId);
        if (state == null) return null;
        final row = await (_db.select(
          _db.crosswordPuzzles,
        )..where((t) => t.id.equals(link.localPuzzleId))).getSingleOrNull();
        final size =
            CrosswordDifficulty.values.where((d) => d.storageKey == row?.difficulty).firstOrNull ??
            CrosswordDifficulty.midi;
        return GroupScore(
          puzzleId: link.remoteId,
          userId: userId,
          solvedWords: state.solvedWords,
          totalWords: state.totalWords,
          completed: state.completed,
          activeMs: state.activeMs ?? 0,
          aided: state.aided,
          points: crosswordScore(
            difficulty: size,
            solvedWords: state.solvedWords,
            completed: state.completed,
            aided: state.aided,
            activeMs: state.activeMs ?? 0,
          ),
          updatedAt: DateTime.now(),
        );
      case GroupPuzzleKind.hunt:
        final state = await _hunts.playState(link.localPuzzleId);
        if (state == null) return null;
        return GroupScore(
          puzzleId: link.remoteId,
          userId: userId,
          solvedWords: state.foundRequired,
          totalWords: state.requiredTotal,
          completed: state.completed,
          activeMs: state.activeMs ?? 0,
          aided: state.aided,
          points: huntLeaderboardScore(boardScore: state.score, completed: state.completed),
          updatedAt: DateTime.now(),
        );
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
