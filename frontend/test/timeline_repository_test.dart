import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:homesync/data/datasources/local/auth_local_datasource.dart';
import 'package:homesync/data/datasources/remote/api_service.dart';
import 'package:homesync/data/repositories/task_repository.dart';
import 'package:homesync/services/cache_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

/// TD-064, commit 2: the timeline's cache metadata is separate from the tasks.
///
/// The defect these pin is invisible on screen, which is how it lasted. The old
/// timeline load called `list()` with a from/to window and no status, which
/// took the "this is a full snapshot" branch and called `saveTasks` — a
/// whole-household REPLACE. Every task outside the window was evicted, so the
/// next offline read showed one slice of dates and nothing else. Online it
/// looked perfect, because the next fetch refilled it.
///
/// Exercises the real TaskRepository against a Hive-backed CacheService, the
/// same integration the bug lived in, scripting HTTP the way
/// task_repository_cache_test.dart does.
class _RecordingAdapter implements HttpClientAdapter {
  final List<ResponseBody Function(RequestOptions)> responses;
  final List<RequestOptions> requests = [];
  int _index = 0;

  _RecordingAdapter(this.responses);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final build = _index < responses.length ? responses[_index] : responses.last;
    _index++;
    return build(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Map<String, dynamic> body, int status) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

Map<String, dynamic> _page(
  List<Map<String, dynamic>> items, {
  String? nextCursor,
  bool hasMore = false,
}) =>
    {
      'success': true,
      'data': {
        'items': items,
        'nextCursor': nextCursor,
        'hasMore': hasMore,
        'total': items.length,
      },
    };

Map<String, dynamic> _taskJson(String id, {String? dueDate}) => {
      'id': id,
      'householdId': 'h1',
      'title': 'Tarea $id',
      'status': 'pending',
      'priority': 'medium',
      'category': 'other',
      'assignedTo': <dynamic>[],
      'isRecurring': false,
      'isDeleted': false,
      if (dueDate != null) 'dueDate': dueDate,
    };

TaskRepository _repoWith(_RecordingAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test.local/api'))
    ..httpClientAdapter = adapter;
  return TaskRepository(ApiService(AuthLocalDataSource(), dio: dio));
}

final _from = DateTime.utc(2026, 9, 1);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('homesync_td064_repo');
    await CacheService().init(testDirectory: tempDir.path);
  });

  tearDown(() async {
    await CacheService().clearAll();
  });

  tearDownAll(() async {
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('a timeline page never evacuates the cache', () {
    test('keeps tasks outside the window that a first page does not mention',
        () async {
      // The regression itself. Before TD-064 this same flow went through
      // saveTasks and left ONLY the windowed task behind.
      await CacheService().saveTasks('h1', [
        buildTask('lejos'),
        buildTask('otra'),
      ]);

      final adapter = _RecordingAdapter([
        (_) => _json(_page([_taskJson('dentro', dueDate: '2026-09-02T09:00:00.000Z')]), 200),
      ]);
      await _repoWith(adapter).timeline('h1', from: _from);

      final ids = CacheService().getTasks('h1').map((t) => t.id).toSet();
      expect(ids, {'lejos', 'otra', 'dentro'});
    });

    test('overwrites an id in place rather than duplicating it', () async {
      await CacheService().saveTasks('h1', [buildTask('t1')]);

      final adapter = _RecordingAdapter([
        (_) => _json(_page([_taskJson('t1', dueDate: '2026-09-02T09:00:00.000Z')]), 200),
      ]);
      await _repoWith(adapter).timeline('h1', from: _from);

      final cached = CacheService().getTasks('h1').where((t) => t.id == 't1').toList();
      expect(cached, hasLength(1));
      expect(cached.single.dueDate, isNotNull);
    });

    test('an undated page leaves dated tasks alone', () async {
      await CacheService().saveTasks('h1', [buildTask('fechada')]);

      final adapter = _RecordingAdapter([
        (_) => _json(_page([_taskJson('sin-fecha')]), 200),
      ]);
      await _repoWith(adapter).undatedTasks('h1');

      expect(
        CacheService().getTasks('h1').map((t) => t.id).toSet(),
        {'fechada', 'sin-fecha'},
      );
    });
  });

  group('the walk position is stored apart from the tasks', () {
    test('records cursor, hasMore and page count for the household', () async {
      final adapter = _RecordingAdapter([
        (_) => _json(_page([_taskJson('a')], nextCursor: 'c1', hasMore: true), 200),
      ]);
      await _repoWith(adapter).timeline('h1', from: _from);

      final session = CacheService().timelineSession('h1');
      expect(session, isNotNull);
      expect(session!.cursor, 'c1');
      expect(session.hasMore, isTrue);
      expect(session.pagesLoaded, 1);
      expect(session.from, _from);
    });

    test('an exhausted walk clears the cursor rather than keeping the old one',
        () async {
      // The TD-056 sentinel problem in its new home: a null nextCursor means
      // "no more pages" and must OVERWRITE, not read as "unspecified".
      final adapter = _RecordingAdapter([
        (_) => _json(_page([_taskJson('a')], nextCursor: 'c1', hasMore: true), 200),
        (_) => _json(_page([_taskJson('b')]), 200),
      ]);
      final repo = _repoWith(adapter);
      await repo.timeline('h1', from: _from);
      await repo.timeline('h1', from: _from, cursor: 'c1');

      final session = CacheService().timelineSession('h1');
      expect(session!.cursor, isNull);
      expect(session.hasMore, isFalse);
      expect(session.pagesLoaded, 2);
    });

    test('a first page starts a fresh session instead of resuming a stale one',
        () async {
      // A cursor is only valid paired with the `from` it was issued for — the
      // backend rejects it otherwise — so carrying one across a new walk would
      // only preserve something already invalid.
      final adapter = _RecordingAdapter([
        (_) => _json(_page([_taskJson('a')], nextCursor: 'viejo', hasMore: true), 200),
        (_) => _json(_page([_taskJson('b')]), 200),
      ]);
      final repo = _repoWith(adapter);
      await repo.timeline('h1', from: _from);
      await repo.timeline('h1', from: _from.add(const Duration(days: 7)));

      final session = CacheService().timelineSession('h1');
      expect(session!.from, _from.add(const Duration(days: 7)));
      expect(session.cursor, isNull);
      expect(session.pagesLoaded, 1);
    });

    test('undated pagination has its own cursor, independent of the dated one',
        () async {
      final adapter = _RecordingAdapter([
        (_) => _json(_page([_taskJson('a')], nextCursor: 'fechado', hasMore: true), 200),
        (_) => _json(_page([_taskJson('u')], nextCursor: 'sinfecha', hasMore: true), 200),
      ]);
      final repo = _repoWith(adapter);
      await repo.timeline('h1', from: _from);
      await repo.undatedTasks('h1');

      final session = CacheService().timelineSession('h1');
      expect(session!.cursor, 'fechado');
      expect(session.undatedCursor, 'sinfecha');
      expect(session.undatedHasMore, isTrue);
    });

    test('clearing the position leaves the tasks readable', () async {
      // The separation, stated as a test: a refresh or an invalidated cursor
      // discards WHERE we were, never WHAT we had.
      final adapter = _RecordingAdapter([
        (_) => _json(_page([_taskJson('a')], nextCursor: 'c1', hasMore: true), 200),
      ]);
      await _repoWith(adapter).timeline('h1', from: _from);

      await CacheService().clearTimelineSession('h1');

      expect(CacheService().timelineSession('h1'), isNull);
      expect(CacheService().getTasks('h1').map((t) => t.id), contains('a'));
    });

    test('clearAll drops the position with the tasks it pointed into', () async {
      final adapter = _RecordingAdapter([
        (_) => _json(_page([_taskJson('a')], nextCursor: 'c1', hasMore: true), 200),
      ]);
      await _repoWith(adapter).timeline('h1', from: _from);

      await CacheService().clearAll();

      expect(CacheService().timelineSession('h1'), isNull);
    });
  });

  group('requests', () {
    test('sends from, limit and cursor to the timeline endpoint', () async {
      final adapter = _RecordingAdapter([
        (_) => _json(_page([]), 200),
      ]);
      await _repoWith(adapter).timeline('h1', from: _from, cursor: 'c9', limit: 25);

      final req = adapter.requests.single;
      expect(req.path, '/households/h1/tasks/timeline');
      expect(req.queryParameters['from'], _from.toUtc().toIso8601String());
      expect(req.queryParameters['limit'], 25);
      expect(req.queryParameters['cursor'], 'c9');
    });

    test('omits cursor on a first page', () async {
      final adapter = _RecordingAdapter([
        (_) => _json(_page([]), 200),
      ]);
      await _repoWith(adapter).timeline('h1', from: _from);

      expect(adapter.requests.single.queryParameters.containsKey('cursor'), isFalse);
    });
  });

  group('offline fallback', () {
    test('serves cached dated tasks in timeline order, from `from` onwards',
        () async {
      await CacheService().saveTasks('h1', [
        buildTask('tarde', dueDate: DateTime.utc(2026, 9, 5)),
        buildTask('pronto', dueDate: DateTime.utc(2026, 9, 2)),
        buildTask('antes', dueDate: DateTime.utc(2026, 8, 1)),
        buildTask('sin-fecha'),
      ]);

      final adapter = _RecordingAdapter([
        (_) => _json({'success': false, 'error': 'nope'}, 503),
      ]);
      final repo = _repoWith(adapter);
      final page = await repo.timeline('h1', from: _from);

      expect(page.items.map((t) => t.id), ['pronto', 'tarde']);
      expect(repo.lastListWasFromCache, isTrue);
    });

    test('never advertises a remote page it cannot fetch', () async {
      // hasMore:true offline would make the UI promise a page nothing can
      // load, and retry forever against a network that is not there.
      await CacheService().saveTasks('h1', [
        buildTask('a', dueDate: DateTime.utc(2026, 9, 2)),
      ]);

      final adapter = _RecordingAdapter([
        (_) => _json({'success': false, 'error': 'nope'}, 503),
      ]);
      final page = await _repoWith(adapter).timeline('h1', from: _from);

      expect(page.hasMore, isFalse);
      expect(page.nextCursor, isNull);
    });

    test('serves cached undated tasks newest first', () async {
      await CacheService().saveTasks('h1', [
        buildTask('u1'),
        buildTask('u2'),
        buildTask('fechada', dueDate: DateTime.utc(2026, 9, 2)),
      ]);

      final adapter = _RecordingAdapter([
        (_) => _json({'success': false, 'error': 'nope'}, 503),
      ]);
      final page = await _repoWith(adapter).undatedTasks('h1');

      expect(page.items.map((t) => t.id), ['u2', 'u1']);
    });

    test('a real 4xx still propagates instead of falling back', () async {
      // Only network-shaped failures are offline-worthy; a 403 is a real
      // answer and hiding it behind stale cache would mask a permission bug.
      final adapter = _RecordingAdapter([
        (_) => _json({'success': false, 'error': 'forbidden'}, 403),
      ]);

      expect(
        () => _repoWith(adapter).timeline('h1', from: _from),
        throwsA(anything),
      );
    });
  });
}
