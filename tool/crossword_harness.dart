// Crossword quality harness.
//
// Generates a fixed, reproducible set of puzzles with the app's own
// generator and word list, then measures them three ways:
//
//   1. lint     — objective, free checks on every answer and clue
//                 (tool/crossword_harness/lint.dart);
//   2. editor   — the production AI editor, same prompt/model/settings as
//                 the `ai-crossword-review` Edge Function, applied through
//                 the app's own verification and re-fill (editorial.dart);
//   3. judge    — a stronger model scoring each puzzle before and after the
//                 editor the way a newspaper crossword editor would.
//
// Writes tool/crossword_harness/out/<label>/run.json and report.html. Runs
// are comparable when they use the same --seed and --count: the puzzles are
// then the same, so any change in the numbers is a change you made.
//
//   dart run tool/crossword_harness.dart [options]
//     --label NAME       output folder (default: a timestamp)
//     --sizes mini,midi,mega
//     --count N          puzzles per size (default 4)
//     --seed N           base seed (default 7000)
//     --no-editor        skip the AI editor
//     --no-judge         skip the judge
//     --judge-model M    default gpt-5
//     --editor-model M   default gpt-5-mini (production)
//     --wordlist PATH    default assets/crossword/wordlist.tsv — point it at a
//                        baked variant to compare clue sources on the same seeds
//
// The LLM steps read OPENAI_API_KEY from the environment or .env and cost
// money: roughly $0.02-0.10 per puzzle with the defaults.

import 'dart:convert';
import 'dart:io';

import 'package:word_wizard/domain/crossword/crossword_models.dart';
import 'package:word_wizard/domain/crossword/editorial.dart';
import 'package:word_wizard/domain/crossword/generator.dart';
import 'package:word_wizard/domain/crossword/word_list.dart';

import 'crossword_harness/lint.dart';
import 'crossword_harness/llm.dart';
import 'crossword_harness/report.dart';

/// Stand-in study words, the kind of vocabulary the app's users save. Each
/// puzzle anchors on a rotating few, as the app anchors on the study pool.
const _studyWords = [
  'CANDID', 'LUCID', 'TERSE', 'OPAQUE', 'DEFT', 'WRY', 'ARDENT', 'FRUGAL',
  'PLACID', 'WISTFUL', 'ZEALOUS', 'AUSTERE', 'BENIGN', 'CURT', 'DOUR', 'EERIE',
  'GAUNT', 'INEPT', 'LITHE', 'MOROSE', 'NAIVE', 'OVERT', 'PRIM', 'SMUG',
];

