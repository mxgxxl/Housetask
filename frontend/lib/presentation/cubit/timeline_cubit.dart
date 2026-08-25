import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/errors/failures.dart';
import '../../data/models/task.dart';
import '../../data/repositories/task_repository.dart';
import 'timeline_grouping.dart';

/// How far back the timeline starts, in local days. Mirrors the window
/// TaskCubit.loadTimeline used: yesterday onwards.
const int kTimelineLookbackDays = 1;

/// Page size for both reads. The undated page size is also the product
/// threshold: 50 arrive at once and anything beyond needs an explicit "ver
/// más" (see TimelineCubit.loadMoreUndated).
const int kTimelinePageSize = 50;

/// What TaskCubit needs from the timeline, and nothing more.
///
/// TaskCubit owns mutations; the timeline has to hear about them without
/// either class taking a dependency on the other's shape. An interface keeps
/// TaskCubit testable with no timeline at all — every existing TaskCubit test
/// passes null and is unaffected.
abstract class TimelineSink {
  void upsert(Task task);
  void replace(String temporaryId, Task confirmed);
  void remove(String id);
}

/// The timeline, stored NORMALIZED BY ID.
///
/// Not a list of days holding lists of tasks — a map keyed by task id, with
/// the day grouping derived on read. That choice is the point of this class:
/// the defect it replaces (a confirmed create sitting next to the optimistic
/// row it was supposed to replace) was possible only because the same task
/// could occupy two positions in a list-shaped state. A map cannot hold the
/// same id twice, so that whole class of bug stops being something to test
/// for and becomes something the data structure forbids.
///
/// [dated] and [undated] stay separate because the backend paginates them
/// separately (TD-064): a long backlog of undated tasks must not ride along
/// with every page of dated ones.
class TimelineState extends Equatable {
  final Map<String, Task> dated;
  final Map<String, Task> undated;

  /// Opaque keyset cursors. Null means "no more pages", which is different
  /// from a session that never started — see [hasMore]/[undatedHasMore].
  final String? cursor;
  final String? undatedCursor;
  final bool hasMore;
  final bool undatedHasMore;

  /// Lower bound of the walk, and part of its identity: the backend rejects a
  /// cursor replayed against a different `from`.
  final DateTime? from;

  final bool isLoadingInitial;
  final bool isLoadingMore;
  final bool isLoadingMoreUndated;
  final bool isRefreshing;

  /// The content on screen came from the local cache, so it may be behind the
  /// server. Deliberately not an error: stale content beats an empty screen.
  final bool isStale;

  final String? error;

  /// Monotonic, bumped on every load that starts a NEW walk (initial load,
  /// refresh, household change). A response tagged with an older generation is
  /// discarded rather than merged: without it, a slow first request answering
  /// after a refresh would resurrect the state the refresh replaced.
  final int generation;

  const TimelineState({
    this.dated = const {},
    this.undated = const {},
    this.cursor,
    this.undatedCursor,
    this.hasMore = false,
    this.undatedHasMore = false,
    this.from,
    this.isLoadingInitial = false,
    this.isLoadingMore = false,
    this.isLoadingMoreUndated = false,
    this.isRefreshing = false,
    this.isStale = false,
    this.error,
    this.generation = 0,
  });

  /// The dated tasks grouped by local day, built on read.
  ///
  /// Derived rather than stored so there is exactly one source of truth. A
  /// stored grouping would need updating alongside the map on every mutation,
  /// which is precisely the bookkeeping that went wrong before.
  TimelineGroups get groups => groupTasksByLocalDay(dated.values);

  /// Undated tasks in display order.
  List<Task> get undatedList => sortTasksForDisplay(undated.values.toList());

  bool get isEmpty => dated.isEmpty && undated.isEmpty;

  /// Nothing to show and nothing on the way — the real empty state, as opposed
  /// to "empty because the first page has not landed yet".
  bool get showEmptyState => isEmpty && !isLoadingInitial && error == null;

