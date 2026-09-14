import 'package:drift/drift.dart';

import '../../domain/models/word_list.dart';
import '../user/user_database.dart';
import 'list_hierarchy.dart';

class ListRepository {
  final UserDatabase _db;

  ListRepository(this._db);

  /// Lists/folders directly under [parentId] (top-level when null), each
  /// with recursive item/due totals over its own subtree — a folder's counts
  /// include every word nested inside it at any depth; a plain list's counts
  /// are just its own, since nothing can nest under it.
  ///
  /// item_count and due_count are deliberately two independent correlated
  /// subqueries rather than one query joining `list_items` and `study_cards`
  /// together: a word with more than one study card (one per direction it's
  /// studied in) would otherwise fan that join out, inflating item_count by
  /// however many cards the word happens to have — a bug caught by manual
  /// testing (a folder with one directly-added word that had both a w2m and
  /// an m2w card reported 2 words instead of 1).
  Stream<List<WordList>> watchLists({int? parentId}) {
    return _db
        .customSelect(
          parentId == null
              ? '''
                $listTreeRollupCte
                SELECT l.id, l.name, l.kind, l.parent_id, l.created_at,
                  (SELECT COUNT(*) FROM list_items li
                     WHERE li.list_id IN (SELECT id FROM list_tree WHERE root_id = l.id)) AS item_count,
                  (SELECT COUNT(*) FROM list_items li
                     JOIN study_cards sc ON sc.entry_id = li.entry_id
                     WHERE li.list_id IN (SELECT id FROM list_tree WHERE root_id = l.id)
                       AND sc.due_at <= ? AND sc.paused = 0) AS due_count
                FROM lists l
                WHERE l.parent_id IS NULL
                ORDER BY l.created_at DESC
                '''
              : '''
                $listTreeRollupCte
                SELECT l.id, l.name, l.kind, l.parent_id, l.created_at,
                  (SELECT COUNT(*) FROM list_items li
                     WHERE li.list_id IN (SELECT id FROM list_tree WHERE root_id = l.id)) AS item_count,
                  (SELECT COUNT(*) FROM list_items li
                     JOIN study_cards sc ON sc.entry_id = li.entry_id
                     WHERE li.list_id IN (SELECT id FROM list_tree WHERE root_id = l.id)
                       AND sc.due_at <= ? AND sc.paused = 0) AS due_count
                FROM lists l
                WHERE l.parent_id = ?
                ORDER BY l.created_at DESC
                ''',
          // See the comment in StudyRepository.watchDueCount: due_at is a
          // unix-epoch integer, so it must be compared against a bound
          // DateTime parameter rather than SQLite's TEXT-valued
          // CURRENT_TIMESTAMP.
          variables: parentId == null
              ? [Variable.withDateTime(DateTime.now())]
              : [Variable.withDateTime(DateTime.now()), Variable.withInt(parentId)],
          readsFrom: {_db.lists, _db.listItems, _db.studyCards},
        )
        .watch()
        .map((rows) => rows.map(_rowToWordList).toList());
  }

  /// One list/folder by id, with the same recursive totals as [watchLists] —
  /// lets a detail screen know what it's looking at (kind, parent) without
  /// relying on a name passed through navigation.
  Stream<WordList?> watchList(int id) {
    return _db
        .customSelect(
          '''
          $listTreeRollupCte
          SELECT l.id, l.name, l.kind, l.parent_id, l.created_at,
            (SELECT COUNT(*) FROM list_items li
               WHERE li.list_id IN (SELECT id FROM list_tree WHERE root_id = l.id)) AS item_count,
            (SELECT COUNT(*) FROM list_items li
               JOIN study_cards sc ON sc.entry_id = li.entry_id
               WHERE li.list_id IN (SELECT id FROM list_tree WHERE root_id = l.id)
                 AND sc.due_at <= ? AND sc.paused = 0) AS due_count
          FROM lists l
          WHERE l.id = ?
          ''',
          variables: [Variable.withDateTime(DateTime.now()), Variable.withInt(id)],
          readsFrom: {_db.lists, _db.listItems, _db.studyCards},
        )
        .watchSingleOrNull()
        .map((r) => r == null ? null : _rowToWordList(r));
  }

  WordList _rowToWordList(QueryRow r) {
    return WordList(
      id: r.read<int>('id'),
      name: r.read<String>('name'),
      kind: _kindFromStorage(r.read<String>('kind')),
      parentId: r.readNullable<int>('parent_id'),
      createdAt: r.read<DateTime>('created_at'),
      itemCount: r.read<int>('item_count'),
      dueCount: r.read<int>('due_count'),
    );
  }

