import 'dictionary/dictionary_database.dart';
import 'user/user_database.dart';

/// Opens both databases and attaches the (read-only) dictionary file onto
/// the user database's connection as schema `dict`, so list/study queries
/// can join user data straight against dictionary entries in one statement
/// instead of round-tripping through two separate connections.
class AppDatabases {
  final DictionaryDatabase dictionary;
  final UserDatabase user;

  AppDatabases._(this.dictionary, this.user);

  static Future<AppDatabases> open() async {
    final dictionary = await DictionaryDatabase.openBundled();
    final user = await UserDatabase.open();

    final dictPath = await DictionaryDatabase.resolveFilePath();
    // Escape single quotes defensively; the path itself is app-controlled.
    final escaped = dictPath.replaceAll("'", "''");
    await user.customStatement("ATTACH DATABASE '$escaped' AS dict");

    return AppDatabases._(dictionary, user);
  }

  Future<void> close() async {
    await user.close();
    await dictionary.close();
  }
}

/// Test-only note: [AppDatabases.open] relies on real files on disk (via
/// path_provider + drift's NativeDatabase), so it is not usable from plain
/// `flutter test` without a platform channel mock — exercise the SM-2 engine
/// and repositories against an in-memory [UserDatabase] instead when adding
/// data-layer tests.
