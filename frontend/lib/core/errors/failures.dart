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

/// Authentication failure (invalid credentials, expired session, etc.).
class AuthFailure extends Failure {
  const AuthFailure(super.message);
}

/// Local cache / storage failure.
class CacheFailure extends Failure {
  const CacheFailure(super.message);
}
