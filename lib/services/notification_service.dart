import 'dart:math';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../data/repositories/study_repository.dart';

const _channelId = 'daily_word';

/// Schedules the "random due word, twice a day" reminder notifications.
///
/// There's no on-device background isolate picking a fresh word right at
/// fire time here — each notification's word/meaning/example is chosen and
/// baked in when [scheduleDailyReminders] runs, then delivered by Android's
/// exact-alarm scheduler even if the app is closed. To keep that content
/// from ever going more than a day stale, every app launch re-picks two
/// random times (one per rough half of the day) for both today and
/// tomorrow and replaces whatever was previously scheduled. A user who
/// doesn't open the app for two or more days in a row will stop getting
/// new reminders until they do — an acceptable trade for a personal daily-
/// study app, and far simpler than a background-isolate + boot-safe alarm
/// pipeline for a single-user build.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    tzdata.initializeTimeZones();
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } catch (_) {
      // Falls back to whatever `timezone` defaults to (UTC) — scheduling
      // still works, just not necessarily at the intended wall-clock hour.
    }
    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('ic_notification'),
      ),
    );
    _initialized = true;
  }

  /// Android 13+ notification permission and Android 12+ exact-alarm
  /// permission. Safe to call repeatedly — the OS no-ops once granted.
  Future<void> requestPermissions() async {
    await _ensureInitialized();
    final android =
        _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
    await android?.requestExactAlarmsPermission();
  }

  Future<void> cancelAll() async {
    await _ensureInitialized();
    await _plugin.cancelAll();
  }

  /// Replaces all pending reminders with a fresh set: up to two per day,
  /// for today and tomorrow, each naming a different random word due
  /// within the next 24h. A day with nothing due yields no notification
  /// for that day rather than an empty/misleading one.
  Future<void> scheduleDailyReminders(StudyRepository studyRepo) async {
    await _ensureInitialized();
    await _plugin.cancelAll();

    final rand = Random();
    final now = tz.TZDateTime.now(tz.local);
    var id = 0;

    for (var dayOffset = 0; dayOffset < 2; dayOffset++) {
      final day = tz.TZDateTime(tz.local, now.year, now.month, now.day + dayOffset);
      for (final fireAt in _pickTimesForDay(day, rand)) {
        if (!fireAt.isAfter(now)) continue;
        final word = await studyRepo.pickReminderWord();
        if (word == null) continue;
        await _plugin.zonedSchedule(
          id++,
          word.headword,
          word.notificationBody,
          fireAt,
          NotificationDetails(
            android: AndroidNotificationDetails(
              _channelId,
              'Daily word reminders',
              channelDescription: 'A random word due for review, twice a day.',
              icon: 'ic_notification',
              styleInformation: BigTextStyleInformation(word.notificationBody),
            ),
          ),
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
        );
      }
    }
  }

  /// One random time in a late-morning window and one in an evening
  /// window, so the two daily notifications land at plausibly different
  /// points in the day instead of clustering together.
  List<tz.TZDateTime> _pickTimesForDay(tz.TZDateTime day, Random rand) {
    tz.TZDateTime randomTimeInMinuteRange(int startMin, int endMin) {
      final minute = startMin + rand.nextInt(endMin - startMin);
      return tz.TZDateTime(tz.local, day.year, day.month, day.day, minute ~/ 60, minute % 60);
    }

    return [
      randomTimeInMinuteRange(9 * 60, 13 * 60), // 9:00–13:00
      randomTimeInMinuteRange(17 * 60, 21 * 60), // 17:00–21:00
    ];
  }
}
