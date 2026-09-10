import 'dart:convert';
import 'dart:math';

import 'clues.dart';
import 'crossword_models.dart';
import 'generator.dart';
import 'skeleton.dart';
import 'solver.dart';
import 'word_list.dart';

/// The editorial pass — PORTING_SPEC.md §9.3 and §9.4.
///
/// Everything else in this generator is deterministic and offline. This is
/// the one place a model is involved, and it is **strictly an upgrade**: no
/// key, a timeout, a rate limit or unparseable output all leave the
/// deterministic puzzle exactly as it was.
///
/// **The reviewer is untrusted, and that is the point.** Nothing it says is
/// applied without proof. Clue edits are re-validated against the same gate
/// every other clue passes; word edits are *pinned* and the grid is re-solved
/// around them, because a replacement changes crossing letters and cannot be
/// checked in isolation. In a measured run the model proposed 32 clue edits
/// on one 9x9 and three broke rules it had been given explicitly — two
/// contained the answer, one signalled an abbreviation.
///
/// This file holds only pure functions. The HTTP call lives in
/// `lib/services/crossword_review_service.dart`, and the whole flow is kept
/// off the click path by `CrosswordRepository`.

/// What the reviewer thought, before any of it is trusted.
class EditorialVerdict {
  final double entertainment; // 0-10, the reviewer's own judgement
  final String notes;
  final Map<int, String> clueEdits; // slotId -> new clue

  /// slotId -> why that answer should not be in a puzzle.
  ///
  /// The reviewer **names bad answers rather than replacing them**. Asking it
  /// for a replacement asked it to do the one thing it is worst at: a
  /// substitute has to satisfy every crossing, which is a search problem, and
  /// in measured runs the model's picks were routinely unfillable — one
  /// review proposed SUPRA→ABOVE and DOE→GAS and the grid could not be
  /// re-solved around either. Judging that SUPRA is a bare prefix nobody
  /// knows is the part it is good at. So it judges, and the solver — which
  /// re-fills a 9x9 in about 4ms — picks the replacement.
  final Map<int, String> bannedAnswers;

  const EditorialVerdict({
    this.entertainment = 0,
    this.notes = '',
    this.clueEdits = const {},
    this.bannedAnswers = const {},
  });

  bool get isEmpty => clueEdits.isEmpty && bannedAnswers.isEmpty;
}

/// One edit the reviewer proposed, and what became of it.
///
/// Kept individually rather than only counted because the counts alone can't
/// answer the question you actually have while tuning the prompt — *which*
/// clue did it want to change, to what, and which rule did the rejected ones
/// break.
class CrosswordProposedEdit {
  /// Whether this was a clue rewrite or an answer *ban*. Bans are
  /// all-or-nothing as a set — one re-solve either succeeds with every banned
  /// word gone or the fill is left alone — so their [applied] values move
  /// together.
  final bool isWordEdit;
  final int slotId;

  /// The answer the edit was written against — the grid form.
  final String answer;

  /// The clue before and after. For a ban, [before] is the answer that was
  /// removed and [after] is what the solver put there instead (empty if the
  /// re-solve failed). For a rejected clue edit [after] is what the reviewer
  /// asked for, not what the puzzle says.
  final String before;
  final String after;

  final bool applied;

  /// Why it was refused: a [ClueRejection] name for a clue, or the
  /// all-or-nothing reason for a word edit. Empty when [applied].
  final String rejection;

  const CrosswordProposedEdit({
    required this.isWordEdit,
    required this.slotId,
    required this.answer,
    required this.before,
    required this.after,
    required this.applied,
    this.rejection = '',
  });

  Map<String, dynamic> toJson() => {
        'kind': isWordEdit ? 'word' : 'clue',
        'slotId': slotId,
        'answer': answer,
        'before': before,
        'after': after,
        'applied': applied,
        if (rejection.isNotEmpty) 'rejection': rejection,
      };

