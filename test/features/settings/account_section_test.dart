import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/app/providers.dart';
import 'package:word_wizard/features/account/sign_in_sheet.dart';
import 'package:word_wizard/features/settings/account_section.dart';
import 'package:word_wizard/services/auth_service.dart';

/// An auth service with a scripted mailbox: the code it "sent" is the one
/// that verifies.
class _FakeAuth implements AuthService {
  final _changes = StreamController<AuthUser?>.broadcast();
  AuthUser? _user;
  String? sentTo;
  String? failNextSend;
  bool deleted = false;

  /// What the next social sign-in does: a user (native success), null
  /// (handed to the browser), or an exception to throw.
  Object? socialResult;
  SocialProvider? socialAsked;

  @override
  AuthUser? get currentUser => _user;
  @override
  bool get isSignedIn => _user != null;
  @override
  Stream<AuthUser?> get changes async* {
    yield _user;
    yield* _changes.stream;
  }

  @override
  Future<String?> accessToken() async => _user == null ? null : 'jwt';
  @override
  Future<void> sendEmailCode(String email) async {
    if (failNextSend != null) throw AuthException(failNextSend!);
    sentTo = email;
  }

  @override
  Future<AuthUser> verifyEmailCode({required String email, required String code}) async {
    if (code != '123456') throw const AuthException('That code didn\'t match.');
    _user = AuthUser(id: 'u1', email: email.trim());
    _changes.add(_user);
    return _user!;
  }

  @override
  List<SocialProvider> get socialProviders => const [SocialProvider.google, SocialProvider.apple];

  @override
  Future<AuthUser?> signInWith(SocialProvider provider) async {
    socialAsked = provider;
    final r = socialResult;
    if (r is Exception) throw r;
    if (r is AuthUser) {
      _user = r;
      _changes.add(r);
    }
    return r as AuthUser?;
  }

  @override
  Future<void> signOut() async {
    _user = null;
    _changes.add(null);
  }

  @override
  Future<void> deleteAccount() async {
    deleted = true;
    await signOut();
  }
}

void main() {
  late _FakeAuth auth;

  setUp(() => auth = _FakeAuth());

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    ProviderScope(
      overrides: [authServiceProvider.overrideWithValue(auth)],
      child: MaterialApp(
        home: Scaffold(body: ListView(children: const [AccountSection()])),
      ),
    ),
  );

  testWidgets('email, then the code, signs in; sign out and delete work', (tester) async {
    await pump(tester);
    await tester.pump();
    expect(find.text('Sign in or create an account'), findsOneWidget);

    await tester.tap(find.text('Sign in or create an account'));
    await tester.pumpAndSettle();
    expect(find.text('Welcome to Word Wizard'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Continue with Apple'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'not an email');
    await tester.tap(find.text('Continue with email'));
    await tester.pump();
    expect(find.textContaining('doesn\'t look like an email'), findsOneWidget);
    expect(auth.sentTo, isNull);

    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'me@example.com');
    await tester.tap(find.text('Continue with email'));
    await tester.pumpAndSettle();
    expect(auth.sentTo, 'me@example.com');
    expect(find.text('Check your email'), findsOneWidget);
    expect(find.textContaining('me@example.com'), findsOneWidget);

    // Six digits go straight through, no tap needed.
    await tester.enterText(find.byType(TextField), '000000');
    await tester.pumpAndSettle();
    expect(find.text('That code didn\'t match.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '123456');
    await tester.pumpAndSettle();
    expect(
      find.text('Signed in as me@example.com. Welcome.'),
      findsOneWidget,
      reason: 'the snackbar',
    );
    expect(find.byType(SignInSheet), findsNothing, reason: 'closed exactly once');
    expect(find.text('me@example.com'), findsOneWidget);
    expect(find.text('Signed in with your email'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);

    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('does not cancel an App Store or Google Play subscription'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(auth.deleted, isTrue);
    expect(find.text('Sign in or create an account'), findsOneWidget, reason: 'back to signed out');
  });

  testWidgets(
    'Google: native success signs in; a cancel says nothing; the browser hand-off waits',
    (tester) async {
      await pump(tester);
      await tester.pump();
      await tester.tap(find.text('Sign in or create an account'));
      await tester.pumpAndSettle();

      auth.socialResult = const AuthCancelled();
      await tester.tap(find.text('Continue with Google'));
      await tester.pumpAndSettle();
      expect(auth.socialAsked, SocialProvider.google);
      expect(find.byType(SignInSheet), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsNothing);

      auth.socialResult = null;
      await tester.tap(find.text('Continue with Apple'));
      // A spinner waits for the browser, so this can't settle.
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Finish in your browser'), findsOneWidget);
      await tester.tap(find.text('Try another way'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Welcome to Word Wizard'), findsOneWidget);

      auth.socialResult = const AuthUser(id: 'g1', email: 'me@gmail.com', provider: 'google');
      await tester.tap(find.text('Continue with Google'));
      await tester.pumpAndSettle();
      expect(find.byType(SignInSheet), findsNothing);
      expect(find.text('Signed in with Google as me@gmail.com. Welcome.'), findsOneWidget);
      expect(find.text('Signed in with Google'), findsOneWidget);
    },
  );

  testWidgets('a link sign-in closes the sheet on its own', (tester) async {
    await pump(tester);
    await tester.pump();
    await tester.tap(find.text('Sign in or create an account'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'me@example.com');
    await tester.tap(find.text('Continue with email'));
    await tester.pumpAndSettle();
    // The deep link completed the session behind the sheet.
    auth._user = const AuthUser(id: 'u1', email: 'me@example.com');
    auth._changes.add(auth._user);
    await tester.pumpAndSettle();
    expect(find.byType(SignInSheet), findsNothing);
    expect(find.text('me@example.com'), findsOneWidget);
  });
}