  TimelineState copyWith({
    Map<String, Task>? dated,
    Map<String, Task>? undated,
    String? cursor,
    String? undatedCursor,
    // Sentinels, same contract as TaskState.copyWith (TD-056): a cursor going
    // null means "exhausted" and MUST overwrite. `?? this.cursor` would read
    // that as "not specified" and keep walking a cursor the server is done
    // with.
    bool clearCursor = false,
    bool clearUndatedCursor = false,
    bool clearError = false,
    bool? hasMore,
    bool? undatedHasMore,
    DateTime? from,
    bool? isLoadingInitial,
    bool? isLoadingMore,
    bool? isLoadingMoreUndated,
    bool? isRefreshing,
    bool? isStale,
    String? error,
    int? generation,
  }) =>
      TimelineState(
        dated: dated ?? this.dated,
        undated: undated ?? this.undated,
        cursor: clearCursor ? null : (cursor ?? this.cursor),
        undatedCursor:
            clearUndatedCursor ? null : (undatedCursor ?? this.undatedCursor),
        hasMore: hasMore ?? this.hasMore,
        undatedHasMore: undatedHasMore ?? this.undatedHasMore,
        from: from ?? this.from,
        isLoadingInitial: isLoadingInitial ?? this.isLoadingInitial,
        isLoadingMore: isLoadingMore ?? this.isLoadingMore,
        isLoadingMoreUndated: isLoadingMoreUndated ?? this.isLoadingMoreUndated,
        isRefreshing: isRefreshing ?? this.isRefreshing,
        isStale: isStale ?? this.isStale,
        error: clearError ? null : (error ?? this.error),
        generation: generation ?? this.generation,
      );

  @override
  List<Object?> get props => [
        dated,
        undated,
        cursor,
        undatedCursor,
        hasMore,
        undatedHasMore,
        from,
        isLoadingInitial,
        isLoadingMore,
        isLoadingMoreUndated,
        isRefreshing,
        isStale,
        error,
        generation,
      ];
}

/// The "Todas" timeline (PDR-003), on the keyset endpoints of TD-064.
///
/// Replaces TaskCubit's window-widening walk, which re-fetched page one of an
/// ever-growing window every time it ran out: correct on screen thanks to a
/// client-side merge, but the backend re-scanned everything already seen —
/// plus every undated task — before reaching new dates.
///
/// TaskCubit keeps owning mutations and its status buckets. It feeds this
/// class through [upsert]/[remove] instead of triggering refetches, so a
/// socket event or an optimistic write costs no HTTP call here.
class TimelineCubit extends Cubit<TimelineState> implements TimelineSink {
  final TaskRepository _repo;

  String? _householdId;

  TimelineCubit(this._repo) : super(const TimelineState());

  String? get householdId => _householdId;

  /// Start a new walk: first dated page and first undated page.
  ///
  /// Bumps [TimelineState.generation] so anything still in flight from a
  /// previous walk is ignored when it lands.
  Future<void> load(String householdId) async {
    _householdId = householdId;
    final from = startOfLocalDay(
      DateTime.now().subtract(const Duration(days: kTimelineLookbackDays)),
    );
    final generation = state.generation + 1;

    emit(state.copyWith(
      isLoadingInitial: true,
      clearError: true,
      generation: generation,
      from: from,
    ));

    await _fetchFirstPages(householdId, from, generation, isRefresh: false);
  }

  /// Pull-to-refresh: re-read the first pages WITHOUT clearing what is on
  /// screen.
  ///
  /// Emptying first would flash a blank list on every pull and, if the request
  /// then failed, would have destroyed readable content in exchange for
  /// nothing. The new generation is what makes this safe: the in-flight pages
  /// of the previous walk cannot merge back in.
  Future<void> refresh() async {
    final householdId = _householdId;
    if (householdId == null || state.isRefreshing) return;

    final from = startOfLocalDay(
      DateTime.now().subtract(const Duration(days: kTimelineLookbackDays)),
    );
    final generation = state.generation + 1;

    emit(state.copyWith(
      isRefreshing: true,
      clearError: true,
      generation: generation,
      from: from,
    ));

    await _fetchFirstPages(householdId, from, generation, isRefresh: true);
  }

