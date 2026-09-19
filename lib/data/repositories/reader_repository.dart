import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/models/reader_document.dart';
import '../../domain/models/word_list.dart';
import '../../domain/reader/reader_analysis.dart';
import '../../domain/reader/text_import.dart';
import '../../domain/reader/tokenizer.dart';
import '../user/user_database.dart';

/// The Reader tab's history of documents, and the two lookups that turn a
/// document into a marked-up page: resolving every word to a dictionary
/// entry (once, against the attached `dict` schema) and watching which of
/// those entries are in lists or under study (live).
class ReaderRepository {
  final UserDatabase _db;

  ReaderRepository(this._db);

  // SQLite's bound-parameter ceiling is 32766 on any build this app ships
  // with, but a pasted article can have a few thousand distinct words, so
  // lookups are chunked well under it.
  static const _chunkSize = 400;

  // ---------------------------------------------------------------------
  // Documents
  // ---------------------------------------------------------------------

  Stream<List<ReaderDocumentSummary>> watchHistory() {
    return (_db.select(_db.readerDocuments)..orderBy([(t) => OrderingTerm.desc(t.openSeq)]))
        .watch()
        .map((rows) => rows.map(_rowToSummary).toList());
  }

  /// The document the tab shows: whichever was opened most recently. Null
  /// until anything has ever been pasted.
  Stream<ReaderDocument?> watchCurrent() {
    return (_db.select(_db.readerDocuments)
          ..orderBy([(t) => OrderingTerm.desc(t.openSeq)])
          ..limit(1))
        .watchSingleOrNull()
        .map((row) => row == null ? null : _rowToDocument(row));
  }

