import 'dart:async';
import 'dart:io';

import 'package:ev_otomasyon/config/app_config.dart';
import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/services/automation_api_service.dart';
import 'package:ev_otomasyon/services/board_network_binding.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/support.dart';

/// Pano kurulum ağı (AP) çağrılarının pano ağına yönlendirilmesi (Android; WP-NET): [AutomationApiService]
/// sarmalayıcısı. Bağlama SAHTE (`FakeBoardNetworkBinding`) ya da gerçek Android bağlaması + sahte kanal;
/// HTTP sahte pano (`MockApi`). Gerçek Android cihazda DOĞRULANMADI.
const String _ap = 'http://192.168.4.1';
const String _acquireAp = 'acquire:192.168.4.1';
const String _hintNotOnNetwork =
    'Telefon pano kurulum ağına (AHBU-…) bağlı görünmüyor: Wi-Fi ayarlarından panonun ağına bağlanın.';
const String _hintNoRoute = 'Pano ağına yönlenme kurulamadı: mobil veriyi kapatıp yeniden deneyin.';
const String _networkMessage =
    'Cihaza ulaşılamadı. Aynı ağda olduğunuzdan ve adresin doğru olduğundan emin olun.';

/// Sahte yerel taraf (yalnızca gerçek [AndroidBoardNetworkBinding] ile birleşik testlerde).
class _Native {
  final List<String> names = <String>[];

  /// Doluysa varsayılan yanıt yerine bu kullanılır (ör. yerel eklenti yok / VPN reddi).
  Future<Object?> Function(MethodCall call)? override;

  int count(String name) => names.where((n) => n == name).length;

