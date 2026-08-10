/// One page of a cursor-paginated list endpoint (backend ADR-008).
///
/// The envelope is `{ items, nextCursor, hasMore, total }`. [total] is only
/// sent on the first page (no cursor); paged requests receive `null`, so the
/// caller must keep the first page's value rather than overwrite it.
class PaginatedResponse<T> {
  final List<T> items;
  final String? nextCursor;
  final bool hasMore;
  final int? total;

  const PaginatedResponse({
    required this.items,
    required this.nextCursor,
    required this.hasMore,
    required this.total,
  });

  /// An empty page, useful as a default before the first load.
  const PaginatedResponse.empty()
      : items = const [],
        nextCursor = null,
        hasMore = false,
        total = 0;

  /// Parse the envelope, delegating each element to [fromJsonT].
  factory PaginatedResponse.fromJson(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) fromJsonT,
  ) {
    final rawItems = (json['items'] as List<dynamic>?) ?? const [];
    return PaginatedResponse<T>(
      items: rawItems
          .map((e) => fromJsonT(Map<String, dynamic>.from(e as Map)))
          .toList(),
      nextCursor: json['nextCursor'] as String?,
      hasMore: json['hasMore'] as bool? ?? false,
      total: (json['total'] as num?)?.toInt(),
    );
  }
}
