import 'package:drift/drift.dart';

import '../../domain/models/entry.dart';
import '../../domain/models/slang.dart';
import '../user/user_database.dart';

/// A headword that's already taken by another slang word.
class SlangHeadwordTakenException implements Exception {
  final String headword;
  const SlangHeadwordTakenException(this.headword);
  @override
  String toString() => '"$headword" is already in your Slang Stack.';
}

/// The Slang Stack: the person's own words and meanings — see
/// `domain/models/slang.dart` for how they join the dictionary's.
class SlangRepository {
  final UserDatabase _db;

  SlangRepository(this._db);

  /// Every table a slang word is spread across — what a watcher of any of
  /// it has to declare it reads from.
  Set<TableInfo> get tables => {_db.slangWords, _db.slangSenses, _db.slangExamples, _db.slangForms};

  // -------------------------------------------------------------------
  // Reading
  // -------------------------------------------------------------------

  /// The whole stack, most recently added or edited first.
  Stream<List<SlangWord>> watchStack() {
    return (_db.select(_db.slangWords)..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
        .watch()
        .asyncMap(_hydrate);
  }

  /// The whole stack, once — for a backup.
  Future<List<SlangWord>> all() async => _hydrate(await _db.select(_db.slangWords).get());

  Future<SlangWord?> byId(int id) async {
    final row = await (_db.select(_db.slangWords)..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : (await _hydrate([row])).single;
  }

  /// The slang word filed under exactly [headword].
  Future<SlangWord?> byHeadword(String headword) async {
    final row = await (_db.select(_db.slangWords)..where((t) => t.headword.equals(headword)))
        .getSingleOrNull();
    return row == null ? null : (await _hydrate([row])).single;
  }

  /// The slang word [text] is another spelling or a form of, if any.
  Future<SlangWord?> byForm(String text) async {
    final form = await (_db.select(_db.slangForms)
          ..where((t) => t.formText.equals(text))
          ..limit(1))
        .getSingleOrNull();
    return form == null ? null : byId(form.wordId);
  }

  /// Slang words whose headword, spelling or form starts with [query] —
  /// the Search tab's share. The headword that *is* the query comes first,
  /// the way the dictionary's search orders it.
  Future<List<EntrySummary>> search(String query, {int limit = 10}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    final like = '${trimmed.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_')}%';
    final rows = await _db.customSelect(
      '''
      SELECT w.id, w.headword,
        (SELECT pos FROM slang_senses s WHERE s.word_id = w.id ORDER BY sense_order LIMIT 1) AS pos,
        (SELECT gloss FROM slang_senses s WHERE s.word_id = w.id ORDER BY sense_order LIMIT 1) AS gloss,
        (SELECT form_text FROM slang_forms f
           WHERE f.word_id = w.id AND f.form_text LIKE ? ESCAPE '\\' LIMIT 1) AS matched_form
      FROM slang_words w
      WHERE w.headword LIKE ? ESCAPE '\\'
         OR EXISTS (SELECT 1 FROM slang_forms f WHERE f.word_id = w.id AND f.form_text LIKE ? ESCAPE '\\')
      ORDER BY (w.headword = ? COLLATE NOCASE) DESC, (w.headword LIKE ? ESCAPE '\\') DESC, w.headword
      LIMIT ?
      ''',
      variables: [
        Variable.withString(like),
        Variable.withString(like),
        Variable.withString(like),
        Variable.withString(trimmed),
        Variable.withString(like),
        Variable.withInt(limit),
      ],
      readsFrom: tables,
    ).get();
    return [
      for (final r in rows)
        EntrySummary(
          id: r.read<int>('id'),
          headword: r.read<String>('headword'),
          pos: r.readNullable<String>('pos') ?? 'slang',
          gloss: r.readNullable<String>('gloss'),
          // Only worth saying when the headword itself didn't match.
          matchedForm: r.read<String>('headword').toLowerCase().startsWith(trimmed.toLowerCase())
              ? null
              : r.readNullable<String>('matched_form'),
          slang: true,
        ),
    ];
  }

