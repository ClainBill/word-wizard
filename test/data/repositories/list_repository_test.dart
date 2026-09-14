import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/data/repositories/list_repository.dart';
import 'package:word_wizard/data/user/user_database.dart';
import 'package:word_wizard/domain/models/word_list.dart';

/// Folders are `lists` rows that other `lists` rows can nest under via
/// `parent_id` — these tests exercise the recursive rollup/subtree SQL in
/// list_hierarchy.dart, which is the first `WITH RECURSIVE` in this project.
/// No dictionary attach is needed: item/due counts never join `dict.*`.
void main() {
  late UserDatabase db;
  late ListRepository repo;

  setUp(() {
    db = UserDatabase(NativeDatabase.memory());
    repo = ListRepository(db);
  });

  tearDown(() => db.close());

  test('a plain list\'s item count is unaffected by folders existing elsewhere', () async {
    final listId = await repo.createList('Verbs');
    await repo.createList('Unrelated folder', kind: ListKind.folder);
    await repo.addToList(listId, 1);
    await repo.addToList(listId, 2);

    final roots = await repo.watchLists().first;
    final list = roots.firstWhere((l) => l.id == listId);
    expect(list.itemCount, 2);
    expect(list.kind, ListKind.custom);
    expect(list.isFolder, isFalse);
  });

  test('a folder\'s item count recursively sums its own words plus nested lists, 2+ levels deep', () async {
    final topFolder = await repo.createList('Top', kind: ListKind.folder);
    final subFolder = await repo.createList('Sub', kind: ListKind.folder, parentId: topFolder);
    final leafList = await repo.createList('Leaf', parentId: subFolder);

    await repo.addToList(topFolder, 1); // word directly in the top folder
    await repo.addToList(subFolder, 2); // word directly in the nested folder
    await repo.addToList(leafList, 3); // word two levels deep

    final roots = await repo.watchLists().first;
    final top = roots.firstWhere((l) => l.id == topFolder);
    expect(top.itemCount, 3);

    final subChildren = await repo.watchLists(parentId: topFolder).first;
    final sub = subChildren.firstWhere((l) => l.id == subFolder);
    expect(sub.itemCount, 2);
  });

  test('due count rolls up recursively too', () async {
    final folder = await repo.createList('Folder', kind: ListKind.folder);
    final child = await repo.createList('Child', parentId: folder);
    await repo.addToList(child, 1);
    await db.into(db.studyCards).insert(StudyCardsCompanion.insert(
          entryId: 1,
          dueAt: Value(DateTime.now().subtract(const Duration(days: 1))),
        ));

    final roots = await repo.watchLists().first;
    final top = roots.firstWhere((l) => l.id == folder);
    expect(top.dueCount, 1);
  });

  test('a word with two study cards (one per direction) is still one item, not two', () async {
    // Regression: item_count and due_count must be independent subqueries,
    // not one query joining list_items to study_cards — a word with more
    // than one card (one per studied direction) would otherwise fan that
    // join out and inflate item_count by however many cards it has. Caught
    // by manual testing, not by the earlier version of this test file.
    final list = await repo.createList('List');
    await repo.addToList(list, 1);
    await db.batch((b) => b.insertAll(db.studyCards, [
          StudyCardsCompanion.insert(entryId: 1, direction: const Value('w2m')),
          StudyCardsCompanion.insert(entryId: 1, direction: const Value('m2w')),
        ]));

    final roots = await repo.watchLists().first;
    final result = roots.firstWhere((l) => l.id == list);
    expect(result.itemCount, 1);
    expect(result.dueCount, 2); // both cards are due — that's a card count, not a word count
  });

  test('watchLists(parentId:) returns only the direct children of that level', () async {
    final folder = await repo.createList('Folder', kind: ListKind.folder);
    final child = await repo.createList('Child', kind: ListKind.folder, parentId: folder);
    final grandchild = await repo.createList('Grandchild', parentId: child);

    final roots = await repo.watchLists().first;
    expect(roots.map((l) => l.id), contains(folder));
    expect(roots.map((l) => l.id), isNot(contains(child)));

    final folderChildren = await repo.watchLists(parentId: folder).first;
    expect(folderChildren.map((l) => l.id).toList(), [child]);

    final childChildren = await repo.watchLists(parentId: child).first;
    expect(childChildren.map((l) => l.id).toList(), [grandchild]);
  });

  group('moveList', () {
    test('rejects moving a list into itself', () async {
      final id = await repo.createList('A', kind: ListKind.folder);
      await expectLater(repo.moveList(id, id), throwsStateError);
    });

    test('rejects moving into something that isn\'t a folder', () async {
      final plain = await repo.createList('Plain');
      final other = await repo.createList('Other');
      await expectLater(repo.moveList(other, plain), throwsStateError);
    });

    test('rejects moving a folder into its own descendant (cycle)', () async {
      final parent = await repo.createList('Parent', kind: ListKind.folder);
      final child = await repo.createList('Child', kind: ListKind.folder, parentId: parent);
      await expectLater(repo.moveList(parent, child), throwsStateError);
    });

    test('moves a list into a folder', () async {
      final folder = await repo.createList('Folder', kind: ListKind.folder);
      final list = await repo.createList('List');
      await repo.moveList(list, folder);
      final children = await repo.watchLists(parentId: folder).first;
      expect(children.map((l) => l.id), contains(list));
    });
  });

  test('deleteList on a folder cascades through its whole subtree', () async {
    final folder = await repo.createList('Folder', kind: ListKind.folder);
    final child = await repo.createList('Child', parentId: folder);
    await repo.addToList(folder, 1);
    await repo.addToList(child, 2);

    await repo.deleteList(folder);

    final roots = await repo.watchLists().first;
    expect(roots.map((l) => l.id), isNot(contains(folder)));
    final orphanCheck = await (db.select(db.lists)..where((t) => t.id.equals(child))).get();
    expect(orphanCheck, isEmpty);
  });

  test('deleting a plain list only deletes itself', () async {
    final untouched = await repo.createList('Untouched');
    final list = await repo.createList('List');
    await repo.addToList(list, 1);

    await repo.deleteList(list);

    final roots = await repo.watchLists().first;
    expect(roots.map((l) => l.id), isNot(contains(list)));
    expect(roots.map((l) => l.id), contains(untouched));
  });
}
