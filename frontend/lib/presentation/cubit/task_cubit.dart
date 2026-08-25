import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';
import '../../core/errors/failures.dart';
import '../../data/models/task.dart';
import '../../data/models/task_adapter.dart';
import '../../data/repositories/task_repository.dart';
import '../../services/connectivity_service.dart';
import '../../services/notification_service.dart';
import '../../services/sentry_service.dart';
import 'timeline_cubit.dart' show TimelineSink;
import 'timeline_grouping.dart' show sortTasksForDisplay;

/// Shown once (via BlocListener) after a mutation the repository could only
/// perform optimistically, offline (TD-003).
const kOfflineNoticeMessage =
    'Guardado offline, se sincronizará cuando haya conexión';

/// Shown when a write could not be persisted to this device at all (TD-059).
///
/// Deliberately distinct from [kOfflineNoticeMessage]: "offline" means the
/// change is safely queued and will sync later, which is reassuring and
/// correct. This one means the opposite — the change did NOT survive — so
/// wording it like a network problem would repeat exactly the false promise
/// TD-059 exists to remove. Nothing here is retryable by us: a full disk is
/// the user's to fix.
const kLocalWriteErrorMessage =
    'No se pudo guardar en este dispositivo. Puede que no quede espacio.';

enum TaskStatusUi { initial, loading, loaded, error }

/// Which slice of the household's tasks a tab is showing.
///
/// Each value maps to a server-side query, not to a local `where`: filtering a
/// paginated list on the client shows only what happens to be loaded, which is
/// how "Completadas" used to look empty until the user had scrolled past every
/// pending task.
enum TaskFilter { all, pending, completed }

extension TaskFilterQuery on TaskFilter {
  /// The `?status=` value, or null for the unfiltered list.
  String? get statusParam {
    switch (this) {
      case TaskFilter.pending:
        return 'pending';
      case TaskFilter.completed:
        return 'completed';
      case TaskFilter.all:
        return null;
    }
  }

  /// Whether a task belongs in this slice — used to keep buckets consistent
  /// when a realtime event or a local mutation changes a task's status.
  bool matches(Task task) {
    switch (this) {
      case TaskFilter.all:
        return true;
      case TaskFilter.pending:
        return !task.isCompleted;
      case TaskFilter.completed:
        return task.isCompleted;
    }
  }
}

/// Independent pagination state for one filter.
///
/// Tabs must not share a cursor: advancing "Pendientes" would otherwise skip
/// rows in "Completadas", and one tab's spinner would appear in all three.
class TaskBucket extends Equatable {
  final List<Task> items;
  final String? nextCursor;
  final bool hasMore;
  final bool isLoadingMore;

  /// Server-side total for this filter, from its first page (later pages send
  /// null). Kept so the header can show "12 de 61", and nudged optimistically
  /// by local mutations so it does not go stale the instant the user acts.
  final int? total;

  /// Whether this bucket has ever completed a real fetch — including one that
  /// legitimately came back empty. Without this, "empty because never
  /// visited" and "empty because there is nothing completed" are
  /// indistinguishable, and setFilter cannot tell whether to refetch.
  final bool loaded;

  const TaskBucket({
    this.items = const [],
    this.nextCursor,
    this.hasMore = false,
    this.isLoadingMore = false,
    this.total,
    this.loaded = false,
  });

  TaskBucket copyWith({
    List<Task>? items,
    String? nextCursor,
    bool? hasMore,
    bool? isLoadingMore,
    int? total,
    bool? loaded,
  }) {
    return TaskBucket(
      items: items ?? this.items,
      // Explicitly nullable: reaching the last page must be able to clear it.
      nextCursor: nextCursor,
      hasMore: hasMore ?? this.hasMore,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      total: total ?? this.total,
      loaded: loaded ?? this.loaded,
    );
  }

  @override
  List<Object?> get props =>
      [items, nextCursor, hasMore, isLoadingMore, total, loaded];
}

class TaskState extends Equatable {
  final TaskStatusUi status;
  final String? error;

  /// The filter the visible tab is showing.
  final TaskFilter activeFilter;

  /// One independent pagination bucket per filter.
  final Map<TaskFilter, TaskBucket> buckets;

  /// True when the most recent [TaskCubit.load] could not reach the server
  /// and fell back to the Hive cache (TD-003). Persists across mutations —
  /// unlike [error], it is not cleared by every emit — until the next load
  /// either confirms connectivity or fails again offline.
  final bool isOffline;

  /// One-shot "saved offline" notice for a create/update/delete that could
  /// only be applied optimistically. Deliberately the ONLY field [copyWith]
  /// still assigns unconditionally (TD-056): every emit resets it to null
  /// unless explicitly re-passed, so a BlocListener only sees it exactly
  /// once, then calls [TaskCubit.clearOfflineNotice]. Every other nullable
  /// field below is sticky — set once, it survives unrelated emits until a
  /// call site explicitly clears it via its `clearX` [copyWith] parameter.
  final String? offlineNotice;

  /// True while [TaskCubit.syncPending] is replaying the offline queue —
  /// drives the spinner in the offline banner (TD-003).
  final bool isSyncing;


