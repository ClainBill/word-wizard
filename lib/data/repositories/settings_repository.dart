import 'package:flutter/material.dart' show ThemeMode;

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

/// A text-to-speech voice as flutter_tts identifies one: the pair of
/// fields `setVoice` takes. See [SettingsRepository.ttsVoiceKey].
class TtsVoiceChoice {
  final String name;
  final String locale;

  const TtsVoiceChoice({required this.name, required this.locale});

  static TtsVoiceChoice? parse(String? stored) {
    if (stored == null) return null;
    final cut = stored.lastIndexOf('|');
    if (cut <= 0) return null;
    return TtsVoiceChoice(name: stored.substring(0, cut), locale: stored.substring(cut + 1));
  }

  String get storageValue => '$name|$locale';

  @override
  bool operator ==(Object other) =>
      other is TtsVoiceChoice && other.name == name && other.locale == locale;

  @override
  int get hashCode => Object.hash(name, locale);
}

class SettingsRepository {
  final UserDatabase _db;

  SettingsRepository(this._db);

  static const remindersKey = 'daily_reminders_enabled';

  /// The morning word-of-the-day notification. Like reminders, on unless
  /// an explicit 'false' row says otherwise.
  static const wordOfTheDayKey = 'word_of_the_day_notification_enabled';

  /// Light, dark, or follow the system. Absent means system, which is how
  /// the app behaved before the setting existed.
  static const themeModeKey = 'theme_mode';

  /// The pronunciation voice, as `name|locale` — the two fields flutter_tts
  /// needs to select it again. Absent means the device's default English
  /// voice.
  static const ttsVoiceKey = 'tts_voice';

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

  Stream<bool> watchWordOfTheDayEnabled() {
    return (_db.select(_db.settings)..where((t) => t.key.equals(wordOfTheDayKey)))
        .watchSingleOrNull()
        .map((row) => row?.value != 'false');
  }

  Future<void> setWordOfTheDayEnabled(bool enabled) {
    return _db.into(_db.settings).insertOnConflictUpdate(
          SettingsCompanion.insert(key: wordOfTheDayKey, value: enabled.toString()),
        );
  }

  Future<void> setRemindersEnabled(bool enabled) {
    return _db.into(_db.settings).insertOnConflictUpdate(
          SettingsCompanion.insert(key: remindersKey, value: enabled.toString()),
        );
  }

  Stream<ThemeMode> watchThemeMode() {
    return (_db.select(_db.settings)..where((t) => t.key.equals(themeModeKey)))
        .watchSingleOrNull()
        .map((row) => switch (row?.value) {
              'light' => ThemeMode.light,
              'dark' => ThemeMode.dark,
              _ => ThemeMode.system,
            });
  }

  Future<void> setThemeMode(ThemeMode mode) {
    return _db.into(_db.settings).insertOnConflictUpdate(
          SettingsCompanion.insert(key: themeModeKey, value: mode.name),
        );
  }

  Stream<TtsVoiceChoice?> watchTtsVoice() {
    return (_db.select(_db.settings)..where((t) => t.key.equals(ttsVoiceKey)))
        .watchSingleOrNull()
        .map((row) => TtsVoiceChoice.parse(row?.value));
  }

  /// Null clears the choice back to the device default.
  Future<void> setTtsVoice(TtsVoiceChoice? voice) async {
    if (voice == null) {
      await (_db.delete(_db.settings)..where((t) => t.key.equals(ttsVoiceKey))).go();
      return;
    }
    await _db.into(_db.settings).insertOnConflictUpdate(
          SettingsCompanion.insert(key: ttsVoiceKey, value: voice.storageValue),
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

  // -------------------------------------------------------------------
  // Premium
  // -------------------------------------------------------------------

  /// The unsolicited-prompt bookkeeping of `domain/premium/prompt_policy`
  /// as JSON: sessions, dismissals and when things last happened.
  static const premiumPromptStateKey = 'premium_prompt_state';

  Future<String?> premiumPromptState() async {
    final row = await (_db.select(_db.settings)
          ..where((t) => t.key.equals(premiumPromptStateKey)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> setPremiumPromptState(String json) {
    return _db.into(_db.settings).insertOnConflictUpdate(
          SettingsCompanion.insert(key: premiumPromptStateKey, value: json),
        );
  }
}
