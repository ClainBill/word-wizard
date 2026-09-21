import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../app/environment.dart';

/// Who is signed in, as the rest of the app needs to know it.
class AuthUser {
  final String id;
  final String? email;

  /// How they signed in: 'email', 'google', 'apple' — as Supabase records it.
  final String? provider;

  const AuthUser({required this.id, this.email, this.provider});
}

class AuthException implements Exception {
  final String message;
  const AuthException(this.message);
  @override
  String toString() => message;
}

/// The person backed out of a sign-in they started (closed Google's
/// account picker, dismissed Apple's sheet). Not an error to show.
class AuthCancelled implements Exception {
  const AuthCancelled();
}

/// The third-party accounts one can sign in with.
enum SocialProvider {
  google('Google'),
  apple('Apple');

  final String label;
  const SocialProvider(this.label);
}

/// Accounts. An account is optional — everything the user studies stays on
/// the device — and exists for premium, the AI features and, later, friends.
///
/// Sign-in is by email — the user types their address and gets a mail with
/// a link that opens the app (`lexery://auth`, handled by supabase_flutter)
/// and, once the project has custom SMTP and the template in
/// `supabase/templates/`, a six-digit code to type in instead — or with a
/// Google or Apple account. No password anywhere. An account is created
/// on first sign-in by any route; the same email through two routes is
/// one account (Supabase links identities by verified email).
abstract class AuthService {
  AuthUser? get currentUser;
  bool get isSignedIn => currentUser != null;

  /// Fires with the user on every change, starting with the current one.
  Stream<AuthUser?> get changes;

  /// Which social sign-ins this build can offer, in the order to show them.
  List<SocialProvider> get socialProviders;

  /// Signs in with [provider]. Returns the user when the sign-in completed
  /// in the app, or null when it continues in the browser — [changes]
  /// fires once that lands. Throws [AuthCancelled] if they backed out.
  Future<AuthUser?> signInWith(SocialProvider provider);

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

