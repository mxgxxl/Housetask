import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'app.dart';
import 'services/cache_service.dart';
import 'services/notification_service.dart';
import 'services/sentry_service.dart';

Future<void> main() async {
  // Wraps the whole bootstrap so that any error escaping an async gap — not
  // just a synchronous throw inside runApp's widget tree — reaches
  // SentryService, which itself no-ops when no DSN was passed at build time.
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // TODO(tech-debt): temporary bootstrap tracing for the iOS white-screen
      // startup investigation — remove once the fix is confirmed on device.
      debugPrint('[bootstrap] Sentry init...');
      // No-op unless built with --dart-define=SENTRY_DSN=...
      await SentryService.init();
      debugPrint('[bootstrap] Sentry done');

      // Framework-level errors (widget build/layout/paint) are reported here
      // rather than only rethrown, so they reach Sentry the same way a caught
      // exception would.
      FlutterError.onError = (FlutterErrorDetails details) {
        SentryService.captureException(details.exception, stackTrace: details.stack);
      };

      // Locale data for date formatting (Spanish labels).
      await initializeDateFormatting('es', null);

      // PDR-008: no-op-safe — this repo ships no google-services.json /
      // GoogleService-Info.plist yet (see frontend/README.md), so this
      // throws on a real device/emulator until a real Firebase project is
      // wired up. Push notifications are a bonus feature, never a reason to
      // block app startup; NotificationService's own FCM calls are
      // independently guarded the same way.
      debugPrint('[bootstrap] Firebase init...');
      try {
        await Firebase.initializeApp();
      } catch (e) {
        debugPrint('Firebase.initializeApp() failed (push notifications disabled): $e');
      }
      debugPrint('[bootstrap] Firebase done');

      debugPrint('[bootstrap] NotificationService init...');
      // Initialize local notifications (permissions + timezone db).
      await NotificationService().init();
      debugPrint('[bootstrap] NotificationService done');

      debugPrint('[bootstrap] CacheService init...');
      // Open the Hive boxes offline-first repositories read/write (TD-003).
      await CacheService().init();
      debugPrint('[bootstrap] CacheService done');

      debugPrint('[bootstrap] runApp...');
      runApp(const HomeSyncApp());
    },
    (error, stackTrace) {
      SentryService.captureException(error, stackTrace: stackTrace);
    },
  );
}
