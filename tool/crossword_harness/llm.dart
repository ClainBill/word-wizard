// The two model calls the harness makes: the production editor (same
// prompt, model and settings as the `ai-crossword-review` Edge Function)
// and a separate judge that scores a finished puzzle the way a crossword
// editor would. The judge is deliberately a different, stronger model than
// the editor — grading its own homework would flatter it.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:word_wizard/domain/crossword/crossword_models.dart';

/// USD per million tokens (input, output), as in `app_config.ai_prices`.
const _prices = {
  'gpt-5': (1.25, 10.0),
  'gpt-5-mini': (0.25, 2.0),
  'gpt-5-nano': (0.05, 0.4),
};

class ChatResult {
  final String content;
  final int promptTokens;
  final int completionTokens;
  final double costUsd;
  final int latencyMs;

  const ChatResult(this.content, this.promptTokens, this.completionTokens, this.costUsd, this.latencyMs);
}

class OpenAi {
  final String key;
  OpenAi(this.key);

  /// Reads OPENAI_API_KEY from the environment, else from `.env`.
  static OpenAi? fromEnvironment() {
    final env = Platform.environment['OPENAI_API_KEY'];
    if (env != null && env.isNotEmpty) return OpenAi(env);
    final file = File('.env');
    if (!file.existsSync()) return null;
    for (final line in file.readAsLinesSync()) {
      if (line.startsWith('OPENAI_API_KEY=')) {
        final value = line.substring('OPENAI_API_KEY='.length).trim();
        if (value.isNotEmpty) return OpenAi(value);
      }
    }
    return null;
  }

  Future<ChatResult> chat({
    required String model,
    required String system,
    required String user,
    String? reasoningEffort,
    int maxOutputTokens = 16000,
    Duration timeout = const Duration(minutes: 4),
  }) async {
    for (var attempt = 1; ; attempt++) {
      final clock = Stopwatch()..start();
      final client = HttpClient();
      try {
        final request = await client.postUrl(Uri.parse('https://api.openai.com/v1/chat/completions'));
        request.headers.contentType = ContentType.json;
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
        request.write(
          jsonEncode({
            'model': model,
            'messages': [
              {'role': 'system', 'content': system},
              {'role': 'user', 'content': user},
            ],
            'response_format': {'type': 'json_object'},
            'max_completion_tokens': maxOutputTokens,
            'reasoning_effort': ?reasoningEffort,
          }),
        );
        final response = await request.close().timeout(timeout);
        final body = await response.transform(utf8.decoder).join().timeout(timeout);
        if (response.statusCode == 429 || response.statusCode >= 500) {
          if (attempt < 4) {
            await Future<void>.delayed(Duration(seconds: 5 * attempt));
            continue;
          }
        }
        if (response.statusCode != 200) {
          throw HttpException('OpenAI ${response.statusCode}: ${body.substring(0, body.length.clamp(0, 400))}');
        }
        final decoded = jsonDecode(body) as Map<String, dynamic>;
        final usage = decoded['usage'] as Map<String, dynamic>? ?? const {};
        final prompt = (usage['prompt_tokens'] as num?)?.toInt() ?? 0;
        final completion = (usage['completion_tokens'] as num?)?.toInt() ?? 0;
        final price = _prices.entries.where((e) => model.startsWith(e.key)).lastOrNull?.value ?? (0.0, 0.0);
        return ChatResult(
          (decoded['choices'] as List).first['message']['content'] as String? ?? '',
          prompt,
          completion,
          (prompt * price.$1 + completion * price.$2) / 1e6,
          clock.elapsedMilliseconds,
        );
      } on TimeoutException {
        if (attempt < 3) continue;
        rethrow;
      } finally {
        client.close(force: true);
      }
    }
  }
}

/// The editor's brief exactly as production sends it: read from the Edge
/// Function's own source, so the harness can never drift from it.
String productionEditorPrompt() {
  final source = File('supabase/functions/_shared/prompts.ts').readAsStringSync();
  final match = RegExp(r'crosswordReviewSystemPrompt = `([\s\S]*?)`\.trim\(\)').firstMatch(source);
  if (match == null) throw StateError('crosswordReviewSystemPrompt not found in prompts.ts');
  return match.group(1)!.trim();
}