  static AuthUser? _toUser(sb.User? user) => user == null
      ? null
      : AuthUser(id: user.id, email: user.email, provider: user.appMetadata['provider'] as String?);

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
      throw AuthException(_friendly(e, verifying: true));
    }
  }

  /// Apple's button is a store requirement wherever another social sign-in
  /// is offered, and works on Android through the browser; Google works
  /// everywhere. Apple first on Apple devices, Google first elsewhere.
  @override
  List<SocialProvider> get socialProviders => Platform.isIOS || Platform.isMacOS
      ? const [SocialProvider.apple, SocialProvider.google]
      : const [SocialProvider.google, SocialProvider.apple];

  @override
  Future<AuthUser?> signInWith(SocialProvider provider) async {
    try {
      switch (provider) {
        case SocialProvider.google:
          final nativeId = Platform.isIOS ? _env.googleIosClientId : _env.googleWebClientId;
          if (nativeId.isEmpty) return _signInViaBrowser(sb.OAuthProvider.google);
          return _signInWithGoogleNatively();
        case SocialProvider.apple:
          if (!(Platform.isIOS || Platform.isMacOS)) {
            return _signInViaBrowser(sb.OAuthProvider.apple);
          }
          return _signInWithAppleNatively();
      }
    } on AuthCancelled {
      rethrow;
    } on AuthException {
      rethrow;
    } on sb.AuthException catch (e) {
      throw AuthException(_friendly(e));
    } catch (e) {
      debugPrint('sign in with ${provider.name}: $e');
      throw AuthException('Couldn\'t sign in with ${provider.label} just now. Try again.');
    }
  }

  bool _googleInitialised = false;

  /// The account picker, then Supabase verifies Google's id token — no
  /// browser, no redirect.
  Future<AuthUser> _signInWithGoogleNatively() async {
    final google = GoogleSignIn.instance;
    if (!_googleInitialised) {
      await google.initialize(
        clientId: Platform.isIOS ? _env.googleIosClientId : null,
        serverClientId: _env.googleWebClientId.isEmpty ? null : _env.googleWebClientId,
      );
      _googleInitialised = true;
    }
    final GoogleSignInAccount account;
    try {
      account = await google.authenticate(scopeHint: const ['email']);
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) throw const AuthCancelled();
      rethrow;
    }
    final idToken = account.authentication.idToken;
    if (idToken == null) throw const AuthException('Google didn\'t return a token. Try again.');
    final authz = await account.authorizationClient.authorizationForScopes(const ['email']);
    final response = await _client.auth.signInWithIdToken(
      provider: sb.OAuthProvider.google,
      idToken: idToken,
      accessToken: authz?.accessToken,
    );
    return _toUser(response.user) ?? (throw const AuthException('Sign-in didn\'t complete.'));
  }

  /// Apple's own sheet; the nonce ties the token Apple returns to this
  /// attempt. Apple only gives the name once, on the first sign-in — the
  /// app doesn't use it, so nothing is lost by not storing it.
  Future<AuthUser> _signInWithAppleNatively() async {
    final rawNonce = _randomNonce();
    final AuthorizationCredentialAppleID credential;
    try {
      credential = await SignInWithApple.getAppleIDCredential(
        scopes: const [AppleIDAuthorizationScopes.email],
        nonce: sha256.convert(utf8.encode(rawNonce)).toString(),
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) throw const AuthCancelled();
      rethrow;
    }
    final idToken = credential.identityToken;
    if (idToken == null) throw const AuthException('Apple didn\'t return a token. Try again.');
    final response = await _client.auth.signInWithIdToken(
      provider: sb.OAuthProvider.apple,
      idToken: idToken,
      nonce: rawNonce,
    );
    return _toUser(response.user) ?? (throw const AuthException('Sign-in didn\'t complete.'));
  }

  /// Supabase's hosted OAuth flow in the system browser; the provider's
  /// redirect lands back on [redirectUrl] and supabase_flutter completes
  /// the session, which surfaces on [changes].
  Future<AuthUser?> _signInViaBrowser(sb.OAuthProvider provider) async {
    final launched = await _client.auth.signInWithOAuth(
      provider,
      redirectTo: redirectUrl,
      authScreenLaunchMode: sb.LaunchMode.externalApplication,
    );
    if (!launched) throw const AuthException('Couldn\'t open the browser to sign in.');
    return null;
  }

  static String _randomNonce([int length = 32]) {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._';
    final random = Random.secure();
    return List.generate(length, (_) => chars[random.nextInt(chars.length)]).join();
  }

  @override
  Future<void> signOut() async {
    await _client.auth.signOut();
    if (_googleInitialised) {
      // Otherwise the next Google sign-in silently picks the same account.
      try {
        await GoogleSignIn.instance.signOut();
      } catch (_) {}
    }
  }

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
  /// [verifying] tells a failure at the code step from one at the send
  /// step, since "invalid" means different things in each.
  static String _friendly(sb.AuthException e, {bool verifying = false}) {
    final code = e.code ?? '';
    final m = e.message.toLowerCase();
    if (code.contains('rate_limit') || m.contains('rate limit') || e.statusCode == '429') {
      return 'Too many attempts — wait a few minutes and try again.';
    }
    if (code == 'email_address_invalid' || code == 'validation_failed' && m.contains('email')) {
      return 'That email address can\'t be used. Check it and try another.';
    }
    if (code == 'otp_expired' || m.contains('expired')) {
      return 'That code has expired. Send a new one.';
    }
    if (verifying && (code == 'otp_disabled' || m.contains('invalid') || m.contains('token'))) {
      return 'That code didn\'t match. Check it and try again.';
    }
    if (code == 'email_provider_disabled' || code == 'signup_disabled') {
      return 'Email sign-in isn\'t available right now.';
    }
    if (code.startsWith('provider_') || code == 'oauth_provider_not_supported') {
      return 'That way of signing in isn\'t set up yet.';
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
  List<SocialProvider> get socialProviders => const [];
  @override
  Future<AuthUser?> signInWith(SocialProvider provider) async =>
      throw const AuthException('Accounts aren\'t available in this build.');
  @override
  Future<void> signOut() async {}
  @override
  Future<void> deleteAccount() async {}
}
