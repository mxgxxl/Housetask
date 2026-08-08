import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import '../data/models/task.dart';

/// Local notifications. Schedules a reminder one hour before a task's due
/// date. Remote push (FCM) will be layered on later.
class NotificationService {
  NotificationService._internal();
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  static const AndroidNotificationDetails _androidDetails =
      AndroidNotificationDetails(
    'task_reminders',
    'Task reminders',
    channelDescription: 'Reminders for upcoming household tasks',
    importance: Importance.high,
    priority: Priority.high,
  );

  static const NotificationDetails _details = NotificationDetails(
    android: _androidDetails,
    iOS: DarwinNotificationDetails(),
  );

  /// Initialize the plugin + timezone database and request permissions.
  Future<void> init() async {
    if (_initialized) return;

    tz_data.initializeTimeZones();

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    await _plugin.initialize(
      const InitializationSettings(android: androidInit, iOS: iosInit),
    );

    await _requestPermissions();
    _initialized = true;
  }

  Future<void> _requestPermissions() async {
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    await _plugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);
  }

  /// Stable notification id derived from the task id.
  int _idForTask(String taskId) => taskId.hashCode & 0x7fffffff;

  /// Schedule a reminder one hour before [task.dueDate]. No-op if the task has
  /// no due date or the reminder time is already in the past.
  Future<void> scheduleTaskReminder(Task task) async {
    if (!_initialized) await init();
    final dueDate = task.dueDate;
    if (dueDate == null) return;

    final remindAt = dueDate.subtract(const Duration(hours: 1));
    if (remindAt.isBefore(DateTime.now())) return;

    try {
      await _plugin.zonedSchedule(
        _idForTask(task.id),
        'Upcoming task',
        task.title,
        tz.TZDateTime.from(remindAt, tz.local),
        _details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    } catch (e) {
      debugPrint('Failed to schedule reminder: $e');
    }
  }

  Future<void> cancelTaskReminder(String taskId) async {
    await _plugin.cancel(_idForTask(taskId));
  }

  Future<void> cancelAll() async => _plugin.cancelAll();
}
