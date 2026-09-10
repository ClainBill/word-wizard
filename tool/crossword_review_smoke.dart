// Live smoke test for the editorial pass (PORTING_SPEC.md §9.3-§9.4):
// generate a real puzzle, ask OpenAI to review it, then run the verdict
// through the same verification the app uses.
//
//   dart run tool/crossword_review_smoke.dart
//
// Reads OPENAI_API_KEY from .env and **makes a paid API call** (~3k tokens,
// ~20s). It exists because the live path is the one part of the generator a
// unit test cannot cover: the app's own CrosswordReviewService needs a
// Flutter binding, so this reuses the domain functions and issues the same
// request by hand. Keep the payload here in step with that class.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:word_wizard/domain/crossword/crossword_models.dart';
import 'package:word_wizard/domain/crossword/editorial.dart';
import 'package:word_wizard/domain/crossword/generator.dart';
import 'package:word_wizard/domain/crossword/word_list.dart';

Future<void> main(List<String> args) async {
  final env = File('.env').readAsLinesSync();
  final key = env
      .firstWhere((l) => l.startsWith('OPENAI_API_KEY='))
      .split('=')
      .sublist(1)
      .join('=')
      .trim();

  final entries = parseWordList(File('assets/crossword/wordlist.tsv').readAsStringSync());
  final puzzle = generateCrossword(CrosswordGenerationRequest(
    difficulty: CrosswordDifficulty.midi,
    entries: entries,
    srsAnchors: [
      CrosswordEntry.synthetic(
          text: 'SPARE', display: 'spare', entryId: 1, clue: 'Not in use'),
    ],
    blockedAnswers: const {},
    weekday: DateTime.wednesday,
    seed: 20260909,
  ))!;

  final prompt = renderForReview(puzzle, weekday: DateTime.wednesday);
  stdout.writeln(prompt);
  stdout.writeln('\n--- calling gpt-5-mini, reasoning_effort low ---');

  final clock = Stopwatch()..start();
  final client = HttpClient();
  final request = await client.postUrl(Uri.parse('https://api.openai.com/v1/chat/completions'));
  request.headers.contentType = ContentType.json;
  request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
  request.write(jsonEncode({
    'model': 'gpt-5-mini',
    'messages': [
      {'role': 'system', 'content': reviewSystemPrompt},
      {'role': 'user', 'content': prompt},
    ],
    'reasoning_effort': 'low',
    'response_format': {'type': 'json_object'},
  }));
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  clock.stop();
  client.close();

  stdout.writeln('HTTP ${response.statusCode} in ${clock.elapsed.inSeconds}s');
  if (response.statusCode != 200) {
    stdout.writeln(body.substring(0, min(600, body.length)));
    return;
  }
  final decoded = jsonDecode(body) as Map;
  stdout.writeln('usage: ${decoded['usage']}');
  final content = (decoded['choices'] as List).first['message']['content'] as String;

  final verdict = parseVerdict(content);
  stdout.writeln('entertainment ${verdict.entertainment}, notes: ${verdict.notes}');
  stdout.writeln('clue edits: ${verdict.clueEdits.length}, '
      'banned answers: ${verdict.bannedAnswers.length}');

  final index = CrosswordPatternIndex.build(entries.where(inFillPool));
  final revision = revisePuzzle(
    puzzle: puzzle,
    verdict: verdict,
    index: index,
    blockedAnswers: const {},
    seed: puzzle.seed,
  );
  stdout.writeln('applied: ${revision.cluesApplied} clues, '
      '${revision.wordsApplied} bans');
  stdout.writeln('rejected clues: ${revision.cluesRejected}');
  stdout.writeln('ban failure: ${revision.wordsRejectedReason}');
  for (final edit in revision.edits.where((e) => e.isWordEdit)) {
    stdout.writeln('  banned ${edit.before}'
        '${edit.applied ? ' -> solver chose ${edit.after}' : ' (${edit.rejection})'}');
  }
  stdout.writeln('assertPuzzleValid: ${assertPuzzleValid(revision.puzzle)}');

  // Answers and clues are reported separately: after a ban re-fills part of
  // the grid, comparing a slot's old clue with its new one would be comparing
  // clues for two different answers.
  final before = {for (final w in puzzle.words) w.slotId: w};
  stdout.writeln('answers changed:');
  for (final w in revision.puzzle.words) {
    final was = before[w.slotId]!;
    if (was.answer != w.answer) {
      stdout.writeln('  ${was.answer} -> ${w.answer}  (${w.clue})');
    }
  }
  stdout.writeln('clues rewritten (same answer):');
  for (final w in revision.puzzle.words) {
    final was = before[w.slotId]!;
    if (was.answer == w.answer && was.clue != w.clue) {
      stdout.writeln('  ${w.answer}: "${was.clue}" -> "${w.clue}"');
    }
  }
}