  Future<Object?> handle(MethodCall call) async {
    names.add(call.method);
    final custom = override;
    if (custom != null) return custom(call);
    return <String, Object?>{'status': call.method == 'acquire' ? 'bound' : 'released'};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> events;
  late FakeBoardNetworkBinding fake;
  late MockApi mock;
  late FakeClock clock;

  http.Response restrictedStatus() => jsonResponse(<String, dynamic>{
        'device': 'AHBU-S3-1A2B3C',
        'name': 'Pano',
        'fw': '1.1.0',
        'provisioned': true,
        'wifi_connected': false,
      });

  Map<String, dynamic> wifiStatus(String state, {int reason = 0, String ip = ''}) => <String, dynamic>{
        'wifi_connect_state': state,
        'wifi_connect_reason': reason,
        'wifi_connected': state == 'success',
        'wifi_sta_ssid': state == 'success' ? 'EvAgi' : '',
        'wifi_sta_ip': ip,
        'wifi_rssi': state == 'success' ? -52 : 0,
        'ap_active': true,
      };

  /// Sahte pano yolu: istek, ortak olay listesine `req:<yöntem> <yol>` olarak yazılır.
  void route(String method, String path, http.Response Function(RecordedRequest request) respond) {
    mock.on(method, path, (r) {
      events.add('req:${r.method} ${r.path}');
      return respond(r);
    });
  }

  void routeDefaults() {
    route('GET', '/api/status', (_) => restrictedStatus());
    route('GET', '/api/wifi/status', (_) => jsonResponse(wifiStatus('idle')));
    route('GET', '/api/wifi/scan', (_) => jsonResponse(<String, dynamic>{
          'status': 'done',
          'cached': false,
          'networks': <Map<String, dynamic>>[
            <String, dynamic>{'ssid': 'EvAgi', 'rssi': -48, 'enc': true},
          ],
        }));
    route('POST', '/api/wifi/connect', (_) => jsonResponse(<String, dynamic>{'status': 'connecting'}));
    route('GET', '/api/auth/check', (_) => jsonResponse(<String, dynamic>{'status': 'ok'}));
    route('POST', '/api/factory/init', (_) => jsonResponse(<String, dynamic>{'status': 'ok'}));
    route('POST', '/api/auth/rekey', (_) => jsonResponse(<String, dynamic>{'status': 'ok'}));
    route('POST', '/api/relay', (_) => jsonResponse(<String, dynamic>{'status': 'ok'}));
    route('POST', '/api/all', (_) => jsonResponse(<String, dynamic>{'status': 'ok'}));
    route('GET', '/api/config', (_) => jsonResponse(<String, dynamic>{'relays': <dynamic>[]}));
    route('POST', '/api/config', (_) => jsonResponse(<String, dynamic>{'status': 'ok'}));
    route('POST', '/api/mqtt/config', (_) => jsonResponse(<String, dynamic>{'status': 'ok'}));
    route('GET', '/api/child-lock', (_) => jsonResponse(<String, dynamic>{'child_lock': false}));
    route('POST', '/api/child-lock', (_) => jsonResponse(<String, dynamic>{'status': 'queued'}));
    route('POST', '/api/actuator', (_) => jsonResponse(<String, dynamic>{'ok': true}));
    route('POST', '/api/alarm/ack', (_) => jsonResponse(<String, dynamic>{'ok': true}));
    route('POST', '/api/alarm/test', (_) => jsonResponse(<String, dynamic>{'ok': true}));
    route('POST', '/api/arm', (_) => jsonResponse(<String, dynamic>{'ok': true}));
    route('GET', '/api/events', (_) => jsonResponse(<String, dynamic>{'events': <dynamic>[]}));
    route('GET', '/api/safety/config', (_) => jsonResponse(<String, dynamic>{'rev': 1}));
    route('POST', '/api/safety/config', (_) => jsonResponse(<String, dynamic>{'ok': true, 'rev': 2}));
    route('GET', '/api/template', (_) => jsonResponse(<String, dynamic>{'template_id': null, 'version': 0}));
    route('POST', '/api/template/apply', (_) => jsonResponse(<String, dynamic>{'ok': true, 'template_id': 't', 'version': 1}));
  }

  /// `GET /api/wifi/status` yanıtlarını sırayla verir (son yanıt tekrarlanır).
  void wifiSequence(List<Map<String, dynamic>> bodies) {
    var i = 0;
    route('GET', '/api/wifi/status', (_) {
      final body = bodies[i < bodies.length ? i : bodies.length - 1];
      i++;
      return jsonResponse(body);
    });
  }

  AutomationApiService apiAt(String baseUrl, {String? key, BoardNetworkBinding? binding}) => AutomationApiService(
        baseUrl: baseUrl,
        localKey: key,
        client: mock.client,
        clock: clock,
        boardNetwork: binding ?? fake,
      );

  /// [future]'ı sahte saati ilerleterek bitirir; sonucu ya da hatayı döner (işlenmemiş hata kalmaz).
  Future<({Object? value, Object? error})> finish(Future<Object?> future, {Duration advance = const Duration(seconds: 90)}) async {
    Object? value;
    Object? error;
    var done = false;
    future.then<void>((v) {
      value = v;
      done = true;
    }, onError: (Object e) {
      error = e;
      done = true;
    });
    await clock.elapse(advance);
    expect(done, isTrue, reason: 'sahte saat ilerletildiği halde işlem bitmedi');
    return (value: value, error: error);
  }

  /// Bir kira, çıkışta bırakılır ve yoklamalar arasında bırakılmaz: tek `acquire`, en sonda tek `release`.
  void expectSingleLease() {
    expect(fake.acquireCount, 1, reason: 'TEK kira');
    expect(fake.releaseCount, 1);
    expect(fake.activeLeases, 0, reason: 'çıkışta bırakıldı');
    expect(events.first, _acquireAp);
    expect(events.last, 'release');
    expect(events.where((e) => e == 'release'), hasLength(1), reason: 'yoklamalar arasında bırakılmadı');
    expect(events.where((e) => e.startsWith('acquire')), hasLength(1));
  }

  /// Temiz başlangıç (her testte ve döngülü senaryolar arasında).
  void freshState() {
    events = <String>[];
    fake = FakeBoardNetworkBinding(events: events);
    mock = MockApi();
    clock = FakeClock();
    AppConfig.current = AppConfig.defaults;
    routeDefaults();
  }

  setUp(freshState);

  tearDown(() {
    BoardNetworkBinding.overrideForTesting(null);
    AppConfig.current = AppConfig.defaults;
  });

  // Aşağıdaki tabloda AP'ye giden TÜM çağrı yolları: her biri tek bir sarmalayıcıdan geçer.
  final Map<String, (Future<Object?> Function(AutomationApiService), String)> allCalls =
      <String, (Future<Object?> Function(AutomationApiService), String)>{
    'fetchStatus': ((a) => a.fetchStatus(), 'GET /api/status'),
    'fetchPublicStatus': ((a) => a.fetchPublicStatus(), 'GET /api/status'),
    'fetchWifiStatus': ((a) => a.fetchWifiStatus(), 'GET /api/wifi/status'),
    'scanWifiNetworks': ((a) => a.scanWifiNetworks(), 'GET /api/wifi/scan'),
    'scanWifi': ((a) => a.scanWifi(), 'GET /api/wifi/scan'),
    'connectWifi': ((a) => a.connectWifi('EvAgi', 'parola1234'), 'POST /api/wifi/connect'),
    'checkKey': ((a) => a.checkKey(), 'GET /api/auth/check'),
    'factoryInit': ((a) => a.factoryInit(localKey: 'anahtar-test-1234', apPass: 'kurulum-parola-1'), 'POST /api/factory/init'),
    'rekey': ((a) => a.rekey('yeni-anahtar-1234'), 'POST /api/auth/rekey'),
    'setRelay': ((a) => a.setRelay(1, true), 'POST /api/relay'),
    'toggleRelay': ((a) => a.toggleRelay(1), 'POST /api/relay'),
    'cmdShutter': ((a) => a.cmdShutter(1, 'up'), 'POST /api/relay'),
    'cmdAll': ((a) => a.cmdAll('lightsoff'), 'POST /api/all'),
    'fetchConfig': ((a) => a.fetchConfig(), 'GET /api/config'),
    'saveConfig': ((a) => a.saveConfig(<String, dynamic>{'relays': <dynamic>[]}), 'POST /api/config'),
    'configureMqtt': (
      (a) => a.configureMqtt(
            const DeviceMqttCredential(host: 'mqtt.ornek.test', port: 8884, username: 'd_test', password: 'test-parola-1', topicId: 'tid-test'),
          ),
      'POST /api/mqtt/config'
    ),
    'fetchChildLock': ((a) => a.fetchChildLock(), 'GET /api/child-lock'),
    'setChildLock': ((a) => a.setChildLock(true), 'POST /api/child-lock'),
    'postActuator': ((a) => a.postActuator('a1', 'closed', id: 'c1'), 'POST /api/actuator'),
    'ackAlarm': ((a) => a.ackAlarm(1, aid: '9f3a11c0-3', id: 'c2'), 'POST /api/alarm/ack'),
    'testAlarm': ((a) => a.testAlarm(1, id: 'c3'), 'POST /api/alarm/test'),
    'postArm': ((a) => a.postArm('away', id: 'c4'), 'POST /api/arm'),
    'fetchEvents': ((a) => a.fetchEvents(), 'GET /api/events'),
    'fetchSafetyConfig': ((a) => a.fetchSafetyConfig(), 'GET /api/safety/config'),
    'saveSafetyConfig': ((a) => a.saveSafetyConfig(<String, dynamic>{'base_rev': 1}), 'POST /api/safety/config'),
    'fetchTemplate': ((a) => a.fetchTemplate(), 'GET /api/template'),
    'applyTemplate': ((a) => a.applyTemplate(<String, dynamic>{'template': <String, dynamic>{}}), 'POST /api/template/apply'),
  };

  group('her AP çağrısında kira ÖNCE alınır, SONRA istek, EN SON bırakılır', () {
    for (final entry in allCalls.entries) {
      test(entry.key, () async {
        final api = apiAt(_ap, key: 'anahtar-test-1234');
        final outcome = await finish(entry.value.$1(api));
        expect(outcome.error, isNull, reason: '${outcome.error}');
        expect(events, <String>[_acquireAp, 'req:${entry.value.$2}', 'release']);
        expect(fake.activeLeases, 0);
        expect(fake.hosts, <String>['192.168.4.1'], reason: 'ana makine port/şema olmadan');
      });
    }

    test('çağrı tablosu, AutomationApiService\'in AP\'ye giden TÜM istek uçlarını kapsar (uçlar KAYNAKTAN çıkarılır)', () {
      // Uç listesi testin kendi sabitinden DEĞİL, kaynaktaki `_send('YÖNTEM', '/yol'` çağrılarından türetilir:
      // yeni bir uç eklenip bu tabloya yazılmazsa test kırmızı olur.
      final source = File('lib/services/automation_api_service.dart').readAsStringSync();
      final inSource = RegExp(r"_send\(\s*'(GET|POST)',\s*'([^']+)'")
          .allMatches(source)
          .map((m) => '${m.group(1)} ${m.group(2)}')
          .toSet();
      final inTable = allCalls.values.map((c) => c.$2).toSet();

      expect(inSource, isNotEmpty, reason: 'desen kaynakta hiç uç bulamadı: regex bozulmuş olabilir');
      expect(inTable.difference(inSource), isEmpty, reason: 'tabloda olup kaynakta olmayan uç');
      expect(inSource.difference(inTable), isEmpty, reason: 'kaynakta olup bu tabloda OLMAYAN uç: tabloya (kira sırası testine) ekleyin');
    });

    test('istek, kira ALINANA kadar gönderilmez (acquire tamamlanır -> istek)', () async {
      fake.acquireGate = Completer<void>();
      final future = apiAt(_ap).fetchPublicStatus();
      await pumpEventQueue();
      expect(mock.requests, isEmpty, reason: 'kira alınırken istek bekler');
      expect(events, <String>[_acquireAp]);

      fake.acquireGate!.complete();
      await future;
      expect(events, <String>[_acquireAp, 'req:GET /api/status', 'release']);
    });

    test('release, çağrı DÖNMEDEN önce tamamlanır (çağrı bittiğinde açık kira kalmaz)', () async {
      final api = apiAt(_ap);
      await api.fetchPublicStatus();
      expect(fake.activeLeases, 0);
      await api.fetchWifiStatus();
      expect(fake.activeLeases, 0);
      expect(events.where((e) => e == 'release'), hasLength(2));
    });

    test('recoveryAp fabrikası da sarmalanır; varsayılan adres AppConfig.deviceApHost', () async {
      final api = AutomationApiService.recoveryAp(client: mock.client, clock: clock, boardNetwork: fake);
      expect(api.baseUrl, 'http://192.168.4.1');
      await api.fetchPublicStatus();
      expect(events, <String>[_acquireAp, 'req:GET /api/status', 'release']);
    });

    test('copyWith bağlamayı taşır', () async {
      final api = apiAt(_ap).copyWith(localKey: 'baska-anahtar-1234');
      await api.fetchStatus();
      expect(events, <String>[_acquireAp, 'req:GET /api/status', 'release']);
    });

    test('adres sonradan updateHost ile pano ağına çevrilince de sarmalanır (adres her çağrıda okunur)', () async {
      final api = AutomationApiService(baseUrl: '', client: mock.client, clock: clock, boardNetwork: fake)..updateHost('192.168.4.1');
      await api.fetchPublicStatus();
      expect(events, <String>[_acquireAp, 'req:GET /api/status', 'release']);

      events.clear();
      api.updateHost('192.168.1.30'); // LAN: artık bağlama yok
      await api.fetchPublicStatus();
      expect(events, <String>['req:GET /api/status']);
    });
  });

  group('her çıkış yolunda kira bırakılır', () {
    test('cihaz hata kodu (401): LocalApiException fırlatılır, kira bırakılır', () async {
      route('POST', '/api/wifi/connect', (_) => jsonResponse(<String, dynamic>{'error': 'unauthorized'}, status: 401));
      final outcome = await finish(apiAt(_ap).connectWifi('EvAgi', 'parola1234'));
      expect(outcome.error, isA<LocalApiException>().having((e) => e.isUnauthorized, 'isUnauthorized', isTrue));
      expect(events, <String>[_acquireAp, 'req:POST /api/wifi/connect', 'release']);
    });

    test('ağ hatası (ClientException) ve zaman aşımı (TimeoutException): kira bırakılır', () async {
      for (final failure in <Object>[http.ClientException('pano ulaşılamıyor'), TimeoutException('zaman aşımı')]) {
        events.clear();
        fake.releaseCount = 0;
        route('GET', '/api/status', (_) => throw failure);
        final outcome = await finish(apiAt(_ap).fetchPublicStatus());
        expect(outcome.error, isA<LocalApiException>().having((e) => e.isNetwork, 'isNetwork', isTrue), reason: '$failure');
        expect(events, <String>[_acquireAp, 'req:GET /api/status', 'release'], reason: '$failure');
        expect(fake.activeLeases, 0);
      }
    });

    test('beklenmeyen (LocalApiException olmayan) istisna da kirayı bırakır ve olduğu gibi yayılır', () async {
      route('GET', '/api/status', (_) => throw StateError('beklenmeyen'));
      final outcome = await finish(apiAt(_ap).fetchPublicStatus());
      expect(outcome.error, isA<StateError>());
      expect(fake.activeLeases, 0);
      expect(events.last, 'release');
    });

    test('tarama iptali (isCancelled): istek atılmadan kira bırakılır', () async {
      final outcome = await finish(apiAt(_ap).scanWifiNetworks(isCancelled: () => true));
      expect(outcome.error, isA<LocalApiException>().having((e) => e.isCancelled, 'isCancelled', isTrue));
      expect(events, <String>[_acquireAp, 'release']);
    });

    test('ağa gitmeyen doğrulama hatası (geçersiz SSID) kira ALMAZ; yapılandırılmamış istemci de', () async {
      final bad = await finish(apiAt(_ap).connectWifi('', 'parola1234'));
      expect(bad.error, isA<LocalApiException>().having((e) => e.isInvalidInput, 'isInvalidInput', isTrue));
      final unset = await finish(apiAt('').fetchStatus());
      expect(unset.error, isA<LocalApiException>().having((e) => e.code, 'code', 'not_configured'));
      expect(events, isEmpty);
      expect(fake.acquireCount, 0);
    });
  });

  group('uzun işlemler tek kira tutar', () {
    test('awaitWifiConnection: baştan sona TEK kira; yoklamalar arasında bırakılmaz (success)', () async {
      wifiSequence(<Map<String, dynamic>>[
        wifiStatus('connecting'),
        wifiStatus('connecting'),
        wifiStatus('success', ip: '192.168.1.77'),
      ]);
      final outcome = await finish(apiAt(_ap).awaitWifiConnection(timeout: const Duration(seconds: 30)));
      expect((outcome.value as WifiConnectResult).outcome, WifiConnectOutcome.success);
      expect(events, <String>[
        _acquireAp,
        'req:GET /api/wifi/status',
        'req:GET /api/wifi/status',
        'req:GET /api/wifi/status',
        'release',
      ]);
      expectSingleLease();
    });

    test('awaitWifiConnection çıkış yolları: failed / timedOut / lostContact (ağ) / lostContact (401) / iptal / ilk okumadan önce 401', () async {
      final scenarios = <String, Future<Object?> Function()>{
        'failed': () {
          wifiSequence(<Map<String, dynamic>>[wifiStatus('connecting'), wifiStatus('failed', reason: 202)]);
          return apiAt(_ap).awaitWifiConnection(timeout: const Duration(seconds: 30));
        },
        'timedOut': () {
          wifiSequence(<Map<String, dynamic>>[wifiStatus('connecting')]);
          return apiAt(_ap).awaitWifiConnection(timeout: const Duration(seconds: 6), interval: const Duration(seconds: 1));
        },
        'lostContact (ağ hatası)': () {
          var calls = 0;
          route('GET', '/api/wifi/status', (_) {
            if (++calls == 1) return jsonResponse(wifiStatus('connecting'));
            throw http.ClientException('bağlantı koptu');
          });
          return apiAt(_ap).awaitWifiConnection(timeout: const Duration(seconds: 30));
        },
        'lostContact (401)': () {
          var calls = 0;
          route('GET', '/api/wifi/status', (_) {
            if (++calls == 1) return jsonResponse(wifiStatus('connecting'));
            return jsonResponse(<String, dynamic>{'error': 'unauthorized'}, status: 401);
          });
          return apiAt(_ap).awaitWifiConnection(timeout: const Duration(seconds: 30));
        },
        'isCancelled': () {
          var polls = 0;
          route('GET', '/api/wifi/status', (_) {
            polls++;
            return jsonResponse(wifiStatus('connecting'));
          });
          return apiAt(_ap).awaitWifiConnection(timeout: const Duration(seconds: 30), isCancelled: () => polls >= 2);
        },
        'istisna (ilk okumadan önce 401)': () {
          route('GET', '/api/wifi/status', (_) => jsonResponse(<String, dynamic>{'error': 'unauthorized'}, status: 401));
          return apiAt(_ap).awaitWifiConnection(timeout: const Duration(seconds: 30));
        },
      };
      for (final entry in scenarios.entries) {
        freshState();
        final outcome = await finish(entry.value());
        switch (entry.key) {
          case 'failed':
            expect((outcome.value as WifiConnectResult).outcome, WifiConnectOutcome.failed);
          case 'timedOut':
            expect((outcome.value as WifiConnectResult).outcome, WifiConnectOutcome.timedOut);
          case 'lostContact (ağ hatası)':
          case 'lostContact (401)':
            expect((outcome.value as WifiConnectResult).outcome, WifiConnectOutcome.lostContact);
          case 'isCancelled':
            expect(outcome.error, isA<LocalApiException>().having((e) => e.isCancelled, 'isCancelled', isTrue));
          default:
            expect(outcome.error, isA<LocalApiException>().having((e) => e.isUnauthorized, 'isUnauthorized', isTrue));
        }
        expectSingleLease();
      }
    });

    test('awaitWifiConnection eski yazılımda (404 -> /api/status) da tek kira', () async {
      route('GET', '/api/wifi/status', (_) => jsonResponse(<String, dynamic>{'error': 'not_found'}, status: 404));
      var polls = 0;
      route('GET', '/api/status', (_) => jsonResponse(<String, dynamic>{
            'device': 'AHBU-S3-1A2B3C',
            'provisioned': true,
            'wifi_connect_state': ++polls < 3 ? 'connecting' : 'success',
            'wifi_sta_ip': polls < 3 ? '' : '192.168.1.90',
            'relays': <dynamic>[],
            'shutters': <dynamic>[],
            'dis': <dynamic>[],
          }));
      final outcome = await finish(apiAt(_ap, key: 'anahtar-test-1234').awaitWifiConnection(timeout: const Duration(seconds: 30)));
      expect((outcome.value as WifiConnectResult).outcome, WifiConnectOutcome.success);
      expect(events.where((e) => e.startsWith('req:')), hasLength(4));
      expectSingleLease();
    });

    test('connectWifiAndWait: gönderme + bekleme TEK kira (arada çözülüp yeniden kurulmaz)', () async {
      wifiSequence(<Map<String, dynamic>>[wifiStatus('connecting'), wifiStatus('success', ip: '192.168.1.5')]);
      final outcome = await finish(apiAt(_ap).connectWifiAndWait('EvAgi', 'parola1234'));
      expect((outcome.value as WifiConnectResult).isSuccess, isTrue);
      expect(events, <String>[
        _acquireAp,
        'req:POST /api/wifi/connect',
        'req:GET /api/wifi/status',
        'req:GET /api/wifi/status',
        'release',
      ]);
      expectSingleLease();
    });

    test('tarama döngüsü (scanning ... done): tek kira', () async {
      var polls = 0;
      route('GET', '/api/wifi/scan', (_) {
        if (++polls <= 2) return jsonResponse(<String, dynamic>{'status': 'scanning'});
        return jsonResponse(<String, dynamic>{
          'status': 'done',
          'cached': false,
          'networks': <Map<String, dynamic>>[
            <String, dynamic>{'ssid': 'EvAgi', 'rssi': -48, 'enc': true},
          ],
        });
      });
      final outcome = await finish(apiAt(_ap).scanWifi(refresh: true));
      expect((outcome.value as List).length, 1);
      expect(events.where((e) => e.startsWith('req:')), hasLength(3));
      expectSingleLease();
    });

    test('bekleme sırasında ağ kaybolursa (networkLost) yeni kira alınmaz; yoklama sürer ve çıkışta bırakılır', () async {
      var polls = 0;
      route('GET', '/api/wifi/status', (_) {
        polls++;
        if (polls == 2) fake.loseNetwork(); // yerel taraf bağlamayı çözdü
        return jsonResponse(polls < 4 ? wifiStatus('connecting') : wifiStatus('success', ip: '192.168.1.9'));
      });
      final outcome = await finish(apiAt(_ap).awaitWifiConnection(timeout: const Duration(seconds: 30)));
      expect((outcome.value as WifiConnectResult).outcome, WifiConnectOutcome.success);
      expectSingleLease();
    });

    test('eşzamanlı iki AP çağrısı (aynı örnek) tek kira alır; son çağrı bitince bırakılır', () async {
      final api = apiAt(_ap);
      await Future.wait<Object?>(<Future<Object?>>[api.fetchPublicStatus(), api.fetchWifiStatus(), api.checkKey()]);
      expect(fake.acquireCount, 1, reason: 'örnek içi çağrılar kirayı paylaşır');
      expect(fake.releaseCount, 1);
      expect(fake.activeLeases, 0);
      expect(events.first, _acquireAp);
      expect(events.last, 'release');
      expect(events.where((e) => e.startsWith('req:')), hasLength(3));
    });

    test('ardışık çağrılar her seferinde kira alıp bırakır (arada bağlama tutulmaz)', () async {
      final api = apiAt(_ap);
      await api.fetchPublicStatus();
      await api.fetchWifiStatus();
      expect(events, <String>[
        _acquireAp,
        'req:GET /api/status',
        'release',
        _acquireAp,
        'req:GET /api/wifi/status',
        'release',
      ]);
    });
  });

  group('gerçek Android bağlaması + sahte kanal: tek yerel acquire', () {
    late _Native native;
    late AndroidBoardNetworkBinding android;

    setUp(() {
      native = _Native();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel(AndroidBoardNetworkBinding.channelName),
        native.handle,
      );
      android = AndroidBoardNetworkBinding(clock: clock, log: (_) {}); // tüm varsayılanlar (linger sıfır, pay 4 sn)
    });

    tearDown(() {
      android.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel(AndroidBoardNetworkBinding.channelName),
        null,
      );
    });

    test('eşzamanlı iki AP çağrısı TEK yerel acquire kullanır; sonra tek yerel release', () async {
      final api = apiAt(_ap, binding: android);
      await Future.wait<Object?>(<Future<Object?>>[api.fetchPublicStatus(), api.fetchWifiStatus()]);
      expect(native.count('acquire'), 1);
      expect(native.count('release'), 1);
      expect(native.names, <String>['acquire', 'release']);
    });

    test('farklı AP istemcileri (sihirbazın iki örneği) aynı bağlamayı paylaşır: yine tek yerel acquire', () async {
      final a = apiAt(_ap, binding: android);
      final b = apiAt(_ap, binding: android);
      await Future.wait<Object?>(<Future<Object?>>[a.fetchPublicStatus(), b.fetchWifiStatus()]);
      expect(native.count('acquire'), 1);
      expect(native.count('release'), 1);
    });

    test('awaitWifiConnection: tüm bekleme boyunca TEK yerel acquire, bekleme sonunda tek release', () async {
      wifiSequence(<Map<String, dynamic>>[wifiStatus('connecting'), wifiStatus('connecting'), wifiStatus('success', ip: '192.168.1.40')]);
      final outcome = await finish(apiAt(_ap, binding: android).awaitWifiConnection(timeout: const Duration(seconds: 30)));
      expect((outcome.value as WifiConnectResult).isSuccess, isTrue);
      expect(native.names, <String>['acquire', 'release']);
    });

    test('LAN adresi gerçek bağlamayla da yerel çağrı YAPMAZ', () async {
      await apiAt('http://192.168.1.30', binding: android).fetchPublicStatus();
      await apiAt('http://10.0.2.2:8081', binding: android).fetchPublicStatus();
      expect(native.names, isEmpty);
    });

    test('çağrı dönünce yerel release ÇOKTAN yapılmıştır (ardından gelen bulut isteği bağlı süreçte başlamaz)', () async {
      final api = apiAt(_ap, binding: android);
      await api.fetchPublicStatus();
      // Saat ilerletilmeden, çağrı döner dönmez: 300 ms'lik "kuyruk" yok.
      expect(native.names, <String>['acquire', 'release']);
      expect(clock.activeTimerCount, 0);
    });

    test('yerel eklenti yoksa (MissingPluginException): ilk çağrıdan sonra sarmalayıcı atlanır; isSupported false; istekler aynen yapılır', () async {
      native.override = (_) async => throw MissingPluginException('yok');
      final api = apiAt(_ap, binding: android);
      expect(android.isSupported, isTrue);

      await api.fetchPublicStatus(); // ilk çağrı: eklenti yok -> unsupported (istek yine de yapılır)
      expect(android.isSupported, isFalse, reason: 'arayüz eski yönergeye döner');
      expect(native.names, <String>['acquire']);

      await api.fetchPublicStatus();
      await api.fetchWifiStatus();
      expect(native.names, <String>['acquire'], reason: 'sonraki çağrılarda kanala HİÇ gidilmez (kira/yerel çağrı yok)');
      expect(events.where((e) => e.startsWith('req:')), hasLength(3), reason: 'üç istek de aynen yapıldı');
    });

    test('yerel "error/bind_denied" (VPN): istek yine denenir; ağ hatasına VPN ipucu eklenir, "pano ağında değil" ipucu EKLENMEZ', () async {
      native.override = (call) async => <String, Object?>{
            'status': call.method == 'acquire' ? 'error' : 'released',
            if (call.method == 'acquire') 'detail': 'bind_denied',
          };
      route('GET', '/api/status', (_) => throw http.ClientException('pano ulaşılamıyor'));

      final error = (await finish(apiAt(_ap, binding: android).fetchPublicStatus())).error as LocalApiException;

      expect(error.isNetwork, isTrue);
      expect(error.hint, BoardNetworkLease.bindDeniedHint);
      expect(error.message, '$_networkMessage ${BoardNetworkLease.bindDeniedHint}');
      expect(error.message, isNot(contains('AHBU')), reason: 'VPN nedeniyle reddedilirken "pano ağına bağlanın" denmez');
      expect(native.names, <String>['acquire', 'release']);
    });
  });

  group('LAN / emülatör / QA adreslerinde kira HİÇ alınmaz', () {
    const hosts = <String>[
      'http://192.168.1.30', // ev ağındaki cihaz (LAN doğrudan mod)
      'http://192.168.4.2', // kurulum ağı alt ağında ama kurulum ağı adresi değil
      'http://10.0.2.2:8081', // Android emülatörü -> QA simülatörü
      'http://127.0.0.1:8081',
      'http://localhost',
      'http://pano.local',
      'http://172.16.0.5',
      'http://100.64.0.9',
    ];

    test('tüm çağrı yolları: istek yapılır, kira alınmaz', () async {
      for (final host in hosts) {
        events.clear();
        for (final entry in allCalls.entries) {
          final outcome = await finish(entry.value.$1(apiAt(host, key: 'anahtar-test-1234')));
          expect(outcome.error, isNull, reason: '$host ${entry.key}: ${outcome.error}');
        }
        expect(events.where((e) => e.startsWith('req:')), hasLength(allCalls.length), reason: host);
        expect(events.where((e) => !e.startsWith('req:')), isEmpty, reason: '$host: kira olayı olmamalı');
        expect(fake.acquireCount, 0, reason: host);
      }
    });

    test('uzun işlemler de (awaitWifiConnection, connectWifiAndWait, scanWifi) LAN adresinde kira almaz', () async {
      wifiSequence(<Map<String, dynamic>>[wifiStatus('connecting'), wifiStatus('success', ip: '192.168.1.40')]);
      for (final host in hosts) {
        await finish(apiAt(host).awaitWifiConnection(timeout: const Duration(seconds: 30)));
        wifiSequence(<Map<String, dynamic>>[wifiStatus('success', ip: '192.168.1.40')]);
        await finish(apiAt(host).connectWifiAndWait('EvAgi', 'parola1234'));
        await finish(apiAt(host).scanWifi());
      }
      expect(fake.acquireCount, 0);
      expect(events.where((e) => e == 'release' || e.startsWith('acquire')), isEmpty);
    });

    test('QA yapılandırması (DEVICE_AP_HOST=10.0.2.2:8081): ne QA adresine ne 192.168.4.1\'e bağlanılır', () async {
      AppConfig.current = AppConfig.forTest(deviceApHost: '10.0.2.2:8081');
      await apiAt('http://10.0.2.2:8081').fetchPublicStatus();
      await apiAt(_ap).fetchPublicStatus();
      await AutomationApiService.recoveryAp(client: mock.client, clock: clock, boardNetwork: fake).fetchPublicStatus();
      expect(fake.acquireCount, 0);
    });

    test('adres, yapılandırılmış kurulum ağı adresine bağlıdır (AppConfig.deviceApHost = 192.168.7.1)', () async {
      AppConfig.current = AppConfig.forTest(deviceApHost: '192.168.7.1');
      await apiAt(_ap).fetchPublicStatus(); // artık kurulum ağı adresi değil
      expect(fake.acquireCount, 0);
      await apiAt('http://192.168.7.1').fetchPublicStatus();
      expect(fake.hosts, <String>['192.168.7.1']);
    });

    test('platform bağlamayı desteklemiyorsa (iOS/masaüstü/web) AP adresinde de kira istenmez; istek aynen yapılır', () async {
      fake.supported = false;
      await apiAt(_ap).fetchPublicStatus();
      await finish(apiAt(_ap).awaitWifiConnection(timeout: const Duration(seconds: 5)));
      expect(fake.acquireCount, 0);
      expect(events.where((e) => !e.startsWith('req:')), isEmpty);
      expect(mock.requests, isNotEmpty);
    });
  });

  group('bağlama başarısız: istek YİNE DE denenir; ağ hatasına doğru ipucu eklenir', () {
    Future<LocalApiException> networkFailure({Future<Object?> Function(AutomationApiService api)? call}) async {
      route('GET', '/api/status', (_) => throw http.ClientException('pano ulaşılamıyor'));
      final outcome = await finish((call ?? (a) => a.fetchPublicStatus())(apiAt(_ap)));
      expect(outcome.error, isA<LocalApiException>());
      return outcome.error as LocalApiException;
    }

    const failures = <BoardNetworkStatus, String>{
      BoardNetworkStatus.notOnBoardNetwork: _hintNotOnNetwork,
      BoardNetworkStatus.noWifi: _hintNotOnNetwork,
      BoardNetworkStatus.timeout: _hintNoRoute,
      BoardNetworkStatus.error: _hintNoRoute,
    };

    for (final entry in failures.entries) {
      test('${entry.key.wire}: istek denenir (başarılıysa sonuç döner); ağ hatasında ipucu "${entry.value}"', () async {
        fake.status = entry.key;
        // 1) bağlama başarısız ama pano yanıt veriyor: davranış bağlamasız sürümden kötü değil.
        final ok = await finish(apiAt(_ap).fetchPublicStatus());
        expect(ok.error, isNull);
        expect(ok.value, isA<Object>());
        expect(events, <String>[_acquireAp, 'req:GET /api/status', 'release']);

        // 2) istek ağ hatasıyla biter: ipucu eklenir; hata türü (ağ hatası) değişmez.
        events.clear();
        final error = await networkFailure();
        expect(error.isNetwork, isTrue);
        expect(error.statusCode, 0);
        expect(error.code, 'network');
        expect(error.hint, entry.value);
        expect(error.message, '$_networkMessage ${entry.value}');
        expect(error.toString(), error.message);
        expect(events, <String>[_acquireAp, 'req:GET /api/status', 'release']);
        expect(fake.activeLeases, 0);
      });
    }

    test('permissionDenied: kısa, teknik olmayan ipucu (sınıf adı/istisna metni yok)', () async {
      fake.status = BoardNetworkStatus.permissionDenied;
      final error = await networkFailure();
      expect(error.isNetwork, isTrue);
      expect(error.hint, isNotNull);
      expect(error.hint!.length, lessThan(120));
      expect(error.message, startsWith(_networkMessage));
      expect(error.message, isNot(anyOf(contains('Exception'), contains('SecurityException'), contains('permission_denied'))));
    });

    test('bağlama BAŞARILI (bound / already_bound) ya da desteklenmiyor: ağ hatası AYNEN kalır (ipucu yok)', () async {
      for (final status in <BoardNetworkStatus>[BoardNetworkStatus.bound, BoardNetworkStatus.alreadyBound, BoardNetworkStatus.unsupported]) {
        fake.status = status;
        final error = await networkFailure();
        expect(error.hint, isNull, reason: status.wire);
        expect(error.message, _networkMessage, reason: status.wire);
        expect(error.isNetwork, isTrue);
      }
    });

    test('ağ hatası olmayan hatalar (401, 409, 429) bağlama başarısız olsa da DEĞİŞMEZ', () async {
      fake.status = BoardNetworkStatus.notOnBoardNetwork;
      route('POST', '/api/wifi/connect', (_) => jsonResponse(<String, dynamic>{'error': 'unauthorized'}, status: 401));
      final unauthorized = (await finish(apiAt(_ap).connectWifi('EvAgi', 'parola1234'))).error as LocalApiException;
      expect(unauthorized.isUnauthorized, isTrue);
      expect(unauthorized.hint, isNull);
      expect(unauthorized.message, isNot(contains('AHBU')));

      route('POST', '/api/wifi/connect', (_) => jsonResponse(<String, dynamic>{'error': 'rate_limited', 'retry_after': 25}, status: 429));
      final limited = (await finish(apiAt(_ap).connectWifi('EvAgi', 'parola1234'))).error as LocalApiException;
      expect(limited.statusCode, 429);
      expect(limited.retryAfter, const Duration(seconds: 25));
      expect(limited.hint, isNull);
    });

    test('ipucu tek kez eklenir (iç içe kapsamlarda — tarama döngüsü, connectWifiAndWait — çiftlenmez)', () async {
      fake.status = BoardNetworkStatus.notOnBoardNetwork;
      route('GET', '/api/wifi/scan', (_) => throw http.ClientException('yok'));
      final scan = (await finish(apiAt(_ap).scanWifi())).error as LocalApiException;
      expect(_hintNotOnNetwork.allMatches(scan.message), hasLength(1));
      expect(scan.hint, _hintNotOnNetwork);

      route('POST', '/api/wifi/connect', (_) => throw http.ClientException('yok'));
      final connect = (await finish(apiAt(_ap).connectWifiAndWait('EvAgi', 'parola1234'))).error as LocalApiException;
      expect(_hintNotOnNetwork.allMatches(connect.message), hasLength(1));
      expect(connect.isNetwork, isTrue);
    });

    test('bağlama başarılıyken ağ kaybolursa ("pano ağından ayrıldı") ağ hatasına "ağda değil" ipucu eklenir', () async {
      route('GET', '/api/status', (_) {
        fake.loseNetwork();
        throw http.ClientException('bağlantı koptu');
      });
      final error = (await finish(apiAt(_ap).fetchPublicStatus())).error as LocalApiException;
      expect(error.hint, _hintNotOnNetwork);
    });

    test('awaitWifiConnection\'ın "belirsiz" sonucu ve 401 davranışı bağlama durumundan etkilenmez', () async {
      fake.status = BoardNetworkStatus.timeout;
      var calls = 0;
      route('GET', '/api/wifi/status', (_) {
        if (++calls == 1) return jsonResponse(wifiStatus('connecting'));
        throw http.ClientException('bağlantı koptu');
      });
      final outcome = await finish(apiAt(_ap).awaitWifiConnection(timeout: const Duration(seconds: 30)));
      expect((outcome.value as WifiConnectResult).outcome, WifiConnectOutcome.lostContact);
      expectSingleLease();
    });
  });

  group('kötü davranan bağlama çağrıyı bozmaz', () {
    test('acquire istisna fırlatırsa istek yine yapılır; ağ hatasında "yönlenme kurulamadı" ipucu; yutulan istisnanın TÜRÜ günlüğe yazılır', () async {
      final printed = <String?>[];
      final originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) => printed.add(message);
      addTearDown(() => debugPrint = originalDebugPrint);

      fake.acquireError = StateError('bağlama bozuk');
      final ok = await finish(apiAt(_ap).fetchPublicStatus());
      expect(ok.error, isNull);
      expect(events, <String>[_acquireAp, 'req:GET /api/status']);

      route('GET', '/api/status', (_) => throw http.ClientException('yok'));
      final error = (await finish(apiAt(_ap).fetchPublicStatus())).error as LocalApiException;
      expect(error.hint, _hintNoRoute);
      expect(error.message, isNot(contains('bağlama bozuk')), reason: 'ham teknik hata metni gösterilmez');

      expect(printed, contains('[BoardNetwork/Dart] acquire istisnası yutuldu (StateError)'));
      expect(printed.join('\n'), isNot(contains('bağlama bozuk')), reason: 'günlüğe istisna İLETİSİ yazılmaz, yalnız türü');
    });

    test('release istisna fırlatırsa çağrının sonucu/hatası değişmez', () async {
      fake.releaseError = StateError('bırakma bozuk');
      final ok = await finish(apiAt(_ap).fetchPublicStatus());
      expect(ok.error, isNull);
      expect(fake.releaseCount, 1);

      route('POST', '/api/wifi/connect', (_) => jsonResponse(<String, dynamic>{'error': 'busy'}, status: 409));
      final busy = (await finish(apiAt(_ap).connectWifi('EvAgi', 'parola1234'))).error as LocalApiException;
      expect(busy.isBusy, isTrue, reason: 'asıl hata korunur');
    });
  });

  group('varsayılan bağlama çözümü (BoardNetworkBinding.instance)', () {
    test('kurucuya bağlama verilmezse çağrı anında BoardNetworkBinding.instance kullanılır (override sonradan da geçerli)', () async {
      final api = AutomationApiService(baseUrl: _ap, client: mock.client, clock: clock);
      BoardNetworkBinding.overrideForTesting(fake);
      await api.fetchPublicStatus();
      expect(events, <String>[_acquireAp, 'req:GET /api/status', 'release']);

      final recovery = AutomationApiService.recoveryAp(client: mock.client, clock: clock);
      await recovery.fetchPublicStatus();
      expect(fake.acquireCount, 2);
    });

    test('override geri alınınca (Noop) hiçbir kira olayı olmaz; istek aynen yapılır', () async {
      final api = AutomationApiService(baseUrl: _ap, client: mock.client, clock: clock);
      BoardNetworkBinding.overrideForTesting(fake);
      BoardNetworkBinding.overrideForTesting(null);
      await api.fetchPublicStatus();
      expect(fake.acquireCount, 0);
      expect(events, <String>['req:GET /api/status']);
    });
  });

  group('mimari değişmez (kaynak taraması)', () {
    test('cihaza giden tüm HTTP istekleri tek yerden (_sendOnce) çıkar ve _send sarmalayıcısından geçer', () {
      final source = File('lib/services/automation_api_service.dart').readAsStringSync();
      final start = source.indexOf('Future<http.Response> _sendOnce(');
      final end = source.indexOf('Map<String, dynamic> _json(http.Response res)');
      expect(start, greaterThan(0), reason: '_sendOnce bulunamadı');
      expect(end, greaterThan(start), reason: '_json bulunamadı');

      final outside = source.substring(0, start) + source.substring(end);
      expect(
        RegExp(r'_client\.(get|post|put|delete|send|head|patch)\(').hasMatch(outside),
        isFalse,
        reason: 'HTTP istemcisi _sendOnce dışında kullanılmamalı: yeni uç noktalar kira sarmalayıcısını atlar',
      );
      expect(RegExp(r'\bhttp\.(get|post|put|delete|head|patch)\(').hasMatch(source), isFalse, reason: 'doğrudan http.* çağrısı yok');
      expect(RegExp(r'\b_sendOnce\(').allMatches(source), hasLength(2), reason: 'tanım + _send içindeki tek çağrı');

      final sendBody = source.substring(source.indexOf('Future<http.Response> _send('), start);
      expect(sendBody, contains('_withBoardNetwork('), reason: '_send kira sarmalayıcısından geçer');
    });
  });
}
