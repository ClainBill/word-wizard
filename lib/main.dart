import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/providers.dart';
import 'app/router.dart';
import 'app/theme.dart';
import 'data/app_databases.dart';
import 'data/repositories/settings_repository.dart';
import 'data/repositories/study_repository.dart';
import 'services/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final databases = await AppDatabases.open();
  runApp(
    ProviderScope(
      overrides: [appDatabasesProvider.overrideWithValue(databases)],
      child: const WordWizardApp(),
    ),
  );

  // Fire-and-forget: refreshes today/tomorrow's reminder notifications on
  // every launch (see NotificationService's doc comment for why) without
  // blocking the first frame on permission dialogs or database queries.
  final remindersEnabled =
      await SettingsRepository(databases.user).watchRemindersEnabled().first;
  if (remindersEnabled) {
    final notifications = NotificationService.instance;
    await notifications.requestPermissions();
    await notifications.scheduleDailyReminders(StudyRepository(databases.user));
  }
}

class WordWizardApp extends StatelessWidget {
  const WordWizardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Word Wizard',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      routerConfig: appRouter,
    );
  }
}
