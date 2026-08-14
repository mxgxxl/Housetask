import 'dart:async' show unawaited;

import 'package:sentry_flutter/sentry_flutter.dart';

/// Error tracking, active only when a DSN is supplied at build time.
///
/// The DSN comes from `--dart-define=SENTRY_DSN=...`, never from
/// [AppConfig]/`constants.dart`: a value baked into a checked-in Dart file
/// would ship in the APK/IPA regardless of build flavor, whereas a
/// `--dart-define` can differ between a local debug build (empty, silent) and
/// a release build (set in CI) without touching source control.
class SentryService {
  SentryService._();

  static bool _initialized = false;

  /// Initialize Sentry from the `SENTRY_DSN` compile-time define.
  ///
  /// No-op when the define is empty — the default for every build that does
  /// not pass it explicitly, so debug runs and CI builds without a configured
  /// DSN behave exactly as if this service did not exist.
  static Future<void> init() async {
    const dsn = String.fromEnvironment('SENTRY_DSN');
    if (dsn.isEmpty) {
      return;
    }

    await SentryFlutter.init((options) {
      options.dsn = dsn;
      options.environment = const String.fromEnvironment(
        'ENVIRONMENT',
        defaultValue: 'development',
      );
      options.tracesSampleRate = 0.2;
    });
    _initialized = true;
  }

  /// Report an error. No-op when [init] never activated Sentry, so call
  /// sites never need to check whether a DSN is configured.
  static void captureException(
    dynamic error, {
    StackTrace? stackTrace,
    Map<String, dynamic>? context,
  }) {
    if (!_initialized) return;

    unawaited(
      Sentry.captureException(
        error,
        stackTrace: stackTrace,
        withScope: context == null
            ? null
            : (scope) {
                scope.setContexts('extra', context);
              },
      ),
    );
  }

  /// Record a breadcrumb for a key user flow (login, completing a task,
  /// adopting/feeding/buying for the pet — TD-037) — part of the timeline
  /// Sentry attaches to whatever error is captured next, even when the flow
  /// itself succeeds. No-op when [init] never activated Sentry, same as
  /// [captureException].
  static void addBreadcrumb(
    String message, {
    required String category,
    Map<String, dynamic>? data,
  }) {
    if (!_initialized) return;

    unawaited(
      Sentry.addBreadcrumb(
        Breadcrumb(message: message, category: category, data: data, level: SentryLevel.info),
      ),
    );
  }
}
