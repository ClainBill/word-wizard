import 'package:drift/drift.dart';

import '../../domain/models/slang.dart';
import '../user/user_database.dart';
import 'slang_repository.dart';

/// What a backup file holds, for the confirmation before restoring it.
typedef BackupSummary = ({
  int lists,
  int listWords,
  int studyWords,
  int cards,
  int reviews,
  int notes,
  int slangWords,
  DateTime? exportedAt,
});

/// What a restore did — including the words this dictionary doesn't have
/// (a backup made with a different dictionary build), which are skipped.
typedef RestoreResult = ({
  int lists,
  int listWords,
  int cards,
  int reviews,
  int notes,
  int slangWords,
  int skippedWords,
});

/// A file that isn't a Word Wizard backup, or is from a newer app.
class BackupFormatException implements Exception {
  final String message;
  const BackupFormatException(this.message);
  @override
  String toString() => message;
}

/// Backs up and restores the things a person builds by hand and can't get
/// back otherwise: their lists (with folders and per-list notes), their
/// study cards with every review behind them, the meanings they pinned or
/// excluded, their notes on words, and their Slang Stack — every word and
/// meaning they wrote themselves, which no dictionary can give back.
/// Puzzles, reading history and
/// settings aren't included — they're either regenerated daily or cheap to
/// redo.
///
/// Words are keyed by dictionary entry id, and each id travels with its
/// headword. A dictionary rebuild can renumber entries, so on restore an id
/// that no longer names the same headword is resolved again by headword;
/// pinned meanings are matched by their gloss the same way. Slang words
/// are restored first and get new ids on this device, and the same
/// headword rule maps everything that pointed at them.
///
/// The format is plain JSON and versioned ([formatVersion]); a restore
/// refuses a file from a newer version rather than half-reading it.
class BackupRepository {
  final UserDatabase _db;

  BackupRepository(this._db);

  static const format = 'word-wizard-backup';
  /// 2 added the Slang Stack. A version-1 file still restores; a
  /// version-1 app refuses a version-2 file rather than silently dropping
  /// the person's own words.
  static const formatVersion = 2;

  // -------------------------------------------------------------------
  // Export
  // -------------------------------------------------------------------

  Future<Map<String, dynamic>> export({required String appVersion, DateTime? now}) async {
    final slang = await SlangRepository(_db).all();
    final lists = await _db.select(_db.lists).get();
    final items = await _db.select(_db.listItems).get();
    final cards = await _db.select(_db.studyCards).get();
    final reviews = await _db.select(_db.reviewLog).get();
    final senses = await _db.select(_db.studySenses).get();
    final notes = await _db.select(_db.entryNotes).get();

    final entryIds = <int>{
      for (final i in items) i.entryId,
      for (final c in cards) c.entryId,
      for (final s in senses) s.entryId,
      for (final n in notes) n.entryId,
    };
    final headwords = await _headwords(entryIds);
    final glosses = await _glosses({for (final s in senses) s.senseId});

    return {
      'format': format,
      'version': formatVersion,
      'app': appVersion,
      'exportedAt': (now ?? DateTime.now()).toUtc().toIso8601String(),
      'entries': {for (final id in entryIds) '$id': headwords[id]},
      'lists': [
        for (final l in lists)
          {
            'id': l.id,
            'name': l.name,
            'kind': l.kind,
            'parentId': l.parentId,
            'createdAt': l.createdAt.toUtc().toIso8601String(),
          },
      ],
      'listItems': [
        for (final i in items)
          {
            'listId': i.listId,
            'entryId': i.entryId,
            'note': i.note,
            'addedAt': i.addedAt.toUtc().toIso8601String(),
          },
      ],
      'studyCards': [
        for (final c in cards)
          {
            'id': c.id,
            'entryId': c.entryId,
            'direction': c.direction,
            'repetitions': c.repetitions,
            'easeFactor': c.easeFactor,
            'intervalDays': c.intervalDays,
            'dueAt': c.dueAt.toUtc().toIso8601String(),
            'createdAt': c.createdAt.toUtc().toIso8601String(),
            'paused': c.paused,
          },
      ],
      'reviews': [
        for (final r in reviews)
          {
            'cardId': r.cardId,
            'reviewedAt': r.reviewedAt.toUtc().toIso8601String(),
            'grade': r.grade,
            'priorInterval': r.priorInterval,
            'durationMs': r.durationMs,
          },
      ],
      'senses': [
        for (final s in senses)
          {'entryId': s.entryId, 'senseId': s.senseId, 'excluded': s.excluded, 'gloss': glosses[s.senseId]},
      ],
      'notes': [
        for (final n in notes)
          {'entryId': n.entryId, 'markdown': n.markdown, 'updatedAt': n.updatedAt.toUtc().toIso8601String()},
      ],
      'slang': [for (final w in slang) _slangToJson(w)],
    };
  }

