import 'dart:async';

import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/dashboard/apartment_dashboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';

/// PF-01 / PF-32 / PF-33 (WP-STATE, S1): LAN yoklaması hata TÜRÜNE göre davranır.
///
/// * `401` / `403 unprovisioned` / anahtarsız (kısıtlı) özet: kalıcı koşul -> yoklama DURUR
///   (`directNeedsKey`), bağlantı `connected`, `status == null`; çevrimdışı SAYILMAZ.
/// * `423` (çok sayıda hatalı deneme): süreli koşul -> `Retry-After` kadar beklenir (`directBlockedUntil`).
/// * Kullanıcı eylemi / ön plana dönüş / yeni adres-anahtar yoklamayı sürdürür.
/// * Tek-uçuş adres/anahtar değişimini bilir; uptime/RSSI telemetrisi kaba eşikle bildirilir.
void main() {
  Map<String, dynamic> statusBody({bool r3 = false, int uptime = 100, int rssi = -55}) => <String, dynamic>{
        'device_name': 'Pano',
        'ip': '192.168.1.30',
        'wifi_connected': true,
        'wifi_sta_ssid': 'EvAg',
        'wifi_sta_rssi': rssi,
        'uptime_sec': uptime,
        'child_lock': false,
        'relays': <Map<String, dynamic>>[
          <String, dynamic>{'id': 1, 'name': 'Avize', 'type': 1, 'state': false},
          <String, dynamic>{'id': 2, 'name': 'Avize Aşağı', 'type': 2, 'state': false},
          <String, dynamic>{'id': 3, 'name': 'Mutfak', 'type': 0, 'state': r3},
          <String, dynamic>{'id': 4, 'name': 'Spot', 'type': 0, 'state': false},
        ],
        'shutters': <Map<String, dynamic>>[
          <String, dynamic>{'pair': 1, 'pos': 20, 'is_moving': false, 'dir': 0, 'target': 255},
        ],
        'dis': <Map<String, dynamic>>[],
      };

  const lockedBody = <String, dynamic>{'error': 'locked', 'retry_after': 60};
  const unauthorizedBody = <String, dynamic>{'error': 'unauthorized'};
  const restrictedBody = <String, dynamic>{
    'device': 'AHBU-S3-TEST01',
    'name': 'Pano',
    'fw': '1.1.0',
    'provisioned': true,
    'wifi_connected': true,
  };

  /// Doğrudan (LAN) mod, anahtar tanımlı, ilk durum alınmış (1,5 sn'lik periyodik yoklama çalışıyor).
  /// [withDevice]: cihaz kimliği bilinir -> 401'de anahtar sunucudan yenilenebilir.
  Future<StateHarness> directHarness({bool withDevice = false}) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final h = StateHarness();
    h.state
      ..setCurrentUserForTesting(const UserModel(id: 'u', email: 'a@b.c', fullName: 'A', role: 'user'))
      ..setAuthStatusForTesting(AuthStatus.authenticated)
      ..setHomesForTesting(<HomeModel>[testHome()]);
    if (withDevice) {
      h.state.setSelectedDeviceForTesting(uuid: 'AHBU-S3-TEST01', ip: '192.168.1.30');
    }
    h.directMock.on('GET', '/api/status', (r) => jsonResponse(statusBody()));
    await h.state.setMode(AppMode.direct);
    await h.state.setHost('192.168.1.30');
    h.direct.localKey = 'devicekey-1234';
    await h.state.refresh();
    return h;
  }

  group('401 (anahtar reddi)', () {
    test('yoklama DURUR: 60 sn boyunca <= 3 istek; bağlı + durum yok + anahtar mesajı; çevrimdışı değil', () async {
      final h = await directHarness();
      addTearDown(h.dispose);
      expect(h.state.connState, ConnectionStateEnum.connected);
      h.directMock.on('GET', '/api/status', (r) => jsonResponse(unauthorizedBody, status: 401));
      h.directMock.requests.clear();

      await h.clock.elapse(const Duration(seconds: 60));

      expect(h.directMock.count('GET', '/api/status'), lessThanOrEqualTo(3),
          reason: 'eskiden 60 sn / 1,5 sn = 40 istek (bayat anahtarla cihaz kilidi tetiklenirdi)');
      expect(h.state.directNeedsKey, isTrue);
      expect(h.state.connState, ConnectionStateEnum.connected, reason: 'cihaza ulaşıldı: "bağlanıyor" ya da "çevrimdışı" değil');
      expect(h.state.status, isNull, reason: 'bayat kontrol kartları kalkar');
      expect(h.state.directError, contains('anahtar'));
      expect(h.state.directBlockedUntil, isNull);
    });

    test('doğru anahtar girilince (setLocalKey) yoklama hemen sürer, durum gelir ve durdurma kalkar', () async {
      final h = await directHarness();
      addTearDown(h.dispose);
      h.directMock.on('GET', '/api/status', (r) => jsonResponse(unauthorizedBody, status: 401));
      await h.clock.elapse(const Duration(seconds: 5));
      expect(h.state.directNeedsKey, isTrue);

      h.directMock.on('GET', '/api/status', (r) => jsonResponse(statusBody()));
      h.directMock.requests.clear();
      await h.state.setLocalKey('devicekey-5678');
      await h.clock.elapse(const Duration(seconds: 2));

      expect(h.state.directNeedsKey, isFalse);
      expect(h.state.status, isNotNull);
      expect(h.state.directError, isNull);
      expect(h.directMock.where('GET', '/api/status').first.headers['X-Device-Key'], 'devicekey-5678');
    });

    test('kullanıcının "Yeniden dene"si (refresh) tam BİR istek atar; ön plana dönüş yoklamayı sürdürür', () async {
      final h = await directHarness();
      addTearDown(h.dispose);
      h.directMock.on('GET', '/api/status', (r) => jsonResponse(unauthorizedBody, status: 401));
      await h.clock.elapse(const Duration(seconds: 5));
      expect(h.state.directNeedsKey, isTrue);
      h.directMock.requests.clear();

      await h.state.refresh(); // kullanıcı eylemi
      expect(h.directMock.count('GET', '/api/status'), 1);
      expect(h.state.directNeedsKey, isTrue, reason: 'anahtar hâlâ reddediliyor: yeniden durur');
      await h.clock.elapse(const Duration(seconds: 20));
      expect(h.directMock.count('GET', '/api/status'), 1, reason: 'durduktan sonra periyodik istek yok');

      h.state.handleLifecycleState(AppLifecycleState.paused);
      h.state.handleLifecycleState(AppLifecycleState.resumed); // ön plana dönüş: yoklama sürer
      await h.clock.elapse(const Duration(seconds: 5));
      expect(h.directMock.count('GET', '/api/status'), greaterThanOrEqualTo(2));
      expect(h.directMock.count('GET', '/api/status'), lessThanOrEqualTo(3));
    });

    test('403 unprovisioned: cihaz kurulmamış -> yoklama durur, mesaj görünür, çevrimdışı değil', () async {
      final h = await directHarness();
      addTearDown(h.dispose);
      h.directMock.on('GET', '/api/status', (r) => jsonResponse(<String, dynamic>{'error': 'unprovisioned'}, status: 403));
      h.directMock.requests.clear();

      await h.clock.elapse(const Duration(seconds: 30));

      expect(h.directMock.count('GET', '/api/status'), lessThanOrEqualTo(2));
      expect(h.state.directNeedsKey, isTrue);
      expect(h.state.connState, ConnectionStateEnum.connected);
      expect(h.state.directError, contains('kurulmam'));
    });

    test('anahtar sunucudan YENİLENİR (bir kez) ve yeni anahtarla devam edilir; durdurma yok', () async {
      final h = await directHarness(withDevice: true);
      addTearDown(h.dispose);
      h.cloud.localKeyValue = 'newkey-9999';
      final keyCallsBefore = h.cloud.count('localKey');
      h.directMock.on('GET', '/api/status', (r) {
        return r.headers['X-Device-Key'] == 'newkey-9999'
            ? jsonResponse(statusBody())
            : jsonResponse(unauthorizedBody, status: 401);
      });
      h.directMock.requests.clear();

      await h.clock.elapse(const Duration(seconds: 10));

      expect(h.cloud.count('localKey'), keyCallsBefore + 1, reason: 'tek anahtar yenilemesi');
      expect(h.direct.localKey, 'newkey-9999');
      expect(h.state.directNeedsKey, isFalse);
      expect(h.state.status, isNotNull);
      expect(h.state.connState, ConnectionStateEnum.connected);
      expect(h.state.directError, isNull);
    });

    test('sunucudaki anahtar da aynı (bayat) ise yenileme sonrası yoklama DURUR', () async {
      final h = await directHarness(withDevice: true);
      addTearDown(h.dispose);
      h.cloud.localKeyValue = 'devicekey-1234'; // sunucu da aynı anahtarı veriyor: reddedilen anahtar
      h.directMock.on('GET', '/api/status', (r) => jsonResponse(unauthorizedBody, status: 401));
      h.directMock.requests.clear();

      await h.clock.elapse(const Duration(seconds: 60));

      expect(h.directMock.count('GET', '/api/status'), lessThanOrEqualTo(3));
      expect(h.state.directNeedsKey, isTrue);
      expect(h.state.connState, ConnectionStateEnum.connected);
    });

    test('EK: anahtar yenileme AĞ hatasıyla düşerse hak tüketilmez; sonraki 401\'de yeniden denenir', () async {
      final h = await directHarness(withDevice: true);
      addTearDown(h.dispose);
      h.cloud.localKeyError = ApiException.network(); // internet yok: sunucudan yanıt alınamadı
      final keyCallsBefore = h.cloud.count('localKey');
      h.directMock.on('GET', '/api/status', (r) {
        return r.headers['X-Device-Key'] == 'newkey-9999'
            ? jsonResponse(statusBody())
            : jsonResponse(unauthorizedBody, status: 401);
      });
      h.directMock.requests.clear();

      await h.clock.elapse(const Duration(seconds: 10));
      expect(h.cloud.count('localKey'), keyCallsBefore + 1, reason: 'ilk 401: yenileme denendi (ağ hatası)');
      expect(h.state.directNeedsKey, isTrue, reason: 'anahtar değişmedi: cihazı bayat anahtarla yormamak için durur');
      expect(h.state.directError, contains('anahtar'), reason: 'cihazın mesajı görünür kalır (bulut ağ hatası değil)');

      h.cloud.localKeyError = null; // internet geldi
      h.cloud.localKeyValue = 'newkey-9999';
      await h.state.refresh(); // kullanıcı "Yeniden dene"
      await h.clock.elapse(const Duration(seconds: 5));

      expect(h.cloud.count('localKey'), keyCallsBefore + 2, reason: 'ağ hatası hakkı tüketmedi: sonraki 401 yeniden denedi');
      expect(h.direct.localKey, 'newkey-9999');
      expect(h.state.status, isNotNull);
      expect(h.state.directNeedsKey, isFalse);
    });

    test('EK: sunucu YANIT verdiyse (ör. 403) hak tüketilir: sonraki 401\'de yeniden sorulmaz', () async {
      final h = await directHarness(withDevice: true);
      addTearDown(h.dispose);
      h.cloud.localKeyError = const ApiException(statusCode: 403, code: 'FORBIDDEN', message: 'Yetkiniz yok');
      final keyCallsBefore = h.cloud.count('localKey');
      h.directMock.on('GET', '/api/status', (r) => jsonResponse(unauthorizedBody, status: 401));

      await h.clock.elapse(const Duration(seconds: 10));
      await h.state.refresh();
      await h.state.refresh();

      expect(h.cloud.count('localKey'), keyCallsBefore + 1, reason: 'gerçek deneme bir kez yapıldı');
      expect(h.state.directNeedsKey, isTrue);
    });
  });

  group('423 (cihaz kilitlendi)', () {
    test('Retry-After kadar BEKLER: ilk 59 sn\'de yalnız 1 istek; sonra bir istek; çevrimdışı olmaz', () async {
      final h = await directHarness();
      addTearDown(h.dispose);
      h.directMock.on(
        'GET',
        '/api/status',
        (r) => jsonResponse(lockedBody, status: 423, headers: <String, String>{'Retry-After': '60'}),
      );
      h.directMock.requests.clear();

      await h.clock.elapse(const Duration(seconds: 59));
      expect(h.directMock.count('GET', '/api/status'), 1, reason: 'eskiden 1,5 sn\'de bir: ~39 istek');
      expect(h.state.directBlockedUntil, isNotNull);
      expect(h.state.directBlockedUntil!.isAfter(h.clock.now()), isTrue);
      expect(h.state.connState, ConnectionStateEnum.connected, reason: 'cihaza ulaşıldı: ~4,5 sn sonra çevrimdışı olmaz');
      expect(h.state.status, isNull);
      expect(h.state.directError, contains('kilitlendi'));
      expect(h.state.directNeedsKey, isFalse, reason: '423 süreli koşul: anahtar sorunu değil');

      await h.clock.elapse(const Duration(seconds: 6)); // bekleme (60 + 1 sn) doldu
      expect(h.directMock.count('GET', '/api/status'), 2, reason: 'süre dolunca bir istek (yine 423: tekrar bekler)');
      expect(h.state.connState, ConnectionStateEnum.connected);
    });

    test('abartılı Retry-After (1 gün) 5 dk ile sınırlanır: yoklama saatlerce susmaz', () async {
      final h = await directHarness();
      addTearDown(h.dispose);
      h.directMock.on('GET', '/api/status', (r) => jsonResponse(<String, dynamic>{'error': 'locked', 'retry_after': 86400}, status: 423));
      h.directMock.requests.clear();

      await h.clock.elapse(const Duration(minutes: 4));
      expect(h.directMock.count('GET', '/api/status'), 1);
      expect(h.state.directBlockedUntil, isNotNull);

      await h.clock.elapse(const Duration(minutes: 2)); // 6 dk > 5 dk + 1 sn
      expect(h.directMock.count('GET', '/api/status'), 2);
    });

    test('Retry-After yoksa 60 sn varsayılır; kilit kalkınca durum geri gelir ve engel temizlenir', () async {
      final h = await directHarness();
      addTearDown(h.dispose);
      h.directMock.on('GET', '/api/status', (r) => jsonResponse(<String, dynamic>{'error': 'locked'}, status: 423));
      h.directMock.requests.clear();

      await h.clock.elapse(const Duration(seconds: 30));
      expect(h.directMock.count('GET', '/api/status'), 1);
      expect(h.state.directBlockedUntil, isNotNull);

      h.directMock.on('GET', '/api/status', (r) => jsonResponse(statusBody()));
      await h.clock.elapse(const Duration(seconds: 40));

      expect(h.state.status, isNotNull);
      expect(h.state.directBlockedUntil, isNull);
      expect(h.state.directError, isNull);
      expect(h.state.connState, ConnectionStateEnum.connected);
    });
  });

  group('423: engel zamanı ve mod değişimi', () {
    test('bekleme dolunca yine 423 gelirse YENİ engel zamanı bildirilir (arayüz bayat zaman görmez)', () async {
      final h = await directHarness();
      addTearDown(h.dispose);
      h.directMock.on('GET', '/api/status', (r) => jsonResponse(lockedBody, status: 423));
      await h.clock.elapse(const Duration(seconds: 5));
      final first = h.state.directBlockedUntil;
      expect(first, isNotNull);
      var notifications = 0;
      h.state.addListener(() => notifications++);

      await h.clock.elapse(const Duration(seconds: 70)); // bekleme (60 + 1 sn) doldu: bir istek, yine 423

      final second = h.state.directBlockedUntil;
      expect(second, isNotNull);
      expect(second!.isAfter(first!), isTrue, reason: 'kilit yenilendi: engel zamanı ileri alındı');
      expect(notifications, 1, reason: 'görünen engel zamanı değişti: tam bir bildirim (eskiden sessizce bayatlardı)');
      expect(h.state.connState, ConnectionStateEnum.connected);
    });

    test('buluta dönünce LAN durdurma ve 423 engeli temizlenir (bulut modunda "anahtar/kilit" kalıntısı yok)', () async {
      final h = await directHarness();
      addTearDown(h.dispose);
      h.directMock.on('GET', '/api/status', (r) => jsonResponse(unauthorizedBody, status: 401));
      await h.clock.elapse(const Duration(seconds: 5));
      expect(h.state.directNeedsKey, isTrue);

      expect(await h.state.setMode(AppMode.cloud), isTrue);
      expect(h.state.directNeedsKey, isFalse);
      expect(h.state.directBlockedUntil, isNull);

      h.directMock.on('GET', '/api/status', (r) => jsonResponse(lockedBody, status: 423));
      await h.state.setMode(AppMode.direct);
      await h.clock.elapse(const Duration(seconds: 5));
      expect(h.state.directBlockedUntil, isNotNull);

      await h.state.setMode(AppMode.cloud);
      expect(h.state.directBlockedUntil, isNull);
      expect(h.state.directNeedsKey, isFalse);
    });
  });

  group('anahtarsız (kısıtlı) özet', () {
    test('anahtar yokken: bildirim <= 1, istek <= 2 (eskiden 0,67 Hz bildirim + sonsuz istek); anahtar gerekli', () async {
      final h = await directHarness();
      addTearDown(h.dispose);
      h.direct.localKey = null;
      h.directMock.on('GET', '/api/status', (r) => jsonResponse(restrictedBody));
      var notifications = 0;
      h.state.addListener(() => notifications++);
      h.directMock.requests.clear();

      await h.clock.elapse(const Duration(seconds: 30));

      expect(h.directMock.count('GET', '/api/status'), lessThanOrEqualTo(2));
      expect(notifications, lessThanOrEqualTo(1), reason: 'durum bir kez değişti: bildirim de bir kez');
      expect(h.state.directNeedsKey, isTrue);
      expect(h.state.status, isNull);
      expect(h.state.connState, ConnectionStateEnum.connected);
      expect(h.state.directError, contains('anahtar'));
    });

    test('anahtar girilince yoklama sürer ve tam durum gelir', () async {
      final h = await directHarness();
      addTearDown(h.dispose);
      h.direct.localKey = null;
      h.directMock.on('GET', '/api/status', (r) {
        return r.headers.containsKey('X-Device-Key') ? jsonResponse(statusBody()) : jsonResponse(restrictedBody);
      });
      await h.clock.elapse(const Duration(seconds: 5));
      expect(h.state.directNeedsKey, isTrue);

      await h.state.setLocalKey('devicekey-5678');
      await h.clock.elapse(const Duration(seconds: 3));

      expect(h.state.directNeedsKey, isFalse);
      expect(h.state.status, isNotNull);
      expect(h.state.directError, isNull);
    });
  });

  group('PF-32: tek-uçuş adres/anahtar değişimini bilir', () {
    test('adres değişimi: eski adrese giden uçuş devralınmaz, yeni istek HEMEN gider; eski yanıt durumu ezmez', () async {
      final h = await directHarness();
      addTearDown(h.dispose);
      final gate = Completer<void>();
      final hosts = <String>[];
      h.directMock.on('GET', '/api/status', (r) async {
        hosts.add(r.url.host);
        if (r.url.host == '192.168.1.30') {
          await gate.future;
          return jsonResponse(statusBody(r3: true)); // eski cihaz: röle 3 açık
        }
        return jsonResponse(statusBody(r3: false)); // yeni cihaz: röle 3 kapalı
      });

      final oldFlight = h.state.refresh(silent: true); // eski adrese giden istek kapıda bekler
      await pumpEventQueue();
      expect(hosts, <String>['192.168.1.30']);

      final setHost = h.state.setHost('192.168.1.31'); // eskiden: mevcut uçuş devralınır, setHost takılırdı
      await pumpEventQueue();
      expect(hosts, <String>['192.168.1.30', '192.168.1.31'], reason: 'yeni adres için ayrı istek hemen gitti');
      expect(h.state.status?.relayById(3)?.state, isFalse);

      gate.complete();
      await Future.wait<void>(<Future<void>>[oldFlight, setHost]);
      await pumpEventQueue();

      expect(h.state.status!.relayById(3)!.state, isFalse, reason: 'eski adresin geç yanıtı yeni adresin durumunu ezmedi');
      expect(h.state.connState, ConnectionStateEnum.connected);
    });

    test('anahtar değişimi: yeni anahtarla istek hemen gider; eski anahtarın geç 401\'i yoklamayı durdurmaz', () async {
      final h = await directHarness();
      addTearDown(h.dispose);
      final gate = Completer<void>();
      final keys = <String?>[];
      h.directMock.on('GET', '/api/status', (r) async {
        final key = r.headers['X-Device-Key'];
        keys.add(key);
        if (key == 'devicekey-1234') {
          await gate.future;
          return jsonResponse(unauthorizedBody, status: 401); // eski anahtar reddedildi (geç)
        }
        return jsonResponse(statusBody());
      });

      final oldFlight = h.state.refresh(silent: true);
      await pumpEventQueue();
      await h.state.setLocalKey('devicekey-5678');
      await pumpEventQueue();
      expect(keys, contains('devicekey-5678'), reason: 'yeni anahtarla ayrı istek');

      gate.complete();
      await oldFlight;
      await pumpEventQueue();

      expect(h.state.directNeedsKey, isFalse, reason: 'eski anahtarın geç 401\'i artık geçersiz');
      expect(h.state.status, isNotNull);
      expect(h.state.directError, isNull);
    });
  });

  group('PF-33: telemetri kartı donmaz, bildirim yağmuru da olmaz', () {
    test('uptime her yoklamada artar: 3 dk içinde en az 2, en çok 6 bildirim (≈ dakikada 1)', () async {
      final h = await directHarness();
      addTearDown(h.dispose);
      var uptime = 1000;
      h.directMock.on('GET', '/api/status', (r) {
        uptime += 2;
        return jsonResponse(statusBody(uptime: uptime));
      });
      await h.clock.elapse(const Duration(seconds: 2)); // ilk yeni değer bildirilir; eşik buradan sayılır
      var notifications = 0;
      h.state.addListener(() => notifications++);

      await h.clock.elapse(const Duration(minutes: 3));

      expect(notifications, greaterThanOrEqualTo(2), reason: 'telemetri kartı (select<DeviceStatus?>) en az dakikada bir tazelenmeli');
      expect(notifications, lessThanOrEqualTo(6), reason: '120 yoklama için bildirim yağmuru yok');
      expect(h.state.status!.uptimeSec, greaterThan(1100));
    });

    test('RSSI sıçraması (>= 10 dB) bildirir; küçük oynama (±3 dB) bildirmez', () async {
      final h = await directHarness();
      addTearDown(h.dispose);
      var rssi = -55;
      h.directMock.on('GET', '/api/status', (r) => jsonResponse(statusBody(rssi: rssi)));
      await h.clock.elapse(const Duration(seconds: 2));
      var notifications = 0;
      h.state.addListener(() => notifications++);

      rssi = -58;
      await h.clock.elapse(const Duration(seconds: 5));
      rssi = -52;
      await h.clock.elapse(const Duration(seconds: 5));
      expect(notifications, 0, reason: '±3 dB: kaba eşik altında');

      rssi = -80;
      await h.clock.elapse(const Duration(seconds: 3));
      expect(notifications, 1);
      expect(h.state.status!.wifiStaRssi, -80);
    });

    test('çocuk kilidi zamanı her yoklamada tazelenir (bildirimsiz): "son bilinen" saati bayat kalmaz', () async {
      final h = await directHarness();
      addTearDown(h.dispose);
      final first = h.state.childLockUpdatedAt;
      expect(first, isNotNull);
      var notifications = 0;
      h.state.addListener(() => notifications++);

      await h.clock.elapse(const Duration(seconds: 10));

      expect(h.state.childLockUpdatedAt!.isAfter(first!), isTrue);
      expect(notifications, 0, reason: 'zaman damgası tazelemesi bildirim üretmez');
    });
  });

  group('arayüz (ApartmentDashboard, doğrudan mod)', () {
    Future<StateHarness> mount(WidgetTester tester) async {
      final h = (await tester.runAsync(() => directHarness()))!;
      addTearDown(h.dispose);
      await pumpApp(tester, child: const Scaffold(body: ApartmentDashboard()), state: h.state, size: const Size(800, 1600));
      return h;
    }

    Future<void> elapse(WidgetTester tester, StateHarness h, Duration d) async {
      await tester.runAsync(() => h.clock.elapse(d));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('401 sonrası "Cihaz kontrol edilemiyor" kartı görünür (sonsuz "Cihaza bağlanılıyor…" yok)', (tester) async {
      final h = await mount(tester);
      expect(find.byKey(const Key('view_apartment')), findsOneWidget);
      h.directMock.on('GET', '/api/status', (r) => jsonResponse(unauthorizedBody, status: 401));

      await elapse(tester, h, const Duration(seconds: 5));

      expect(find.text('Cihaz kontrol edilemiyor'), findsOneWidget);
      expect(find.byKey(const Key('loading_view')), findsNothing);
      expect(find.text('Cihaza bağlanılıyor…'), findsNothing);
      expect(find.textContaining('anahtar'), findsWidgets, reason: 'anahtar sorunu arayüzde görünür');
      expect(h.state.directNeedsKey, isTrue);
    });

    testWidgets('423 sonrası kart cihazın kilitlendiğini söyler; "Yerel Wi-Fi ağına bağlı olduğunuzdan emin olun" YANILTMAZ', (tester) async {
      final h = await mount(tester);
      h.directMock.on('GET', '/api/status', (r) => jsonResponse(lockedBody, status: 423));

      await elapse(tester, h, const Duration(seconds: 10));

      expect(find.text('Cihaz kontrol edilemiyor'), findsOneWidget);
      expect(find.textContaining('kilitlendi'), findsWidgets);
      expect(find.text('Cihaza ulaşılamıyor'), findsNothing, reason: 'eskiden ~4,5 sn sonra yanıltıcı "ulaşılamıyor" kartı çıkardı');
      expect(find.textContaining('Yerel Wi-Fi'), findsNothing);
    });
  });
}
