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
        _subscription = _connectivity.onConnectivityChanged.listen((results) {
          _controller?.add(_isConnected(results));
        });
      },
      onCancel: () {
        _subscription?.cancel();
        _subscription = null;
      },
    );
    return _controller!.stream;
  }

  Future<bool> checkConnectivity() async {
    final results = await _connectivity.checkConnectivity();
    return _isConnected(results);
  }

  bool _isConnected(List<ConnectivityResult> results) =>
      results.any((r) => r != ConnectivityResult.none);
}