  factory CrosswordProposedEdit.fromJson(Map<String, dynamic> json) =>
      CrosswordProposedEdit(
        isWordEdit: json['kind'] == 'word',
        slotId: json['slotId'] as int? ?? -1,
        answer: json['answer'] as String? ?? '',
        before: json['before'] as String? ?? '',
        after: json['after'] as String? ?? '',
        applied: json['applied'] as bool? ?? false,
        rejection: json['rejection'] as String? ?? '',
      );
}

class CrosswordRevision {
  final CrosswordPuzzle puzzle;

  /// Every edit the reviewer proposed, applied or not, in the order it was
  /// considered.
  final List<CrosswordProposedEdit> edits;

  final String wordsRejectedReason;

  const CrosswordRevision({
    required this.puzzle,
    this.edits = const [],
    this.wordsRejectedReason = '',
  });

  Iterable<CrosswordProposedEdit> get _clues => edits.where((e) => !e.isWordEdit);
  Iterable<CrosswordProposedEdit> get _words => edits.where((e) => e.isWordEdit);

  int get cluesProposed => _clues.length;
  int get cluesApplied => _clues.where((e) => e.applied).length;
  int get wordsProposed => _words.length;
  int get wordsApplied => _words.where((e) => e.applied).length;

  /// Rejected clue edits counted by the rule they broke.
  Map<ClueRejection, int> get cluesRejected {
    final out = <ClueRejection, int>{};
    for (final edit in _clues) {
      if (edit.applied) continue;
      final reason = ClueRejection.values.firstWhere(
        (r) => r.name == edit.rejection,
        orElse: () => ClueRejection.none,
      );
      out[reason] = (out[reason] ?? 0) + 1;
    }
    return out;
  }

  bool get changed => cluesApplied > 0 || wordsApplied > 0;
}

/// The system prompt. Ported from the reference implementation, including the
/// rules restated at the end — the model is told exactly what will be
/// enforced after it replies, which raises the acceptance rate without
/// relaxing anything.
const String reviewSystemPrompt = '''
You are the editor of a daily crossword for a vocabulary-learning app. You are shown a finished, valid puzzle. Judge it as a solver would, then propose only the changes that make it better.

Judge two things: the ANSWERS and the CLUES.

ANSWERS first — this matters most. The solvers are learning vocabulary, not crossword veterans, so an answer must be a word or name they plausibly know. Reject an answer that is any of these:
- a word almost nobody uses in English: AIN, PAP, ABA, NEE, YAW
- a technical unit or jargon term: ERG, DYNE
- an obscure abbreviation or initialism: DDS, DES, NYSE, OSHA
- a bare prefix or suffix rather than a word: GEO-, -ADE
- a foreign word not naturalised in English
- a niche proper noun: a minor historical region, a half-remembered celebrity
A corpus-frequency figure is given for each answer. It is unreliable below four letters — DES scores as high as many common words because those letters appear constantly inside other text — so trust your own sense of whether a person would know the word, not the number.

Then the CLUES:
- Are any WRONG? Factual errors matter most — a clue that describes something else entirely, or attributes the wrong person, place or work.
- Does the clue point at the sense people actually mean? VIOLA is an instrument, not a genus of plants. TYRE is a car part before it is a Phoenician city. Clue the common meaning.
- Do they read like a newspaper crossword, or like a dictionary? Rewrite encyclopedic definitions short and vivid. Do not be scholarly: "definite article in English grammar" is a worse clue for THE than "Word before noun".
- Be straightforward rather than cryptic. Misdirection that merely confuses is worse than a plain clue; do not reach for a misleading reading.
- Is there variety, or does every clue work the same way?
- Does the puzzle suit its stated day and theme?

Every clue you propose must obey these rules, which are enforced after you reply — a clue that breaks one is discarded:
- 3-12 words. Do not end with a period.
- NEVER contain the answer, an inflection of it, or a word sharing its root. For a multi-word answer this applies to every word in it.
- NEVER spell the answer out as an acronym, and never write "for short", "abbrev.", "acronym", "initials" or "stands for".
- NEVER mention the answer's length or spelling.
- No profanity, crude anatomy, slurs or sexual content.

Do NOT suggest a replacement answer. Name the ids of the answers that should not be there and why, and the grid is re-filled without them by a solver that will find words which actually fit the crossings. A banned answer is also kept out of future puzzles. Ban only what genuinely fails the test above — every ban makes the remaining grid harder to fill, and if it cannot be filled at all, none of them take effect.

Banning answers re-fills the grid, so clues for answers that change are regenerated and any rewrite you gave for them is discarded. Clue rewrites for answers that survive still apply.

Return strict JSON and nothing else:
{"entertainment": 0-10, "notes": "one or two sentences",
 "clue_edits": {"<id>": "new clue"}, "banned_answers": {"<id>": "why it is unfair"}}
Use the numeric id shown against each clue. Leave a map empty if you have no changes of that kind. Do not rewrite clues that are already good.''';

