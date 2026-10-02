import 'dart:async';
import 'dart:io';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/services/ev_cloud_api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/support.dart';

const String kHome = '11111111-1111-4111-8111-111111111111';

void main() {
  late MockApi api;
  late FakeClock clock;
  late EvCloudApiService service;
  late List<SessionEndReason> expired;
  late List<String?> guestExpired;
  late List<String?> forbidden;
  late List<String> events;

  setUp(() {
    api = MockApi();
    clock = FakeClock();
    service = EvCloudApiService(baseUrl: 'https://api.test/api', client: api.client, clock: clock);
    expired = <SessionEndReason>[];
    guestExpired = <String?>[];
    forbidden = <String?>[];
    events = <String>[];
    service
      ..onSessionExpired = expired.add
      ..onGuestExpired = guestExpired.add
      ..onForbidden = forbidden.add;
  });

  tearDown(() => service.dispose());

  /// `/api/v1/auth/refresh` yolunu yapılandırır.
  void stubRefresh({String access = 'new-access', String refresh = 'new-refresh', int status = 200}) {
    api.on('POST', '/api/v1/auth/refresh', (r) {
      events.add('refresh');
      if (status != 200) return errorResponse(status, 'reddedildi', code: 'INVALID_TOKEN');
      return okResponse(<String, dynamic>{'access_token': access, 'refresh_token': refresh});
    });
  }

  group('kimlik ve başlıklar', () {
    test('Authorization Bearer eklenir; oturum yokken eklenmez', () async {
      api.on('GET', '/api/v1/homes', (r) => okResponse(<dynamic>[]));
      await service.fetchHomes();
      expect(api.requests.last.headers.containsKey('Authorization'), isFalse);
      service.setAuthToken('tok-1');
      await service.fetchHomes();
      expect(api.requests.last.headers['Authorization'], 'Bearer tok-1');
      expect(api.requests.last.headers['Content-Type'], contains('application/json'));
    });

    test('yönetici API anahtarı HİÇBİR istekte gönderilmez', () async {
      service.setAuthToken('jwt');
      api.on('GET', '/api/v1/admin/inventory', (r) => okResponse(<String, dynamic>{'items': <dynamic>[]}));
      api.on('PATCH', RegExp(r'/api/v1/admin/inventory/.+/status'), (r) => okResponse(<String, dynamic>{}));
      api.on('DELETE', RegExp(r'/api/v1/admin/inventory/.+'), (r) => okResponse(<String, dynamic>{}));
      await service.fetchDeviceInventory();
      await service.updateInventoryDeviceStatus('AHBU-S3-ABC123', 'SUSPENDED');
      await service.deleteInventoryDevice('AHBU-S3-ABC123');
      for (final r in api.requests) {
        final names = r.headers.keys.map((k) => k.toLowerCase());
        expect(names.where((n) => n.contains('api-key') || n.contains('apikey')), isEmpty, reason: r.toString());
        expect(r.headers['Authorization'], 'Bearer jwt');
      }
    });

    test('kaynak kodda gömülü yönetici anahtarı başlığı / sabit MQTT parolası kalmadı', () {
      final offenders = <String>[];
      for (final dir in <String>['lib/services', 'lib/models', 'lib/utils', 'lib/config']) {
        for (final entity in Directory(dir).listSync(recursive: true)) {
          if (entity is! File || !entity.path.endsWith('.dart')) continue;
          final text = entity.readAsStringSync();
          if (RegExp('x-admin-api-key', caseSensitive: false).hasMatch(text)) offenders.add('${entity.path}: admin key başlığı');
          // password: 'sabit-metin' (yer tutucu olmayan düz metin parola) arayışı
          if (RegExp(r'''password:\s*['"][^'"$\s][^'"]*['"]''').hasMatch(text)) {
            offenders.add('${entity.path}: sabit parola');
          }
        }
      }
      expect(offenders, isEmpty);
    });

    test('baseUrl AppConfig varsayılanından gelir ve /v1 yolları kullanılır', () async {
      api.on('POST', '/api/v1/auth/login', (r) => okResponse(<String, dynamic>{'access_token': 'a', 'refresh_token': 'r'}));
      await service.login('a@b.c', ' parola ');
      expect(api.requests.single.url.toString(), 'https://api.test/api/v1/auth/login');
    });
  });

  group('giriş / kayıt gövdeleri', () {
    test('login: parola KIRPILMAZ, tanımlayıcı kırpılır; belirteçler yeni oturum olur', () async {
      api.on('POST', '/api/v1/auth/login', (r) {
        return okResponse(<String, dynamic>{'access_token': 'acc', 'refresh_token': 'ref', 'user': <String, dynamic>{'id': 'u'}});
      });
      final generationBefore = service.sessionGeneration;
      final payload = await service.login('  a@b.c  ', '  boşluklu parola  ');
      final body = api.requests.single.json!;
      expect(body['identifier'], 'a@b.c');
      expect(body['password'], '  boşluklu parola  ');
      expect(service.authToken, 'acc');
      expect(service.currentRefreshToken, 'ref');
      expect(service.sessionGeneration, greaterThan(generationBefore));
      expect((payload['user'] as Map)['id'], 'u');
    });

    test('hatalı giriş: ApiException(code) ve oturum açılmaz', () async {
      api.on('POST', '/api/v1/auth/login',
          (r) => errorResponse(401, 'E-posta veya şifre hatalı', code: 'INVALID_CREDENTIALS'));
      await expectLater(
        service.login('a@b.c', 'x'),
        throwsA(isA<ApiException>()
            .having((e) => e.code, 'code', 'INVALID_CREDENTIALS')
            .having((e) => e.message, 'message', 'E-posta veya şifre hatalı')),
      );
      expect(service.authToken, isNull);
      expect(expired, isEmpty, reason: 'kimliksiz uçta 401 oturum sonu sayılmaz');
      expect(api.count('POST', '/api/v1/auth/refresh'), 0);
    });

    test('Google: yalnızca id_token gider (e-posta/kimlik alanı yok)', () async {
      api.on('POST', '/api/v1/auth/google', (r) => okResponse(<String, dynamic>{'access_token': 'a'}));
      await service.loginWithGoogle(idToken: 'google-id-token');
      expect(api.requests.single.json, <String, dynamic>{'id_token': 'google-id-token'});
    });

    test('Apple: kimlik jetonu zorunlu; ad isteğe bağlı', () async {
      api.on('POST', '/api/v1/auth/apple', (r) => okResponse(<String, dynamic>{'access_token': 'a'}));
      await service.loginWithApple(identityToken: 'apple-jwt', fullName: ' Ayşe Y ');
      expect(api.requests.single.json, <String, dynamic>{'identity_token': 'apple-jwt', 'full_name': 'Ayşe Y'});
    });

    test('resetPassword: yeni parola kırpılmaz; belirteç yoksa oturum başlamaz', () async {
      api.on('POST', '/api/v1/auth/reset-password', (r) => okResponse(<String, dynamic>{'message': 'ok'}));
      await service.resetPassword(identifier: ' a@b.c ', code: ' 123456 ', newPassword: '  yeni parola 1  ');
      final body = api.requests.single.json!;
      expect(body['identifier'], 'a@b.c');
      expect(body['code'], '123456');
      expect(body['new_password'], '  yeni parola 1  ');
      expect(service.authToken, isNull);
    });

    test('magicLogin POST ile (GET ile oturum açılmaz)', () async {
      api.on('POST', '/api/v1/auth/magic-login', (r) => okResponse(<String, dynamic>{'access_token': 'a'}));
      await service.magicLogin(' tok ');
      expect(api.requests.single.method, 'POST');
      expect(api.requests.single.json, <String, dynamic>{'token': 'tok'});
    });

    test('yanıtta access_token yoksa BAD_RESPONSE', () async {
      api.on('POST', '/api/v1/auth/login', (r) => okResponse(<String, dynamic>{'x': 1}));
      await expectLater(service.login('a', 'b'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'BAD_RESPONSE')));
    });
  });

  group('refresh: yalnızca 401, tek-uçuş, tek yeniden deneme', () {
    setUp(() {
      service.setAuthToken('old-access');
      service.setRefreshToken('old-refresh');
    });

    test('üç eşzamanlı 401 -> TEK refresh isteği, hepsi yeni belirteçle yeniden denenir', () async {
      stubRefresh();
      final gate = Completer<void>();
      api.on('GET', '/api/v1/homes', (r) async {
        if (r.headers['Authorization'] == 'Bearer old-access') {
          await gate.future; // üçü de eski token ile 401 yesin diye hepsi bekler
          return errorResponse(401, 'Süre doldu', code: 'TOKEN_EXPIRED');
        }
        return okResponse(<dynamic>[]);
      });
      final calls = Future.wait<dynamic>(<Future<dynamic>>[
        service.fetchHomes(),
        service.fetchHomes(),
        service.fetchHomes(),
      ]);
      await pumpEventQueue();
      gate.complete();
      await calls;
      expect(api.count('POST', '/api/v1/auth/refresh'), 1, reason: 'refresh token döner: paralel iki kullanım aile iptali olurdu');
      expect(service.authToken, 'new-access');
      expect(service.currentRefreshToken, 'new-refresh', reason: 'rotasyon: yeni refresh token saklanır');
      // her istek tam bir kez yeniden denendi: 3 ilk + 3 yeniden
      expect(api.count('GET', '/api/v1/homes'), 6);
      expect(expired, isEmpty);
    });

    test('yeniden denenen istek de 401 alırsa İKİNCİ refresh yapılmaz', () async {
      stubRefresh();
      api.on('GET', '/api/v1/homes', (r) => errorResponse(401, 'Hâlâ geçersiz', code: 'TOKEN_EXPIRED'));
      await expectLater(service.fetchHomes(), throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 401)));
      expect(api.count('POST', '/api/v1/auth/refresh'), 1);
      expect(api.count('GET', '/api/v1/homes'), 2);
    });

    test('403 refresh TETİKLEMEZ ve oturum korunur (onForbidden çağrılır)', () async {
      stubRefresh();
      api.on('GET', RegExp(r'/api/v1/homes/.+/endpoints'),
          (r) => errorResponse(403, 'Yetkiniz yok', code: 'FORBIDDEN'));
      await expectLater(service.fetchEndpoints(kHome), throwsA(isA<ApiException>().having((e) => e.isForbidden, 'forbidden', true)));
      expect(api.count('POST', '/api/v1/auth/refresh'), 0);
      expect(service.authToken, 'old-access');
      expect(service.currentRefreshToken, 'old-refresh');
      expect(forbidden, <String?>[kHome]);
      expect(expired, isEmpty);
    });

    test('403 GUEST_EXPIRED -> onGuestExpired(homeId); refresh yok', () async {
      stubRefresh();
      api.on('POST', RegExp(r'/api/v1/homes/.+/mqtt-credentials'),
          (r) => errorResponse(403, 'Misafir süreniz doldu', code: 'GUEST_EXPIRED'));
      await expectLater(service.mqttCredentials(kHome), throwsA(isA<ApiException>().having((e) => e.isGuestExpired, 'guestExpired', true)));
      expect(guestExpired, <String?>[kHome]);
      expect(forbidden, isEmpty, reason: 'GUEST_EXPIRED ayrı olay; genel yetki yenilemesi tetiklenmez');
      expect(api.count('POST', '/api/v1/auth/refresh'), 0);
    });

    test('refresh ağ hatasıyla düşerse oturum KORUNUR (çıkış olayı yok)', () async {
      var failRefresh = true;
      api.on('POST', '/api/v1/auth/refresh', (r) {
        if (failRefresh) throw const SocketException('bağlantı yok');
        return okResponse(<String, dynamic>{'access_token': 'a2', 'refresh_token': 'r2'});
      });
      api.on('GET', '/api/v1/homes', (r) => r.headers['Authorization'] == 'Bearer old-access'
          ? errorResponse(401, 'x', code: 'TOKEN_EXPIRED')
          : okResponse(<dynamic>[]));
      await expectLater(service.fetchHomes(), throwsA(isA<ApiException>().having((e) => e.isNetwork, 'network', true)));
      expect(service.authToken, 'old-access');
      expect(service.currentRefreshToken, 'old-refresh');
      expect(expired, isEmpty);

      failRefresh = false; // ağ geri geldi: aynı oturumla devam
      await service.fetchHomes();
      expect(service.currentRefreshToken, 'r2');
    });

    test('refresh 5xx / 429 ile düşerse oturum korunur', () async {
      for (final status in <int>[500, 503, 429]) {
        service
          ..setAuthToken('old-access')
          ..setRefreshToken('old-refresh');
        api.requests.clear();
        final local = MockApi();
        final svc = EvCloudApiService(baseUrl: 'https://api.test/api', client: local.client, clock: clock)
          ..setAuthToken('old-access')
          ..setRefreshToken('old-refresh')
          ..onSessionExpired = expired.add;
        addTearDown(svc.dispose);
        local.on('POST', '/api/v1/auth/refresh', (r) => errorResponse(status, 'iç hata detayı SQL'));
        local.on('GET', '/api/v1/homes', (r) => errorResponse(401, 'x', code: 'TOKEN_EXPIRED'));
        await expectLater(svc.fetchHomes(), throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', status)));
        expect(svc.currentRefreshToken, 'old-refresh', reason: 'status=$status');
        expect(svc.authToken, 'old-access');
      }
      expect(expired, isEmpty);
    });

    test('refresh KALICI reddedilirse -> onSessionExpired + belirteçler silinir', () async {
      stubRefresh(status: 401);
      api.on('GET', '/api/v1/homes', (r) => errorResponse(401, 'x', code: 'TOKEN_EXPIRED'));
      await expectLater(service.fetchHomes(), throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 401)));
      expect(expired, <SessionEndReason>[SessionEndReason.refreshRejected]);
      expect(service.authToken, isNull);
      expect(service.currentRefreshToken, isNull);
      expect(service.hasSession, isFalse);

      // sonraki çağrı artık Authorization taşımaz ve ikinci bir olay üretmez
      api.requests.clear();
      api.on('GET', '/api/v1/homes', (r) => errorResponse(401, 'x', code: 'TOKEN_EXPIRED'));
      await expectLater(service.fetchHomes(), throwsA(isA<ApiException>()));
      expect(api.requests.single.headers.containsKey('Authorization'), isFalse);
      expect(expired, hasLength(1));
    });

    test('paralel istekler kalıcı reddi yalnızca BİR kez bildirir', () async {
      stubRefresh(status: 401);
      api.on('GET', '/api/v1/homes', (r) => errorResponse(401, 'x', code: 'TOKEN_EXPIRED'));
      final results = await Future.wait<Object?>(<Future<Object?>>[
        service.fetchHomes().then<Object?>((v) => v).catchError((Object e) => e),
        service.fetchHomes().then<Object?>((v) => v).catchError((Object e) => e),
      ]);
      expect(results.every((r) => r is ApiException), isTrue);
      expect(expired, hasLength(1));
      expect(api.count('POST', '/api/v1/auth/refresh'), 1);
    });

    test('refresh token yoksa 401 -> noRefreshToken olayı', () async {
      service.setRefreshToken(null);
      api.on('GET', '/api/v1/homes', (r) => errorResponse(401, 'x', code: 'INVALID_TOKEN'));
      await expectLater(service.fetchHomes(), throwsA(isA<ApiException>()));
      expect(expired, <SessionEndReason>[SessionEndReason.noRefreshToken]);
      expect(api.count('POST', '/api/v1/auth/refresh'), 0);
    });

    test('INVALID_TOKEN: önce refresh denenir; olmazsa invalidToken sonu', () async {
      stubRefresh(status: 401);
      api.on('GET', '/api/v1/homes', (r) => errorResponse(401, 'x', code: 'INVALID_TOKEN'));
      await expectLater(service.fetchHomes(), throwsA(isA<ApiException>()));
      expect(expired, <SessionEndReason>[SessionEndReason.invalidToken]);
    });

    test('onTokenRefreshed BEKLENİR: yeniden denenen istek, depolama bitince gönderilir', () async {
      stubRefresh();
      final storageDone = Completer<void>();
      service.onTokenRefreshed = (access, refresh) async {
        events.add('persist-start');
        await storageDone.future;
        events.add('persist-end:$access:$refresh');
      };
      api.on('GET', '/api/v1/homes', (r) {
        final token = r.headers['Authorization'];
        events.add('GET:$token');
        return token == 'Bearer old-access'
            ? errorResponse(401, 'x', code: 'TOKEN_EXPIRED')
            : okResponse(<dynamic>[]);
      });
      final call = service.fetchHomes();
      await pumpEventQueue();
      expect(events, <String>['GET:Bearer old-access', 'refresh', 'persist-start']);
      storageDone.complete();
      await call;
      expect(events, <String>[
        'GET:Bearer old-access',
        'refresh',
        'persist-start',
        'persist-end:new-access:new-refresh',
        'GET:Bearer new-access',
      ]);
    });

    test('OTURUM NESLİ: refresh uçarken çıkış yapılırsa gelen yanıt yazılmaz, geri çağrı çalışmaz', () async {
      final refreshGate = Completer<void>();
      var persisted = false;
      service.onTokenRefreshed = (a, r) => persisted = true;
      api.on('POST', '/api/v1/auth/refresh', (r) async {
        await refreshGate.future;
        return okResponse(<String, dynamic>{'access_token': 'zombie-access', 'refresh_token': 'zombie-refresh'});
      });
      api.on('GET', '/api/v1/homes', (r) => errorResponse(401, 'x', code: 'TOKEN_EXPIRED'));
      final call = service
          .fetchHomes()
          .then<Object?>((v) => v)
          .catchError((Object e) => e);
      await pumpEventQueue();
      expect(api.count('POST', '/api/v1/auth/refresh'), 1);

      service.clearSession(); // kullanıcı çıkış yaptı
      refreshGate.complete(); // refresh yanıtı geç geldi
      final result = await call;

      expect(result, isA<ApiException>());
      expect(service.authToken, isNull, reason: 'çıkıştan sonra gelen refresh yanıtı yazılmaz');
      expect(service.currentRefreshToken, isNull);
      expect(persisted, isFalse);
      expect(api.count('GET', '/api/v1/homes'), 1, reason: 'istek yeniden denenmez');
      expect(expired, isEmpty, reason: 'çıkış zaten yapıldı; ikinci olay yok');
    });

    test('refresh yanıtı yeni refresh token vermezse eskisi korunur', () async {
      api.on('POST', '/api/v1/auth/refresh', (r) => okResponse(<String, dynamic>{'access_token': 'a2'}));
      api.on('GET', '/api/v1/homes', (r) => r.headers['Authorization'] == 'Bearer old-access'
          ? errorResponse(401, 'x', code: 'TOKEN_EXPIRED')
          : okResponse(<dynamic>[]));
      await service.fetchHomes();
      expect(service.currentRefreshToken, 'old-refresh');
      expect(service.authToken, 'a2');
    });
  });

  group('çıkış', () {
    test('logout: ÖNCE yerel temizlik, sonra sunucu iptali (sunucu yanıtlamasa da)', () async {
      service
        ..setAuthToken('acc')
        ..setRefreshToken('ref');
      final gate = Completer<void>();
      api.on('POST', '/api/v1/auth/logout', (r) async {
        events.add('server-revoke:${service.authToken}:${service.currentRefreshToken}');
        await gate.future;
        return okResponse(null);
      });
      final future = service.logout();
      await pumpEventQueue();
      expect(service.authToken, isNull);
      expect(service.currentRefreshToken, isNull);
      expect(events, <String>['server-revoke:null:null'], reason: 'yerel oturum sunucu çağrısından ÖNCE silinmiş olmalı');
      expect(api.requests.single.json, <String, dynamic>{'refresh_token': 'ref'});
      gate.complete();
      await future;
    });

    test('logout sunucu hatası/ağ hatası çıkışı engellemez', () async {
      service
        ..setAuthToken('acc')
        ..setRefreshToken('ref');
      api.on('POST', '/api/v1/auth/logout', (r) => throw const SocketException('yok'));
      await service.logout();
      expect(service.hasSession, isFalse);
    });

    test('revokeRefreshToken asla fırlatmaz', () async {
      api.on('POST', '/api/v1/auth/logout', (r) => errorResponse(500, 'x'));
      expect(await service.revokeRefreshToken('r'), isFalse);
    });
  });

  group('servis oturumu (PIN)', () {
    test('kapsamlı token: refresh yok, süre izlenir, ev bilgisi döner', () async {
      api.on('POST', '/api/v1/auth/service-login', (r) => okResponse(<String, dynamic>{
            'access_token': 'svc-token',
            'expires_in': 7200,
            'scope': 'home_service',
            'home': <String, dynamic>{'id': kHome, 'name': 'Müşteri Evi'},
          }));
      final info = await service.serviceLogin(' 123456 ', technicianName: ' Ali Veli ');
      expect(api.requests.single.json, <String, dynamic>{'service_pin': '123456', 'technician_name': 'Ali Veli'});
      expect(service.authToken, 'svc-token');
      expect(service.currentRefreshToken, isNull);
      expect(service.isServiceSession, isTrue);
      expect(info.homeId, kHome);
      expect(info.homeName, 'Müşteri Evi');
      expect(info.expiresAt, clock.now().add(const Duration(seconds: 7200)));
      expect(info.remaining(clock.now()), const Duration(hours: 2));
    });

    test('401 SERVICE_SESSION_EXPIRED -> refresh denenmez, oturum biter', () async {
      service.restoreServiceSession(
        accessToken: 'svc',
        info: ServiceSessionInfo(homeId: kHome, homeName: 'x', expiresAt: clock.now().add(const Duration(hours: 1))),
      );
      stubRefresh();
      api.on('GET', RegExp(r'/api/v1/homes/.+/endpoints'),
          (r) => errorResponse(401, 'bitti', code: 'SERVICE_SESSION_EXPIRED'));
      await expectLater(service.fetchEndpoints(kHome), throwsA(isA<ApiException>()));
      expect(expired, <SessionEndReason>[SessionEndReason.serviceSessionExpired]);
      expect(api.count('POST', '/api/v1/auth/refresh'), 0);
      expect(service.isServiceSession, isFalse);
    });

    test('yerel süre dolduysa sunucuya gitmeden oturum kapanır', () async {
      service.restoreServiceSession(
        accessToken: 'svc',
        info: ServiceSessionInfo(homeId: kHome, homeName: 'x', expiresAt: clock.now().add(const Duration(minutes: 5))),
      );
      api.on('GET', RegExp(r'/api/v1/homes/.+/endpoints'), (r) => okResponse(<dynamic>[]));
      await service.fetchEndpoints(kHome); // süre dolmadı
      expect(api.requests, hasLength(1));
      clock.advance(const Duration(minutes: 6));
      await expectLater(
        service.fetchEndpoints(kHome),
        throwsA(isA<ApiException>().having((e) => e.isServiceSessionExpired, 'expired', true)),
      );
      expect(api.requests, hasLength(1), reason: 'süre dolduktan sonra ağa çıkılmadı');
      expect(expired, <SessionEndReason>[SessionEndReason.serviceSessionExpired]);
    });
  });

  group('yeni uçlar', () {
    setUp(() => service.setAuthToken('jwt'));

    test('mqttCredentials: POST /homes/:id/mqtt-credentials, yanıt çözülür', () async {
      api.on('POST', '/api/v1/homes/$kHome/mqtt-credentials', (r) => okResponse(<String, dynamic>{
            'host': 'evotomasyon.example',
            'port': 8884,
            'username': 'a_h_x_1',
            'password': 'p',
            'client_id': 'cid-1',
            'expires_at': '2026-10-02T00:00:00Z',
            'topic_id': 'h_x',
          }));
      final c = await service.mqttCredentials(kHome);
      expect(c.host, 'evotomasyon.example');
      expect(c.port, 8884);
      expect(c.clientId, 'cid-1');
      expect(c.expiresAt, DateTime.utc(2026, 10, 2));
      expect(c.topicId, 'h_x');
    });

    test('mqttCredentials: eksik alan -> BAD_RESPONSE', () async {
      api.on('POST', '/api/v1/homes/$kHome/mqtt-credentials', (r) => okResponse(<String, dynamic>{'host': 'x'}));
      await expectLater(service.mqttCredentials(kHome), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'BAD_RESPONSE')));
    });

    test('sendCommand: gövde {home_id, command}; yanıt {delivered, device_online, command_id}', () async {
      api.on('POST', '/api/v1/devices/AHBU-S3-ABC123/command', (r) => okResponse(<String, dynamic>{
            'delivered': true,
            'device_online': true,
            'command_id': 'cmd-7',
          }));
      final result = await service.sendCommand(
        homeId: kHome,
        deviceId: 'AHBU-S3-ABC123',
        command: <String, dynamic>{'relay': 3, 'state': true, 'id': 'x1'},
      );
      expect(api.requests.single.json, <String, dynamic>{
        'home_id': kHome,
        'command': <String, dynamic>{'relay': 3, 'state': true, 'id': 'x1'},
      });
      expect(result.delivered, isTrue);
      expect(result.deviceOnline, isTrue);
      expect(result.commandId, 'cmd-7');
    });

    test('sendCommand: 409 DEVICE_OFFLINE -> ApiException(isDeviceOffline)', () async {
      api.on('POST', RegExp(r'/api/v1/devices/.+/command'),
          (r) => errorResponse(409, 'Cihaz çevrimdışı', code: 'DEVICE_OFFLINE'));
      await expectLater(
        service.sendCommand(homeId: kHome, deviceId: 'AHBU-S3-ABC123', command: <String, dynamic>{'relay': 1, 'state': true}),
        throwsA(isA<ApiException>().having((e) => e.isDeviceOffline, 'offline', true).having((e) => e.statusCode, 'status', 409)),
      );
      expect(api.count('POST', '/api/v1/auth/refresh'), 0);
    });

    test('sendCommand: cihaz kimliği yol parçası olarak kodlanır', () async {
      api.on('POST', RegExp(r'/api/v1/devices/.+/command'), (r) => okResponse(<String, dynamic>{'delivered': true}));
      await service.sendCommand(homeId: kHome, deviceId: 'a/b c', command: <String, dynamic>{'cmd': 'all_off'});
      expect(api.requests.single.url.path, '/api/v1/devices/a%2Fb%20c/command');
    });

    test('devices: liste çözülür, bozuk kayıt atlanır', () async {
      api.on('GET', '/api/v1/homes/$kHome/devices', (r) => okResponse(<dynamic>[
            <String, dynamic>{'device_uuid': 'AHBU-S3-ABC123', 'name': 'Pano', 'online': true, 'last_seen_at': '2026-10-01T10:00:00Z', 'firmware': '1.1.0'},
            <String, dynamic>{'name': 'kimliksiz'},
          ]));
      final list = await service.devices(kHome);
      expect(list, hasLength(1));
      expect(list.single.online, isTrue);
      expect(list.single.firmware, '1.1.0');
      expect(list.single.lastSeenAt, DateTime.utc(2026, 10, 1, 10));
    });

    test('localKey: yanıt doğrulanır (8–32 karakter)', () async {
      api.on('GET', '/api/v1/homes/$kHome/devices/AHBU-S3-ABC123/local-key',
          (r) => okResponse(<String, dynamic>{'local_key': 'abcd1234efgh'}));
      expect(await service.localKey(kHome, 'AHBU-S3-ABC123'), 'abcd1234efgh');
      api.on('GET', '/api/v1/homes/$kHome/devices/AHBU-S3-SHORT01/local-key',
          (r) => okResponse(<String, dynamic>{'local_key': 'kisa'}));
      await expectLater(service.localKey(kHome, 'AHBU-S3-SHORT01'), throwsA(isA<ApiException>()));
    });

    test('commission: 5 kontrol AYRI alanlarla, tests_passed GÖNDERİLMEZ, sonuç sunucudan', () async {
      api.on('POST', '/api/v1/homes/$kHome/commissioning',
          (r) => okResponse(<String, dynamic>{'tests_passed': true, 'status': 'APPROVED_WORKING'}));
      const ok = CommissionCheck(ok: true, detail: 'tamam');
      final result = await service.commission(
        homeId: kHome,
        deviceUuid: 'ahbu-s3-abc123',
        checks: const CommissioningChecks(relays: ok, buttons: ok, shutters: ok, network: ok, cloud: ok),
        notes: ' Müşteri onayladı ',
      );
      final body = api.requests.single.json!;
      expect(body['device_uuid'], 'AHBU-S3-ABC123');
      expect(body['notes'], 'Müşteri onayladı');
      expect(body.containsKey('tests_passed'), isFalse);
      final checks = body['checks'] as Map<String, dynamic>;
      expect(checks.keys, containsAll(<String>['relays', 'buttons', 'shutters', 'network', 'cloud']));
      expect((checks['relays'] as Map)['ok'], true);
      expect((checks['cloud'] as Map)['detail'], 'tamam');
      expect(result.testsPassed, isTrue);
      expect(result.status, 'APPROVED_WORKING');
    });

    test('updateEndpoint: shutter_duration_sec 1..300; ad/oda gövdesi', () async {
      api.on('PUT', RegExp(r'/api/v1/homes/.+/endpoints/.+'), (r) => okResponse(<String, dynamic>{'id': 'e1'}));
      await service.updateEndpoint(homeId: kHome, endpointId: 'e1', name: 'Salon', room: 'Oturma', shutterDurationSec: 24);
      expect(api.requests.single.json, <String, dynamic>{'name': 'Salon', 'room': 'Oturma', 'shutter_duration_sec': 24});
      for (final bad in <int>[0, -3, 301]) {
        await expectLater(
          service.updateEndpoint(homeId: kHome, endpointId: 'e1', shutterDurationSec: bad),
          throwsA(isA<ApiException>().having((e) => e.code, 'code', 'VALIDATION')),
        );
      }
      expect(api.requests, hasLength(1), reason: 'geçersiz süre ağa çıkmaz');
    });

    test('getChildLock hatada FIRLATIR (eskiden false döndürüyordu)', () async {
      api.on('GET', RegExp(r'/api/v1/devices/child-lock/.+'), (r) => errorResponse(500, 'SQL hata'));
      await expectLater(service.getChildLock(kHome), throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 500)));
      api.requests.clear();
      final ok = MockApi()..on('GET', RegExp(r'/api/v1/devices/child-lock/.+'), (r) => okResponse(<String, dynamic>{'child_lock_enabled': true}));
      final svc = EvCloudApiService(baseUrl: 'https://api.test/api', client: ok.client)..setAuthToken('t');
      addTearDown(svc.dispose);
      expect(await svc.getChildLock(kHome), isTrue);
    });

    test('controlEndpoint: sonuç türü CommandResult', () async {
      api.on('POST', RegExp(r'/api/v1/homes/.+/endpoints/.+/control'),
          (r) => okResponse(<String, dynamic>{'delivered': false, 'device_online': false}));
      final r = await service.controlEndpoint(kHome, 'e1', state: true);
      expect(r, isA<CommandResult>());
      expect(r.delivered, isFalse);
      expect(api.requests.single.json, <String, dynamic>{'state': true});
    });

    test('fetchHomes: {data: [...]} ve {data: {homes: [...]}} biçimleri, bozuk kayıt atlanır', () async {
      api.on('GET', '/api/v1/homes', (r) => okResponse(<dynamic>[
            <String, dynamic>{'id': kHome, 'name': 'Ev', 'role': 'owner', 'timezone': 'Europe/Istanbul', 'mqtt_topic_id': 'h_1'},
            <String, dynamic>{'name': 'kimliksiz'},
            'bozuk',
          ]));
      final a = await service.fetchHomes();
      expect(a.single.id, kHome);
      expect(a.single.role, 'owner');

      final nested = MockApi()..on('GET', '/api/v1/homes', (r) => okResponse(<String, dynamic>{'homes': <dynamic>[<String, dynamic>{'id': 'h2'}]}));
      final svc = EvCloudApiService(baseUrl: 'https://api.test/api', client: nested.client)..setAuthToken('t');
      addTearDown(svc.dispose);
      expect((await svc.fetchHomes()).single.id, 'h2');
    });

    test('üye listesi / silme: UUID String kimlikler yola yazılır', () async {
      const userId = '3f2504e0-4f89-11d3-9a0c-0305e82c3301';
      api.on('GET', '/api/v1/homes/$kHome/members', (r) => jsonResponse(<String, dynamic>{
            'success': true,
            'members': <dynamic>[
              <String, dynamic>{'userId': userId, 'fullName': 'Ali', 'role': 'guest', 'validUntil': '2026-10-02T00:00:00Z'},
            ],
          }));
      api.on('DELETE', '/api/v1/homes/$kHome/members/$userId', (r) => okResponse(null));
      final members = await service.getHomeMembers(kHome);
      expect(members.single.userId, userId);
      expect(await service.removeHomeMember(kHome, members.single.userId), isTrue);
      expect(api.requests.last.url.path, '/api/v1/homes/$kHome/members/$userId');
    });

    test('createInvitation: rol beyaz listesi, süre 1..72 saat, snake_case gövde', () async {
      api.on('POST', '/api/v1/homes/$kHome/invitations', (r) => jsonResponse(<String, dynamic>{
            'success': true,
            'invitation': <String, dynamic>{'inviteCode': 'ABCD123456', 'role': 'guest', 'expiresAt': '2026-10-02T00:00:00Z'},
          }));
      final inv = await service.createInvitation(kHome, role: 'guest', durationHours: 8, guestName: ' Temizlikçi ');
      expect(inv.code, 'ABCD123456');
      expect(api.requests.single.json, <String, dynamic>{'role': 'guest', 'duration_hours': 8, 'guest_name': 'Temizlikçi'});
      await expectLater(service.createInvitation(kHome, role: 'owner'), throwsA(isA<ApiException>()));
      await expectLater(service.createInvitation(kHome, role: 'guest', durationHours: 100), throwsA(isA<ApiException>()));
      await expectLater(service.createInvitation(kHome, role: 'member'), throwsA(isA<ApiException>()));
      expect(api.requests, hasLength(1));
    });

    test('initiateTransfer: hedef zorunlu', () async {
      await expectLater(service.initiateTransfer(kHome, targetIdentifier: '  '), throwsA(isA<ApiException>()));
      expect(api.requests, isEmpty);
      api.on('POST', '/api/v1/homes/$kHome/transfer-initiate', (r) => okResponse(<String, dynamic>{
            'transferCode': 'AHBU-TR-482910',
            'qrPayload': 'AHBU-TRANSFER:AHBU-TR-482910',
            'expiresAt': '2026-10-03T00:00:00Z',
          }));
      final info = await service.initiateTransfer(kHome, targetIdentifier: ' yeni@sahip.com ');
      expect(info.code, 'AHBU-TR-482910');
      expect(api.requests.single.json, <String, dynamic>{'target_identifier': 'yeni@sahip.com'});
    });

    test('claimDevice: home_id gönderilmez; sonuç home_id/home_name/device_uuid', () async {
      api.on('POST', '/api/v1/devices/claim', (r) => okResponse(<String, dynamic>{'home_id': kHome, 'home_name': 'Yeni Ev', 'device_uuid': 'AHBU-S3-ABC123'}));
      final r = await service.claimDevice(deviceUuid: 'ahbu-s3-abc123', setupPin: ' 123456 ', homeName: ' Yeni Ev ');
      final body = api.requests.single.json!;
      expect(body.containsKey('home_id'), isFalse);
      expect(body['device_uuid'], 'AHBU-S3-ABC123');
      expect(body['setup_pin'], '123456');
      expect(r.homeId, kHome);
      expect(r.homeName, 'Yeni Ev');
    });

    test('emergencyReset: confirm_uid ve gerekçe gönderilir', () async {
      api.on('POST', '/api/v1/devices/emergency-reset', (r) => okResponse(<String, dynamic>{'setup_pin': '654321'}));
      final res = await service.emergencyResetDevice(
        deviceUuid: 'ahbu-s3-abc123',
        confirmUid: 'ahbu-s3-abc123',
        reason: ' Müşteri telefonunu kaybetti, kimlik doğrulandı ',
      );
      final body = api.requests.single.json!;
      expect(body['device_uuid'], 'AHBU-S3-ABC123');
      expect(body['confirm_uid'], 'AHBU-S3-ABC123');
      expect(body['reason'], 'Müşteri telefonunu kaybetti, kimlik doğrulandı');
      expect(res.setupPin, '654321');
    });

    test('zamanlı kurallar: snake_case gövde, String kural kimliği', () async {
      api.on('GET', '/api/v1/homes/$kHome/scheduled-rules', (r) => jsonResponse(<String, dynamic>{
            'rules': <dynamic>[
              <String, dynamic>{'id': 'r-1', 'channel': 2, 'action': 'on', 'hour': 7, 'minute': 0, 'days_of_week': <int>[1]},
              <String, dynamic>{'id': 'bozuk', 'channel': 0, 'action': 'on', 'hour': 99, 'minute': 0},
            ],
          }));
      api.on('PUT', '/api/v1/homes/$kHome/scheduled-rules/r-1', (r) => okResponse(<String, dynamic>{}));
      api.on('DELETE', '/api/v1/homes/$kHome/scheduled-rules/r-1', (r) => okResponse(null));
      final rules = await service.getScheduledRules(kHome);
      expect(rules.map((r) => r.id), <String>['r-1']);
      await service.updateScheduledRule(kHome, 'r-1', <String, dynamic>{'enabled': false});
      await service.deleteScheduledRule(kHome, 'r-1');
      expect(api.requests[1].json, <String, dynamic>{'enabled': false});
    });
  });

  group('hata çözümleme', () {
    test('code, message, Retry-After başlığı', () async {
      api.on('POST', '/api/v1/auth/login', (r) => errorResponse(
            429,
            'Çok fazla deneme',
            code: 'RATE_LIMITED',
            headers: <String, String>{'Retry-After': '42'},
          ));
      await expectLater(
        service.login('a', 'b'),
        throwsA(isA<ApiException>()
            .having((e) => e.isRateLimited, 'rateLimited', true)
            .having((e) => e.retryAfter, 'retryAfter', const Duration(seconds: 42))
            .having((e) => e.message, 'message', 'Çok fazla deneme')),
      );
    });

    test('423 PIN_LOCKED: retry_after gövdeden', () async {
      api.on('POST', '/api/v1/auth/service-login', (r) => errorResponse(
            423,
            'PIN kilitli',
            code: 'PIN_LOCKED',
            extra: <String, dynamic>{'retry_after': 90},
          ));
      await expectLater(
        service.serviceLogin('123456'),
        throwsA(isA<ApiException>()
            .having((e) => e.isPinLocked, 'pinLocked', true)
            .having((e) => e.retryAfter, 'retryAfter', const Duration(seconds: 90))),
      );
    });

    test('5xx: ham iç mesaj kullanıcıya SIZMAZ', () async {
      service.setAuthToken('t');
      api.on('GET', '/api/v1/homes', (r) => errorResponse(500, 'duplicate key value violates unique constraint "x"'));
      try {
        await service.fetchHomes();
        fail('fırlatılmalıydı');
      } on ApiException catch (e) {
        expect(e.message, isNot(contains('constraint')));
        expect(e.message, ApiException.defaultMessageFor(500));
        expect(e.toString(), e.message);
      }
    });

    test('JSON olmayan hata gövdesi (HTML) varsayılan mesajla çözülür', () async {
      service.setAuthToken('t');
      api.on('GET', '/api/v1/homes', (r) => http.Response('<html>502 Bad Gateway</html>', 502));
      await expectLater(service.fetchHomes(), throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 502)));
    });

    test('ağ hataları ApiException(statusCode: 0)', () async {
      service.setAuthToken('t');
      api.on('GET', '/api/v1/homes', (r) => throw const SocketException('yok'));
      await expectLater(service.fetchHomes(), throwsA(isA<ApiException>().having((e) => e.isNetwork, 'network', true)));
    });

    test('zaman aşımı ApiException(network) olur', () async {
      service.setAuthToken('t');
      api.on('GET', '/api/v1/homes', (r) => throw TimeoutException('yanıt yok'));
      await expectLater(
        service.fetchHomes(),
        throwsA(isA<ApiException>().having((e) => e.isNetwork, 'network', true).having((e) => e.cause, 'cause', isA<TimeoutException>())),
      );
    });

    test('2xx + success:false de hatadır', () async {
      api.on('POST', '/api/v1/auth/forgot-password',
          (r) => jsonResponse(<String, dynamic>{'success': false, 'message': 'Gönderilemedi'}));
      await expectLater(service.forgotPassword('a@b.c'), throwsA(isA<ApiException>().having((e) => e.message, 'message', 'Gönderilemedi')));
    });

    test('ApiException toString yalnızca mesajdır', () {
      expect(const ApiException(statusCode: 404, message: 'Yok', code: 'NOT_FOUND').toString(), 'Yok');
      expect('${ApiException.network()}', contains('ulaşılamadı'));
    });
  });
}
