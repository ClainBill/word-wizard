import 'package:drift/drift.dart';

import '../../domain/models/word_list.dart';
import '../user/user_database.dart';

class ListRepository {
  final UserDatabase _db;

  ListRepository(this._db);

  Stream<List<WordList>> watchLists() {
    return _db
        .customSelect(
          '''
          SELECT l.id, l.name, l.kind, l.created_at,
            (SELECT COUNT(*) FROM list_items li WHERE li.list_id = l.id) AS item_count,
            (SELECT COUNT(*) FROM list_items li
               JOIN study_cards sc ON sc.entry_id = li.entry_id
               WHERE li.list_id = l.id AND sc.due_at <= ? AND sc.paused = 0) AS due_count
          FROM lists l
          ORDER BY l.created_at DESC
          ''',
          // See the comment in StudyRepository.watchDueCount: due_at is a
          // unix-epoch integer, so it must be compared against a bound
          // DateTime parameter rather than SQLite's TEXT-valued
          // CURRENT_TIMESTAMP.
          variables: [Variable.withDateTime(DateTime.now())],
          readsFrom: {_db.lists, _db.listItems, _db.studyCards},
        )
        .watch()
        .map((rows) => rows
            .map((r) => WordList(
                  id: r.read<int>('id'),
                  name: r.read<String>('name'),
                  kind: r.read<String>('kind') == 'curated' ? ListKind.curated : ListKind.custom,
                  createdAt: r.read<DateTime>('created_at'),
                  itemCount: r.read<int>('item_count'),
                  dueCount: r.read<int>('due_count'),
                ))
            .toList());
  }

  Stream<List<ListItem>> watchListItems(int listId) {
    return _db
        .customSelect(
          '''
          SELECT li.entry_id, li.note, li.added_at, e.headword, e.pos,
            (SELECT gloss FROM dict.senses WHERE entry_id = e.id ORDER BY sense_order LIMIT 1) AS gloss
          FROM list_items li
          JOIN dict.entries e ON e.id = li.entry_id
          WHERE li.list_id = ?
          ORDER BY li.added_at DESC
          ''',
          variables: [Variable.withInt(listId)],
          readsFrom: {_db.listItems},
        )
        .watch()
        .map((rows) => rows
            .map((r) => ListItem(
                  entryId: r.read<int>('entry_id'),
                  headword: r.read<String>('headword'),
                  pos: r.read<String>('pos'),
                  gloss: r.readNullable<String>('gloss'),
                  note: r.readNullable<String>('note'),
                  addedAt: r.read<DateTime>('added_at'),
                ))
            .toList());
  }

  /// Every list plus whether [entryId] is already a member of it — powers
  /// the "add to list" sheet's checkmarks so it can toggle membership
  /// instead of blindly re-adding (or looking addable) for lists a word is
  /// already in.
  Stream<List<ListMembership>> watchListsForEntry(int entryId) {
    return _db
        .customSelect(
          '''
          SELECT l.id, l.name,
            EXISTS(
              SELECT 1 FROM list_items li WHERE li.list_id = l.id AND li.entry_id = ?
            ) AS is_member
          FROM lists l
          ORDER BY l.created_at DESC
          ''',
          variables: [Variable.withInt(entryId)],
          readsFrom: {_db.lists, _db.listItems},
        )
        .watch()
        .map((rows) => rows
            .map((r) => ListMembership(
                  id: r.read<int>('id'),
                  name: r.read<String>('name'),
                  isMember: r.read<bool>('is_member'),
                ))
            .toList());
  }

  Future<int> createList(String name, {ListKind kind = ListKind.custom}) {
    return _db.into(_db.lists).insert(
          ListsCompanion.insert(name: name, kind: Value(kind.name)),
        );
  }

  /// Ignores the insert if the word is already in the list, rather than
  /// overwriting — there's no note-editing UI yet, so a conflict-update here
  /// would silently wipe out a note set some other way.
  Future<void> addToList(int listId, int entryId, {String? note}) {
    return _db.into(_db.listItems).insert(
          ListItemsCompanion.insert(
            listId: listId,
            entryId: entryId,
            note: Value(note),
          ),
          mode: InsertMode.insertOrIgnore,
        );
  }

  Future<void> removeFromList(int listId, int entryId) {
    return (_db.delete(_db.listItems)
          ..where((t) => t.listId.equals(listId) & t.entryId.equals(entryId)))
        .go();
  }

  Future<void> renameList(int listId, String name) {
    return (_db.update(_db.lists)..where((t) => t.id.equals(listId)))
        .write(ListsCompanion(name: Value(name)));
  }

  Future<void> deleteList(int listId) async {
    await (_db.delete(_db.listItems)..where((t) => t.listId.equals(listId))).go();
    await (_db.delete(_db.lists)..where((t) => t.id.equals(listId))).go();
  }
}