  Future<void> _fetchFirstPages(
    String householdId,
    DateTime from,
    int generation, {
    required bool isRefresh,
  }) async {
    try {
      final dated = await _repo.timeline(householdId, from: from, limit: kTimelinePageSize);
      final fromCache = _repo.lastListWasFromCache;
      final undated = await _repo.undatedTasks(householdId, limit: kTimelinePageSize);

      if (_isStale(generation)) return;

      emit(state.copyWith(
        // Replaces rather than merges: this IS the first page of a new walk,
        // so anything not in it is either gone or beyond the page.
        dated: {for (final t in dated.items) t.id: t},
        undated: {for (final t in undated.items) t.id: t},
        cursor: dated.nextCursor,
        clearCursor: dated.nextCursor == null,
        undatedCursor: undated.nextCursor,
        clearUndatedCursor: undated.nextCursor == null,
        hasMore: dated.hasMore,
        undatedHasMore: undated.hasMore,
        isLoadingInitial: false,
        isRefreshing: false,
        isStale: fromCache || _repo.lastListWasFromCache,
        clearError: true,
      ));
    } on Failure catch (f) {
      if (_isStale(generation)) return;
      // A failed refresh keeps cursor and content: the user still has
      // something to read, and the walk can continue from where it was.
      emit(state.copyWith(
        isLoadingInitial: false,
        isRefreshing: false,
        error: f.message,
      ));
    }
  }

  /// Next page of DATED tasks. Called by the view's prefetch threshold.
  ///
  /// Coalesced three ways, because a fast scroll fires this repeatedly: an
  /// in-flight page, an exhausted walk, and a missing cursor each make it a
  /// no-op. Without that, one flick would queue several identical requests
  /// against the same cursor and merge the same page several times — harmless
  /// to the normalized state, wasteful against the 100-requests/15-min budget.
  Future<void> loadMore() async {
    final householdId = _householdId;
    final cursor = state.cursor;
    final from = state.from;
    if (householdId == null || from == null) return;
    if (state.isLoadingMore || !state.hasMore || cursor == null) return;

    final generation = state.generation;
    emit(state.copyWith(isLoadingMore: true));

    try {
      final page = await _repo.timeline(
        householdId,
        from: from,
        cursor: cursor,
        limit: kTimelinePageSize,
      );
      if (_isStale(generation)) return;

      emit(state.copyWith(
        dated: {...state.dated, for (final t in page.items) t.id: t},
        cursor: page.nextCursor,
        clearCursor: page.nextCursor == null,
        hasMore: page.hasMore,
        isLoadingMore: false,
      ));
    } on Failure catch (f) {
      if (_isStale(generation)) return;
      // Keeps the cursor: the page can be retried, and the content already
      // loaded stays on screen.
      emit(state.copyWith(isLoadingMore: false, error: f.message));
    }
  }

  /// Next page of UNDATED tasks — only ever called from an explicit "ver más".
  ///
  /// Deliberately NOT wired to the scroll prefetch, unlike [loadMore]. Dated
  /// tasks are an ordered stretch the user is walking through, so fetching
  /// ahead matches the intent. Undated tasks are a drawer: someone who never
  /// opens it should not pay for its size.
  Future<void> loadMoreUndated() async {
    final householdId = _householdId;
    final cursor = state.undatedCursor;
    if (householdId == null) return;
    if (state.isLoadingMoreUndated || !state.undatedHasMore || cursor == null) {
      return;
    }

    final generation = state.generation;
    emit(state.copyWith(isLoadingMoreUndated: true));

    try {
      final page = await _repo.undatedTasks(
        householdId,
        cursor: cursor,
        limit: kTimelinePageSize,
      );
      if (_isStale(generation)) return;

      emit(state.copyWith(
        undated: {...state.undated, for (final t in page.items) t.id: t},
        undatedCursor: page.nextCursor,
        clearUndatedCursor: page.nextCursor == null,
        undatedHasMore: page.hasMore,
        isLoadingMoreUndated: false,
      ));
    } on Failure catch (f) {
      if (_isStale(generation)) return;
      emit(state.copyWith(isLoadingMoreUndated: false, error: f.message));
    }
  }

