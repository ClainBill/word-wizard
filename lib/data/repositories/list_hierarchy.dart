/// Shared `WITH RECURSIVE` fragments over `lists.parent_id` — folders are
/// just `lists` rows that other `lists` rows (plain lists or folders) can
/// nest under, so "operate on this list" and "operate on this folder and
/// everything nested inside it" are the same query shape once the ids to
/// operate over come from one of these.
library;

/// Ids in the subtree rooted at one bound `?` id — that id itself plus every
/// list/folder nested under it, at any depth. For a plain (non-folder) list
/// this always resolves to just `{itself}`, since nothing can be nested under
/// it — which is what makes every existing per-list action (enroll, pause,
/// reset, remove, due-queue, delete) work unchanged for folders once its
/// `list_id = ?` filter is replaced with
/// `list_id IN (SELECT id FROM list_subtree)`, prefixed with this CTE.
const listSubtreeCte = '''
WITH RECURSIVE list_subtree(id) AS (
  SELECT ? AS id
  UNION ALL
  SELECT l.id FROM lists l JOIN list_subtree s ON l.parent_id = s.id
)
''';

/// For every list/folder row, every id in its own subtree — one pass that
/// computes the recursive rollup for all rows at once, rather than one
/// correlated query per row. `root_id` is the list/folder being rolled up
/// for, `id` ranges over it and everything nested inside it.
const listTreeRollupCte = '''
WITH RECURSIVE list_tree(root_id, id) AS (
  SELECT id, id FROM lists
  UNION ALL
  SELECT t.root_id, l.id FROM lists l JOIN list_tree t ON l.parent_id = t.id
)
''';