Future<void> main(List<String> args) async {
  final opts = _Options.parse(args);
  final out = Directory('tool/crossword_harness/out/${opts.label}')..createSync(recursive: true);

  final entries = parseWordList(File(opts.wordlist).readAsStringSync());
  final byText = <String, CrosswordEntry>{};
  for (final e in entries) {
    byText.putIfAbsent(e.text, () => e);
  }
  final index = CrosswordPatternIndex.build(entries.where(inFillPool));

  final ai = (opts.editor || opts.judge) ? OpenAi.fromEnvironment() : null;
  if ((opts.editor || opts.judge) && ai == null) {
    stderr.writeln('No OPENAI_API_KEY in the environment or .env — running lint only.');
  }
  final editorPrompt = productionEditorPrompt();

  final jobs = <_Job>[];
  for (final size in opts.sizes) {
    for (var i = 0; i < opts.count; i++) {
      jobs.add(_Job(size, opts.seed + size.index * 1000 + i, (i % 7) + 1, i));
    }
  }
  stdout.writeln('${jobs.length} puzzles → ${out.path}');

  // A few at a time: the model calls dominate and run fine in parallel.
  final results = <Map<String, dynamic>>[];
  for (var i = 0; i < jobs.length; i += 4) {
    final batch = jobs.sublist(i, (i + 4).clamp(0, jobs.length));
    results.addAll(
      await Future.wait(
        batch.map((job) => _run(job, entries, byText, index, ai, opts, editorPrompt)),
      ),
    );
  }

  final run = {
    'label': opts.label,
    'createdAt': DateTime.now().toIso8601String(),
    'config': {
      'sizes': [for (final s in opts.sizes) s.storageKey],
      'count': opts.count,
      'seed': opts.seed,
      'editor': opts.editor && ai != null,
      'editorModel': opts.editorModel,
      'judge': opts.judge && ai != null,
      'judgeModel': opts.judgeModel,
      'wordlist': opts.wordlist,
    },
    'puzzles': results,
    'summary': summarize(results),
  };
  File('${out.path}/run.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(run));
  File('${out.path}/report.html').writeAsStringSync(renderReport(run));
  stdout.writeln('\n${formatSummary(run['summary'] as Map<String, dynamic>)}');
  stdout.writeln('wrote ${out.path}/report.html');
}

class _Job {
  final CrosswordDifficulty size;
  final int seed;
  final int weekday;
  final int i;
  _Job(this.size, this.seed, this.weekday, this.i);
}

Future<Map<String, dynamic>> _run(
  _Job job,
  List<CrosswordEntry> entries,
  Map<String, CrosswordEntry> byText,
  CrosswordPatternIndex index,
  OpenAi? ai,
  _Options opts,
  String editorPrompt,
) async {
  final anchors = [
    for (var k = 0; k < 2; k++) _studyWords[(job.i * 2 + k + job.size.index * 5) % _studyWords.length],
  ];
  final clock = Stopwatch()..start();
  final puzzle = generateCrossword(
    CrosswordGenerationRequest(
      difficulty: job.size,
      entries: entries,
      srsAnchors: [
        for (final a in anchors)
          CrosswordEntry.synthetic(
            text: a,
            display: a.toLowerCase(),
            entryId: 1,
            clue: byText[a]?.clues.firstOrNull?.text,
          ),
      ],
      blockedAnswers: const {},
      weekday: job.weekday,
      seed: job.seed,
    ),
  );
  final genMs = clock.elapsedMilliseconds;
  final tag = '${job.size.label} #${job.i + 1} (seed ${job.seed})';
  if (puzzle == null) {
    stdout.writeln('  $tag: generation failed');
    return {'size': job.size.storageKey, 'seed': job.seed, 'weekday': job.weekday, 'ok': false, 'genMs': genMs};
  }

  final before = _snapshot(puzzle, byText);
  final result = <String, dynamic>{
    'size': job.size.storageKey,
    'seed': job.seed,
    'weekday': job.weekday,
    'ok': true,
    'genMs': genMs,
    'theme': puzzle.themeName,
    'anchors': puzzle.anchors,
    'before': before,
  };

  CrosswordPuzzle? edited;
  if (ai != null && opts.editor) {
    try {
      final response = await ai.chat(
        model: opts.editorModel,
        system: editorPrompt,
        user: renderForReview(puzzle, weekday: job.weekday),
        reasoningEffort: 'low',
        maxOutputTokens: (4000 + 60 * puzzle.words.length).clamp(0, 16000),
      );
      final verdict = parseVerdict(response.content);
      final revision = revisePuzzle(
        puzzle: puzzle,
        verdict: verdict,
        index: index,
        blockedAnswers: const {},
        seed: puzzle.seed,
      );
      edited = revision.puzzle;
      result['editor'] = {
        'costUsd': response.costUsd,
        'latencyMs': response.latencyMs,
        'entertainment': verdict.entertainment,
        'notes': verdict.notes,
        'cluesProposed': revision.cluesProposed,
        'cluesApplied': revision.cluesApplied,
        'wordsProposed': revision.wordsProposed,
        'wordsApplied': revision.wordsApplied,
        'banFailure': revision.wordsRejectedReason,
        'edits': [
          for (final e in revision.edits)
            {
              'kind': e.isWordEdit ? 'ban' : 'clue',
              'before': e.before,
              'after': e.after,
              'applied': e.applied,
              'rejection': e.rejection,
            },
        ],
      };
      result['after'] = _snapshot(edited, byText);
    } catch (e) {
      result['editorError'] = '$e';
    }
  }

  if (ai != null && opts.judge) {
    Future<Map<String, dynamic>?> judge(CrosswordPuzzle p, Map<String, dynamic> snap) async {
      try {
        final response = await ai.chat(
          model: opts.judgeModel,
          system: judgeSystemPrompt,
          user: renderForJudge(p, (snap['grid'] as List).cast<String>(), size: job.size.label, weekday: job.weekday),
          reasoningEffort: 'medium',
        );
        return JudgeVerdict.parse(response).toJson();
      } catch (e) {
        return {'error': '$e'};
      }
    }

    final verdicts = await Future.wait([
      judge(puzzle, before),
      if (edited != null) judge(edited, result['after'] as Map<String, dynamic>),
    ]);
    before['judge'] = verdicts[0];
    if (edited != null) (result['after'] as Map<String, dynamic>)['judge'] = verdicts[1];
  }

  final overall = (before['judge'] as Map?)?['scores']?['overall'];
  final after = ((result['after'] as Map?)?['judge'] as Map?)?['scores']?['overall'];
  stdout.writeln(
    '  $tag: ${puzzle.words.length} words in ${genMs}ms, '
    '${(before['lint'] as Map)['flaggedClues']} flagged clues'
    '${overall == null ? '' : ', judge $overall${after == null ? '' : ' → $after'}'}',
  );
  return result;
}

/// One puzzle as the report and summary need it.
Map<String, dynamic> _snapshot(CrosswordPuzzle puzzle, Map<String, CrosswordEntry> byText) {
  final grid = List.generate(puzzle.height, (_) => List.filled(puzzle.width, '#'));
  for (final w in puzzle.words) {
    for (var k = 0; k < w.answer.length; k++) {
      final r = w.direction == CrosswordDirection.across ? w.row : w.row + k;
      final c = w.direction == CrosswordDirection.across ? w.col + k : w.col;
      grid[r][c] = w.answer[k];
    }
  }
  final answers = [for (final w in puzzle.words) w.answer];
  final words = <Map<String, dynamic>>[];
  final fillCounts = <String, int>{};
  final clueCounts = <String, int>{};
  final types = <String, int>{};
  var flaggedClues = 0;
  var flaggedFill = 0;
  for (final w in puzzle.words) {
    final fill = lintFill(w, byText, answers);
    final clue = lintClue(w.answer, w.clue);
    if (fill.isNotEmpty) flaggedFill++;
    if (clue.isNotEmpty) flaggedClues++;
    for (final f in fill) {
      fillCounts[f.name] = (fillCounts[f.name] ?? 0) + 1;
    }
    for (final f in clue) {
      clueCounts[f.name] = (clueCounts[f.name] ?? 0) + 1;
    }
    types[w.clueType.name] = (types[w.clueType.name] ?? 0) + 1;
    final entry = byText[w.answer];
    words.add({
      'number': w.number,
      'dir': w.direction.name,
      'answer': w.answer,
      'clue': w.clue,
      'clueType': w.clueType.name,
      'zipf': w.freqZipf,
      'familiarity': entry?.familiarity,
      'study': w.fromStudyPool,
      'fillFlags': [for (final f in fill) f.name],
      'clueFlags': [for (final f in clue) f.name],
      'clueWords': wordCount(w.clue),
    });
  }
  return {
    'grid': [for (final row in grid) row.join()],
    'words': words,
    'lint': {
      'words': puzzle.words.length,
      'flaggedClues': flaggedClues,
      'flaggedFill': flaggedFill,
      'clueFlags': clueCounts,
      'fillFlags': fillCounts,
      'clueTypes': types,
      'meanClueWords': puzzle.words.isEmpty
          ? 0
          : words.map((w) => w['clueWords'] as int).reduce((a, b) => a + b) / puzzle.words.length,
    },
  };
}

class _Options {
  String label = DateTime.now().toIso8601String().substring(0, 19).replaceAll(':', '-');
  List<CrosswordDifficulty> sizes = CrosswordDifficulty.values;
  int count = 4;
  int seed = 7000;
  bool editor = true;
  bool judge = true;
  String judgeModel = 'gpt-5';
  String editorModel = 'gpt-5-mini';
  String wordlist = 'assets/crossword/wordlist.tsv';

  static _Options parse(List<String> args) {
    final o = _Options();
    for (var i = 0; i < args.length; i++) {
      String next() => args[++i];
      switch (args[i]) {
        case '--label':
          o.label = next();
        case '--sizes':
          o.sizes = [for (final s in next().split(',')) CrosswordDifficulty.fromStorageKey(s.trim())];
        case '--count':
          o.count = int.parse(next());
        case '--seed':
          o.seed = int.parse(next());
        case '--no-editor':
          o.editor = false;
        case '--no-judge':
          o.judge = false;
        case '--judge-model':
          o.judgeModel = next();
        case '--editor-model':
          o.editorModel = next();
        case '--wordlist':
          o.wordlist = next();
        default:
          stderr.writeln('unknown option ${args[i]}');
          exit(64);
      }
    }
    return o;
  }
}
