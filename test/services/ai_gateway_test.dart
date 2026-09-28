import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/app/environment.dart';
import 'package:word_wizard/domain/crossword/crossword_models.dart';
import 'package:word_wizard/domain/crossword/generator.dart';
import 'package:word_wizard/services/ai_gateway.dart';
import 'package:word_wizard/services/crossword_review_service.dart';
import 'package:word_wizard/services/feature_clues_service.dart';

/// The gateway and both AI services against a stand-in for the Edge
/// Functions: what goes over the wire, and what each status code becomes.
void main() {
  late HttpServer server;
  final requests = <({String path, Map<String, String> headers, Map<String, dynamic> body})>[];
  int Function() status = () => 200;
  Map<String, dynamic> Function() reply = () => const {};

  setUp(() async {
    requests.clear();
    status = () => 200;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body = jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
      final headers = <String, String>{};
      req.headers.forEach((k, v) => headers[k] = v.join(','));
      requests.add((path: req.uri.path, headers: headers, body: body));
      req.response
        ..statusCode = status()
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(reply()));
      await req.response.close();
    });
    AiGateway.instance = AiGateway(
      env: AppEnvironment(
        env: AppEnv.dev,
        supabaseUrl: 'http://127.0.0.1:${server.port}',
        supabaseAnonKey: 'anon-key',
      ),
      hasSession: () => true,
      accessToken: () async => 'user-jwt',
    );
  });

  tearDown(() async {
    AiGateway.instance = const AiGateway.unconfigured();
    await server.close(force: true);
  });

  test('a call carries the session and the anon key to the function', () async {
    reply = () => {
      'content': '{"clues":["a","b","c"]}',
      'model': 'gpt-5-mini',
      'usage': {'prompt_tokens': 10, 'completion_tokens': 20, 'reasoning_tokens': 5},
      'cached': false,
      'remaining': 29,
    };
    final result = await AiGateway.instance.call('ai-feature-clues', {
      'headword': 'x',
    }, timeout: const Duration(seconds: 5));
    expect(requests.single.path, '/functions/v1/ai-feature-clues');
    expect(requests.single.headers['authorization'], 'Bearer user-jwt');
    expect(requests.single.headers['apikey'], 'anon-key');
    expect(result.content, '{"clues":["a","b","c"]}');
    expect(result.promptTokens, 10);
    expect(result.reasoningTokens, 5);
    expect(result.remaining, 29);
    expect(result.cached, isFalse);
  });

  test('status codes become the failures the UI keys on', () {
    expect(
      () => AiGateway.decode(401, '{"error":"unauthenticated"}'),
      throwsA(predicate<AiGatewayException>((e) => e.failure == AiGatewayFailure.notSignedIn)),
    );
    expect(
      () => AiGateway.decode(
        402,
        '{"error":"quota_exceeded","resets_at":"2026-09-18T00:00:00Z","premium":false}',
      ),
      throwsA(
        predicate<AiGatewayException>(
          (e) =>
              e.failure == AiGatewayFailure.quotaExceeded &&
              e.quotaResetsAt == DateTime.utc(2026, 9, 18) &&
              !e.premium,
        ),
      ),
    );
    expect(
      () => AiGateway.decode(409, '{"error":"in_progress"}'),
      throwsA(predicate<AiGatewayException>((e) => e.failure == AiGatewayFailure.inProgress)),
    );
    expect(
      () => AiGateway.decode(503, '{"error":"ai_unavailable"}'),
      throwsA(predicate<AiGatewayException>((e) => e.failure == AiGatewayFailure.unavailable)),
    );
    expect(
      () => AiGateway.decode(200, 'not json'),
      throwsA(predicate<AiGatewayException>((e) => e.failure == AiGatewayFailure.other)),
    );
  });

  test('signed out, the gateway is not used and reports itself unavailable', () {
    AiGateway.instance = AiGateway(
      env: const AppEnvironment(env: AppEnv.dev, supabaseUrl: 'http://x', supabaseAnonKey: 'k'),
      hasSession: () => false,
      accessToken: () async => null,
    );
    expect(AiGateway.instance.signedIn, isFalse);
    expect(
      const FeatureCluesService().isConfigured,
      isFalse,
      reason: 'no session, no debug key, no user key',
    );
  });

  test('feature clues go through the function and are filtered as before', () async {
    reply = () => {'content': '{"clues":["Something serene and calm","A quiet lake","Peaceful"]}'};
    final clues = await const FeatureCluesService().clues(
      headword: 'serene',
      pos: 'adjective',
      gloss: 'calm and peaceful',
    );
    expect(requests.single.body, {
      'headword': 'serene',
      'pos': 'adjective',
      'gloss': 'calm and peaceful',
    });
    expect(clues, [
      'A quiet lake',
      'Peaceful',
    ], reason: 'the clue containing the headword is dropped');

    status = () => 402;
    reply = () => {'error': 'quota_exceeded'};
    expect(await const FeatureCluesService().clues(headword: 'x', pos: 'n', gloss: 'y'), isEmpty);
  });

  test(
    'a crossword review sends the rendered puzzle keyed by puzzle, and reads the verdict',
    () async {
      final source = File('assets/crossword/wordlist.tsv').readAsStringSync();
      final puzzle = generateCrosswordFromSource(
        CrosswordIsolateRequest(
          wordListSource: source,
          difficulty: CrosswordDifficulty.mini,
          srsWords: const [],
          blockedAnswers: const {},
          weekday: DateTime.monday,
          seed: 99,
        ),
      )!;
      final target = puzzle.words.first;
      reply = () => {
        'content': jsonEncode({
          'entertainment': 7,
          'notes': 'fine',
          'clue_edits': {'${target.slotId}': 'A replacement clue that breaks no rules'},
          'banned_answers': {},
        }),
        'model': 'gpt-5-mini',
        'usage': {'prompt_tokens': 500, 'completion_tokens': 120, 'reasoning_tokens': 40},
      };
      final result = await const CrosswordReviewService().review(
        puzzle,
        weekday: DateTime.monday,
        puzzleKey: 'puzzle-7-99',
        difficulty: CrosswordDifficulty.midi,
      );
      expect(requests.single.path, '/functions/v1/ai-crossword-review');
      expect(requests.single.body['puzzle_id'], 'puzzle-7-99');
      expect(requests.single.body['word_count'], puzzle.words.length);
      // The allowance is per size, so the size goes with the request.
      expect(requests.single.body['difficulty'], 'midi');
      expect(requests.single.body['rendered'], contains(target.answer));
      expect(result.error, isEmpty);
      expect(result.verdict.clueEdits[target.slotId], 'A replacement clue that breaks no rules');
      expect(result.promptTokens, 500);
      expect(result.reasoningTokens, 40);

      // Quota: an empty verdict with a reason the status strip can show.
      status = () => 402;
      reply = () => {'error': 'quota_exceeded'};
      final refused = await const CrosswordReviewService().review(
        puzzle,
        weekday: DateTime.monday,
        difficulty: CrosswordDifficulty.midi,
      );
      expect(refused.verdict.isEmpty, isTrue);
      expect(refused.error, contains('AI-edited Midi puzzles are used up'));
    },
  );
}
