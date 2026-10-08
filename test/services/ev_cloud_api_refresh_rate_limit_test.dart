import 'dart:isolate';

import 'package:ev_otomasyon/services/alarm_watch/refresh_gate.dart';
import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/services/ev_cloud_api_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';

/// Bellek içi ad kaydı: aynı kaydı paylaşan iki [IsolateRefreshGate] iki ayrı isolate'in (ön plan uygulaması + arka plan
/// alarm izleyicisi) süreç geneli kapısını taklit eder.
class _MemoryRegistry implements PortRegistry {
  final Map<String, SendPort> map = <String, SendPort>{};

  @override
  bool register(SendPort port, String name) {
    if (map.containsKey(name)) return false;
    map[name] = port;
    return true;
  }

  @override
  SendPort? lookup(String name) => map[name];

  @override
  bool remove(String name) => map.remove(name) != null;
}

/// Olay döngüsünü [condition] sağlanana kadar döndürür (gerçek bekleme yok).
Future<void> _until(bool Function() condition, {int maxTurns = 500}) async {
  for (var i = 0; i < maxTurns && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue, reason: 'koşul olay döngüsünde gerçekleşmedi');
}

/// uyelik-5: ortak NAT arkasında (aynı IP) yenileme hız sınırına (429 RATE_LIMITED) takılan uygulama oturumu
/// kaybetmemeli: `Retry-After` en çok 30 sn ise o kadar beklenip BİR kez yeniden denenir; daha uzunsa (sabit pencere:
/// 30 sn sonra da 429 kesin) beklenmeden anlaşılır mesaj verilir. Oturum her durumda korunur. Bekleme yenileme kapısı
/// DIŞINDA yapılır: kapıyı uzun tutmak diğer isolate'in kilidi devralıp aynı token'la yenilemesine (oturum ailesi
/// iptali) yol açardı.
void main() {
  late MockApi api;
  late FakeClock clock;
  late EvCloudApiService service;
  late List<SessionEndReason> expired;

  setUp(() {
    api = MockApi();
    clock = FakeClock();
    service = EvCloudApiService(baseUrl: 'https://api.test/api', client: api.client, clock: clock)
      ..setAuthToken('a-old')
      ..setRefreshToken('r-old');
    expired = <SessionEndReason>[];
    service.onSessionExpired = expired.add;
  });

  tearDown(() => service.dispose());

  test('429 + Retry-After 1 sn: beklenir, ikinci deneme başarılı', () async {
    var calls = 0;
    final sent = <String>[];
    api.on('POST', '/api/v1/auth/refresh', (r) {
      calls++;
      sent.add(r.json?['refresh_token'] as String);
      if (calls == 1) {
        return errorResponse(
          429,
          'Çok fazla istek.',
          code: 'RATE_LIMITED',
          headers: <String, String>{'Retry-After': '1'},
          extra: <String, dynamic>{'retry_after': 1},
        );
      }
      return okResponse(<String, dynamic>{'access_token': 'a2', 'refresh_token': 'r2'});
    });
    final future = service.refreshSession();
    await clock.elapse(const Duration(milliseconds: 500));
    expect(calls, 1, reason: 'Retry-After dolmadan yeniden denenmez');
    await clock.elapse(const Duration(seconds: 1));
    expect(await future, isTrue);
    expect(calls, 2);
    expect(sent, <String>['r-old', 'r-old']);
    expect(service.currentRefreshToken, 'r2');
    expect(expired, isEmpty);
  });

  test('iki 429 (Retry-After 5 sn): bir kez yeniden denenir, sonra "Sunucu geçici olarak yoğun"; oturum korunur', () async {
    api.on(
      'POST',
      '/api/v1/auth/refresh',
      (r) => errorResponse(429, 'x', code: 'RATE_LIMITED', headers: <String, String>{'Retry-After': '5'}),
    );
    final future = service.refreshSession();
    final expectation = expectLater(
      future,
      throwsA(isA<ApiException>()
          .having((e) => e.isRateLimited, 'rateLimited', isTrue)
          .having((e) => e.message, 'message', EvCloudApiService.refreshBusyMessage)),
    );
    await clock.elapse(const Duration(seconds: 4));
    expect(api.count('POST', '/api/v1/auth/refresh'), 1);
    await clock.elapse(const Duration(seconds: 2));
    await expectation;
    expect(api.count('POST', '/api/v1/auth/refresh'), 2);
    expect(service.currentRefreshToken, 'r-old');
    expect(service.authToken, 'a-old');
    expect(expired, isEmpty);
  });

  test('Retry-After 30 sn\'den uzun (sabit 15 dk pencere): yeniden denenmez, beklemeden "Sunucu geçici olarak yoğun"',
      () async {
    api.on(
      'POST',
      '/api/v1/auth/refresh',
      (r) => errorResponse(429, 'x', code: 'RATE_LIMITED', headers: <String, String>{'Retry-After': '900'}),
    );
    // Saat İLERLETİLMEDEN sonuçlanmalı: 30 sn beklemek yalnız açılışı/isteği geciktirir, sonuç yine 429 olurdu.
    await expectLater(
      service.refreshSession(),
      throwsA(isA<ApiException>()
          .having((e) => e.isRateLimited, 'rateLimited', isTrue)
          .having((e) => e.message, 'message', EvCloudApiService.refreshBusyMessage)
          .having((e) => e.retryAfter, 'retryAfter', const Duration(seconds: 900))),
    );
    expect(api.count('POST', '/api/v1/auth/refresh'), 1);
    expect(clock.activeTimerCount, 0, reason: 'bekleme zamanlayıcısı kurulmaz');
    expect(service.currentRefreshToken, 'r-old');
    expect(service.authToken, 'a-old');
    expect(expired, isEmpty);
  });

  group('uyelik-5: 429 beklemesi yenileme kapısı DIŞINDA (iki isolate aynı oturum ailesi)', () {
    late _MemoryRegistry registry;
    late FakeClock sharedClock;
    late MockApi server;
    late String storage;
    late List<String> sent;
    late bool familyRevoked;
    late List<SessionEndReason> ended;
    late int rateLimited;
    final clients = <EvCloudApiService>[];

    /// Ön plan uygulaması ya da arka plan izleyicisi: ortak güvenli depo ([storage]) ve ortak süreç kapısı.
    EvCloudApiService client() {
      final c = EvCloudApiService(baseUrl: 'https://api.test/api', client: server.client, clock: sharedClock)
        ..setAuthToken('a0')
        ..setRefreshToken('r0')
        // Kısa maxWait: kapıyı uzun tutan (canlı) sahibinden kilidin devralınmasını hızlı gösterir (üretimde 45 sn).
        ..refreshGate = IsolateRefreshGate(registry: registry, maxWait: const Duration(milliseconds: 300))
        ..readStoredRefreshToken = (() async => storage)
        ..onTokenRefreshed = ((access, refresh) async => storage = refresh!)
        ..onSessionExpired = ended.add;
      clients.add(c);
      return c;
    }

    setUp(() {
      registry = _MemoryRegistry();
      sharedClock = FakeClock();
      server = MockApi();
      storage = 'r0';
      sent = <String>[];
      familyRevoked = false;
      ended = <SessionEndReason>[];
      rateLimited = 1;
      var current = 'r0';
      final used = <String>{};
      var n = 0;
      // Sunucu: her yenileme token'ı döndürür; kullanılmış token'ın yeniden gelmesi "çalıntı" sayılır ve bütün aile
      // iptal edilir (CONTRACTS §1.2). Hız sınırı (429) token'ı TÜKETMEZ.
      server.on('POST', '/api/v1/auth/refresh', (r) {
        final token = r.json?['refresh_token'] as String;
        sent.add(token);
        if (rateLimited > 0) {
          rateLimited--;
          return errorResponse(429, 'Çok fazla istek.', code: 'RATE_LIMITED', headers: <String, String>{'Retry-After': '20'});
        }
        if (used.contains(token)) {
          familyRevoked = true;
          return errorResponse(401, 'Oturum iptal edildi.', code: 'INVALID_TOKEN');
        }
        if (familyRevoked || token != current) return errorResponse(401, 'Geçersiz oturum.', code: 'INVALID_TOKEN');
        used.add(token);
        n++;
        current = 'r$n';
        return okResponse(<String, dynamic>{'access_token': 'a$n', 'refresh_token': current});
      });
    });

    tearDown(() {
      for (final c in clients) {
        c.dispose();
      }
      clients.clear();
    });

    test('ön plan 429 beklerken kapıyı tutmaz: arka plan yeniler; ön plan sonra depodaki YENİ token\'la dener (aile iptal '
        'edilmez)', () async {
      final foreground = client();
      final background = client();

      final fgFuture = foreground.refreshSession();
      await _until(() => sent.length == 1); // ön plan 429 aldı, Retry-After (20 sn) bekliyor
      await pumpEventQueue();
      expect(registry.map, isEmpty, reason: '429 beklemesi sırasında yenileme kapısı TUTULMAZ');

      expect(await background.refreshSession().timeout(const Duration(seconds: 5)), isTrue);
      expect(storage, 'r1');

      await sharedClock.elapse(const Duration(seconds: 21));
      expect(await fgFuture, isTrue);
      expect(sent, <String>['r0', 'r0', 'r1'], reason: 'bekleme sonrası depodaki döndürülmüş token benimsenir');
      expect(familyRevoked, isFalse, reason: 'kullanılmış token yeniden gönderilmez');
      expect(ended, isEmpty);
      expect(foreground.currentRefreshToken, 'r2');
      expect(storage, 'r2');
      expect(registry.map, isEmpty, reason: 'kapı bırakıldı');
    });

    test('bekleme sırasında depo değişmediyse aynı token\'la BİR kez yeniden denenir (kapı yeniden alınır)', () async {
      final foreground = client();
      final fgFuture = foreground.refreshSession();
      await _until(() => sent.length == 1);
      await pumpEventQueue();
      expect(registry.map, isEmpty);
      await sharedClock.elapse(const Duration(seconds: 21));
      expect(await fgFuture, isTrue);
      expect(sent, <String>['r0', 'r0']);
      expect(storage, 'r1');
      expect(familyRevoked, isFalse);
      expect(registry.map, isEmpty);
    });
  });
}
