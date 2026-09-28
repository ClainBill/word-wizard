import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app/environment.dart';
import '../domain/crossword/crossword_models.dart';
import '../domain/crossword/editorial.dart';

import 'ai_gateway.dart';
import 'api_key_store.dart';

/// Asks a model to review a finished puzzle — PORTING_SPEC.md §9.3, and the
/// one place in the whole generator that touches the network.
///
/// ## This is a development configuration, not a shippable one
///
/// `docs/APP_INTEGRATION.md` §4 is unambiguous: **never put the API key in
/// the app.** A key in a mobile binary is extractable in minutes, and then it
/// is your bill, your rate limit and your terms of service. The app should
/// call your backend, and the backend should call OpenAI.
///
/// So this class calls OpenAI directly **only in debug builds**, with the key
/// supplied at build time:
///
/// ```
/// flutter run --dart-define-from-file=.env
/// ```
///
/// A define, rather than a bundled asset, is what keeps the key out of builds
/// that should not have it: an asset listed in `pubspec.yaml` is packaged into
/// *every* artifact including release ones, whereas a define exists only in a
/// build you passed it to. Without it [isConfigured] is false and the pass
/// does nothing at all, which leaves the deterministic puzzle exactly as it
/// was — the same path as no network, a timeout, or a rejected key.
///
/// That backend now exists: a signed-in user's review goes through
/// [AiGateway] to the `ai-crossword-review` Edge Function, which holds the
/// key, the editor's brief, the model and the quota, and never bills the
/// same puzzle twice. The direct path below is what remains for
/// development without an account. [proxyUrl] is an older seam for an
/// endpoint speaking OpenAI's own shape; kept, unused by the app.
///
/// Everything about this pass is optional by construction. It never gates a
/// puzzle, and [review] returns an empty verdict on **any** failure.
/// What one review call returned, including what it billed.
///
/// The verdict alone is not enough to tune this pass: the token counts are
/// the only feedback on what it costs, and [error] is the difference between
/// "the model thought the puzzle was fine" and "the call never happened".
typedef CrosswordReviewResult = ({
  EditorialVerdict verdict,
  String model,
  int promptTokens,

  /// Includes [reasoningTokens] — that is how the API bills it.
  int completionTokens,
  int reasoningTokens,
  int latencyMs,

  /// Empty on success. A short, loggable description of what went wrong.
  String error,
});

/// Per-million-token prices, US dollars, `(input, output)`.
///
/// **Hardcoded, and therefore certain to go stale.** They exist so the debug
/// cost readout is roughly right, not so the app can bill anyone; check
/// OpenAI's pricing page before trusting a total. A model that isn't listed
/// yields a cost of 0, which the UI shows as unknown rather than free.
const Map<String, (double, double)> openAiPricePerMillionTokens = {
  'gpt-5': (1.25, 10.00),
  'gpt-5-mini': (0.25, 2.00),
  'gpt-5-nano': (0.05, 0.40),
};

/// Estimated dollar cost of one call. Reasoning tokens are already inside
/// [completionTokens], so they are not added again.
double estimateCostUsd({
  required String model,
  required int promptTokens,
  required int completionTokens,
}) {
  final price = openAiPricePerMillionTokens[model];
  if (price == null) return 0;
  return promptTokens / 1e6 * price.$1 + completionTokens / 1e6 * price.$2;
}

class CrosswordReviewService {
  /// Measured as the only setting that behaves the same at every puzzle size
  /// (§9.3): `minimal` has the opinion but does not do the work — on a 17x17
  /// it proposed nothing at all — and `medium` is three times slower for no
  /// more edits, once running 23 minutes and returning nothing.
  static const String reasoningEffort = 'low';

  static const String defaultModel = 'gpt-5-mini';

  final String model;

  /// A backend endpoint that speaks the OpenAI chat-completions shape and
  /// holds the key server-side. When set, it is used in every build and no
  /// key is read from the app at all.
  final String? proxyUrl;

  const CrosswordReviewService({this.model = defaultModel, this.proxyUrl});

  /// Supplied by `--dart-define-from-file=.env`, and empty otherwise.
  static const String _definedKey = String.fromEnvironment('OPENAI_API_KEY');

  String? get _apiKey => _keySource?.$1;

