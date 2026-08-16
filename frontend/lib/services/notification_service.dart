import 'dart:async';
import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import 'package:uuid/uuid.dart';
import '../config/routes.dart';
import '../data/datasources/remote/api_service.dart';
import '../data/models/task.dart';

/// Local notifications (scheduled task reminders) plus remote push via FCM
/// (PDR-008): device token registration and foreground/tapped message
/// handling. A missing/misconfigured Firebase project (no
/// google-services.json / GoogleService-Info.plist — see
/// frontend/README.md) degrades every FCM call to a caught, logged no-op
/// rather than crashing the app; local reminders are unaffected either way.
class NotificationService {
  NotificationService._internal();
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  final Uuid _uuid = const Uuid();
  bool _initialized = false;

  ApiService? _api;
  bool _pushInitialized = false;
  StreamSubscription<String>? _tokenRefreshSubscription;

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

  /// Distinct id for the "starts in 30 min" reminder (PDR-004) — offset by a
  /// fixed salt so it never collides with [_idForTask]'s dueDate reminder id
  /// for the same task, letting both be scheduled/canceled independently.
  int _startReminderIdForTask(String taskId) =>
      (taskId.hashCode ^ 0x53544152) & 0x7fffffff; // 'STAR' as a salt

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

  /// Schedule a reminder 30 minutes before [task.startsAt] (PDR-004).
  /// Cancels any previously-scheduled one and returns if the task no longer
  /// has a startsAt (e.g. an edit removed it, or it just became recurring —
  /// the backend already strips startsAt/endsAt from those) so a stale
  /// reminder never fires for a task that no longer has a start time. Also a
  /// no-op if the reminder time is already in the past. Independent of
  /// [scheduleTaskReminder] (dueDate, 1h before): a task with both a dueDate
  /// and a startsAt gets both reminders, each under its own id, so
  /// scheduling/canceling one never touches the other.
  Future<void> scheduleTaskStartReminder(Task task) async {
    if (!_initialized) await init();
    final startsAt = task.startsAt;
    if (startsAt == null) {
      await _plugin.cancel(_startReminderIdForTask(task.id));
      return;
    }

    final remindAt = startsAt.subtract(const Duration(minutes: 30));
    if (remindAt.isBefore(DateTime.now())) return;

    try {
      await _plugin.zonedSchedule(
        _startReminderIdForTask(task.id),
        'Empieza en 30 min: ${task.title}',
        null,
        tz.TZDateTime.from(remindAt, tz.local),
        _details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    } catch (e) {
      debugPrint('Failed to schedule start reminder: $e');
    }
  }

  Future<void> cancelTaskStartReminder(String taskId) async {
    await _plugin.cancel(_startReminderIdForTask(taskId));
  }

  Future<void> cancelAll() async => _plugin.cancelAll();

  // ---- Remote push (FCM, PDR-008) ----

  /// Wires the [ApiService] used by [registerToken]/[unregisterToken] to talk
  /// to the backend. Called once from the composition root (app.dart) —
  /// NotificationService is a singleton constructed before ApiService exists,
  /// so it cannot take it as a constructor dependency.
  void attachApi(ApiService api) {
    _api = api;
  }

  /// iOS 10+ requires explicit permission before FCM delivers anything;
  /// Android grants silently pre-13 and via the already-declared
  /// POST_NOTIFICATIONS permission on 13+. Returns whether the user granted
  /// (or provisionally granted) permission.
  Future<bool> requestPermission() async {
    try {
      final settings = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      return settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
    } catch (e) {
      // No Firebase project wired up yet (see frontend/README.md) — push is
      // a bonus feature, never a reason to block login.
      debugPrint('Failed to request push notification permission: $e');
      return false;
    }
  }

  /// The device's current FCM registration token, or null if unavailable
  /// (no Firebase project configured, permission denied, offline, ...).
  Future<String?> getToken() async {
    try {
      return await FirebaseMessaging.instance.getToken();
    } catch (e) {
      debugPrint('Failed to get FCM token: $e');
      return null;
    }
  }

  /// Registers the device's FCM token with the backend
  /// (`POST /api/devices/register`, Hard Rule 13 idempotency-protected).
  /// [token] is injectable for tests; production calls always resolve it
  /// from [getToken]. A missing API binding, a null token (no Firebase
  /// project), or a network failure are all silent no-ops — registration is
  /// retried on the next app start / token refresh, never worth surfacing to
  /// the user.
  Future<void> registerToken({String? token}) async {
    final api = _api;
    if (api == null) return;

    final resolvedToken = token ?? await getToken();
    if (resolvedToken == null) return;

    try {
      await api.post(
        '/devices/register',
        body: {
          'token': resolvedToken,
          'platform': defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
        },
        headers: {'Idempotency-Key': _uuid.v4()},
      );
    } catch (e) {
      debugPrint('Failed to register device token: $e');
    }
  }

  /// Removes this device's token from the backend (`DELETE
  /// /api/devices/:token`), called on logout so a stale token never keeps
  /// receiving another user's notifications on a shared device.
  Future<void> unregisterToken() async {
    final api = _api;
    if (api == null) return;

    try {
      final token = await getToken();
      if (token == null) return;
      await api.delete('/devices/$token');
    } catch (e) {
      debugPrint('Failed to unregister device token: $e');
    }
  }

  /// Re-registers the token whenever FCM rotates it (rare, but happens on
  /// e.g. app restore to a new device). Idempotent to call more than once —
  /// only the first call attaches the listener.
  void listenForTokenRefresh() {
    _tokenRefreshSubscription ??=
        FirebaseMessaging.instance.onTokenRefresh.listen((_) => registerToken());
  }

  /// Displays a push notification's content immediately via the same local
  /// notification channel task reminders use — this is what makes a
  /// foreground push (which FCM does NOT show a system banner for on its
  /// own) visible to the user.
  Future<void> showLocalNotification(String? title, String? body, Map<String, dynamic>? data) async {
    if (!_initialized) await init();
    try {
      await _plugin.show(
        DateTime.now().millisecondsSinceEpoch & 0x7fffffff,
        title,
        body,
        _details,
        payload: data != null ? jsonEncode(data) : null,
      );
    } catch (e) {
      debugPrint('Failed to show local notification: $e');
    }
  }

  /// Navigates to the relevant screen when the user taps a push notification
  /// that opened the app from the background. Only `type: 'task'` is wired
  /// up today (task assignment/completion, PDR-008's two triggers) — there is
  /// no per-task deep-link route yet, so this lands on the main shell (whose
  /// default tab shows tasks) rather than opening the specific task.
  void _handleNotificationTap(RemoteMessage message) {
    if (message.data['type'] == 'task') {
      Routes.navigatorKey.currentState?.pushNamedAndRemoveUntil(Routes.main, (route) => false);
    }
  }

  /// Full push setup: permission, initial token registration, token-refresh
  /// listener, and foreground/tapped message handling. Called once per
  /// session after a successful login (app.dart) — safe to call more than
  /// once, a no-op after the first successful run so re-emitted auth states
  /// don't re-request permission or double-subscribe listeners.
  Future<void> initPushNotifications() async {
    if (_pushInitialized) return;

    final granted = await requestPermission();
    if (!granted) return;

    _pushInitialized = true;

    await registerToken();
    listenForTokenRefresh();

    // Foreground: FCM delivers the message but shows no system banner itself
    // (that's normal FCM behavior, not a bug) — showLocalNotification is what
    // makes it visible while the user has the app open.
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      showLocalNotification(message.notification?.title, message.notification?.body, message.data);
    });

    // Background → foreground via a notification tap.
    FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap);
  }
}