  /// One row per recurring series for the Recurrentes tab (TD-035): the
  /// current occurrence (pending if one exists, otherwise the most
  /// recently due completed one), sorted by next due date. Populated by
  /// [TaskCubit.loadRecurringTasks] — deliberately NOT derived from
  /// [allTasks] or any [buckets] entry, both of which are only ever
  /// partially paginated; see that method's doc comment.
  final List<Task> recurringTasks;
  final bool recurringLoading;
  final bool recurringLoaded;
  final String? recurringError;

  /// Soft-deleted tasks for the Papelera/trash view (TD-009), most recently
  /// deleted first. Populated by [TaskCubit.loadTrashTasks] — same
  /// walk-the-full-list-then-filter-client-side approach as [recurringTasks]
  /// (TD-035), deliberately not derived from [buckets]/[allTasks], which the
  /// backend never returns deleted rows into in the first place.
  final List<Task> trashTasks;
  final bool trashLoading;
  final bool trashLoaded;
  final String? trashError;

  /// Ids with a mutation in flight, waiting for the server to confirm or
  /// reject it (TD-007).
  ///
  /// Deliberately NOT `isSynced`, which means "queued offline, will be sent
  /// when there is a connection" — a very different thing to tell the user.
  /// Reusing it would paint the offline indicator during every online write
  /// and lie about the state for the ~200ms the round trip takes.
  ///
  /// Transient by design: never persisted to Hive, never restored on start.
  /// An app killed mid-flight must not resurrect an "in flight".
  final Set<String> pendingIds;

  const TaskState({
    this.status = TaskStatusUi.initial,
    this.error,
    this.activeFilter = TaskFilter.all,
    this.buckets = const {},
    this.isOffline = false,
    this.offlineNotice,
    this.isSyncing = false,
    this.recurringTasks = const [],
    this.recurringLoading = false,
    this.recurringLoaded = false,
    this.recurringError,
    this.trashTasks = const [],
    this.trashLoading = false,
    this.trashLoaded = false,
    this.trashError,
    this.pendingIds = const {},
  });

  /// Pagination state for [filter], empty if it has never been loaded.
  TaskBucket bucket(TaskFilter filter) => buckets[filter] ?? const TaskBucket();

  /// The active tab's bucket — what the tasks page renders.
  TaskBucket get active => bucket(activeFilter);

  List<Task> get tasks => active.items;
  String? get nextCursor => active.nextCursor;
  bool get hasMore => active.hasMore;
  bool get isLoadingMore => active.isLoadingMore;
  int? get total => active.total;

  /// Every task loaded under the unfiltered slice.
  ///
  /// Dashboard-style consumers (home, calendar) must read this rather than
  /// [tasks]: otherwise switching the tasks tab to "Completadas" would empty
  /// their views too.
  List<Task> get allTasks => bucket(TaskFilter.all).items;

  /// TD-056: every nullable field except [offlineNotice] is sticky — passing
  /// nothing preserves the current value (via `??`), and clearing one to
  /// null requires its dedicated `clearX` flag. Before this, [copyWith]
  /// assigned every nullable field unconditionally, so any emit that didn't
  /// happen to re-pass e.g. [recurringCursor] silently wiped it — 16 of the
  /// 18 emit sites in this file didn't. See TD-056 in docs/TECH_DEBT.md and
  /// the `clearError` pattern StatsCubit/HouseholdCubit/AuthCubit already
  /// used, which this replicates.
  TaskState copyWith({
    TaskStatusUi? status,
    String? error,
    bool clearError = false,
    TaskFilter? activeFilter,
    Map<TaskFilter, TaskBucket>? buckets,
    bool? isOffline,
    String? offlineNotice,
    bool? isSyncing,
    List<Task>? recurringTasks,
    bool? recurringLoading,
    bool? recurringLoaded,
    String? recurringError,
    bool clearRecurringError = false,
    List<Task>? trashTasks,
    bool? trashLoading,
    bool? trashLoaded,
    String? trashError,
    bool clearTrashError = false,
    Set<String>? pendingIds,
  }) {
    return TaskState(
      status: status ?? this.status,
      error: clearError ? null : (error ?? this.error),
      activeFilter: activeFilter ?? this.activeFilter,
      buckets: buckets ?? this.buckets,
      isOffline: isOffline ?? this.isOffline,
      // Deliberately unconditional — see the field's own doc comment.
      offlineNotice: offlineNotice,
      isSyncing: isSyncing ?? this.isSyncing,
      recurringTasks: recurringTasks ?? this.recurringTasks,
      recurringLoading: recurringLoading ?? this.recurringLoading,
      recurringLoaded: recurringLoaded ?? this.recurringLoaded,
      recurringError: clearRecurringError ? null : (recurringError ?? this.recurringError),
      trashTasks: trashTasks ?? this.trashTasks,
      trashLoading: trashLoading ?? this.trashLoading,
      trashLoaded: trashLoaded ?? this.trashLoaded,
      trashError: clearTrashError ? null : (trashError ?? this.trashError),
      pendingIds: pendingIds ?? this.pendingIds,
    );
  }