const List<String> _weekdayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

String weekdayName(int weekday) => _weekdayNames[(weekday - 1) % 7];

/// The puzzle as the reviewer sees it.
///
/// Answers are shown alongside their clues deliberately — fairness and
/// factual accuracy cannot be judged without them — with their corpus
/// frequency, and each clue carries the slot id that edits must be keyed by.
String renderForReview(CrosswordPuzzle puzzle, {required int weekday}) {
  final lines = <String>[
    'Day: ${weekdayName(weekday)}',
    'Size: ${puzzle.width}x${puzzle.height}',
  ];
  if (puzzle.themeName != null) {
    lines.add('Theme: ${puzzle.themeName} (${puzzle.themeKind})');
  }
  if (puzzle.anchors.isNotEmpty) {
    lines.add('Required answers (do not replace): ${puzzle.anchors.join(', ')}');
  }
  lines
    ..add('')
    ..add('Grid (# = black square):')
    ..add(renderGrid(puzzle))
    ..add('');

  for (final direction in CrosswordDirection.values) {
    lines.add(direction.name.toUpperCase());
    for (final word in direction == CrosswordDirection.across ? puzzle.across : puzzle.down) {
      final freq = word.freqZipf > 0 ? ' (freq ${word.freqZipf.toStringAsFixed(1)})' : '';
      lines.add('  id=${word.slotId} ${word.number}. [${word.display}$freq] ${word.clue}');
    }
    lines.add('');
  }
  return lines.join('\n').trim();
}

String renderGrid(CrosswordPuzzle puzzle) {
  final letters = <(int, int), String>{};
  for (final word in puzzle.words) {
    final cells = word.cells;
    for (var i = 0; i < cells.length; i++) {
      letters[cells[i]] = word.answer[i];
    }
  }
  return [
    for (var r = 0; r < puzzle.height; r++)
      [for (var c = 0; c < puzzle.width; c++) letters[(r, c)] ?? '#'].join(),
  ].join('\n');
}

final _fenced = RegExp(r'```(?:json)?\s*(.*?)```', dotAll: true);
final _leadingDigits = RegExp(r'^\s*(\d+)');