  Future<ReaderDocument?> getDocument(int id) async {
    final row = await (_db.select(_db.readerDocuments)..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _rowToDocument(row);
  }

  /// The id of an existing document with exactly this text, if any — so
  /// re-copying something already in history reopens it instead of
  /// duplicating it.
  Future<int?> findByContent(List<ReaderBlock> blocks) async {
    final hash = fingerprint(_flatten(blocks));
    final row = await (_db.select(_db.readerDocuments)..where((t) => t.contentHash.equals(hash)))
        .getSingleOrNull();
    return row?.id;
  }

  /// Creates a document and makes it current. [title] defaults to one
  /// derived from the text.
  Future<int> createDocument(
    List<ReaderBlock> blocks, {
    required ReaderSource source,
    String? title,
  }) async {
    final flat = _flatten(blocks);
    return _db.into(_db.readerDocuments).insert(
          ReaderDocumentsCompanion.insert(
            title: title?.trim().isNotEmpty == true ? title!.trim() : deriveTitle(blocks),
            source: Value(source.name),
            blocksJson: _encodeBlocks(blocks),
            preview: Value(derivePreview(blocks)),
            contentHash: fingerprint(flat),
            wordCount: Value(countWords(flat)),
            openSeq: Value(await _nextOpenSeq()),
          ),
        );
  }

  /// Replaces a document's text (after editing it). The title is kept
  /// unless it was the auto-derived one — a title the user typed survives
  /// an edit to the body.
  Future<void> updateDocumentText(int id, List<ReaderBlock> blocks, {String? title}) async {
    final flat = _flatten(blocks);
    await (_db.update(_db.readerDocuments)..where((t) => t.id.equals(id))).write(
      ReaderDocumentsCompanion(
        title: title == null || title.trim().isEmpty ? const Value.absent() : Value(title.trim()),
        blocksJson: Value(_encodeBlocks(blocks)),
        preview: Value(derivePreview(blocks)),
        contentHash: Value(fingerprint(flat)),
        wordCount: Value(countWords(flat)),
        openedAt: Value(DateTime.now()),
        openSeq: Value(await _nextOpenSeq()),
      ),
    );
  }

  Future<void> rename(int id, String title) {
    return (_db.update(_db.readerDocuments)..where((t) => t.id.equals(id)))
        .write(ReaderDocumentsCompanion(title: Value(title.trim())));
  }

  /// Marks a document as the current one.
  Future<void> open(int id) async {
    await (_db.update(_db.readerDocuments)..where((t) => t.id.equals(id))).write(
      ReaderDocumentsCompanion(openedAt: Value(DateTime.now()), openSeq: Value(await _nextOpenSeq())),
    );
  }

  Future<int> _nextOpenSeq() async {
    final row = await _db
        .customSelect('SELECT COALESCE(MAX(open_seq), 0) + 1 AS next FROM reader_documents')
        .getSingle();
    return row.read<int>('next');
  }

  Future<void> delete(int id) {
    return (_db.delete(_db.readerDocuments)..where((t) => t.id.equals(id))).go();
  }

  Future<void> deleteAll() => _db.delete(_db.readerDocuments).go();

  static String _flatten(List<ReaderBlock> blocks) => blocks.map((b) => b.text).join('\n\n');

  static String _encodeBlocks(List<ReaderBlock> blocks) => jsonEncode([for (final b in blocks) b.toJson()]);

  static List<ReaderBlock> decodeBlocks(String json) => [
        for (final b in (jsonDecode(json) as List)) ReaderBlock.fromJson((b as Map).cast<String, Object?>()),
      ];

  ReaderDocument _rowToDocument(ReaderDocumentRow row) => ReaderDocument(
        id: row.id,
        title: row.title,
        source: ReaderSource.fromStorageKey(row.source),
        blocks: decodeBlocks(row.blocksJson),
        contentHash: row.contentHash,
        wordCount: row.wordCount,
        createdAt: row.createdAt,
        openedAt: row.openedAt,
      );

  ReaderDocumentSummary _rowToSummary(ReaderDocumentRow row) => ReaderDocumentSummary(
        id: row.id,
        title: row.title,
        preview: row.preview,
        source: ReaderSource.fromStorageKey(row.source),
        wordCount: row.wordCount,
        createdAt: row.createdAt,
        openedAt: row.openedAt,
      );

  // ---------------------------------------------------------------------
  // Analysis
  // ---------------------------------------------------------------------

  /// Resolves every word in [blocks] to a dictionary entry, in two batched
  /// lookups rather than one query per word: first each spelling (as
  /// written, lower-cased, minus a possessive) against headwords and against
  /// the inflection table; then the canonical row for every headword that
  /// came back — the same "best-ranked (headword, pos) row" rule
  /// `DictionaryDatabase.loadWord` uses, so the ids here are the ids the
  /// rest of the app keys on.
  Future<ReaderAnalysis> analyze(List<ReaderBlock> blocks) async {
    final tokensPerBlock = [for (final b in blocks) tokenize(b.text)];

    // Every spelling worth trying, across every token, deduplicated.
    final candidates = <String>{};
    for (var i = 0; i < blocks.length; i++) {
      final text = blocks[i].text;
      for (final token in tokensPerBlock[i]) {
        candidates.addAll(_candidateSpellings(token.textIn(text)));
        for (final part in splitHyphens(token, text)) {
          candidates.addAll(_candidateSpellings(part.textIn(text)));
        }
      }
    }
    if (candidates.isEmpty) {
      return ReaderAnalysis([for (final tokens in tokensPerBlock) [for (final t in tokens) AnalyzedToken(t, null)]]);
    }

    final matches = await _lookupSpellings(candidates);
    final headwords = <String>{
      for (final m in matches.values) ...[if (m.direct != null) m.direct!, ...m.lemmas.map((l) => l.headword)],
    };
    final canonical = await _canonicalRows(headwords);

    ResolvedWord? resolveSpelling(String spelling) {
      for (final candidate in _candidateSpellings(spelling)) {
        final match = matches[candidate];
        if (match == null) continue;
        if (match.direct != null) {
          final direct = canonical[match.direct!];
          if (direct == null) continue;
          // The best-ranked lemma this spelling inflects from, if it's a
          // different word.
          ResolvedWord? lemma;
          for (final l in match.lemmas) {
            if (l.headword == match.direct) continue;
            final row = canonical[l.headword];
            if (row != null) {
              lemma = row;
              break;
            }
          }
          return lemma == null ? direct : direct.withLemma(lemma);
        }
        for (final l in match.lemmas) {
          final row = canonical[l.headword];
          if (row != null) return row;
        }
      }
      return null;
    }

    final analyzed = <List<AnalyzedToken>>[];
    for (var i = 0; i < blocks.length; i++) {
      final text = blocks[i].text;
      final out = <AnalyzedToken>[];
      for (final token in tokensPerBlock[i]) {
        final whole = resolveSpelling(token.textIn(text));
        if (whole != null) {
          out.add(AnalyzedToken(token, whole));
          continue;
        }
        // "bio-luminescent" isn't a headword, but its halves might be.
        final parts = splitHyphens(token, text);
        if (parts.isEmpty) {
          out.add(AnalyzedToken(token, null));
        } else {
          for (final part in parts) {
            out.add(AnalyzedToken(part, resolveSpelling(part.textIn(text))));
          }
        }
      }
      analyzed.add(out);
    }
    return ReaderAnalysis(analyzed);
  }

  /// The spellings to try for one word, most likely first: lower-case (how
  /// nearly every headword is filed), as written (proper nouns), and with a
  /// trailing possessive dropped ("Darwin's", "the word’s").
  static List<String> _candidateSpellings(String word) {
    final lower = word.toLowerCase();
    final out = <String>[lower];
    if (word != lower) out.add(word);
    for (final base in List.of(out)) {
      if (base.endsWith("'s") || base.endsWith('’s')) out.add(base.substring(0, base.length - 2));
    }
    return out;
  }

  Future<Map<String, _SpellingMatch>> _lookupSpellings(Set<String> spellings) async {
    final result = <String, _SpellingMatch>{};
    final list = spellings.toList();
    for (var i = 0; i < list.length; i += _chunkSize) {
      final chunk = list.sublist(i, i + _chunkSize > list.length ? list.length : i + _chunkSize);
      final values = chunk.map((_) => '(?)').join(',');
      final rows = await _db.customSelect(
        '''
        WITH c(w) AS (VALUES $values)
        SELECT c.w AS spelling, e.headword AS headword, 0 AS via, e.frequency_rank AS rank
        FROM c JOIN dict.entries e ON e.headword = c.w
        UNION ALL
        SELECT c.w, e.headword, 1, e.frequency_rank
        FROM c
        JOIN dict.forms f ON f.form_text = c.w
        JOIN dict.entries e ON e.id = f.entry_id
        UNION ALL
        SELECT c.w, v.headword, 2, NULL
        FROM c JOIN dict.spelling_variants v ON v.variant = c.w
        ''',
        variables: [for (final s in chunk) Variable.withString(s)],
      ).get();
      for (final r in rows) {
        final spelling = r.read<String>('spelling');
        final headword = r.read<String>('headword');
        final match = result.putIfAbsent(spelling, _SpellingMatch.new);
        switch (r.read<int>('via')) {
          // A word that is only another spelling of one ("colour") is that
          // word ("color") on the page, whatever order the rows come in.
          case 2:
            match.direct = headword;
            match.directIsVariantTarget = true;
          case 0:
            if (!match.directIsVariantTarget) match.direct = headword;
          default:
            match.lemmas.add((headword: headword, rank: r.readNullable<int>('rank')));
        }
      }
    }
    for (final m in result.values) {
      m.lemmas.sort((a, b) => _compareRank(a.rank, b.rank));
    }
    return result;
  }

  static int _compareRank(int? a, int? b) {
    if (a == null) return b == null ? 0 : 1;
    if (b == null) return -1;
    return a.compareTo(b);
  }

  Future<Map<String, ResolvedWord>> _canonicalRows(Set<String> headwords) async {
    final result = <String, ResolvedWord>{};
    final list = headwords.toList();
    for (var i = 0; i < list.length; i += _chunkSize) {
      final chunk = list.sublist(i, i + _chunkSize > list.length ? list.length : i + _chunkSize);
      final placeholders = chunk.map((_) => '?').join(',');
      final rows = await _db.customSelect(
        '''
        SELECT m.headword, m.id, m.pos, m.frequency_rank,
               (SELECT gloss FROM dict.senses s WHERE s.entry_id = m.id ORDER BY sense_order LIMIT 1) AS gloss
        FROM (
          SELECT e.headword, e.id, e.pos, e.frequency_rank,
                 ROW_NUMBER() OVER (
                   PARTITION BY e.headword
                   ORDER BY (e.frequency_rank IS NULL), e.frequency_rank, e.pos
                 ) AS rn
          FROM dict.entries e
          WHERE e.headword IN ($placeholders)
        ) m
        WHERE m.rn = 1
        ''',
        variables: [for (final h in chunk) Variable.withString(h)],
      ).get();
      for (final r in rows) {
        final headword = r.read<String>('headword');
        result[headword] = ResolvedWord(
          headword: headword,
          entryId: r.read<int>('id'),
          pos: r.read<String>('pos'),
          gloss: r.readNullable<String>('gloss'),
          frequencyRank: r.readNullable<int>('frequency_rank'),
        );
      }
    }
    return result;
  }

  // ---------------------------------------------------------------------
  // Marks
  // ---------------------------------------------------------------------

  /// Every list membership and every studied entry, as one stream: a
  /// personal vocabulary has hundreds of these, not millions, so watching
  /// the lot and filtering in memory is simpler and no slower than
  /// re-issuing a per-document `IN (...)` query on every change.
  Stream<WordMarks> watchMarks() {
    return _db
        .customSelect(
          '''
          SELECT entry_id, list_id, 0 AS studying FROM list_items
          UNION ALL
          SELECT DISTINCT entry_id, NULL, 1 FROM study_cards
          ''',
          readsFrom: {_db.listItems, _db.studyCards},
        )
        .watch()
        .map((rows) {
      final lists = <int, List<int>>{};
      final studying = <int>{};
      for (final r in rows) {
        final entryId = r.read<int>('entry_id');
        if (r.read<int>('studying') == 1) {
          studying.add(entryId);
        } else {
          lists.putIfAbsent(entryId, () => []).add(r.read<int>('list_id'));
        }
      }
      return WordMarks(listIdsByEntry: lists, studyingEntryIds: studying);
    });
  }

  /// Every list and folder by id — names for the legend and peek panel.
  Stream<Map<int, ReaderListInfo>> watchListIndex() {
    return _db.select(_db.lists).watch().map((rows) => {
          for (final r in rows)
            r.id: ReaderListInfo(
              id: r.id,
              name: r.name,
              kind: r.kind == 'folder' ? ListKind.folder : (r.kind == 'curated' ? ListKind.curated : ListKind.custom),
            ),
        });
  }
}

class ReaderListInfo {
  final int id;
  final String name;
  final ListKind kind;

  const ReaderListInfo({required this.id, required this.name, required this.kind});
}

class _SpellingMatch {
  String? direct;

  /// [direct] is the word a variant spelling points at, which a row for the
  /// variant's own stub entry must not overwrite.
  bool directIsVariantTarget = false;
  final lemmas = <({String headword, int? rank})>[];
}

extension on ResolvedWord {
  ResolvedWord withLemma(ResolvedWord lemma) => ResolvedWord(
        headword: headword,
        entryId: entryId,
        pos: pos,
        gloss: gloss,
        frequencyRank: frequencyRank,
        lemma: lemma,
      );
}
