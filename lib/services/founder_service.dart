import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app/environment.dart';
import '../domain/premium/premium.dart';

/// The Founding Member allocation lives on the server (spec §6.3): the
/// app asks how many places remain, and reserves one for a few minutes
/// before it opens the store sheet, so the 500th place can't be sold
/// twice. The exact count is only ever shown fresh from here.
abstract class FounderService {
  /// Whether reserving needs a signed-in account — a Founding Member
  /// place is tied to one. The paywall asks for the sign-in first.
  bool get needsAccount;

  /// Null when the backend can't say — the paywall then shows "Limited to
  /// 500 completed purchases" and doesn't sell.
  Future<FounderStatus?> status();

  /// A reservation id, or throws [FounderSoldOut] / [FounderReserveFailed].
  Future<String> reserve();
}

class FounderSoldOut implements Exception {
  const FounderSoldOut();
}

class FounderReserveFailed implements Exception {
  final String message;
  const FounderReserveFailed(this.message);
  @override
  String toString() => message;
}

/// Over the `founder-status` / `founder-reserve` Edge Functions.
class HttpFounderService implements FounderService {
  final AppEnvironment _env;
  final Future<String?> Function() _accessToken;

  HttpFounderService(this._env, {required Future<String?> Function() accessToken})
    : _accessToken = accessToken;

  @override
  bool get needsAccount => true;

  Future<(int, Map<String, dynamic>)> _call(String function, {Object? body}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.postUrl(_env.functionUrl(function));
      request.headers.contentType = ContentType.json;
      request.headers.set('apikey', _env.supabaseAnonKey);
      // Status is public (the anon key is enough); reserving needs a user.
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${await _accessToken() ?? _env.supabaseAnonKey}',
      );
      request.write(jsonEncode(body ?? const {}));
      final response = await request.close().timeout(const Duration(seconds: 15));
      final text = await utf8.decodeStream(response);
      final decoded = text.isEmpty ? const <String, dynamic>{} : jsonDecode(text);
      return (response.statusCode, decoded is Map<String, dynamic> ? decoded : <String, dynamic>{});
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<FounderStatus?> status() async {
    try {
      final (code, json) = await _call('founder-status');
      if (code != 200) {
        debugPrint('founder-status: HTTP $code ${json['error']}');
        return null;
      }
      return FounderStatus.fromJson(json);
    } catch (e) {
      debugPrint('founder-status: $e');
      return null;
    }
  }

  @override
  Future<String> reserve() async {
    final (code, json) = await _call('founder-reserve');
    if (code == 200 && json['reservation_id'] is String) return json['reservation_id'] as String;
    if (code == 409 && json['error'] == 'sold_out') throw const FounderSoldOut();
    if (code == 401) throw const FounderReserveFailed('Sign in to become a Founding Member.');
    throw FounderReserveFailed('Couldn\'t reserve a place: ${json['error'] ?? 'HTTP $code'}');
  }
}

/// Backend-less: for tests and the debug build before the project has the
/// functions. [remaining] null means "can't say".
class FakeFounderService implements FounderService {
  int? remaining;
  int cap;
  bool active;
  int reservations = 0;
  @override
  final bool needsAccount;

  FakeFounderService({
    this.remaining = 137,
    this.cap = 500,
    this.active = true,
    this.needsAccount = false,
  });

  @override
  Future<FounderStatus?> status() async {
    final r = remaining;
    if (r == null) return null;
    return FounderStatus(
      active: active && r > 0,
      cap: cap,
      sold: cap - r,
      remaining: r,
      version: 1,
      lastUpdatedAt: DateTime.now(),
      fetchedAt: DateTime.now(),
    );
  }

  @override
  Future<String> reserve() async {
    final r = remaining;
    if (r == null) throw const FounderReserveFailed('Availability unknown.');
    if (!active || r <= 0) throw const FounderSoldOut();
    reservations++;
    return 'fake-reservation-$reservations';
  }
}
