import 'dart:convert';
import 'dart:io';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/services/automation_api_service.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/support.dart';

/// Cihazın yerel (LAN/AP) HTTP API istemcisi: CONTRACTS §3 / §3b.
void main() {
  late MockApi mock;
  late FakeClock clock;
  late AutomationApiService api;

  setUp(() {
    mock = MockApi();
    clock = FakeClock();
    api = AutomationApiService(baseUrl: 'http://192.168.1.30', localKey: 'devicekey-1234', client: mock.client, clock: clock);
  });

  tearDown(() => api.dispose());

  /// Anahtarlı tam `GET /api/status` yanıtı (alan listesi CONTRACTS §3b).
  Map<String, dynamic> fullStatus({
    String connectState = 'idle',
    int connectReason = 0,
    bool wifiConnected = false,
    String staIp = '',
    bool mqttConnected = false,
    bool childLock = false,
  }) =>
      <String, dynamic>{
        'device': 'AHBU-S3-A1B2C3',
        'name': 'Salon Panosu',
        'device_name': 'Salon Panosu',
        'fw': '1.1.0',
        'provisioned': true,
        'ip': '192.168.1.30',
        'wifi_rssi': -55,
        'uptime_sec': 120,
        'wifi_connected': wifiConnected,
        'wifi_sta_ssid': 'EvAgi',
        'wifi_sta_ip': staIp,
        'wifi_sta_rssi': -55,
        'wifi_ap_active': true,
        'wifi_ap_ip': '192.168.4.1',
        'wifi_ap_ssid': 'AHBU-A1B2C3',
        'wifi_last_reason': 0,
        'wifi_connect_state': connectState,
        'wifi_connect_reason': connectReason,
        'time_synced': true,
        'mqtt_configured': true,
        'mqtt_connected': mqttConnected,
        'ext_module_enabled': false,
        'ext_module_channels': 0,
        'ext_module_address': 1,
        'ext_module_responding': false,
        'total_relays': 8,
        'total_dis': 8,
        'child_lock': childLock,
        'last_id': '',
        'relays': <Map<String, dynamic>>[
          <String, dynamic>{'id': 1, 'name': 'Avize', 'type': 0, 'state': true},
          <String, dynamic>{'id': 2, 'name': 'Spot', 'type': 0, 'state': false},
          <String, dynamic>{'id': 3, 'name': 'Salon Panjur Yukarı', 'type': 1, 'state': false},
          <String, dynamic>{'id': 4, 'name': 'Salon Panjur Aşağı', 'type': 2, 'state': false},
        ],
        'shutters': <Map<String, dynamic>>[
          <String, dynamic>{'pair': 1, 'is_shutter': false, 'is_moving': false, 'moving': false, 'dir': 0, 'pos': 0, 'target': 255},
          <String, dynamic>{'pair': 2, 'is_shutter': true, 'is_moving': false, 'moving': false, 'dir': 0, 'pos': 40, 'target': 255},
        ],
        'dis': <Map<String, dynamic>>[
          <String, dynamic>{'id': 1, 'name': 'Giriş 1', 'state': false},
        ],
      };

  group('ana makine (adres) kuralları', () {
    test('izinli adresler', () {
      for (final host in <String>[
        '192.168.1.30',
        '192.168.1.30:80',
        'http://192.168.1.30',
        'http://192.168.1.30/',
        'https://192.168.1.30', // cihaz TLS konuşmaz: http'ye çevrilir
        '10.0.2.2:8081', // Android emülatörü -> geliştirici makinesi
        '172.16.0.1',
        '172.31.255.255',
        '169.254.10.10',
        '127.0.0.1:8081',
        '100.64.0.1',
        'localhost',
        'localhost:8081',
        'pano.local',
        'ev-panosu.local',
        'ABC.LOCAL',
      ]) {
        final service = AutomationApiService(baseUrl: '');
        service.updateHost(host);
        expect(service.isConfigured, isTrue, reason: host);
        expect(service.baseUrl.startsWith('http://'), isTrue, reason: host);
        service.dispose();
      }
    });

    test('https:// öneki http:// olarak normalleştirilir; sondaki / atılır', () {
      api.updateHost('https://192.168.1.30/');
      expect(api.baseUrl, 'http://192.168.1.30');
    });

    test('reddedilen adresler: adres "ayarlanmadı" olur (başka adrese sessizce gidilmez)', () {
      for (final host in <String>[
        'example.com',
        'cihaz.example.com',
        '8.8.8.8',
        '1.2.3.4',
        '172.32.0.1',
        '172.15.0.1',
        '192.169.1.1',
        '100.128.0.1',
        '192.168.1',
        '192.168.1.300',
        '192.168.1.30:99999',
        '192.168.1.30:0',
        '192.168.1.30/api',
        '192.168.1.30?x=1',
        'user@192.168.1.30',
        'ftp://192.168.1.30',
        'localhost.evil.com',
        'pano.local.evil.com',
        '.local',
        '[::1]',
        '::1',
        '192.168.1.30 evil',
        'http://',
      ]) {
        final service = AutomationApiService(baseUrl: 'http://192.168.1.30');
        service.updateHost(host);
        expect(service.isConfigured, isFalse, reason: host);
        service.dispose();
      }
    });

    test('isAllowedDeviceHost doğrudan', () {
      expect(AutomationApiService.isAllowedDeviceHost('192.168.4.1'), isTrue);
      expect(AutomationApiService.isAllowedDeviceHost('evotomasyon.gudeteknoloji.com.tr'), isFalse);
      expect(AutomationApiService.isAllowedDeviceHost(''), isFalse);
    });

    test('boş adres adresi temizler; yapılandırılmamış istemci ağa çıkmaz', () async {
      api.updateHost('');
      expect(api.isConfigured, isFalse);
      await expectLater(
        api.fetchStatus(),
        throwsA(isA<LocalApiException>().having((e) => e.code, 'code', 'not_configured')),
      );
      expect(mock.requests, isEmpty);
    });
  });

  group('kimlik başlığı ve içerik türü', () {
    test('anahtarlı GET ve JSON gövdeli POST: X-Device-Key + Content-Type', () async {
      mock
        ..on('GET', '/api/status', (r) => jsonResponse(fullStatus()))
        ..on('POST', '/api/child-lock', (r) => jsonResponse(<String, dynamic>{'status': 'queued'}));
      await api.fetchStatus();
      await api.setChildLock(true);

      expect(mock.requests[0].headers['X-Device-Key'], 'devicekey-1234');
      final post = mock.requests[1];
      expect(post.headers['X-Device-Key'], 'devicekey-1234');
      expect(post.headers['Content-Type'], contains('application/json'));
      expect(post.json, <String, dynamic>{'enabled': true});
    });

    test('fetchPublicStatus anahtar GÖNDERMEZ (yanlış anahtar kilidine takılmaz)', () async {
      mock.on('GET', '/api/status', (r) => jsonResponse(<String, dynamic>{
            'device': 'AHBU-S3-A1B2C3',
            'name': 'Pano',
            'fw': '1.1.0',
            'provisioned': true,
            'wifi_connected': true,
          }));
      final status = await api.fetchPublicStatus();
      expect(mock.requests.single.headers.containsKey('X-Device-Key'), isFalse);
      expect(status.restricted, isTrue);
      expect(status.provisioned, isTrue);
      expect(status.uid, 'AHBU-S3-A1B2C3');
      expect(status.relays, isEmpty);
    });

    test('anahtar tanımlı değilse başlık hiç gönderilmez', () async {
      api.localKey = null;
      mock.on('GET', '/api/status', (r) => jsonResponse(<String, dynamic>{'provisioned': true}));
      await api.fetchStatus();
      expect(mock.requests.single.headers.containsKey('X-Device-Key'), isFalse);
    });
  });

  group('durum çözümleme (GET /api/status)', () {
    test('anahtarlı tam yanıt: uid `device` alanından, hayalet panjur `is_shutter:false` ile atılır', () async {
      mock.on('GET', '/api/status', (r) => jsonResponse(fullStatus(wifiConnected: true, staIp: '192.168.1.30', mqttConnected: true)));
      final st = await api.fetchStatus();

      expect(st.restricted, isFalse);
      expect(st.uid, 'AHBU-S3-A1B2C3', reason: 'LAN status uid taşımaz; kimlik `device` alanındadır');
      expect(st.deviceName, 'Salon Panosu');
      expect(st.firmware, '1.1.0');
      expect(st.provisioned, isTrue);
      expect(st.shutters.map((s) => s.pair), <int>[2], reason: 'pair 1: is_shutter=false');
      expect(st.shutters.single.pos, 40);
      expect(st.shutters.single.target, isNull, reason: '255 = hedef yok');
      expect(st.mqttConfigured, isTrue);
      expect(st.mqttConnected, isTrue);
      expect(st.timeSynced, isTrue);
      expect(st.wifiApActive, isTrue);
      expect(st.wifiApSsid, 'AHBU-A1B2C3');
      expect(st.totalRelays, 8);
      expect(st.extModuleEnabled, isFalse);
      expect(st.childLockKnown, isTrue);
    });

    test('kısıtlı özet (anahtarsız): restricted + provisioned; röle listesi yok', () async {
      mock.on('GET', '/api/status', (r) => jsonResponse(<String, dynamic>{
            'device': 'AHBU-S3-A1B2C3',
            'name': 'Pano',
            'fw': '1.1.0',
            'provisioned': false,
            'wifi_connected': false,
          }));
      final st = await api.fetchStatus();
      expect(st.restricted, isTrue);
      expect(st.provisioned, isFalse);
      expect(st.childLockKnown, isFalse, reason: 'özet çocuk kilidi bilgisi vermez');
      expect(st.deviceName, 'Pano');
    });

    test('`device` kimlik değilse (eski bellenim) ad olarak kullanılır', () {
      final st = DeviceStatus.fromJson(<String, dynamic>{'device': 'Salon Panosu', 'relays': <dynamic>[]});
      expect(st.deviceName, 'Salon Panosu');
      expect(st.uid, isNull);
    });

    test('wifi_connect_state tüm değerleri; bilinmeyen değer = unknown', () {
      for (final entry in <String, WifiConnectState>{
        'idle': WifiConnectState.idle,
        'connecting': WifiConnectState.connecting,
        'success': WifiConnectState.success,
        'failed': WifiConnectState.failed,
        'SUCCESS': WifiConnectState.success,
        'weird': WifiConnectState.unknown,
      }.entries) {
        expect(WifiConnectState.parse(entry.key), entry.value, reason: entry.key);
      }
      expect(WifiConnectState.parse(null), WifiConnectState.unknown);
      expect(WifiConnectState.success.isFinal, isTrue);
      expect(WifiConnectState.connecting.isFinal, isFalse);
    });

    test('değişmeyen durum sameAs; Wi-Fi bağlanma durumu / MQTT bağlantısı değişimi sameAs=false', () {
      final a = DeviceStatus.fromJson(fullStatus());
      final b = DeviceStatus.fromJson(fullStatus());
      expect(a.sameAs(b), isTrue);
      expect(a.sameAs(DeviceStatus.fromJson(fullStatus(connectState: 'connecting'))), isFalse);
      expect(a.sameAs(DeviceStatus.fromJson(fullStatus(mqttConnected: true))), isFalse);
    });
  });

  group('hata eşlemesi (CONTRACTS §3b)', () {
    Future<LocalApiException> failWith(int status, Map<String, dynamic> body, {Map<String, String>? headers, String path = '/api/status'}) async {
      mock.on('GET', path, (r) => jsonResponse(body, status: status, headers: headers));
      try {
        await api.fetchStatus();
      } on LocalApiException catch (e) {
        return e;
      }
      fail('LocalApiException bekleniyordu');
    }

    test('401 unauthorized', () async {
      final e = await failWith(401, <String, dynamic>{'error': 'unauthorized'});
      expect(e.isUnauthorized, isTrue);
      expect(e.message, contains('anahtar'));
    });

    test('423 locked: retry_after gövdeden veya Retry-After başlığından', () async {
      final fromBody = await failWith(423, <String, dynamic>{'error': 'locked', 'retry_after': 60});
      expect(fromBody.isLocked, isTrue);
      expect(fromBody.retryAfter, const Duration(seconds: 60));

      final fromHeader = await failWith(423, <String, dynamic>{'error': 'locked'}, headers: <String, String>{'Retry-After': '45'});
      expect(fromHeader.retryAfter, const Duration(seconds: 45));
    });

    test('403 unprovisioned / already_provisioned / bad_origin', () async {
      expect((await failWith(403, <String, dynamic>{'error': 'unprovisioned'})).isUnprovisioned, isTrue);
      final already = await failWith(403, <String, dynamic>{'error': 'already_provisioned'});
      expect(already.isAlreadyProvisioned, isTrue);
      expect(already.message, contains('kurulmuş'));
      final origin = await failWith(403, <String, dynamic>{'error': 'bad_origin'});
      expect(origin.isHostRejected, isTrue);
    });

    test('409 busy ve 503 busy|queue_full = meşgul (yeniden denenebilir); 503 storage değil', () async {
      expect((await failWith(409, <String, dynamic>{'error': 'busy'})).isBusy, isTrue);
      expect((await failWith(503, <String, dynamic>{'error': 'busy'})).isBusy, isTrue);
      expect((await failWith(503, <String, dynamic>{'error': 'queue_full'})).isBusy, isTrue);
      final storage = await failWith(503, <String, dynamic>{'error': 'storage'});
      expect(storage.isBusy, isFalse);
      expect(storage.message, contains('belleğine'));
    });

    test('400 hata kodları Türkçe mesaja eşlenir; bilinmeyen kod genel mesaj', () async {
      expect((await failWith(400, <String, dynamic>{'error': 'invalid_ssid'})).message, contains('Ağ adı'));
      expect((await failWith(400, <String, dynamic>{'error': 'invalid_password'})).message, contains('şifre'));
      expect((await failWith(400, <String, dynamic>{'error': 'invalid_key'})).message, contains('anahtar'));
      expect((await failWith(400, <String, dynamic>{'error': 'invalid_ap_pass'})).message, contains('parola'));
      expect((await failWith(400, <String, dynamic>{'error': 'unknown_command'})).message, contains('tanımıyor'));
      final bad = await failWith(400, <String, dynamic>{'error': 'bad_host'});
      expect(bad.isHostRejected, isTrue);
      expect(bad.isInvalidInput, isTrue);
      expect((await failWith(400, <String, dynamic>{'error': 'xyz'})).message, 'Cihaz isteği kabul etmedi.');
    });

    test('413 / 415 / 502 / gövdesiz 500 genel mesajlar; gövde bozuk olsa da çökmez', () async {
      expect((await failWith(413, <String, dynamic>{'error': 'too_large'})).message, contains('büyük'));
      expect((await failWith(415, <String, dynamic>{})).message, contains('içerik'));
      expect((await failWith(502, <String, dynamic>{'error': 'rs485'})).message, contains('genişleme'));
      mock.on('GET', '/api/status', (r) => http.Response('<html>oops</html>', 500));
      await expectLater(api.fetchStatus(), throwsA(isA<LocalApiException>().having((e) => e.statusCode, 'status', 500)));
    });

    test('ağ hatası / zaman aşımı: isNetwork', () async {
      mock.on('GET', '/api/status', (r) => throw http.ClientException('bağlantı reddedildi'));
      await expectLater(api.fetchStatus(), throwsA(isA<LocalApiException>().having((e) => e.isNetwork, 'network', isTrue)));

      mock.on('GET', '/api/status', (r) => throw const SocketException('ulaşılamıyor'));
      await expectLater(api.fetchStatus(), throwsA(isA<LocalApiException>().having((e) => e.isNetwork, 'network', isTrue)));
    });
  });

  group('Wi-Fi: tarama ve bağlanma', () {
    test('scanWifi: scanning sonrası done; sinyale göre sıralı, aynı adlılar tekil, gizli ağlar atılır', () async {
      var calls = 0;
      mock.on('GET', '/api/wifi/scan', (r) {
        calls++;
        if (calls == 1) return jsonResponse(<String, dynamic>{'status': 'scanning'});
        return jsonResponse(<String, dynamic>{
          'status': 'done',
          'cached': false,
          'networks': <Map<String, dynamic>>[
            <String, dynamic>{'ssid': 'EvAgi', 'rssi': -70, 'enc': true},
            <String, dynamic>{'ssid': 'EvAgi', 'rssi': -50, 'enc': true},
            <String, dynamic>{'ssid': 'Misafir', 'rssi': -60, 'enc': false},
            <String, dynamic>{'ssid': '', 'rssi': -30, 'enc': true},
            <String, dynamic>{'rssi': -20, 'enc': true},
          ],
        });
      });
      final future = api.scanWifi(refresh: true);
      await clock.elapse(const Duration(seconds: 3));
      final networks = await future;

      expect(calls, 2);
      expect(networks.map((n) => n.ssid), <String>['EvAgi', 'Misafir']);
      expect(networks.first.rssi, -50);
      expect(networks.first.secured, isTrue);
      expect(networks.last.secured, isFalse);
      expect(mock.requests.first.url.queryParameters['refresh'], '1', reason: 'yalnızca ilk istekte refresh');
      expect(mock.requests[1].url.queryParameters.containsKey('refresh'), isFalse);
    });

    test('geçersiz UTF-8 SSID çökertmez (allowMalformed): değiştirme karakteri', () async {
      final bytes = <int>[
        ...utf8.encode('{"status":"done","cached":true,"networks":[{"ssid":"Ev'),
        0xFF, 0xFE,
        ...utf8.encode('Agi","rssi":-40,"enc":true}]}'),
      ];
      mock.on('GET', '/api/wifi/scan', (r) => http.Response.bytes(bytes, 200, headers: <String, String>{'content-type': 'application/json'}));
      final networks = await api.scanWifi();
      expect(networks.single.ssid, startsWith('Ev'));
      expect(networks.single.ssid, contains('�'));
    });

    test('tarama hiç bitmezse zaman aşımı hatası; iptal edilirse cancelled', () async {
      mock.on('GET', '/api/wifi/scan', (r) => jsonResponse(<String, dynamic>{'status': 'scanning'}));
      final future = api.scanWifiNetworks();
      final expectation = expectLater(future, throwsA(isA<LocalApiException>().having((e) => e.code, 'code', 'timeout')));
      await clock.elapse(const Duration(seconds: 30));
      await expectation;

      var cancel = false;
      final cancelled = api.scanWifiNetworks(isCancelled: () => cancel);
      final cancelledExpectation = expectLater(cancelled, throwsA(isA<LocalApiException>().having((e) => e.isCancelled, 'cancelled', isTrue)));
      cancel = true;
      await clock.elapse(const Duration(seconds: 3));
      await cancelledExpectation;
    });

    test('connectWifi: gövde SSID/parola kırpılmadan gider; 200 connecting yanıtı bağlandı demek değildir', () async {
      mock.on('POST', '/api/wifi/connect', (r) => jsonResponse(<String, dynamic>{'status': 'connecting'}));
      await api.connectWifi(' Ev Agi ', ' parola 123 ');
      expect(mock.requests.single.json, <String, dynamic>{'ssid': ' Ev Agi ', 'pass': ' parola 123 '});
      expect(mock.requests.single.headers['X-Device-Key'], 'devicekey-1234');
    });

    test('connectWifi doğrulamaları ağa gitmeden reddeder (SSID ≤ 32 bayt, WPA 8–63)', () async {
      for (final args in <(String, String)>[
        ('', 'parola1234'),
        ('a' * 33, 'parola1234'),
        ('ağ' * 17, 'parola1234'), // 34 bayt
        ('EvAgi', 'kisa'),
        ('EvAgi', 'p' * 64),
      ]) {
        await expectLater(api.connectWifi(args.$1, args.$2), throwsA(isA<LocalApiException>().having((e) => e.isInvalidInput, 'invalid', isTrue)), reason: '${args.$1.length}/${args.$2.length}');
      }
      // Açık ağ (boş parola) ve 32 baytlık SSID geçerli
      mock.on('POST', '/api/wifi/connect', (r) => jsonResponse(<String, dynamic>{'status': 'connecting'}));
      await api.connectWifi('a' * 32, '');
      expect(mock.count('POST', '/api/wifi/connect'), 1);
    });

    test('connectWifi 409 busy: meşgul hatası', () async {
      mock.on('POST', '/api/wifi/connect', (r) => jsonResponse(<String, dynamic>{'error': 'busy'}, status: 409));
      await expectLater(api.connectWifi('EvAgi', 'parola1234'), throwsA(isA<LocalApiException>().having((e) => e.isBusy, 'busy', isTrue)));
    });

    group('awaitWifiConnection', () {
      /// `GET /api/status` yanıtlarını sırayla verir.
      void statusSequence(List<Map<String, dynamic>> bodies) {
        var i = 0;
        mock.on('GET', '/api/status', (r) {
          final body = bodies[i < bodies.length ? i : bodies.length - 1];
          i++;
          return jsonResponse(body);
        });
      }

      test('connecting -> success: başarı ve pano IP adresi', () async {
        statusSequence(<Map<String, dynamic>>[
          fullStatus(connectState: 'connecting'),
          fullStatus(connectState: 'connecting'),
          fullStatus(connectState: 'success', wifiConnected: true, staIp: '192.168.1.77'),
        ]);
        final future = api.awaitWifiConnection(timeout: const Duration(seconds: 30));
        await clock.elapse(const Duration(seconds: 10));
        final result = await future;
        expect(result.outcome, WifiConnectOutcome.success);
        expect(result.isSuccess, isTrue);
        expect(result.ipAddress, '192.168.1.77');
        expect(result.message, contains('bağlandı'));
      });

      test('failed: neden kodu ve Türkçe mesaj (yanlış şifre / ağ yok)', () async {
        statusSequence(<Map<String, dynamic>>[fullStatus(connectState: 'failed', connectReason: 202)]);
        var result = await api.awaitWifiConnection();
        expect(result.outcome, WifiConnectOutcome.failed);
        expect(result.reason, 202);
        expect(result.message, contains('şifre'));

        expect(WifiConnectResult.failureMessage(201), contains('Ağ bulunamadı'));
        expect(WifiConnectResult.failureMessage(0), contains('zaman aşımı'));
        expect(WifiConnectResult.failureMessage(99), contains('99'));
      });

      test('süre dolarsa timedOut (state hâlâ connecting)', () async {
        statusSequence(<Map<String, dynamic>>[fullStatus(connectState: 'connecting')]);
        final future = api.awaitWifiConnection(timeout: const Duration(seconds: 6), interval: const Duration(seconds: 1));
        await clock.elapse(const Duration(seconds: 10));
        final result = await future;
        expect(result.outcome, WifiConnectOutcome.timedOut);
        expect(result.message, contains('zaman aşımı'));
        expect(mock.count('GET', '/api/status'), greaterThanOrEqualTo(4));
      });

      test('bağlantı koptu (pano AP\'yi kapattı): belirsiz sonuç, başarısızlık SANILMAZ', () async {
        var calls = 0;
        mock.on('GET', '/api/status', (r) {
          calls++;
          if (calls == 1) return jsonResponse(fullStatus(connectState: 'connecting'));
          throw http.ClientException('connection closed');
        });
        final future = api.awaitWifiConnection(timeout: const Duration(seconds: 30));
        await clock.elapse(const Duration(seconds: 5));
        final result = await future;
        expect(result.outcome, WifiConnectOutcome.lostContact);
        expect(result.isSuccess, isFalse);
        expect(result.message, contains('ev ağına'));
      });

      test('hiç durum okunamadıysa geçici ağ hatasında yeniden dener; sonra başarı', () async {
        var calls = 0;
        mock.on('GET', '/api/status', (r) {
          calls++;
          if (calls <= 2) throw http.ClientException('henüz hazır değil');
          return jsonResponse(fullStatus(connectState: 'success', staIp: '192.168.1.90'));
        });
        final future = api.awaitWifiConnection(timeout: const Duration(seconds: 30));
        await clock.elapse(const Duration(seconds: 10));
        expect((await future).outcome, WifiConnectOutcome.success);
        expect(calls, 3);
      });

      test('yetki / kilit hataları yeniden fırlatılır (401, 423)', () async {
        mock.on('GET', '/api/status', (r) => jsonResponse(<String, dynamic>{'error': 'unauthorized'}, status: 401));
        await expectLater(api.awaitWifiConnection(), throwsA(isA<LocalApiException>().having((e) => e.isUnauthorized, 'unauthorized', isTrue)));
        mock.on('GET', '/api/status', (r) => jsonResponse(<String, dynamic>{'error': 'locked', 'retry_after': 60}, status: 423));
        await expectLater(api.awaitWifiConnection(), throwsA(isA<LocalApiException>().having((e) => e.isLocked, 'locked', isTrue)));
      });

      test('iptal: LocalApiException.cancelled', () async {
        statusSequence(<Map<String, dynamic>>[fullStatus(connectState: 'connecting')]);
        var cancel = false;
        final future = api.awaitWifiConnection(isCancelled: () => cancel);
        final expectation = expectLater(future, throwsA(isA<LocalApiException>().having((e) => e.isCancelled, 'cancelled', isTrue)));
        await clock.elapse(const Duration(seconds: 2));
        cancel = true;
        await clock.elapse(const Duration(seconds: 2));
        await expectation;
      });

      test('connectWifiAndWait: önce POST sonra yoklama', () async {
        mock.on('POST', '/api/wifi/connect', (r) => jsonResponse(<String, dynamic>{'status': 'connecting'}));
        statusSequence(<Map<String, dynamic>>[fullStatus(connectState: 'success', staIp: '192.168.1.5')]);
        final result = await api.connectWifiAndWait('EvAgi', 'parola1234');
        expect(result.isSuccess, isTrue);
        final order = mock.requests.map((r) => '${r.method} ${r.path}').toList();
        expect(order.first, 'POST /api/wifi/connect');
        expect(order.last, 'GET /api/status');
      });
    });
  });

  group('provizyon uçları', () {
    test('factoryInit: anahtar başlığı GÖNDERİLMEZ; gövde local_key + ap_pass; başarıda localKey ayarlanır', () async {
      api.localKey = null;
      mock.on('POST', '/api/factory/init', (r) => jsonResponse(<String, dynamic>{'status': 'ok'}));
      await api.factoryInit(localKey: 'yeni-anahtar-123', apPass: 'ap-parola-99');

      final request = mock.requests.single;
      expect(request.headers.containsKey('X-Device-Key'), isFalse);
      expect(request.headers['Content-Type'], contains('application/json'));
      expect(request.json, <String, dynamic>{'local_key': 'yeni-anahtar-123', 'ap_pass': 'ap-parola-99'});
      expect(api.localKey, 'yeni-anahtar-123');
    });

    test('factoryInit: eski anahtar tanımlıyken de başlık gönderilmez', () async {
      mock.on('POST', '/api/factory/init', (r) => jsonResponse(<String, dynamic>{'status': 'ok'}));
      await api.factoryInit(localKey: 'yeni-anahtar-123', apPass: 'ap-parola-99');
      expect(mock.requests.single.headers.containsKey('X-Device-Key'), isFalse);
    });

    test('factoryInit: doğrulama ağa gitmeden (anahtar 8–32 görünür ASCII, ap_pass 8–32)', () async {
      api.localKey = null;
      for (final args in <(String, String)>[
        ('kisa', 'ap-parola-99'),
        ('k' * 33, 'ap-parola-99'),
        ('boşluk var 1234', 'ap-parola-99'),
        ('türkçe-anahtar-1', 'ap-parola-99'),
        ('yeni-anahtar-123', 'kisa'),
        ('yeni-anahtar-123', 'p' * 33),
      ]) {
        await expectLater(api.factoryInit(localKey: args.$1, apPass: args.$2), throwsA(isA<LocalApiException>().having((e) => e.isInvalidInput, 'invalid', isTrue)));
      }
      expect(mock.requests, isEmpty);
      expect(api.localKey, isNull);
    });

    test('factoryInit: cihaz zaten kuruluysa 403 already_provisioned ve localKey DEĞİŞMEZ', () async {
      mock.on('POST', '/api/factory/init', (r) => jsonResponse(<String, dynamic>{'error': 'already_provisioned'}, status: 403));
      await expectLater(
        api.factoryInit(localKey: 'yeni-anahtar-123', apPass: 'ap-parola-99'),
        throwsA(isA<LocalApiException>().having((e) => e.isAlreadyProvisioned, 'already', isTrue)),
      );
      expect(api.localKey, 'devicekey-1234');
    });

    test('rekey: mevcut anahtarla yeni anahtarı yazar; başarıda localKey güncellenir, hatada değişmez', () async {
      mock.on('POST', '/api/auth/rekey', (r) => jsonResponse(<String, dynamic>{'status': 'ok'}));
      await api.rekey('degisen-anahtar-1');
      expect(mock.requests.single.headers['X-Device-Key'], 'devicekey-1234', reason: 'istek ESKİ anahtarla imzalanır');
      expect(mock.requests.single.json, <String, dynamic>{'local_key': 'degisen-anahtar-1'});
      expect(api.localKey, 'degisen-anahtar-1');

      mock.on('POST', '/api/auth/rekey', (r) => jsonResponse(<String, dynamic>{'error': 'storage_error'}, status: 500));
      await expectLater(api.rekey('baska-anahtar-123'), throwsA(isA<LocalApiException>()));
      expect(api.localKey, 'degisen-anahtar-1');

      await expectLater(api.rekey('kisa'), throwsA(isA<LocalApiException>().having((e) => e.isInvalidInput, 'invalid', isTrue)));
    });

    test('checkKey: kabul = true, yanlış anahtar (401) = false; kilit (423) ve ağ hatası fırlatılır', () async {
      mock.on('GET', '/api/auth/check', (r) => jsonResponse(<String, dynamic>{'status': 'ok'}));
      expect(await api.checkKey(), isTrue);

      mock.on('GET', '/api/auth/check', (r) => jsonResponse(<String, dynamic>{'error': 'unauthorized'}, status: 401));
      expect(await api.checkKey(), isFalse);

      mock.on('GET', '/api/auth/check', (r) => jsonResponse(<String, dynamic>{'error': 'locked', 'retry_after': 60}, status: 423));
      await expectLater(api.checkKey(), throwsA(isA<LocalApiException>().having((e) => e.isLocked, 'locked', isTrue)));

      mock.on('GET', '/api/auth/check', (r) => jsonResponse(<String, dynamic>{'error': 'unprovisioned'}, status: 403));
      await expectLater(api.checkKey(), throwsA(isA<LocalApiException>().having((e) => e.isUnprovisioned, 'unprovisioned', isTrue)));
    });

    test('configureMqtt: gövde {server,port,user,pass} + anahtar başlığı; parola hata mesajına sızmaz', () async {
      const credential = DeviceMqttCredential(
        host: 'broker.example.test',
        port: 8884,
        username: 'd_h_abc123',
        password: 'sifre-yer-tutucu-xyz',
        topicId: 'h_abc123',
      );
      mock.on('POST', '/api/mqtt/config', (r) => jsonResponse(<String, dynamic>{'status': 'ok'}));
      await api.configureMqtt(credential);

      expect(mock.requests.single.json, <String, dynamic>{
        'server': 'broker.example.test',
        'port': 8884,
        'user': 'd_h_abc123',
        'pass': 'sifre-yer-tutucu-xyz',
      });
      expect(mock.requests.single.headers['X-Device-Key'], 'devicekey-1234');

      mock.on('POST', '/api/mqtt/config', (r) => jsonResponse(<String, dynamic>{'error': 'invalid_value'}, status: 400));
      try {
        await api.configureMqtt(credential);
        fail('hata bekleniyordu');
      } on LocalApiException catch (e) {
        expect(e.toString(), isNot(contains('sifre-yer-tutucu-xyz')));
        expect(e.message, isNot(contains('sifre-yer-tutucu-xyz')));
      }
    });

    test('configureMqtt: cihaz sınırları (ana makine, port, kullanıcı ≤ 47, parola ≤ 63 bayt) ağa gitmeden doğrulanır', () async {
      DeviceMqttCredential c({String host = 'broker.example.test', int port = 8884, String user = 'd_x', String pass = 'p'}) =>
          DeviceMqttCredential(host: host, port: port, username: user, password: pass, topicId: 'h_x');
      for (final bad in <DeviceMqttCredential>[
        c(host: 'bad host'),
        c(host: 'a/b'),
        c(host: ''),
        c(port: 0),
        c(port: 70000),
        c(user: ''),
        c(user: 'u' * 48),
        c(pass: ''),
        c(pass: 'p' * 64),
      ]) {
        await expectLater(api.configureMqtt(bad), throwsA(isA<LocalApiException>().having((e) => e.isInvalidInput, 'invalid', isTrue)));
      }
      expect(mock.requests, isEmpty);
      mock.on('POST', '/api/mqtt/config', (r) => jsonResponse(<String, dynamic>{'status': 'ok'}));
      await api.configureMqtt(c(user: 'u' * 47, pass: 'p' * 63));
      expect(mock.count('POST', '/api/mqtt/config'), 1);
    });
  });

  group('çocuk kilidi (LAN)', () {
    test('fetchChildLock: {"child_lock":bool}; alan yoksa fırlatır (kilitsiz sanılmaz)', () async {
      mock.on('GET', '/api/child-lock', (r) => jsonResponse(<String, dynamic>{'child_lock': true}));
      expect(await api.fetchChildLock(), isTrue);
      mock.on('GET', '/api/child-lock', (r) => jsonResponse(<String, dynamic>{'child_lock': false}));
      expect(await api.fetchChildLock(), isFalse);

      mock.on('GET', '/api/child-lock', (r) => jsonResponse(<String, dynamic>{'status': 'ok'}));
      await expectLater(api.fetchChildLock(), throwsA(isA<LocalApiException>()));
      mock.on('GET', '/api/child-lock', (r) => jsonResponse(<String, dynamic>{'error': 'unauthorized'}, status: 401));
      await expectLater(api.fetchChildLock(), throwsA(isA<LocalApiException>().having((e) => e.isUnauthorized, 'unauthorized', isTrue)));
    });
  });

  group('komutlar (1 tabanlı numaralar, `val` zorunlu)', () {
    setUp(() {
      mock.on('POST', '/api/relay', (r) => jsonResponse(<String, dynamic>{'status': 'ok'}));
      mock.on('POST', '/api/all', (r) => jsonResponse(<String, dynamic>{'status': 'ok'}));
    });

    test('setRelay / toggleRelay sorgu parametreleri', () async {
      await api.setRelay(3, true);
      await api.toggleRelay(5);
      expect(mock.requests[0].url.queryParameters, <String, String>{'ch': '3', 'state': '1'});
      expect(mock.requests[1].url.queryParameters, <String, String>{'ch': '5', 'cmd': 'toggle'});
    });

    test('panjur: pair 1 tabanlı; pos için val zorunlu ve 0..100', () async {
      await api.cmdShutter(2, 'up');
      await api.setShutterPosition(2, 40);
      expect(mock.requests[0].url.queryParameters, <String, String>{'pair': '2', 'cmd': 'up'});
      expect(mock.requests[1].url.queryParameters, <String, String>{'pair': '2', 'cmd': 'pos', 'val': '40'});

      for (final bad in <Future<bool> Function()>[
        () => api.cmdShutter(0, 'up'),
        () => api.cmdShutter(33, 'up'),
        () => api.cmdShutter(1, 'jump'),
        () => api.cmdShutter(1, 'pos'),
        () => api.cmdShutter(1, 'pos', value: -1),
        () => api.cmdShutter(1, 'pos', value: 101),
      ]) {
        await expectLater(bad(), throwsA(isA<LocalApiException>().having((e) => e.isInvalidInput, 'invalid', isTrue)));
      }
      expect(mock.requests, hasLength(2), reason: 'geçersiz istekler cihaza gitmez');
    });

    test('röle numarası 1..64; toplu komutlar eşanlamlıları normalleştirir', () async {
      await expectLater(api.setRelay(0, true), throwsA(isA<LocalApiException>()));
      await expectLater(api.toggleRelay(65), throwsA(isA<LocalApiException>()));
      await api.cmdAll('all_lights_off');
      await api.cmdAll('all_shutters_down');
      expect(mock.requests[0].url.queryParameters['cmd'], 'lightsoff');
      expect(mock.requests[1].url.queryParameters['cmd'], 'shuttersdown');
      await expectLater(api.cmdAll('bilinmeyen'), throwsA(isA<LocalApiException>()));
    });
  });

  group('doğrudan mod durum akışı (AutomationState)', () {
    Future<StateHarness> lan({Map<String, dynamic>? status}) async {
      // Oturum açık + bulut hazır. Aktif evin panosu adresteki pano (kullanim-3: başka evin panosu gösterilmez).
      final h = await readyHarness(
        configure: (h) => h.cloud.devicesByHome[kHomeA] = <DeviceInfo>[
          const DeviceInfo(deviceUuid: 'AHBU-S3-A1B2C3', name: 'Pano', online: true, firmware: '1.1.0'),
        ],
      );
      h.directMock.on('GET', '/api/status', (r) => jsonResponse(status ?? fullStatus()));
      await h.state.setMode(AppMode.direct);
      await h.state.setHost('192.168.1.30');
      h.direct.localKey = 'devicekey-1234';
      await h.state.refresh();
      return h;
    }

    test('kısıtlı özet: cihaz erişilebilir ama kontrol edilemez; "anahtar gerekli" mesajı, boş cihaz gösterilmez', () async {
      final h = await lan(status: <String, dynamic>{
        'device': 'AHBU-S3-A1B2C3',
        'name': 'Pano',
        'fw': '1.1.0',
        'provisioned': true,
        'wifi_connected': true,
      });
      addTearDown(h.dispose);
      expect(h.state.status, isNull);
      expect(h.state.connState, ConnectionStateEnum.connected);
      expect(h.state.directError, contains('anahtar'));
    });

    // bireysel-13: servis rolü olmayan kullanıcıya açamayacağı servis sihirbazı değil, satıcı / servis yolu söylenir.
    test('kısıtlı özet + provisioned:false: hazırlanmamış pano mesajı (servis rolü olmayan kullanıcı)', () async {
      final h = await lan(status: <String, dynamic>{
        'device': 'AHBU-S3-A1B2C3',
        'name': 'Pano',
        'fw': '1.1.0',
        'provisioned': false,
        'wifi_connected': false,
      });
      addTearDown(h.dispose);
      expect(h.state.status, isNull);
      expect(h.state.directError, kUnprovisionedBoardUserMessage);
    });

    test('tam durum: kimlik `device` alanından, hayalet panjur süzülmüş, hata temizlenir', () async {
      final h = await lan();
      addTearDown(h.dispose);
      expect(h.state.directError, isNull);
      expect(h.state.status?.uid, 'AHBU-S3-A1B2C3');
      expect(h.state.shutterItems.map((s) => s.pair), <int>[2]);
    });

    test('selectDevice / updateSelectedDeviceIp: geçersiz (internet) adres reddedilir, önceki adres korunur', () async {
      final h = await lan();
      addTearDown(h.dispose);
      final before = h.state.host;
      await expectLater(
        h.state.selectDevice(uuid: 'AHBU-S3-A1B2C3', ip: 'cihaz.example.com'),
        throwsA(isA<ApiException>().having((e) => e.isValidation, 'validation', isTrue)),
      );
      await expectLater(
        h.state.updateSelectedDeviceIp('8.8.8.8'),
        throwsA(isA<ApiException>().having((e) => e.isValidation, 'validation', isTrue)),
      );
      expect(h.state.host, before);
      expect(h.direct.isConfigured, isTrue);

      await h.state.selectDevice(uuid: 'AHBU-S3-A1B2C3', ip: '192.168.1.31');
      expect(h.state.host, '192.168.1.31');
      expect(h.state.selectedDeviceUuid, 'AHBU-S3-A1B2C3');
    });

    test('setHost: geçersiz adres doğrulama hatası; önceki adres korunur', () async {
      final h = await lan();
      addTearDown(h.dispose);
      await expectLater(h.state.setHost('evil.example.com'), throwsA(isA<ApiException>()));
      expect(h.direct.baseUrl, 'http://192.168.1.30');
    });
  });
}
