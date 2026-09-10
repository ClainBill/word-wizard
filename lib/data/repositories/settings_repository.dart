import '../user/user_database.dart';

class SettingsRepository {
  final UserDatabase _db;

  SettingsRepository(this._db);

  static const remindersKey = 'daily_reminders_enabled';

  /// **Debug setting.** Whether the crossword's editorial pass may call the
  /// model at all (PORTING_SPEC.md §9.3). It defaults on, matching the
  /// behaviour when there was no switch, and exists so a puzzle can be
  /// regenerated repeatedly — while tuning grids, anchors or clue selection —
  /// without paying for a review of each one, and so the same puzzle can be
  /// compared with the pass on and off.
  static const crosswordReviewKey = 'crossword_ai_editor_enabled';

  /// Reminders default on (no row yet) so the feature works out of the box;
  /// an explicit 'false' row is what turns them off.
  Stream<bool> watchRemindersEnabled() {
    return (_db.select(_db.settings)..where((t) => t.key.equals(remindersKey)))
        .watchSingleOrNull()
        .map((row) => row?.value != 'false');
  }

  Future<void> setRemindersEnabled(bool enabled) {
    return _db.into(_db.settings).insertOnConflictUpdate(
          SettingsCompanion.insert(key: remindersKey, value: enabled.toString()),
        );
  }

  Stream<bool> watchCrosswordReviewEnabled() {
    return (_db.select(_db.settings)..where((t) => t.key.equals(crosswordReviewKey)))
        .watchSingleOrNull()
        .map((row) => row?.value != 'false');
  }

  /// The one-shot read the generator uses; the switch itself watches.
  Future<bool> crosswordReviewEnabled() async {
    final row = await (_db.select(_db.settings)
          ..where((t) => t.key.equals(crosswordReviewKey)))
        .getSingleOrNull();
    return row?.value != 'false';
  }

  Future<void> setCrosswordReviewEnabled(bool enabled) {
    return _db.into(_db.settings).insertOnConflictUpdate(
          SettingsCompanion.insert(key: crosswordReviewKey, value: enabled.toString()),
        );
  }
}
