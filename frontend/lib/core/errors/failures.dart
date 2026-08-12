/// Base failure surfaced to the presentation layer.
class Failure implements Exception {
  final String message;
  const Failure(this.message);

  @override
  String toString() => message;
}

/// Network / server error carrying an optional HTTP status code.
class ServerFailure extends Failure {
  final int? statusCode;
  const ServerFailure(super.message, {this.statusCode});
}

/// The request never reached the server at all — no connection, DNS failure,
/// or timeout before a response arrived. Distinct from [ServerFailure]: a
/// repository treats this (and a 5xx [ServerFailure]) as "the device or
/// backend is unreachable right now", worth falling back to cache / queuing
/// for later, whereas an ordinary 4xx [ServerFailure] is a real answer from
/// the server that must not be silently swallowed into an offline write.
class NetworkFailure extends Failure {
  const NetworkFailure(super.message);
}

/// Authentication failure (invalid credentials, expired session, etc.).
class AuthFailure extends Failure {
  const AuthFailure(super.message);
}

/// The server refused because an identical operation is already in flight
/// (HTTP 409 from Idempotency-Key handling). Never retry automatically:
/// the original request is still running and will succeed on its own.
class ConflictFailure extends Failure {
  const ConflictFailure(super.message);
}

/// Local cache / storage failure.
class CacheFailure extends Failure {
  const CacheFailure(super.message);
}

/// Whether [failure] means "the device or backend is unreachable right now"
/// — worth falling back to the cache on a read, or queuing on a write —
/// rather than a real answer from the server (bad input, not found, a
/// conflict) that must be surfaced to the user as-is.
bool isOfflineWorthy(Failure failure) {
  if (failure is NetworkFailure) return true;
  if (failure is ServerFailure) {
    final status = failure.statusCode;
    return status == null || status >= 500;
  }
  return false;
}
