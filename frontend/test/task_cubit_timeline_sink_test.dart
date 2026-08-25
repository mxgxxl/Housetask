import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/core/errors/failures.dart';
import 'package:homesync/data/models/paginated_response.dart';
import 'package:homesync/data/models/task.dart';
import 'package:homesync/presentation/cubit/task_cubit.dart';
import 'package:homesync/presentation/cubit/timeline_cubit.dart';

import 'fakes.dart';

/// TaskCubit echoing its mutations into the timeline (TD-064 commit 4).
///
/// This file replaces the one that tested TaskCubit's own timeline. That
/// timeline is gone: the "Todas" tab belongs to TimelineCubit now, and
/// TaskCubit reaches it through the [TimelineSink] interface.
///
/// What is pinned here is only the ECHO — that a mutation reaches the sink,
/// with the right shape. Whether the sink then stores it without duplicating
/// is TimelineCubit's business, and its state is keyed by id, so the bug this
/// file was originally written for (an optimistic row surviving next to the
/// confirmed one, 073daea) is no longer expressible there.
class _RecordingSink implements TimelineSink {
  final List<String> calls = [];

  @override
  void upsert(Task task) => calls.add('upsert:${task.id}');

  @override
  void replace(String temporaryId, Task confirmed) =>
      calls.add('replace:$temporaryId->${confirmed.id}');

  @override
  void remove(String id) => calls.add('remove:$id');
}

void main() {
  FakeTaskRepository repoWith(List<Task> seed) => FakeTaskRepository(pages: [
        PaginatedResponse<Task>(
          items: seed,
          nextCursor: null,
          hasMore: false,
          total: seed.length,
        ),
      ]);

  test('a create echoes the optimistic row, then the id swap', () async {
    final sink = _RecordingSink();
    final repo = repoWith([]);
    final cubit = TaskCubit(repo, FakeNotificationService(), timeline: sink);
    await cubit.load('h1');
    sink.calls.clear();

    await cubit.createTask({'title': 'Nueva'});

    // The optimistic row first (instant feedback), then ONE replace — not a
    // remove plus an upsert, which is what let the two rows coexist before.
    expect(sink.calls.first, startsWith('upsert:pending-'));
    expect(sink.calls.last, matches(RegExp(r'^replace:pending-.*->created$')));
    expect(sink.calls.where((c) => c.startsWith('replace:')), hasLength(1));
  });

  test('a create that falls back to the queue still echoes a single replace',
      () async {
    final sink = _RecordingSink();
    final repo = FakeTaskRepository(
      pages: const [PaginatedResponse<Task>.empty()],
      returnsUnsynced: true,
    );
    final cubit = TaskCubit(repo, FakeNotificationService(), timeline: sink);
    await cubit.load('h1');
    sink.calls.clear();

    await cubit.createTask({'title': 'Offline'});

    expect(sink.calls.where((c) => c.startsWith('replace:')), hasLength(1));
  });

  test('a rejected create echoes a remove so the optimistic row disappears',
      () async {
    final sink = _RecordingSink();
    final repo = FakeTaskRepository(
      pages: const [PaginatedResponse<Task>.empty()],
      failCreateWith: const ServerFailure('rechazado'),
    );
    final cubit = TaskCubit(repo, FakeNotificationService(), timeline: sink);
    await cubit.load('h1');
    sink.calls.clear();

    await cubit.createTask({'title': 'Fallará'});

    expect(sink.calls.first, startsWith('upsert:pending-'));
    expect(sink.calls.last, startsWith('remove:pending-'));
  });

  test('a delete echoes a remove', () async {
    final sink = _RecordingSink();
    final repo = repoWith([buildTask('t1')]);
    final cubit = TaskCubit(repo, FakeNotificationService(), timeline: sink);
    await cubit.load('h1');
    sink.calls.clear();

    await cubit.deleteTask('t1');

    expect(sink.calls, contains('remove:t1'));
  });

  test('a TaskCubit with no timeline attached behaves exactly as before',
      () async {
    // The sink is optional on purpose: every pre-existing TaskCubit test
    // constructs one without it, and none of them should have had to change.
    final repo = repoWith([]);
    final cubit = TaskCubit(repo, FakeNotificationService());

    await cubit.load('h1');
    final created = await cubit.createTask({'title': 'Sin timeline'});

    expect(created, isNotNull);
    expect(cubit.state.error, isNull);
  });
}
