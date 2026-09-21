import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../domain/groups/group_models.dart';

/// Something the server said no to, in words for the person.
class GroupsException implements Exception {
  final String message;
  const GroupsException(this.message);
  @override
  String toString() => message;
}

/// The group tables, as the signed-in user (row-level security does the
/// rest). One real implementation over PostgREST; a fake for tests.
abstract class GroupsApi {
  bool get available;

  Future<List<Group>> myGroups();
  Future<Group?> group(String groupId);
  Future<String> create({required String name, required String displayName});
  Future<String> join({required String code, required String displayName});
  Future<void> leave(String groupId, {required String userId});
  Future<void> removeMember(String groupId, {required String userId});
  Future<void> deleteGroup(String groupId);
  Future<List<GroupMember>> members(String groupId);
  Future<void> setShareWords(String groupId, {required String userId, required bool share});
  Future<void> setDisplayName(String groupId, {required String userId, required String name});

  /// Replaces this member's shared words with [words].
  Future<void> replaceMyWords(
    String groupId, {
    required String userId,
    required List<GroupWord> words,
  });
  Future<List<GroupWord>> pool(String groupId);

  Future<GroupPuzzle?> puzzle(String groupId, {required String date, String kind = 'crossword'});

  /// Offers a generated puzzle; returns the one the group will play,
  /// which may be someone else's if they published first.
  Future<GroupPuzzle> publishPuzzle({
    required String groupId,
    required String date,
    required String kind,
    required String difficulty,
    required int seed,
    required Map<String, dynamic> grid,
    required List<String> anchors,
  });

  Future<List<GroupScore>> scores(String puzzleId);
  Future<void> submitScore(GroupScore score);
}

class SupabaseGroupsApi implements GroupsApi {
  final sb.SupabaseClient _client;

  SupabaseGroupsApi(this._client);

