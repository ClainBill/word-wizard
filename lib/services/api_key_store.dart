import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The OpenAI key the user typed into Settings, if any.
///
/// `docs/APP_INTEGRATION.md` §4's rule — never put a key *in the app* — is
/// about a key baked into the binary, shared by every install and
/// extractable by anyone. A key the user pastes in themselves is a different
/// thing: it's their key, their bill, entered on their device, and it never
/// leaves that device except in calls to OpenAI. So this is the one path
/// that's allowed in a release build, where the build-time define is not
/// (`CrosswordReviewService._apiKey`, `FeatureCluesService._apiKey`).
///
/// Kept in the platform keystore (`flutter_secure_storage`) rather than the
/// settings table, and mirrored in memory after [load] so the services can
/// check it synchronously — the study session decides whether to offer the
/// feature-clues game without an await.
class ApiKeyStore extends ChangeNotifier {
  ApiKeyStore._();

  static final ApiKeyStore instance = ApiKeyStore._();

  static const _storageKey = 'openai_api_key';
  static const _storage = FlutterSecureStorage();

  String? _key;
  bool _loaded = false;

  /// The stored key, or null when none is set (or [load] hasn't run yet).
  String? get key => _key;

  bool get hasKey => _key != null;

  bool get isLoaded => _loaded;

  /// Reads the key from secure storage into memory. Called once at startup;
  /// a storage failure just means "no key", the same as never having set one.
  Future<void> load() async {
    try {
      final stored = await _storage.read(key: _storageKey);
      _key = stored == null || stored.trim().isEmpty ? null : stored.trim();
    } catch (e) {
      debugPrint('ApiKeyStore: could not read key: $e');
      _key = null;
    }
    _loaded = true;
    notifyListeners();
  }

  /// One token of key-ish characters. OpenAI keys are `sk-` plus letters,
  /// digits, `_` and `-`; the point is to reject a pasted paragraph (or a
  /// key with a newline on the end) before it reaches an HTTP header, where
  /// it would throw rather than fail cleanly.
  static final _keyShape = RegExp(r'^[A-Za-z0-9_\-]{20,}$');

  static bool looksLikeKey(String key) => _keyShape.hasMatch(key.trim());

  /// Throws [ArgumentError] for something that can't be a key — callers
  /// check [looksLikeKey] first.
  Future<void> save(String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) return clear();
    if (!looksLikeKey(trimmed)) throw ArgumentError('not an API key');
    await _storage.write(key: _storageKey, value: trimmed);
    _key = trimmed;
    notifyListeners();
  }

  Future<void> clear() async {
    await _storage.delete(key: _storageKey);
    _key = null;
    notifyListeners();
  }

  /// "sk-…abcd" — enough to recognise a key without showing it.
  static String mask(String key) {
    if (key.length <= 8) return '••••';
    return '${key.substring(0, 3)}…${key.substring(key.length - 4)}';
  }

  /// Checks a key against OpenAI without spending tokens — one GET of the
  /// model the app uses. Returns null when the key works, otherwise a short
  /// message for the Settings screen.
  static Future<String?> validate(String key, {String model = 'gpt-5-mini'}) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) return 'Enter a key first.';
    if (!looksLikeKey(trimmed)) return 'That doesn\'t look like an API key.';
    final client = HttpClient();
    try {
      final request = await client
          .getUrl(Uri.parse('https://api.openai.com/v1/models/$model'))
          .timeout(const Duration(seconds: 10));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $trimmed');
      final response = await request.close().timeout(const Duration(seconds: 15));
      final body = await response.transform(utf8.decoder).join();
      switch (response.statusCode) {
        case 200:
          return null;
        case 401:
          return 'OpenAI rejected this key.';
        case 403:
          return 'This key isn\'t allowed to use $model.';
        case 404:
          return 'The key works, but $model isn\'t available to it.';
        case 429:
          return 'The key works, but the account is over its quota or rate limit.';
        default:
          String detail = '';
          try {
            final json = jsonDecode(body) as Map<String, Object?>;
            detail = ((json['error'] as Map?)?['message'] as String?) ?? '';
          } catch (_) {
            // Not JSON — the status code is all there is.
          }
          return 'OpenAI returned ${response.statusCode}${detail.isEmpty ? '' : ': $detail'}';
      }
    } on TimeoutException {
      return 'OpenAI didn\'t answer in time. Check the connection and try again.';
    } on SocketException {
      return 'No connection to OpenAI.';
    } catch (e) {
      // Never echo the input back: a bad paste could be anything.
      return 'Couldn\'t check the key (${e.runtimeType}).';
    } finally {
      client.close(force: true);
    }
  }
}
