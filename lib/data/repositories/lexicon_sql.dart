/// SQL pieces for reading a word by entry id when the id may name either a
/// dictionary entry (`dict.entries`) or a word only the Slang Stack knows
/// (`slang_words`, ids from `slangIdBase` up — see
/// `domain/models/slang.dart`).
///
/// Both tables are joined and the columns coalesced, rather than read
/// through a `UNION ALL` view: SQLite won't flatten a compound view into a
/// query with ORDER BY, LIMIT or GROUP BY — which is nearly every query
/// here — and materialises it instead, which over the dictionary's 740k
/// entries took seconds. These joins stay two primary-key lookups a row.
///
/// The aliases are fixed: `de` for the dictionary row, `sw` for the slang
/// word. A query using them mustn't use either alias for anything else.
library;

/// `LEFT JOIN`s to both sides for the entry id [idExpr]. Pair with
/// [lexFound] in the WHERE clause to drop ids neither side knows, which is
/// what the plain `JOIN dict.entries` these replace did.
String lexJoins(String idExpr) => '''
  LEFT JOIN dict.entries de ON de.id = $idExpr
  LEFT JOIN slang_words sw ON sw.id = $idExpr''';

const lexFound = '(de.id IS NOT NULL OR sw.id IS NOT NULL)';

const lexHeadword = 'COALESCE(de.headword, sw.headword)';

/// The dictionary row's part of speech, or the slang word's first
/// meaning's.
const lexPos = "COALESCE(de.pos, "
    "(SELECT pos FROM slang_senses WHERE word_id = sw.id ORDER BY sense_order LIMIT 1), 'slang')";

/// The one-line gloss a list row or a card's summary shows: the person's
/// own first meaning when they've added one under this headword — that's
/// the sense they care about — else the dictionary's first.
String lexFirstGloss(String idExpr) => '''COALESCE(
    (SELECT ss.gloss FROM slang_senses ss JOIN slang_words w ON w.id = ss.word_id
       WHERE w.headword = $lexHeadword ORDER BY ss.sense_order LIMIT 1),
    (SELECT gloss FROM dict.senses WHERE entry_id = $idExpr ORDER BY sense_order LIMIT 1))''';

/// The first example, on the same terms as [lexFirstGloss].
String lexFirstExample(String idExpr) => '''COALESCE(
    (SELECT x.sentence FROM slang_examples x
       JOIN slang_senses ss ON ss.id = x.sense_id
       JOIN slang_words w ON w.id = ss.word_id
       WHERE w.headword = $lexHeadword ORDER BY ss.sense_order, x.id LIMIT 1),
    (SELECT x.text FROM dict.examples x
       JOIN dict.senses s2 ON s2.id = x.sense_id
       WHERE s2.entry_id = $idExpr ORDER BY s2.sense_order LIMIT 1))''';