  @override
  List<Object?> get props => [
        status,
        error,
        activeFilter,
        buckets,
        isOffline,
        offlineNotice,
        isSyncing,
        recurringTasks,
        recurringLoading,
        recurringLoaded,
        recurringError,
        trashTasks,
        trashLoading,
        trashLoaded,
        trashError,
        pendingIds,
      ];
}

/// Manages the task list for the active household, including realtime sync.
class TaskCubit extends Cubit<TaskState> {
  final TaskRepository _repo;
  final NotificationService _notifications;
  final ConnectivityService _connectivity;

  String? _householdId;
  StreamSubscription<bool>? _connectivitySub;

  /// Last connectivity value seen, so the subscription can detect a
  /// false→true edge rather than firing on every emission (the stream may
  /// repeat `true` without ever having gone offline).
  bool _wasOnline = true;

  /// Where mutations are echoed so the timeline stays in step without a
  /// refetch per event (TD-064). Optional: a TaskCubit with no timeline
  /// attached behaves exactly as before, which is what every test that does
  /// not care about the timeline relies on.
  TimelineSink? timeline;

  TaskCubit(this._repo, this._notifications,
      {ConnectivityService? connectivity, this.timeline})
      : _connectivity = connectivity ?? ConnectivityService(),
        super(const TaskState()) {
    _connectivitySub = _connectivity.isOnline.listen((online) {
      if (online && !_wasOnline) {
        syncPending();
      }
      _wasOnline = online;
    });
  }

  @override
  Future<void> close() {
    _connectivitySub?.cancel();
    return super.close();
  }

  String? get householdId => _householdId;

  /// Drop every task, timeline/recurring/trash entry and pagination cursor
  /// and forget the active household — called on logout/session-expiry
  /// (TD-058) so the next login's first frame never renders the previous
  /// account's tasks while its own [load] is still in flight. The
  /// connectivity subscription set up in the constructor is left running
  /// (it is a cubit-lifetime resource torn down in [close], not per-session).
  void reset() {
    _householdId = null;
    emit(const TaskState());
  }

  /// Replay the queued offline operations, then refresh from the server if
  /// anything was actually applied — called automatically on reconnection,
  /// and available for a manual "retry sync" action in the UI.
  Future<void> syncPending() async {
    emit(state.copyWith(isSyncing: true));
    try {
      final processed = await _repo.syncPendingOperations();
      if (processed > 0 && _householdId != null) {
        await load(_householdId!, filter: state.activeFilter);
      }
    } finally {
      emit(state.copyWith(isSyncing: false));
    }
  }

  /// Consume the one-shot [TaskState.offlineNotice] after the UI has shown
  /// it, without disturbing anything else (F7 — this used to also silently
  /// clear [TaskState.recurringError]/[TaskState.trashError] via the same bug
  /// TD-056 fixed in [copyWith]).
  void clearOfflineNotice() {
    emit(state.copyWith());
  }

  Map<TaskFilter, TaskBucket> _withBucket(
      TaskFilter filter, TaskBucket bucket) {
    return {...state.buckets, filter: bucket};
  }

  /// Load the FIRST page of [filter], replacing that bucket and resetting its
  /// cursor. Other buckets are untouched.
  ///
  /// A null [filter] means the unfiltered list and sends no query param.
  Future<void> load(String householdId, {TaskFilter? filter}) async {
    _householdId = householdId;
    final target = filter ?? TaskFilter.all;

    emit(state.copyWith(
      status: TaskStatusUi.loading,
      activeFilter: target,
      clearError: true,
    ));

    try {
      final page = await _repo.list(householdId, status: target.statusParam);
      emit(state.copyWith(
        status: TaskStatusUi.loaded,
        isOffline: _repo.lastListWasFromCache,
        buckets: _withBucket(
          target,
          TaskBucket(
            items: _sorted(page.items),
            nextCursor: page.nextCursor,
            hasMore: page.hasMore,
            isLoadingMore: false,
            total: page.total,
            loaded: true,
          ),
        ),
      ));
    } on Failure catch (f) {
      emit(state.copyWith(status: TaskStatusUi.error, error: f.message));
    }
  }

  /// Switch tabs. Fetches only when [filter]'s bucket has never completed a
  /// real load — a tab that is already loaded, including one that is
  /// legitimately empty (e.g. no completed tasks yet), just becomes visible.
  Future<void> setFilter(TaskFilter? filter) async {
    final target = filter ?? TaskFilter.all;
    final alreadyLoaded = state.bucket(target).loaded;

    if (target == state.activeFilter) {
      if (alreadyLoaded) return;
    } else if (alreadyLoaded) {
      emit(state.copyWith(activeFilter: target));
      return;
    }

    if (_householdId == null) {
      emit(state.copyWith(activeFilter: target));
      return;
    }
    await load(_householdId!, filter: target);
  }

  Future<void> refresh() async {
    if (_householdId != null) {
      await load(_householdId!, filter: state.activeFilter);
    }
  }

