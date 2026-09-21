import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/premium/prompt_policy.dart';
import '../../services/premium_analytics.dart';
import 'paywall_screen.dart';

/// The contextual, unsolicited nudge (spec §4.4, §5) — a sheet, not a
/// paywall: two lines and two buttons. Shows only when the policy says the
/// moment is fair; the trigger sites call this and forget about it.
///
/// [trigger] names the moment for the funnel: `milestone_25`,
/// `review_complete`.
Future<void> maybeShowPremiumPrompt(BuildContext context, {required String trigger}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final prompts = container.read(premiumPromptsProvider);
  final wordCount = container.read(studyStatsProvider).valueOrNull?.total ?? 0;
  final isPremium = container.read(isPremiumProvider);
  final verdict = prompts.verdict(wordCount: wordCount, isPremium: isPremium);
  prompts.pendingMilestone = null;
  if (verdict != PromptVerdict.show) return;
  await prompts.markShown();
  if (!context.mounted) return;
  PremiumAnalytics.instance.log('paywall_viewed', {
    'source': 'prompt_$trigger',
    'variant': 'prompt',
    'word_count': wordCount,
  });
  final see = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (context) => _PromptSheet(wordCount: wordCount),
  );
  if (see == true) {
    if (context.mounted) await showPaywall(context, source: 'prompt_$trigger');
  } else {
    await prompts.markDismissed();
    PremiumAnalytics.instance.log('paywall_dismissed', {
      'source': 'prompt_$trigger',
      'variant': 'prompt',
    });
  }
}

class _PromptSheet extends StatelessWidget {
  final int wordCount;

  const _PromptSheet({required this.wordCount});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Your word collection is ready to play',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            'You have saved $wordCount ${wordCount == 1 ? 'word' : 'words'}. Premium can turn '
            'them into crosswords, Word Hunt and shared games with friends.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('See Premium'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
        ],
      ),
    );
  }
}
