/// Group puzzles, v1.1 — see docs/Group Puzzles v1.1.md. A group pools
/// the headwords its members chose to share; each day that pool anchors
/// one puzzle every member solves on their own copy — a crossword at the
/// size the group chose, or a Word Hunt board.
library;

import '../crossword/crossword_models.dart';

/// What a group plays every day. Chosen when the group is made and fixed
/// after (the server refuses a change).
enum GroupPuzzleKind {
  crossword('crossword', 'Crossword'),
  hunt('hunt', 'Word Hunt');

  /// The value the server stores (`groups.puzzle_kind`, `group_puzzles.kind`).
  final String storageKey;
  final String label;
  const GroupPuzzleKind(this.storageKey, this.label);

  static GroupPuzzleKind fromStorageKey(String? key) =>
      values.where((k) => k.storageKey == key).firstOrNull ?? crossword;
}

class Group {
  final String id;
  final String name;
  final String ownerId;
  final String inviteCode;
  final DateTime createdAt;
  final GroupPuzzleKind puzzleKind;

  /// The crossword size, when [puzzleKind] is a crossword.
  final CrosswordDifficulty crosswordSize;

  /// Filled by the list query: how many people, and whether this is mine.
  final int memberCount;

  const Group({
    required this.id,
    required this.name,
    required this.ownerId,
    required this.inviteCode,
    required this.createdAt,
    this.puzzleKind = GroupPuzzleKind.crossword,
    this.crosswordSize = CrosswordDifficulty.midi,
    this.memberCount = 0,
  });

  bool isOwnedBy(String userId) => ownerId == userId;

  /// "Mini crossword", "Word Hunt" — what the group plays, in a phrase.
  String get playsLabel => switch (puzzleKind) {
    GroupPuzzleKind.crossword => '${crosswordSize.label} crossword',
    GroupPuzzleKind.hunt => 'Word Hunt',
  };

  /// The `group_puzzles.difficulty` a puzzle of this group carries.
  String get puzzleDifficulty => switch (puzzleKind) {
    GroupPuzzleKind.crossword => crosswordSize.storageKey,
    GroupPuzzleKind.hunt => 'daily',
  };

  static Group fromJson(Map<String, dynamic> json) => Group(
    id: json['id'] as String,
    name: json['name'] as String,
    ownerId: json['owner_id'] as String,
    inviteCode: json['invite_code'] as String,
    createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ?? DateTime.now(),
    puzzleKind: GroupPuzzleKind.fromStorageKey(json['puzzle_kind'] as String?),
    crosswordSize: CrosswordDifficulty.values
            .where((d) => d.storageKey == json['crossword_size'])
            .firstOrNull ??
        CrosswordDifficulty.midi,
    memberCount: switch (json['group_members']) {
      final List<dynamic> rows =>
        rows.isNotEmpty && rows.first is Map && (rows.first as Map).containsKey('count')
            ? ((rows.first as Map)['count'] as num).toInt()
            : rows.length,
      _ => 0,
    },
  );
}

enum GroupRole { owner, member }

class GroupMember {
  final String groupId;
  final String userId;
  final GroupRole role;
  final String displayName;
  final bool shareWords;
  final DateTime joinedAt;

  const GroupMember({
    required this.groupId,
    required this.userId,
    required this.role,
    required this.displayName,
    required this.shareWords,
    required this.joinedAt,
  });

  static GroupMember fromJson(Map<String, dynamic> json) => GroupMember(
    groupId: json['group_id'] as String,
    userId: json['user_id'] as String,
    role: json['role'] == 'owner' ? GroupRole.owner : GroupRole.member,
    displayName: json['display_name'] as String,
    shareWords: json['share_words'] == true,
    joinedAt: DateTime.tryParse(json['joined_at'] as String? ?? '') ?? DateTime.now(),
  );
}

/// One shared headword, with who brought it and (when the dictionary
/// had one) a short gloss for the clue.
class GroupWord {
  final String headword;
  final String? gloss;
  final String userId;

  const GroupWord({required this.headword, this.gloss, required this.userId});

  static GroupWord fromJson(Map<String, dynamic> json) => GroupWord(
    headword: json['headword'] as String,
    gloss: json['gloss'] as String?,
    userId: json['user_id'] as String,
  );
}

/// The day's published puzzle, as the server holds it.
class GroupPuzzle {
  final String id;
  final String groupId;
  final String date; // YYYY-MM-DD
  final String kind;
  final String difficulty;
  final int seed;
  final Map<String, dynamic> grid;
  final List<String> anchors;
  final String? generatedBy;

  GroupPuzzleKind get puzzleKind => GroupPuzzleKind.fromStorageKey(kind);

  const GroupPuzzle({
    required this.id,
    required this.groupId,
    required this.date,
    required this.kind,
    required this.difficulty,
    required this.seed,
    required this.grid,
    required this.anchors,
    this.generatedBy,
  });

  static GroupPuzzle fromJson(Map<String, dynamic> json) => GroupPuzzle(
    id: json['id'] as String,
    groupId: json['group_id'] as String,
    date: (json['puzzle_date'] as String).substring(0, 10),
    kind: json['kind'] as String,
    difficulty: json['difficulty'] as String,
    seed: (json['seed'] as num).toInt(),
    grid: Map<String, dynamic>.from(json['grid'] as Map),
    anchors: [for (final a in json['anchors'] as List? ?? const []) a as String],
    generatedBy: json['generated_by'] as String?,
  );
}

