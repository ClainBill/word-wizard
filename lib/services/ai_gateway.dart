import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app/environment.dart';

/// What an AI function answered — see supabase/README.md, "the contract".
class AiGatewayResult {
  /// The model's JSON string, as the app has always parsed it.
  final String content;
  final String model;
  final int promptTokens;
  final int completionTokens;
  final int reasoningTokens;

  /// A stored answer for a key seen before: nothing was billed.
  final bool cached;

  /// Calls left today for this kind, when the server said.
  final int? remaining;

  const AiGatewayResult({
    required this.content,
    required this.model,
    required this.promptTokens,
    required this.completionTokens,
    required this.reasoningTokens,
    required this.cached,
    this.remaining,
  });
}

enum AiGatewayFailure {
  /// No account: the gateway can't be used, and the caller falls back.
  notSignedIn,

  /// Today's allowance for this kind is spent; `quotaResetsAt` says when.
  quotaExceeded,

  /// The kill switch, the global cap, or the provider is down.
  unavailable,

  /// The same key is being worked on already.
  inProgress,
  network,
  other,
}

class AiGatewayException implements Exception {
  final AiGatewayFailure failure;
  final String message;
  final int? status;
  final DateTime? quotaResetsAt;
  final bool premium;

  const AiGatewayException(
    this.failure,
    this.message, {
    this.status,
    this.quotaResetsAt,
    this.premium = false,
  });

  @override
  String toString() => message;
}

/// The app's door to the AI Edge Functions: adds the session token, speaks
/// the functions' contract, turns their status codes into
/// [AiGatewayException]s the services and the UI can act on.
///
/// A singleton the two AI services consult at call time, like
/// `ApiKeyStore.instance`, because both are built `const` in places. Left
/// unconfigured — no backend, or in tests — it reports [signedIn] false
/// and the services use their direct path exactly as before.
class AiGateway {
  static AiGateway instance = const AiGateway.unconfigured();

  final AppEnvironment? _env;
  final bool Function() _hasSession;
  final Future<String?> Function() _accessToken;

  const AiGateway({
    required AppEnvironment env,
    required bool Function() hasSession,
    required Future<String?> Function() accessToken,
  }) : _env = env,
       _hasSession = hasSession,
       _accessToken = accessToken;

  const AiGateway.unconfigured() : _env = null, _hasSession = _never, _accessToken = _noToken;

  static bool _never() => false;
  static Future<String?> _noToken() async => null;

  bool get configured => _env != null && _env.isConfigured;

  /// Whether a call would be authenticated: the backend is configured and
  /// someone is signed in. Synchronous so `isConfigured` getters stay so.
  bool get signedIn => configured && _hasSession();

  Future<AiGatewayResult> call(
    String function,
    Map<String, Object?> body, {
    required Duration timeout,
  }) async {
    final env = _env;
    if (env == null || !env.isConfigured) {
      throw const AiGatewayException(AiGatewayFailure.notSignedIn, 'no backend configured');
    }
    final token = await _accessToken();
    if (token == null) {
      throw const AiGatewayException(AiGatewayFailure.notSignedIn, 'not signed in');
    }

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.postUrl(env.functionUrl(function));
      request.headers.contentType = ContentType.json;
      request.headers.set('apikey', env.supabaseAnonKey);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.write(jsonEncode(body));
      final response = await request.close().timeout(timeout);
      final text = await utf8.decodeStream(response).timeout(timeout);
      return _decode(response.statusCode, text);
    } on AiGatewayException {
      rethrow;
    } on TimeoutException {
      throw AiGatewayException(AiGatewayFailure.network, 'timed out after ${timeout.inSeconds}s');
    } catch (e) {
      throw AiGatewayException(AiGatewayFailure.network, '$e');
    } finally {
      client.close(force: true);
    }
  }

  @visibleForTesting
  static AiGatewayResult decode(int status, String text) => _decode(status, text);

  static AiGatewayResult _decode(int status, String text) {
    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(text);
      json = decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      json = const {};
    }
    if (status == 200) {
      final content = json['content'];
      if (content is! String) {
        throw const AiGatewayException(
          AiGatewayFailure.other,
          'no content in the response',
          status: 200,
        );
      }
      final usage = json['usage'];
      int tokens(String key) => usage is Map ? (usage[key] as num?)?.toInt() ?? 0 : 0;
      return AiGatewayResult(
        content: content,
        model: json['model'] as String? ?? '',
        promptTokens: tokens('prompt_tokens'),
        completionTokens: tokens('completion_tokens'),
        reasoningTokens: tokens('reasoning_tokens'),
        cached: json['cached'] == true,
        remaining: (json['remaining'] as num?)?.toInt(),
      );
    }
    final code = json['error'] as String? ?? 'HTTP $status';
    switch (status) {
      case 401:
        throw AiGatewayException(AiGatewayFailure.notSignedIn, code, status: status);
      case 402:
        throw AiGatewayException(
          AiGatewayFailure.quotaExceeded,
          'daily limit reached',
          status: status,
          quotaResetsAt: DateTime.tryParse(json['resets_at'] as String? ?? ''),
          premium: json['premium'] == true,
        );
      case 409:
        throw AiGatewayException(AiGatewayFailure.inProgress, code, status: status);
      case 429:
      case 503:
        throw AiGatewayException(AiGatewayFailure.unavailable, code, status: status);
      default:
        throw AiGatewayException(AiGatewayFailure.other, code, status: status);
    }
  }
}