/// Tolerant parse. Anything unreadable yields an empty verdict, which is a
/// no-op rather than an error.
EditorialVerdict parseVerdict(String raw) {
  if (raw.isEmpty) return const EditorialVerdict();
  final fenced = _fenced.firstMatch(raw);
  var body = fenced != null ? fenced.group(1)! : raw;
  final start = body.indexOf('{');
  final end = body.lastIndexOf('}');
  if (start == -1 || end == -1 || end < start) return const EditorialVerdict();
  body = body.substring(start, end + 1);

  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    return const EditorialVerdict();
  }
  if (decoded is! Map) return const EditorialVerdict();

  Map<int, String> intKeyed(Object? value) {
    final out = <int, String>{};
    if (value is! Map) return out;
    for (final entry in value.entries) {
      final text = entry.value;
      if (text is! String || text.trim().isEmpty) continue;
      // Models key edits as "12", 12, or "12A" despite being asked for the
      // bare id; take the leading digits either way.
      final match = _leadingDigits.firstMatch(entry.key.toString());
      if (match != null) out[int.parse(match.group(1)!)] = text.trim();
    }
    return out;
  }

  final entertainment = switch (decoded['entertainment']) {
    final num n => n.toDouble(),
    final String s => double.tryParse(s) ?? 0.0,
    _ => 0.0,
  };
  final notes = decoded['notes']?.toString() ?? '';

  return EditorialVerdict(
    entertainment: entertainment.clamp(0.0, 10.0),
    notes: notes.length > 500 ? notes.substring(0, 500) : notes,
    clueEdits: intKeyed(decoded['clue_edits']),
    // `word_edits` is the older key, from when the reviewer proposed
    // replacements; a model that has seen that shape still occasionally uses
    // it, and the ids mean the same thing either way.
    bannedAnswers: {
      ...intKeyed(decoded['word_edits']),
      ...intKeyed(decoded['banned_answers']),
    },
  );
}

/// Rebuilds the solver's view of the grid from a finished puzzle.
///
/// The puzzle stores placements rather than slots, because everything the
/// screen renders is derivable from them — but re-solving around pinned words
/// needs the crossing map, so it is recomputed here from the same geometry.
List<CrosswordSlot> slotsOf(CrosswordPuzzle puzzle) {
  final slots = [
    for (final word in puzzle.words)
      CrosswordSlot(
        slotId: word.slotId,
        number: word.number,
        direction: word.direction,
        row: word.row,
        col: word.col,
        length: word.answer.length,
      ),
  ];
  computeCrossings(slots);
  return slots;
}

