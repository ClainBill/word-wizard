import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/models/entry.dart';
import '../../domain/study/quiz_example.dart';

part 'dictionary_database.g.dart';

/// The read-only vocabulary database — generated once, offline, by
/// `tool/pipeline/build_dictionary.py` from a Kaikki.org Wiktionary extract.
///
/// This class owns no drift-managed tables: the schema already exists (with
/// `PRAGMA user_version` pre-set by the pipeline) by the time the app opens
/// it, so every query below is a hand-written `customSelect` against that
/// fixed, external schema rather than drift-generated SQL.
@DriftDatabase(tables: [])
class DictionaryDatabase extends _$DictionaryDatabase {
  DictionaryDatabase(super.e);

  // Wiktionary orders senses with the primary/most common meaning first —
  // confirmed against the bundled data (e.g. "cat"'s sense_order 0-1 are the
  // mammal/pet senses; its obscure "synonym of itinerant worker" sense is
  // order 7). Restricting clue candidates to early senses filters out the
  // long tail of technical/slang/niche meanings a random pick would
  // otherwise surface just as often as the obvious one.
  static const _maxSenseOrderForClue = 2;

  // "Abbreviation of X." / "Initialism of X." / "Acronym of X." / "Clipping
  // of X." / "Ellipsis of X." glosses (several thousand of them in the
  // bundled dictionary) turn directly into the classic crossword "___, for
  // short" clue style. Deliberately handled separately from
  // [_synonymOrDefinitionClue] below: unlike a real leak, an abbreviation or
  // clipping is *supposed* to share letters with its expansion (that's the
  // entire premise of the clue) — e.g. ESC's expansion "escape" trivially
  // contains "esc", INT's "intermediate" trivially contains "int". Running
  // the leak check against these produced constant false positives (ESC,
  // INT, STA and most other real abbreviations all "leaked" by this
  // definition), so this path is exempt from it entirely.
  static final _abbreviationGloss =
      RegExp(r'^(?:Abbreviation|Initialism|Acronym|Clipping|Ellipsis) of (.+?)\.?$', caseSensitive: false);
  // "Synonym of X." glosses (tens of thousands in the bundled dictionary)
  // are exactly the plain-synonym clue style real crosswords use — often
  // with a quoted mini-definition of the sense attached, which is even
  // terser than the bare synonym.
  static final _synonymGloss = RegExp(r'^Synonym of (.+?)\.?$', caseSensitive: false);
  static final _quotedAside = RegExp('[“"]([^”"]+)[”"]');

  // Common English inflectional/derivational suffixes — used to tell a
  // genuine restatement of the answer (e.g. "surfeited" for SURFEIT) from a
  // coincidental unrelated word that merely happens to start with the same
  // letters (e.g. "amah" for AMA, "Ljósalfar" for ALF, "escape" for ESC).
  static final _inflectionalSuffixes = [
    'ing', 'tion', 'ment', 'ness', 'able', 'ible', 'less', 'ful', 'ies', 'ers', 'est',
    's', 'd', 'ed', 'er', 'y',
  ]..sort((a, b) => b.length.compareTo(a.length)); // longest first

  static String _capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  /// True if [clue] restates [answer] outright — an exact word match, or a
  /// word that is [answer] plus a common suffix (catches inflections a raw
  /// gloss list-of-synonyms often includes, e.g. the bundled data's
  /// "surfeit" glosses include "sated; surfeited; filled"). Deliberately
  /// narrower than a plain substring check: an early version flagged *any*
  /// word containing the answer anywhere, which caught genuine leaks but
  /// also coincidental unrelated matches (ALF flagged by "Ljósalfar", AMA by
  /// "amah") purely because the answer happened to be a short 3-letter
  /// prefix. Only checked against the word actually being clued, so short
  /// answers don't false-positive against unrelated words in general.
  static bool _leaksAnswer(String clue, String answer) {
    if (answer.length < 3) return false;
    final answerLower = answer.toLowerCase();
    for (final match in RegExp(r"[A-Za-z']+").allMatches(clue)) {
      final word = match.group(0)!.replaceAll("'", '').toLowerCase();
      if (word == answerLower) return true;
      if (word.startsWith(answerLower) &&
          _inflectionalSuffixes.contains(word.substring(answerLower.length))) {
        return true;
      }
    }
    return false;
  }

