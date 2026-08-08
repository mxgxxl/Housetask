import 'package:flutter_bloc/flutter_bloc.dart';
import '../../data/datasources/local/auth_local_datasource.dart';
import '../../services/socket_service.dart';
import 'household_cubit.dart';
import 'shopping_cubit.dart';
import 'task_cubit.dart';

/// Bridges the Socket.io connection to the feature cubits: it connects using
/// the stored token, joins the active household room, and forwards realtime
/// events to the Task, Shopping, and Household cubits.
class SocketCubit extends Cubit<bool> {
  final SocketService _socket;
  final AuthLocalDataSource _local;
  final TaskCubit _taskCubit;
  final ShoppingCubit _shoppingCubit;
  final HouseholdCubit _householdCubit;

  bool _listenersBound = false;

  SocketCubit(
    this._socket,
    this._local,
    this._taskCubit,
    this._shoppingCubit,
    this._householdCubit,
  ) : super(false);

  /// Connect with the stored access token and start listening for events.
  Future<void> connectAndListen() async {
    final token = await _local.getAccessToken();
    if (token == null) return;

    _socket.connect(token);
    _bindListeners();

    // (Re)join the active household room whenever we (re)connect.
    _socket.onConnect(() {
      emit(true);
      final id = _householdCubit.currentId;
      if (id != null) _socket.joinHousehold(id);
    });
    _socket.onDisconnect(() => emit(false));
  }

  void _bindListeners() {
    if (_listenersBound) return;
    _listenersBound = true;

    _socket.onTaskUpdated(_taskCubit.applyRealtime);
    _socket.onShoppingUpdated(_shoppingCubit.applyRealtime);
    _socket.onHouseholdUpdated(_householdCubit.applyRealtime);
  }

  /// Join a household room (call after creating/joining a household).
  void joinHousehold(String householdId) {
    _socket.joinHousehold(householdId);
  }

  void disconnect() {
    _socket.disconnect();
    _listenersBound = false;
    emit(false);
  }
}