/// Applies a reviewer's verdict, keeping only what survives verification.
///
/// **A verdict is only valid for the puzzle the reviewer was shown.** Word
/// edits re-solve the whole grid, so slots keep their ids but change their
/// answers — and clue edits, written against the old answers, would then land
/// on new ones. That is not hypothetical: in the reference implementation it
/// shipped a clue for LLOYD'S of London onto the answer SYNTAX. So the two
/// kinds are mutually exclusive within a pass; word edits win when both are
/// present, being the structural change and the rarer request. A caller that
/// wants both runs a second review against the re-solved puzzle.
CrosswordRevision revisePuzzle({
  required CrosswordPuzzle puzzle,
  required EditorialVerdict verdict,
  required CrosswordPatternIndex index,
  required Set<String> blockedAnswers,
  required int seed,
}) {
  final byId = {for (final w in puzzle.words) w.slotId: w};
  var working = puzzle;
  final edits = <CrosswordProposedEdit>[];
  var banFailure = '';

  if (verdict.bannedAnswers.isNotEmpty) {
    final result = _applyBans(
      puzzle: puzzle,
      slotIds: verdict.bannedAnswers.keys,
      index: index,
      blockedAnswers: blockedAnswers,
      seed: seed,
    );
    banFailure = result.reason;
    if (result.puzzle != null) working = result.puzzle!;
    final after = {for (final w in working.words) w.slotId: w};
    for (final slotId in result.banned) {
      edits.add(CrosswordProposedEdit(
        isWordEdit: true,
        slotId: slotId,
        answer: byId[slotId]?.answer ?? '',
        before: byId[slotId]?.answer ?? '',
        // What the solver chose in its place — the whole point of banning
        // rather than dictating.
        after: result.puzzle == null ? '' : after[slotId]?.answer ?? '',
        applied: result.puzzle != null,
        rejection: result.puzzle != null ? '' : result.reason,
      ));
    }
  }

  if (verdict.clueEdits.isNotEmpty) {
    final current = {for (final w in working.words) w.slotId: w};
    final replacements = <int, String>{};
    for (final edit in verdict.clueEdits.entries) {
      final word = current[edit.key];
      if (word == null) {
        edits.add(CrosswordProposedEdit(
          isWordEdit: false,
          slotId: edit.key,
          answer: '',
          before: '',
          after: edit.value,
          applied: false,
          rejection: 'unknown_slot',
        ));
        continue;
      }
      // A clue rewrite is only valid for the answer it was written against.
      // Re-filling changes some answers and leaves others alone, so only the
      // ones that moved lose their rewrite — the old rule threw away every
      // clue edit whenever a single word changed.
      if (byId[edit.key]?.answer != word.answer) {
        edits.add(CrosswordProposedEdit(
          isWordEdit: false,
          slotId: edit.key,
          answer: word.answer,
          before: word.clue,
          after: edit.value,
          applied: false,
          rejection: 'stale_after_refill',
        ));
        continue;
      }
      // `display` matters: without it a rewritten clue for ICE CREAM could
      // mention "cream" and pass, since the joined grid form contains neither
      // word.
      final candidate = validateClue(edit.value, word.answer, display: word.display);
      if (candidate.ok) replacements[edit.key] = candidate.text;
      edits.add(CrosswordProposedEdit(
        isWordEdit: false,
        slotId: edit.key,
        answer: word.answer,
        before: word.clue,
        after: candidate.text,
        applied: candidate.ok,
        rejection: candidate.ok ? '' : candidate.reason.name,
      ));
    }

    if (replacements.isNotEmpty) {
      working = working.copyWith(
        words: [
          for (final word in working.words)
            replacements.containsKey(word.slotId)
                ? word.copyWith(
                    clue: replacements[word.slotId], clueType: CrosswordClueType.llm)
                : word,
        ],
        reviewed: true,
      );
    }
  }

  return CrosswordRevision(
    puzzle: working,
    edits: edits,
    wordsRejectedReason: banFailure,
  );
}

/// Every slot within [radius] crossings of [from], including [from] itself —
/// the region a local repair is allowed to rewrite.
Set<int> _withinRadius(
  Iterable<int> from,
  Map<int, CrosswordSlot> byId,
  int radius,
) {
  var frontier = {...from};
  final seen = {...from};
  for (var hop = 0; hop < radius; hop++) {
    final next = <int>{};
    for (final slotId in frontier) {
      for (final crossing in byId[slotId]!.crossings.values) {
        if (seen.add(crossing.$1)) next.add(crossing.$1);
      }
    }
    if (next.isEmpty) break;
    frontier = next;
  }
  return seen;
}

