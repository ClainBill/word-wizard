import 'package:drift/native.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/data/repositories/settings_repository.dart';
import 'package:word_wizard/data/user/user_database.dart';

void main() {
  late UserDatabase db;
  late SettingsRepository repo;

  setUp(() {
    db = UserDatabase(NativeDatabase.memory());
    repo = SettingsRepository(db);
  });

  tearDown(() => db.close());

  group('theme mode', () {
    test('defaults to system and round-trips light and dark', () async {
      expect(await repo.watchThemeMode().first, ThemeMode.system);
      await repo.setThemeMode(ThemeMode.dark);
      expect(await repo.watchThemeMode().first, ThemeMode.dark);
      await repo.setThemeMode(ThemeMode.light);
      expect(await repo.watchThemeMode().first, ThemeMode.light);
      await repo.setThemeMode(ThemeMode.system);
      expect(await repo.watchThemeMode().first, ThemeMode.system);
    });
  });

  group('tts voice', () {
    test('defaults to null, stores a choice, and clears back to null', () async {
      expect(await repo.watchTtsVoice().first, isNull);
      const voice = TtsVoiceChoice(name: 'en-us-x-sfg#female_2-local', locale: 'en-US');
      await repo.setTtsVoice(voice);
      expect(await repo.watchTtsVoice().first, voice);
      await repo.setTtsVoice(null);
      expect(await repo.watchTtsVoice().first, isNull);
    });

    test('a voice name containing the separator survives the round trip', () {
      const voice = TtsVoiceChoice(name: 'odd|name', locale: 'en-GB');
      expect(TtsVoiceChoice.parse(voice.storageValue), voice);
      expect(TtsVoiceChoice.parse('garbage'), isNull);
      expect(TtsVoiceChoice.parse(null), isNull);
    });
  });
}