  static ListKind _kindFromStorage(String kind) {
    switch (kind) {
      case 'curated':
        return ListKind.curated;
      case 'folder':
        return ListKind.folder;
      default:
        return ListKind.custom;
    }
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
  /// already in. Folders appear here too — a folder is a valid target, since
  /// it can hold words directly just like a plain list.
  Stream<List<ListMembership>> watchListsForEntry(int entryId) {
    return _db
        .customSelect(
          '''
          SELECT l.id, l.name, l.kind, l.parent_id,
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
                  kind: _kindFromStorage(r.read<String>('kind')),
                  parentId: r.readNullable<int>('parent_id'),
                  isMember: r.read<bool>('is_member'),
                ))
            .toList());
  }

  Future<int> createList(String name, {ListKind kind = ListKind.custom, int? parentId}) {
    return _db.into(_db.lists).insert(
          ListsCompanion.insert(
            name: name,
            kind: Value(kind.name),
            parentId: Value(parentId),
          ),
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

  /// Moves [listId] under [newParentId] (top-level when null). Throws a
  /// [StateError] rather than silently no-oping on an invalid move — the
  /// caller (a folder picker) is expected to only offer valid targets, so
  /// hitting one of these means something upstream is stale or buggy.
  Future<void> moveList(int listId, int? newParentId) async {
    if (newParentId == listId) {
      throw StateError('A list cannot be moved into itself.');
    }
    if (newParentId != null) {
      final target = await (_db.select(_db.lists)..where((t) => t.id.equals(newParentId)))
          .getSingleOrNull();
      if (target == null || _kindFromStorage(target.kind) != ListKind.folder) {
        throw StateError('Lists can only be moved into a folder.');
      }
      final subtree = await _subtreeIds(listId);
      if (subtree.contains(newParentId)) {
        throw StateError('A folder cannot be moved into its own contents.');
      }
    }
    await (_db.update(_db.lists)..where((t) => t.id.equals(listId)))
        .write(ListsCompanion(parentId: Value(newParentId)));
  }

  /// Every folder, for a "move to folder" picker — excluding [excludingSubtreeOf]'s
  /// own subtree, since a folder can't be moved into itself or one of its
  /// descendants.
  Future<List<WordList>> watchableFolders({int? excludingSubtreeOf}) async {
    final excluded = excludingSubtreeOf == null ? const <int>{} : await _subtreeIds(excludingSubtreeOf);
    final rows = await _db
        .customSelect(
          '''
          $listTreeRollupCte
          SELECT l.id, l.name, l.kind, l.parent_id, l.created_at,
            (SELECT COUNT(*) FROM list_items li
               WHERE li.list_id IN (SELECT id FROM list_tree WHERE root_id = l.id)) AS item_count,
            (SELECT COUNT(*) FROM list_items li
               JOIN study_cards sc ON sc.entry_id = li.entry_id
               WHERE li.list_id IN (SELECT id FROM list_tree WHERE root_id = l.id)
                 AND sc.due_at <= ? AND sc.paused = 0) AS due_count
          FROM lists l
          WHERE l.kind = 'folder'
          ORDER BY l.name
          ''',
          variables: [Variable.withDateTime(DateTime.now())],
          readsFrom: {_db.lists, _db.listItems, _db.studyCards},
        )
        .get();
    return rows.map(_rowToWordList).where((l) => !excluded.contains(l.id)).toList();
  }

  /// Deletes [listId] and, if it's a folder, everything nested inside it at
  /// any depth — its own words, every descendant list/folder, and their
  /// words. A plain list's subtree is just itself, so this is unchanged
  /// behavior for the non-folder case.
  Future<void> deleteList(int listId) async {
    final ids = await _subtreeIds(listId);
    if (ids.isEmpty) return;
    await (_db.delete(_db.listItems)..where((t) => t.listId.isIn(ids))).go();
    await (_db.delete(_db.lists)..where((t) => t.id.isIn(ids))).go();
  }

  Future<Set<int>> _subtreeIds(int rootId) async {
    final rows = await _db.customSelect(
      '$listSubtreeCte SELECT id FROM list_subtree',
      variables: [Variable.withInt(rootId)],
      readsFrom: {_db.lists},
    ).get();
    return rows.map((r) => r.read<int>('id')).toSet();
  }
}