/// Re-fills the grid with the reviewer's rejected answers excluded.
///
/// This is the mechanism the editorial pass uses in place of the spec's §9.4
/// word edits, and it inverts who does what. The reviewer says only *which*
/// answers are unfair; the solver — for which this is 1-35ms of work — finds
/// words that fit the crossings. Measured, the old way failed constantly:
/// a replacement has to agree with every crossing letter, and a model
/// picking one is guessing at a constraint problem.
///
/// All-or-nothing: one re-solve either places every banned answer's
/// replacement or the original fill stands. Anchors are pinned, so the
/// personalised SRS words and the theme entries survive, and an attempt to
/// ban one is refused outright.
({CrosswordPuzzle? puzzle, String reason, List<int> banned}) _applyBans({
  required CrosswordPuzzle puzzle,
  required Iterable<int> slotIds,
  required CrosswordPatternIndex index,
  required Set<String> blockedAnswers,
  required int seed,
}) {
  final byId = {for (final w in puzzle.words) w.slotId: w};
  final anchors = puzzle.anchors.toSet();

  final banned = <int>[];
  final bannedText = <String>{};
  for (final slotId in slotIds) {
    final word = byId[slotId];
    if (word == null) continue; // an id the puzzle doesn't have
    if (anchors.contains(word.answer)) continue; // never the user's own words
    banned.add(slotId);
    bannedText.add(word.answer);
  }
  if (banned.isEmpty) {
    return (puzzle: null, reason: 'nothing_bannable', banned: const []);
  }

  final slots = slotsOf(puzzle);
  final byIdSlot = {for (final s in slots) s.slotId: s};
  final anchorPins = <int, String>{
    for (final word in puzzle.words)
      if (anchors.contains(word.answer)) word.slotId: word.answer,
  };

  // Two attempts, narrowest first — actually a ladder. Re-filling the whole
  // grid produces a *different puzzle*: measured, only 2 of 25 answers
  // survived, because the search diverges as soon as one domain changes. That
  // throws away the reviewer's other clue rewrites and rewrites a puzzle the
  // user may already have been reading, when all that was asked for was the
  // removal of one bad word.
  //
  // So the repair starts as local as possible and widens only when it has to.
  // One hop is often over-constrained — every neighbour of the banned slot is
  // boxed in by pinned words on all its other crossings — so the radius grows
  // to two and three before the whole grid is given back to the solver. Each
  // attempt is milliseconds, so trying four is free.
  final attempts = <Map<int, String>>[
    for (final radius in [1, 2, 3])
      {
        for (final word in puzzle.words)
          if (!_withinRadius(banned, byIdSlot, radius).contains(word.slotId))
            word.slotId: word.answer,
        ...anchorPins,
      },
    anchorPins,
  ];

  Map<int, String>? fill;
  for (final pinned in attempts) {
    final solver = CrosswordSolver(
      slots: slots,
      index: index,
      rng: Random(seed),
      preAssigned: pinned,
      blockedAnswers: {...blockedAnswers, ...bannedText},
      timeBudget: const Duration(seconds: 8),
      // Low jitter: the aim is this puzzle minus the bad answers, not a
      // different puzzle.
      scoreJitter: 0.5,
    );
    fill = solver.solve();
    if (fill != null) break;
  }
  if (fill == null) {
    return (puzzle: null, reason: 'unfillable_without_banned', banned: banned);
  }

  final rng = Random(seed);
  final offenders = qualityOffenders(fill.values, index: index, anchorTexts: anchors);
  if (offenders > 0) {
    return (puzzle: null, reason: 'quality_gate:$offenders', banned: banned);
  }

  // Commit: answers, clues and study-word tagging move together. A slot whose
  // answer is unchanged keeps its clue, so the puzzle only churns where it
  // had to.
  final srsByAnswer = {
    for (final word in puzzle.words)
      if (word.fromStudyPool) word.answer: word,
  };
  final words = <CrosswordWordPlacement>[];
  for (final slot in slots) {
    final text = fill[slot.slotId]!;
    final previous = byId[slot.slotId];
    if (previous != null && previous.answer == text) {
      words.add(previous);
      continue;
    }
    final entry = index.byText[text] ??
        CrosswordEntry.synthetic(text: text, display: text, entryId: -1);
    final clue = pickClue(entry, rng);
    words.add(CrosswordWordPlacement(
      number: slot.number,
      slotId: slot.slotId,
      direction: slot.direction,
      row: slot.row,
      col: slot.col,
      answer: text,
      display: entry.display,
      entryId: srsByAnswer[text]?.entryId ?? entry.entryId,
      clue: clue.text,
      clueType: clue.type,
      freqZipf: entry.freqZipf,
      fromStudyPool: srsByAnswer.containsKey(text),
    ));
  }

  return (
    puzzle: puzzle.copyWith(words: words, reviewed: true),
    reason: '',
    banned: banned,
  );
}

