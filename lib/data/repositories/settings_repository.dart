import '../../domain/models/study_direction.dart';
import '../user/user_database.dart';

/// How the Reader page is drawn — see [SettingsRepository.watchReaderPrefs].
class ReaderPrefs {
  final double fontSize;
  final bool markUncommon;

  const ReaderPrefs({
    this.fontSize = SettingsRepository.readerDefaultFontSize,
    this.markUncommon = true,
  });
}

class SettingsRepository {
  final UserDatabase _db;

  SettingsRepository(this._db);

  static const remindersKey = 'daily_reminders_enabled';

  /// Which direction(s) SRS reviews are asked in — see
  /// [StudyDirectionMode]. Absent (or unrecognised) means
  /// [StudyDirectionMode.defaultMode], word → meaning, which is how every
  /// card behaved before the setting existed.
  static const studyDirectionKey = 'srs_study_direction_mode';

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

  Stream<StudyDirectionMode> watchStudyDirectionMode() {
    return (_db.select(_db.settings)..where((t) => t.key.equals(studyDirectionKey)))
        .watchSingleOrNull()
        .map((row) => StudyDirectionMode.fromStorageKey(row?.value));
  }

  /// The one-shot read used when a word is enrolled (which needs to know
  /// which direction rows to create); the options sheet watches instead.
  Future<StudyDirectionMode> studyDirectionMode() async {
    final row = await (_db.select(_db.settings)
          ..where((t) => t.key.equals(studyDirectionKey)))
        .getSingleOrNull();
    return StudyDirectionMode.fromStorageKey(row?.value);
  }

  Future<void> setStudyDirectionMode(StudyDirectionMode mode) {
    return _db.into(_db.settings).insertOnConflictUpdate(
          SettingsCompanion.insert(key: studyDirectionKey, value: mode.storageKey),
        );
  }

  /// Identifies the last clipboard contents the Reader tab pulled in, so
  /// the same copy isn't offered again on every visit. The Android clip
  /// timestamp when there is one (checking it doesn't count as reading the
  /// clipboard, so no system toast), else a fingerprint of the text.
  static const readerClipboardStampKey = 'reader_clipboard_stamp';

  /// Reader body text size, in logical pixels.
  static const readerFontSizeKey = 'reader_font_size';
  static const readerDefaultFontSize = 17.0;

  /// Whether the Reader page underlines words past the uncommon-rank line
  /// — see `uncommonRankThreshold`. On by default: spotting words worth
  /// learning is the point of reading in a vocabulary app.
  static const readerMarkUncommonKey = 'reader_mark_uncommon';

  Stream<ReaderPrefs> watchReaderPrefs() {
    return (_db.select(_db.settings)
          ..where((t) => t.key.isIn([readerFontSizeKey, readerMarkUncommonKey])))
        .watch()
        .map((rows) {
      final byKey = {for (final r in rows) r.key: r.value};
      return ReaderPrefs(
        fontSize: double.tryParse(byKey[readerFontSizeKey] ?? '') ?? readerDefaultFontSize,
        markUncommon: byKey[readerMarkUncommonKey] != 'false',
      );
    });
  }

  Future<void> setReaderFontSize(double size) {
    return _db.into(_db.settings).insertOnConflictUpdate(
          SettingsCompanion.insert(key: readerFontSizeKey, value: size.toString()),
        );
  }

  Future<void> setReaderMarkUncommon(bool enabled) {
    return _db.into(_db.settings).insertOnConflictUpdate(
          SettingsCompanion.insert(key: readerMarkUncommonKey, value: enabled.toString()),
        );
  }

  Future<String?> readerClipboardStamp() async {
    final row = await (_db.select(_db.settings)
          ..where((t) => t.key.equals(readerClipboardStampKey)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> setReaderClipboardStamp(String stamp) {
    return _db.into(_db.settings).insertOnConflictUpdate(
          SettingsCompanion.insert(key: readerClipboardStampKey, value: stamp),
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
