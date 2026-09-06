import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remindersAsync = ref.watch(remindersEnabledProvider);

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