/// Structural re-check of a (possibly edited) puzzle — §9.4's last step.
///
/// Cheap enough to run unconditionally after any revision, and the safety net
/// for the safety net: if it ever fires, show the un-revised puzzle rather
/// than a broken one. Returns a list of problems; empty means the puzzle is
/// internally consistent.
List<String> assertPuzzleValid(CrosswordPuzzle puzzle) {
  final problems = <String>[];
  final letters = <(int, int), String>{};

  for (final word in puzzle.words) {
    if (word.answer.length < 3) problems.add('slot ${word.slotId}: ${word.answer} too short');
    final cells = word.cells;
    for (var i = 0; i < cells.length; i++) {
      final existing = letters[cells[i]];
      if (existing != null && existing != word.answer[i]) {
        problems.add('crossing mismatch at ${cells[i]}: $existing vs ${word.answer[i]}');
      }
      letters[cells[i]] = word.answer[i];
    }
  }

  if (puzzle.words.map((w) => w.answer).toSet().length != puzzle.words.length) {
    problems.add('duplicate answers in grid');
  }

  for (final anchor in puzzle.anchors) {
    if (!puzzle.words.any((w) => w.answer == anchor)) {
      problems.add('anchor $anchor no longer in the grid');
    }
  }

  // The same gate every other clue passes, applied to the *final* puzzle, so
  // it catches anything an edit reintroduced. This is the last thing that
  // runs before a puzzle reaches a solver.
  for (final word in puzzle.words) {
    final leaks =
        leakForms(word.answer, word.display).any((f) => isGiveaway(word.clue, f));
    if (leaks) problems.add('clue leaks answer ${word.answer}: "${word.clue}"');
    if (signalsAbbreviation(word.clue) || expandsAcronym(word.clue, word.answer)) {
      problems.add('clue signals an abbreviation for ${word.answer}: "${word.clue}"');
    }
    if (hintsAtLength(word.clue)) {
      problems.add('clue gives away the length of ${word.answer}: "${word.clue}"');
    }
    if (hasProfanity(word.clue)) {
      problems.add('clue is not clean for ${word.answer}: "${word.clue}"');
    }
  }

  return problems;
}

/// Isolate entry point for §9.4: parse the asset, rebuild the fill index and
/// apply a verdict.
///
/// Word edits re-solve the grid, which needs the index — 8.9 MB to parse — so
/// this runs off the UI isolate like generation does.
class CrosswordRevisionRequest {
  final String wordListSource;
  final CrosswordPuzzle puzzle;
  final EditorialVerdict verdict;
  final Set<String> blockedAnswers;
  final int seed;

  const CrosswordRevisionRequest({
    required this.wordListSource,
    required this.puzzle,
    required this.verdict,
    required this.blockedAnswers,
    required this.seed,
  });
}

/// Returns the puzzle to show. Never returns something worse than what it was
/// given: a revision that fails [assertPuzzleValid] is discarded.
CrosswordRevision reviseCrosswordFromSource(CrosswordRevisionRequest request) {
  final entries = parseWordList(request.wordListSource);
  final index = CrosswordPatternIndex.build(entries.where(inFillPool));
  final revision = revisePuzzle(
    puzzle: request.puzzle,
    verdict: request.verdict,
    index: index,
    blockedAnswers: request.blockedAnswers,
    seed: request.seed,
  );
  if (!revision.changed) return revision;

  final problems = assertPuzzleValid(revision.puzzle);
  if (problems.isEmpty) return revision;
  // Unreachable if the verification above is right, which is exactly why it
  // is checked: the pre-review puzzle is always valid and always playable.
  return CrosswordRevision(
    puzzle: request.puzzle,
    edits: [
      for (final edit in revision.edits)
        CrosswordProposedEdit(
          isWordEdit: edit.isWordEdit,
          slotId: edit.slotId,
          answer: edit.answer,
          before: edit.before,
          after: edit.after,
          applied: false,
          rejection: 'invalid_after_revision',
        ),
    ],
    wordsRejectedReason: 'invalid_after_revision:${problems.first}',
  );
}
