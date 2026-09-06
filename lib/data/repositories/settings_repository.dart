import '../user/user_database.dart';

class SettingsRepository {
  final UserDatabase _db;

  SettingsRepository(this._db);

  static const remindersKey = 'daily_reminders_enabled';

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
}