  /// Crossword clue candidates from the person's own meanings, per entry
  /// id in [entryIds] — the same shape as the dictionary's
  /// `crosswordClueOptions`. An id may be a slang word's own or a
  /// dictionary word the person added a meaning to. A plain-English
  /// equivalent makes the best clue (it's exactly a synonym clue), then
  /// the meaning itself, then any example with the word blanked out.
  Future<Map<int, List<String>>> clueOptions(Iterable<int> entryIds) async {
    final result = <int, List<String>>{};
    for (final entryId in entryIds) {
      final SlangWord? word;
      if (isSlangId(entryId)) {
        word = await byId(entryId);
      } else {
        final row = await _db.customSelect(
          'SELECT headword FROM dict.entries WHERE id = ?',
          variables: [Variable.withInt(entryId)],
        ).getSingleOrNull();
        word = row == null ? null : await byHeadword(row.read<String>('headword'));
      }
      if (word == null || word.senses.isEmpty) continue;
      final options = <String>[];
      for (final sense in word.senses) {
        final plain = sense.plainEnglish?.trim();
        if (plain != null && plain.isNotEmpty) options.add(_capitalize(plain));
        options.add(sense.gloss);
      }
      for (final sense in word.senses) {
        for (final example in sense.examples) {
          final blanked = example.replaceAll(
            RegExp('\\b${RegExp.escape(word.headword)}\\b', caseSensitive: false),
            '___',
          );
          if (blanked != example && blanked.length <= 100) options.add(blanked);
        }
      }
      // Giveaways (the answer in its own clue) are the caller's to filter,
      // as they are for the dictionary's options.
      result[entryId] = options;
    }
    return result;
  }

  static String _capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  Future<List<SlangWord>> _hydrate(List<SlangWordRow> words) async {
    if (words.isEmpty) return const [];
    final ids = words.map((w) => w.id).toList();
    final senses = await (_db.select(_db.slangSenses)
          ..where((t) => t.wordId.isIn(ids))
          ..orderBy([(t) => OrderingTerm.asc(t.senseOrder), (t) => OrderingTerm.asc(t.id)]))
        .get();
    final senseIds = senses.map((s) => s.id).toList();
    final examples = senseIds.isEmpty
        ? const <SlangExampleRow>[]
        : await (_db.select(_db.slangExamples)
              ..where((t) => t.senseId.isIn(senseIds))
              ..orderBy([(t) => OrderingTerm.asc(t.id)]))
            .get();
    final forms = await (_db.select(_db.slangForms)..where((t) => t.wordId.isIn(ids))).get();

    return [
      for (final w in words)
        SlangWord(
          id: w.id,
          headword: w.headword,
          sayItLike: w.sayItLike,
          region: w.region,
          scene: w.scene,
          freshness: SlangFreshness.fromStorageKey(w.freshness),
          heardAt: w.heardAt,
          origin: w.origin,
          createdAt: w.createdAt,
          updatedAt: w.updatedAt,
          spellings: [
            for (final f in forms)
              if (f.wordId == w.id && f.formType == 'spelling') f.formText,
          ],
          forms: [
            for (final f in forms)
              if (f.wordId == w.id && f.formType == 'form') f.formText,
          ],
          senses: [
            for (final s in senses)
              if (s.wordId == w.id)
                SlangSense(
                  id: s.id,
                  pos: s.pos,
                  gloss: s.gloss,
                  plainEnglish: s.plainEnglish,
                  tone: SlangTone.fromStorageKey(s.tone),
                  examples: [
                    for (final x in examples)
                      if (x.senseId == s.id) x.sentence,
                  ],
                ),
          ],
        ),
    ];
  }

  // -------------------------------------------------------------------
  // Writing
  // -------------------------------------------------------------------

