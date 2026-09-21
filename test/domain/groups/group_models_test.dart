import 'package:flutter_test/flutter_test.dart';
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
    expect(stamp, '3/10/false/false');
  });
}
