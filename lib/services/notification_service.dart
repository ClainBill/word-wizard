import 'dart:math';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../data/repositories/study_repository.dart';
import '../domain/models/daily_word.dart';

const _channelId = 'daily_word';
const _wordOfTheDayChannelId = 'word_of_the_day';

/// Notification ids: the reminders take a block from 0, the word of the
/// day its own, so scheduling one kind never cancels the other.
const _reminderIdBase = 0;
const _reminderIdCount = 4;
const _wordOfTheDayIdBase = 100;
const _wordOfTheDayIdCount = 2;

/// When the word of the day arrives, local time.
const wordOfTheDayHour = 9;

/// Schedules the "random due word, twice a day" reminder notifications.
///
/// There's no on-device background isolate picking a fresh word right at
/// fire time here — each notification's word/meaning/example is chosen and
/// baked in when [scheduleDailyReminders] runs, then delivered by Android's
/// alarm scheduler even if the app is closed. To keep that content
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

  /// Called with a notification's payload — a route, `/entry/acumen` —
  /// when the user taps it while the app is running. Set by `main`.
  void Function(String route)? onOpen;

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
        // Permission is asked for explicitly in requestPermissions() so the
        // iOS prompt appears at the same point in the flow as on Android.
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload != null && payload.isNotEmpty) onOpen?.call(payload);
      },
    );
    _initialized = true;
  }

  /// The route carried by the notification the app was just launched from
  /// (cold start), or null when it was opened any other way. Read once at
  /// start-up so the word of the day opens on its card.
  Future<String?> launchRoute() async {
    await _ensureInitialized();
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details == null || !details.didNotificationLaunchApp) return null;
    final payload = details.notificationResponse?.payload;
    return payload == null || payload.isEmpty ? null : payload;
  }

  /// Android 13+ notification permission, or the iOS alert/sound
  /// permission. Safe to call repeatedly — the OS no-ops once granted.
  ///
  /// No exact-alarm permission: the reminders are scheduled inexactly (see
  /// [scheduleDailyReminders]), which needs none.
  Future<void> requestPermissions() async {
    await _ensureInitialized();
    final android =
        _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
    final ios =
        _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    await ios?.requestPermissions(alert: true, sound: true);
  }

  Future<void> cancelReminders() async {
    await _ensureInitialized();
    for (var i = 0; i < _reminderIdCount; i++) {
      await _plugin.cancel(_reminderIdBase + i);
    }
  }

  Future<void> cancelWordOfTheDay() async {
    await _ensureInitialized();
    for (var i = 0; i < _wordOfTheDayIdCount; i++) {
      await _plugin.cancel(_wordOfTheDayIdBase + i);
    }
  }

  /// One notification at [wordOfTheDayHour] for today (if that's still
  /// ahead) and tomorrow, each carrying that day's word from the curated
  /// pool, and a tap opens the word's card. Re-run on every launch like the
  /// reminders, so it never goes more than a day stale.
  Future<void> scheduleWordOfTheDay(Future<DailyWord?> Function(DateTime day) pick) async {
    await _ensureInitialized();
    await cancelWordOfTheDay();
    const scheduleMode = AndroidScheduleMode.inexactAllowWhileIdle;
    final now = tz.TZDateTime.now(tz.local);
    for (var dayOffset = 0; dayOffset < _wordOfTheDayIdCount; dayOffset++) {
      final fireAt = tz.TZDateTime(
        tz.local, now.year, now.month, now.day + dayOffset, wordOfTheDayHour);
      if (!fireAt.isAfter(now)) continue;
      final word = await pick(DateTime(fireAt.year, fireAt.month, fireAt.day));
      if (word == null) continue;
      await _plugin.zonedSchedule(
        _wordOfTheDayIdBase + dayOffset,
        'Word of the day: ${word.headword}',
        word.notificationBody,
        fireAt,
        NotificationDetails(
          android: AndroidNotificationDetails(
            _wordOfTheDayChannelId,
            'Word of the day',
            channelDescription: 'One new word every morning.',
            icon: 'ic_notification',
            styleInformation: BigTextStyleInformation(word.notificationBody),
          ),
          iOS: const DarwinNotificationDetails(),
        ),
        androidScheduleMode: scheduleMode,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
        payload: '/entry/${Uri.encodeComponent(word.headword)}',
      );
    }
  }

  /// Replaces all pending reminders with a fresh set: up to two per day,
  /// for today and tomorrow, each naming a different random word due
  /// within the next 24h. A day with nothing due yields no notification
  /// for that day rather than an empty/misleading one.
  Future<void> scheduleDailyReminders(StudyRepository studyRepo) async {
    await _ensureInitialized();
    await cancelReminders();

    // Inexact on purpose. The times are random to begin with, so a
    // reminder landing some minutes after its slot loses nothing, and it
    // keeps the app clear of the exact-alarm permissions — which Play
    // policy reserves for alarm-clock and calendar apps, and which a user
    // could decline anyway, silently cancelling every reminder.
    const scheduleMode = AndroidScheduleMode.inexactAllowWhileIdle;

    final rand = Random();
    final now = tz.TZDateTime.now(tz.local);
    var id = _reminderIdBase;

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
            iOS: const DarwinNotificationDetails(),
          ),
          androidScheduleMode: scheduleMode,
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
