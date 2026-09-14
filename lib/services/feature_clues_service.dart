import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'api_key_store.dart';

/// Generates 2-3 short "semantic feature" clues about a word's meaning for
/// the study session's pre-reveal recall game — clues that circle the
/// meaning (category, a typical context, an associated feeling, a
/// near-synonym) without ever paraphrasing the definition verbatim or using
/// the headword itself, so answering them takes genuine recall rather than
/// picking from a list.
///
/// Same development-only calling convention as `CrosswordReviewService`:
/// docs/APP_INTEGRATION.md §4 says never ship an API key in the app, so this
/// only calls OpenAI directly in debug builds, with the key supplied at
/// build time via `--dart-define-from-file=.env`. A shipping build should
/// route this through a backend proxy instead — [proxyUrl] is that seam.
/// [isConfigured] is false, and the recall game simply isn't offered,
/// without a key or proxy — the same path as no network or a rejected key.
class FeatureCluesService {
  static const String defaultModel = 'gpt-5-mini';

  final String model;
  final String? proxyUrl;

  const FeatureCluesService({this.model = defaultModel, this.proxyUrl});

  /// Supplied by `--dart-define-from-file=.env`, and empty otherwise.
  static const String _definedKey = String.fromEnvironment('OPENAI_API_KEY');

  String? get _apiKey {
    // A key the user pasted into Settings is theirs to spend, in any build
    // — see ApiKeyStore. The build-time define stays debug-only: even if a
    // release build is handed it, it does not call OpenAI directly. A
    // shipping build without a user key goes through [proxyUrl] or not at
    // all.
    final userKey = ApiKeyStore.instance.key;
    if (userKey != null) return userKey;
    if (kReleaseMode) return null;
    final key = _definedKey.trim();
    return key.isEmpty ? null : key;
  }

  bool get isConfigured => proxyUrl != null || _apiKey != null;

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
    } catch (error) {
      debugPrint('feature clues: $error');
      return const [];
    } finally {
      client.close(force: true);
    }
  }
}
