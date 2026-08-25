import 'package:flutter_bloc/flutter_bloc.dart';
import '../../data/datasources/local/auth_local_datasource.dart';
import '../../services/socket_service.dart';
import 'household_cubit.dart';
import 'pet_cubit.dart';
import 'shopping_cubit.dart';
import 'task_cubit.dart';
import 'timeline_cubit.dart';

/// Bridges the Socket.io connection to the feature cubits: it connects using
/// the stored token, joins the active household room, and forwards realtime
/// events to the Task, Shopping, Household, and Pet cubits.
class SocketCubit extends Cubit<bool> {
  final SocketService _socket;
  final AuthLocalDataSource _local;
  final TaskCubit _taskCubit;
  final ShoppingCubit _shoppingCubit;
  final HouseholdCubit _householdCubit;
  final PetCubit _petCubit;
  /// Optional so a test that only cares about task/shopping events does not
  /// have to build a timeline it never asserts on.
  final TimelineCubit? _timelineCubit;

  bool _listenersBound = false;

  SocketCubit(
    this._socket,
    this._local,
    this._taskCubit,
    this._shoppingCubit,
    this._householdCubit,
    this._petCubit, {
    TimelineCubit? timeline,
  })  : _timelineCubit = timeline,
        super(false);

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

    // Both, deliberately: TaskCubit keeps its status buckets, the timeline
    // keeps its own normalized map. Feeding one from the other would make the
    // timeline's correctness depend on bucket bookkeeping, which is exactly
    // the coupling TD-064 removes.
    _socket.onTaskUpdated((event, data) {
      _taskCubit.applyRealtime(event, data);
      _timelineCubit?.applyRealtime(event, data);
    });
    _socket.onShoppingUpdated(_shoppingCubit.applyRealtime);
    _socket.onHouseholdUpdated(_householdCubit.applyRealtime);
    // A batch of recurring occurrences was generated elsewhere; reload tasks.
    _socket.onTasksBatchCreated((_) {
      _taskCubit.refresh();
      _timelineCubit?.refresh();
    });
    // PDR-001 A4: any pet/adoption/economy change elsewhere reloads the pet.
    _socket.onPetUpdated(_petCubit.applyRealtime);
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