  static Map<String, dynamic> _slangToJson(SlangWord w) => {
        'id': w.id,
        'headword': w.headword,
        'sayItLike': w.sayItLike,
        'spellings': w.spellings,
        'forms': w.forms,
        'region': w.region,
        'scene': w.scene,
        'freshness': w.freshness?.storageKey,
        'heardAt': w.heardAt,
        'origin': w.origin,
        'createdAt': w.createdAt?.toUtc().toIso8601String(),
        'senses': [
          for (final s in w.senses)
            {
              'id': s.id,
              'pos': s.pos,
              'gloss': s.gloss,
              'plainEnglish': s.plainEnglish,
              'tone': s.tone?.storageKey,
              'examples': s.examples,
            },
        ],
      };

  static SlangWord _slangFromJson(Map<String, dynamic> j, DateTime now) => SlangWord(
        headword: (j['headword'] as String).trim(),
        sayItLike: j['sayItLike'] as String?,
        spellings: [for (final s in j['spellings'] as List? ?? const []) '$s'],
        forms: [for (final s in j['forms'] as List? ?? const []) '$s'],
        region: j['region'] as String?,
        scene: j['scene'] as String?,
        freshness: SlangFreshness.fromStorageKey(j['freshness'] as String?),
        heardAt: j['heardAt'] as String?,
        origin: j['origin'] as String?,
        createdAt: _date(j['createdAt'], now),
        senses: [
          for (final raw in j['senses'] as List? ?? const [])
            if (raw is Map && raw['gloss'] is String)
              SlangSense(
                pos: raw['pos'] as String? ?? 'noun',
                gloss: raw['gloss'] as String,
                plainEnglish: raw['plainEnglish'] as String?,
                tone: SlangTone.fromStorageKey(raw['tone'] as String?),
                examples: [for (final x in raw['examples'] as List? ?? const []) '$x'],
              ),
        ],
      );

  Future<Map<int, String>> _headwords(Set<int> ids) async {
    if (ids.isEmpty) return {};
    final out = <int, String>{};
    // Chunked: SQLite caps the number of bound variables per statement.
    final list = ids.toList();
    for (var i = 0; i < list.length; i += 500) {
      final chunk = list.sublist(i, i + 500 > list.length ? list.length : i + 500);
      final rows = await _db.customSelect(
        'SELECT id, headword FROM dict.entries WHERE id IN (${List.filled(chunk.length, '?').join(',')})',
        variables: [for (final id in chunk) Variable.withInt(id)],
      ).get();
      for (final r in rows) {
        out[r.read<int>('id')] = r.read<String>('headword');
      }
      final slangRows = await _db.customSelect(
        'SELECT id, headword FROM slang_words WHERE id IN (${List.filled(chunk.length, '?').join(',')})',
        variables: [for (final id in chunk) Variable.withInt(id)],
      ).get();
      for (final r in slangRows) {
        out[r.read<int>('id')] = r.read<String>('headword');
      }
    }
    return out;
  }

  Future<Map<int, String>> _glosses(Set<int> senseIds) async {
    if (senseIds.isEmpty) return {};
    final out = <int, String>{};
    final list = senseIds.toList();
    for (var i = 0; i < list.length; i += 500) {
      final chunk = list.sublist(i, i + 500 > list.length ? list.length : i + 500);
      final rows = await _db.customSelect(
        'SELECT id, gloss FROM dict.senses WHERE id IN (${List.filled(chunk.length, '?').join(',')})',
        variables: [for (final id in chunk) Variable.withInt(id)],
      ).get();
      for (final r in rows) {
        out[r.read<int>('id')] = r.read<String>('gloss');
      }
      final slangRows = await _db.customSelect(
        'SELECT id, gloss FROM slang_senses WHERE id IN (${List.filled(chunk.length, '?').join(',')})',
        variables: [for (final id in chunk) Variable.withInt(id)],
      ).get();
      for (final r in slangRows) {
        out[r.read<int>('id')] = r.read<String>('gloss');
      }
    }
    return out;
  }

  // -------------------------------------------------------------------
  // Reading a file
  // -------------------------------------------------------------------

