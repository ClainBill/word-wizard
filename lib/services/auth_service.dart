import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../app/environment.dart';

/// Who is signed in, as the rest of the app needs to know it.
class AuthUser {
  final String id;
  final String? email;

  const AuthUser({required this.id, this.email});
}

class AuthException implements Exception {
  final String message;
  const AuthException(this.message);
  @override
  String toString() => message;
}

/// Accounts. An account is optional — everything the user studies stays on
/// the device — and exists for premium, the AI features and, later, friends.
///
/// Sign-in is by email: the user types their address and gets a mail with a
/// link that opens the app (`lexery://auth`, handled by supabase_flutter)
/// and — once the project has custom SMTP and the template in
/// `supabase/templates/` — a six-digit code to type in instead. No password
/// to forget, and the same on both platforms. Apple and Google sign-in slot
/// in beside it once the developer accounts exist (`signInWithIdToken`).
abstract class AuthService {
  AuthUser? get currentUser;
  bool get isSignedIn => currentUser != null;

  /// Fires with the user on every change, starting with the current one.
  Stream<AuthUser?> get changes;

  /// The bearer token the backend wants, refreshed if it's about to expire.
  /// Null when signed out.
  Future<String?> accessToken();

  /// Sends the sign-in mail: a link back into the app, plus a code when
  /// the project's template carries one.
  Future<void> sendEmailCode(String email);
  Future<AuthUser> verifyEmailCode({required String email, required String code});
  Future<void> signOut();

  /// Deletes the account on the server, then signs out locally. The store
  /// subscription, if any, is *not* cancelled by this — the UI says so.
  Future<void> deleteAccount();
}

/// The real thing, over `supabase_flutter`. [Supabase.initialize] has run
/// in `main` before this is constructed.
class SupabaseAuthService implements AuthService {
  final sb.SupabaseClient _client;
  final AppEnvironment _env;

  SupabaseAuthService(this._client, this._env);

  static AuthUser? _toUser(sb.User? user) =>
      user == null ? null : AuthUser(id: user.id, email: user.email);

  @override
  AuthUser? get currentUser => _toUser(_client.auth.currentUser);

  @override
  bool get isSignedIn => currentUser != null;

  @override
  Stream<AuthUser?> get changes async* {
    yield currentUser;
    yield* _client.auth.onAuthStateChange.map((s) => _toUser(s.session?.user));
  }

  @override
  Future<String?> accessToken() async {
    final session = _client.auth.currentSession;
    if (session == null) return null;
    // supabase_flutter refreshes in the background; this covers the case
    // where the app was asleep past the expiry.
    if (session.isExpired) {
      try {
        final refreshed = await _client.auth.refreshSession();
        return refreshed.session?.accessToken;
      } catch (_) {
        return null;
      }
    }
    return session.accessToken;
  }

  /// Where the mail's link lands. Registered on both platforms
  /// (AndroidManifest.xml, Info.plist) and in the project's redirect list.
  static const String redirectUrl = 'lexery://auth';

  @override
  Future<void> sendEmailCode(String email) async {
    try {
      await _client.auth.signInWithOtp(
        email: email.trim(),
        shouldCreateUser: true,
        emailRedirectTo: redirectUrl,
      );
    } on sb.AuthException catch (e) {
      throw AuthException(_friendly(e));
    }
  }

  @override
  Future<AuthUser> verifyEmailCode({required String email, required String code}) async {
    try {
      final response = await _client.auth.verifyOTP(
        email: email.trim(),
        token: code.trim(),
        type: sb.OtpType.email,
      );
      final user = _toUser(response.user);
      if (user == null) throw const AuthException('That code didn\'t work. Try again.');
      return user;
    } on sb.AuthException catch (e) {
      throw AuthException(_friendly(e));
    }
  }

  @override
  Future<void> signOut() => _client.auth.signOut();

  @override
  Future<void> deleteAccount() async {
    final token = await accessToken();
    if (token == null) throw const AuthException('Not signed in.');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.postUrl(_env.functionUrl('delete-account'));
      request.headers.contentType = ContentType.json;
      request.headers.set('apikey', _env.supabaseAnonKey);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.write(jsonEncode({'confirm': true}));
      final response = await request.close().timeout(const Duration(seconds: 30));
      final body = await utf8.decodeStream(response);
      if (response.statusCode != 200) {
        debugPrint('delete-account: HTTP ${response.statusCode} $body');
        throw const AuthException('Couldn\'t delete the account just now. Try again later.');
      }
    } on AuthException {
      rethrow;
    } catch (e) {
      throw AuthException('Couldn\'t reach the server: $e');
    } finally {
      client.close();
    }
    // The server-side user is gone; the local session would only 401.
    await _client.auth.signOut(scope: sb.SignOutScope.local);
  }

  /// Supabase's messages are for developers; these are for the person.
  static String _friendly(sb.AuthException e) {
    final m = e.message.toLowerCase();
    if (m.contains('rate limit') || e.statusCode == '429') {
      return 'Too many attempts — wait a few minutes and try again.';
    }
    if (m.contains('expired')) return 'That code has expired. Send a new one.';
    if (m.contains('invalid') || m.contains('token')) {
      return 'That code didn\'t match. Check it and try again.';
    }
    if (m.contains('email')) return 'That doesn\'t look like a valid email address.';
    return e.message;
  }
}

/// Signed-out, always: for tests and for a build with no backend
/// configured (`AppEnvironment.isConfigured` false).
class NoAuthService implements AuthService {
  const NoAuthService();

  @override
  AuthUser? get currentUser => null;
  @override
  bool get isSignedIn => false;
  @override
  Stream<AuthUser?> get changes => Stream.value(null);
  @override
  Future<String?> accessToken() async => null;
  @override
  Future<void> sendEmailCode(String email) async =>
      throw const AuthException('Accounts aren\'t available in this build.');
  @override
  Future<AuthUser> verifyEmailCode({required String email, required String code}) async =>
      throw const AuthException('Accounts aren\'t available in this build.');
  @override
  Future<void> signOut() async {}
  @override
  Future<void> deleteAccount() async {}
}
