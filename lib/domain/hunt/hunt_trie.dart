import 'dart:typed_data';

/// A compact, immutable letter trie over uppercase A-Z words, as four flat
/// typed arrays in left-child/right-sibling form.
///
/// The research engine's map-of-maps trie is the right shape for Python and
/// the wrong one for a phone: 169,000 accepted spellings make roughly
/// 400,000 nodes, and a Dart `Map` per node is tens of megabytes plus a
/// pointer chase per letter. Here a node is one row across the arrays — its
/// letter, whether a word ends here, its first child and its next sibling —
/// about 10 bytes, and the whole structure is sendable to an isolate as a
/// handful of typed lists. Child lookup walks the sibling chain, which is at
/// most 26 long and usually a few.
///
/// Built once per lexicon and reused for every board (research contract §8:
/// constructing a trie per puzzle costs more than solving the board).
class HuntTrie {
  /// Letter code 0-25 of each node; the root's is unused.
  final Uint8List letters;

  /// 1 where a word ends at the node.
  final Uint8List terminal;

  /// Index of the first child, or -1.
  final Int32List firstChild;

  /// Index of the next sibling, or -1.
  final Int32List nextSibling;

  final int nodeCount;
  final int wordCount;

  static const int root = 0;

  const HuntTrie._({
    required this.letters,
    required this.terminal,
    required this.firstChild,
    required this.nextSibling,
    required this.nodeCount,
    required this.wordCount,
  });

  /// Builds from any iterable of uppercase A-Z words; sorted and
  /// de-duplicated internally, and anything that isn't purely A-Z is
  /// skipped rather than corrupting the letter arrays.
  factory HuntTrie.build(Iterable<String> words) {
    final sorted = <String>[];
    for (final w in words) {
      if (w.isEmpty) continue;
      var ok = true;
      for (var i = 0; i < w.length; i++) {
        final c = w.codeUnitAt(i);
        if (c < 0x41 || c > 0x5A) {
          ok = false;
          break;
        }
      }
      if (ok) sorted.add(w);
    }
    sorted.sort();

    // Upper bound on nodes: one per letter plus the root. Trimmed after.
    var capacity = 1;
    for (final w in sorted) {
      capacity += w.length;
    }
    var letters = Uint8List(capacity);
    var terminal = Uint8List(capacity);
    var firstChild = Int32List(capacity)..fillRange(0, capacity, -1);
    var nextSibling = Int32List(capacity)..fillRange(0, capacity, -1);
    var count = 1;
    var wordCount = 0;

    // Sorted input means each word shares a prefix with the previous one and
    // then only ever *appends*: `path[d]` is the node at depth d along the
    // previous word, `lastChild[d]` the most recently added child under it,
    // which is where the next sibling links from.
    final path = Int32List(64);
    final lastChild = Int32List(64)..fillRange(0, 64, -1);
    var previous = '';
    for (final word in sorted) {
      if (word == previous) continue;
      var common = 0;
      final limit = word.length < previous.length ? word.length : previous.length;
      while (common < limit && word.codeUnitAt(common) == previous.codeUnitAt(common)) {
        common++;
      }
      for (var i = common; i < word.length; i++) {
        final node = count++;
        letters[node] = word.codeUnitAt(i) - 0x41;
        final parent = path[i];
        if (firstChild[parent] == -1) {
          firstChild[parent] = node;
        } else {
          nextSibling[lastChild[i]] = node;
        }
        lastChild[i] = node;
        path[i + 1] = node;
        lastChild[i + 1] = -1;
      }
      terminal[path[word.length]] = 1;
      wordCount++;
      previous = word;
    }

    if (count < capacity) {
      letters = Uint8List.sublistView(letters, 0, count);
      terminal = Uint8List.sublistView(terminal, 0, count);
      firstChild = Int32List.sublistView(firstChild, 0, count);
      nextSibling = Int32List.sublistView(nextSibling, 0, count);
    }
    return HuntTrie._(
      letters: letters,
      terminal: terminal,
      firstChild: firstChild,
      nextSibling: nextSibling,
      nodeCount: count,
      wordCount: wordCount,
    );
  }

  /// The child of [node] carrying [letter] (0-25), or -1.
  int child(int node, int letter) {
    var c = firstChild[node];
    while (c != -1) {
      if (letters[c] == letter) return c;
      c = nextSibling[c];
    }
    return -1;
  }

  bool isTerminal(int node) => terminal[node] == 1;

  /// Whether [word] (uppercase A-Z) is in the trie.
  bool contains(String word) {
    if (word.isEmpty) return false;
    var node = root;
    for (var i = 0; i < word.length; i++) {
      final c = word.codeUnitAt(i) - 0x41;
      if (c < 0 || c > 25) return false;
      node = child(node, c);
      if (node == -1) return false;
    }
    return terminal[node] == 1;
  }
}
