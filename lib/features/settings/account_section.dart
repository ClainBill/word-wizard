import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../services/auth_service.dart';
import '../account/sign_in_sheet.dart' show showSignInSheet;
import '../leaderboard/leaderboard_screen.dart' show showLeaderboardOptIn;

/// Settings → Account: sign in (Apple, Google or an email code), sign out,
/// delete. An account is optional — the copy says what it's for and what
/// it isn't.
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
            leading: CircleAvatar(
              backgroundColor: scheme.surfaceContainerHighest,
              child: Icon(Icons.person_outline, color: scheme.onSurfaceVariant),
            ),
            title: const Text('Sign in or create an account'),
            subtitle: Text(
              auth is NoAuthService
                  ? 'Not available in this build.'
                  : 'With Apple, Google or your email. For Premium, the AI editor, groups '
                        'and the leaderboard — your words stay on this device either way.',
            ),
            trailing: const Icon(Icons.chevron_right),
            enabled: auth is! NoAuthService,
            onTap: () => showSignInSheet(context, ref),
          )
        else ...[
          ListTile(
            leading: CircleAvatar(
              backgroundColor: scheme.primaryContainer,
              foregroundColor: scheme.onPrimaryContainer,
              child: Text(
                (user.email ?? '?').substring(0, 1).toUpperCase(),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            title: Text(user.email ?? 'Signed in'),
            subtitle: Text(switch (user.provider) {
              'google' => 'Signed in with Google',
              'apple' => 'Signed in with Apple',
              _ => 'Signed in with your email',
            }),
          ),
          ListTile(
            leading: const Icon(Icons.emoji_events_outlined),
            title: const Text('Leaderboard name'),
            subtitle: const Text('Whether you appear on the puzzle leaderboard, and as what.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showLeaderboardOptIn(context, ref),
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
