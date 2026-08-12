import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/config/constants.dart';
import 'package:homesync/data/datasources/local/auth_local_datasource.dart';
import 'package:homesync/data/datasources/remote/api_service.dart';
import 'package:homesync/data/repositories/auth_repository.dart';
import 'package:homesync/presentation/cubit/auth_cubit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

/// Always answers with a bare success envelope — logout is the only call
/// under test here, and it does not care about the response body.
class _StubAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      jsonEncode({'success': true, 'data': <String, dynamic>{}}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      StorageKeys.accessToken: 'token',
      StorageKeys.refreshToken: 'refresh-token',
    });
  });

  group('AuthCubit.logout', () {
    test('wipes the offline cache so a later login starts clean (TD-003)', () async {
      final dio = Dio(BaseOptions(baseUrl: 'http://test.local/api'))
        ..httpClientAdapter = _StubAdapter();
      final local = AuthLocalDataSource();
      final repo = AuthRepository(ApiService(local, dio: dio), local);
      final cache = FakeCacheService();
      final cubit = AuthCubit(repo, cache: cache);

      await cubit.logout();

      expect(cache.clearAllCalls, 1);
      expect(cubit.state.status, AuthStatus.unauthenticated);
    });
  });
}
