import 'package:hive/hive.dart';

/// The write this queued operation represents.
enum PendingOperationType { create, update, delete }

/// Which repository owns this operation.
enum PendingOperationEntity { task, shopping }

/// A write that could not reach the server and is queued for replay once
/// connectivity returns.
///
/// [entityId] is null for [PendingOperationType.create] — the server assigns
/// the real id — and set for update/delete, so the sync processor knows which
/// resource to act on. It may itself be a locally-generated id (the user
/// created something offline, then edited it before ever syncing); the
/// processor remaps it to the server id once the matching create operation
/// has been replayed, so ordering — not identity — is what makes this safe.
class PendingOperation {
  final String id;
  final PendingOperationType type;
  final PendingOperationEntity entity;
  final String householdId;
  final String? entityId;
  final Map<String, dynamic> payload;
  final DateTime timestamp;
  final int retryCount;

  /// Reused verbatim on every retry of a create, so a request that actually
  /// reached the server before a connection drop replays into the original
  /// resource instead of creating a duplicate (backend ADR-007).
  final String idempotencyKey;

  const PendingOperation({
    required this.id,
    required this.type,
    required this.entity,
    required this.householdId,
    this.entityId,
    required this.payload,
    required this.timestamp,
    this.retryCount = 0,
    required this.idempotencyKey,
  });

  PendingOperation copyWith({String? entityId, int? retryCount}) {
    return PendingOperation(
      id: id,
      type: type,
      entity: entity,
      householdId: householdId,
      entityId: entityId ?? this.entityId,
      payload: payload,
      timestamp: timestamp,
      retryCount: retryCount ?? this.retryCount,
      idempotencyKey: idempotencyKey,
    );
  }
}

/// Hand-written rather than generated: the classic hive_generator package is
/// abandoned at `analyzer <7.0.0`, which conflicts with the `analyzer >=8.0.0`
/// this project's test toolchain (bloc_test → test 1.31) already requires —
/// see TD (Sentry hardening's sibling entry for this round). TypeAdapter is a
/// small, stable, fully public Hive interface, so hand-writing it carries no
/// real risk; it just skips a broken dev-dependency.
class PendingOperationAdapter extends TypeAdapter<PendingOperation> {
  @override
  final int typeId = 3;

  @override
  PendingOperation read(BinaryReader reader) {
    final map = reader.readMap();
    return PendingOperation(
      id: map['id'] as String,
      type: PendingOperationType.values.byName(map['type'] as String),
      entity: PendingOperationEntity.values.byName(map['entity'] as String),
      householdId: map['householdId'] as String,
      entityId: map['entityId'] as String?,
      payload: Map<String, dynamic>.from(map['payload'] as Map),
      timestamp: DateTime.parse(map['timestamp'] as String),
      retryCount: map['retryCount'] as int,
      idempotencyKey: map['idempotencyKey'] as String,
    );
  }

  @override
  void write(BinaryWriter writer, PendingOperation obj) {
    writer.writeMap({
      'id': obj.id,
      'type': obj.type.name,
      'entity': obj.entity.name,
      'householdId': obj.householdId,
      'entityId': obj.entityId,
      'payload': obj.payload,
      'timestamp': obj.timestamp.toIso8601String(),
      'retryCount': obj.retryCount,
      'idempotencyKey': obj.idempotencyKey,
    });
  }
}
