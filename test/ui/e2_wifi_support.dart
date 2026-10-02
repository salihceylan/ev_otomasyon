import 'package:ev_otomasyon/services/automation_api_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/support.dart';

/// Wi-Fi kurulum/kurtarma testleri için ortak sahte pano (CONTRACTS §3b/§3d) ve yardımcılar.
///
/// Değerler gerçek bir sır DEĞİLDİR (yalnızca test yer tutucusu).
const String kDeviceKey = 'cihaz-anahtari-1234';
const String kOtherDeviceKey = 'baska-pano-anahtari-5678';
const String kDeviceUid = 'AHBU-S3-1A2B3C';
const String kOtherDeviceUid = 'AHBU-S3-9F8E7D';

/// Firmware yerel API'sinin (CONTRACTS §3/§3b/§3d) en küçük taklidi.
///
/// * [apOnlyAuth] `true` (varsayılan, W1 yazılımı): Wi-Fi uçları (`scan`, `connect`, `wifi/status`)
///   panonun WPA2 kurulum ağından **anahtarsız** çalışır; diğer uçlar anahtar ister.
///   `false` = anahtar-zorunlu (eski) yazılım: anahtarsız Wi-Fi isteği `401`.
/// * [wifiStatusSupported] `false` = eski yazılım: `GET /api/wifi/status` yok (`404`); bağlanma sonucu
///   anahtarlı `GET /api/status` ile izlenir.
class FakeWifiDevice {
  FakeWifiDevice({
    this.provisioned = true,
    this.apOnlyAuth = true,
    this.wifiStatusSupported = true,
    this.uid = kDeviceUid,
  }) {
    api
      ..on('GET', '/api/status', (r) {
        if (statusDown) throw http.ClientException('pano ulaşılamıyor');
        statusCalls++;
        if (!hasValidKey(r)) {
          // Anahtarsız / yanlış anahtar: yalnızca KISITLI özet (CONTRACTS §3b).
          return jsonResponse(<String, dynamic>{
            'device': uid,
            'name': 'Pano',
            'fw': '1.1.0',
            'provisioned': provisioned,
            'wifi_connected': false,
          });
        }
        return jsonResponse(<String, dynamic>{
          'device': uid,
          'name': 'Pano',
          'fw': '1.1.0',
          'provisioned': provisioned,
          'wifi_connected': connectState == 'success',
          'wifi_sta_ip': connectState == 'success' ? '192.168.1.57' : '',
          'wifi_connect_state': connectState,
          'wifi_connect_reason': connectReason,
          'relays': <dynamic>[],
          'shutters': <dynamic>[],
          'dis': <dynamic>[],
        });
      })
      ..on('GET', '/api/wifi/status', (r) {
        if (statusDown) throw http.ClientException('pano ulaşılamıyor');
        wifiStatusCalls++;
        if (!wifiStatusSupported) return jsonResponse(<String, dynamic>{'error': 'not_found'}, status: 404);
        final denied = wifiAuth(r);
        if (denied != null) return denied;
        return jsonResponse(<String, dynamic>{
          'wifi_connect_state': connectState,
          'wifi_connect_reason': connectReason,
          'wifi_connected': connectState == 'success',
          'wifi_sta_ssid': connectState == 'success' ? 'EvAgi' : '',
          'wifi_sta_ip': connectState == 'success' ? '192.168.1.57' : '',
          'wifi_rssi': connectState == 'success' ? -52 : 0,
          'ap_active': true,
        });
      })
      ..on('GET', '/api/wifi/scan', (r) {
        scanRequests++;
        scanHeaders.add(r.headers);
        final denied = wifiAuth(r);
        if (denied != null) return denied;
        if (scanStatus != 200) {
          return jsonResponse(<String, dynamic>{'error': 'busy'}, status: scanStatus);
        }
        if (scanRequests <= scanningFirst) return jsonResponse(<String, dynamic>{'status': 'scanning'});
        return jsonResponse(<String, dynamic>{'status': 'done', 'cached': false, 'networks': networks});
      })
      ..on('POST', '/api/wifi/connect', (r) {
        connectBodies.add(r.json ?? <String, dynamic>{});
        connectHeaders.add(r.headers);
        final denied = wifiAuth(r);
        if (denied != null) return denied;
        final limited = rateLimitRetryAfter;
        if (limited != null) {
          return jsonResponse(
            <String, dynamic>{'error': 'rate_limited', 'retry_after': limited.inSeconds},
            status: 429,
            headers: <String, String>{'Retry-After': '${limited.inSeconds}'},
          );
        }
        if (connectStatus != 200) {
          return jsonResponse(<String, dynamic>{'error': 'busy'}, status: connectStatus);
        }
        connectState = 'connecting';
        pollCallsAtConnect = pollCalls;
        return jsonResponse(<String, dynamic>{'status': 'connecting'});
      });
  }

