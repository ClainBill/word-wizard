import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../domain/crossword/crossword_models.dart';
import '../../domain/premium/premium.dart' show sampleWithoutEditorNote;
import '../premium/paywall_screen.dart';

/// The one size a free account can play, clearly labelled as a sample
/// (spec §2.1, §3.2): it proves the experience without granting the
/// daily catalogue.
const CrosswordDifficulty sampleCrossword = CrosswordDifficulty.mini;

/// Whether [location] is a game a free account may open.
bool gameRouteIsFree(String location) =>
    location.startsWith('/games/crossword/${sampleCrossword.storageKey}') ||
    location.endsWith('/history') ||
    location == '/games/crossword-bans';

/// The Games tab. Premium: the full list. Free: the same cards, locked,
/// behind a paywall that the tab opens on every visit — and a useful
/// preview to stay on if the paywall is dismissed (spec §3.2).
class GamesScreen extends ConsumerWidget {
  const GamesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final premium = ref.watch(isPremiumProvider);
    final scheme = Theme.of(context).colorScheme;
    final wordCount = ref.watch(studyStatsProvider).valueOrNull?.total ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Games'),
        actions: [
          if (!premium)
            TextButton.icon(
              onPressed: () => showPaywall(context, source: 'games_header'),
              icon: const Icon(Icons.workspace_premium_outlined, size: 18),
              label: const Text('Premium'),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const _LeaderboardStrip(),
          const SizedBox(height: 20),
          if (!premium) ...[_LockedIntro(wordCount: wordCount), const SizedBox(height: 24)],
          Text('Daily Crossword', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            premium
                ? 'A grid of dictionary words with a few of today\'s study words mixed in.'
                : 'Three personalized puzzles a day, built around the words you\'re learning.',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          for (final difficulty in CrosswordDifficulty.values) ...[
            _DifficultyTile(
              difficulty: difficulty,
              locked: !premium && difficulty != sampleCrossword,
              sample: !premium && difficulty == sampleCrossword,
            ),
            const SizedBox(height: 10),
          ],
          if (!premium)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
              child: Text(
                sampleWithoutEditorNote,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
          const SizedBox(height: 16),
          Text('Word Hunt', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Trace words through a 4×4 board built around your study words and a daily theme.',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          _HuntTile(locked: !premium),
          const SizedBox(height: 32),
          Text('Group puzzles', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Pool your friends\' words into one daily crossword and see who knows them best.',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          if (premium)
            Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                onTap: () => context.push('/games/groups'),
                leading: CircleAvatar(
                  backgroundColor: scheme.secondaryContainer,
                  child: Icon(Icons.group_outlined, color: scheme.onSecondaryContainer),
                ),
                title: const Text('Your groups'),
                subtitle: const Text('Start one, or join with a code'),
                trailing: const Icon(Icons.chevron_right),
              ),
            )
          else ...[
            const _FriendGroupsCard(),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => showPaywall(context, source: 'games_footer'),
              icon: const Icon(Icons.workspace_premium_outlined),
              label: const Text('See Premium'),
            ),
          ],
        ],
      ),
    );
  }
}

/// The way to the leaderboard: one slim pill at the top of the tab, with
/// your standing this week folded in once you're on the board. Anyone can
/// open it, signed in or not.
class _LeaderboardStrip extends ConsumerWidget {
  const _LeaderboardStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final signedIn = ref.watch(authUserProvider).valueOrNull != null;
    final mine = signedIn ? ref.watch(myRankProvider('week')).valueOrNull : null;
    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(999),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.push('/games/leaderboard'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 7, 8, 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.emoji_events_outlined, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Text('Leaderboard', style: Theme.of(context).textTheme.labelLarge),
                if (mine != null) ...[
                  Text(
                    '  ·  #${mine.rank} this week',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
                const SizedBox(width: 2),
                Icon(Icons.chevron_right, size: 18, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LockedIntro extends StatelessWidget {
  final int wordCount;

  const _LockedIntro({required this.wordCount});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Make your words playable',
          style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Text(
          wordCount > 0
              ? 'You have $wordCount ${wordCount == 1 ? 'word' : 'words'} ready to play. Premium '
                    'turns them into daily games; the sample below is free.'
              : 'Premium turns the words you save into daily games. Try the sample below, '
                    'and add a few words to see your own in a puzzle.',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _DifficultyTile extends StatelessWidget {
  final CrosswordDifficulty difficulty;
  final bool locked;
  final bool sample;

  const _DifficultyTile({required this.difficulty, this.locked = false, this.sample = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final route = '/games/crossword/${difficulty.storageKey}';

    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        onTap: locked
            ? () => showPaywall(context, source: 'games_crossword', next: route)
            : () => context.push(route),
        leading: CircleAvatar(
          backgroundColor: locked ? scheme.surfaceContainerHighest : scheme.primaryContainer,
          child: locked
              ? Icon(Icons.lock_outline, color: scheme.onSurfaceVariant)
              : Text(
                  difficulty.label[0],
                  style: TextStyle(fontWeight: FontWeight.w600, color: scheme.onPrimaryContainer),
                ),
        ),
        title: Row(
          children: [
            Text(difficulty.label),
            if (sample) ...[
              const SizedBox(width: 8),
              _Tag(
                'Sample · free',
                color: scheme.secondaryContainer,
                onColor: scheme.onSecondaryContainer,
              ),
            ],
          ],
        ),
        subtitle: Text(
          locked
              ? '${difficulty.size}×${difficulty.size} · Premium'
              : sample
              ? '${difficulty.size}×${difficulty.size} · without the AI editor'
              : '${difficulty.size}×${difficulty.size}',
        ),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}

class _HuntTile extends StatelessWidget {
  final bool locked;

  const _HuntTile({this.locked = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        onTap: locked
            ? () => showPaywall(context, source: 'games_hunt', next: '/games/hunt')
            : () => context.push('/games/hunt'),
        leading: CircleAvatar(
          backgroundColor: locked ? scheme.surfaceContainerHighest : scheme.secondaryContainer,
          child: Icon(
            locked ? Icons.lock_outline : Icons.grid_view_rounded,
            color: locked ? scheme.onSurfaceVariant : scheme.onSecondaryContainer,
          ),
        ),
        title: const Text('Daily board'),
        subtitle: Text(
          locked ? '4×4 · new theme every day · Premium' : '4×4 · new theme every day',
        ),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}

/// Spec §4.5. Friend groups aren't built yet; the card says what they'll
/// be and opens the paywall.
class _FriendGroupsCard extends StatelessWidget {
  const _FriendGroupsCard();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.group_outlined, color: scheme.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Build a shared word world',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Icon(Icons.lock_outline, size: 18, color: scheme.onSurfaceVariant),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Combine your friends\' saved words, then solve together or compete to see who '
              'knows the group vocabulary best.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () => showPaywall(context, source: 'games_friends'),
                  child: const Text('Unlock friend groups'),
                ),
                TextButton(
                  onPressed: () => context.push('/games/groups'),
                  child: const Text('Have an invite code?'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;
  final Color color;
  final Color onColor;

  const _Tag(this.text, {required this.color, required this.onColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(999)),
      child: Text(text, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: onColor)),
    );
  }
}