  /// Checks [json] is a backup this app can read, and says what's in it.
  static BackupSummary summarize(Object? json) {
    final map = _validate(json);
    final cards = _rows(map, 'studyCards');
    return (
      lists: _rows(map, 'lists').length,
      listWords: {for (final i in _rows(map, 'listItems')) i['entryId']}.length,
      studyWords: {for (final c in cards) c['entryId']}.length,
      cards: cards.length,
      reviews: _rows(map, 'reviews').length,
      notes: _rows(map, 'notes').length,
      slangWords: _rows(map, 'slang').length,
      exportedAt: DateTime.tryParse(map['exportedAt'] as String? ?? '')?.toLocal(),
    );
  }

  static Map<String, dynamic> _validate(Object? json) {
    if (json is! Map || json['format'] != format) {
      throw const BackupFormatException('That file isn\'t a Word Wizard backup.');
    }
    final version = json['version'];
    if (version is! int || version > formatVersion) {
      throw const BackupFormatException(
        'That backup was made by a newer version of Word Wizard. Update the app to restore it.',
      );
    }
    return Map<String, dynamic>.from(json);
  }

  static List<Map<String, dynamic>> _rows(Map<String, dynamic> map, String key) => [
    for (final r in map[key] as List? ?? const []) Map<String, dynamic>.from(r as Map),
  ];

  static DateTime _date(Object? value, DateTime fallback) =>
      value is String ? (DateTime.tryParse(value)?.toLocal() ?? fallback) : fallback;

  // -------------------------------------------------------------------
  // Restore
  // -------------------------------------------------------------------

