import 'dart:async';

import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/services/command_pipeline.dart';
import 'package:ev_otomasyon/services/ev_cloud_api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/support.dart';

/// `EvCloudApiService` süre bütçeleri (Dalga 5a, WP-CLOUD-API):
///
/// * PF-09: `_call` TOPLAM süre bütçesi. Eskiden 401 yolunda istek + refresh + yeniden deneme süreleri
///   ARDIŞIK birikiyordu (GET 10+10+10 sn, komut 8+10+8 sn); `_sendRaw`'daki `Future.timeout` yalnız tek isteği
///   sınırlar. Bütçe = istek zaman aşımı + 4 sn (komutlarda komut hattı `maxTotal` = 10 sn ile uyumlu).
/// * PF-02 (5. adım): refresh sonrası `onTokenRefreshed` (kalıcı yazım) 3 sn ile sınırlıdır; takılı yazım tek-uçuş
///   yenilemeyi ve bekleyen TÜM 401 yeniden denemelerini sonsuza dek bloklamaz.
///
/// Plain test + `FakeClock` + `MockApi`: bütçe zamanlayıcısı `Clock`'tan kurulur, `clock.elapse` ile deterministiktir.
/// (`_sendRaw`'ın kendi `Future.timeout`'u gerçek zamanlıdır; bu testlerde asla tetiklenmez, bu yüzden dönmeyen
/// istekleri yalnız bütçe keser.)
void main() {
  const homeId = kHomeA;
  const deviceId = 'AHBU-S3-TEST01';

  late MockApi api;
  late FakeClock clock;
  late EvCloudApiService service;
  late List<SessionEndReason> expired;
  final gates = <Completer<http.Response>>[];

  setUp(() {
    api = MockApi();
    clock = FakeClock();
    service = EvCloudApiService(baseUrl: 'https://api.test/api', client: api.client, clock: clock)
      ..setAuthToken('access-old')
      ..setRefreshToken('refresh-old');
    expired = <SessionEndReason>[];
    service.onSessionExpired = expired.add;
  });

  tearDown(() async {
    // Hiç dönmeyen sahte istekleri bırak: `_sendRaw`'ın gerçek zamanlı `Future.timeout` zamanlayıcıları iptal olsun.
    // 503: hem GET kapısında hem refresh kapısında oturumu düşürmeyen, nötr bir sonuç.
    for (final gate in gates) {
      if (!gate.isCompleted) gate.complete(errorResponse(503, 'test sonu', code: 'SERVICE_UNAVAILABLE'));
    }
    gates.clear();
    await pumpEventQueue();
    service.dispose();
  });

  /// Kapı açılana kadar dönmeyen sahte yanıt.
  Completer<http.Response> hang() {
    final gate = Completer<http.Response>();
    gates.add(gate);
    return gate;
  }

  /// Sonucu (değer ya da hata) bir kutuya yazar; "henüz dönmedi" de gözlenebilsin.
  _Box<T> track<T>(Future<T> future) {
    final box = _Box<T>();
    future.then<void>((value) {
      box.done = true;
      box.value = value;
    }, onError: (Object error) {
      box.done = true;
      box.error = error;
    });
    return box;
  }

  Matcher networkError() => isA<ApiException>().having((e) => e.isNetwork, 'isNetwork', isTrue);

  http.Response refreshOk() =>
      okResponse(<String, dynamic>{'access_token': 'access-new', 'refresh_token': 'refresh-new'});

  group('PF-09: _call toplam süre bütçesi', () {
    test('hiç dönmeyen GET: 10 sn istek sınırı + 4 sn pay = 14 sn içinde ağ hatası (zaman aşımı nedenli), oturum korunur', () async {
      final gate = hang();
      api.on('GET', '/api/v1/homes', (r) => gate.future);
      final call = track(service.fetchHomes());

      await clock.elapse(const Duration(seconds: 13));
      expect(call.done, isFalse, reason: 'bütçe (14 sn) dolmadan beklenir');

      await clock.elapse(const Duration(seconds: 1));
      expect(call.done, isTrue, reason: 'bütçe dolunca çağrı SONSUZA DEK asılı kalmaz');
      expect(
        call.error,
        isA<ApiException>()
            .having((e) => e.isNetwork, 'isNetwork', isTrue)
            .having((e) => e.cause, 'cause', isA<TimeoutException>())
            .having((e) => e.message, 'message', contains('zamanında yanıt vermedi')),
        reason: '_sendRaw zaman aşımıyla aynı biçim: arayüz "zaman aşımı" ile "internet yok"u ayırt edebilir',
      );
      expect(service.hasSession, isTrue, reason: 'ağ hatası oturumu düşürmez');
      expect(expired, isEmpty);
      expect(api.count('GET', '/api/v1/homes'), 1);
      expect(clock.activeTimerCount, 0, reason: 'bütçe zamanlayıcısı tetiklendi ve kalmadı');
    });

    test('hızlı çağrı: değer aynen döner ve bütçe zamanlayıcısı iptal edilir (zamanlayıcı sızıntısı yok)', () async {
      api.on('GET', '/api/v1/homes', (r) => okResponse(<dynamic>[]));
      expect(await service.fetchHomes(), isEmpty);
      expect(clock.activeTimerCount, 0);

      await clock.elapse(const Duration(minutes: 1)); // iptal edilen zamanlayıcı artık kimseyi etkilemez
      expect(api.count('GET', '/api/v1/homes'), 1);
    });

    test('hata yanıtı (4xx) bütçeden bağımsız aynen iletilir; bütçe zamanlayıcısı kalmaz', () async {
      api.on('GET', '/api/v1/homes', (r) => errorResponse(404, 'Yok', code: 'NOT_FOUND'));
      await expectLater(service.fetchHomes(), throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 404)));
      expect(clock.activeTimerCount, 0);
    });

    test('bütçe dolduktan sonra gelen HATA yanıtı çağırana ulaşmaz ve ele alınmamış (zone) hata üretmez', () async {
      // Not: beklentiler korumalı bölgenin DIŞINDADIR. Hata bölgeleri arası hata geçmediğinden bölge içinde
      // başarısız olan bir `expect` testi (30 sn) asılı bırakırdı.
      final uncaught = <Object>[];
      final gate = hang();
      api.on('GET', '/api/v1/homes', (r) => gate.future);
      late _Box<Object?> call;
      Object? errorAtBudget;
      await runZonedGuarded<Future<void>>(() async {
        call = track(service.fetchHomes());
        await clock.elapse(const Duration(seconds: 14));
        errorAtBudget = call.error;

        gate.complete(errorResponse(500, 'iç hata', code: 'INTERNAL')); // geç dönen yanıt
        await pumpEventQueue();
      }, (error, stack) => uncaught.add(error));

      expect(errorAtBudget, networkError());
      expect(call.value, isNull);
      expect(call.error, networkError(), reason: 'geç gelen yanıt sonucu değiştirmez');
      expect(uncaught, isEmpty, reason: 'main.dart onError\'una düşecek ele alınmamış hata olmamalı');
    });

    test('kimliksiz çağrılar (login) da bütçelidir; refresh denenmez', () async {
      service.clearSession();
      final gate = hang();
      api.on('POST', '/api/v1/auth/login', (r) => gate.future);
      final call = track(service.login('a@b.c', 'parola-12345'));

      await clock.elapse(const Duration(seconds: 14));
      expect(call.error, networkError());
      expect(api.count('POST', '/api/v1/auth/refresh'), 0);
      expect(service.hasSession, isFalse);
    });

    test('401 hemen, refresh dönmüyor: 14 sn içinde ağ hatası, oturum KORUNUR, iç koşu bir kez refresh gönderir', () async {
      api.on('GET', '/api/v1/homes', (r) => errorResponse(401, 'Süre doldu', code: 'TOKEN_EXPIRED'));
      final refreshGate = hang();
      api.on('POST', '/api/v1/auth/refresh', (r) => refreshGate.future);

      final call = track(service.fetchHomes());
      await clock.elapse(const Duration(seconds: 13));
      expect(call.done, isFalse);
      expect(api.count('POST', '/api/v1/auth/refresh'), 1, reason: 'tek-uçuş refresh başladı');

      await clock.elapse(const Duration(seconds: 1));
      expect(call.error, networkError(), reason: 'eskiden 10+10+10 sn ardışık beklenirdi');
      expect(service.hasSession, isTrue);
      expect(expired, isEmpty, reason: 'ağ hatası oturumu düşürmez');
      expect(service.authToken, 'access-old');
      expect(service.currentRefreshToken, 'refresh-old');
      expect(api.count('POST', '/api/v1/auth/refresh'), 1);
      expect(api.count('GET', '/api/v1/homes'), 1);
    });

    test('terk edilen koşu: refresh bütçeden SONRA dönerse belirteçler yine uygulanır ama istek HAYALET yeniden gönderilmez', () async {
      api.on('GET', '/api/v1/homes', (r) => errorResponse(401, 'Süre doldu', code: 'TOKEN_EXPIRED'));
      final refreshGate = hang();
      api.on('POST', '/api/v1/auth/refresh', (r) => refreshGate.future);
      final call = track(service.fetchHomes());
      await clock.elapse(const Duration(seconds: 14));
      expect(call.error, networkError());

      refreshGate.complete(refreshOk()); // geç geldi
      await pumpEventQueue();
      expect(api.count('GET', '/api/v1/homes'), 1, reason: 'çağıran zaten hata aldı: iç koşu isteği yeniden göndermez');
      expect(api.count('POST', '/api/v1/auth/refresh'), 1);
      expect(call.error, networkError(), reason: 'sonuç değişmez');
      expect(service.authToken, 'access-new', reason: 'refresh boşa gitmez: dönen (rotasyon) belirteçler uygulanır');
      expect(service.currentRefreshToken, 'refresh-new');
      expect(expired, isEmpty);

      // Oturum devam eder: sonraki çağrı yeni belirteçle, ek refresh olmadan gider.
      api.on('GET', '/api/v1/homes', (r) => okResponse(<dynamic>[]));
      expect(await service.fetchHomes(), isEmpty);
      expect(api.requests.last.headers['Authorization'], 'Bearer access-new');
      expect(api.count('POST', '/api/v1/auth/refresh'), 1);
    });

    test('terk edilen koşu: ilk istek bütçeden SONRA 401 ile dönerse refresh BAŞLATMAZ (belirteçler/oturum değişmez)', () async {
      final gate = hang();
      api.on('GET', '/api/v1/homes', (r) => gate.future);
      api.on('POST', '/api/v1/auth/refresh', (r) => refreshOk());
      final call = track(service.fetchHomes());
      await clock.elapse(const Duration(seconds: 14));
      expect(call.error, networkError());

      gate.complete(errorResponse(401, 'Süre doldu', code: 'TOKEN_EXPIRED')); // geç 401
      await pumpEventQueue();
      expect(api.count('POST', '/api/v1/auth/refresh'), 0, reason: 'çağıran zaten hata aldı: terk edilen koşu refresh başlatmaz');
      expect(api.count('GET', '/api/v1/homes'), 1);
      expect(call.error, networkError());
      expect(service.authToken, 'access-old');
      expect(service.currentRefreshToken, 'refresh-old');
      expect(expired, isEmpty);
    });

    test('refresh dönüyor ama YENİDEN DENEME isteği takılıyor: yine 14 sn toplam sınırı, oturum korunur', () async {
      final retryGate = hang();
      api.on('GET', '/api/v1/homes', (r) => r.headers['Authorization'] == 'Bearer access-old'
          ? errorResponse(401, 'Süre doldu', code: 'TOKEN_EXPIRED')
          : retryGate.future);
      api.on('POST', '/api/v1/auth/refresh', (r) => refreshOk());

      final call = track(service.fetchHomes());
      await clock.elapse(const Duration(seconds: 13));
      expect(call.done, isFalse);
      expect(api.count('GET', '/api/v1/homes'), 2, reason: 'ilk istek + yeniden deneme');

      await clock.elapse(const Duration(seconds: 1));
      expect(call.error, networkError());
      expect(service.hasSession, isTrue);
      expect(service.authToken, 'access-new');
      expect(expired, isEmpty);
      expect(api.count('POST', '/api/v1/auth/refresh'), 1);
    });

    test('yavaş ama bütçe İÇİNDE dönen refresh: istek normal yeniden denenir (bütçe meşru akışı bozmaz)', () async {
      api.on('GET', '/api/v1/homes', (r) => r.headers['Authorization'] == 'Bearer access-old'
          ? errorResponse(401, 'Süre doldu', code: 'TOKEN_EXPIRED')
          : okResponse(<dynamic>[]));
      final refreshGate = hang();
      api.on('POST', '/api/v1/auth/refresh', (r) => refreshGate.future);

      final call = track(service.fetchHomes());
      await clock.elapse(const Duration(seconds: 9));
      expect(call.done, isFalse);

      refreshGate.complete(refreshOk()); // 9. sn: bütçe (14 sn) içinde
      await clock.elapse(const Duration(seconds: 1));
      expect(call.done, isTrue);
      expect(call.error, isNull);
      expect(call.value, isEmpty);
      expect(api.count('GET', '/api/v1/homes'), 2);
      expect(api.requests.last.headers['Authorization'], 'Bearer access-new');
      expect(clock.activeTimerCount, 0);
    });

    test('komut (sendCommand): toplam bütçe komut hattı üst sınırıyla (maxTotal 10 sn) uyumlu; terk edilen koşu komutu yeniden GÖNDERMEZ', () async {
      final pipeline = CommandPipeline(clock: clock);
      addTearDown(pipeline.dispose);
      final maxTotal = pipeline.maxTotal; // CONTRACTS §5: komut başına toplam üst sınır

      api.on('POST', '/api/v1/devices/$deviceId/command', (r) => errorResponse(401, 'Süre doldu', code: 'TOKEN_EXPIRED'));
      final refreshGate = hang();
      api.on('POST', '/api/v1/auth/refresh', (r) => refreshGate.future);

      final call = track(service.sendCommand(
        homeId: homeId,
        deviceId: deviceId,
        command: <String, dynamic>{'relay': 1, 'state': true},
      ));
      await clock.elapse(const Duration(seconds: 8));
      expect(call.done, isFalse, reason: 'tek REST isteğine tanınan 8 sn bütçeyi aşmamalı');

      await clock.elapse(maxTotal - const Duration(seconds: 8));
      expect(call.error, networkError(), reason: 'REST çağrısı, komut hattı komutu geri almadan ÖNCE/AYNI ANDA biter (eskiden 8+10+8 sn)');
      expect(service.hasSession, isTrue);
      expect(expired, isEmpty);

      refreshGate.complete(refreshOk());
      await pumpEventQueue();
      expect(api.count('POST', '/api/v1/devices/$deviceId/command'), 1,
          reason: 'hayalet yeniden gönderim YOK: komut hattı geri aldıktan sonra komut ikinci kez gitmez');
    });

    // Diğer komut türü çağrılar (8 sn istek sınırı) aynı komut bütçesini taşır: komut hattı `maxTotal` içinde biter.
    final commandLikeCalls = <String, ({String path, Future<Object?> Function() run})>{
      'setChildLock': (
        path: '/api/v1/devices/child-lock',
        run: () => service.setChildLock(homeId: homeId, enabled: true),
      ),
      'controlEndpoint': (
        path: '/api/v1/homes/$homeId/endpoints/ep-1/control',
        run: () => service.controlEndpoint(homeId, 'ep-1', cmd: 'on'),
      ),
    };
    for (final entry in commandLikeCalls.entries) {
      test('${entry.key}: komut bütçesi (8 sn <= bütçe <= komut hattı maxTotal)', () async {
        final pipeline = CommandPipeline(clock: clock);
        addTearDown(pipeline.dispose);
        final gate = hang();
        api.on('POST', entry.value.path, (r) => gate.future);

        final call = track(entry.value.run());
        await clock.elapse(const Duration(seconds: 8));
        expect(call.done, isFalse, reason: 'tek REST isteğine tanınan 8 sn bütçeyi aşmamalı');

        await clock.elapse(pipeline.maxTotal - const Duration(seconds: 8));
        expect(call.error, networkError(), reason: 'varsayılan 12 sn (8+4) komut hattının 10 sn sınırını aşardı');
      });
    }

    test('uzun zaman aşımlı çağrılar (acil sıfırlama 20 sn) bütçeyi kendi zaman aşımına göre alır: 24 sn', () async {
      final gate = hang();
      api.on('POST', '/api/v1/devices/emergency-reset', (r) => gate.future);
      final call = track(service.emergencyResetDevice(
        deviceUuid: deviceId,
        confirmUid: deviceId,
        reason: 'Pano yanıt vermiyor, yerinde değiştirilecek.',
      ));

      await clock.elapse(const Duration(seconds: 23));
      expect(call.done, isFalse, reason: '20 sn istek sınırı + 4 sn pay');
      await clock.elapse(const Duration(seconds: 1));
      expect(call.error, networkError());
    });
  });

  group('PF-02 (5. adım): refresh sonrası belirteç yazımı (onTokenRefreshed) 3 sn ile sınırlı', () {
    void stubRefreshThenOk() {
      api.on('POST', '/api/v1/auth/refresh', (r) => refreshOk());
      api.on('GET', '/api/v1/homes', (r) => r.headers['Authorization'] == 'Bearer access-old'
          ? errorResponse(401, 'Süre doldu', code: 'TOKEN_EXPIRED')
          : okResponse(<dynamic>[]));
    }

    test('yazım hiç dönmüyor: çağrı 4 sn içinde tamamlanır; yeniden deneme YENİ belirteçle, refresh tek kez', () async {
      stubRefreshThenOk();
      final persist = Completer<void>();
      var persistCalls = 0;
      String? persistedAccess;
      String? persistedRefresh;
      service.onTokenRefreshed = (access, refresh) {
        persistCalls++;
        persistedAccess = access;
        persistedRefresh = refresh;
        return persist.future; // güvenli depo takıldı
      };

      final call = track(service.fetchHomes());
      await clock.elapse(const Duration(seconds: 4));

      expect(call.done, isTrue, reason: 'takılı yazım artık tek-uçuş yenilemeyi ve yeniden denemeyi SONSUZA DEK bloklamaz');
      expect(call.error, isNull);
      expect(call.value, isEmpty);
      expect(persistCalls, 1);
      expect(persistedAccess, 'access-new');
      expect(persistedRefresh, 'refresh-new');
      expect(api.count('POST', '/api/v1/auth/refresh'), 1);
      expect(api.count('GET', '/api/v1/homes'), 2);
      expect(api.requests.last.headers['Authorization'], 'Bearer access-new');
      expect(service.authToken, 'access-new', reason: 'belirteçler zaten bellekte');
      expect(service.currentRefreshToken, 'refresh-new');
      expect(expired, isEmpty);
      expect(clock.activeTimerCount, 0);

      persist.complete(); // geç biten yazım sonucu bozmaz
      await pumpEventQueue();
      expect(service.authToken, 'access-new');
    });

    test('sınır tam 3 sn: yazım bu sürede BEKLENİR (yeniden deneme gönderilmez), süre dolunca beklemeden gider', () async {
      stubRefreshThenOk();
      final persist = Completer<void>();
      service.onTokenRefreshed = (access, refresh) => persist.future;

      final call = track(service.fetchHomes());
      await clock.elapse(const Duration(seconds: 2, milliseconds: 999));
      expect(call.done, isFalse);
      expect(api.count('GET', '/api/v1/homes'), 1, reason: 'yeniden deneme yazım sınırı dolana kadar gönderilmez (pinli sözleşme: yazım BEKLENİR)');

      await clock.elapse(const Duration(milliseconds: 1));
      expect(call.done, isTrue);
      expect(api.count('GET', '/api/v1/homes'), 2);
    });

    test('yazım sınır İÇİNDE biterse çağrı 3 sn beklemez; zamanlayıcı iptal edilir', () async {
      stubRefreshThenOk();
      final persist = Completer<void>();
      service.onTokenRefreshed = (access, refresh) => persist.future;

      final call = track(service.fetchHomes());
      await clock.elapse(const Duration(seconds: 1));
      expect(call.done, isFalse);

      persist.complete();
      await pumpEventQueue();
      expect(call.done, isTrue, reason: 'yazım biter bitmez yeniden deneme gider');
      expect(call.error, isNull);
      expect(api.count('GET', '/api/v1/homes'), 2);
      expect(clock.activeTimerCount, 0);
    });

    test('uyelik-3: yazım HATA verirse yenileme yine başarılıdır (belirteçler bellekte); istek yeniden denenir', () async {
      stubRefreshThenOk();
      service.onTokenRefreshed = (access, refresh) => throw StateError('depo yazılamadı');

      final call = track(service.fetchHomes());
      await clock.elapse(const Duration(seconds: 1));
      expect(call.error, isNull, reason: 'yazım hatası yenilemeyi başarısız saymaz');
      expect(call.done, isTrue);
      expect(api.count('GET', '/api/v1/homes'), 2, reason: '401 sonrası yeni belirteçle bir kez yeniden denenir');
      expect(service.storedRefreshKnown, isTrue, reason: 'depodan geri yüklenen eski değer bilinir; yenisi yazılamadı');
    });

    test('sınırı aşan yazımın GEÇ dönen hatası yutulur: ele alınmamış (zone) hata üretmez', () async {
      // Beklentiler korumalı bölgenin dışında (bkz. yukarıdaki not).
      final uncaught = <Object>[];
      stubRefreshThenOk();
      late _Box<Object?> call;
      var doneAtLimit = false;
      await runZonedGuarded<Future<void>>(() async {
        // Tamamlayıcı da korumalı bölgede kurulur: hata bölgeleri arası hata geçmez; üretimdeki tek bölgeyi taklit eder.
        final persist = Completer<void>();
        service.onTokenRefreshed = (access, refresh) => persist.future;
        call = track(service.fetchHomes());
        await clock.elapse(const Duration(seconds: 4));
        doneAtLimit = call.done;

        persist.completeError(StateError('geç gelen depo hatası'));
        await pumpEventQueue();
      }, (error, stack) => uncaught.add(error));

      expect(doneAtLimit, isTrue, reason: 'çağrı yazımı 3 sn bekleyip yoluna devam etti');
      expect(call.error, isNull, reason: 'geç hata sonucu bozmaz');
      expect(call.value, isEmpty);
      expect(uncaught, isEmpty, reason: 'main.dart onError\'una düşecek ele alınmamış hata olmamalı');
    });

    test('yazım beklenirken çıkış yapılırsa (oturum nesli değişti) yeniden deneme GÖNDERİLMEZ', () async {
      stubRefreshThenOk();
      final persist = Completer<void>();
      service.onTokenRefreshed = (access, refresh) => persist.future;

      final call = track(service.fetchHomes());
      await clock.elapse(const Duration(seconds: 1));
      expect(call.done, isFalse);

      service.clearSession(); // kullanıcı çıkış yaptı
      await clock.elapse(const Duration(seconds: 3));

      expect(call.done, isTrue);
      expect(call.error, isA<ApiException>().having((e) => e.statusCode, 'status', 401));
      expect(api.count('GET', '/api/v1/homes'), 1, reason: 'çıkış yapılmış istemciden istek yeniden denenmez');
      expect(service.authToken, isNull);
      expect(service.currentRefreshToken, isNull);
      expect(expired, isEmpty, reason: 'çıkış zaten yapıldı; ikinci olay yok');
    });
  });
}

class _Box<T> {
  bool done = false;
  T? value;
  Object? error;
}