  /// The key and where it came from. The source is only ever used in error
  /// text: a 401 from a key the user pasted into Settings and a 401 from a
  /// stale `.env` are fixed in different places, and "HTTP 401" alone does
  /// not say which one was sent.
  (String, String)? get _keySource {
    // A key the user pasted into Settings is theirs to spend, in any build
    // — see ApiKeyStore. The build-time define is for dev-tools builds
    // only (AppEnvironment.devTools): a store build handed it does not
    // call OpenAI directly. A shipping build without a user key goes
    // through [proxyUrl] or not at all.
    final userKey = ApiKeyStore.instance.key;
    if (userKey != null) return (userKey, 'Settings key ${ApiKeyStore.mask(userKey)}');
    if (!AppEnvironment.devTools) return null;
    final key = _definedKey.trim();
    return key.isEmpty ? null : (key, '.env key ${ApiKeyStore.mask(key)}');
  }

  bool get isConfigured => AiGateway.instance.signedIn || proxyUrl != null || _apiKey != null;

  /// Scales the deadline with the puzzle.
  ///
  /// A fixed 90s was fine for a 5x5 and silently swallowed every 17x17 in the
  /// reference implementation: 100 clues took longer than that, the call
  /// timed out, and the pass became a no-op on exactly the puzzles that most
  /// need editing.
  static Duration timeoutFor(CrosswordPuzzle puzzle) =>
      Duration(milliseconds: 45000 + (1500 * puzzle.words.length));

  /// Returns the reviewer's verdict and what the call billed, or an empty
  /// verdict with [CrosswordReviewResult.error] set on any failure.
  Future<CrosswordReviewResult> review(
    CrosswordPuzzle puzzle, {
    required int weekday,
    /// Identifies this puzzle to the backend so a retry, or a second tap,
    /// gets the stored verdict instead of a second bill. Only used through
    /// the gateway.
    String? puzzleKey,

    /// The puzzle's size. The backend's allowance is two edited puzzles a
    /// day per size, so it has to know which one this spends.
    CrosswordDifficulty? difficulty,

    /// A group's daily puzzle, edited by whoever builds it: spends the
    /// backend's group allowance rather than a personal puzzle.
    bool group = false,
  }) async {
    if (AiGateway.instance.signedIn) {
      return _reviewViaGateway(puzzle, weekday, puzzleKey, difficulty, group);
    }

    final source = _keySource;
    final key = source?.$1;
    final url = proxyUrl ?? 'https://api.openai.com/v1/chat/completions';
    if (proxyUrl == null && key == null) return _failed('no API key configured');
    final credential = proxyUrl != null ? 'proxy' : source!.$2;

    final payload = <String, Object?>{
      'model': model,
      'messages': [
        {'role': 'system', 'content': reviewSystemPrompt},
        {'role': 'user', 'content': renderForReview(puzzle, weekday: weekday)},
      ],
      // Reasoning models reject a custom temperature ("only the default (1)
      // is supported"), so none is sent.
      'reasoning_effort': reasoningEffort,
      'response_format': {'type': 'json_object'},
    };

    final clock = Stopwatch()..start();
    final client = HttpClient();
    try {
      // A socket timeout is not a deadline. The reference implementation
      // measured a 1,396-second review against a 240-second socket timeout,
      // because each socket operation reset it. `Future.timeout` bounds the
      // whole call in wall-clock time, which is what this needs.
      final result =
          await _post(client, url, key, payload, credential: credential).timeout(timeoutFor(puzzle));
      return (
        verdict: result.verdict,
        model: model,
        promptTokens: result.promptTokens,
        completionTokens: result.completionTokens,
        reasoningTokens: result.reasoningTokens,
        latencyMs: clock.elapsedMilliseconds,
        error: result.error,
      );
    } on TimeoutException {
      return _failed('timed out after ${timeoutFor(puzzle).inSeconds}s',
          latencyMs: clock.elapsedMilliseconds);
    } catch (error) {
      // No network, a rejected key, a rate limit, malformed JSON: all the
      // same outcome, and the outcome is "the puzzle is exactly as good as it
      // already was".
      return _failed('$error', latencyMs: clock.elapsedMilliseconds);
    } finally {
      // Closes the underlying socket if the deadline fired mid-request; the
      // response, if any, is discarded.
      client.close(force: true);
    }
  }

