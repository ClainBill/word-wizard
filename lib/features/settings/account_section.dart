import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../services/auth_service.dart';

/// Settings → Account: sign in by email code, sign out, delete. An account
/// is optional — the copy says what it's for and what it isn't.
class AccountSection extends ConsumerWidget {
  const AccountSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authServiceProvider);
    final user = ref.watch(authUserProvider).valueOrNull;
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text('Account', style: TextStyle(fontWeight: FontWeight.w600)),
        ),
        if (user == null)
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('Sign in'),
            subtitle: Text(
              auth is NoAuthService
                  ? 'Not available in this build.'
                  : 'For premium and the AI features. Everything you study stays on '
                        'this device either way.',
            ),
            trailing: const Icon(Icons.chevron_right),
            enabled: auth is! NoAuthService,
            onTap: () => showSignInSheet(context, ref),
          )
        else ...[
          ListTile(
            leading: Icon(Icons.person, color: scheme.primary),
            title: Text(user.email ?? 'Signed in'),
            subtitle: const Text('Signed in'),
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Sign out'),
            onTap: () async {
              await auth.signOut();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Signed out. Your words and progress are still here.'),
                  ),
                );
              }
            },
          ),
          ListTile(
            leading: Icon(Icons.delete_forever_outlined, color: scheme.error),
            title: Text('Delete account', style: TextStyle(color: scheme.error)),
            onTap: () => _confirmDelete(context, auth),
          ),
        ],
      ],
    );
  }

  Future<void> _confirmDelete(BuildContext context, AuthService auth) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete your account?'),
        content: const Text(
          'This removes your account and what the server holds for it — your '
          'subscription record and AI usage. Your words and progress on this '
          'device stay.\n\n'
          'It does not cancel an App Store or Google Play subscription: cancel '
          'that in your store\'s subscription settings, or it will keep renewing.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await auth.deleteAccount();
      messenger.showSnackBar(const SnackBar(content: Text('Your account has been deleted.')));
    } on AuthException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

Future<void> showSignInSheet(BuildContext context, WidgetRef ref) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SignInSheet(auth: ref.read(authServiceProvider)),
    ),
  );
}

/// Two steps: an address, then the six-digit code that was sent to it.
class SignInSheet extends StatefulWidget {
  final AuthService auth;

  const SignInSheet({super.key, required this.auth});

  @override
  State<SignInSheet> createState() => _SignInSheetState();
}

class _SignInSheetState extends State<SignInSheet> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  bool _codeSent = false;
  bool _busy = false;
  String? _error;
  StreamSubscription<AuthUser?>? _signedIn;

  @override
  void initState() {
    super.initState();
    // Tapping the link in the mail signs in behind this sheet; close it
    // when that happens rather than leave a code field waiting.
    _signedIn = widget.auth.changes.listen((user) {
      if (user != null && mounted) _finish(user);
    });
  }

  @override
  void dispose() {
    _signedIn?.cancel();
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  bool _done = false;

  /// Once: a typed code also fires the change stream, and the sheet must
  /// close exactly one route.
  void _finish(AuthUser user) {
    if (_done) return;
    _done = true;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(content: Text('Signed in as ${user.email ?? 'you'}.')));
  }

  static final _emailShape = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

  Future<void> _sendCode() async {
    final email = _email.text.trim();
    if (!_emailShape.hasMatch(email)) {
      setState(() => _error = 'That doesn\'t look like an email address.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.auth.sendEmailCode(email);
      if (mounted) setState(() => _codeSent = true);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    final code = _code.text.trim();
    if (code.length < 6) {
      setState(() => _error = 'Enter the six-digit code from the email.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final user = await widget.auth.verifyEmailCode(email: _email.text, code: code);
      if (mounted) _finish(user);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Sign in', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 6),
          Text(
            _codeSent
                ? 'Check ${_email.text.trim()}: tap the link in the mail to sign in here, '
                      'or type the code if it has one. Good for an hour.'
                : 'Enter your email and we\'ll send a sign-in link — no password to remember.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          if (!_codeSent)
            TextField(
              controller: _email,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _sendCode(),
              decoration: const InputDecoration(
                labelText: 'Email',
                prefixIcon: Icon(Icons.alternate_email),
                border: OutlineInputBorder(),
              ),
            )
          else
            TextField(
              controller: _code,
              autofocus: true,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              maxLength: 6,
              onSubmitted: (_) => _verify(),
              decoration: const InputDecoration(
                labelText: 'Code from the email (if it has one)',
                prefixIcon: Icon(Icons.pin_outlined),
                border: OutlineInputBorder(),
                counterText: '',
              ),
              style: const TextStyle(letterSpacing: 6, fontSize: 22, fontWeight: FontWeight.w600),
            ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: scheme.error)),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : (_codeSent ? _verify : _sendCode),
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(_codeSent ? 'Sign in' : 'Send code'),
          ),
          if (_codeSent)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _codeSent = false;
                      _code.clear();
                      _error = null;
                    }),
              child: const Text('Use a different email'),
            ),
        ],
      ),
    );
  }
}
