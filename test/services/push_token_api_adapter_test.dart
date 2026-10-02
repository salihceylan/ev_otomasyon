import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/services/ev_cloud_api_service.dart';
import 'package:ev_otomasyon/services/push/push_coordinator.dart';
import 'package:ev_otomasyon/services/push_token_api_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/support.dart';

/// `CloudPushTokenApi`: kalıcı hatalar [PushRegistrationRejected], geçici hatalar olduğu gibi.
void main() {
  // Yer tutucu (gerçek olmayan) belirteç: 20..512 görünür ASCII.
  final token = 'fcm-token-${'x' * 40}';

  late MockApi api;
  late EvCloudApiService service;
  late CloudPushTokenApi adapter;

  setUp(() {
    api = MockApi();
    service = EvCloudApiService(baseUrl: 'https://api.test/api', client: api.client, clock: FakeClock())
      ..setAuthToken('access-1');
    adapter = CloudPushTokenApi(service);
  });

  tearDown(() => service.dispose());

  test('kayıt başarılıysa PUT /me/push-tokens gider', () async {
    api.on('PUT', '/api/v1/me/push-tokens', (r) => okResponse(<String, dynamic>{'registered': true}));
    await adapter.registerPushToken(token: token, platform: 'android', appVersion: '1.0.0+1');
    expect(api.requests.single.method, 'PUT');
    expect(api.requests.single.json, <String, dynamic>{
      'token': token,
      'platform': 'android',
      'app_version': '1.0.0+1',
    });
  });

  for (final status in <int>[400, 403, 404]) {
    test('kayıt HTTP $status: kalıcı red (PushRegistrationRejected), neden yalnızca durum kodu', () async {
      api.on('PUT', '/api/v1/me/push-tokens', (r) => errorResponse(status, 'ret', code: 'X'));
      await expectLater(
        adapter.registerPushToken(token: token, platform: 'android'),
        throwsA(
          isA<PushRegistrationRejected>()
              .having((e) => e.reason, 'reason', '$status')
              .having((e) => e.toString(), 'toString', isNot(contains(token))),
        ),
      );
    });
  }

  test('kayıt 401 (yenileme de reddedildi): kalıcı red', () async {
    api
      ..on('PUT', '/api/v1/me/push-tokens', (r) => errorResponse(401, 'Oturum', code: 'INVALID_TOKEN'))
      ..on('POST', '/api/v1/auth/refresh', (r) => errorResponse(401, 'Reddedildi', code: 'INVALID_TOKEN'));
    service.setRefreshToken('refresh-1');
    await expectLater(
      adapter.registerPushToken(token: token, platform: 'android'),
      throwsA(isA<PushRegistrationRejected>().having((e) => e.reason, 'reason', '401')),
    );
  });

  test('yerel doğrulama hatası (geçersiz belirteç) kalıcı red sayılır', () async {
    await expectLater(
      adapter.registerPushToken(token: 'kisa', platform: 'android'),
      throwsA(isA<PushRegistrationRejected>().having((e) => e.reason, 'reason', '400')),
    );
    expect(api.requests, isEmpty, reason: 'ağa gitmeden');
  });

  for (final status in <int>[429, 500, 502, 503]) {
    test('kayıt HTTP $status: geçici, ApiException olduğu gibi fırlar', () async {
      api.on('PUT', '/api/v1/me/push-tokens', (r) => errorResponse(status, 'Sunucu', code: 'X'));
      await expectLater(
        adapter.registerPushToken(token: token, platform: 'ios'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', status)),
      );
    });
  }

  test('ağ hatası (statusCode 0): geçici, ApiException olduğu gibi fırlar', () async {
    api.on('PUT', '/api/v1/me/push-tokens', (r) => throw http.ClientException('bağlantı koptu'));
    await expectLater(
      adapter.registerPushToken(token: token, platform: 'android'),
      throwsA(isA<ApiException>().having((e) => e.isNetwork, 'isNetwork', isTrue)),
    );
  });

  test('ApiException olmayan hata da olduğu gibi fırlar (sınıflandırılmaz)', () async {
    final failing = _FailingApi(StateError('beklenmeyen'));
    final a = CloudPushTokenApi(failing);
    await expectLater(a.registerPushToken(token: token, platform: 'android'), throwsA(isA<StateError>()));
    failing.dispose();
  });

  test('silme: DELETE gövdede belirteç; hata olduğu gibi fırlar', () async {
    api.on('DELETE', '/api/v1/me/push-tokens', (r) => okResponse(<String, dynamic>{'registered': false}));
    await adapter.unregisterPushToken(token);
    expect(api.requests.single.method, 'DELETE');
    expect(api.requests.single.json, <String, dynamic>{'token': token});

    api.on('DELETE', '/api/v1/me/push-tokens', (r) => errorResponse(403, 'Yetki', code: 'FORBIDDEN'));
    await expectLater(
      adapter.unregisterPushToken(token),
      throwsA(isA<ApiException>().having((e) => e.isForbidden, 'isForbidden', isTrue)),
    );
  });
}

/// Her push çağrısında verilen hatayı fırlatan bulut istemcisi.
class _FailingApi extends EvCloudApiService {
  _FailingApi(this.error) : super(baseUrl: 'https://api.test/api', client: MockApi().client, clock: FakeClock());

  final Object error;

  @override
  Future<void> registerPushToken({required String token, required String platform, String? appVersion}) async =>
      throw error;

  @override
  Future<void> unregisterPushToken(String token) async => throw error;
}
