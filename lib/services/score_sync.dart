import 'package:flutter/foundation.dart';

import '../data/repositories/score_repository.dart';
import '../domain/games/scoring.dart';
import 'leaderboard_api.dart';

/// Pushes recent plays to the board. Only for people who opted in, only
/// when signed in, and never more than once a minute — the Games tab and
/// the leaderboard screen call it on every visit.
class ScoreSync {
  final ScoreRepository _scores;
  final LeaderboardApi _api;
  DateTime? _last;

  ScoreSync(this._scores, this._api);

  Future<int> sync({required String? userId, bool force = false}) async {
    if (userId == null || !_api.available) return 0;
    final now = DateTime.now();
    if (!force && _last != null && now.difference(_last!) < const Duration(minutes: 1)) return 0;
    _last = now;
    try {
      final profile = await _api.profile();
      if (!profile.visible) return 0;
      final plays = await _scores.recentPlays();
      await _api.submit(plays, userId: userId);
      return plays.length;
    } catch (e) {
      debugPrint('score sync: $e');
      return 0;
    }
  }

  /// For the opt-in sheet: what would go up right now.
  Future<List<PuzzlePlay>> preview() => _scores.recentPlays();
}
