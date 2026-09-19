import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../services/api_key_store.dart';
import '../../services/feedback_config.dart';
import 'account_section.dart';
import 'api_key_sheet.dart';
import 'voice_picker_sheet.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remindersAsync = ref.watch(remindersEnabledProvider);
    final wordOfTheDayEnabled = ref.watch(wordOfTheDayEnabledProvider).valueOrNull ?? true;
    final reviewEnabledAsync = ref.watch(crosswordReviewEnabledProvider);
    // Rebuilds when a key is saved or removed, so the AI switch below
    // follows it.
    final keyStore = ref.watch(apiKeyStoreProvider);
    // Signing in or out changes what the AI features can do, and the
    // repository's getter reads that live — so this rebuild has to follow it.
    final signedIn = ref.watch(authUserProvider).valueOrNull != null;
    final reviewConfigured = ref.watch(crosswordRepositoryProvider).reviewConfigured;
    final bannedCount = ref.watch(crosswordBannedAnswersProvider).valueOrNull?.length ?? 0;
    final pendingFeedback = ref.watch(feedbackPendingProvider).valueOrNull ?? 0;
    final themeMode = ref.watch(themeModeProvider).valueOrNull ?? ThemeMode.system;
    final voice = ref.watch(ttsVoiceProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const AccountSection(),
          const Divider(),
          ListTile(
            leading: Icon(switch (themeMode) {
              ThemeMode.light => Icons.light_mode_outlined,
              ThemeMode.dark => Icons.dark_mode_outlined,
              ThemeMode.system => Icons.brightness_auto_outlined,
            }),
            title: const Text('Theme'),
            subtitle: Text(switch (themeMode) {
              ThemeMode.light => 'Light',
              ThemeMode.dark => 'Dark',
              ThemeMode.system => 'Follows the system light/dark setting',
            }),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickTheme(context, ref, themeMode),
          ),
          ListTile(
            leading: const Icon(Icons.record_voice_over_outlined),
            title: const Text('Pronunciation voice'),
            subtitle: Text(
              voice == null
                  ? 'The device\'s default English text-to-speech voice'
                  : describeVoice(voice),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showVoicePickerSheet(context),
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
                  await notifications.cancelReminders();
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
          SwitchListTile(
            secondary: const Icon(Icons.wb_sunny_outlined),
            title: const Text('Word of the day'),
            subtitle: const Text(
              'One new word every morning at 9, with its meaning and an example. '
              'The word is featured on the Search tab either way.',
            ),
            value: wordOfTheDayEnabled,
            onChanged: (value) async {
              await ref.read(settingsRepositoryProvider).setWordOfTheDayEnabled(value);
              final notifications = ref.read(notificationServiceProvider);
              if (value) {
                await notifications.requestPermissions();
                await notifications.scheduleWordOfTheDay(
                  ref.read(searchRepositoryProvider).wordOfTheDay,
                );
              } else {
                await notifications.cancelWordOfTheDay();
              }
            },
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('AI features', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          if (signedIn)
            const ListTile(
              leading: Icon(Icons.auto_awesome_outlined),
              title: Text('AI features'),
              subtitle: Text(
                'The crossword AI editor and the "guess from the clues" recall game '
                'run through your account, with a daily allowance.',
              ),
            ),
          ListTile(
            leading: const Icon(Icons.key_outlined),
            title: Text(signedIn ? 'Your own OpenAI key (optional)' : 'OpenAI API key'),
            subtitle: Text(
              keyStore.hasKey
                  ? 'Using your key (${ApiKeyStore.mask(keyStore.key!)})'
                        '${signedIn ? ' instead of your account\'s allowance, at your own cost.' : '. Powers the crossword AI editor and the "guess from the clues" recall game.'}'
                  : signedIn
                  ? 'Not needed. Add one only to use OpenAI directly at your own cost.'
                  : reviewConfigured
                  ? 'Using the key from this debug build. Sign in, or add your own '
                        'key, to use the AI features in any build.'
                  : 'Sign in to use the AI features, or add your own OpenAI key.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showApiKeySheet(context),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.auto_fix_high_outlined),
            title: const Text('Crossword AI editor'),
            subtitle: Text(
              !reviewConfigured
                  ? 'Sign in, or add an API key above, to use it.'
                  : 'One model call per new puzzle rewrites weak clues. Costs '
                        'tokens; turn it off to regenerate puzzles for free. '
                        'Per-puzzle cost is in each size\'s History screen.',
            ),
            // A key-less build can't run the pass whatever the switch says,
            // so the switch shows off and does nothing rather than implying
            // an on state that never fires.
            value: reviewConfigured && (reviewEnabledAsync.valueOrNull ?? true),
            onChanged: reviewConfigured
                ? (value) => ref.read(settingsRepositoryProvider).setCrosswordReviewEnabled(value)
                : null,
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('Developer', style: TextStyle(fontWeight: FontWeight.w600)),
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
            child: Text('Feedback', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('Report a bug or suggest a feature'),
            subtitle: Text(
              pendingFeedback == 0
                  ? 'Right here in the app — attach a screenshot of the screen '
                        'you were just on, or a photo'
                  : '$pendingFeedback report${pendingFeedback == 1 ? '' : 's'} saved, '
                        'waiting to send',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/feedback'),
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('About', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              'Lexery is an offline, ad-free advanced-English vocabulary '
              'dictionary and flashcard app. Dictionary content is derived from '
              'the English Wiktionary via the Kaikki.org project, licensed under '
              'CC BY-SA 3.0 and GFDL.',
            ),
          ),
          ListTile(
            leading: const Icon(Icons.balance_outlined),
            title: const Text('Data sources & licences'),
            subtitle: const Text('Wiktionary, ENABLE, WordNet and the rest, and their terms'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/licences'),
          ),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Version'),
            subtitle: Text(appVersion),
          ),
        ],
      ),
    );
  }

  Future<void> _pickTheme(BuildContext context, WidgetRef ref, ThemeMode current) async {
    final picked = await showDialog<ThemeMode>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Theme'),
        children: [
          RadioGroup<ThemeMode>(
            groupValue: current,
            onChanged: (value) => Navigator.of(context).pop(value),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (mode, label) in [
                  (ThemeMode.system, 'Follow the system'),
                  (ThemeMode.light, 'Light'),
                  (ThemeMode.dark, 'Dark'),
                ])
                  RadioListTile<ThemeMode>(value: mode, title: Text(label)),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked != null) {
      await ref.read(settingsRepositoryProvider).setThemeMode(picked);
    }
  }
}
