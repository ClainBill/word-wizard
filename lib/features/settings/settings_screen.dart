import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remindersAsync = ref.watch(remindersEnabledProvider);
    final reviewEnabledAsync = ref.watch(crosswordReviewEnabledProvider);
    final reviewConfigured = ref.watch(crosswordRepositoryProvider).reviewConfigured;
    final bannedCount = ref.watch(crosswordBannedAnswersProvider).valueOrNull?.length ?? 0;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const ListTile(
            leading: Icon(Icons.dark_mode_outlined),
            title: Text('Theme'),
            subtitle: Text('Follows system light/dark setting'),
          ),
          const ListTile(
            leading: Icon(Icons.record_voice_over_outlined),
            title: Text('Pronunciation voice'),
            subtitle: Text('Uses the device\'s default English text-to-speech voice'),
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('Notifications', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          remindersAsync.when(
            data: (enabled) => SwitchListTile(
              secondary: const Icon(Icons.notifications_active_outlined),
              title: const Text('Daily word reminders'),
              subtitle: const Text(
                'Two notifications a day, at random times, each with a word due '
                'soon and a one-sentence meaning and example',
              ),
              value: enabled,
              onChanged: (value) async {
                await ref.read(settingsRepositoryProvider).setRemindersEnabled(value);
                final notifications = ref.read(notificationServiceProvider);
                if (value) {
                  await notifications.requestPermissions();
                  await notifications.scheduleDailyReminders(ref.read(studyRepositoryProvider));
                } else {
                  await notifications.cancelAll();
                }
              },
            ),
            loading: () => const ListTile(
              leading: Icon(Icons.notifications_active_outlined),
              title: Text('Daily word reminders'),
              trailing: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
            error: (e, _) => ListTile(
              leading: const Icon(Icons.notifications_active_outlined),
              title: const Text('Daily word reminders'),
              subtitle: Text('Couldn\'t load: $e'),
            ),
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('Developer', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.auto_fix_high_outlined),
            title: const Text('Crossword AI editor'),
            subtitle: Text(
              !reviewConfigured
                  ? 'No API key in this build. Run with '
                      '--dart-define-from-file=.env to enable it.'
                  : 'One model call per new puzzle rewrites weak clues. Costs '
                      'tokens; turn it off to regenerate puzzles for free. '
                      'Per-puzzle cost is in each size\'s History screen.',
            ),
            // A key-less build can't run the pass whatever the switch says,
            // so the switch shows off and does nothing rather than implying
            // an on state that never fires.
            value: reviewConfigured && (reviewEnabledAsync.valueOrNull ?? true),
            onChanged: reviewConfigured
                ? (value) =>
                    ref.read(settingsRepositoryProvider).setCrosswordReviewEnabled(value)
                : null,
          ),
          ListTile(
            leading: const Icon(Icons.block_outlined),
            title: const Text('Banned crossword answers'),
            subtitle: Text(
              bannedCount == 0
                  ? 'Nothing banned yet'
                  : '$bannedCount answer${bannedCount == 1 ? '' : 's'} kept out '
                      'of every puzzle',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/games/crossword-bans'),
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('About', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              'Word Wizard is an offline, ad-free advanced-English vocabulary '
              'dictionary and flashcard app. Dictionary content is derived from '
              'the English Wiktionary via the Kaikki.org project, licensed under '
              'CC BY-SA 3.0 and GFDL.',
            ),
          ),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Version'),
            subtitle: Text('0.1.0 (MVP)'),
          ),
        ],
      ),
    );
  }
}
