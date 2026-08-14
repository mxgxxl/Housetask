import 'package:socket_io_client/socket_io_client.dart' as io;
import '../config/constants.dart';

/// Singleton wrapper around the Socket.io client.
///
/// Handles connecting with the JWT, joining household rooms, subscribing to
/// realtime events, and automatic reconnection with backoff.
class SocketService {
  SocketService._internal();
  static final SocketService _instance = SocketService._internal();
  factory SocketService() => _instance;

  io.Socket? _socket;

  bool get isConnected => _socket?.connected ?? false;

  /// Connect to the server, authenticating with [token]. If a socket already
  /// exists it is torn down first so the (possibly refreshed) token applies.
  void connect(String token) {
    if (_socket != null) {
      _socket!.dispose();
      _socket = null;
    }

    _socket = io.io(
      AppConfig.socketUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .setAuth({'token': token})
          .enableReconnection()
          .setReconnectionAttempts(1 << 30)
          .setReconnectionDelay(1000) // base delay
          .setReconnectionDelayMax(30000) // cap for backoff growth
          .build(),
    );

    _socket!.connect();
  }

  /// Join a household room so household-scoped events are received.
  void joinHousehold(String householdId) {
    _socket?.emit('household:join', householdId);
  }

  void leaveHousehold(String householdId) {
    _socket?.emit('household:leave', householdId);
  }

  // ---- Event subscriptions ----

  void onConnect(void Function() cb) => _socket?.onConnect((_) => cb());
  void onDisconnect(void Function() cb) => _socket?.onDisconnect((_) => cb());

  /// Subscribe to all task lifecycle events. The callback receives the event
  /// name plus its payload.
  void onTaskUpdated(void Function(String event, dynamic data) cb) {
    for (final e in ['task:created', 'task:updated', 'task:completed', 'task:deleted']) {
      _socket?.on(e, (data) => cb(e, data));
    }
  }

  /// Subscribe to all shopping lifecycle events.
  void onShoppingUpdated(void Function(String event, dynamic data) cb) {
    for (final e in [
      'shopping:created',
      'shopping:updated',
      'shopping:purchased',
      'shopping:deleted',
    ]) {
      _socket?.on(e, (data) => cb(e, data));
    }
  }

  /// Subscribe to household membership events.
  void onHouseholdUpdated(void Function(String event, dynamic data) cb) {
    for (final e in ['household:member_joined', 'household:member_left']) {
      _socket?.on(e, (data) => cb(e, data));
    }
  }

  /// Subscribe to bulk recurring-task generation (catch-up).
  void onTasksBatchCreated(void Function(dynamic data) cb) {
    _socket?.on('tasks:batch_created', cb);
  }

  /// Subscribe to all pet/adoption/economy lifecycle events (PDR-001 A4).
  void onPetUpdated(void Function(String event, dynamic data) cb) {
    for (final e in [
      'pet:adopt_requested',
      'pet:adopted',
      'pet:adopt_cancelled',
      'pet:updated',
    ]) {
      _socket?.on(e, (data) => cb(e, data));
    }
  }

  void off(String event) => _socket?.off(event);

  /// Disconnect and tear down the socket (used on logout).
  void disconnect() {
    _socket?.dispose();
    _socket = null;
  }
}