  /// Restores [json] into this device's data.
  ///
  /// With [replace], this device's lists, study cards, reviews, pinned
  /// meanings and notes are cleared first, so the result is exactly the
  /// backup. Without it the backup is merged in: lists are matched by name
  /// within the same folder, list words and pins are added, a note is taken
  /// only where the device has none, and for a word studied on both sides
  /// the card that was reviewed most recently wins, with its own history.
  ///
  /// All or nothing: one transaction.
  Future<RestoreResult> restore(Object? json, {required bool replace}) async {
    final map = _validate(json);
    final entries = {
      for (final e in (map['entries'] as Map? ?? const {}).entries) int.parse('${e.key}'): e.value as String?,
    };
    final now = DateTime.now();

    Future<int> count(String table) async =>
        (await _db.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle()).read<int>('n');

    return _db.transaction(() async {
      if (replace) {
        await _db.delete(_db.reviewLog).go();
        await _db.delete(_db.studyCards).go();
        await _db.delete(_db.listItems).go();
        // Children before parents: the self-reference is a foreign key.
        await _db.customStatement('DELETE FROM lists');
        await _db.delete(_db.studySenses).go();
        await _db.delete(_db.entryNotes).go();
        await _db.delete(_db.slangExamples).go();
        await _db.delete(_db.slangSenses).go();
        await _db.delete(_db.slangForms).go();
        await _db.delete(_db.slangWords).go();
      }

      // ---- The Slang Stack, first: everything below that points at a
      // slang word or meaning finds it again by headword and gloss ----
      final slangBefore = await count('slang_words');
      final slangRepo = SlangRepository(_db);
      for (final raw in _rows(map, 'slang')) {
        if (raw['headword'] is! String || (raw['headword'] as String).trim().isEmpty) continue;
        final theirs = _slangFromJson(raw, now);
        final mine = await slangRepo.byHeadword(theirs.headword);
        if (mine == null) {
          await slangRepo.save(theirs);
          continue;
        }
        // Both sides have the word: keep this device's, and add what only
        // the backup knows — meanings by gloss, spellings, forms, and any
        // detail this device left blank.
        final glosses = {for (final s in mine.senses) s.gloss};
        await slangRepo.save(SlangWord(
          id: mine.id,
          headword: mine.headword,
          sayItLike: mine.sayItLike ?? theirs.sayItLike,
          spellings: {...mine.spellings, ...theirs.spellings}.toList(),
          forms: {...mine.forms, ...theirs.forms}.toList(),
          region: mine.region ?? theirs.region,
          scene: mine.scene ?? theirs.scene,
          freshness: mine.freshness ?? theirs.freshness,
          heardAt: mine.heardAt ?? theirs.heardAt,
          origin: mine.origin ?? theirs.origin,
          createdAt: mine.createdAt,
          senses: [...mine.senses, ...theirs.senses.where((s) => !glosses.contains(s.gloss))],
        ));
      }
      final resolved = await _resolveEntries(entries);

      // ---- Lists, parents first so every child finds its folder ----
      final backupLists = _rows(map, 'lists');
      final byId = {for (final l in backupLists) l['id'] as int: l};
      final newId = <int, int>{};
      Future<int?> place(int backupId, Set<int> visiting) async {
        if (newId.containsKey(backupId)) return newId[backupId];
        final l = byId[backupId];
        if (l == null || !visiting.add(backupId)) return null; // missing or a cycle
        final parent = l['parentId'] is int ? await place(l['parentId'] as int, visiting) : null;
        final name = l['name'] as String? ?? 'List';
        final kind = l['kind'] as String? ?? 'custom';
        final existing = replace
            ? null
            : await (_db.select(_db.lists)..where(
                  (t) =>
                      t.name.equals(name) &
                      t.kind.equals(kind) &
                      (parent == null ? t.parentId.isNull() : t.parentId.equals(parent)),
                ))
                .getSingleOrNull();
        final id =
            existing?.id ??
            await _db
                .into(_db.lists)
                .insert(
                  ListsCompanion.insert(
                    name: name,
                    kind: Value(kind),
                    parentId: Value(parent),
                    createdAt: Value(_date(l['createdAt'], now)),
                  ),
                );
        newId[backupId] = id;
        return id;
      }

      for (final id in byId.keys) {
        await place(id, {});
      }

      final listWordsBefore = await count('list_items');
      final skipped = <int>{};
      for (final i in _rows(map, 'listItems')) {
        final list = newId[i['listId']];
        final entry = resolved[i['entryId']];
        if (entry == null) skipped.add(i['entryId'] as int);
        if (list == null || entry == null) continue;
        await _db
            .into(_db.listItems)
            .insert(
              ListItemsCompanion.insert(
                listId: list,
                entryId: entry,
                note: Value(i['note'] as String?),
                addedAt: Value(_date(i['addedAt'], now)),
              ),
              mode: InsertMode.insertOrIgnore,
            );
      }

      // ---- Study cards and their reviews ----
      final reviewsByCard = <int, List<Map<String, dynamic>>>{};
      for (final r in _rows(map, 'reviews')) {
        (reviewsByCard[r['cardId'] as int] ??= []).add(r);
      }
      DateTime? lastReview(List<Map<String, dynamic>>? rs) => rs == null || rs.isEmpty
          ? null
          : rs.map((r) => _date(r['reviewedAt'], now)).reduce((a, b) => a.isAfter(b) ? a : b);

      var cards = 0;
      var reviews = 0;
      for (final c in _rows(map, 'studyCards')) {
        final entry = resolved[c['entryId']];
        if (entry == null) {
          skipped.add(c['entryId'] as int);
          continue;
        }
        final direction = c['direction'] as String? ?? 'w2m';
        final theirReviews = reviewsByCard[c['id']];
        final mine = await (_db.select(
          _db.studyCards,
        )..where((t) => t.entryId.equals(entry) & t.direction.equals(direction))).getSingleOrNull();
        if (mine != null) {
          final myReviews = await (_db.select(_db.reviewLog)..where((t) => t.cardId.equals(mine.id))).get();
          final myLast = myReviews.isEmpty
              ? null
              : myReviews.map((r) => r.reviewedAt).reduce((a, b) => a.isAfter(b) ? a : b);
          final theirLast = lastReview(theirReviews);
          // Keep this device's card unless the backup's was reviewed later.
          if (theirLast == null || (myLast != null && !theirLast.isAfter(myLast))) continue;
          await (_db.delete(_db.reviewLog)..where((t) => t.cardId.equals(mine.id))).go();
          await (_db.delete(_db.studyCards)..where((t) => t.id.equals(mine.id))).go();
        }
        final cardId = await _db
            .into(_db.studyCards)
            .insert(
              StudyCardsCompanion.insert(
                entryId: entry,
                direction: Value(direction),
                repetitions: Value((c['repetitions'] as num?)?.toInt() ?? 0),
                easeFactor: Value((c['easeFactor'] as num?)?.toDouble() ?? 2.5),
                intervalDays: Value((c['intervalDays'] as num?)?.toInt() ?? 0),
                dueAt: Value(_date(c['dueAt'], now)),
                createdAt: Value(_date(c['createdAt'], now)),
                paused: Value(c['paused'] == true),
              ),
            );
        cards++;
        for (final r in theirReviews ?? const <Map<String, dynamic>>[]) {
          await _db
              .into(_db.reviewLog)
              .insert(
                ReviewLogCompanion.insert(
                  cardId: cardId,
                  reviewedAt: Value(_date(r['reviewedAt'], now)),
                  grade: (r['grade'] as num).toInt(),
                  priorInterval: (r['priorInterval'] as num?)?.toInt() ?? 0,
                  durationMs: Value((r['durationMs'] as num?)?.toInt() ?? 0),
                ),
              );
          reviews++;
        }
      }

      // ---- Pinned / excluded meanings ----
      for (final s in _rows(map, 'senses')) {
        final entry = resolved[s['entryId']];
        if (entry == null) continue;
        final sense = await _resolveSense(entry, s['senseId'] as int, s['gloss'] as String?);
        if (sense == null) continue;
        await _db
            .into(_db.studySenses)
            .insert(
              StudySensesCompanion.insert(entryId: entry, senseId: sense, excluded: Value(s['excluded'] == true)),
              mode: InsertMode.insertOrIgnore,
            );
      }

      // ---- Notes ----
      final notesBefore = await count('entry_notes');
      for (final n in _rows(map, 'notes')) {
        final entry = resolved[n['entryId']];
        if (entry == null) {
          skipped.add(n['entryId'] as int);
          continue;
        }
        await _db
            .into(_db.entryNotes)
            .insert(
              EntryNotesCompanion.insert(
                entryId: Value(entry),
                markdown: n['markdown'] as String? ?? '',
                updatedAt: Value(_date(n['updatedAt'], now)),
              ),
              mode: InsertMode.insertOrIgnore,
            );
      }

      return (
        lists: newId.length,
        listWords: await count('list_items') - listWordsBefore,
        cards: cards,
        reviews: reviews,
        notes: await count('entry_notes') - notesBefore,
        slangWords: await count('slang_words') - slangBefore,
        skippedWords: skipped.length,
      );
    });
  }

