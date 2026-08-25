import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/data/models/paginated_response.dart';
import 'package:homesync/data/models/task.dart';
import 'package:homesync/presentation/cubit/task_cubit.dart';

import 'fakes.dart';

/// The optimistic create's id swap, seen from the TIMELINE.
///
/// `_confirmCreate` replaces the temporary `pending-<uuid>` row with the
/// entity the server returned. It did that for the buckets — `_bucketsAfterRemove`
/// then `_bucketsAfterUpsert` — but only UPSERTED into the timeline, never
/// removing the temporary id from it. So the "Todas" tab (PDR-003) kept both
/// rows: the optimistic one and its confirmed replacement, permanently, until
/// the tab was reloaded.
///
/// Distinct from the limitation TD-060 accepted. That one is the backend
/// echoing `task:created` back to its own author, is transient, and resolves
/// itself on confirm. This one survives the confirm, happens with the socket
/// disconnected, and leaves a row carrying an id the server never issued — so
/// acting on it targets a task that does not exist.
///
/// These tests exist because the TD-060 suite never loaded a timeline: with
/// `timelineWindowFrom/To` null every timeline helper is a no-op, which made
/// the whole defect invisible to it.
void main() {
  /// A repository whose timeline page is empty, so the only rows the timeline
  /// ever holds are the ones the create under test puts there.
  FakeTaskRepository repoWithEmptyTimeline({bool returnsUnsynced = false}) =>
      FakeTaskRepository(
        pages: const [PaginatedResponse<Task>.empty()],
        timelinePages: const [PaginatedResponse<Task>.empty()],
        returnsUnsynced: returnsUnsynced,
      );

  /// Every id currently rendered by the timeline, dated buckets and undated.
  List<String> timelineIds(TaskCubit cubit) => [
        ...cubit.state.timelineDays.values.expand((l) => l).map((t) => t.id),
        ...cubit.state.timelineUndated.map((t) => t.id),
      ];

  Future<TaskCubit> cubitWithTimelineLoaded(FakeTaskRepository repo) async {
    final cubit = TaskCubit(repo, FakeNotificationService());
    await cubit.load('h1');
    // Without this the window bounds stay null and every timeline helper
    // returns null — which is exactly why the defect went unnoticed.
    await cubit.loadTimeline('h1');
    return cubit;
  }

  test('an UNDATED create leaves one row in the timeline, not two', () async {
    // The commonest case, and the one that always reproduced: `withinWindow`
    // is `due == null || ...`, so an undated task always enters the timeline.
    final repo = repoWithEmptyTimeline();
    final cubit = await cubitWithTimelineLoaded(repo);

    await cubit.createTask({'title': 'Sin fecha'});

    expect(timelineIds(cubit), ['created']);
    expect(
      timelineIds(cubit).where((id) => id.startsWith('pending-')),
      isEmpty,
      reason: 'the temporary row must not survive its own replacement',
    );
  });

  test('a DATED create inside the window leaves one row in the timeline',
      () async {
    final repo = repoWithEmptyTimeline();
    final cubit = await cubitWithTimelineLoaded(repo);
    // loadTimeline's window is yesterday..today+6, so +2 days is inside it.
    final due = DateTime.now().add(const Duration(days: 2));

    await cubit.createTask({
      'title': 'Con fecha',
      'dueDate': due.toIso8601String(),
    });

    expect(timelineIds(cubit), ['created']);
  });

  test('a create that FALLS BACK to the offline queue leaves one row',
      () async {
    // Same `_confirmCreate` path: an unsynced entity with a different id is
    // still an id swap, and the queue case is the one where the stale row
    // would linger longest — there is no server round trip coming to tidy up.
    final repo = repoWithEmptyTimeline(returnsUnsynced: true);
    final cubit = await cubitWithTimelineLoaded(repo);

    await cubit.createTask({'title': 'Offline'});

    expect(timelineIds(cubit), ['created']);
    expect(cubit.state.timelineUndated.single.isSynced, isFalse);
  });

  test('the optimistic row IS shown in the timeline while in flight', () async {
    // Guards the fix from the lazy version of itself: never adding the
    // optimistic row to the timeline would also make these pass, at the cost
    // of the instant feedback TD-060 exists to give.
    final repo = repoWithEmptyTimeline();
    final cubit = await cubitWithTimelineLoaded(repo);

    final gate = Completer<void>();
    repo.createGate = gate.future;
    final inFlight = cubit.createTask({'title': 'En vuelo'});

    expect(timelineIds(cubit), hasLength(1));
    expect(timelineIds(cubit).single, startsWith('pending-'));

    gate.complete();
    await inFlight;

    expect(timelineIds(cubit), ['created']);
  });
}