class GroupScore {
  final String puzzleId;
  final String userId;
  final int solvedWords;
  final int totalWords;
  final bool completed;
  final int activeMs;
  final bool aided;

  /// The play's leaderboard points (lib/domain/games/scoring.dart) — what
  /// the group's standings add up.
  final int points;
  final DateTime updatedAt;

  const GroupScore({
    required this.puzzleId,
    required this.userId,
    required this.solvedWords,
    required this.totalWords,
    required this.completed,
    required this.activeMs,
    required this.aided,
    this.points = 0,
    required this.updatedAt,
  });

  static GroupScore fromJson(Map<String, dynamic> json) => GroupScore(
    puzzleId: json['puzzle_id'] as String,
    userId: json['user_id'] as String,
    solvedWords: (json['solved_words'] as num?)?.toInt() ?? 0,
    totalWords: (json['total_words'] as num?)?.toInt() ?? 0,
    completed: json['completed'] == true,
    activeMs: (json['active_ms'] as num?)?.toInt() ?? 0,
    aided: json['aided'] == true,
    points: (json['points'] as num?)?.toInt() ?? 0,
    updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '') ?? DateTime.now(),
  );

  Map<String, dynamic> toJson() => {
    'puzzle_id': puzzleId,
    'user_id': userId,
    'solved_words': solvedWords,
    'total_words': totalWords,
    'completed': completed,
    'active_ms': activeMs,
    'aided': aided,
    'points': points,
  };

  /// The "solved/total/completed" stamp the link row keeps to skip
  /// re-uploading an unchanged score.
  String get stamp => '$solvedWords/$totalWords/$completed/$aided/$points';
}

/// One member's line on the group's standings: points summed over the
/// group's puzzles in a period.
class GroupStanding {
  final int rank;
  final String userId;
  final String displayName;
  final int points;
  final int puzzles;
  final int completed;
  final bool isMe;

  const GroupStanding({
    required this.rank,
    required this.userId,
    required this.displayName,
    required this.points,
    required this.puzzles,
    required this.completed,
    required this.isMe,
  });

  static GroupStanding fromJson(Map<String, dynamic> json) => GroupStanding(
    rank: (json['rank'] as num).toInt(),
    userId: json['user_id'] as String,
    displayName: json['display_name'] as String? ?? 'Someone',
    points: (json['points'] as num?)?.toInt() ?? 0,
    puzzles: (json['puzzles'] as num?)?.toInt() ?? 0,
    completed: (json['completed'] as num?)?.toInt() ?? 0,
    isMe: json['is_me'] == true,
  );
}

/// The most groups one person can be in, owned or joined. The server
/// enforces it (`group_create`, `group_join`); the app says so up front.
const int maxGroupsPerPerson = 5;

/// Who's building today's group puzzle, as `group_claim_build` answers.
enum GroupBuildStatus { published, claimed, building }

class GroupBuildClaim {
  final GroupBuildStatus status;

  /// When someone else is building: their name in the group.
  final String? by;

  const GroupBuildClaim(this.status, {this.by});

  static GroupBuildClaim fromJson(Map<String, dynamic> json) => GroupBuildClaim(
    switch (json['status']) {
      'published' => GroupBuildStatus.published,
      'building' => GroupBuildStatus.building,
      _ => GroupBuildStatus.claimed,
    },
    by: json['by'] as String?,
  );
}

/// The periods the group standings can cover.
enum GroupStandingsPeriod {
  week('This week'),
  allTime('All time');

  final String label;
  const GroupStandingsPeriod(this.label);

  /// The first day counted, as YYYY-MM-DD, or null for all time. A week
  /// starts on Monday, as the global board's does.
  String? since(DateTime now) {
    if (this == allTime) return null;
    final monday = DateTime(now.year, now.month, now.day).subtract(Duration(days: now.weekday - 1));
    return '${monday.year.toString().padLeft(4, '0')}-'
        '${monday.month.toString().padLeft(2, '0')}-'
        '${monday.day.toString().padLeft(2, '0')}';
  }
}

/// Leaderboard order: finished first, then most words, then quickest;
/// an aided solve ranks below an unaided one at equal words.
int compareScores(GroupScore a, GroupScore b) {
  if (a.completed != b.completed) return a.completed ? -1 : 1;
  if (a.solvedWords != b.solvedWords) return b.solvedWords - a.solvedWords;
  if (a.aided != b.aided) return a.aided ? 1 : -1;
  return a.activeMs - b.activeMs;
}

/// The invite code as people type it: any case, spaces and dashes
/// ignored, look-alike digits mapped to the letters the alphabet uses.
String normalizeInviteCode(String raw) =>
    raw.toUpperCase().replaceAll(RegExp(r'[\s-]'), '').replaceAll('0', 'O').replaceAll('1', 'I');

/// What a person is told before their words join a pool (spec §7.2).
const String shareWordsConsentText =
    'The headwords of the words you\'re studying — just the words, not your notes, '
    'the meanings you pinned, or anything you looked up — become visible to the '
    'members of this group and are used to build its puzzles. Switch this off or '
    'leave the group and they\'re removed straight away.';
