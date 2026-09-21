import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app/environment.dart';

/// Asks the backend to re-derive the account's entitlement from the store
/// (`entitlement-refresh`), so what the AI quota sees matches what the
/// person just bought — the webhook usually gets there first, but not
/// always (spec §6.5). Signed-out or no backend: nothing to do.
class EntitlementSync {
  static EntitlementSync instance = EntitlementSync.none();

  final AppEnvironment? _env;
  final Future<String?> Function() _accessToken;

  EntitlementSync({required AppEnvironment env, required Future<String?> Function() accessToken})
    : _env = env,
      _accessToken = accessToken;

  EntitlementSync.none() : _env = null, _accessToken = _noToken;

  static Future<String?> _noToken() async => null;

  DateTime? _last;

  /// At most once a minute, as the function asks.
  Future<bool> refresh({bool force = false}) async {
    final env = _env;
    if (env == null || !env.isConfigured) return false;
    final token = await _accessToken();
    if (token == null) return false;
    final now = DateTime.now();
    final last = _last;
    if (!force && last != null && now.difference(last) < const Duration(minutes: 1)) {
      return false;
    }
    _last = now;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.postUrl(env.functionUrl('entitlement-refresh'));
      request.headers.contentType = ContentType.json;
      request.headers.set('apikey', env.supabaseAnonKey);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.write('{}');
      final response = await request.close().timeout(const Duration(seconds: 20));
      final body = await utf8.decodeStream(response);
      if (response.statusCode != 200) {
        debugPrint('entitlement-refresh: HTTP ${response.statusCode} $body');
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('entitlement-refresh: $e');
      return false;
    } finally {
      client.close(force: true);
    }
  }
}
