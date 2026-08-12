import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

/// Reachability signal for the offline queue (TD-003).
///
/// `connectivity_plus` reports whether the device has an active network
/// interface (wifi/cellular/etc.), not whether the internet — or this app's
/// backend specifically — is actually reachable. That is the standard,
/// low-cost signal for "try syncing now"; a sync attempt that still fails
/// with a real network error simply stays queued for the next transition.
class ConnectivityService {
  ConnectivityService._internal();
  static final ConnectivityService _instance = ConnectivityService._internal();
  factory ConnectivityService() => _instance;

  final Connectivity _connectivity = Connectivity();

  StreamController<bool>? _controller;
  StreamSubscription<List<ConnectivityResult>>? _subscription;

  /// Emits the current online/offline state on every change.
  ///
  /// The underlying platform stream is only subscribed to while something is
  /// listening here — constructing this service never touches a platform
  /// channel, which matters for widget tests that never exercise
  /// connectivity at all.
  Stream<bool> get isOnline {
    _controller ??= StreamController<bool>.broadcast(
      onListen: () {
        // connectivity_plus's EventChannel sets up its platform subscription
        // from an `async` callback of its own, so a missing/unmocked
        // platform channel (no Flutter binding at all — a plain `flutter
        // test`) surfaces as an *unhandled Future error* on this zone, not a
        // synchronous throw a try/catch around .listen() could catch. A
        // nested guarded zone is what actually intercepts it, so a cubit
        // built without a fake ConnectivityService stays constructible in a
        // headless test; production callers never see a difference.
        runZonedGuarded(() {
          _subscription = _connectivity.onConnectivityChanged.listen(
            (results) => _controller?.add(_isConnected(results)),
            onError: (_) {},
          );
        }, (_, __) {});
      },
      onCancel: () {
        // Same rationale as onListen above: cancelling can just as easily
        // resolve to an unhandled Future error when there was never a real
        // platform subscription to begin with.
        runZonedGuarded(() {
          _subscription?.cancel();
        }, (_, __) {});
        _subscription = null;
      },
    );
    return _controller!.stream;
  }

  /// Used on the hot path of every create/update/complete/delete to decide
  /// online-first vs. queue-immediately. If the platform channel itself is
  /// unavailable (plugin not registered, a plain `flutter test`), assume
  /// online rather than throw: the mutation's own network attempt still has
  /// a working isOfflineWorthy() fallback, whereas a thrown exception here
  /// would crash the mutation outright instead of degrading gracefully.
  Future<bool> checkConnectivity() async {
    try {
      final results = await _connectivity.checkConnectivity();
      return _isConnected(results);
    } catch (_) {
      return true;
    }
  }

  bool _isConnected(List<ConnectivityResult> results) =>
      results.any((r) => r != ConnectivityResult.none);
}