  /// Append the next page of the ACTIVE filter. No-op when that bucket is
  /// exhausted or already fetching — the scroll listener fires on every pixel.
  Future<void> loadMore() async {
    if (_householdId == null) return;

    final filter = state.activeFilter;
    final current = state.bucket(filter);
    if (!current.hasMore ||
        current.isLoadingMore ||
        current.nextCursor == null) {
      return;
    }

    emit(state.copyWith(
      buckets: _withBucket(
        filter,
        current.copyWith(nextCursor: current.nextCursor, isLoadingMore: true),
      ),
    ));

    try {
      final page = await _repo.list(
        _householdId!,
        status: filter.statusParam,
        cursor: current.nextCursor,
      );
      emit(state.copyWith(
        status: TaskStatusUi.loaded,
        buckets: _withBucket(
          filter,
          current.copyWith(
            items: _sorted([...current.items, ...page.items]),
            nextCursor: page.nextCursor,
            hasMore: page.hasMore,
            isLoadingMore: false,
          ),
        ),
      ));
    } on Failure catch (f) {
      // Keep the pages already loaded; only surface the error.
      emit(state.copyWith(
        error: f.message,
        buckets: _withBucket(
          filter,
          current.copyWith(
              nextCursor: current.nextCursor, isLoadingMore: false),
        ),
      ));
    }
  }

  // TD-064 commit 4: loadTimeline/loadMoreTimeline are gone. The "Todas" tab
  // is TimelineCubit's now — keyset pagination that never revisits ground,
  // instead of the window-widening walk that re-fetched page one of an
  // ever-larger superset. TaskCubit keeps mutations and status buckets, and
  // echoes each mutation to [timeline].

  /// Ask the backend to generate any missed recurring occurrences, then reload
  /// if new tasks were created. Silent + non-critical: never surfaces errors.
  Future<void> catchUpRecurringTasks(String householdId) async {
    try {
      final data = await _repo.generateRecurringInstances(householdId);
      final generated = (data['generated'] as num?)?.toInt() ?? 0;
      if (generated > 0) {
        await load(householdId, filter: state.activeFilter);
      }
    } catch (_) {
      // Non-critical background task; ignore failures.
    }
  }

  /// Fetch every recurring task's current-occurrence representative for the
  /// Recurrentes tab (TD-035), sorted by next due date. Exhaustively drains
  /// the UNFILTERED task list (same status=null population [TaskFilter.all]'s
  /// bucket uses) rather than reading whatever page happens to already be
  /// cached — filtering a partially-loaded paginated list is exactly why this
  /// tab was removed the first time (see [TaskFilter]'s own doc comment).
  /// Deliberately does NOT use a status=pending/status=completed filtered
  /// fetch even though that would be cheaper: [TaskRepository.list] only
  /// caches a first page (`cursor == null`) as "this household's tasks" —
  /// caching a status-filtered first page here would silently evict the other
  /// statuses' entries from the offline cache (`CacheService.saveTasks`
  /// replaces, it does not merge). No new backend endpoint (TD-035's original
  /// proposal): the existing paginated list already has everything needed, it
  /// just has to be walked to completion instead of one page. An offline
  /// cache fallback returns everything in a single non-paginated page (see
  /// [TaskRepository.list]'s doc comment), so this loop still terminates in
  /// one iteration when there is no connectivity.
  Future<void> loadRecurringTasks(String householdId) async {
    _householdId = householdId;
    emit(state.copyWith(recurringLoading: true, clearRecurringError: true));
    try {
      final all = <Task>[];
      String? cursor;
      while (true) {
        final page = await _repo.list(householdId, cursor: cursor);
        all.addAll(page.items);
        if (!page.hasMore || page.nextCursor == null) break;
        cursor = page.nextCursor;
      }
      emit(state.copyWith(
        recurringLoading: false,
        recurringLoaded: true,
        recurringTasks: _representativeRecurringTasks(all),
      ));
    } on Failure catch (f) {
      emit(state.copyWith(recurringLoading: false, recurringError: f.message));
    }
  }

  /// Fetch every soft-deleted task for the Papelera/trash view (TD-009),
  /// most recently deleted first. Exhaustively drains the `includeDeleted`
  /// list (same reasoning as [loadRecurringTasks]: filtering a partially
  /// loaded paginated list would randomly miss deleted rows depending on
  /// where they happen to sort by status/dueDate) rather than adding a
  /// dedicated backend endpoint — `?includeDeleted=true` already returns
  /// everything needed, just mixed with active tasks.
  Future<void> loadTrashTasks(String householdId) async {
    _householdId = householdId;
    emit(state.copyWith(trashLoading: true, clearTrashError: true));
    try {
      final all = <Task>[];
      String? cursor;
      while (true) {
        final page = await _repo.list(householdId, cursor: cursor, includeDeleted: true);
        all.addAll(page.items);
        if (!page.hasMore || page.nextCursor == null) break;
        cursor = page.nextCursor;
      }
      final trashed = all.where((t) => t.isDeleted).toList()
        ..sort((a, b) {
          final ad = a.deletedAt;
          final bd = b.deletedAt;
          if (ad == null && bd == null) return 0;
          if (ad == null) return 1;
          if (bd == null) return -1;
          return bd.compareTo(ad); // most recently deleted first
        });
      emit(state.copyWith(trashLoading: false, trashLoaded: true, trashTasks: trashed));
    } on Failure catch (f) {
      emit(state.copyWith(trashLoading: false, trashError: f.message));
    }
  }

