import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/domain/crossword/crossword_models.dart';
import 'package:word_wizard/domain/groups/group_models.dart';
import 'package:word_wizard/services/group_puzzle_service.dart';

GroupScore score({int solved = 0, bool completed = false, bool aided = false, int ms = 0}) =>
    GroupScore(
      puzzleId: 'p',
      userId: 'u$solved$completed$aided$ms',
      solvedWords: solved,
      totalWords: 10,
      completed: completed,
      activeMs: ms,
      aided: aided,
      updatedAt: DateTime(2026),
    );

void main() {
  test('leaderboard order: finished, then words, then unaided, then time', () {
    final scores = [
      score(solved: 10, completed: true, ms: 300000),
      score(solved: 10, completed: true, ms: 200000),
      score(solved: 7, aided: true),
      score(solved: 7),
      score(solved: 9),
    ]..sort(compareScores);
    expect(scores.map((s) => '${s.solvedWords}${s.completed ? 'c' : ''}${s.aided ? 'a' : ''}${s.activeMs}').toList(),
        ['10c200000', '10c300000', '90', '70', '7a0']);
  });

  test('invite codes are forgiving', () {
    expect(normalizeInviteCode(' zdgu-tuqu '), 'ZDGUTUQU');
    expect(normalizeInviteCode('ab0l 1234'), 'ABOLI234');
  });

  test('the seed is stable and differs by day and group', () {
    expect(GroupPuzzleService.seedFor('g1', '2026-09-20'), GroupPuzzleService.seedFor('g1', '2026-09-20'));
    expect(GroupPuzzleService.seedFor('g1', '2026-09-20'), isNot(GroupPuzzleService.seedFor('g1', '2026-09-21')));
    expect(GroupPuzzleService.seedFor('g1', '2026-09-20'), isNot(GroupPuzzleService.seedFor('g2', '2026-09-20')));
    expect(GroupPuzzleService.seedFor('g1', '2026-09-20'), greaterThanOrEqualTo(0));
  });

  test('group JSON with a member count', () {
    final g = Group.fromJson({
      'id': 'g',
      'name': 'Book club',
      'owner_id': 'o',
      'invite_code': 'ABCDEFGH',
      'created_at': '2026-09-20T00:00:00Z',
      'group_members': [{'count': 4}],
    });
    expect(g.memberCount, 4);
    expect(g.isOwnedBy('o'), isTrue);
    final stamp = score(solved: 3).stamp;
    expect(stamp, '3/10/false/false/0');
  });

  test('what a group plays comes from its row, defaulting to a Midi crossword', () {
    Group group(Map<String, dynamic> extra) => Group.fromJson({
      'id': 'g',
      'name': 'n',
      'owner_id': 'o',
      'invite_code': 'ABCDEFGH',
      'created_at': '2026-09-20T00:00:00Z',
      ...extra,
    });
    final old = group({});
    expect(old.puzzleKind, GroupPuzzleKind.crossword);
    expect(old.crosswordSize, CrosswordDifficulty.midi);
    expect(old.playsLabel, 'Midi crossword');

    final mini = group({'puzzle_kind': 'crossword', 'crossword_size': 'mini'});
    expect(mini.playsLabel, 'Mini crossword');
    expect(mini.puzzleDifficulty, 'mini');

    final hunt = group({'puzzle_kind': 'hunt', 'crossword_size': 'midi'});
    expect(hunt.puzzleKind, GroupPuzzleKind.hunt);
    expect(hunt.playsLabel, 'Word Hunt');
    expect(hunt.puzzleDifficulty, 'daily');
  });

  test('points travel with a score and change its stamp', () {
    final s = GroupScore(
      puzzleId: 'p',
      userId: 'u',
      solvedWords: 3,
      totalWords: 10,
      completed: false,
      activeMs: 0,
      aided: false,
      points: 60,
      updatedAt: DateTime(2026),
    );
    expect(s.toJson()['points'], 60);
    expect(GroupScore.fromJson({...s.toJson(), 'updated_at': '2026-09-20T00:00:00Z'}).points, 60);
    expect(s.stamp, isNot(score(solved: 3).stamp));
  });

  test('standings rows and periods', () {
    final row = GroupStanding.fromJson({
      'rank': 2,
      'user_id': 'u',
      'display_name': 'Sam',
      'points': 340,
      'puzzles': 3,
      'completed': 2,
      'is_me': true,
    });
    expect((row.rank, row.displayName, row.points, row.puzzles, row.completed, row.isMe),
        (2, 'Sam', 340, 3, 2, true));
    // A Sunday counts from the Monday before it; a Monday from itself.
    expect(GroupStandingsPeriod.week.since(DateTime(2026, 9, 27, 22)), '2026-09-21');
    expect(GroupStandingsPeriod.week.since(DateTime(2026, 9, 21, 1)), '2026-09-21');
    expect(GroupStandingsPeriod.allTime.since(DateTime(2026, 9, 27)), isNull);
  });
}
