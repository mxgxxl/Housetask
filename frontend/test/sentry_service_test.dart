import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/app.dart';
import 'package:homesync/services/sentry_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('SentryService without SENTRY_DSN', () {
    // No `--dart-define=SENTRY_DSN=...` is passed to this test run, so
    // String.fromEnvironment('SENTRY_DSN') resolves to '' here exactly as it
    // does in a debug build that omits the flag — this is not a stand-in for
    // the disabled path, it IS the disabled path.

    test('init() completes without throwing and without a DSN configured', () async {
      await expectLater(SentryService.init(), completes);
    });

    test('captureException() is a no-op that never throws', () async {
      await SentryService.init();

      expect(
        () => SentryService.captureException(
          Exception('simulated'),
          stackTrace: StackTrace.current,
          context: {'status': 500, 'path': '/api/whatever'},
        ),
        returnsNormally,
      );
    });

    test('addBreadcrumb() is a no-op that never throws (TD-037)', () async {
      await SentryService.init();

      expect(
        () => SentryService.addBreadcrumb(
          'User logged in',
          category: 'auth',
          data: {'householdId': 'h1'},
        ),
        returnsNormally,
      );
    });
  });

  testWidgets('the app builds and reaches the splash screen with Sentry inactive',
      (tester) async {
    // Native scaffolding (ios/Runner.xcodeproj, android/gradlew) is not
    // checked into this repo, so `flutter run` cannot be exercised here.
    // Pumping the real composition root — the same HomeSyncApp main.dart
    // mounts — is the closest available proxy for "the app starts without a
    // configured Sentry DSN and does not crash".
    await SentryService.init();

    await tester.pumpWidget(const HomeSyncApp());
    // One frame: enough to prove the widget tree builds and the first route
    // resolves. Settling further would wait on real network calls that have
    // no backend to answer them in this test environment.
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
