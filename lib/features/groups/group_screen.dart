import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/providers.dart';
import '../../domain/groups/group_models.dart';
import '../../services/group_puzzle_service.dart';
import '../../services/groups_api.dart';
import '../premium/paywall_screen.dart';

/// One group: today's puzzle and who's done how well, the words you're
/// contributing (with the consent switch), the members, the invite code,
/// and the way out.
class GroupScreen extends ConsumerStatefulWidget {
  final String groupId;

  const GroupScreen({super.key, required this.groupId});

  @override
  ConsumerState<GroupScreen> createState() => _GroupScreenState();
}

class _GroupScreenState extends ConsumerState<GroupScreen> {
  bool _opening = false;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    // Coming back from a solve: tell the leaderboard, refresh the pool
    // if we're sharing. Quiet on failure.
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncInBackground());
  }

  Future<void> _syncInBackground() async {
    final user = ref.read(authUserProvider).valueOrNull;
    if (user == null) return;
    final service = ref.read(groupPuzzleServiceProvider);
    await service.syncScores(widget.groupId, userId: user.id);
    final me = (await ref.read(
      groupMembersProvider(widget.groupId).future,
    )).where((m) => m.userId == user.id).firstOrNull;
    if (me?.shareWords == true) {
      try {
        await service.syncMyWords(widget.groupId, userId: user.id);
        ref.invalidate(groupPoolProvider(widget.groupId));
      } catch (_) {}
    }
    _refreshScores();
  }

  void _refreshScores() {
    final puzzle = ref.read(groupTodayPuzzleProvider(widget.groupId)).valueOrNull;
    if (puzzle != null) ref.invalidate(groupScoresProvider(puzzle.id));
    ref.invalidate(groupTodayPuzzleProvider(widget.groupId));
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authUserProvider).valueOrNull;
    final groupAsync = ref.watch(groupProvider(widget.groupId));
    final members = ref.watch(groupMembersProvider(widget.groupId)).valueOrNull ?? const [];
    final pool = ref.watch(groupPoolProvider(widget.groupId)).valueOrNull;
    final puzzle = ref.watch(groupTodayPuzzleProvider(widget.groupId)).valueOrNull;
    final premium = ref.watch(isPremiumProvider);
    final scheme = Theme.of(context).colorScheme;
    final group = groupAsync.valueOrNull;
    final me = user == null ? null : members.where((m) => m.userId == user.id).firstOrNull;
    final owner = user != null && group?.isOwnedBy(user.id) == true;

    return Scaffold(
      appBar: AppBar(
        title: Text(group?.name ?? 'Group'),
        actions: [
          if (group != null)
            PopupMenuButton<String>(
              onSelected: (v) => v == 'leave' ? _leave(group, owner) : _rename(me),
              itemBuilder: (_) => [
                if (me != null) const PopupMenuItem(value: 'rename', child: Text('Change my name')),
                PopupMenuItem(value: 'leave', child: Text(owner ? 'Delete group' : 'Leave group')),
              ],
            ),
        ],
      ),
      body: groupAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(padding: const EdgeInsets.all(24), child: Text('$e')),
        ),
        data: (group) {
          if (group == null) return const Center(child: Text('This group is gone.'));
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(groupProvider(widget.groupId));
              ref.invalidate(groupMembersProvider(widget.groupId));
              ref.invalidate(groupPoolProvider(widget.groupId));
              _refreshScores();
            },
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                _TodayCard(
                  puzzle: puzzle,
                  poolSize: pool?.length,
                  opening: _opening,
                  premium: premium,
                  onPlay: () => premium ? _play() : showPaywall(context, source: 'group_play'),
                ),
                const SizedBox(height: 16),
                if (puzzle != null) ...[
                  Text('Today\'s leaderboard', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  _Leaderboard(puzzleId: puzzle.id, members: members, me: user?.id),
                  const SizedBox(height: 16),
                ],
                Text('Your words', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Share my words'),
                  subtitle: Text(
                    me?.shareWords == true
                        ? (_syncing
                              ? 'Updating…'
                              : 'The headwords you\'re studying are in the pool. '
                                    '${pool == null ? '' : '${pool.where((w) => w.userId == user?.id).length} of yours right now.'}')
                        : 'Off. Only headwords are ever shared — never notes or lookups.',
                  ),
                  value: me?.shareWords ?? false,
                  onChanged: me == null ? null : (on) => _setShare(me, on),
                ),
                const SizedBox(height: 16),
                Text('Members · ${members.length}', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                for (final m in members)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor: scheme.surfaceContainerHighest,
                      child: Text(m.displayName.isEmpty ? '?' : m.displayName[0].toUpperCase()),
                    ),
                    title: Text(m.displayName + (m.userId == user?.id ? ' (you)' : '')),
                    subtitle: Text(
                      [
                        if (m.role == GroupRole.owner) 'owner',
                        if (m.shareWords)
                          '${pool?.where((w) => w.userId == m.userId).length ?? '…'} words shared'
                        else
                          'not sharing words',
                      ].join(' · '),
                    ),
                    trailing: owner && m.role == GroupRole.member
                        ? IconButton(
                            icon: const Icon(Icons.person_remove_outlined),
                            tooltip: 'Remove from group',
                            onPressed: () => _remove(m),
                          )
                        : null,
                  ),
                const SizedBox(height: 16),
                Text('Invite', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  'Anyone with the code can join — up to 12 people. Share it only with people '
                  'you\'re happy to see your words.',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    SelectableText(
                      group.inviteCode,
                      style: const TextStyle(
                        fontSize: 22,
                        letterSpacing: 3,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.copy),
                      tooltip: 'Copy code',
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: group.inviteCode));
                        if (context.mounted) {
                          ScaffoldMessenger.of(
                            context,
                          ).showSnackBar(const SnackBar(content: Text('Code copied.')));
                        }
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.share_outlined),
                      tooltip: 'Share invite',
                      onPressed: () => SharePlus.instance.share(
                        ShareParams(
                          text:
                              'Join my Word Wizard group "${group.name}": open Games → Group puzzles → '
                              'Join with a code, and enter ${group.inviteCode}.',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 32),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _play() async {
    setState(() => _opening = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final localId = await ref.read(groupPuzzleServiceProvider).openToday(widget.groupId);
      if (!mounted) return;
      await context.push(
        '/games/crossword/${GroupPuzzleService.difficulty.storageKey}?puzzle=$localId',
      );
      if (mounted) _syncInBackground();
    } on GroupsException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _setShare(GroupMember me, bool on) async {
    if (on) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Share your words with this group?'),
          content: const Text(shareWordsConsentText),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Share'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _syncing = true);
    try {
      final api = ref.read(groupsApiProvider);
      await api.setShareWords(widget.groupId, userId: me.userId, share: on);
      if (on) {
        final n = await ref
            .read(groupPuzzleServiceProvider)
            .syncMyWords(widget.groupId, userId: me.userId);
        messenger.showSnackBar(SnackBar(content: Text('$n ${n == 1 ? 'word' : 'words'} shared.')));
      }
      ref.invalidate(groupMembersProvider(widget.groupId));
      ref.invalidate(groupPoolProvider(widget.groupId));
    } on GroupsException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _rename(GroupMember? me) async {
    if (me == null) return;
    final controller = TextEditingController(text: me.displayName);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Your name in this group'),
        content: TextField(controller: controller, autofocus: true, maxLength: 30),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || !mounted) return;
    await ref.read(groupsApiProvider).setDisplayName(widget.groupId, userId: me.userId, name: name);
    ref.invalidate(groupMembersProvider(widget.groupId));
  }

  Future<void> _remove(GroupMember m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${m.displayName}?'),
        content: const Text('Their shared words leave the pool. They can rejoin with the code.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await ref.read(groupsApiProvider).removeMember(widget.groupId, userId: m.userId);
    ref.invalidate(groupMembersProvider(widget.groupId));
    ref.invalidate(groupPoolProvider(widget.groupId));
  }

  Future<void> _leave(Group group, bool owner) async {
    final user = ref.read(authUserProvider).valueOrNull;
    if (user == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(owner ? 'Delete "${group.name}"?' : 'Leave "${group.name}"?'),
        content: Text(
          owner
              ? 'The group, its puzzles and everyone\'s shared words are deleted for all members. '
                    'Your own words and progress on this device stay.'
              : 'Your shared words are removed from the pool. Your progress on this device stays.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(owner ? 'Delete' : 'Leave'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final api = ref.read(groupsApiProvider);
      if (owner) {
        await api.deleteGroup(group.id);
      } else {
        await api.leave(group.id, userId: user.id);
      }
      ref.invalidate(myGroupsProvider);
      if (mounted) context.pop();
    } on GroupsException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

class _TodayCard extends StatelessWidget {
  final GroupPuzzle? puzzle;
  final int? poolSize;
  final bool opening;
  final bool premium;
  final VoidCallback onPlay;

  const _TodayCard({
    required this.puzzle,
    required this.poolSize,
    required this.opening,
    required this.premium,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ready = puzzle != null;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.grid_on, color: scheme.primary),
                const SizedBox(width: 10),
                Text('Today\'s crossword', style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              ready
                  ? 'Built on ${puzzle!.anchors.length} of the group\'s words. Everyone gets the same grid.'
                  : poolSize == 0
                  ? 'The pool is empty — switch on "Share my words" below to start it.'
                  : 'Nobody has opened today\'s puzzle yet. Be the first: it\'s built from the '
                        '${poolSize ?? ''} words in the pool.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: opening ? null : onPlay,
              icon: opening
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(premium ? Icons.play_arrow : Icons.workspace_premium_outlined),
              label: Text(
                !premium
                    ? 'Play (Premium)'
                    : opening
                    ? (ready ? 'Opening…' : 'Building…')
                    : (ready ? 'Play' : 'Build today\'s puzzle'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Leaderboard extends ConsumerWidget {
  final String puzzleId;
  final List<GroupMember> members;
  final String? me;

  const _Leaderboard({required this.puzzleId, required this.members, required this.me});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final names = {for (final m in members) m.userId: m.displayName};
    return ref
        .watch(groupScoresProvider(puzzleId))
        .when(
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => Text('$e', style: TextStyle(color: scheme.error)),
          data: (scores) {
            if (scores.isEmpty) {
              return Text(
                'Nobody has started yet.',
                style: TextStyle(color: scheme.onSurfaceVariant),
              );
            }
            return Column(
              children: [
                for (var i = 0; i < scores.length; i++)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Text(
                      '${i + 1}',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: i == 0 ? scheme.primary : scheme.onSurfaceVariant,
                      ),
                    ),
                    title: Text(
                      '${names[scores[i].userId] ?? 'Someone'}'
                      '${scores[i].userId == me ? ' (you)' : ''}',
                    ),
                    subtitle: Text(
                      '${scores[i].solvedWords}/${scores[i].totalWords} words'
                      '${scores[i].completed ? ' · finished' : ''}'
                      '${scores[i].aided ? ' · with reveals' : ''}'
                      '${scores[i].activeMs > 0 ? ' · ${_minutes(scores[i].activeMs)}' : ''}',
                    ),
                  ),
              ],
            );
          },
        );
  }

  static String _minutes(int ms) {
    final s = ms ~/ 1000;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}
