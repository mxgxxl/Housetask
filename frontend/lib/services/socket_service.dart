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

  /// Personal-room P1 economy events (TD-066 F2).
  ///
  /// These arrive on `user_<id>`, not on the household room: a wallet, a
  /// budget and a streak are personal (PDR-012/PDR-017), and broadcasting
  /// them to the household would hand every housemate everyone else's
  /// balance. The client does not join that room — the server puts every
  /// socket in it at handshake — so subscribing is all there is to do.
  void onEconomyP1Updated(void Function(String event, dynamic data) cb) {
    for (final e in economyP1Events) {
      _socket?.on(e, (data) => cb(e, data));
    }
  }

  /// The personal-room event names, in CLAUDE.md's documented order.
  ///
  /// Exposed so a test can assert the wiring covers exactly this set rather
  /// than re-typing eleven strings that would drift from the ones subscribed.
  static const List<String> economyP1Events = [
    'economy:reward',
    'economy:budget_updated',
    'economy:streak_updated',
    'economy:ice_consumed',
    'economy:ice_refunded',
    'economy:streak_broken',
    'economy:streak_milestone',
    'economy:ice_purchased',
    'economy:level_up',
    'economy:milestone',
    // Added by TD-066 F3. It is a PERSONAL event — a refund lands in one
    // member's wallet — even though what triggers it is the household-wide
    // cancellation of a joint goal. F2 listed the ten events the personal
    // economy emitted on its own and left this one unsubscribed, so a
    // cancelled goal credited coins the app never showed until the next read.
    'economy:savings_refunded',
  ];

  /// Household-room P1 economy events (TD-066 F3).
  ///
  /// The counterpart of [onEconomyP1Updated] on the other room. These carry
  /// only what the whole household may see — pooled XP, shared levels and the
  /// joint goal with its explicitly public per-member breakdown (UX-P1-SPEC
  /// §4) — never a wallet, a budget or a streak.
  void onHouseholdEconomyUpdated(void Function(String event, dynamic data) cb) {
    for (final e in householdEconomyEvents) {
      _socket?.on(e, (data) => cb(e, data));
    }
  }

  /// The household-room event names, in CLAUDE.md's documented order.
  static const List<String> householdEconomyEvents = [
    'household:xp_updated',
    'household:level_up',
    'household:milestone',
    'household:savings_goal_created',
    'household:savings_contribution',
    'household:savings_goal_unlocked',
    'household:savings_goal_cancelled',
  ];

  void off(String event) => _socket?.off(event);

  /// Disconnect and tear down the socket (used on logout).
  void disconnect() {
    _socket?.dispose();
    _socket = null;
  }
}
