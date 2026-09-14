enum ListKind { custom, curated, folder }

class WordList {
  final int id;
  final String name;
  final ListKind kind;
  final int? parentId;
  final DateTime createdAt;

  /// Recursive totals: for a folder, these sum over every word directly in
  /// it plus every word in any list/folder nested inside it at any depth.
  /// For a plain list (nothing can nest under it) these are just its own
  /// counts, unchanged from before folders existed.
  final int itemCount;
  final int dueCount;

  const WordList({
    required this.id,
    required this.name,
    required this.kind,
    this.parentId,
    required this.createdAt,
    this.itemCount = 0,
    this.dueCount = 0,
  });

  bool get isFolder => kind == ListKind.folder;
}

/// A list name plus whether some entry (implicit from the query) already
/// belongs to it — see [ListRepository.watchListsForEntry].
class ListMembership {
  final int id;
  final String name;
  final ListKind kind;
  final int? parentId;
  final bool isMember;

  const ListMembership({
    required this.id,
    required this.name,
    required this.kind,
    this.parentId,
    required this.isMember,
  });
}

class ListItem {
  final int entryId;
  final String headword;
  final String pos;
  final String? gloss;
  final String? note;
  final DateTime addedAt;

  const ListItem({
    required this.entryId,
    required this.headword,
    required this.pos,
    this.gloss,
    this.note,
    required this.addedAt,
  });
}