  /// Backup entry id → this dictionary's entry id. An id that still names
  /// the same headword is kept; otherwise the headword's canonical entry
  /// (the one the app studies — lowest frequency rank) stands in. Words
  /// this dictionary lacks map to nothing.
  Future<Map<int, int>> _resolveEntries(Map<int, String?> entries) async {
    final current = await _headwords(entries.keys.toSet());
    final out = <int, int>{};
    for (final e in entries.entries) {
      final headword = e.value;
      if (headword == null) {
        // Exported without a headword: only trust the id as it stands.
        if (current.containsKey(e.key)) out[e.key] = e.key;
        continue;
      }
      if (current[e.key] == headword) {
        out[e.key] = e.key;
        continue;
      }
      // The dictionary's canonical row first; failing that, a slang word
      // of that headword (restored above, so its id here is new).
      final row = await _db.customSelect(
        'SELECT id FROM dict.entries WHERE headword = ? '
        'ORDER BY (frequency_rank IS NULL), frequency_rank, pos LIMIT 1',
        variables: [Variable.withString(headword)],
      ).getSingleOrNull() ??
          await _db.customSelect(
            'SELECT id FROM slang_words WHERE headword = ?',
            variables: [Variable.withString(headword)],
          ).getSingleOrNull();
      if (row != null) out[e.key] = row.read<int>('id');
    }
    return out;
  }

  /// A pinned meaning's sense id in this dictionary: the same id if it
  /// still carries the same gloss, else the sense with that gloss among the
  /// entry's headword.
  ///
  /// The meaning may be one of the person's own: the slang meanings filed
  /// under the same headword are searched by gloss too.
  Future<int?> _resolveSense(int entryId, int senseId, String? gloss) async {
    final same = await _db.customSelect(
      isSlangId(senseId) ? 'SELECT gloss FROM slang_senses WHERE id = ?' : 'SELECT gloss FROM dict.senses WHERE id = ?',
      variables: [Variable.withInt(senseId)],
    ).getSingleOrNull();
    if (same != null && (gloss == null || same.read<String>('gloss') == gloss)) return senseId;
    if (gloss == null) return null;
    final headword = (await _headwords({entryId}))[entryId];
    if (headword == null) return null;
    final row = await _db.customSelect(
      'SELECT s.id FROM slang_senses s JOIN slang_words w ON w.id = s.word_id '
      'WHERE w.headword = ? AND s.gloss = ? '
      'UNION ALL '
      'SELECT s.id FROM dict.senses s JOIN dict.entries e ON e.id = s.entry_id '
      'WHERE e.headword = ? AND s.gloss = ? LIMIT 1',
      variables: [
        Variable.withString(headword),
        Variable.withString(gloss),
        Variable.withString(headword),
        Variable.withString(gloss),
      ],
    ).getSingleOrNull();
    return row?.read<int>('id');
  }
}
