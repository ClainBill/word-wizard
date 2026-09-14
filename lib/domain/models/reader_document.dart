/// A piece of text the user brought into the Reader — from the clipboard or
/// typed in — kept as a small structured document rather than a flat string
/// so that what was copied *as* a heading, a quote, or bold text is still
/// drawn as one on the page.
///
/// Deliberately tiny: block kinds and three inline flags. That is enough to
/// make a copied article look like the article rather than a wall of text,
/// and small enough that the HTML importer never has to be clever about the
/// long tail of markup a browser puts on the clipboard.
enum BlockKind {
  paragraph,
  heading,
  quote,
  bullet,
  numbered;

  static BlockKind fromStorageKey(String key) =>
      values.firstWhere((k) => k.name == key, orElse: () => BlockKind.paragraph);
}

class ReaderSpan {
  final String text;
  final bool bold;
  final bool italic;
  final bool underline;

  const ReaderSpan(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.underline = false,
  });

  bool get isPlain => !bold && !italic && !underline;

  bool sameStyle(ReaderSpan other) =>
      bold == other.bold && italic == other.italic && underline == other.underline;

  ReaderSpan copyWith({String? text}) =>
      ReaderSpan(text ?? this.text, bold: bold, italic: italic, underline: underline);

  Map<String, Object?> toJson() => {
        't': text,
        if (bold) 'b': 1,
        if (italic) 'i': 1,
        if (underline) 'u': 1,
      };

  factory ReaderSpan.fromJson(Map<String, Object?> json) => ReaderSpan(
        json['t'] as String? ?? '',
        bold: json['b'] == 1,
        italic: json['i'] == 1,
        underline: json['u'] == 1,
      );
}

class ReaderBlock {
  final BlockKind kind;

  /// Heading level 1-6 for [BlockKind.heading]; the 1-based item number for
  /// [BlockKind.numbered]; unused otherwise.
  final int level;
  final List<ReaderSpan> spans;

  const ReaderBlock({required this.kind, this.level = 0, required this.spans});

  /// The block's text with formatting flattened out — what the tokenizer
  /// runs over, and what span/token offsets are measured against.
  String get text => spans.map((s) => s.text).join();

  Map<String, Object?> toJson() => {
        'k': kind.name,
        if (level != 0) 'l': level,
        's': [for (final s in spans) s.toJson()],
      };

  factory ReaderBlock.fromJson(Map<String, Object?> json) => ReaderBlock(
        kind: BlockKind.fromStorageKey(json['k'] as String? ?? 'paragraph'),
        level: json['l'] as int? ?? 0,
        spans: [
          for (final s in (json['s'] as List? ?? const []))
            ReaderSpan.fromJson((s as Map).cast<String, Object?>()),
        ],
      );
}

/// Where a document's text came from.
enum ReaderSource {
  clipboard,
  typed;

  static ReaderSource fromStorageKey(String key) =>
      values.firstWhere((s) => s.name == key, orElse: () => ReaderSource.typed);

  String get label => switch (this) {
        ReaderSource.clipboard => 'Clipboard',
        ReaderSource.typed => 'Written',
      };
}

class ReaderDocument {
  final int id;
  final String title;
  final ReaderSource source;
  final List<ReaderBlock> blocks;

  /// Fingerprint of the flattened text — changes only when the text does,
  /// which is what the (expensive) word analysis is cached against.
  final String contentHash;
  final int wordCount;
  final DateTime createdAt;
  final DateTime openedAt;

  const ReaderDocument({
    required this.id,
    required this.title,
    required this.source,
    required this.blocks,
    required this.contentHash,
    required this.wordCount,
    required this.createdAt,
    required this.openedAt,
  });

  String get plainText => blocks.map((b) => b.text).join('\n\n');
}

/// The history row: everything but the blocks, which nobody needs to list
/// two hundred documents.
class ReaderDocumentSummary {
  final int id;
  final String title;
  final String preview;
  final ReaderSource source;
  final int wordCount;
  final DateTime createdAt;
  final DateTime openedAt;

  const ReaderDocumentSummary({
    required this.id,
    required this.title,
    required this.preview,
    required this.source,
    required this.wordCount,
    required this.createdAt,
    required this.openedAt,
  });
}
