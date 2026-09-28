import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/domain/crossword/crossword_models.dart';
import 'package:word_wizard/domain/games/scoring.dart';

void main() {
  test('crossword points: per answer by size, bonuses for finishing and pace, nothing when helped', () {
    int s({
      CrosswordDifficulty d = CrosswordDifficulty.mini,
      int words = 10,
      bool done = false,
      bool aided = false,
      int ms = 0,
    }) =>
        crosswordScore(difficulty: d, solvedWords: words, completed: done, aided: aided, activeMs: ms);

    expect(s(words: 4), 40, reason: 'an abandoned mini keeps its answers');
    expect(s(d: CrosswordDifficulty.midi, words: 4), 80);
    expect(s(words: 10, done: true, aided: true), 0, reason: 'a revealed board is helped: no points');
    expect(s(words: 4, aided: true), 0);
    expect(s(words: 10, done: true, ms: 10 * 60000), 100 + 50 + 25 + 20);
    expect(s(words: 10, done: true, ms: 45 * 60000), 100 + 50 + 25, reason: 'no pace bonus past 30 min');
    expect(s(d: CrosswordDifficulty.mega, words: 30, done: true, ms: 20 * 60000), 900 + 150 + 75 + 30);
    expect(s(words: 0), 0);
  });

  test('hunt points: board score ×5 plus a completion bonus', () {
    expect(huntLeaderboardScore(boardScore: 12, completed: false), 60);
    expect(huntLeaderboardScore(boardScore: 12, completed: true), 110);
  });

  test('entries and ranks parse', () {
    final e = LeaderboardEntry.fromJson({'rank': 3, 'user_id': 'u', 'public_name': 'Sam', 'score': 420, 'puzzles': 7, 'is_me': true});
    expect(e.rank, 3);
    expect(e.isMe, isTrue);
    final r = MyRank.fromJson({'rank': 12, 'score': 90, 'puzzles': 2, 'players': 40});
    expect(r.players, 40);
    expect(const LeaderboardProfile(publicName: 'Sam', optIn: true).visible, isTrue);
    expect(const LeaderboardProfile(publicName: 'Sam').visible, isFalse);
    expect(const LeaderboardProfile(optIn: true).visible, isFalse);
  });
}