  /// Saves [word] — a new one when its id is null — and returns it as
  /// stored, ids filled in.
  ///
  /// A meaning that already has an id keeps it, so a pin on it in
  /// `study_senses` survives the edit; a meaning dropped from [word] goes,
  /// and so does any pin or exclusion on it. Examples, spellings and forms
  /// are replaced wholesale — nothing else points at them.
  ///
  /// Throws [SlangHeadwordTakenException] if another slang word already
  /// has [word]'s headword.
  Future<SlangWord> save(SlangWord word) async {
    final headword = word.headword.trim();
    final id = await _db.transaction(() async {
      final clash = await (_db.select(_db.slangWords)..where((t) => t.headword.equals(headword)))
          .getSingleOrNull();
      if (clash != null && clash.id != word.id) throw SlangHeadwordTakenException(headword);

      final now = DateTime.now();
      final fields = SlangWordsCompanion(
        headword: Value(headword),
        sayItLike: Value(_clean(word.sayItLike)),
        region: Value(_clean(word.region)),
        scene: Value(_clean(word.scene)),
        freshness: Value(word.freshness?.storageKey),
        heardAt: Value(_clean(word.heardAt)),
        origin: Value(_clean(word.origin)),
        updatedAt: Value(now),
      );
      final int id;
      if (word.id == null) {
        id = await _nextId('slang_words');
        await _db.into(_db.slangWords).insert(
              fields.copyWith(id: Value(id), createdAt: Value(word.createdAt ?? now)),
            );
      } else {
        id = word.id!;
        await (_db.update(_db.slangWords)..where((t) => t.id.equals(id))).write(fields);
      }

      // Meanings: keep the ids of the ones still here, drop the rest.
      final existing = await (_db.select(_db.slangSenses)..where((t) => t.wordId.equals(id))).get();
      final kept = {for (final s in word.senses) if (s.id != null) s.id!};
      final dropped = [for (final s in existing) if (!kept.contains(s.id)) s.id];
      await _deleteSenses([for (final s in existing) s.id], examplesOnly: true);
      await _deleteSenses(dropped);

      var nextSenseId = await _nextId('slang_senses');
      var nextExampleId = await _nextId('slang_examples');
      for (final (order, sense) in word.senses.where((s) => s.gloss.trim().isNotEmpty).indexed) {
        final senseId = sense.id ?? nextSenseId++;
        await _db.into(_db.slangSenses).insertOnConflictUpdate(
              SlangSensesCompanion.insert(
                id: Value(senseId),
                wordId: id,
                pos: sense.pos,
                gloss: sense.gloss.trim(),
                plainEnglish: Value(_clean(sense.plainEnglish)),
                tone: Value(sense.tone?.storageKey),
                senseOrder: order,
              ),
            );
        for (final example in sense.examples) {
          final text = example.trim();
          if (text.isEmpty) continue;
          await _db.into(_db.slangExamples).insert(
                SlangExamplesCompanion.insert(id: Value(nextExampleId++), senseId: senseId, sentence: text),
              );
        }
      }

      await (_db.delete(_db.slangForms)..where((t) => t.wordId.equals(id))).go();
      final seen = <String>{headword};
      for (final (type, texts) in [('spelling', word.spellings), ('form', word.forms)]) {
        for (final text in texts) {
          final t = text.trim();
          if (t.isEmpty || !seen.add(t)) continue;
          await _db.into(_db.slangForms).insert(
                SlangFormsCompanion.insert(wordId: id, formText: t, formType: type),
              );
        }
      }
      return id;
    });
    return (await byId(id))!;
  }

  /// Removes a word from the Slang Stack along with its meanings.
  ///
  /// When the dictionary doesn't have the word, the slang word *was* the
  /// word: its study cards and their history, its list memberships and its
  /// notes go too, since nothing could ever show them again. A dictionary
  /// word just loses the person's own meanings and goes back to being the
  /// dictionary's.
  Future<void> delete(int id) async {
    await _db.transaction(() async {
      final senses = await (_db.select(_db.slangSenses)..where((t) => t.wordId.equals(id))).get();
      await _deleteSenses([for (final s in senses) s.id]);
      await (_db.delete(_db.slangForms)..where((t) => t.wordId.equals(id))).go();
      await (_db.delete(_db.slangWords)..where((t) => t.id.equals(id))).go();

      final cards = await (_db.select(_db.studyCards)..where((t) => t.entryId.equals(id))).get();
      final cardIds = [for (final c in cards) c.id];
      await (_db.delete(_db.reviewLog)..where((t) => t.cardId.isIn(cardIds))).go();
      await (_db.delete(_db.studyCards)..where((t) => t.entryId.equals(id))).go();
      await (_db.delete(_db.studySenses)..where((t) => t.entryId.equals(id))).go();
      await (_db.delete(_db.listItems)..where((t) => t.entryId.equals(id))).go();
      await (_db.delete(_db.entryNotes)..where((t) => t.entryId.equals(id))).go();
    });
  }

  /// Deletes [senseIds]' examples and, unless [examplesOnly], the senses
  /// themselves and every pin or exclusion naming them.
  Future<void> _deleteSenses(List<int> senseIds, {bool examplesOnly = false}) async {
    if (senseIds.isEmpty) return;
    await (_db.delete(_db.slangExamples)..where((t) => t.senseId.isIn(senseIds))).go();
    if (examplesOnly) return;
    await (_db.delete(_db.studySenses)..where((t) => t.senseId.isIn(senseIds))).go();
    await (_db.delete(_db.slangSenses)..where((t) => t.id.isIn(senseIds))).go();
  }

  /// The next id for [table], never below [slangIdBase] and never one
  /// handed out before — the tables are AUTOINCREMENT, so `sqlite_sequence`
  /// remembers the highest id ever used even after its row is gone.
  Future<int> _nextId(String table) async {
    final row = await _db.customSelect(
      'SELECT MAX(COALESCE((SELECT seq FROM sqlite_sequence WHERE name = ?), 0), '
      '           COALESCE((SELECT MAX(id) FROM $table), 0)) AS m',
      variables: [Variable.withString(table)],
    ).getSingle();
    final max = row.read<int>('m');
    return max < slangIdBase ? slangIdBase : max + 1;
  }

  static String? _clean(String? s) {
    final t = s?.trim();
    return t == null || t.isEmpty ? null : t;
  }
}
