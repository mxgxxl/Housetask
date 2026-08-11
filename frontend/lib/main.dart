import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'app.dart';
import 'services/notification_service.dart';
import 'services/sentry_service.dart';

Future<void> main() async {
  // Wraps the whole bootstrap so that any error escaping an async gap — not
  // just a synchronous throw inside runApp's widget tree — reaches
  // SentryService, which itself no-ops when no DSN was passed at build time.
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // No-op unless built with --dart-define=SENTRY_DSN=...
      await SentryService.init();

      // Framework-level errors (widget build/layout/paint) are reported here
      // rather than only rethrown, so they reach Sentry the same way a caught
      // exception would.
      FlutterError.onError = (FlutterErrorDetails details) {
        SentryService.captureException(details.exception, stackTrace: details.stack);
      };

      // Locale data for date formatting (Spanish labels).
      await initializeDateFormatting('es', null);

      // Initialize local notifications (permissions + timezone db).
      await NotificationService().init();

      runApp(const HomeSyncApp());
    },
    (error, stackTrace) {
      SentryService.captureException(error, stackTrace: stackTrace);
    },
  );
}
