import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../domain/crossword/crossword_models.dart';
import '../../domain/groups/group_models.dart';
import '../../services/groups_api.dart';
import '../premium/paywall_screen.dart';
import '../account/sign_in_sheet.dart' show showSignInSheet;

/// Games → Group puzzles: the groups this person is in, and the two ways
/// in — start one (Premium) or join one with a code (anyone: an invite
/// is meant to be the free tier's first taste of the feature).
class GroupsScreen extends ConsumerWidget {
  const GroupsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(groupsApiProvider);
    final user = ref.watch(authUserProvider).valueOrNull;
    final premium = ref.watch(isPremiumProvider);
    final scheme = Theme.of(context).colorScheme;
    final full = (ref.watch(myGroupsProvider).valueOrNull?.length ?? 0) >= maxGroupsPerPerson;

    return Scaffold(
      appBar: AppBar(title: const Text('Group puzzles')),
      body: !api.available
          ? const _Message('Group puzzles aren\'t available in this build.')
          : user == null
          ? _SignedOut(onSignIn: () => showSignInSheet(context, ref))
          : RefreshIndicator(
              onRefresh: () => ref.refresh(myGroupsProvider.future),
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Text(
                    'Pool the words your group is learning; every day the pool becomes a '
                    'puzzle you all solve — a crossword or a Word Hunt, whichever the group '
                    'was set up for — and a leaderboard says who knew them best.',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 16),
                  ref
                      .watch(myGroupsProvider)
                      .when(
                        data: (groups) => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (groups.isEmpty)
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 24),
                                child: Text(
                                  'No groups yet.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: scheme.onSurfaceVariant),
                                ),
                              ),
                            for (final g in groups) ...[
                              Card(
                                margin: EdgeInsets.zero,
                                child: ListTile(
                                  leading: CircleAvatar(
                                    backgroundColor: scheme.secondaryContainer,
                                    child: Icon(
                                      Icons.group_outlined,
                                      color: scheme.onSecondaryContainer,
                                    ),
                                  ),
                                  title: Text(g.name),
                                  subtitle: Text(
                                    '${g.playsLabel} · '
                                    '${g.memberCount} ${g.memberCount == 1 ? 'member' : 'members'}'
                                    '${g.isOwnedBy(user.id) ? ' · yours' : ''}',
                                  ),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: () => context.push('/games/groups/${g.id}'),
                                ),
                              ),
                              const SizedBox(height: 10),
                            ],
                          ],
                        ),
                        loading: () => const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                        error: (e, _) => _Message('$e'),
                      ),
                  const SizedBox(height: 16),
                  if (full)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        'You\'re in $maxGroupsPerPerson groups — the most anyone can be in. '
                        'Leave one to start or join another.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  FilledButton.icon(
                    onPressed: full
                        ? null
                        : () => premium
                              ? _create(context, ref, user.id)
                              : showPaywall(context, source: 'groups_create'),
                    icon: Icon(premium ? Icons.add : Icons.workspace_premium_outlined),
                    label: Text(premium ? 'Start a group' : 'Start a group (Premium)'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: full ? null : () => _join(context, ref),
                    icon: const Icon(Icons.login),
                    label: const Text('Join with a code'),
                  ),
                ],
              ),
            ),
    );
  }

  Future<void> _create(BuildContext context, WidgetRef ref, String userId) async {
    final result = await showModalBottomSheet<_SheetResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => const _NameSheet(
        title: 'Start a group',
        firstLabel: 'Group name',
        action: 'Create',
        chooseMode: true,
      ),
    );
    if (result == null || !context.mounted) return;
    await _run(context, ref, () async {
      final id = await ref
          .read(groupsApiProvider)
          .create(
            name: result.first,
            displayName: result.name,
            kind: result.kind,
            size: result.size,
          );
      ref.invalidate(myGroupsProvider);
      if (context.mounted) context.push('/games/groups/$id');
    });
  }

  Future<void> _join(BuildContext context, WidgetRef ref) async {
    final result = await showModalBottomSheet<_SheetResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => const _NameSheet(
        title: 'Join a group',
        firstLabel: 'Invite code',
        action: 'Join',
        code: true,
      ),
    );
    if (result == null || !context.mounted) return;
    await _run(context, ref, () async {
      final id = await ref
          .read(groupsApiProvider)
          .join(code: normalizeInviteCode(result.first), displayName: result.name);
      ref.invalidate(myGroupsProvider);
      if (context.mounted) context.push('/games/groups/$id');
    });
  }

  static Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function() body,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await body();
    } on GroupsException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