  /// Restore a soft-deleted task from the trash view. Drops it from
  /// [TaskState.trashTasks] and upserts the now-active task back into
  /// whichever buckets it belongs to (`_upsert` keys purely off status), so
  /// it reappears in the normal tabs immediately instead of waiting for a
  /// manual refresh.
  Future<void> restoreTask(String taskId) async {
    if (_householdId == null) return;
    try {
      final task = await _repo.restore(_householdId!, taskId);
      _upsert(task);
      emit(state.copyWith(
        trashTasks: state.trashTasks.where((t) => t.id != taskId).toList(),
      ));
    } on Failure catch (f) {
      emit(state.copyWith(trashError: f.message));
    }
  }

  /// "Vaciar papelera" (TD-048): hard-delete trash entries older than 30 days
  /// (the backend's default). Reloads [TaskState.trashTasks] from the server
  /// afterwards rather than guessing locally which rows were purged — the
  /// server is the only place that knows each row's exact age. Returns the
  /// purged count on success, or null on failure (with [TaskState.trashError]
  /// set — e.g. a non-admin caller sees the backend's 403).
  Future<int?> purgeTrash() async {
    if (_householdId == null) return null;
    try {
      final deleted = await _repo.purgeTrash(_householdId!);
      await loadTrashTasks(_householdId!);
      return deleted;
    } on Failure catch (f) {
      emit(state.copyWith(trashError: f.message));
      return null;
    }
  }

  /// Confirm an optimistic create: drop the temporary-id row and insert the
  /// server's, in ONE emission (TD-060).
  ///
  /// A create is the only mutation whose id changes on confirmation, so
  /// _confirmOptimistic cannot serve it: _upsert keys by id, and upserting an
  /// entity with a different id ADDS a second row instead of replacing the
  /// first. Emitting a remove and an upsert separately would leave a frame in
  /// which the row is gone and its replacement not yet there — a visible
  /// flicker on every create.
  ///
  /// [confirmed] is whatever the repository returned: the server's entity, or
  /// — when it fell back to the queue — the same write with a `local-` id and
  /// isSynced:false. Both are the same operation from here: an id swap.
  void _confirmCreate(String tempId, Task confirmed, {String? offlineNotice}) {
    // One call, not remove+upsert: the timeline models the id swap as a single
    // operation so the intermediate state with both rows is unrepresentable.
    timeline?.replace(tempId, confirmed);
    _rollbackSnapshots.remove(tempId);
    _optimisticApplied.remove(tempId);

    // Compose both changes onto one starting state, then emit once.
    final withoutTemp = state.copyWith(
      buckets: _bucketsAfterRemove(state, tempId),
      pendingIds: state.pendingIds.difference({tempId}),
    );
    emit(withoutTemp.copyWith(
      status: TaskStatusUi.loaded,
      buckets: _bucketsAfterUpsert(withoutTemp, confirmed),
      offlineNotice: offlineNotice,
    ));
  }

  Future<Task?> createTask(Map<String, dynamic> payload) async {
    if (_householdId == null) return null;

    // Optimistic row with a temporary id (TD-060). The prefix is `pending-`,
    // never `local-`: that one already means "created offline and queued" to
    // syncPendingOperations, and an in-flight online create is not queued —
    // no PendingOperation backs it. Reusing the prefix would make the queue
    // believe it had work nobody gave it.
    final tempId = 'pending-${_uuid.v4()}';
    _applyOptimistic(
      mergeTaskPayload(
        base: null,
        id: tempId,
        householdId: _householdId!,
        payload: payload,
        isSynced: true,
      ),
      previous: null,
    );

    try {
      final task = await _repo.create(_householdId!, payload);
      _confirmCreate(tempId, task,
          offlineNotice: task.isSynced ? null : kOfflineNoticeMessage);
      // Phase 3.3: schedule a local reminder if the task has a due date.
      await _notifications.scheduleTaskReminder(task);
      // PDR-004: independent "starts in 30 min" reminder if the task has a
      // startsAt — no-op otherwise, and never set on a recurring task (the
      // backend already strips startsAt/endsAt from one).
      await _notifications.scheduleTaskStartReminder(task);
      return task;
    } on Failure catch (f) {
      _rollbackOptimistic(tempId, errorMessage: f.message);
      return null;
    } catch (_) {
      // Not a Failure: the repository could not persist the write
      // locally (TD-059). Caught here or it would escape the cubit
      // entirely and leave the UI with no feedback at all.
      _rollbackOptimistic(tempId, errorMessage: kLocalWriteErrorMessage);
      return null;
    }
  }

  Future<void> updateTask(String taskId, Map<String, dynamic> payload) async {
    if (_householdId == null) return;

    final previous = _findById(taskId);
    if (previous != null) {
      _applyOptimistic(
        mergeTaskPayload(
          base: previous,
          id: taskId,
          householdId: _householdId!,
          payload: payload,
          isSynced: previous.isSynced,
        ),
        previous: previous,
      );
    }

    try {
      final task = await _repo.update(_householdId!, taskId, payload);
      _confirmOptimistic(taskId, task,
          offlineNotice: task.isSynced ? null : kOfflineNoticeMessage);
      // Reminders are scheduled only on confirmation, never optimistically:
      // they book real OS notifications, so a rollback would have to cancel
      // them again. A 200ms delay on a reminder due in hours is invisible.
      await _notifications.scheduleTaskReminder(task);
      await _notifications.scheduleTaskStartReminder(task);
    } on Failure catch (f) {
      _rollbackOptimistic(taskId, errorMessage: f.message);
    } catch (_) {
      // Not a Failure: the repository could not persist the write
      // locally (TD-059). Caught here or it would escape the cubit
      // entirely and leave the UI with no feedback at all.
      _rollbackOptimistic(taskId, errorMessage: kLocalWriteErrorMessage);
    }
  }