  final MockApi api = MockApi();
  final String uid;
  bool provisioned;
  final bool apOnlyAuth;
  final bool wifiStatusSupported;
  bool statusDown = false;
  int statusCalls = 0;
  int wifiStatusCalls = 0;
  int pollCallsAtConnect = 0;
  int scanRequests = 0;
  int scanningFirst = 0;
  int scanStatus = 200;
  int connectStatus = 200;
  Duration? rateLimitRetryAfter;
  String connectState = 'idle';
  int connectReason = 0;
  final List<Map<String, dynamic>> connectBodies = <Map<String, dynamic>>[];
  final List<Map<String, String>> connectHeaders = <Map<String, String>>[];
  final List<Map<String, String>> scanHeaders = <Map<String, String>>[];
  List<Map<String, dynamic>> networks = <Map<String, dynamic>>[
    <String, dynamic>{'ssid': 'EvAgi', 'rssi': -48, 'enc': true},
    <String, dynamic>{'ssid': 'KomsuAcik', 'rssi': -70, 'enc': false},
    <String, dynamic>{'ssid': 'Uzak', 'rssi': -88, 'enc': true},
  ];

  /// Bağlanma sonucunun yoklandığı uca yapılan toplam istek (`wifi/status` + eski yazılımda `status`).
  int get pollCalls => wifiStatusCalls + statusCalls;

  bool hasValidKey(RecordedRequest r) =>
      r.headers.entries.any((e) => e.key.toLowerCase() == 'x-device-key' && e.value == kDeviceKey);

  /// Wi-Fi uçlarının yetkisi: hazırlanmamış cihaz `403`; AP kaynaklı model anahtarsız izin verir;
  /// anahtar-zorunlu yazılım geçerli anahtar ister (`401`).
  http.Response? wifiAuth(RecordedRequest r) {
    if (!provisioned) return jsonResponse(<String, dynamic>{'error': 'unprovisioned'}, status: 403);
    if (apOnlyAuth || hasValidKey(r)) return null;
    return jsonResponse(<String, dynamic>{'error': 'unauthorized'}, status: 401);
  }

  /// Tüm isteklerden herhangi birinde `X-Device-Key` başlığı var mı?
  bool anyRequestSentKey() => api.requests.any((r) => r.headers.keys.any((k) => k.toLowerCase() == 'x-device-key'));

  AutomationApiService client(FakeClock clock, {String? key}) =>
      AutomationApiService(baseUrl: 'http://192.168.4.1', localKey: key, client: api.client, clock: clock);
}

/// [done] sağlanana kadar sahte saati ilerletip çerçeve çizer.
Future<void> advanceUntil(
  WidgetTester tester,
  FakeClock clock,
  bool Function() done, {
  Duration step = const Duration(milliseconds: 700),
  int maxSteps = 150,
}) async {
  for (var i = 0; i < maxSteps; i++) {
    if (done()) return;
    clock.advance(step);
    await tester.pump();
  }
  fail('beklenen durum oluşmadı (sahte saat ${step * maxSteps} ilerletildi)');
}

bool shown(String key) => find.byKey(Key(key)).evaluate().isNotEmpty;
