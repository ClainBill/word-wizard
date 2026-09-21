import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../domain/games/scoring.dart';

class LeaderboardException implements Exception {
  final String message;
  const LeaderboardException(this.message);
  @override
  String toString() => message;
}

/// The global board (migrations 20260921000000_leaderboard.sql,
/// 20260922000000_leaderboard_public.sql). Anyone can read it, signed in
/// or not; uploading scores needs an account, and appearing on it needs
/// a public name and the opt-in, both on the profile.
abstract class LeaderboardApi {
  bool get available;
  Future<LeaderboardProfile> profile();
  Future<void> setProfile({required String? publicName, required bool optIn});
  Future<void> submit(List<PuzzlePlay> plays, {required String userId});
  Future<List<LeaderboardEntry>> top({required String period, int limit = 50});
  Future<MyRank?> myRank({required String period});
}

class SupabaseLeaderboardApi implements LeaderboardApi {
  final sb.SupabaseClient _client;

  SupabaseLeaderboardApi(this._client);

  @override
  bool get available => true;

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on sb.PostgrestException catch (e) {
      throw LeaderboardException(
        e.message == 'too_many_plays'
            ? 'Too many plays today to count.'
            : 'The server said no: ${e.message}',
      );
    } catch (e) {
      debugPrint('leaderboard: $e');
      throw const LeaderboardException('Couldn\'t reach the server. Check your connection.');
    }
  }

  @override
  Future<LeaderboardProfile> profile() => _guard(() async {
    final id = _client.auth.currentUser?.id;
    if (id == null) return const LeaderboardProfile();
    final row = await _client
        .from('profiles')
        .select('public_name, leaderboard_opt_in')
        .eq('id', id)
        .maybeSingle();
    return LeaderboardProfile(
      publicName: row?['public_name'] as String?,
      optIn: row?['leaderboard_opt_in'] == true,
    );
  });

  @override
  Future<void> setProfile({required String? publicName, required bool optIn}) => _guard(() async {
    final id = _client.auth.currentUser?.id;
    if (id == null) throw const LeaderboardException('Sign in first.');
    await _client
        .from('profiles')
        .update({'public_name': publicName, 'leaderboard_opt_in': optIn})
        .eq('id', id);
  });

  @override
  Future<void> submit(List<PuzzlePlay> plays, {required String userId}) => _guard(() async {
    if (plays.isEmpty) return;
    await _client.from('puzzle_scores').upsert([for (final p in plays) p.toJson(userId)]);
  });

  @override
  Future<List<LeaderboardEntry>> top({required String period, int limit = 50}) => _guard(() async {
    final rows = await _client.rpc('leaderboard', params: {'p_period': period, 'p_limit': limit});
    return [
      for (final r in rows as List) LeaderboardEntry.fromJson(Map<String, dynamic>.from(r as Map)),
    ];
  });

  @override
  Future<MyRank?> myRank({required String period}) => _guard(() async {
    // Authenticated-only on the server; signed out there is no rank to ask for.
    if (_client.auth.currentUser == null) return null;
    final rows = await _client.rpc('my_leaderboard_rank', params: {'p_period': period});
    final list = rows as List;
    return list.isEmpty ? null : MyRank.fromJson(Map<String, dynamic>.from(list.first as Map));
  });
}

class NoLeaderboardApi implements LeaderboardApi {
  const NoLeaderboardApi();
  @override
  bool get available => false;
  @override
  Future<LeaderboardProfile> profile() async => const LeaderboardProfile();
  @override
  Future<void> setProfile({required String? publicName, required bool optIn}) async {}
  @override
  Future<void> submit(List<PuzzlePlay> plays, {required String userId}) async {}
  @override
  Future<List<LeaderboardEntry>> top({required String period, int limit = 50}) async => const [];
  @override
  Future<MyRank?> myRank({required String period}) async => null;
}
