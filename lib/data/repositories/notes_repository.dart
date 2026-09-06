import 'package:drift/drift.dart';

import '../user/user_database.dart';

class NotesRepository {
  final UserDatabase _db;

  NotesRepository(this._db);

  Stream<String?> watchNote(int entryId) {
    return (_db.select(_db.entryNotes)..where((t) => t.entryId.equals(entryId)))
        .watchSingleOrNull()
        .map((row) => row?.markdown);
  }

  /// Saving an empty/whitespace-only note deletes the row rather than
  /// storing blank text — an empty note and no note should look identical.
  Future<void> saveNote(int entryId, String markdown) async {
    final trimmed = markdown.trim();
    if (trimmed.isEmpty) {
      await (_db.delete(_db.entryNotes)..where((t) => t.entryId.equals(entryId))).go();
      return;
    }
    await _db.into(_db.entryNotes).insertOnConflictUpdate(
          EntryNotesCompanion.insert(entryId: Value(entryId), markdown: trimmed),
        );
  }
}