// ---------------------------------------------------------------------
// The judge
// ---------------------------------------------------------------------

const judgeSystemPrompt = '''
You are a veteran newspaper crossword editor (think New York Times or Guardian quick crossword) reviewing a submitted puzzle for a vocabulary-learning app. Its solvers are fluent adult English readers who like words, not crossword veterans: an answer they are unlikely to know, or a clue that reads like a dictionary, is a failure.

Judge the puzzle as published. Be strict and specific — the point is to find what is wrong, not to be encouraging. A puzzle you would print unchanged in a good newspaper is a 9-10; one a solver would find tedious or unfair is a 3-4.

Score 1-10 each:
- fill: are the answers real, familiar words and names? Penalise abbreviations, initialisms, obscure words, crosswordese, partial phrases, niche proper nouns, and ugly or forced entries.
- clues: are they accurate, concise (ideally 2-8 words), in a newspaper register, pointing at the common sense of the word, and fair? Penalise dictionary-style definitions, overlong or multi-part clues, technical/scientific register, factual errors, clues that give the answer away, and clues that barely identify it.
- variety: do the clues vary in type (synonym, definition, fill-in-the-blank, wordplay-lite) or is every clue the same shape?
- fun: would a solver enjoy it?
- overall: would you publish it as is?

List EVERY answer you would reject and EVERY clue you would rewrite. For a clue, give a category: wrong (factually or points at the wrong sense), dictionary (reads like a definition), long, technical, obscure (clue is fine but answer too hard to get from it), leak (gives the answer away), awkward, other. Suggest a better clue for each.

Return strict JSON only:
{"fill": n, "clues": n, "variety": n, "fun": n, "overall": n,
 "summary": "two or three sentences on the biggest problems",
 "bad_answers": [{"answer": "...", "why": "..."}],
 "bad_clues": [{"answer": "...", "clue": "...", "category": "...", "why": "...", "better": "..."}]}''';

/// The puzzle as a solver sees it, plus the answers (the judge needs them).
String renderForJudge(CrosswordPuzzle puzzle, List<String> gridRows, {required String size, required int weekday}) {
  const days = ['', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  final b = StringBuffer()
    ..writeln('A $size crossword (${puzzle.width}x${puzzle.height}) for ${days[weekday]}'
        '${puzzle.themeName == null ? '' : ', theme: ${puzzle.themeName}'}.')
    ..writeln()
    ..writeln('Grid (# is a black square):');
  for (final row in gridRows) {
    b.writeln(row.split('').join(' '));
  }
  for (final dir in CrosswordDirection.values) {
    b
      ..writeln()
      ..writeln(dir == CrosswordDirection.across ? 'ACROSS' : 'DOWN');
    final words = puzzle.words.where((w) => w.direction == dir).toList()
      ..sort((a, c) => a.number.compareTo(c.number));
    for (final w in words) {
      b.writeln('${w.number}. ${w.clue}  = ${w.answer}');
    }
  }
  return b.toString();
}

class JudgeVerdict {
  final Map<String, num> scores;
  final String summary;
  final List<Map<String, dynamic>> badAnswers;
  final List<Map<String, dynamic>> badClues;
  final double costUsd;

  const JudgeVerdict(this.scores, this.summary, this.badAnswers, this.badClues, this.costUsd);

  Map<String, dynamic> toJson() => {
    'scores': scores,
    'summary': summary,
    'badAnswers': badAnswers,
    'badClues': badClues,
    'costUsd': costUsd,
  };

  static JudgeVerdict parse(ChatResult result) {
    final json = jsonDecode(result.content) as Map<String, dynamic>;
    List<Map<String, dynamic>> list(String key) => [
      for (final x in json[key] as List? ?? const []) Map<String, dynamic>.from(x as Map),
    ];
    return JudgeVerdict(
      {
        for (final k in ['fill', 'clues', 'variety', 'fun', 'overall'])
          if (json[k] is num) k: json[k] as num,
      },
      json['summary'] as String? ?? '',
      list('bad_answers'),
      list('bad_clues'),
      result.costUsd,
    );
  }
}