class _SignedOut extends StatelessWidget {
  final VoidCallback onSignIn;

  const _SignedOut({required this.onSignIn});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(
            Icons.group_outlined,
            size: 48,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          const Text(
            'Groups live on your account, so the others can find you and your words can '
            'join the pool. Sign in to start or join one.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: onSignIn, child: const Text('Sign in')),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final String text;
  const _Message(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Center(child: Text(text, textAlign: TextAlign.center)),
  );
}

typedef _SheetResult = ({
  String first,
  String name,
  GroupPuzzleKind kind,
  CrosswordDifficulty size,
});

/// Two fields: the group's name or the code, and what to call you in it.
/// Starting a group also chooses what it plays, for good.
class _NameSheet extends StatefulWidget {
  final String title;
  final String firstLabel;
  final String action;
  final bool code;
  final bool chooseMode;

  const _NameSheet({
    required this.title,
    required this.firstLabel,
    required this.action,
    this.code = false,
    this.chooseMode = false,
  });

  @override
  State<_NameSheet> createState() => _NameSheetState();
}

class _NameSheetState extends State<_NameSheet> {
  final _first = TextEditingController();
  final _name = TextEditingController();
  GroupPuzzleKind _kind = GroupPuzzleKind.crossword;
  CrosswordDifficulty _size = CrosswordDifficulty.midi;
  String? _error;

  @override
  void dispose() {
    _first.dispose();
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final first = _first.text.trim();
    final name = _name.text.trim();
    if (first.isEmpty || name.isEmpty) {
      setState(() => _error = 'Both fields are needed.');
      return;
    }
    if (widget.code && normalizeInviteCode(first).length != 8) {
      setState(() => _error = 'A code is eight letters and digits.');
      return;
    }
    Navigator.of(context).pop((first: first, name: name, kind: _kind, size: _size));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, 24 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),
          TextField(
            controller: _first,
            autofocus: true,
            textCapitalization: widget.code
                ? TextCapitalization.characters
                : TextCapitalization.words,
            autocorrect: !widget.code,
            maxLength: widget.code ? 10 : 40,
            decoration: InputDecoration(
              labelText: widget.firstLabel,
              border: const OutlineInputBorder(),
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            maxLength: 30,
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(
              labelText: 'Your name in the group',
              helperText: 'Only members of the group see it.',
              border: OutlineInputBorder(),
              counterText: '',
            ),
          ),
          if (widget.chooseMode) ...[
            const SizedBox(height: 16),
            Text('Every day, play', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            SegmentedButton<GroupPuzzleKind>(
              segments: [
                for (final k in GroupPuzzleKind.values)
                  ButtonSegment(
                    value: k,
                    label: Text(k.label),
                    icon: Icon(k == GroupPuzzleKind.hunt ? Icons.apps : Icons.grid_on),
                  ),
              ],
              selected: {_kind},
              onSelectionChanged: (s) => setState(() => _kind = s.first),
            ),
            if (_kind == GroupPuzzleKind.crossword) ...[
              const SizedBox(height: 12),
              SegmentedButton<CrosswordDifficulty>(
                showSelectedIcon: false,
                segments: [
                  for (final d in CrosswordDifficulty.values)
                    ButtonSegment(value: d, label: Text('${d.label} ${d.size}×${d.size}')),
                ],
                selected: {_size},
                onSelectionChanged: (s) => setState(() => _size = s.first),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              'Chosen once — the group plays this every day.',
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 16),
          FilledButton(onPressed: _submit, child: Text(widget.action)),
        ],
      ),
    );
  }
}