  @override
  bool get available => true;

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on sb.PostgrestException catch (e) {
      throw GroupsException(_friendly(e));
    } catch (e) {
      debugPrint('groups: $e');
      throw const GroupsException('Couldn\'t reach the server. Check your connection.');
    }
  }

  static String _friendly(sb.PostgrestException e) => switch (e.message) {
    'invalid_code' => 'That code doesn\'t match a group.',
    'group_full' => 'That group is full (12 people).',
    'too_many_groups' => 'You already own ten groups.',
    'unauthenticated' || 'not_a_member' => 'Sign in to use groups.',
    _ => 'The server said no: ${e.message}',
  };

  @override
  Future<List<Group>> myGroups() => _guard(() async {
    final rows = await _client
        .from('groups')
        .select('id, name, owner_id, invite_code, created_at, group_members(count)')
        .order('created_at');
    return [for (final r in rows) Group.fromJson(r)];
  });

  @override
  Future<Group?> group(String groupId) => _guard(() async {
    final row = await _client
        .from('groups')
        .select('id, name, owner_id, invite_code, created_at, group_members(count)')
        .eq('id', groupId)
        .maybeSingle();
    return row == null ? null : Group.fromJson(row);
  });

  @override
  Future<String> create({required String name, required String displayName}) => _guard(() async {
    final id = await _client.rpc(
      'group_create',
      params: {'p_name': name, 'p_display_name': displayName},
    );
    return id as String;
  });

  @override
  Future<String> join({required String code, required String displayName}) => _guard(() async {
    final id = await _client.rpc(
      'group_join',
      params: {'p_code': code, 'p_display_name': displayName},
    );
    return id as String;
  });

  @override
  Future<void> leave(String groupId, {required String userId}) => _guard(
    () => _client.from('group_members').delete().eq('group_id', groupId).eq('user_id', userId),
  );

  @override
  Future<void> removeMember(String groupId, {required String userId}) =>
      leave(groupId, userId: userId);

  @override
  Future<void> deleteGroup(String groupId) =>
      _guard(() => _client.from('groups').delete().eq('id', groupId));

  @override
  Future<List<GroupMember>> members(String groupId) => _guard(() async {
    final rows = await _client
        .from('group_members')
        .select()
        .eq('group_id', groupId)
        .order('joined_at');
    return [for (final r in rows) GroupMember.fromJson(r)];
  });

  @override
  Future<void> setShareWords(String groupId, {required String userId, required bool share}) =>
      _guard(
        () => _client
            .from('group_members')
            .update({'share_words': share})
            .eq('group_id', groupId)
            .eq('user_id', userId),
      );

  @override
  Future<void> setDisplayName(String groupId, {required String userId, required String name}) =>
      _guard(
        () => _client
            .from('group_members')
            .update({'display_name': name})
            .eq('group_id', groupId)
            .eq('user_id', userId),
      );

  @override
  Future<void> replaceMyWords(
    String groupId, {
    required String userId,
    required List<GroupWord> words,
  }) => _guard(() async {
    await _client.from('group_words').delete().eq('group_id', groupId).eq('user_id', userId);
    if (words.isEmpty) return;
    // PostgREST wants every object in a bulk insert to carry the same keys.
    await _client.from('group_words').upsert([
      for (final w in words)
        {'group_id': groupId, 'user_id': userId, 'headword': w.headword, 'gloss': w.gloss},
    ]);
  });

  @override
  Future<List<GroupWord>> pool(String groupId) => _guard(() async {
    final rows = await _client
        .from('group_words')
        .select('headword, gloss, user_id')
        .eq('group_id', groupId);
    return [for (final r in rows) GroupWord.fromJson(r)];
  });

  @override
  Future<GroupPuzzle?> puzzle(String groupId, {required String date, String kind = 'crossword'}) =>
      _guard(() async {
        final row = await _client
            .from('group_puzzles')
            .select()
            .eq('group_id', groupId)
            .eq('puzzle_date', date)
            .eq('kind', kind)
            .maybeSingle();
        return row == null ? null : GroupPuzzle.fromJson(row);
      });

  @override
  Future<GroupPuzzle> publishPuzzle({
    required String groupId,
    required String date,
    required String kind,
    required String difficulty,
    required int seed,
    required Map<String, dynamic> grid,
    required List<String> anchors,
  }) => _guard(() async {
    final row = await _client.rpc(
      'group_publish_puzzle',
      params: {
        'p_group': groupId,
        'p_date': date,
        'p_kind': kind,
        'p_difficulty': difficulty,
        'p_seed': seed,
        'p_grid': grid,
        'p_anchors': anchors,
      },
    );
    return GroupPuzzle.fromJson(Map<String, dynamic>.from(row as Map));
  });

  @override
  Future<List<GroupScore>> scores(String puzzleId) => _guard(() async {
    final rows = await _client.from('group_scores').select().eq('puzzle_id', puzzleId);
    return [for (final r in rows) GroupScore.fromJson(r)]..sort(compareScores);
  });

  @override
  Future<void> submitScore(GroupScore score) =>
      _guard(() => _client.from('group_scores').upsert(score.toJson()));
}

/// No backend in this build.
class NoGroupsApi implements GroupsApi {
  const NoGroupsApi();
  static Never _no() => throw const GroupsException('Groups aren\'t available in this build.');

  @override
  bool get available => false;
  @override
  Future<List<Group>> myGroups() async => const [];
  @override
  Future<Group?> group(String groupId) async => null;
  @override
  Future<String> create({required String name, required String displayName}) async => _no();
  @override
  Future<String> join({required String code, required String displayName}) async => _no();
  @override
  Future<void> leave(String groupId, {required String userId}) async => _no();
  @override
  Future<void> removeMember(String groupId, {required String userId}) async => _no();
  @override
  Future<void> deleteGroup(String groupId) async => _no();
  @override
  Future<List<GroupMember>> members(String groupId) async => const [];
  @override
  Future<void> setShareWords(String groupId, {required String userId, required bool share}) async =>
      _no();
  @override
  Future<void> setDisplayName(
    String groupId, {
    required String userId,
    required String name,
  }) async => _no();
  @override
  Future<void> replaceMyWords(
    String groupId, {
    required String userId,
    required List<GroupWord> words,
  }) async => _no();
  @override
  Future<List<GroupWord>> pool(String groupId) async => const [];
  @override
  Future<GroupPuzzle?> puzzle(
    String groupId, {
    required String date,
    String kind = 'crossword',
  }) async => null;
  @override
  Future<GroupPuzzle> publishPuzzle({
    required String groupId,
    required String date,
    required String kind,
    required String difficulty,
    required int seed,
    required Map<String, dynamic> grid,
    required List<String> anchors,
  }) async => _no();
  @override
  Future<List<GroupScore>> scores(String puzzleId) async => const [];
  @override
  Future<void> submitScore(GroupScore score) async => _no();
}