  /// Mark a task complete, applied to the UI immediately (TD-007).
  ///
  /// The row moves to the Completadas bucket, the counters adjust and the
  /// timeline recomputes before the request is even sent — completing is the
  /// most frequent action in the app and the one where a round-trip's delay
  /// is most obvious.
  ///
  /// The server's answer then replaces the optimistic value, because it
  /// carries fields only it knows (a populated `completedBy`, the real
  /// `completedAt`). A rejection restores the previous value unless the task
  /// changed meanwhile — see [_rollbackOptimistic].
  Future<void> completeTask(String taskId) async {
    if (_householdId == null) return;

    final previous = _findById(taskId);
    if (previous != null) {
      _applyOptimistic(
        mergeTaskPayload(
          base: previous,
          id: taskId,
          householdId: _householdId!,
          payload: {
            'status': 'completed',
            'completedAt': DateTime.now().toUtc().toIso8601String(),
          },
          // Unchanged: an in-flight online write is not queued offline. If the
          // repository ends up falling back to the queue, the entity it
          // returns carries isSynced:false and _confirmOptimistic applies it.
          isSynced: previous.isSynced,
        ),
        previous: previous,
      );
    }

    try {
      final task = await _repo.complete(_householdId!, taskId);
      SentryService.addBreadcrumb(
        'Task completed',
        category: 'task',
        data: {'householdId': _householdId, 'synced': task.isSynced},
      );
      // Covers both outcomes the repository treats as success: confirmed by
      // the server (isSynced true), or fell back to the offline queue
      // (isSynced false). Neither is a rejection, so neither rolls back.
      _confirmOptimistic(taskId, task,
          offlineNotice: task.isSynced ? null : kOfflineNoticeMessage);
      await _notifications.cancelTaskReminder(taskId);
      await _notifications.cancelTaskStartReminder(taskId);
    } on Failure catch (f) {
      _rollbackOptimistic(taskId, errorMessage: f.message);
    } catch (_) {
      // Not a Failure: the repository could not persist the write
      // locally (TD-059). Caught here or it would escape the cubit
      // entirely and leave the UI with no feedback at all.
      _rollbackOptimistic(taskId, errorMessage: kLocalWriteErrorMessage);
    }
  }

  /// Online, the repository deletes for real and returns null — remove the
  /// row. Offline, it returns the task marked `isDeleted: true` — keep it
  /// upserted (struck through by the tile) rather than removing it, so the
  /// user can see the delete is queued, not lost.
  Future<void> deleteTask(String taskId) async {
    if (_householdId == null) return;

    // Optimistic removal: the row goes now. On rejection it comes back, which
    // is visually abrupt, so the error message names the task (see below) —
    // otherwise the reappearance reads as a glitch rather than a failure.
    final previous = _findById(taskId);
    if (previous != null) {
      _rollbackSnapshots[taskId] = previous;
      _optimisticApplied.remove(taskId);
      emit(state.copyWith(pendingIds: {...state.pendingIds, taskId}));
      _remove(taskId);
    }

    try {
      final marked = await _repo.delete(_householdId!, taskId);
      if (marked != null) {
        // Fell back to the offline queue: the row does NOT stay removed, it
        // comes back struck through so the user can see the delete is queued
        // rather than lost. This asymmetry predates TD-007 and must survive it.
        _confirmOptimistic(taskId, marked,
            offlineNotice: kOfflineNoticeMessage);
      } else {
        _rollbackSnapshots.remove(taskId);
        emit(state.copyWith(pendingIds: state.pendingIds.difference({taskId})));
        // Idempotent on purpose: the optimistic branch above only fires for
        // entities present in the paginated buckets, and the echo to
        // [timeline] has to happen whether or not the row was in one.
        // Removing again here costs nothing and keeps both surfaces correct.
        _remove(taskId);
      }
      await _notifications.cancelTaskReminder(taskId);
      await _notifications.cancelTaskStartReminder(taskId);
    } on Failure catch (f) {
      _rollbackDelete(taskId, previous, errorMessage: f.message);
    } catch (_) {
      // Not a Failure: the repository could not persist the write
      // locally (TD-059). Caught here or it would escape the cubit
      // entirely and leave the UI with no feedback at all.
      _rollbackDelete(taskId, previous, errorMessage: kLocalWriteErrorMessage);
    }
  }

