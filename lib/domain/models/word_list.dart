enum ListKind { custom, curated }

class WordList {
  final int id;
  final String name;
  final ListKind kind;
  final DateTime createdAt;
  final int itemCount;
  final int dueCount;

  const WordList({
    required this.id,
    required this.name,
    required this.kind,
    required this.createdAt,
    this.itemCount = 0,
    this.dueCount = 0,
  });
}

/// A list name plus whether some entry (implicit from the query) already
/// belongs to it — see [ListRepository.watchListsForEntry].
class ListMembership {
  final int id;
  final String name;
  final bool isMember;

  const ListMembership({required this.id, required this.name, required this.isMember});
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
