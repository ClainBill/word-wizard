import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../app/environment.dart';

import 'package:flutter/foundation.dart';

import 'ai_gateway.dart';
import 'api_key_store.dart';

/// Generates 2-3 short "semantic feature" clues about a word's meaning for
/// the study session's pre-reveal recall game — clues that circle the
/// meaning (category, a typical context, an associated feeling, a
/// near-synonym) without ever paraphrasing the definition verbatim or using
/// the headword itself, so answering them takes genuine recall rather than
/// picking from a list.
///
/// A signed-in user goes through [AiGateway] — the `ai-feature-clues` Edge
/// Function holds the key, the prompt, the model and the quota. Without an
/// account the development convention applies, as `CrosswordReviewService`
/// documents: OpenAI is called directly only in debug builds with the key
/// from `--dart-define-from-file=.env`, or with a key the user pasted into
/// Settings. [isConfigured] is false, and the recall game simply isn't
/// offered, with none of those — the same path as no network.
class FeatureCluesService {
  static const String defaultModel = 'gpt-5-mini';

  final String model;
  final String? proxyUrl;

  const FeatureCluesService({this.model = defaultModel, this.proxyUrl});

  /// Supplied by `--dart-define-from-file=.env`, and empty otherwise.
  static const String _definedKey = String.fromEnvironment('OPENAI_API_KEY');

  String? get _apiKey {
    // A key the user pasted into Settings is theirs to spend, in any build
    // — see ApiKeyStore. The build-time define is for dev-tools builds
    // only (AppEnvironment.devTools): a store build handed it does not
    // call OpenAI directly. A shipping build without a user key goes
    // through [proxyUrl] or not at all.
    final userKey = ApiKeyStore.instance.key;
    if (userKey != null) return userKey;
    if (!AppEnvironment.devTools) return null;
    final key = _definedKey.trim();
    return key.isEmpty ? null : key;
  }

  bool get isConfigured => AiGateway.instance.signedIn || proxyUrl != null || _apiKey != null;

  static const _timeout = Duration(seconds: 12);

  static const _systemPrompt = '''
You write short recall-jog clues for a vocabulary flashcard app. Given a
word, its part of speech, and its definition, write exactly 3 short clues
(under 12 words each) that circle the word's meaning without paraphrasing
the definition and without ever using the headword or an obvious inflection
of it. Mix clue types: one about its category or a typical context it
appears in, one about an associated feeling, image, or example, and one
synonym or near-synonym. Reply with strict JSON of the shape
{"clues": ["...", "...", "..."]} and nothing else.''';

  /// Returns 2-3 short clues, or an empty list on any failure — no key, no
  /// network, a timeout, a malformed response, or a clue that slipped and
  /// contains the headword. The caller treats an empty list exactly like
  /// "this game type isn't available for this word".
  Future<List<String>> clues({
    required String headword,
    required String pos,
    required String gloss,
  }) async {
    if (AiGateway.instance.signedIn) {
      try {
        final result = await AiGateway.instance.call(
          'ai-feature-clues',
          {'headword': headword, 'pos': pos, 'gloss': gloss},
          timeout: _timeout + const Duration(seconds: 5),
        );
        return _parseClues(result.content, headword);
      } on AiGatewayException catch (e) {
        // Quota, outage, no network: the game type just isn't available
        // for this word, which is what an empty list means to the caller.
        debugPrint('feature clues (gateway): ${e.failure.name} ${e.message}');
        return const [];
      }
    }

    final key = _apiKey;
    final url = proxyUrl ?? 'https://api.openai.com/v1/chat/completions';
    if (proxyUrl == null && key == null) return const [];

    final payload = <String, Object?>{
      'model': model,
      'messages': [
        {'role': 'system', 'content': _systemPrompt},
        {
          'role': 'user',
          'content': 'Word: $headword\nPart of speech: $pos\nDefinition: $gloss',
        },
      ],
      'response_format': {'type': 'json_object'},
    };

    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse(url));
      request.headers.contentType = ContentType.json;
      if (key != null) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
      request.write(jsonEncode(payload));

      final response = await request.close().timeout(_timeout);
      final body = await response.transform(utf8.decoder).join().timeout(_timeout);
      if (response.statusCode != HttpStatus.ok) {
        debugPrint('feature clues: HTTP ${response.statusCode}');
        return const [];
      }

      final decoded = jsonDecode(body);
      if (decoded is! Map) return const [];
      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty) return const [];
      final message = (choices.first as Map)['message'];
      final content = message is Map ? message['content'] : null;
      if (content is! String) return const [];

      return _parseClues(content, headword);
    } catch (error) {
      debugPrint('feature clues: $error');
      return const [];
    } finally {
      client.close(force: true);
    }
  }

  /// The model's `{"clues": [...]}`, minus anything that gives the word
  /// away. Empty on malformed content.
  static List<String> _parseClues(String content, String headword) {
    try {
      final parsed = jsonDecode(content);
      final rawClues = parsed is Map ? parsed['clues'] : null;
      if (rawClues is! List) return const [];
      final lowerHeadword = headword.toLowerCase();
      return rawClues
          .whereType<String>()
          .map((c) => c.trim())
          .where((c) => c.isNotEmpty && !c.toLowerCase().contains(lowerHeadword))
          .take(3)
          .toList();
    } catch (_) {
      return const [];
    }
  }
}
