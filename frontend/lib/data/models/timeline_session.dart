import 'package:hive/hive.dart';

/// Where a household's timeline walk got to, kept apart from the tasks it
/// walked over (TD-064).
///
/// The two used to be conflated, and that was the bug. A timeline's first page
/// arrives with a `from`/`to` window, and the repository treated it as a full
/// snapshot of the household — so `CacheService.saveTasks` evicted every
/// cached task outside that window. The offline view then showed one slice of
/// dates and nothing else, having silently thrown away the rest.
///
/// Separating them makes each hold what it actually is: tasks are normalized
/// by id and only ever upserted, while THIS records the position and freshness
/// of one pagination session. A page can now update the tasks it contains
/// without making any claim about the tasks it does not.
///
/// [cursor] is null once the walk is exhausted — meaning "no more pages",
/// which is different from a session that never started (no record at all).
/// [pagesLoaded] is not used by any decision; it is here because the question
/// asked when a timeline misbehaves is never just "where is the cursor" but
/// "how far did it get before it stopped", and a record that cannot answer
/// that sends you to the logs.
class TimelineSession {
  /// Lower bound of the walk. Also its identity: the backend rejects a cursor
  /// replayed against a different `from`, so a stored cursor is only valid
  /// paired with the `from` it was issued for.
  final DateTime from;

  /// Opaque cursor for the next DATED page, or null when exhausted.
  final String? cursor;

  /// Opaque cursor for the next UNDATED page, or null when exhausted.
  final String? undatedCursor;

  final bool hasMore;
  final bool undatedHasMore;
  final int pagesLoaded;

  /// When the first page of this session was fetched. Drives the "showing you
  /// something older than you might expect" state, which is deliberately a
  /// display decision and not a reason to discard content.
  final DateTime fetchedAt;

  const TimelineSession({
    required this.from,
    required this.fetchedAt,
    this.cursor,
    this.undatedCursor,
    this.hasMore = false,
    this.undatedHasMore = false,
    this.pagesLoaded = 0,
  });

  TimelineSession copyWith({
    String? cursor,
    String? undatedCursor,
    bool clearCursor = false,
    bool clearUndatedCursor = false,
    bool? hasMore,
    bool? undatedHasMore,
    int? pagesLoaded,
  }) =>
      TimelineSession(
        from: from,
        fetchedAt: fetchedAt,
        // Same sentinel contract as TaskState.copyWith (TD-056): a cursor
        // going null means "exhausted" and must overwrite, which an
        // `?? this.cursor` fallback would silently discard.
        cursor: clearCursor ? null : (cursor ?? this.cursor),
        undatedCursor: clearUndatedCursor ? null : (undatedCursor ?? this.undatedCursor),
        hasMore: hasMore ?? this.hasMore,
        undatedHasMore: undatedHasMore ?? this.undatedHasMore,
        pagesLoaded: pagesLoaded ?? this.pagesLoaded,
      );

  Map<String, dynamic> toJson() => {
        'from': from.toIso8601String(),
        'cursor': cursor,
        'undatedCursor': undatedCursor,
        'hasMore': hasMore,
        'undatedHasMore': undatedHasMore,
        'pagesLoaded': pagesLoaded,
        'fetchedAt': fetchedAt.toIso8601String(),
      };

  factory TimelineSession.fromJson(Map<String, dynamic> json) => TimelineSession(
        from: DateTime.parse(json['from'] as String),
        cursor: json['cursor'] as String?,
        undatedCursor: json['undatedCursor'] as String?,
        hasMore: json['hasMore'] as bool? ?? false,
        undatedHasMore: json['undatedHasMore'] as bool? ?? false,
        pagesLoaded: (json['pagesLoaded'] as num?)?.toInt() ?? 0,
        fetchedAt: DateTime.parse(json['fetchedAt'] as String),
      );
}

/// Hand-written for the same reason as the other adapters (see
/// task_adapter.dart): hive_generator is abandoned and incompatible with this
/// project's `analyzer >=8.0.0` test toolchain.
class TimelineSessionAdapter extends TypeAdapter<TimelineSession> {
  @override
  final int typeId = 5;

  @override
  TimelineSession read(BinaryReader reader) =>
      TimelineSession.fromJson(Map<String, dynamic>.from(reader.readMap()));

  @override
  void write(BinaryWriter writer, TimelineSession obj) => writer.writeMap(obj.toJson());
}
