import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/services/automation_api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/support.dart';

/// Wi-Fi servis akışı istemci ucu (CONTRACTS §3d): `GET /api/wifi/status` (anahtarsız AP kaynaklı),
/// bağlanma sonucunun bu uçla beklenmesi ve eski yazılım (404) için `/api/status` yedeği.
void main() {
  late MockApi mock;
  late FakeClock clock;

  AutomationApiService apiWith({String? key}) =>
      AutomationApiService(baseUrl: 'http://192.168.4.1', localKey: key, client: mock.client, clock: clock);

  Map<String, dynamic> wifiStatus({
    String state = 'idle',
    int reason = 0,
    String ip = '',
    bool connected = false,
  }) =>
      <String, dynamic>{
        'wifi_connect_state': state,
        'wifi_connect_reason': reason,
        'wifi_connected': connected,
        'wifi_sta_ssid': connected ? 'EvAgi' : '',
        'wifi_sta_ip': ip,
        'wifi_rssi': connected ? -52 : 0,
        'ap_active': true,
      };

  /// `GET /api/wifi/status` yanıtlarını sırayla verir (son yanıt tekrarlanır).
  void wifiSequence(List<Map<String, dynamic>> bodies) {
    var i = 0;
    mock.on('GET', '/api/wifi/status', (r) {
      final body = bodies[i < bodies.length ? i : bodies.length - 1];
      i++;
      return jsonResponse(body);
    });
  }

  setUp(() {
    mock = MockApi();
    clock = FakeClock();
  });

  group('fetchWifiStatus', () {
    test('alanlar çözülür: bağlanma durumu/nedeni, IP, RSSI ve ap_active (wifiApActive)', () async {
      mock.on('GET', '/api/wifi/status', (r) => jsonResponse(wifiStatus(state: 'success', ip: '192.168.1.57', connected: true)));
      final status = await apiWith().fetchWifiStatus();

      expect(status.wifiConnectState, WifiConnectState.success);
      expect(status.wifiConnected, isTrue);
      expect(status.wifiStaIp, '192.168.1.57');
      expect(status.wifiStaSsid, 'EvAgi');
      expect(status.wifiRssi, -52);
      expect(status.wifiApActive, isTrue, reason: 'ap_active -> wifiApActive');
      expect(mock.requests.single.method, 'GET');
      expect(mock.requests.single.path, '/api/wifi/status');
    });

    test('failed: neden kodu okunur', () async {
      mock.on('GET', '/api/wifi/status', (r) => jsonResponse(wifiStatus(state: 'failed', reason: 202)));
      final status = await apiWith().fetchWifiStatus();
      expect(status.wifiConnectState, WifiConnectState.failed);
      expect(status.wifiConnectReason, 202);
    });

    test('anahtar yoksa X-Device-Key GÖNDERİLMEZ (AP kaynaklı anahtarsız uç); varsa gönderilir', () async {
      mock.on('GET', '/api/wifi/status', (r) => jsonResponse(wifiStatus()));
      await apiWith().fetchWifiStatus();
      expect(mock.requests.last.headers.keys.map((k) => k.toLowerCase()), isNot(contains('x-device-key')));

      await apiWith(key: 'test-anahtar-1234').fetchWifiStatus();
      expect(mock.requests.last.headers['X-Device-Key'], 'test-anahtar-1234');
    });

    test('eski yazılım: 404 -> LocalApiException (desteklenmiyor); 401 -> yetki; 403 unprovisioned -> hazırlanmamış', () async {
      await expectLater(
        apiWith().fetchWifiStatus(),
        throwsA(isA<LocalApiException>().having((e) => e.statusCode, 'status', 404).having((e) => e.message, 'mesaj', contains('desteklemiyor'))),
      );
      mock.on('GET', '/api/wifi/status', (r) => jsonResponse(<String, dynamic>{'error': 'unauthorized'}, status: 401));
      await expectLater(apiWith().fetchWifiStatus(), throwsA(isA<LocalApiException>().having((e) => e.isUnauthorized, 'unauthorized', isTrue)));
      mock.on('GET', '/api/wifi/status', (r) => jsonResponse(<String, dynamic>{'error': 'unprovisioned'}, status: 403));
      await expectLater(apiWith().fetchWifiStatus(), throwsA(isA<LocalApiException>().having((e) => e.isUnprovisioned, 'unprovisioned', isTrue)));
    });
  });

  group('awaitWifiConnection /api/wifi/status ile bekler', () {
    test('connecting -> success: başarı ve pano IP adresi; tam /api/status HİÇ çağrılmaz', () async {
      wifiSequence(<Map<String, dynamic>>[
        wifiStatus(state: 'connecting'),
        wifiStatus(state: 'connecting'),
        wifiStatus(state: 'success', ip: '192.168.1.77', connected: true),
      ]);
      final api = apiWith();
      final future = api.awaitWifiConnection(timeout: const Duration(seconds: 30));
      await clock.elapse(const Duration(seconds: 10));
      final result = await future;

      expect(result.outcome, WifiConnectOutcome.success);
      expect(result.ipAddress, '192.168.1.77');
      expect(mock.count('GET', '/api/status'), 0);
      expect(mock.count('GET', '/api/wifi/status'), 3);
    });

    test('idle durumu başarı DEĞİLDİR (yoklama sürer); failed -> neden kodu ve Türkçe mesaj', () async {
      wifiSequence(<Map<String, dynamic>>[wifiStatus(), wifiStatus(state: 'failed', reason: 201)]);
      final future = apiWith().awaitWifiConnection(timeout: const Duration(seconds: 30));
      await clock.elapse(const Duration(seconds: 5));
      final result = await future;

      expect(result.outcome, WifiConnectOutcome.failed);
      expect(result.reason, 201);
      expect(result.message, contains('Ağ bulunamadı'));
      expect(mock.count('GET', '/api/wifi/status'), 2);
    });

    test('süre dolarsa timedOut', () async {
      wifiSequence(<Map<String, dynamic>>[wifiStatus(state: 'connecting')]);
      final future = apiWith().awaitWifiConnection(timeout: const Duration(seconds: 6), interval: const Duration(seconds: 1));
      await clock.elapse(const Duration(seconds: 10));
      expect((await future).outcome, WifiConnectOutcome.timedOut);
    });

    test('eski yazılım (404): anahtarlı /api/status\'a düşülür; tercih bekleme boyunca korunur (yeni uç yalnızca bir kez denenir)', () async {
      var polls = 0;
      mock.on('GET', '/api/status', (r) {
        polls++;
        return jsonResponse(<String, dynamic>{
          'device': 'AHBU-S3-1A2B3C',
          'provisioned': true,
          'wifi_connect_state': polls < 3 ? 'connecting' : 'success',
          'wifi_sta_ip': polls < 3 ? '' : '192.168.1.90',
          'relays': <dynamic>[],
          'shutters': <dynamic>[],
          'dis': <dynamic>[],
        });
      });
      final api = apiWith(key: 'test-anahtar-1234');
      final future = api.awaitWifiConnection(timeout: const Duration(seconds: 30));
      await clock.elapse(const Duration(seconds: 10));
      final result = await future;

      expect(result.outcome, WifiConnectOutcome.success);
      expect(result.ipAddress, '192.168.1.90');
      expect(mock.count('GET', '/api/wifi/status'), 1, reason: '404 sonrası yeni uç bırakıldı');
      expect(mock.count('GET', '/api/status'), 3);
    });

    test('yetki hataları yeniden fırlatılır ve eski uca DÜŞÜLMEZ (401, 403 unprovisioned, 423)', () async {
      mock.on('GET', '/api/wifi/status', (r) => jsonResponse(<String, dynamic>{'error': 'unauthorized'}, status: 401));
      await expectLater(apiWith().awaitWifiConnection(), throwsA(isA<LocalApiException>().having((e) => e.isUnauthorized, 'unauthorized', isTrue)));
      mock.on('GET', '/api/wifi/status', (r) => jsonResponse(<String, dynamic>{'error': 'unprovisioned'}, status: 403));
      await expectLater(apiWith().awaitWifiConnection(), throwsA(isA<LocalApiException>().having((e) => e.isUnprovisioned, 'unprovisioned', isTrue)));
      mock.on('GET', '/api/wifi/status', (r) => jsonResponse(<String, dynamic>{'error': 'locked', 'retry_after': 60}, status: 423));
      await expectLater(apiWith().awaitWifiConnection(), throwsA(isA<LocalApiException>().having((e) => e.isLocked, 'locked', isTrue)));
      expect(mock.count('GET', '/api/status'), 0, reason: 'yetki hatasında yedek uca gidilmez');
    });

    test('bağlantı koptu (pano AP\'yi kapattı): belirsiz sonuç, başarısızlık SANILMAZ', () async {
      var calls = 0;
      mock.on('GET', '/api/wifi/status', (r) {
        calls++;
        if (calls == 1) return jsonResponse(wifiStatus(state: 'connecting'));
        throw http.ClientException('connection closed');
      });
      final future = apiWith().awaitWifiConnection(timeout: const Duration(seconds: 30));
      await clock.elapse(const Duration(seconds: 5));
      final result = await future;

      expect(result.outcome, WifiConnectOutcome.lostContact);
      expect(result.isSuccess, isFalse);
    });

    test('yoklama SIRASINDA yetki yolu kapanırsa (401; ör. pano bağlandı ve modem ağı da 192.168.4.x): belirsiz sonuç, yetki hatası/başarısızlık SANILMAZ', () async {
      var calls = 0;
      mock.on('GET', '/api/wifi/status', (r) {
        calls++;
        if (calls == 1) return jsonResponse(wifiStatus(state: 'connecting'));
        return jsonResponse(<String, dynamic>{'error': 'unauthorized'}, status: 401);
      });
      final future = apiWith().awaitWifiConnection(timeout: const Duration(seconds: 30));
      await clock.elapse(const Duration(seconds: 5));
      final result = await future;

      expect(result.outcome, WifiConnectOutcome.lostContact);
      expect(result.isSuccess, isFalse);
      expect(calls, 2, reason: 'ilk okuma sonrası gelen 401 yoklamayı bitirir (yeniden denenmez)');
    });

    test('connectWifiAndWait anahtarsız: önce POST /api/wifi/connect sonra GET /api/wifi/status; hiçbir istekte X-Device-Key yok', () async {
      mock.on('POST', '/api/wifi/connect', (r) => jsonResponse(<String, dynamic>{'status': 'connecting'}));
      wifiSequence(<Map<String, dynamic>>[wifiStatus(state: 'success', ip: '192.168.1.5', connected: true)]);
      final result = await apiWith().connectWifiAndWait('EvAgi', 'parola1234');

      expect(result.isSuccess, isTrue);
      expect(mock.requests.map((r) => '${r.method} ${r.path}').toList(), <String>['POST /api/wifi/connect', 'GET /api/wifi/status']);
      expect(mock.requests.every((r) => !r.headers.keys.map((k) => k.toLowerCase()).contains('x-device-key')), isTrue);
    });
  });

  group('connectWifi hız sınırı (429)', () {
    test('gövdedeki retry_after okunur; hata "çok sık istek" mesajıdır', () async {
      mock.on('POST', '/api/wifi/connect', (r) => jsonResponse(<String, dynamic>{'error': 'rate_limited', 'retry_after': 25}, status: 429));
      await expectLater(
        apiWith().connectWifi('EvAgi', 'parola1234'),
        throwsA(isA<LocalApiException>()
            .having((e) => e.statusCode, 'status', 429)
            .having((e) => e.retryAfter, 'retryAfter', const Duration(seconds: 25))
            .having((e) => e.message, 'mesaj', contains('çok sık'))),
      );
    });

    test('yalnızca Retry-After başlığı varsa o okunur', () async {
      mock.on('POST', '/api/wifi/connect', (r) => jsonResponse(<String, dynamic>{'error': 'rate_limited'}, status: 429, headers: <String, String>{'Retry-After': '7'}));
      await expectLater(
        apiWith().connectWifi('EvAgi', 'parola1234'),
        throwsA(isA<LocalApiException>().having((e) => e.retryAfter, 'retryAfter', const Duration(seconds: 7))),
      );
    });
  });
}