  /// Put back a row an optimistic delete removed, unless something already
  /// took its place.
  ///
  /// The message names the task because the reinsertion is abrupt: a row
  /// reappearing without an explanation reads as a bug, not as a refusal.
  void _rollbackDelete(String taskId, Task? previous,
      {required String errorMessage}) {
    final stillGone = _findById(taskId) == null;
    _rollbackSnapshots.remove(taskId);

    final message = previous == null
        ? errorMessage
        : 'No se pudo borrar «${previous.title}»: $errorMessage';

    emit(state.copyWith(
      error: message,
      pendingIds: state.pendingIds.difference({taskId}),
    ));
    if (previous != null && stillGone) _upsert(previous);
  }

  /// Apply an incoming realtime socket event to local state.
  void applyRealtime(String event, dynamic data) {
    if (data is! Map) return;
    final map = Map<String, dynamic>.from(data);

    // Only react to events for the household currently loaded.
    if (_householdId != null &&
        map['householdId'] != null &&
        map['householdId'].toString() != _householdId) {
      return;
    }

    if (event == 'task:deleted') {
      _remove(map['id'].toString());
    } else {
      _upsert(Task.fromJson(map));
    }
  }

  /// Place [task] in every bucket whose filter it matches and drop it from the
  /// rest, so completing a task moves it from "Pendientes" to "Completadas"
  /// without a refetch. Each affected bucket's total is nudged by exactly the
  /// same net change — created moves 0→1 (+1 wherever it now belongs),
  /// completed moves pending→completed (−1/+1, "all" stays put since the task
  /// never left it), a plain edit that changes nothing about membership
  /// leaves every total untouched. The same math applies whether the call
  /// came from a local mutation or a realtime event from another device, so
  /// header counts stay correct either way.
  /// Only used to mint the temporary id of an optimistic create (TD-060).
  static const _uuid = Uuid();

  // ---- Optimistic mutation overlay (TD-007) ----
  //
  // Deliberate duplicate of ShoppingCubit's overlay: the two cubits share no
  // base class and their states differ in ways that matter here (TaskState
  // preserves `error` across emits, ShoppingState clears it, which flips the
  // emit order in rollback). KEEP BOTH COPIES IN SYNC — a change to one almost
  // certainly belongs in the other. See docs/TD-007-DESIGN.md; extracting a
  // generic mixin is filed as a pending improvement in IMPROVEMENTS.md.

  /// The entity as it was BEFORE an in-flight mutation, keyed by id, so a
  /// rejection can put it back. Null value = it did not exist (a create).
  /// Private and not part of the state: nothing renders from it.
  final Map<String, Task?> _rollbackSnapshots = {};

  /// What we optimistically applied, kept to detect supersession later.
  final Map<String, Task> _optimisticApplied = {};

  /// Apply [optimistic] to the UI now and mark its id in flight.
  ///
  /// [previous] is the value to restore on rejection, or null for a create.
  // NOTE on emit order, in all three helpers below: pendingIds is updated
  // FIRST and _upsert runs LAST. offlineNotice is the one field copyWith
  // resets unconditionally on every emit (TD-056), so an emit placed after
  // _upsert silently wipes the notice it just set — which is exactly how the
  // fell-back-to-offline case lost its "Guardado offline" message the first
  // time this was written the other way round.
  void _applyOptimistic(Task optimistic, {required Task? previous}) {
    _rollbackSnapshots[optimistic.id] = previous;
    _optimisticApplied[optimistic.id] = optimistic;
    emit(state.copyWith(pendingIds: {...state.pendingIds, optimistic.id}));
    _upsert(optimistic);
  }

  /// The server answered: apply what it actually returned and clear the
  /// in-flight marks. Also used for the fell-back-to-offline case, where the
  /// entity comes back with isSynced:false — that is a success, not a
  /// rejection, so it must never roll back.
  void _confirmOptimistic(String id, Task confirmed, {String? offlineNotice}) {
    _rollbackSnapshots.remove(id);
    _optimisticApplied.remove(id);
    emit(state.copyWith(pendingIds: state.pendingIds.difference({id})));
    _upsert(confirmed, offlineNotice: offlineNotice);
  }

  /// Whether the entity currently in state is still exactly what we applied.
  ///
  /// If anything replaced it meanwhile — another mutation, a socket event, a
  /// refresh — the mutation is superseded and MUST NOT be rolled back:
  /// restoring an older snapshot over a newer value destroys work the user
  /// did. Losing a rollback only leaves the UI ahead of the server until the
  /// next refresh, which is the cheaper mistake by far.
  bool _isSuperseded(String id) {
    final applied = _optimisticApplied[id];
    if (applied == null) return true;
    final current = _findById(id);
    return current != applied;
  }

  /// Undo an in-flight mutation after a rejection, unless superseded.
  void _rollbackOptimistic(String id, {required String errorMessage}) {
    final superseded = _isSuperseded(id);
    final previous = _rollbackSnapshots.remove(id);
    _optimisticApplied.remove(id);

    emit(state.copyWith(
      error: errorMessage,
      pendingIds: state.pendingIds.difference({id}),
    ));
    if (!superseded) {
      if (previous != null) {
        _upsert(previous);
      } else {
        _remove(id);
      }
    }
  }

  /// The task as it currently stands in any bucket, or null if absent.
  Task? _findById(String id) {
    for (final filter in TaskFilter.values) {
      for (final t in state.bucket(filter).items) {
        if (t.id == id) return t;
      }
    }
    return null;
  }