  /// Handles the "Abbreviation/Initialism/Acronym/Clipping/Ellipsis of X"
  /// gloss family — see [_abbreviationGloss] for why these are exempt from
  /// [_leaksAnswer]. Returns `null` if the gloss doesn't match this pattern.
  static String? _abbreviationClue(String gloss) {
    final match = _abbreviationGloss.firstMatch(gloss);
    if (match == null) return null;
    var target = match.group(1)!.replaceAll(_quotedAside, '').trim();
    target = target.split(RegExp('[;,]')).first.trim();
    if (target.isEmpty || target.length > 40) return gloss;
    return '${_capitalize(target)}, for short';
  }

  /// Handles "Synonym of X" glosses and, for everything else, returns the
  /// gloss as a plain definition-style clue. Never returns `null` for a
  /// non-empty [gloss] — callers apply [_leaksAnswer] to whatever comes back.
  static String _synonymOrDefinitionClue(String gloss) {
    final synonymMatch = _synonymGloss.firstMatch(gloss);
    if (synonymMatch != null) {
      final rest = synonymMatch.group(1)!.trim();
      final quoted = _quotedAside.firstMatch(rest);
      var target = quoted != null ? quoted.group(1)!.trim() : rest.replaceAll(_quotedAside, '').trim();
      final parenIndex = target.indexOf('(');
      if (parenIndex > 0) target = target.substring(0, parenIndex).trim();
      if (target.isEmpty || target.length > 40) return gloss;
      return _capitalize(target);
    }
    return gloss;
  }

  @override
  int get schemaVersion => 1;

  // Bump whenever the bundled `assets/db/dictionary.db` asset changes, so
  // devices holding an already-copied (and now stale) database file — e.g.
  // an install from before the full dictionary replaced the 469-entry
  // curated core set — re-copy instead of silently keeping the old data.
  static const _assetVersion = '2-full';

  static Future<String> resolveFilePath() async {
    final dir = await getApplicationSupportDirectory();
    return p.join(dir.path, 'dictionary.db');
  }

  static Future<String> _versionMarkerPath() async {
    final dir = await getApplicationSupportDirectory();
    return p.join(dir.path, 'dictionary.version');
  }

  /// Copies the bundled `assets/db/dictionary.db` asset to a real file the
  /// first time the app runs (or whenever [_assetVersion] moves past what's
  /// already on disk), then opens it. Otherwise just opens the existing
  /// copy — re-copying a 400&nbsp;MB asset on every launch would be wasteful.
  static Future<DictionaryDatabase> openBundled() async {
    final file = File(await resolveFilePath());
    final versionFile = File(await _versionMarkerPath());
    final onDiskVersion = await versionFile.exists() ? await versionFile.readAsString() : null;

    if (!await file.exists() || onDiskVersion != _assetVersion) {
      final bytes = await rootBundle.load('assets/db/dictionary.db');
      await file.create(recursive: true);
      await file.writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
      await versionFile.writeAsString(_assetVersion);
    }
    return DictionaryDatabase(
      NativeDatabase.createInBackground(file, setup: (db) {
        db.execute('PRAGMA query_only = ON;');
      }),
    );
  }