  /// Place [task] in the timeline, or move it between the dated and undated
  /// halves if its due date changed.
  ///
  /// The only way a task enters this state outside a page load — used by
  /// TaskCubit for optimistic writes and by the socket for events from other
  /// devices. An upsert by id can never duplicate: replacing a row and adding
  /// one are the same operation here.
  @override
  void upsert(Task task) {
    if (state.from == null) return; // no walk started; nothing to keep in sync.

    final dated = Map<String, Task>.from(state.dated);
    final undated = Map<String, Task>.from(state.undated);
    // Remove from BOTH first: a task that just gained or lost its due date has
    // to leave the half it used to live in, or it shows up twice.
    dated.remove(task.id);
    undated.remove(task.id);

    if (task.dueDate == null) {
      undated[task.id] = task;
    } else if (!task.dueDate!.toLocal().isBefore(state.from!)) {
      dated[task.id] = task;
    }
    // A task dated BEFORE the window start belongs to neither: it is outside
    // the walk, and inventing a position for it would put a row on screen the
    // next refresh would silently drop.

    emit(state.copyWith(dated: dated, undated: undated));
  }

  /// Swap an optimistic row for its confirmed entity in one emit.
  ///
  /// The operation that used to be split across two structures and lost half
  /// of itself. Here it is a remove plus an upsert on the same map, so the
  /// intermediate state where both exist is not representable.
  @override
  void replace(String temporaryId, Task confirmed) {
    if (state.from == null) return;

    final dated = Map<String, Task>.from(state.dated)..remove(temporaryId);
    final undated = Map<String, Task>.from(state.undated)..remove(temporaryId);

    dated.remove(confirmed.id);
    undated.remove(confirmed.id);
    if (confirmed.dueDate == null) {
      undated[confirmed.id] = confirmed;
    } else if (!confirmed.dueDate!.toLocal().isBefore(state.from!)) {
      dated[confirmed.id] = confirmed;
    }

    emit(state.copyWith(dated: dated, undated: undated));
  }

  /// Drop [id] from the timeline. No-op if it was never there.
  @override
  void remove(String id) {
    if (!state.dated.containsKey(id) && !state.undated.containsKey(id)) return;
    emit(state.copyWith(
      dated: Map<String, Task>.from(state.dated)..remove(id),
      undated: Map<String, Task>.from(state.undated)..remove(id),
    ));
  }

  /// Apply a realtime socket event.
  ///
  /// Mirrors TaskCubit.applyRealtime's contract, including the household guard:
  /// an event for a household this cubit is not showing must not land here.
  void applyRealtime(String event, dynamic data) {
    if (data is! Map) return;
    final map = Map<String, dynamic>.from(data);

    if (_householdId != null &&
        map['householdId'] != null &&
        map['householdId'].toString() != _householdId) {
      return;
    }

    if (event == 'task:deleted') {
      remove(map['id'].toString());
    } else {
      upsert(Task.fromJson(map));
    }
  }

  /// Forget everything, e.g. on logout or when leaving a household.
  ///
  /// Bumps the generation as it goes: a request still in flight for the old
  /// household must not repopulate the timeline someone else is now looking at.
  void reset() {
    _householdId = null;
    emit(TimelineState(generation: state.generation + 1));
  }

  /// Whether [generation] has been superseded while a request was in flight.
  bool _isStale(int generation) => generation != state.generation;
}