  /// Buckets after upserting [task] into [from], WITHOUT emitting.
  ///
  /// Split out from [_upsert] so several changes can be composed onto one
  /// starting state and emitted once (TD-060): confirming an optimistic
  /// create has to drop the temporary-id row and insert the server one
  /// together, or the list visibly flickers through a frame that holds
  /// neither.
  Map<TaskFilter, TaskBucket> _bucketsAfterUpsert(TaskState from, Task task) {
    final updated = <TaskFilter, TaskBucket>{};

    for (final filter in TaskFilter.values) {
      final bucket = from.bucket(filter);
      final items = List<Task>.from(bucket.items);
      final index = items.indexWhere((t) => t.id == task.id);
      final belongs = filter.matches(task);
      final existed = index >= 0;

      if (belongs) {
        if (existed) {
          items[index] = task;
        } else {
          items.add(task);
        }
      } else if (existed) {
        items.removeAt(index);
      } else {
        // Nothing to do for this bucket; keep it as-is to avoid needless rebuilds.
        updated[filter] = bucket;
        continue;
      }

      updated[filter] = bucket.copyWith(
        items: _sorted(items),
        nextCursor: bucket.nextCursor,
        total: _adjustedTotal(bucket,
            delta: belongs && !existed ? 1 : (!belongs && existed ? -1 : 0)),
      );
    }
    return updated;
  }

  void _upsert(Task task, {String? offlineNotice}) {
    timeline?.upsert(task);
    emit(state.copyWith(
      status: TaskStatusUi.loaded,
      buckets: _bucketsAfterUpsert(state, task),
      offlineNotice: offlineNotice,
    ));
  }

  /// Buckets after removing [id] from [from], WITHOUT emitting. See
  /// [_bucketsAfterUpsert].
  Map<TaskFilter, TaskBucket> _bucketsAfterRemove(TaskState from, String id) {
    final updated = <TaskFilter, TaskBucket>{};
    for (final filter in TaskFilter.values) {
      final bucket = from.bucket(filter);
      final existed = bucket.items.any((t) => t.id == id);
      updated[filter] = bucket.copyWith(
        items: bucket.items.where((t) => t.id != id).toList(),
        nextCursor: bucket.nextCursor,
        total: _adjustedTotal(bucket, delta: existed ? -1 : 0),
      );
    }
    return updated;
  }

  void _remove(String id) {
    timeline?.remove(id);
    emit(state.copyWith(buckets: _bucketsAfterRemove(state, id)));
  }



  /// [bucket.total] shifted by [delta], but only once the bucket has actually
  /// been fetched: a total of null means "unknown", and unknown ± 1 is still
  /// unknown, not 1. That bucket gets an accurate total the moment it is
  /// visited for real.
  int? _adjustedTotal(TaskBucket bucket, {required int delta}) {
    if (!bucket.loaded || bucket.total == null || delta == 0) {
      return bucket.total;
    }
    return bucket.total! + delta;
  }

  /// Pending first, then by due date ascending (nulls last).
  List<Task> _sorted(List<Task> tasks) => sortTasksForDisplay(tasks);
}




/// Grouped items for the timeline: dated tasks keyed by local midnight, plus
/// the undated ones the backend always includes alongside a from/to window.



/// Merge a newly-fetched page into the existing timeline buckets, keyed by
/// task id so a widened window's superset re-fetch overwrites rather than
/// duplicates already-bucketed items.

/// One row per recurring series (grouped by parentTaskId, or the task's own
/// id for a series' very first occurrence): the PENDING occurrence if one
/// exists (the "current" one — completing a recurring task immediately
/// regenerates the next pending instance, task.service.ts's
/// generateNextInstance, so this is the normal case), otherwise the most
/// recently due completed one, so a series briefly caught between completion
/// and catch-up still shows something instead of vanishing. Every generated
/// occurrence inherits isRecurring: true (not just the series template), so
/// grouping by series is required — a raw `isRecurring == true` filter would
/// list one row per historical occurrence instead of one per series.
List<Task> _representativeRecurringTasks(List<Task> tasks) {
  final bySeries = <String, Task>{};
  for (final task in tasks) {
    if (!task.isRecurring) continue;
    final seriesId = task.parentTaskId ?? task.id;
    final existing = bySeries[seriesId];
    if (existing == null || _isBetterRecurringRepresentative(task, existing)) {
      bySeries[seriesId] = task;
    }
  }
  return _sortByNextOccurrence(bySeries.values.toList());
}

bool _isBetterRecurringRepresentative(Task candidate, Task current) {
  if (candidate.isCompleted != current.isCompleted) {
    return !candidate.isCompleted; // prefer pending over completed
  }
  final cd = candidate.dueDate;
  final xd = current.dueDate;
  if (cd == null) return false;
  if (xd == null) return true;
  return cd.isAfter(xd); // among same-status candidates, the latest one
}

List<Task> _sortByNextOccurrence(List<Task> tasks) {
  final copy = List<Task>.from(tasks);
  copy.sort((a, b) {
    final ad = a.dueDate;
    final bd = b.dueDate;
    if (ad == null && bd == null) return 0;
    if (ad == null) return 1;
    if (bd == null) return -1;
    return ad.compareTo(bd);
  });
  return copy;
}