  Future<CrosswordReviewResult> _reviewViaGateway(
    CrosswordPuzzle puzzle,
    int weekday,
    String? puzzleKey,
    CrosswordDifficulty? difficulty,
    bool group,
  ) async {
    final clock = Stopwatch()..start();
    try {
      final result = await AiGateway.instance.call(
        'ai-crossword-review',
        {
          'puzzle_id': puzzleKey ?? 'seed-${puzzle.seed}-${puzzle.words.length}',
          'rendered': renderForReview(puzzle, weekday: weekday),
          'word_count': puzzle.words.length,
          if (difficulty != null) 'difficulty': difficulty.storageKey,
          if (group) 'allowance': 'group',
        },
        // The function bounds its own call; this only has to outlast it.
        timeout: timeoutFor(puzzle) + const Duration(seconds: 15),
      );
      return (
        verdict: parseVerdict(result.content),
        model: result.model.isEmpty ? model : result.model,
        promptTokens: result.promptTokens,
        completionTokens: result.completionTokens,
        reasoningTokens: result.reasoningTokens,
        latencyMs: clock.elapsedMilliseconds,
        error: '',
      );
    } on AiGatewayException catch (e) {
      // The strip under the app bar shows this, so say which it was.
      final why = switch (e.failure) {
        AiGatewayFailure.quotaExceeded => group
            ? 'today\'s AI edits for group puzzles are used up'
            : 'today\'s AI-edited ${difficulty?.label ?? 'crossword'} puzzles are used up',
        AiGatewayFailure.unavailable => 'AI editor unavailable right now',
        AiGatewayFailure.inProgress => 'already being reviewed',
        AiGatewayFailure.notSignedIn => 'not signed in',
        AiGatewayFailure.network || AiGatewayFailure.other => 'gateway: ${e.message}',
      };
      debugPrint('crossword review (gateway): ${e.failure.name} ${e.message}');
      return _failed(why, latencyMs: clock.elapsedMilliseconds);
    }
  }

  CrosswordReviewResult _failed(String error, {int latencyMs = 0}) => (
        verdict: const EditorialVerdict(),
        model: model,
        promptTokens: 0,
        completionTokens: 0,
        reasoningTokens: 0,
        latencyMs: latencyMs,
        error: error,
      );

  Future<_ReviewResponse> _post(
    HttpClient client,
    String url,
    String? key,
    Map<String, Object?> payload, {
    required String credential,
  }) async {
    final request = await client.postUrl(Uri.parse(url));
    request.headers.contentType = ContentType.json;
    if (key != null) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
    request.write(jsonEncode(payload));

    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();

    if (response.statusCode != HttpStatus.ok) {
      // OpenAI's error body says *why* — "Incorrect API key provided",
      // "insufficient_quota" — and masks the key itself, so it is safe to
      // surface. A 401 also names which credential was sent: that is the
      // difference between fixing Settings and fixing `.env`.
      final detail = _errorMessage(body);
      final error = StringBuffer('HTTP ${response.statusCode}');
      if (response.statusCode == HttpStatus.unauthorized) error.write(' ($credential rejected)');
      if (detail.isNotEmpty) error.write(': $detail');
      debugPrint('crossword review: $error');
      return _ReviewResponse.failed('$error');
    }

    final decoded = jsonDecode(body);
    if (decoded is! Map) return _ReviewResponse.failed('response was not an object');

    // A call that failed to produce a usable verdict still billed for its
    // tokens, so usage is read before anything else can bail out.
    var promptTokens = 0;
    var completionTokens = 0;
    var reasoningTokens = 0;
    final usage = decoded['usage'];
    if (usage is Map) {
      promptTokens = (usage['prompt_tokens'] as num?)?.toInt() ?? 0;
      completionTokens = (usage['completion_tokens'] as num?)?.toInt() ?? 0;
      final details = usage['completion_tokens_details'];
      if (details is Map) {
        reasoningTokens = (details['reasoning_tokens'] as num?)?.toInt() ?? 0;
      }
    }

    String? content;
    final choices = decoded['choices'];
    if (choices is List && choices.isNotEmpty) {
      final message = (choices.first as Map)['message'];
      if (message is Map && message['content'] is String) {
        content = message['content'] as String;
      }
    }

    return _ReviewResponse(
      verdict: content == null ? const EditorialVerdict() : parseVerdict(content),
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      reasoningTokens: reasoningTokens,
      error: content == null ? 'no message content in the response' : '',
    );
  }
}

/// The `error.message` of an OpenAI error body, or empty if the body isn't
/// one — a proxy may answer with anything.
String _errorMessage(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return '';
    final error = decoded['error'];
    if (error is! Map) return '';
    return (error['message'] as String?)?.trim() ?? '';
  } catch (_) {
    return '';
  }
}

/// The raw shape of one API response, before it is stamped with a latency and
/// the model that produced it.
class _ReviewResponse {
  final EditorialVerdict verdict;
  final int promptTokens;
  final int completionTokens;
  final int reasoningTokens;
  final String error;

  const _ReviewResponse({
    required this.verdict,
    required this.promptTokens,
    required this.completionTokens,
    required this.reasoningTokens,
    required this.error,
  });

  factory _ReviewResponse.failed(String error) => _ReviewResponse(
        verdict: const EditorialVerdict(),
        promptTokens: 0,
        completionTokens: 0,
        reasoningTokens: 0,
        error: error,
      );
}