  /// Search results are deduped to one row per headword — "run" (verb,
  /// noun, adj) shows up once, ranked and glossed by whichever POS variant
  /// ranks best, since a lookup should feel like one word with several
  /// meanings rather than three near-duplicate rows. `loadWord` fills in
  /// the rest once the user taps in.
  ///
  /// Ordered in three tiers before frequency ever comes into it: the
  /// headword that *is* the query, then headwords that start with it, then
  /// everything else the index matched (multi-word headwords whose later
  /// word starts with it — "house museum" for "muse"). Frequency alone put
  /// "museum" and ten compounds above "muse" itself, which is the one row
  /// someone typing "muse" is nearly always after.
  Future<List<EntrySummary>> search(String query, {int limit = 30}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    // A trailing space is a deliberate "stop here" signal from the user —
    // it switches the last word from a prefix match to an exact-token
    // match, so "muse " excludes "museum" instead of the space just being
    // silently absorbed by trim().
    final exact = query.endsWith(' ');
    final sanitized = trimmed.replaceAll('"', ' ');
    final ftsQuery = exact ? sanitized : '$sanitized*';
    // LIKE is case-insensitive for ASCII, which is what makes "muse" and
    // "Muse" both land in the first tier. `_` and `%` are wildcards in a
    // LIKE pattern, so they're escaped in case someone types one.
    final likePrefix = '${trimmed.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_')}%';
    final rows = await customSelect(
      '''
      SELECT m.id, m.headword, m.pos,
             (SELECT gloss FROM senses WHERE entry_id = m.id ORDER BY sense_order LIMIT 1) AS gloss
      FROM (
        SELECT e.id, e.headword, e.pos, e.frequency_rank,
               CASE
                 WHEN e.headword = ? COLLATE NOCASE THEN 0
                 WHEN e.headword LIKE ? ESCAPE '\\' THEN 1
                 ELSE 2
               END AS tier,
               ROW_NUMBER() OVER (
                 PARTITION BY e.headword
                 ORDER BY (e.frequency_rank IS NULL), e.frequency_rank
               ) AS rn
        FROM entries_fts f
        JOIN entries e ON e.id = f.rowid
        WHERE entries_fts MATCH ?
      ) m
      WHERE m.rn = 1
      ORDER BY m.tier, (m.frequency_rank IS NULL), m.frequency_rank ASC
      LIMIT ?
      ''',
      variables: [
        Variable.withString(trimmed),
        Variable.withString(likePrefix),
        Variable.withString(ftsQuery),
        Variable.withInt(limit),
      ],
    ).get();
    return rows.map(_summaryFromRow).toList();
  }

  /// Resolves an inflected surface form ("ran") back to its lemma, deduped
  /// by headword the same way [search] is.
  ///
  /// Looks the form up as typed and lower-cased rather than with `COLLATE
  /// NOCASE`: a collation the index wasn't built with makes SQLite scan all
  /// 800k+ form rows, and this runs on every search keystroke.
  Future<List<EntrySummary>> resolveForm(String surfaceForm) async {
    final trimmed = surfaceForm.trim();
    if (trimmed.isEmpty) return const [];
    final rows = await customSelect(
      '''
      SELECT m.id, m.headword, m.pos,
             (SELECT gloss FROM senses WHERE entry_id = m.id ORDER BY sense_order LIMIT 1) AS gloss
      FROM (
        SELECT e.id, e.headword, e.pos, e.frequency_rank,
               ROW_NUMBER() OVER (
                 PARTITION BY e.headword
                 ORDER BY (e.frequency_rank IS NULL), e.frequency_rank
               ) AS rn
        FROM forms fm
        JOIN entries e ON e.id = fm.entry_id
        WHERE fm.form_text IN (?, ?)
      ) m
      WHERE m.rn = 1
      ORDER BY (m.frequency_rank IS NULL), m.frequency_rank ASC
      ''',
      variables: [Variable.withString(trimmed), Variable.withString(trimmed.toLowerCase())],
    ).get();
    return rows.map(_summaryFromRow).toList();
  }

  static EntrySummary _summaryFromRow(QueryRow r) => EntrySummary(
        id: r.read<int>('id'),
        headword: r.read<String>('headword'),
        pos: r.read<String>('pos'),
        gloss: r.readNullable<String>('gloss'),
      );

  /// A best-effort "sounds like" cue for the study session's rhyme/sound
  /// recall game — another common headword ending in the same 2-3 letters
  /// as [headword], used as a purely phonological hint (nothing about
  /// meaning). Spelling-suffix match is a proxy for a real phonetic rhyme —
  /// there's no pronunciation-similarity data in this database — but it's
  /// right often enough (e.g. -tion, -ight, -ould) to be worth the shortcut.
  ///
  /// Tries the shortest, most distinctive suffix first, widening the
  /// frequency-rank net (common words only, then less common) rather than
  /// scanning all 740k+ entries — a leading-wildcard `LIKE` can't use the
  /// headword index, so this always filters by `frequency_rank` first
  /// (indexed) and only `LIKE`-scans the handful of rows within that band.
  /// Returns null rather than falling back to a full scan if nothing common
  /// enough turns up.
  Future<String?> similarSoundingWord(String headword, {required int excludeEntryId}) async {
    final lower = headword.toLowerCase();
    if (lower.length < 3) return null;
    final suffixes = [
      if (lower.length >= 3) lower.substring(lower.length - 3),
      lower.substring(lower.length - 2),
    ];

    for (final maxRank in const [5000, 30000, 150000]) {
      for (final suffix in suffixes) {
        final rows = await customSelect(
          '''
          SELECT headword FROM entries
          WHERE frequency_rank <= ? AND id != ? AND headword LIKE ? AND headword != ?
            AND headword NOT GLOB '*[^a-z]*'
          ORDER BY frequency_rank
          LIMIT 8
          ''',
          variables: [
            Variable.withInt(maxRank),
            Variable.withInt(excludeEntryId),
            Variable.withString('%$suffix'),
            Variable.withString(lower),
          ],
        ).get();
        final candidates = rows.map((r) => r.read<String>('headword')).toSet().toList();
        if (candidates.isNotEmpty) {
          candidates.shuffle(Random());
          return candidates.first;
        }
      }
    }
    return null;
  }

  /// Grabs a handful of unrelated, plausibly-sized glosses to use as wrong
  /// answers in the study session's "which definition is right?" mini
  /// exercise — never [excludeGloss] itself, and length-capped so a
  /// three-option row stays compact.
  ///
  /// Picks random `rowid`s and does one indexed batch lookup rather than
  /// `ORDER BY RANDOM() LIMIT n`, which over senses' 700k+ rows means a
  /// full-table sort — measured at several seconds, far too slow for an
  /// exercise that's supposed to appear instantly under a flipped card.
  /// Candidates are fetched in a single `WHERE rowid IN (...)` round trip
  /// (oversampled to absorb filtered-out rows) instead of one query per
  /// candidate — on a slow/contended disk, a dozen-plus sequential
  /// round trips each waiting on their own I/O was itself enough to stall
  /// the UI isolate for several seconds.
  Future<List<String>> randomGlosses({
    required int excludeEntryId,
    required String excludeGloss,
    int count = 2,
  }) async {
    final rangeRow =
        await customSelect('SELECT MIN(rowid) AS lo, MAX(rowid) AS hi FROM senses').getSingleOrNull();
    if (rangeRow == null) return const [];
    final lo = rangeRow.read<int>('lo');
    final hi = rangeRow.read<int>('hi');
    if (hi < lo) return const [];

    final rand = Random();
    final span = hi - lo + 1;
    final sampleSize = (count * 8).clamp(1, span);
    final candidateRowids = <int>{};
    while (candidateRowids.length < sampleSize) {
      candidateRowids.add(lo + rand.nextInt(span));
    }

    final placeholders = candidateRowids.map((_) => '?').join(',');
    final rows = await customSelect(
      'SELECT gloss, entry_id FROM senses WHERE rowid IN ($placeholders)',
      variables: candidateRowids.map(Variable.withInt).toList(),
    ).get();

    final seen = <String>{excludeGloss};
    final result = <String>[];
    for (final row in rows) {
      if (result.length >= count) break;
      final gloss = row.readNullable<String>('gloss');
      final entryId = row.read<int>('entry_id');
      if (gloss == null || entryId == excludeEntryId) continue;
      if (gloss.length < 6 || gloss.length > 70) continue;
      if (!seen.add(gloss)) continue;
      result.add(gloss);
    }
    return result;
  }

  /// Example sentences belonging to *other* words, with their own headword
  /// blanked out — the wrong answers in the study session's "which sentence
  /// is it?" game, where a blanked sentence that genuinely belongs to some
  /// other word is a far better distractor than an invented one.
  ///
  /// Same random-rowid sampling trick as [randomGlosses], and for the same
  /// reason: `ORDER BY RANDOM()` over the examples table is a full-table
  /// sort, measured in seconds. Oversampled hard here because most candidate
  /// rows get thrown away — a usable one has to pass [isQuizExample] for
  /// its own headword (a real, modern sentence with the word in it and no
  /// inflected form left standing beside the gap) and be short enough to
  /// sit three to a screen.
  ///
  /// [excludeHeadword], when given, is the word the game is really about:
  /// a distractor whose gap could take that word — or which mentions it in
  /// any form — is not a wrong answer.
  Future<List<String>> randomBlankedExamples({
    required int excludeEntryId,
    String? excludeHeadword,
    int count = 2,
    int maxLength = 120,
  }) async {
    final rangeRow =
        await customSelect('SELECT MIN(rowid) AS lo, MAX(rowid) AS hi FROM examples').getSingleOrNull();
    if (rangeRow == null) return const [];
    final lo = rangeRow.readNullable<int>('lo');
    final hi = rangeRow.readNullable<int>('hi');
    if (lo == null || hi == null || hi < lo) return const [];

    final rand = Random();
    final span = hi - lo + 1;
    final sampleSize = (count * 30).clamp(1, span);
    final candidateRowids = <int>{};
    while (candidateRowids.length < sampleSize) {
      candidateRowids.add(lo + rand.nextInt(span));
    }

    final placeholders = candidateRowids.map((_) => '?').join(',');
    final rows = await customSelect(
      '''
      SELECT x.text, x.source, e.id AS entry_id, e.headword
      FROM examples x
      JOIN senses s ON s.id = x.sense_id
      JOIN entries e ON e.id = s.entry_id
      WHERE x.rowid IN ($placeholders)
      ''',
      variables: candidateRowids.map(Variable.withInt).toList(),
    ).get();

    final result = <String>[];
    for (final row in rows) {
      if (result.length >= count) break;
      if (row.read<int>('entry_id') == excludeEntryId) continue;
      final text = row.read<String>('text').trim();
      if (text.length > maxLength) continue;
      final headword = row.read<String>('headword');
      if (!isQuizExample(headword, text, source: row.readNullable<String>('source'))) continue;
      if (excludeHeadword != null && giveawayPattern(excludeHeadword).hasMatch(text)) continue;
      result.add(blankHeadword(headword, text));
    }
    return result;
  }

  /// Whether this build of the dictionary carries `examples_fts`. Checked
  /// once: the index is newer than the schema, and a dictionary.db built
  /// before it existed still has to work — it just falls back to the random
  /// sample.
  Future<bool> get _hasExamplesFts async => _examplesFtsPresent ??= (await customSelect(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'examples_fts'",
      ).get())
          .isNotEmpty;
  bool? _examplesFtsPresent;

  /// Function words and the like — what's left of a sentence after these
  /// go is what it's *about*, and that is what the distractor search keys
  /// on. Deliberately short; the FTS ranking does the fine work.
  static const _stopwords = {
    'a', 'an', 'the', 'and', 'or', 'but', 'of', 'to', 'in', 'on', 'at', 'by', 'for', 'with',
    'from', 'as', 'is', 'are', 'was', 'were', 'be', 'been', 'being', 'it', 'its', 'this', 'that',
    'these', 'those', 'he', 'she', 'they', 'them', 'his', 'her', 'their', 'we', 'our', 'you',
    'your', 'i', 'my', 'me', 'him', 'us', 'not', 'no', 'so', 'if', 'then', 'than', 'too',
    'very', 'can', 'could', 'would', 'should', 'will', 'shall', 'may', 'might', 'do', 'does',
    'did', 'have', 'has', 'had', 'into', 'out', 'up', 'down', 'over', 'about', 'there', 'here',
    'when', 'where', 'which', 'who', 'what', 'how', 'all', 'any', 'some', 'one', 'more',
    'most', 'other', 'such', 'only', 'own', 'same', 'just', 'also', 'said', 'says', 'like',
  };

  /// Blanked sentences from other words that are **about the same things**
  /// as [text] — sharing its content words, ranked by FTS5's bm25 — so the
  /// "which sentence wants this word?" game can't be won on topic alone.
  ///
  /// Rows from the same entry are skipped, and so is anything that wouldn't
  /// pass [randomBlankedExamples]'s own filters — including any sentence
  /// that mentions [excludeHeadword] in any form. Returns fewer than
  /// [count] when the index turns up nothing usable; the caller tops up at
  /// random.
  Future<List<String>> similarBlankedExamples(
    String text, {
    required int excludeEntryId,
    required String excludeHeadword,
    int count = 2,
    int maxLength = 120,
  }) async {
    if (!await _hasExamplesFts) return const [];
    final headwordLower = excludeHeadword.toLowerCase();
    final terms = <String>{};
    for (final m in RegExp(r"[a-zA-Z][a-zA-Z'-]{2,}").allMatches(text)) {
      final w = m.group(0)!.toLowerCase().replaceAll("'", '');
      if (w.length < 3 || _stopwords.contains(w) || w == headwordLower) continue;
      if (headwordLower.contains(w) || w.contains(headwordLower)) continue;
      terms.add(w);
    }
    if (terms.isEmpty) return const [];
    // Each term quoted so punctuation inside a word can't break the query;
    // OR'd so a sentence sharing any of them ranks, more shared ranking
    // higher.
    final query = terms.take(12).map((t) => '"${t.replaceAll('"', '')}"').join(' OR ');

    final rows = await customSelect(
      '''
      SELECT x.text, x.source, e.id AS entry_id, e.headword
      FROM examples_fts f
      JOIN examples x ON x.id = f.rowid
      JOIN senses s ON s.id = x.sense_id
      JOIN entries e ON e.id = s.entry_id
      WHERE examples_fts MATCH ? AND length(x.text) BETWEEN 20 AND ?
      ORDER BY bm25(examples_fts)
      LIMIT 80
      ''',
      variables: [Variable.withString(query), Variable.withInt(maxLength)],
    ).get();

    final result = <String>[];
    final usedEntries = <int>{excludeEntryId};
    final target = giveawayPattern(excludeHeadword);
    for (final row in rows) {
      if (result.length >= count) break;
      final entryId = row.read<int>('entry_id');
      if (usedEntries.contains(entryId)) continue;
      final candidate = row.read<String>('text').trim();
      if (candidate.length > maxLength) continue;
      if (candidate == text.trim()) continue;
      final headword = row.read<String>('headword');
      if (!isQuizExample(headword, candidate, source: row.readNullable<String>('source'))) continue;
      // A distractor whose blank could take *our* word is not a wrong
      // answer, so the target must not appear in it in any form.
      if (target.hasMatch(candidate)) continue;
      usedEntries.add(entryId);
      result.add(blankHeadword(headword, candidate));
    }
    return result;
  }

  /// A pool of possible clue phrasings per entry, restricted to each
  /// entry's earliest (most common) senses — see [_maxSenseOrderForClue] —
  /// so a random pick can't land on some obscure tail meaning. Three clue
  /// styles come out of this, matching real crossword conventions: a plain
  /// definition, a synonym (from "Synonym of X" glosses, rewritten to drop
  /// the "Synonym of" framing), "___, for short" (from "Abbreviation/
  /// Initialism/Acronym of X" glosses), and a fill-in-the-blank version of
  /// any example sentence that actually contains the headword.
  Future<Map<int, List<String>>> crosswordClueOptions(Map<int, String> headwordsByEntryId) async {
    if (headwordsByEntryId.isEmpty) return {};
    final entryIds = headwordsByEntryId.keys.toList();
    final placeholders = entryIds.map((_) => '?').join(',');

    final senseRows = await customSelect(
      'SELECT id, entry_id, gloss FROM senses '
      'WHERE entry_id IN ($placeholders) AND gloss IS NOT NULL AND sense_order <= $_maxSenseOrderForClue',
      variables: entryIds.map(Variable.withInt).toList(),
    ).get();

    final senseIds = senseRows.map((r) => r.read<int>('id')).toList();
    final examplesBySense = <int, List<String>>{};
    if (senseIds.isNotEmpty) {
      final sensePlaceholders = senseIds.map((_) => '?').join(',');
      final exampleRows = await customSelect(
        'SELECT sense_id, text, source FROM examples WHERE sense_id IN ($sensePlaceholders)',
        variables: senseIds.map(Variable.withInt).toList(),
      ).get();
      for (final r in exampleRows) {
        if (!isModernCitation(r.readNullable<String>('source'))) continue;
        examplesBySense.putIfAbsent(r.read<int>('sense_id'), () => []).add(r.read<String>('text'));
      }
    }

    // Some technical/scientific senses only have a genuinely multi-sentence
    // definition available (e.g. the bundled data's "aurora" gloss runs four
    // sentences) — worse as a clue than a short one, but still better than
    // the generic length-based fallback, so long options are kept separately
    // and only surface for an entry that has nothing shorter.
    const maxClueLength = 100;
    final result = <int, List<String>>{};
    final longOptions = <int, List<String>>{};
    for (final row in senseRows) {
      final entryId = row.read<int>('entry_id');
      final headword = headwordsByEntryId[entryId];
      if (headword == null) continue;
      final options = result.putIfAbsent(entryId, () => []);
      final gloss = row.read<String>('gloss').trim();
      if (gloss.isNotEmpty) {
        // Abbreviation/clipping clues are exempt from the leak check by
        // design (see _abbreviationGloss); anything else is checked.
        final abbrevClue = _abbreviationClue(gloss);
        final clue = abbrevClue ?? _synonymOrDefinitionClue(gloss);
        if (abbrevClue != null || !_leaksAnswer(clue, headword)) {
          if (clue.length <= maxClueLength) {
            options.add(clue);
          } else {
            longOptions.putIfAbsent(entryId, () => []).add(clue);
          }
        }
      }

      final wordPattern = headwordPattern(headword);
      for (final example in examplesBySense[row.read<int>('id')] ?? const <String>[]) {
        // Wiktionary examples range from a short invented sentence to a full
        // quoted paragraph from a novel (seen in the bundled data: a
        // 400+-character Kensington-society passage) — the latter reads
        // fine as a citation but is unusable as a crossword clue, which
        // needs to fit on one line like every other clue style here.
        if (example.length > maxClueLength) continue;
        if (!wordPattern.hasMatch(example)) continue;
        // "The train _____ along the tracks, thundering…" — an inflected
        // form left beside the gap hands the solver the answer.
        if (leaksHeadword(headword, example)) continue;
        options.add(blankHeadword(headword, example));
      }
    }
    longOptions.forEach((entryId, clues) {
      if (result[entryId] == null || result[entryId]!.isEmpty) {
        result[entryId] = clues;
      }
    });
    return result;
  }

  /// Loads every (headword, pos) row for [headword] and merges them into one
  /// [WordEntry] — the unit the Entry Detail screen renders. The best-ranked
  /// row (lowest frequency_rank) becomes `canonicalEntryId`, the single id
  /// this word uses for studying, listing, and notes.
  Future<WordEntry?> loadWord(String headword) async {
    final entryRows = await customSelect(
      '''
      SELECT id, pos, etymology FROM entries
      WHERE headword = ?
      ORDER BY (frequency_rank IS NULL), frequency_rank, pos
      ''',
      variables: [Variable.withString(headword)],
    ).get();
    if (entryRows.isEmpty) return null;

    final ids = entryRows.map((r) => r.read<int>('id')).toList();
    final placeholders = ids.map((_) => '?').join(',');
    final idVars = ids.map(Variable.withInt).toList();

    final pronRows = await customSelect(
      'SELECT entry_id, ipa FROM pronunciations WHERE entry_id IN ($placeholders)',
      variables: idVars,
    ).get();
    final ipaByEntry = {
      for (final r in pronRows) r.read<int>('entry_id'): r.readNullable<String>('ipa'),
    };

    final senseRows = await customSelect(
      '''
      SELECT id, entry_id, gloss, sense_order FROM senses
      WHERE entry_id IN ($placeholders)
      ORDER BY entry_id, sense_order
      ''',
      variables: idVars,
    ).get();
    final senseIds = senseRows.map((r) => r.read<int>('id')).toList();

    final examplesBySense = <int, List<Example>>{};
    if (senseIds.isNotEmpty) {
      final sensePlaceholders = senseIds.map((_) => '?').join(',');
      final exampleRows = await customSelect(
        'SELECT id, sense_id, text, source FROM examples WHERE sense_id IN ($sensePlaceholders)',
        variables: senseIds.map(Variable.withInt).toList(),
      ).get();
      for (final r in exampleRows) {
        examplesBySense.putIfAbsent(r.read<int>('sense_id'), () => []).add(
              Example(
                id: r.read<int>('id'),
                text: r.read<String>('text'),
                source: r.readNullable<String>('source'),
              ),
            );
      }
    }

    final formRows = await customSelect(
      'SELECT DISTINCT form_text, form_type FROM forms WHERE entry_id IN ($placeholders)',
      variables: idVars,
    ).get();

    final posOrder = <String>[];
    final sensesByPos = <String, List<Sense>>{};
    for (final er in entryRows) {
      final pos = er.read<String>('pos');
      final entryId = er.read<int>('id');
      final group = sensesByPos.putIfAbsent(pos, () {
        posOrder.add(pos);
        return [];
      });
      for (final sr in senseRows.where((r) => r.read<int>('entry_id') == entryId)) {
        final sid = sr.read<int>('id');
        group.add(Sense(
          id: sid,
          gloss: sr.read<String>('gloss'),
          order: sr.read<int>('sense_order'),
          examples: examplesBySense[sid] ?? const [],
        ));
      }
    }

    String? ipa;
    for (final id in ids) {
      if (ipaByEntry[id] != null) {
        ipa = ipaByEntry[id];
        break;
      }
    }
    String? etymology;
    for (final er in entryRows) {
      final e = er.readNullable<String>('etymology');
      if (e != null && e.trim().isNotEmpty) {
        etymology = e;
        break;
      }
    }

    return WordEntry(
      canonicalEntryId: ids.first,
      headword: headword,
      pronunciation: Pronunciation(ipa: ipa),
      etymology: etymology,
      posGroups: [
        for (final pos in posOrder) PosSenses(pos: pos, senses: sensesByPos[pos]!),
      ],
      forms: formRows
          .map((r) => WordForm(
                formText: r.read<String>('form_text'),
                formType: r.read<String>('form_type'),
              ))
          .toList(),
    );
  }
}
