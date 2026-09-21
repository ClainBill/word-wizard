import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/games/scoring.dart';
import '../../services/leaderboard_api.dart';
import '../account/sign_in_sheet.dart' show showSignInSheet;

/// Games → Leaderboard: this week and all time, top 50 plus your own
/// standing, and the opt-in that puts you on it. Anyone can look; getting
/// on it takes an account, since scores are uploaded against one.
class LeaderboardScreen extends ConsumerStatefulWidget {
  const LeaderboardScreen({super.key});

  @override
  ConsumerState<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends ConsumerState<LeaderboardScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  Future<void> _sync({bool force = false}) async {
    final user = ref.read(authUserProvider).valueOrNull;
    final n = await ref.read(scoreSyncProvider).sync(userId: user?.id, force: force);
    if (n > 0 && mounted) {
      ref.invalidate(leaderboardProvider);
      ref.invalidate(myRankProvider);
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(leaderboardApiProvider);
    final user = ref.watch(authUserProvider).valueOrNull;
    final profile = ref.watch(leaderboardProfileProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Leaderboard'),
        bottom: !api.available
            ? null
            : TabBar(
                controller: _tabs,
                tabs: const [
                  Tab(text: 'This week'),
                  Tab(text: 'All time'),
                ],
              ),
      ),
      body: !api.available
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Not available in this build.'),
              ),
            )
          : Column(
              children: [
                if (user == null)
                  _Banner(
                    icon: Icons.person_outline,
                    text:
                        'Sign in to put your own puzzle scores on the board, under a name you choose.',
                    onTap: () => showSignInSheet(context, ref),
                  )
                else if (profile != null && !profile.visible)
                  _Banner(
                    icon: Icons.visibility_off_outlined,
                    text:
                        'You\'re not on the board. Pick a public name to join — only the name and '
                        'your score are shown.',
                    onTap: () => showLeaderboardOptIn(context, ref),
                  ),
                Expanded(
                  child: TabBarView(
                    controller: _tabs,
                    children: [
                      _Board(period: 'week', onRefresh: () => _sync(force: true)),
                      _Board(period: 'all', onRefresh: () => _sync(force: true)),
                    ],
                  ),
                ),
              ],
            ),
      floatingActionButton: !api.available
          ? null
          : user == null
          ? FloatingActionButton.extended(
              onPressed: () => showSignInSheet(context, ref),
              icon: const Icon(Icons.login),
              label: const Text('Sign in to join'),
            )
          : FloatingActionButton.extended(
              onPressed: () => showLeaderboardOptIn(context, ref),
              icon: const Icon(Icons.badge_outlined),
              label: Text(profile?.visible == true ? 'Your name' : 'Join the board'),
            ),
    );
  }
}

/// The strip above the board: what stands between this person and being
/// on it, and the way there.
class _Banner extends StatelessWidget {
  final IconData icon;
  final String text;
  final VoidCallback onTap;
  const _Banner({required this.icon, required this.text, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primaryContainer.withValues(alpha: 0.5),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: [
              Icon(icon, color: scheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(child: Text(text)),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

class _Board extends ConsumerWidget {
  final String period;
  final Future<void> Function() onRefresh;

  const _Board({required this.period, required this.onRefresh});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final entries = ref.watch(leaderboardProvider(period));
    final mine = ref.watch(myRankProvider(period)).valueOrNull;
    return RefreshIndicator(
      onRefresh: () async {
        await onRefresh();
        ref.invalidate(leaderboardProvider(period));
        ref.invalidate(myRankProvider(period));
      },
      child: entries.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ListView(
          children: [Padding(padding: const EdgeInsets.all(24), child: Text('$e'))],
        ),
        data: (rows) => ListView(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 96),
          children: [
            if (mine != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Text('#${mine.rank}', style: Theme.of(context).textTheme.headlineSmall),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          'You · ${mine.score} points from ${mine.puzzles} '
                          '${mine.puzzles == 1 ? 'puzzle' : 'puzzles'} · ${mine.players} on the board',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  period == 'week'
                      ? 'Nobody has scored this week yet. The week starts on Monday.'
                      : 'Nobody on the board yet.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            for (final e in rows)
              ListTile(
                selected: e.isMe,
                leading: SizedBox(
                  width: 36,
                  child: Text(
                    '${e.rank}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: e.rank <= 3 ? 18 : 15,
                      color: e.rank == 1 ? scheme.primary : null,
                    ),
                  ),
                ),
                title: Text(e.name + (e.isMe ? ' (you)' : '')),
                subtitle: Text('${e.puzzles} ${e.puzzles == 1 ? 'puzzle' : 'puzzles'}'),
                trailing: Text(
                  '${e.score}',
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Text(
                'Points: crossword answers 10 each (×2 Midi, ×3 Mega), finishing +50, no reveals +25, '
                'pace up to +30; Word Hunt board score ×5, clearing the list +50. Unfinished puzzles '
                'keep the points for what they got.',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Public name + the switch. The same sheet from Settings → Account.
Future<void> showLeaderboardOptIn(BuildContext context, WidgetRef ref) async {
  final current = await ref.read(leaderboardApiProvider).profile();
  if (!context.mounted) return;
  final result = await showModalBottomSheet<(String, bool)>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: _OptInSheet(profile: current),
    ),
  );
  if (result == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    final (name, optIn) = result;
    await ref
        .read(leaderboardApiProvider)
        .setProfile(publicName: name.isEmpty ? null : name, optIn: optIn);
    ref.invalidate(leaderboardProfileProvider);
    final user = ref.read(authUserProvider).valueOrNull;
    if (optIn) await ref.read(scoreSyncProvider).sync(userId: user?.id, force: true);
    ref.invalidate(leaderboardProvider);
    ref.invalidate(myRankProvider);
    messenger.showSnackBar(
      SnackBar(
        content: Text(optIn ? 'You\'re on the board as "$name".' : 'Removed from the board.'),
      ),
    );
  } on LeaderboardException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  }
}

class _OptInSheet extends StatefulWidget {
  final LeaderboardProfile profile;
  const _OptInSheet({required this.profile});

  @override
  State<_OptInSheet> createState() => _OptInSheetState();
}

class _OptInSheetState extends State<_OptInSheet> {
  late final _name = TextEditingController(text: widget.profile.publicName ?? '');
  late bool _optIn = widget.profile.optIn;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (_optIn && name.length < 2) {
      setState(() => _error = 'A public name is at least two characters.');
      return;
    }
    Navigator.of(context).pop((name, _optIn));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('On the leaderboard', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 6),
          Text(
            'Only this name and your puzzle points are shown, to anyone using the app. Your '
            'words, progress and email stay private. Switch it off any time.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            maxLength: 24,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Public name',
              border: OutlineInputBorder(),
              counterText: '',
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Show me on the leaderboard'),
            value: _optIn,
            onChanged: (v) => setState(() => _optIn = v),
          ),
          if (_error != null) Text(_error!, style: TextStyle(color: scheme.error)),
          const SizedBox(height: 8),
          FilledButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
    );
  }
}
