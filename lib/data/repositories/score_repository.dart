import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/crossword/crossword_models.dart';
import '../../domain/games/scoring.dart';
import '../../domain/hunt/hunt_models.dart';
import '../user/user_database.dart';
import 'hunt_repository.dart' show huntScore;

/// Reads recent plays off the local puzzle tables and scores them, for
/// the leaderboard upload. Every play is scored from its stored state, so
/// a re-upload after more progress simply raises the row.
class ScoreRepository {
  final UserDatabase _db;

  ScoreRepository(this._db);

  /// Plays from the last [days] days (by puzzle date), scored. Group
  /// puzzles are included — they're crosswords played like any other.
  Future<List<PuzzlePlay>> recentPlays({int days = 14}) async {
    final since = DateTime.now().subtract(Duration(days: days));
    final sinceKey =
        '${since.year}-${since.month.toString().padLeft(2, '0')}-'
        '${since.day.toString().padLeft(2, '0')}';
    final plays = <PuzzlePlay>[];

    final results = {
      for (final r in await _db.select(_db.gameResults).get()) '${r.game}/${r.refId}': r,
    };

    final crosswords = await (_db.select(
      _db.crosswordPuzzles,
    )..where((t) => t.puzzleDate.isBiggerOrEqualValue(sinceKey))).get();
    for (final row in crosswords) {
      try {
        final puzzle = CrosswordPuzzle.fromJson(jsonDecode(row.gridJson) as Map<String, dynamic>);
        final filled = Map<String, String>.from(jsonDecode(row.progressJson) as Map);
        if (filled.isEmpty && !row.completed) continue; // opened, never played
        var solved = 0;
        for (final word in puzzle.words) {
          var complete = true;
          for (var i = 0; i < word.cells.length && complete; i++) {
            complete = filled['${word.cells[i].$1},${word.cells[i].$2}'] == word.answer[i];
          }
          if (complete) solved++;
        }
        if (row.completed) solved = puzzle.words.length;
        final play = results['crossword/${row.id}'];
        final difficulty =
            CrosswordDifficulty.values.where((d) => d.storageKey == row.difficulty).firstOrNull ??
            CrosswordDifficulty.mini;
        final aided = play?.aided ?? false;
        plays.add(
          PuzzlePlay(
            game: 'crossword',
            puzzleKey: '${row.puzzleDate}/${row.id}',
            playedOn: row.puzzleDate,
            difficulty: row.difficulty,
            score: crosswordScore(
              difficulty: difficulty,
              solvedWords: solved,
              completed: row.completed,
              aided: aided,
              activeMs: play?.activeMs ?? 0,
            ),
            completed: row.completed,
            words: solved,
            activeMs: play?.activeMs ?? 0,
            aided: aided,
          ),
        );
      } catch (_) {}
    }

    final hunts = await (_db.select(
      _db.huntPuzzles,
    )..where((t) => t.puzzleDate.isBiggerOrEqualValue(sinceKey))).get();
    for (final row in hunts) {
      try {
        final puzzle = HuntPuzzle.fromJson(jsonDecode(row.puzzleJson) as Map<String, dynamic>);
        final map = jsonDecode(row.progressJson) as Map<String, dynamic>;
        final found = {for (final w in map['found'] as List? ?? const []) w as String};
        if (found.isEmpty) continue;
        final play = results['hunt/${row.id}'];
        plays.add(
          PuzzlePlay(
            game: 'hunt',
            puzzleKey: '${row.puzzleDate}/${row.id}',
            playedOn: row.puzzleDate,
            difficulty: '',
            score: huntLeaderboardScore(
              boardScore: huntScore(puzzle, found),
              completed: row.completed,
            ),
            completed: row.completed,
            words: found.length,
            activeMs: play?.activeMs ?? 0,
            aided: play?.aided ?? false,
          ),
        );
      } catch (_) {}
    }
    return plays;
  }
}
