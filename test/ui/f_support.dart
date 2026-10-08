import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/models/install_template_models.dart';
import 'package:ev_otomasyon/services/automation_api_service.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/services/clock.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_controller.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_target.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';

/// Servis kurulum sihirbazı testleri için ortak yardımcılar (WP-F):
///
/// * [FakeDevice]: firmware'in yerel HTTP API'sini (CONTRACTS §3/§3b) taklit eder: kısıtlı/tam `status`,
///   `X-Device-Key`, `factory/init`, Wi-Fi bağlanma durumu, röle/panjur/DI, `config`, `mqtt/config`.
/// * [ServiceFakeCloud]: servis uçlarını (OTP, claim, cihaz listesi, envanter, uç nokta süresi, devreye alma)
///   bellek içinde yanıtlar; hepsi gerçek `ApiException` şekilleriyle.
/// * [ServiceHarness]: ikisini `AutomationState` ile ve sihirbaz denetleyicisiyle birleştirir.

const String kClaimedHome = '33333333-3333-4333-8333-333333333333';
const String kDeviceUid = 'AHBU-S3-A1B2C3';
const String kSetupPin = '482916';
const String kCustomerOtp = '135790';
const String kCustomerEmail = 'musteri@ornek.test';
const String kHomeWifiSsid = 'EvAgi';
const String kHomeWifiPass = 'ev-wifi-sifre-1';
const String kApPass = 'ap-parola-123';
const String kLanIp = '192.168.1.42';

/// Kurulum şablonu (İP-4.4) sahte kimlikleri.
const String kSiteId = '8c1d2e3f-4a5b-4c6d-8e7f-0123456789ab';
const String kTplId = '3f2a9c1e-5b7d-4e8f-9a01-23456789abcd';
const String kGlobalTplId = '11111111-2222-4333-8444-555555555555';

/// `ahbu-template/1` gövdesi: 8 röle (2 panjur çifti + [lights] lamba), 8 giriş, su sensörü + vana ([safety]).
Map<String, dynamic> templateBody({
  String id = kTplId,
  int version = 4,
  String name = 'B Tipi 3+1',
  String? siteId = kSiteId,
  bool safety = true,
}) =>
    <String, dynamic>{
      'schema': 'ahbu-template/1',
      'meta': <String, dynamic>{
        'template_id': id,
        'version': version,
        'name': name,
        'flat_type': '3+1',
        'site_id': siteId,
      },
      'ext_module': <String, dynamic>{'enabled': false, 'channels': 0, 'address': 1},
      'relays': <Map<String, dynamic>>[
        for (var p = 1; p <= 2; p++) ...<Map<String, dynamic>>[
          <String, dynamic>{'ch': 2 * p - 1, 'name': 'Oda $p Panjur Yukarı', 'room': 'Oda $p', 'type': 'shutter_up', 'runtime_s': 25},
          <String, dynamic>{'ch': 2 * p, 'name': 'Oda $p Panjur Aşağı', 'room': 'Oda $p', 'type': 'shutter_down', 'runtime_s': 25},
        ],
        for (var c = 5; c <= 8; c++)
          <String, dynamic>{'ch': c, 'name': 'Şablon Lamba ${c - 4}', 'room': 'Salon', 'type': 'light'},
      ],
      'dis': <Map<String, dynamic>>[
        for (var c = 1; c <= 8; c++)
          <String, dynamic>{'ch': c, 'name': 'Şablon Giriş $c', 'target_relay': c <= 4 ? c + 4 : 0, 'mode': 'toggle'},
      ],
      'safety': <String, dynamic>{
        'policy': <String, dynamic>{'on': true, 'dry_hold_ms': 10000},
        'zones': <Map<String, dynamic>>[<String, dynamic>{'id': 1, 'name': 'Ev'}],
        'sensors': safety
            ? <Map<String, dynamic>>[<String, dynamic>{'id': 'd7', 'kind': 'water', 'zone': 1, 'active_open': 0, 'name': 'Mutfak Su'}]
            : <Map<String, dynamic>>[],
        'actuators': <Map<String, dynamic>>[],
        'lights': <Map<String, dynamic>>[],
      },
    };

/// Test boyunca üretilen gizli değerler: sızıntı denetimi için bunların hiçbir kayıtta olmaması beklenir.
const String kCredentialPassword = 'bulut-kimlik-parolasi-xyz';
const String kLocalKey = 'yerel-anahtar-4321';

/// Etiket yeniden üretimi / acil sıfırlama yanıtlarındaki sahte tek seferlik değerler.
const String kReissuedPin = '705318';
const String kReissuedKey = 'yeni-yerel-anahtar-9988';

/// Ev sahibinin devir onay kodu ve yönetici hesabı parolası (sahte, yalnızca testlerde geçerli).
const String kOwnerConsentOtp = '864209';
const String kActorPassword = 'mevcut-parola-12';

// =============================================================================
// Sahte pano
// =============================================================================

class SimRelay {
  SimRelay(this.id, this.name, this.type);

  final int id;
  final String name;
  final int type; // 0 lamba, 1 panjur yukarı, 2 panjur aşağı, 3 darbe
  bool state = false;
}

class SimShutter {
  SimShutter(this.pair);

  final int pair;
  int pos = 0;
  int dir = 0; // 0 durdu, 1 yukarı, 2 aşağı
  DateTime? startedAt;
  int startPos = 0;
  int runtimeSec = 20;
  int durationMs = 0;
}

class SimDi {
  SimDi(this.id, this.name);

  final int id;
  final String name;
  bool state = false;
}

/// ESP32-S3 panosunun yerel API'si (firmware sözleşmesi). Saat [FakeClock]'tur.
class FakeDevice {
  FakeDevice({
    this.uid = kDeviceUid,
    this.localKey = kLocalKey,
    this.provisioned = true,
    required this.clock,
    int lightCount = 4,
    int shutterPairs = 2,
    int inputCount = 4,
  }) {
    var id = 1;
    for (var p = 1; p <= shutterPairs; p++) {
      relays.add(SimRelay(id++, 'Panjur $p Yukarı', 1));
      relays.add(SimRelay(id++, 'Panjur $p Aşağı', 2));
      shutters.add(SimShutter(p));
    }
    for (var i = 0; i < lightCount; i++) {
      relays.add(SimRelay(id, 'Lamba ${i + 1}', 0));
      id++;
    }
    for (var i = 1; i <= inputCount; i++) {
      dis.add(SimDi(i, 'Buton $i'));
    }
    _install();
  }

  final String uid;
  String? localKey;
  bool provisioned;
  final FakeClock clock;
  final MockApi api = MockApi();

  final List<SimRelay> relays = <SimRelay>[];
  final List<SimShutter> shutters = <SimShutter>[];
  final List<SimDi> dis = <SimDi>[];

  // Ağ / erişilebilirlik
  String apHost = '192.168.4.1';
  bool apReachable = true;
  bool lanReachable = true;
  String apPass = '';

  /// Kurulum ağı şu an WPA2 mi (cihaza özel `ap_pass`). Provizyonsuz pano AÇIK ağ yayınlar: Wi-Fi uçları
  /// bu durumda anahtarsız da çalışmaz (`403 unprovisioned`; CONTRACTS §3d).
  bool apSecured = true;

  /// Anahtarsız (AP kaynaklı) Wi-Fi isteği sayısı ve anahtar başlığı taşıyan Wi-Fi istekleri.
  int keylessWifiCalls = 0;
  int keyedWifiCalls = 0;
  String staIp = '';
  bool wifiConnected = false;
  bool timeSynced = true;
  bool mqttConfigured = false;
  bool mqttConnected = false;
  bool childLock = false;
  String firmware = '1.1.0';

  // Wi-Fi bağlanma
  String homeSsid = kHomeWifiSsid;
  String homePass = kHomeWifiPass;
  Duration connectDelay = const Duration(seconds: 3);
  bool dropApOnConnect = false;
  String connectState = 'idle';
  int connectReason = 0;
  DateTime? _connectStartedAt;
  String? _pendingSsid;
  String? _pendingPass;

  // Hata enjeksiyonu
  final Set<int> unresponsiveRelays = <int>{};
  bool rejectRuntimeApply = false;
  int wrongKeyAttempts = 0;

  /// Panoya giden yanlış anahtarlı isteklerin TOPLAMI (başarılı doğrulamada sıfırlanmaz; [wrongKeyAttempts] sıfırlanır).
  int wrongKeyTotal = 0;

  /// Erişilemeyen adrese (telefon o ağda değil / AP kapandı) giden istek, bu süre **sanal saatle** (FakeClock)
  /// beklendikten sonra ağ hatasıyla düşer: gerçek istemcideki bağlantı zaman aşımını (`AutomationApiService`
  /// 4 sn) taklit eder. Varsayılan sıfır: eski davranış (hata hemen gelir).
  Duration unreachableDelay = Duration.zero;

  // Gözlem (testler)
  String? receivedMqttServer;
  int? receivedMqttPort;
  String? receivedMqttUser;
  String? receivedMqttPass;
  int mqttConfigCount = 0;
  int factoryInitCount = 0;
  final Map<int, int> runtimeSec = <int, int>{};

  /// Darbe rölesi tetikleme sayısı (geri bildirimsiz).
  int impulseTriggers = 0;
  final List<String> keyHeaderHosts = <String>[]; // anahtar başlığı gönderilen adresler

  /// MQTT kimliği yazılınca çağrılır (sahte bulut cihazı çevrimiçi yapar).
  void Function(String server, int port, String user, String pass)? onMqttConfigured;

  // --- Güvenlik modülü (firmware v1.2.0, tasarım §3.2, §3.5; WP-A4) ---

  /// Pano güvenlik yeteneği ilan ediyor mu (`caps`); `false`: v1.1 yazılımı (uçlar 404).
  bool safetyCaps = false;

  /// Pano hırsız alarmı katmanını ilan ediyor mu (`caps` `intrusion`; firmware v1.2.1, Faz 2 F2.B.7). `false`: v1.2.0
  /// davranışı (sensör `flags` > 0x07 `bad_value` ile reddedilir, `intrusion` öğesi bilinmez).
  bool intrusionCaps = false;

  /// `true`: yerel anahtarla yapılandırma yazımı gevşetme sayılır ve reddedilir (`403 local_loosen_forbidden`, karar
  /// 7.2b-7; Faz 2 F2.D.5 bulut önerisi testleri).
  bool loosenForbidden = false;

  // --- Kurulum şablonu (firmware v1.3.0, CONTRACTS §3e) ---

  /// Pano şablonu destekliyor mu: `false` = v1.2.x (`/api/template*` 404, durumda `tpl` yok).
  bool templateCaps = false;

  /// Panoda yüklü şablon (`tpl {id, ver}`) ve etiket.
  String? tplId;
  int tplVer = 0;
  String tplLabel = '';

  /// Ethernet alanları (firmware v1.3.0; `null` = durumda alan yok).
  bool? ethConnected;

  /// Bir sonraki `POST /api/template/apply` bu hatayla reddedilir: `(status, error, path)` (tek seferlik).
  (int, String, String?)? templateRejectOnce;

  /// Gelen uygulama zarfları.
  final List<Map<String, dynamic>> templateApplies = <Map<String, dynamic>>[];

  /// Ek röle modülü (`/api/config`, `/api/status`).
  bool extEnabled = false;
  int extAddress = 1;

  /// Röle -> eylemci türü (`relays[].act`).
  final Map<int, String> relayAct = <int, String>{};

  /// Panonun bildirdiği eylemciler / sensörler (`state.actuators[]`, `state.sensors[]`).
  final List<Map<String, dynamic>> boardActuators = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> boardSensors = <Map<String, dynamic>>[];

  /// Güvenlik yapılandırmasının sürümü ve panodaki yapılandırma (firmware biçimi: `{policy?, zones?, lights, sensors,
  /// actuators}`; `null` = hiç yazılmadı). Yazım firmware F5 gibi TEK öğelik yamalarla olur ([safetyPatches]).
  int safetyRev = 3;
  Map<String, dynamic>? savedSafetyConfig;
  final List<Map<String, dynamic>> safetyPatches = <Map<String, dynamic>>[];

  /// `POST /api/alarm/test` ile test edilen bölgeler ve olay halkası (`GET /api/events`).
  final List<int> alarmTests = <int>[];
  final List<Map<String, dynamic>> events = <Map<String, dynamic>>[];

  /// Bölge testinin sonucu: geri bildirimle ölçülen süre (`null` = geri bildirim yok).
  int? testResultFbMs;
  bool testResultOk = true;

  void _install() {
    _route('GET', '/api/status', _status);
    _route('GET', '/api/auth/check', _authCheck);
    _route('POST', '/api/factory/init', _factoryInit);
    _route('POST', '/api/wifi/connect', _wifiConnect);
    _route('GET', '/api/wifi/scan', _wifiScan);
    _route('GET', '/api/wifi/status', _wifiStatus);
    _route('POST', '/api/mqtt/config', _mqttConfig);
    _route('POST', '/api/relay', _relayCmd);
    _route('POST', '/api/all', _all);
    _route('GET', '/api/config', _config);
    _route('GET', '/api/child-lock', _childLockGet);
    _route('POST', '/api/child-lock', _childLockPost);
    _route('GET', '/api/safety/config', _safetyConfigGet);
    _route('POST', '/api/safety/config', _safetyConfigPost);
    _route('POST', '/api/alarm/test', _alarmTest);
    _route('GET', '/api/events', _events);
    _route('GET', '/api/template', _templateGet);
    _route('POST', '/api/template/apply', _templateApply);
  }

  /// Ucu kaydeder. [unreachableDelay] > 0 iken erişilemeyen adrese giden istek önce o süre (sanal saat) bekler;
  /// aksi halde işleyici eskisi gibi eşzamanlı çalışır.
  void _route(String method, String path, http.Response Function(RecordedRequest r) handler) {
    api.on(method, path, (r) {
      if (unreachableDelay == Duration.zero || _isReachable(r)) return handler(r);
      return _failAfterDelay(r, handler);
    });
  }

  Future<http.Response> _failAfterDelay(RecordedRequest r, http.Response Function(RecordedRequest r) handler) async {
    final gate = Completer<void>();
    clock.timer(unreachableDelay, gate.complete);
    await gate.future;
    return handler(r); // hâlâ erişilemezse işleyicinin `_reach`'i ağ hatası fırlatır
  }

  // --- yardımcılar ---
  http.Response _json(Object body, {int status = 200}) => jsonResponse(body, status: status);

  http.Response _err(int status, String error, {Map<String, dynamic>? extra}) =>
      jsonResponse(<String, dynamic>{'error': error, ...?extra}, status: status);

  bool _isReachable(RecordedRequest r) {
    _advance(); // zaman geçtiyse Wi-Fi bağlanma sonucu / AP kapanışı bu istek yanıtlanmadan ÖNCE işlenir
    final host = r.url.host;
    return (host == apHost && apReachable) || (host == staIp && staIp.isNotEmpty && wifiConnected && lanReachable);
  }

  /// Adres erişilebilir değilse ağ hatası (telefon o ağda değil / AP kapandı).
  void _reach(RecordedRequest r) {
    if (!_isReachable(r)) throw const SocketException('Bağlantı kurulamadı');
  }

  String? _key(RecordedRequest r) => r.headers['X-Device-Key'] ?? r.headers['x-device-key'];

  /// Anahtar denetimi: null = geçti, aksi halde yanıt.
  http.Response? _auth(RecordedRequest r) {
    if (!provisioned || localKey == null) return _err(403, 'unprovisioned');
    final key = _key(r);
    if (key == null || key.isEmpty) return _err(401, 'unauthorized');
    keyHeaderHosts.add(r.url.host);
    if (key != localKey) {
      wrongKeyAttempts++;
      wrongKeyTotal++;
      if (wrongKeyAttempts >= 5) return _err(423, 'locked', extra: <String, dynamic>{'retry_after': 60});
      return _err(401, 'unauthorized');
    }
    wrongKeyAttempts = 0;
    return null;
  }

  /// Wi-Fi servis uçları (`scan`, `connect`, `status`): geçerli anahtar YA DA AP kaynaklı anahtarsız erişim
  /// (istemci SoftAP adresinden bağlı + AP WPA2 + pano provizyonlu). Anahtarsız ve AP dışı -> 401.
  http.Response? _authApOrKey(RecordedRequest r) {
    if (!provisioned || localKey == null) return _err(403, 'unprovisioned');
    final viaAp = r.url.host == apHost && apSecured;
    final key = _key(r);
    if (viaAp) {
      // AP kaynaklı yolda yetki anahtardan bağımsızdır; yanlış anahtar hata sayacına işlenmez.
      if (key == null || key.isEmpty) {
        keylessWifiCalls++;
      } else {
        keyedWifiCalls++;
        keyHeaderHosts.add(r.url.host);
      }
      return null;
    }
    if (key == null || key.isEmpty) return _err(401, 'unauthorized');
    keyedWifiCalls++;
    return _auth(r);
  }

  void _advance() {
    final now = clock.now();
    // Wi-Fi bağlanma sonucu
    if (connectState == 'connecting' && _connectStartedAt != null && now.difference(_connectStartedAt!) >= connectDelay) {
      if (_pendingSsid == homeSsid && _pendingPass == homePass) {
        connectState = 'success';
        wifiConnected = true;
        staIp = kLanIp;
        connectReason = 0;
        if (dropApOnConnect) apReachable = false;
      } else if (_pendingSsid != homeSsid) {
        connectState = 'failed';
        connectReason = 201; // ağ bulunamadı
      } else {
        connectState = 'failed';
        connectReason = 202; // doğrulama hatası (yanlış şifre)
      }
    }
    // Panjur süresi dolumu
    for (final s in shutters) {
      if (s.dir == 0) continue;
      final started = s.startedAt!;
      if (now.difference(started).inMilliseconds >= s.durationMs) {
        s.pos = s.dir == 1 ? 100 : 0;
        s.dir = 0;
        s.startedAt = null;
      }
    }
  }

  int _posOf(SimShutter s) {
    if (s.dir == 0) return s.pos;
    final elapsed = clock.now().difference(s.startedAt!).inMilliseconds;
    final delta = (elapsed * 100) ~/ (s.runtimeSec * 1000);
    if (s.dir == 1) return (s.startPos + delta).clamp(0, 100);
    return (s.startPos - delta).clamp(0, 100);
  }

  bool relayState(int id) => relays.firstWhere((r) => r.id == id).state;

  // --- uçlar ---
  http.Response _status(RecordedRequest r) {
    _reach(r);
    _advance();
    final key = _key(r);
    if (!provisioned || key == null || key.isEmpty) {
      return _json(<String, dynamic>{
        'device': uid,
        'name': 'Pano',
        'fw': firmware,
        'provisioned': provisioned,
        'wifi_connected': wifiConnected,
      });
    }
    final denied = _auth(r);
    if (denied != null) return denied;
    return _json(<String, dynamic>{
      'device': uid,
      'name': 'Pano',
      'device_name': 'Pano',
      'fw': firmware,
      'provisioned': true,
      'ip': wifiConnected ? staIp : apHost,
      'wifi_rssi': wifiConnected ? -52 : 0,
      'uptime_sec': 100,
      'wifi_connected': wifiConnected,
      'wifi_sta_ssid': wifiConnected ? homeSsid : '',
      'wifi_sta_ip': wifiConnected ? staIp : '',
      'wifi_sta_rssi': wifiConnected ? -52 : 0,
      'wifi_ap_active': apReachable,
      'wifi_ap_ip': apHost,
      'wifi_ap_ssid': 'AHBU-A1B2C3',
      'wifi_last_reason': 0,
      'wifi_connect_state': connectState,
      'wifi_connect_reason': connectReason,
      'time_synced': timeSynced,
      'mqtt_configured': mqttConfigured,
      'mqtt_connected': mqttConnected,
      'total_relays': relays.length,
      'total_dis': dis.length,
      'child_lock': childLock,
      'last_id': '',
      if (extEnabled) 'ext_module_enabled': true,
      if (templateCaps && tplId != null) 'tpl': <String, dynamic>{'id': tplId, 'ver': tplVer},
      if (ethConnected != null) ...<String, dynamic>{
        'eth_connected': ethConnected,
        'eth_ip': ethConnected! ? '192.168.1.77' : '',
        'net_if': ethConnected! ? 'eth' : (wifiConnected ? 'wifi' : 'none'),
      },
      if (safetyCaps) 'caps': <String>['safety', 'actuator', 'event', 'cfg', if (intrusionCaps) 'intrusion'],
      'relays': <Map<String, dynamic>>[
        for (final r in relays)
          <String, dynamic>{'id': r.id, 'name': r.name, 'type': r.type, 'state': r.state, 'act': ?relayAct[r.id]},
      ],
      if (safetyCaps && (boardActuators.isNotEmpty || boardSensors.isNotEmpty)) ...<String, dynamic>{
        'actuators': boardActuators,
        'sensors': boardSensors,
        'safety': <String, dynamic>{
          'policy': 'on',
          'mode': 'normal',
          'zones': <Map<String, dynamic>>[
            <String, dynamic>{'id': 1, 'st': 'normal'},
          ],
        },
      },
      'shutters': <Map<String, dynamic>>[
        for (final s in shutters)
          <String, dynamic>{
            'pair': s.pair,
            'is_shutter': true,
            'is_moving': s.dir != 0,
            'moving': s.dir != 0,
            'dir': s.dir,
            'pos': _posOf(s),
            'target': 255,
          },
      ],
      'dis': <Map<String, dynamic>>[
        for (final d in dis) <String, dynamic>{'id': d.id, 'name': d.name, 'state': d.state},
      ],
    });
  }

  http.Response _authCheck(RecordedRequest r) {
    _reach(r);
    final denied = _auth(r);
    return denied ?? _json(<String, dynamic>{'status': 'ok'});
  }

  http.Response _factoryInit(RecordedRequest r) {
    _reach(r);
    if (provisioned) return _err(403, 'already_provisioned');
    final body = r.json ?? const <String, dynamic>{};
    final key = body['local_key'];
    final ap = body['ap_pass'];
    if (key is! String || key.length < 8 || key.length > 32) return _err(400, 'invalid_key');
    if (ap is! String || ap.length < 8 || ap.length > 32) return _err(400, 'invalid_ap_pass');
    factoryInitCount++;
    localKey = key;
    apPass = ap;
    provisioned = true;
    return _json(<String, dynamic>{'status': 'ok'});
  }

  http.Response _wifiConnect(RecordedRequest r) {
    _reach(r);
    final denied = _authApOrKey(r);
    if (denied != null) return denied;
    if (connectState == 'connecting') return _err(409, 'busy');
    final body = r.json ?? const <String, dynamic>{};
    final ssid = body['ssid'];
    if (ssid is! String || ssid.isEmpty) return _err(400, 'invalid_ssid');
    _pendingSsid = ssid;
    _pendingPass = (body['pass'] as String?) ?? '';
    connectState = 'connecting';
    connectReason = 0;
    _connectStartedAt = clock.now();
    return _json(<String, dynamic>{'status': 'connecting'});
  }

  /// `GET /api/wifi/status` (CONTRACTS §3d): bağlanma sonucunun tek doğruluk kaynağı.
  http.Response _wifiStatus(RecordedRequest r) {
    _reach(r);
    final denied = _authApOrKey(r);
    if (denied != null) return denied;
    _advance();
    return _json(<String, dynamic>{
      'wifi_connect_state': connectState,
      'wifi_connect_reason': connectReason,
      'wifi_connected': wifiConnected,
      'wifi_sta_ssid': wifiConnected ? homeSsid : '',
      'wifi_sta_ip': wifiConnected ? staIp : '',
      'wifi_rssi': wifiConnected ? -52 : 0,
      'ap_active': apReachable,
    });
  }

  http.Response _wifiScan(RecordedRequest r) {
    _reach(r);
    final denied = _authApOrKey(r);
    if (denied != null) return denied;
    return _json(<String, dynamic>{
      'status': 'done',
      'cached': false,
      'networks': <Map<String, dynamic>>[
        <String, dynamic>{'ssid': homeSsid, 'rssi': -48, 'enc': true},
        <String, dynamic>{'ssid': 'Komsu Wifi', 'rssi': -80, 'enc': true},
      ],
    });
  }

  http.Response _mqttConfig(RecordedRequest r) {
    _reach(r);
    final denied = _auth(r);
    if (denied != null) return denied;
    final body = r.json ?? const <String, dynamic>{};
    final server = body['server'];
    final port = body['port'];
    final user = body['user'];
    final pass = body['pass'];
    if (server is! String || port is! int || user is! String || pass is! String || pass.isEmpty) {
      return _err(400, 'invalid_value');
    }
    receivedMqttServer = server;
    receivedMqttPort = port;
    receivedMqttUser = user;
    receivedMqttPass = pass;
    mqttConfigCount++;
    mqttConfigured = true;
    onMqttConfigured?.call(server, port, user, pass);
    return _json(<String, dynamic>{'status': 'ok'});
  }

  http.Response _relayCmd(RecordedRequest r) {
    _reach(r);
    final denied = _auth(r);
    if (denied != null) return denied;
    _advance();
    final q = r.url.queryParameters;
    if (q.containsKey('pair')) {
      final pair = int.tryParse(q['pair'] ?? '');
      final s = shutters.where((x) => x.pair == pair).firstOrNull;
      if (s == null) return _err(400, 'invalid_pair');
      final now = clock.now();
      switch (q['cmd']) {
        case 'up':
        case 'down':
          final dir = q['cmd'] == 'up' ? 1 : 2;
          if (s.dir == dir) break;
          if (s.dir != 0) s.pos = _posOf(s);
          s.dir = dir;
          s.startedAt = now;
          s.startPos = s.pos;
          s.durationMs = (s.runtimeSec + 2) * 1000; // tam hareket: süre + 2 sn oturma payı (ShutterFsm)
        case 'stop':
          if (s.dir != 0) {
            s.pos = _posOf(s);
            s.dir = 0;
            s.startedAt = null;
          }
        default:
          return _err(400, 'unknown_command');
      }
      return _json(<String, dynamic>{'status': 'queued'});
    }
    final ch = int.tryParse(q['ch'] ?? '');
    final relay = relays.where((x) => x.id == ch).firstOrNull;
    if (relay == null) return _err(400, 'invalid_channel');
    if (unresponsiveRelays.contains(relay.id)) return _json(<String, dynamic>{'status': 'queued'});
    if (relay.type == 3) {
      // Darbe rölesi: çok kısa süre çeker ve kendiliğinden bırakır; durum yoklamasında hiç "açık" görünmez.
      impulseTriggers++;
      return _json(<String, dynamic>{'status': 'queued'});
    }
    if (q['cmd'] == 'toggle') {
      relay.state = !relay.state;
    } else {
      relay.state = q['state'] == '1';
    }
    return _json(<String, dynamic>{'status': 'queued'});
  }

  http.Response _all(RecordedRequest r) {
    _reach(r);
    final denied = _auth(r);
    if (denied != null) return denied;
    if (r.url.queryParameters['cmd'] == 'lightsoff') {
      for (final x in relays.where((x) => x.type == 0)) {
        x.state = false;
      }
    }
    return _json(<String, dynamic>{'status': 'queued'});
  }

  http.Response _config(RecordedRequest r) {
    _reach(r);
    final denied = _auth(r);
    if (denied != null) return denied;
    return _json(<String, dynamic>{
      'device_name': 'Pano',
      if (extEnabled) ...<String, dynamic>{'ext_module_enabled': true, 'ext_module_address': extAddress},
      'total_relays': relays.length,
      'total_dis': dis.length,
      'relays': <Map<String, dynamic>>[
        for (final x in relays)
          <String, dynamic>{
            'id': x.id,
            'name': x.name,
            'type': x.type,
            'runtime_sec': runtimeSec[x.id] ?? 20,
          },
      ],
      'dis': <Map<String, dynamic>>[
        for (final d in dis) <String, dynamic>{'id': d.id, 'name': d.name, 'target_relay': 0, 'mode': 0},
      ],
    });
  }

  http.Response _childLockGet(RecordedRequest r) {
    _reach(r);
    final denied = _auth(r);
    return denied ?? _json(<String, dynamic>{'child_lock': childLock});
  }

  http.Response _childLockPost(RecordedRequest r) {
    _reach(r);
    final denied = _auth(r);
    if (denied != null) return denied;
    childLock = (r.json?['enabled'] as bool?) ?? childLock;
    return _json(<String, dynamic>{'status': 'queued'});
  }

  http.Response _safetyConfigGet(RecordedRequest r) {
    _reach(r);
    final denied = _auth(r);
    if (denied != null) return denied;
    if (!safetyCaps) return _err(404, 'not_found');
    return _json(<String, dynamic>{'rev': safetyRev, 'crc': '00000000', ...?savedSafetyConfig});
  }

  http.Response _safetyConfigPost(RecordedRequest r) {
    _reach(r);
    final denied = _auth(r);
    if (denied != null) return denied;
    if (!safetyCaps) return _err(404, 'not_found');
    if (loosenForbidden) return _json(<String, dynamic>{'error': 'local_loosen_forbidden'}, status: 403);
    // Firmware F5 sözleşmesi (CONTRACTS §2.6): {base_rev?, set:{sensor|actuator|light:{…}}} ya da {base_rev?, del:{…}}.
    final body = r.json ?? const <String, dynamic>{};
    if (body.containsKey('base_rev') && body['base_rev'] != safetyRev) {
      return _json(<String, dynamic>{'error': 'cfg_conflict', 'rev': safetyRev, 'crc': '00000000'}, status: 409);
    }
    final set = body['set'] is Map ? Map<String, dynamic>.from(body['set'] as Map) : null;
    final del = body['del'] is Map ? Map<String, dynamic>.from(body['del'] as Map) : null;
    final unknown = body.keys.where((k) => k != 'base_rev' && k != 'set' && k != 'del');
    if ((set == null) == (del == null) || unknown.isNotEmpty || (set ?? del)!.length != 1) {
      return _json(<String, dynamic>{'error': 'cfg_invalid', 'detail': 'bad_field'}, status: 400);
    }
    final cfg = <String, dynamic>{
      'lights': <Map<String, dynamic>>[],
      'sensors': <Map<String, dynamic>>[],
      'actuators': <Map<String, dynamic>>[],
      ...?savedSafetyConfig,
    };
    List<Map<String, dynamic>> list(String k) =>
        (cfg[k] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final sensors = list('sensors');
    final actuators = list('actuators');
    final lights = list('lights');
    final what = (set ?? del)!.keys.single;
    final value = (set ?? del)![what];
    if (del != null) {
      if (what == 'sensor') sensors.removeWhere((s) => s['id'] == value);
      if (what == 'actuator') {
        final idx = int.parse((value as String).substring(1)) - 1;
        if (idx < 0 || idx >= actuators.length) return _json(<String, dynamic>{'error': 'cfg_invalid', 'detail': 'bad_id'}, status: 400);
        actuators.removeAt(idx);
        for (var i = 0; i < actuators.length; i++) {
          actuators[i]['id'] = 'a${i + 1}'; // silme sonraki kimlikleri kaydırır
        }
      }
    } else {
      final item = Map<String, dynamic>.from(value as Map);
      final flags = item['flags'];
      if (what == 'sensor' && !intrusionCaps && flags is int && flags > 0x07) {
        return _json(<String, dynamic>{'error': 'cfg_invalid', 'detail': 'bad_value'}, status: 400);
      }
      if (what == 'intrusion') {
        if (!intrusionCaps) return _json(<String, dynamic>{'error': 'cfg_invalid', 'detail': 'bad_field'}, status: 400);
        savedSafetyConfig = <String, dynamic>{...cfg, 'intrusion': item};
        safetyPatches.add(Map<String, dynamic>.of(body));
        safetyRev++;
        return _json(<String, dynamic>{'status': 'ok', 'rev': safetyRev, 'crc': '00000000'});
      }
      if (what == 'sensor') {
        final i = sensors.indexWhere((s) => s['id'] == item['id']);
        if (i >= 0) {
          sensors[i] = item;
        } else {
          sensors.add(item);
        }
      } else if (what == 'actuator') {
        final id = item['id'] as String?;
        if (id == null) {
          actuators.add(<String, dynamic>{...item, 'id': 'a${actuators.length + 1}'});
        } else {
          final idx = int.parse(id.substring(1)) - 1;
          if (idx < 0 || idx >= actuators.length) return _json(<String, dynamic>{'error': 'cfg_invalid', 'detail': 'bad_id'}, status: 400);
          actuators[idx] = item;
        }
      } else if (what == 'light') {
        lights
          ..removeWhere((l) => l['relay'] == item['relay'])
          ..add(item);
      } else {
        return _json(<String, dynamic>{'error': 'cfg_invalid', 'detail': 'bad_field'}, status: 400);
      }
    }
    savedSafetyConfig = <String, dynamic>{...cfg, 'sensors': sensors, 'actuators': actuators, 'lights': lights};
    safetyPatches.add(Map<String, dynamic>.of(body));
    safetyRev++;
    return _json(<String, dynamic>{'status': 'ok', 'rev': safetyRev, 'crc': '00000000'});
  }

  http.Response _alarmTest(RecordedRequest r) {
    _reach(r);
    final denied = _auth(r);
    if (denied != null) return denied;
    if (!safetyCaps) return _err(404, 'not_found');
    final zone = (r.json?['zone'] as int?) ?? 0;
    alarmTests.add(zone);
    events.add(<String, dynamic>{
      'eid': 'a1b2c3d4-${events.length + 1}',
      'type': 'test_result',
      'zone': zone,
      'ok': testResultOk,
      'fb_ms': ?testResultFbMs,
    });
    return _json(<String, dynamic>{'ok': true, 'id': r.json?['id']});
  }

  http.Response _events(RecordedRequest r) {
    _reach(r);
    final denied = _auth(r);
    if (denied != null) return denied;
    if (!safetyCaps) return _err(404, 'not_found');
    return _json(<String, dynamic>{'events': events});
  }

  http.Response _templateGet(RecordedRequest r) {
    _reach(r);
    final denied = _auth(r);
    if (denied != null) return denied;
    if (!templateCaps) return _err(404, 'not_found');
    return _json(<String, dynamic>{
      'template_id': tplId,
      'version': tplVer,
      'label': tplLabel,
      'applied_at_uptime_s': tplId == null ? null : 90,
    });
  }

  /// `POST /api/template/apply`: zarf kaydedilir; ret enjekte edilmediyse röle/panjur/giriş listesi şablondan kurulur.
  http.Response _templateApply(RecordedRequest r) {
    _reach(r);
    final denied = _auth(r);
    if (denied != null) return denied;
    if (!templateCaps) return _err(404, 'not_found');
    final body = r.json ?? const <String, dynamic>{};
    templateApplies.add(Map<String, dynamic>.of(body));
    final reject = templateRejectOnce;
    if (reject != null) {
      templateRejectOnce = null;
      return _err(reject.$1, reject.$2, extra: <String, dynamic>{'path': ?reject.$3});
    }
    if (shutters.any((s) => s.dir != 0)) return _err(409, 'busy');
    final tpl = Map<String, dynamic>.from(body['template'] as Map);
    final meta = Map<String, dynamic>.from(tpl['meta'] as Map);
    relays.clear();
    shutters.clear();
    for (final raw in tpl['relays'] as List) {
      final m = Map<String, dynamic>.from(raw as Map);
      final type = switch (m['type']) { 'shutter_up' => 1, 'shutter_down' => 2, 'impulse' => 3, _ => 0 };
      relays.add(SimRelay(m['ch'] as int, m['name'] as String, type));
      if (type == 1) {
        final s = SimShutter(((m['ch'] as int) + 1) ~/ 2)..runtimeSec = (m['runtime_s'] as int?) ?? 20;
        shutters.add(s);
      }
    }
    dis
      ..clear()
      ..addAll(<SimDi>[
        for (final raw in tpl['dis'] as List)
          SimDi((raw as Map)['ch'] as int, raw['name'] as String),
      ]);
    tplId = meta['template_id'] as String;
    tplVer = meta['version'] as int;
    tplLabel = (body['label'] as String?) ?? '';
    safetyRev++;
    return _json(<String, dynamic>{'ok': true, 'template_id': tplId, 'version': tplVer, 'rev': safetyRev});
  }

  // --- test kancaları ---
  void setDi(int id, bool pressed) => dis.firstWhere((d) => d.id == id).state = pressed;

  /// Bulut `set_runtime` komutu (sunucu uç noktayı güncelleyince): pano hareket halindeyse reddeder.
  void applyRuntime(int pair, int seconds) {
    _advance();
    final s = shutters.where((x) => x.pair == pair).firstOrNull;
    if (s == null || rejectRuntimeApply || s.dir != 0 || !mqttConfigured) return;
    s.runtimeSec = seconds;
    runtimeSec[2 * pair - 1] = seconds;
    runtimeSec[2 * pair] = seconds;
  }

  int shutterRuntime(int pair) => shutters.firstWhere((s) => s.pair == pair).runtimeSec;
  bool shutterMoving(int pair) {
    _advance();
    return shutters.firstWhere((s) => s.pair == pair).dir != 0;
  }

  void dispose() {}
}

// =============================================================================
// Sahte bulut (servis uçları)
// =============================================================================

class ServiceFakeCloud extends FakeCloudApi {
  // `clock` hem üst sınıfa iletilir hem [_delayClock]'a alınır: süper parametre bunu yapamaz.
  // ignore: use_super_parameters
  ServiceFakeCloud({Clock clock = const SystemClock()})
      : _delayClock = clock,
        super(clock: clock);

  /// Gecikme kancalarının ([devicesDelay]) zamanlayıcıları için saat (testte [FakeClock]).
  final Clock _delayClock;

  /// Telefonun interneti var mı: telefon panonun kurulum ağındayken (AP) internet YOKTUR; sunucu çağrıları
  /// ağ hatasıyla ([ApiException.network]) düşer.
  bool internetUp = true;

  void _net() {
    if (!internetUp) throw ApiException.network();
  }

  /// [duration] kadar **sanal saatle** bekler (saat ilerletilmedikçe tamamlanmaz).
  Future<void> _wait(Duration duration) {
    final gate = Completer<void>();
    _delayClock.timer(duration, gate.complete);
    return gate.future;
  }

  /// Sunucu tarafındaki "doğru" değerler.
  String expectedPin = kSetupPin;
  String expectedOtp = kCustomerOtp;
  String deviceUid = kDeviceUid;

  Object? otpError;
  Object? claimErrorOnce;
  Object? commissionError;
  Object? updateEndpointError;
  // Üst sınıf (FakeCloudApi) da aynı kancayı tanımlayabilir; burada bu sınıf tek başına çalışsın diye korunur.
  // ignore: overridden_fields, annotate_overrides
  Object? devicesError;
  Object? fetchHomesErrorOnce;

  /// Atanırsa `updateEndpoint` bu kapı açılana kadar bekler (sunucu isteği "uçuşta": ör. panjur ölçüm hazırlığı
  /// 300 sn'yi yazarken sihirbazdan çıkış denemesi). Pano tarafındaki etki (`onRuntime`) kapı açılınca uygulanır.
  Completer<void>? updateEndpointGate;

  /// Her `updateEndpoint` çağrısı BAŞTAN bir hata tüketir (kuyruk boşalınca çağrılar normal çalışır; kalıcı
  /// [updateEndpointError] ayrıdır): "ilk istek 409 CONFLICT, ikincisi başarılı" gibi sırayla değişen sunucu yanıtları.
  final List<Object> updateEndpointErrorQueue = <Object>[];

  /// `devices` yanıtı bu süre (sanal saat) sonra gelir (varsayılan sıfır: hemen).
  Duration devicesDelay = Duration.zero;

  /// `true` ise bir sonraki claim sunucuda **uygulanır** (ev + cihaz + servis üyeliği oluşur, `claimApplied`
  /// olur), ama yanıt telefona ulaşmaz: istemci [ApiException.network] görür (kopan bağlantı).
  bool claimLosesResponseOnce = false;

  /// Cihaz sunucuda artık sahiplenilmiş (yanıtı kaybolan claim uygulandı). Sunucu **idempotent değildir**: bundan
  /// sonraki her claim isteği (tek kullanımlık PIN/OTP) `409` ile reddedilir ve [claimCalls] artar.
  bool claimApplied = false;

  int otpRequests = 0;
  int claimCalls = 0;
  int wrongPinCount = 0;
  int wrongOtpCount = 0;
  final List<CommissioningChecks> commissionChecks = <CommissioningChecks>[];
  final List<String> commissionNotes = <String>[];
  final List<Map<String, dynamic>> endpointUpdates = <Map<String, dynamic>>[];
  final List<String> homeIdsUsed = <String>[];
  bool deviceOnline = false;
  DateTime? deviceLastSeen;
  bool serverCommissionRejects = false;

  /// Envanter satırları (`fetchDeviceInventory`).
  List<InventoryDeviceModel> inventory = <InventoryDeviceModel>[];

  /// Uç nokta süresi güncellenince pano tarafına iletilir (`set_runtime`).
  void Function(int pair, int seconds)? onRuntime;

  /// Claim edilen evin kimliği.
  String claimedHomeId = kClaimedHome;
  DeviceMqttCredential claimCredential = const DeviceMqttCredential(
    host: 'mqtt.ornek.test',
    port: 8884,
    username: 'd_h_kurulum',
    password: kCredentialPassword,
    topicId: 'h_kurulum',
  );
  List<String> claimWarnings = const <String>[];

  List<EndpointModel> _claimedEndpoints() => <EndpointModel>[
        for (var p = 1; p <= 2; p++) ...<EndpointModel>[
          EndpointModel(
            id: 'ep-up-$p',
            homeId: claimedHomeId,
            deviceUuid: deviceUid,
            channel: 2 * p - 1,
            shutterPair: p,
            name: 'Panjur $p Yukarı',
            room: 'Salon',
            endpointType: 'shutter',
            currentState: false,
          ),
          EndpointModel(
            id: 'ep-down-$p',
            homeId: claimedHomeId,
            deviceUuid: deviceUid,
            channel: 2 * p,
            shutterPair: p,
            name: 'Panjur $p Aşağı',
            room: 'Salon',
            endpointType: 'shutter',
            currentState: false,
          ),
        ],
        for (var c = 5; c <= 8; c++)
          EndpointModel(
            id: 'ep-light-$c',
            homeId: claimedHomeId,
            deviceUuid: deviceUid,
            channel: c,
            name: 'Lamba ${c - 4}',
            room: 'Salon',
            endpointType: 'light',
            currentState: false,
          ),
      ];

  // --- Site / kurulum şablonları (CONTRACTS §3e) ---
  List<InstallSite> sites = <InstallSite>[const InstallSite(id: kSiteId, name: 'Güneş Sitesi', city: 'Ankara', district: 'Çankaya')];
  final Map<String, Map<String, dynamic>> templateBodies = <String, Map<String, dynamic>>{
    kTplId: templateBody(),
    kGlobalTplId: templateBody(id: kGlobalTplId, version: 2, name: 'Standart 2+1', siteId: null, safety: false),
  };

  /// Şablon uçlarına verilecek hata (ör. servis oturumunda 403).
  Object? templatesError;

  /// Yazım kayıtları (`POST /template-writes`) ve kayıt hatası.
  final List<Map<String, dynamic>> templateWrites = <Map<String, dynamic>>[];
  Object? templateWriteError;

  void _tplGate() {
    _net();
    final e = templatesError;
    if (e != null) throw e;
  }

  @override
  Future<List<InstallSite>> listInstallSites() async {
    _tplGate();
    calls.add('listInstallSites');
    return sites;
  }

  @override
  Future<List<InstallTemplateSummary>> listInstallTemplates({String? siteId, bool includeGlobal = true}) async {
    _tplGate();
    calls.add('listInstallTemplates:${siteId ?? '-'}:$includeGlobal');
    return <InstallTemplateSummary>[
      for (final e in templateBodies.entries)
        if ((siteId != null && e.value['meta']['site_id'] == siteId) || (includeGlobal && e.value['meta']['site_id'] == null))
          InstallTemplateSummary(
            id: e.key,
            siteId: e.value['meta']['site_id'] as String?,
            name: e.value['meta']['name'] as String,
            flatType: e.value['meta']['flat_type'] as String,
            currentVersion: e.value['meta']['version'] as int,
          ),
    ];
  }

  @override
  Future<InstallTemplate> installTemplate(String templateId) async {
    _tplGate();
    final body = templateBodies[templateId];
    if (body == null) throw const ApiException(statusCode: 404, code: 'NOT_FOUND', message: 'Şablon bulunamadı.');
    return InstallTemplate.fromJson(<String, dynamic>{
      'id': templateId,
      'site_id': body['meta']['site_id'],
      'name': body['meta']['name'],
      'flat_type': body['meta']['flat_type'],
      'current_version': body['meta']['version'],
      'body': body,
    });
  }

  @override
  Future<void> recordTemplateWrite({
    required String deviceUuid,
    required String templateId,
    required int version,
    required String via,
    required bool ok,
    String? errorCode,
    String? flatId,
  }) async {
    _net();
    final e = templateWriteError;
    if (e != null) throw e;
    templateWrites.add(<String, dynamic>{
      'device_uuid': deviceUuid,
      'template_id': templateId,
      'version': version,
      'via': via,
      'result': ok ? 'ok' : 'error',
      'error_code': ?errorCode,
    });
  }

  /// Sunucuda claim edilmiş gibi evi/cihazı kurar (mevcut cihaz testleri).
  void seedClaimed({bool online = false}) {
    endpoints[claimedHomeId] = _claimedEndpoints();
    deviceOnline = online;
    deviceLastSeen = online ? nowProvider().toUtc() : null;
  }

  /// Sunucunun "şimdi"si (sahte saat bağlanır).
  DateTime Function() nowProvider = () => DateTime.utc(2026, 10, 1, 12);

  @override
  Future<String> localKey(String homeId, String deviceUuid) async {
    _net();
    return super.localKey(homeId, deviceUuid);
  }

  @override
  Future<DeviceMqttCredential> reissueDeviceMqttCredential(String homeId, String deviceUuid) async {
    _net();
    homeIdsUsed.add(homeId);
    return super.reissueDeviceMqttCredential(homeId, deviceUuid);
  }

  @override
  Future<List<HomeModel>> fetchHomes() async {
    _net();
    calls.add('fetchHomes');
    final gate = fetchHomesGate;
    if (gate != null) await gate.future;
    final error = fetchHomesErrorOnce;
    if (error != null) {
      fetchHomesErrorOnce = null;
      throw error;
    }
    return List<HomeModel>.of(homes);
  }

  @override
  Future<Map<String, dynamic>> requestClaimOtp({required String deviceUuid, required String targetOwner}) async {
    _net();
    calls.add('requestClaimOtp:$deviceUuid');
    otpRequests++;
    final error = otpError;
    if (error != null) throw error;
    return <String, dynamic>{
      'message': 'Doğrulama kodu m***@o***.test adresine gönderildi.',
      'expires_in': 900,
      'resend_after': 60,
    };
  }

  @override
  Future<ClaimResult> claimDevice({
    required String deviceUuid,
    required String setupPin,
    String? homeName,
    String? targetOwner,
    String? otpCode,
  }) async {
    _net();
    calls.add('claimDevice:$deviceUuid');
    claimCalls++;
    final once = claimErrorOnce;
    if (once != null) {
      claimErrorOnce = null;
      throw once;
    }
    if (claimApplied) {
      throw const ApiException(statusCode: 409, code: 'CONFLICT', message: 'Cihaz zaten sahiplenilmiş.');
    }
    if (setupPin != expectedPin) {
      wrongPinCount++;
      throw ApiException(
        statusCode: 403,
        code: 'FORBIDDEN',
        message: 'Geçersiz kurulum PIN kodu. Kalan deneme hakkı: ${5 - wrongPinCount}',
        remainingAttempts: 5 - wrongPinCount,
      );
    }
    if (otpCode != expectedOtp) {
      wrongOtpCount++;
      throw ApiException(
        statusCode: 400,
        code: 'VALIDATION',
        message: 'Hatalı doğrulama kodu. Kalan deneme hakkı: ${5 - wrongOtpCount}',
        remainingAttempts: 5 - wrongOtpCount,
      );
    }
    endpoints[claimedHomeId] = _claimedEndpoints();
    devicesByHome[claimedHomeId] = <DeviceInfo>[];
    if (claimLosesResponseOnce) {
      // Sunucu claim'i tamamladı (servis personeline 72 saatlik üyelik verildi) ama yanıt telefona ulaşmadı.
      claimLosesResponseOnce = false;
      claimApplied = true;
      homes = <HomeModel>[
        ...homes,
        HomeModel(id: claimedHomeId, name: homeName ?? 'Yeni Daire', role: 'service_user'),
      ];
      throw ApiException.network();
    }
    return ClaimResult(
      homeId: claimedHomeId,
      homeName: homeName ?? 'Yeni Daire',
      deviceUuid: deviceUuid,
      deviceCredential: claimCredential,
      customerAccount: const CustomerAccountInfo(created: true, status: 'pending_invite', inviteSent: true),
      technicianAccessExpiresAt: DateTime.utc(2026, 10, 4, 12),
      warnings: claimWarnings,
    );
  }

  @override
  Future<List<DeviceInfo>> devices(String homeId) async {
    _net();
    calls.add('devices:$homeId');
    homeIdsUsed.add(homeId);
    if (devicesDelay > Duration.zero) await _wait(devicesDelay);
    final error = devicesError;
    if (error != null) throw error;
    final base = devicesByHome[homeId];
    // Testin açıkça verdiği pano listesi her zaman önceliklidir (talep edilen evde bile).
    if (base != null && (base.isNotEmpty || homeId != claimedHomeId)) return List<DeviceInfo>.of(base);
    if (homeId != claimedHomeId) return const <DeviceInfo>[];
    return <DeviceInfo>[
      DeviceInfo(
        deviceUuid: deviceUid,
        name: 'Pano',
        online: deviceOnline,
        lastSeenAt: deviceOnline ? (deviceLastSeen ?? nowProvider()) : null,
        firmware: '1.1.0',
      ),
    ];
  }

  @override
  Future<List<EndpointModel>> fetchEndpoints(String homeId) async {
    _net();
    calls.add('fetchEndpoints:$homeId');
    homeIdsUsed.add(homeId);
    return List<EndpointModel>.of(endpoints[homeId] ?? const <EndpointModel>[]);
  }

  @override
  Future<Map<String, dynamic>> updateEndpoint({
    required String homeId,
    required String endpointId,
    String? name,
    String? room,
    String? type,
    int? shutterDurationSec,
  }) async {
    _net();
    calls.add('updateEndpoint:$endpointId');
    homeIdsUsed.add(homeId);
    final gate = updateEndpointGate;
    if (gate != null) await gate.future;
    if (updateEndpointErrorQueue.isNotEmpty) throw updateEndpointErrorQueue.removeAt(0);
    final error = updateEndpointError;
    if (error != null) throw error;
    if (shutterDurationSec != null && (shutterDurationSec < 1 || shutterDurationSec > 300)) {
      throw ApiException.validation('Panjur süresi 1 ile 300 saniye arasında olmalıdır.');
    }
    endpointUpdates.add(<String, dynamic>{
      'home_id': homeId,
      'endpoint_id': endpointId,
      'sec': shutterDurationSec,
    });
    final pair = RegExp(r'ep-(?:up|down)-(\d+)').firstMatch(endpointId)?.group(1);
    if (pair != null && shutterDurationSec != null) onRuntime?.call(int.parse(pair), shutterDurationSec);
    return <String, dynamic>{'id': endpointId, 'shutter_duration_sec': shutterDurationSec};
  }

  @override
  Future<CommissioningResult> commission({
    required String homeId,
    required String deviceUuid,
    required CommissioningChecks checks,
    String? notes,
  }) async {
    _net();
    calls.add('commission:$deviceUuid');
    homeIdsUsed.add(homeId);
    final error = commissionError;
    if (error != null) throw error;
    commissionChecks.add(checks);
    commissionNotes.add(notes ?? '');
    final passed = checks.allOk && !serverCommissionRejects;
    return CommissioningResult(
      testsPassed: passed,
      status: passed ? 'APPROVED_WORKING' : 'TESTS_FAILED',
      raw: <String, dynamic>{
        'tests_passed': passed,
        'checks': <String, dynamic>{
          'relays': checks.relays.toJson(),
          'buttons': checks.buttons.toJson(),
          'shutters': checks.shutters.toJson(),
          'network': checks.network.toJson(),
          'cloud': <String, dynamic>{'ok': checks.cloud.ok && !serverCommissionRejects, 'detail': checks.cloud.detail},
        },
      },
    );
  }

  @override
  Future<Map<String, dynamic>> fetchDeviceInventory({
    String? status,
    String? search,
    int limit = 100,
    int offset = 0,
  }) async {
    calls.add('fetchDeviceInventory:${search ?? ''}:$offset');
    final gate = inventoryGate;
    if (gate != null) await gate.future;
    final once = inventoryErrorOnce;
    if (once != null) {
      inventoryErrorOnce = null;
      throw once;
    }
    final fail = inventoryError;
    if (fail != null) throw fail;
    var items = inventory.where((d) {
      if (status != null && status.isNotEmpty && d.status.toUpperCase() != status.toUpperCase()) return false;
      if (search != null && search.isNotEmpty) {
        final q = search.toLowerCase();
        return d.deviceUuid.toLowerCase().contains(q) || d.macAddress.toLowerCase().contains(q);
      }
      return true;
    }).toList();
    final total = items.length;
    items = items.skip(offset).take(limit).toList();
    return <String, dynamic>{
      'total': total,
      'items': <Map<String, dynamic>>[
        for (final d in items)
          <String, dynamic>{
            'id': d.id,
            'serial_no': d.serialNo,
            'device_uuid': d.deviceUuid,
            'mac_address': d.macAddress,
            'model': d.model,
            'batch_no': d.batchNo,
            'status': d.status,
            'created_at': d.createdAt.toUtc().toIso8601String(),
            'claimed_home_name': d.claimedHomeName,
          },
      ],
      'stats': <String, dynamic>{
        'total': inventory.length,
        'in_stock': inventory.where((d) => d.isInStock).length,
        'claimed': inventory.where((d) => d.isClaimed).length,
        'suspended': inventory.where((d) => d.isSuspended).length,
        'revoked': inventory.where((d) => d.isRevoked).length,
      },
    };
  }

  // ---------------------------------------------------------------------------
  // Envanter değişiklikleri (durum / silme / etiket yeniden üretimi)
  // ---------------------------------------------------------------------------

  Object? inventoryError;
  Object? inventoryErrorOnce;
  Object? inventoryMutationError;
  Completer<void>? inventoryGate;
  final List<String> inventoryStatusUpdates = <String>[];
  final List<String> inventoryDeleted = <String>[];
  final List<String> reissued = <String>[];
  Object? reissueError;
  Map<String, dynamic>? reissueResponse;

  /// Atanırsa `reissueInventoryLabel` bu kapı açılana kadar bekler (istek sürerken sayfa kapatma denemesi için).
  Completer<void>? reissueGate;

  @override
  Future<Map<String, dynamic>> updateInventoryDeviceStatus(String uuid, String status) async {
    calls.add('updateInventoryDeviceStatus:$uuid:$status');
    final error = inventoryMutationError;
    if (error != null) throw error;
    inventoryStatusUpdates.add('$uuid:$status');
    inventory = <InventoryDeviceModel>[
      for (final d in inventory) d.deviceUuid == uuid ? d.copyWith(status: status) : d,
    ];
    return <String, dynamic>{'device_uuid': uuid, 'status': status};
  }

  @override
  Future<bool> deleteInventoryDevice(String uuid) async {
    calls.add('deleteInventoryDevice:$uuid');
    final error = inventoryMutationError;
    if (error != null) throw error;
    inventoryDeleted.add(uuid);
    inventory = inventory.where((d) => d.deviceUuid != uuid).toList();
    return true;
  }

  @override
  Future<Map<String, dynamic>> reissueInventoryLabel(String uuid) async {
    calls.add('reissueInventoryLabel:$uuid');
    final gate = reissueGate;
    if (gate != null) await gate.future;
    final error = reissueError;
    if (error != null) throw error;
    reissued.add(uuid);
    return reissueResponse ??
        <String, dynamic>{
          'setup_pin': kReissuedPin,
          'local_key': kReissuedKey,
          'qr_claim_url': 'https://evotomasyon.gudeteknoloji.com.tr/claim?uid=$uuid&pin=$kReissuedPin',
        };
  }

  // ---------------------------------------------------------------------------
  // Aboneler / Home Admin ataması
  // ---------------------------------------------------------------------------

  List<Map<String, dynamic>> subscribers = <Map<String, dynamic>>[];
  Object? subscribersError;
  Object? subscribersErrorOnce;
  Completer<void>? subscribersGate;
  final List<String> subscriberQueries = <String>[];
  int adminOtpRequests = 0;
  Object? adminOtpError;
  Object? assignError;
  Completer<void>? assignGate;
  String expectedAdminOtp = kOwnerConsentOtp;
  final List<Map<String, dynamic>> assignments = <Map<String, dynamic>>[];

  @override
  Future<({List<Map<String, dynamic>> items, int? total})> fetchServiceSubscribersPage({
    int limit = 50,
    int offset = 0,
    String? search,
  }) async {
    calls.add('fetchServiceSubscribersPage:$offset:${search ?? ''}');
    subscriberQueries.add('$offset|${search ?? ''}');
    final gate = subscribersGate;
    if (gate != null) await gate.future;
    final once = subscribersErrorOnce;
    if (once != null) {
      subscribersErrorOnce = null;
      throw once;
    }
    final fail = subscribersError;
    if (fail != null) throw fail;
    final q = (search ?? '').trim().toLowerCase();
    final filtered = subscribers.where((s) => q.isEmpty || jsonEncode(s).toLowerCase().contains(q)).toList();
    return (items: filtered.skip(offset).take(limit).toList(), total: filtered.length);
  }

  /// Mevcut sahibe ulaşılamıyor (sunucu `OWNER_UNREACHABLE`).
  bool ownerUnreachable = false;
  final List<Map<String, dynamic>> otpTargets = <Map<String, dynamic>>[];

  @override
  Future<({bool otpRequired, CodeChallenge challenge, String? ownerHint})> requestAssignAdminOtp(
    String homeId, {
    required String fullName,
    String? email,
    String? phone,
  }) async {
    calls.add('requestAssignAdminOtp:$homeId');
    adminOtpRequests++;
    otpTargets.add(<String, dynamic>{'full_name': fullName, 'email': email, 'phone': phone});
    final error = adminOtpError;
    if (error != null) throw error;
    final target = subscribers.where((s) => '${s['home_id']}' == homeId).firstOrNull;
    final hasOwner = target != null && target['owner'] != null;
    if (!hasOwner) {
      return (
        otpRequired: false,
        challenge: const CodeChallenge(message: 'Bu dairede mevcut ev sahibi yok; onay kodu gerekmez.'),
        ownerHint: null,
      );
    }
    if (ownerUnreachable) {
      throw const ApiException(
        statusCode: 409,
        code: 'OWNER_UNREACHABLE',
        message: 'Mevcut ev sahibine e-posta ile ulaşılamıyor.',
      );
    }
    return (
      otpRequired: true,
      challenge: const CodeChallenge(
        message: 'Onay kodu ev sahibine (e***@o***.test) gönderildi.',
        expiresIn: Duration(minutes: 15),
        resendAfter: Duration(seconds: 60),
      ),
      ownerHint: 'e***@o***.test',
    );
  }

  @override
  Future<Map<String, dynamic>> assignHomeAdmin({
    required String homeId,
    required String fullName,
    String? email,
    String? phone,
    String? otpCode,
    bool force = false,
    String? reason,
  }) async {
    calls.add('assignHomeAdmin:$homeId');
    final gate = assignGate;
    if (gate != null) await gate.future;
    final error = assignError;
    if (error != null) throw error;
    final target = subscribers.where((s) => '${s['home_id']}' == homeId).firstOrNull;
    final hasOwner = target != null && target['owner'] != null;
    if (force) {
      if (!actorIsSuper) {
        throw const ApiException(
          statusCode: 403,
          code: 'FORBIDDEN',
          message: 'Zorla atama yalnızca süper yönetici tarafından yapılabilir.',
        );
      }
      if ((reason ?? '').trim().length < 15) {
        throw const ApiException(statusCode: 400, code: 'VALIDATION', message: 'Zorla atama için gerekçe en az 15 karakter olmalı.');
      }
    } else if (hasOwner && otpCode != expectedAdminOtp) {
      throw const ApiException(
        statusCode: 400,
        code: 'VALIDATION',
        message: 'Hatalı onay kodu. Kalan deneme hakkı: 4',
        remainingAttempts: 4,
      );
    }
    assignments.add(<String, dynamic>{
      'home_id': homeId,
      'full_name': fullName,
      'email': email,
      'phone': phone,
      'with_otp': otpCode != null && otpCode.isNotEmpty,
      'force': force,
      'reason': reason,
    });
    if (target != null) {
      target['owner'] = <String, dynamic>{'full_name': fullName, 'email': email, 'phone': phone};
    }
    return <String, dynamic>{
      'message': '$fullName Home Admin olarak atandı.',
      'account_created': true,
      'invite_sent': !assignWarnings,
      if (assignWarnings) 'warnings': const <String>['Hesap etkinleştirme e-postası gönderilemedi.'],
      if (assignWarnings) 'partial': true,
    };
  }

  /// Atama kısmi başarıyla biter (uyarılı yanıt).
  bool assignWarnings = false;

  // ---------------------------------------------------------------------------
  // Yönetici hesapları (admin panel)
  // ---------------------------------------------------------------------------

  /// Sunucudaki hesap satırları (`GET /admin/users` yanıtı biçiminde).
  List<Map<String, dynamic>> adminUsers = <Map<String, dynamic>>[];
  Object? adminListError;
  Object? adminListErrorOnce;
  Completer<void>? adminListGate;
  Object? summaryError;
  Map<String, dynamic>? serviceSummary;
  Object? adminWriteError;
  Completer<void>? adminWriteGate;
  final List<String> adminQueries = <String>[];
  final List<Map<String, dynamic>> adminCreates = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> adminUpdates = <Map<String, dynamic>>[];
  final List<String> adminResets = <String>[];
  Object? adminResetError;

  /// İşlemi yapan hesabın sunucudaki kimliği ve süper yönetici olup olmadığı.
  String actorId = 'super-1';
  bool actorIsSuper = true;
  bool inviteMailFails = false;
  int _adminSeq = 0;

  Map<String, dynamic>? _adminById(String id) => adminUsers.where((u) => '${u['id']}' == id).firstOrNull;

  int _activeSupers({String? except}) => adminUsers
      .where((u) =>
          u['role'] == 'super_user' && u['is_active'] != false && u['account_status'] != 'suspended' && '${u['id']}' != except)
      .length;

  @override
  Future<Map<String, dynamic>> listAdminUsers({
    String? role,
    String? search,
    bool? isActive,
    int limit = 50,
    int offset = 0,
  }) async {
    calls.add('listAdminUsers:${role ?? 'all'}:$offset:${search ?? ''}');
    adminQueries.add('${role ?? ''}|$offset|${search ?? ''}');
    final gate = adminListGate;
    if (gate != null) await gate.future;
    final once = adminListErrorOnce;
    if (once != null) {
      adminListErrorOnce = null;
      throw once;
    }
    final fail = adminListError;
    if (fail != null) throw fail;
    final q = (search ?? '').trim().toLowerCase();
    final filtered = adminUsers.where((u) {
      if (role != null && role.isNotEmpty && u['role'] != role) return false;
      if (q.isEmpty) return true;
      return '${u['full_name']} ${u['email']} ${u['phone'] ?? ''}'.toLowerCase().contains(q);
    }).toList();
    return <String, dynamic>{
      'total': filtered.length,
      'limit': limit,
      'offset': offset,
      'users': filtered.skip(offset).take(limit).map((u) => Map<String, dynamic>.of(u)).toList(),
    };
  }

  @override
  Future<Map<String, dynamic>> getServiceSummary() async {
    calls.add('getServiceSummary');
    final error = summaryError;
    if (error != null) throw error;
    return serviceSummary ??
        <String, dynamic>{
          'users': <String, dynamic>{'super_users': 2, 'service_users': 3, 'regular_users': 40, 'total_users': 45},
          'homes': <String, dynamic>{'total_homes': 38},
          'devices': <String, dynamic>{'total_devices': 55},
        };
  }

  @override
  Future<Map<String, dynamic>> createAdminUser({
    required String fullName,
    required String email,
    String? password,
    String? phone,
    required String role,
    String? adminNotes,
  }) async {
    calls.add('createAdminUser:$role');
    final gate = adminWriteGate;
    if (gate != null) await gate.future;
    final error = adminWriteError;
    if (error != null) throw error;
    final withPassword = password != null && password.isNotEmpty;
    if (!actorIsSuper) {
      if (role != 'user') {
        throw const ApiException(
          statusCode: 403,
          code: 'FORBIDDEN',
          message: 'Servis sorumluları yalnızca müşteri hesabı tanımlayabilir.',
        );
      }
      if (withPassword) {
        throw const ApiException(
          statusCode: 403,
          code: 'FORBIDDEN',
          message: 'Servis sorumluları kullanıcı parolası belirleyemez.',
        );
      }
    }
    if (adminUsers.any((u) => '${u['email']}'.toLowerCase() == email.toLowerCase())) {
      throw const ApiException(statusCode: 409, code: 'CONFLICT', message: 'Bu e-posta adresi sistemde zaten kayıtlı.');
    }
    adminCreates.add(<String, dynamic>{
      'full_name': fullName,
      'email': email,
      'role': role,
      'phone': phone,
      'notes': adminNotes,
      'password_length': password?.length ?? 0,
      'password_had_edge_space': withPassword && password != password.trim(),
    });
    final id = 'u-${++_adminSeq}';
    final row = <String, dynamic>{
      'id': id,
      'full_name': fullName,
      'email': email,
      'phone': phone,
      'role': role,
      'is_active': true,
      'account_status': withPassword ? 'active' : 'pending_invite',
      'admin_notes': adminNotes,
    };
    adminUsers = <Map<String, dynamic>>[row, ...adminUsers];
    return <String, dynamic>{
      ...row,
      if (!withPassword) 'invite_sent': !inviteMailFails,
      if (!withPassword && inviteMailFails) 'invite_warning': 'Etkinleştirme e-postası gönderilemedi.',
    };
  }

  @override
  Future<Map<String, dynamic>> updateAdminUser(
    String userId, {
    String? fullName,
    String? phone,
    String? role,
    String? password,
    String? currentPassword,
    bool? isActive,
    String? adminNotes,
  }) async {
    calls.add('updateAdminUser:$userId');
    final gate = adminWriteGate;
    if (gate != null) await gate.future;
    final error = adminWriteError;
    if (error != null) throw error;
    final target = _adminById(userId);
    if (target == null) throw const ApiException(statusCode: 404, code: 'NOT_FOUND', message: 'Kullanıcı bulunamadı.');
    final wantsPassword = password != null && password.isNotEmpty;
    if (wantsPassword && !actorIsSuper) {
      throw const ApiException(statusCode: 403, code: 'FORBIDDEN', message: 'Servis sorumluları parola değiştiremez.');
    }
    if (userId == actorId && isActive == false) {
      throw const ApiException(statusCode: 400, code: 'VALIDATION', message: 'Kendi hesabınızı donduramazsınız.');
    }
    if (wantsPassword && target['role'] == 'super_user' && userId != actorId) {
      if (currentPassword == null || currentPassword.isEmpty) {
        throw const ApiException(
          statusCode: 403,
          code: 'REAUTH_REQUIRED',
          message: 'Başka bir süper yöneticinin parolasını değiştirmek için kendi mevcut parolanızı girin.',
        );
      }
      if (currentPassword != kActorPassword) {
        throw const ApiException(statusCode: 403, code: 'REAUTH_REQUIRED', message: 'Mevcut parolanız doğrulanamadı.');
      }
    }
    if (isActive == false && target['role'] == 'super_user' && _activeSupers(except: userId) == 0) {
      throw const ApiException(
        statusCode: 409,
        code: 'CONFLICT',
        message: 'Son aktif Süper Yönetici dondurulamaz veya rolü düşürülemez.',
      );
    }
    adminUpdates.add(<String, dynamic>{
      'id': userId,
      'full_name': fullName,
      'phone': phone,
      'notes': adminNotes,
      'is_active': isActive,
      'password_length': password?.length ?? 0,
      'password_had_edge_space': wantsPassword && password != password.trim(),
      'sent_current_password': currentPassword != null && currentPassword.isNotEmpty,
    });
    if (fullName != null) target['full_name'] = fullName;
    if (phone != null) target['phone'] = phone.isEmpty ? null : phone;
    if (adminNotes != null) target['admin_notes'] = adminNotes;
    if (isActive != null) {
      target['is_active'] = isActive;
      target['account_status'] = isActive ? 'active' : 'suspended';
    }
    return Map<String, dynamic>.of(target);
  }

  @override
  Future<Map<String, dynamic>> sendAdminUserReset(String userId) async {
    calls.add('sendAdminUserReset:$userId');
    final error = adminResetError;
    if (error != null) throw error;
    final target = _adminById(userId);
    if (target == null) throw const ApiException(statusCode: 404, code: 'NOT_FOUND', message: 'Kullanıcı bulunamadı.');
    adminResets.add(userId);
    return <String, dynamic>{
      'sent': true,
      'purpose': target['account_status'] == 'pending_invite' ? 'account_setup' : 'reset',
    };
  }

  // ---------------------------------------------------------------------------
  // Sistem doktoru / pano değişimi / acil sıfırlama kayıtları
  // ---------------------------------------------------------------------------

  Map<String, dynamic>? diagnostic;
  Object? diagnosticError;
  Completer<void>? diagnosticGate;
  int diagnosticCalls = 0;

  @override
  Future<Map<String, dynamic>> fetchSystemDiagnostic(String homeId) async {
    calls.add('fetchSystemDiagnostic:$homeId');
    diagnosticCalls++;
    final gate = diagnosticGate;
    if (gate != null) await gate.future;
    final error = diagnosticError;
    if (error != null) throw error;
    return Map<String, dynamic>.of(diagnostic ?? const <String, dynamic>{});
  }

  /// `replaceBoard` istekleri (PIN değeri değil, yalnızca uzunluğu yazılır).
  final List<Map<String, dynamic>> replaceRequests = <Map<String, dynamic>>[];
  Object? replaceError;

  @override
  Future<ReplaceBoardResult> replaceBoard({
    required String homeId,
    String? oldDeviceUuid,
    required String newDeviceUuid,
    required String setupPin,
    String? reason,
  }) async {
    calls.add('replaceBoard:$newDeviceUuid');
    final error = replaceError;
    if (error != null) throw error;
    replaceRequests.add(<String, dynamic>{
      'home_id': homeId,
      'old': oldDeviceUuid,
      'new': newDeviceUuid,
      'pin_length': setupPin.length,
      'reason': reason,
    });
    return replaceBoardToReturn ??
        ReplaceBoardResult(
          newDeviceUuid: newDeviceUuid,
          oldDeviceUuid: oldDeviceUuid,
          homeId: homeId,
          migratedEndpointsCount: 6,
        );
  }

  final List<Map<String, dynamic>> emergencyResets = <Map<String, dynamic>>[];
  Object? emergencyError;
  Completer<void>? emergencyGate;

  @override
  Future<EmergencyResetResult> emergencyResetDevice({
    required String deviceUuid,
    required String confirmUid,
    required String reason,
    String? newOwnerIdentifier,
  }) async {
    calls.add('emergencyResetDevice:$deviceUuid');
    final gate = emergencyGate;
    if (gate != null) await gate.future;
    final error = emergencyError;
    if (error != null) throw error;
    emergencyResets.add(<String, dynamic>{
      'device': deviceUuid,
      'confirm': confirmUid,
      'reason': reason,
      'new_owner': newOwnerIdentifier,
    });
    return emergencyResetToReturn ??
        EmergencyResetResult(
          action: 'UNCLAIMED',
          deviceUuid: deviceUuid,
          setupPin: kReissuedPin,
          affectedUsersCount: 3,
        );
  }
}

InventoryDeviceModel inventoryDevice({
  String uid = kDeviceUid,
  String status = 'IN_STOCK',
  int serial = 1,
  String? claimedHome,
}) =>
    InventoryDeviceModel(
      id: 'inv-$serial',
      serialNo: serial,
      deviceUuid: uid,
      macAddress: 'E8:F6:0A:11:22:3$serial',
      model: 'ESP32-S3-POE-ETH-8DI-8RO',
      batchNo: 'BATCH-2026-01',
      status: status,
      claimedHomeName: claimedHome,
      createdAt: DateTime.utc(2026, 9, 24, 10),
      qrClaimUrl: 'https://evotomasyon.gudeteknoloji.com.tr/claim?uid=$uid',
    );

// =============================================================================
// Birleşik test donanımı
// =============================================================================

class ServiceHarness {
  ServiceHarness._({
    required this.h,
    required this.cloud,
    required this.device,
    required this.clock,
    required this.store,
    required this.access,
  });

  final StateHarness h;
  final ServiceFakeCloud cloud;
  final FakeDevice device;
  final FakeClock clock;
  final SetupStore store;
  final ServiceSetupAccess access;

  AutomationState get state => h.state;

  /// Telefon panonun KURULUM AĞINA (AP) bağlandı: internet YOK, yalnızca AP adresi erişilebilir.
  void phoneOnSetupNetwork() {
    cloud.internetUp = false;
    device.apReachable = true;
    device.lanReachable = false;
  }

  /// Telefon müşterinin EV Wi-Fi ağına döndü: internet VAR, pano yalnızca ev ağı adresinden erişilebilir
  /// (kurulum ağı kapandı).
  void phoneOnHomeNetwork() {
    cloud.internetUp = true;
    device.apReachable = false;
    device.lanReachable = true;
  }

  /// Güvenli depodaki tüm ham anahtar/değer çiftleri (gizli değer sızıntısı denetimi için tek metin).
  String dumpSecureStore() {
    final buffer = StringBuffer();
    for (final entry in h.storage.memory.data.entries) {
      buffer.writeln('${entry.key}=${entry.value}');
    }
    return buffer.toString();
  }

  /// Pano istemcisi üreticisi: tüm adresler aynı sahte panoya gider (adres erişilebilirliğini pano belirler).
  AutomationApiService Function(String host) get deviceFactory =>
      (host) => AutomationApiService(baseUrl: '', client: device.api.client, clock: clock)..updateHost(host);

  ServiceSetupController newController({
    SetupProgressRecord? resume,
    ServiceTarget? existingTarget,
    int? startStep,
    AutomationApiService Function(String host)? factory,
  }) =>
      ServiceSetupController(
        state: state,
        access: access,
        store: store,
        deviceApiFactory: factory ?? deviceFactory,
        resume: resume,
        existingTarget: existingTarget,
        startStep: startStep,
      );

  void dispose() {
    device.dispose();
    h.dispose();
  }
}

/// Servis personeli (`service_user`), geçici servis oturumu (`pin`) ya da süper kullanıcı için donanım.
///
/// [role]: `staff` | `pin` | `super`.
///
/// [flush]: olay kuyruğunu boşaltan işlev (varsayılan `pumpEventQueue`). Widget testlerinde (FakeAsync)
/// `pumpEventQueue` takılır: orada `flush: () async {}` verilir ve tüm bekleyenler `tester.pump` ile işlenir.
/// **Önemli:** `AutomationState` gerçek (runAsync) bölgede kurulursa depolama kuyruğu gerçek bölgeye
/// bağlanır ve widget testlerinde asla tamamlanmaz; bu yüzden widget testlerinde `runAsync` KULLANILMAZ.
Future<ServiceHarness> serviceHarness({
  String role = 'staff',
  bool provisioned = true,
  bool inventoryListed = false,
  Future<void> Function()? flush,
}) async {
  final doFlush = flush ?? pumpEventQueue;
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final clock = FakeClock();
  final cloud = ServiceFakeCloud(clock: clock);
  final h = StateHarness(clock: clock, cloud: cloud);
  final device = FakeDevice(clock: clock, provisioned: provisioned);
  cloud.nowProvider = clock.now;
  cloud.localKeyValue = kLocalKey;
  cloud.onRuntime = device.applyRuntime;
  device.onMqttConfigured = (server, port, user, pass) {
    cloud.deviceOnline = true;
    cloud.deviceLastSeen = clock.now().toUtc();
    device.mqttConnected = true;
  };
  if (inventoryListed) cloud.inventory = <InventoryDeviceModel>[inventoryDevice()];

  switch (role) {
    case 'pin':
      cloud.claimedHomeId = kClaimedHome;
      cloud.seedClaimed();
      cloud.devicesByHome[kClaimedHome] = <DeviceInfo>[];
      cloud.homes = <HomeModel>[HomeModel(id: kClaimedHome, name: 'Servis Evi', role: 'service_session')];
      cloud.serviceSessionToReturn = ServiceSessionInfo(
        homeId: kClaimedHome,
        homeName: 'Servis Evi',
        expiresAt: clock.now().add(const Duration(hours: 2)),
        technicianName: 'Usta',
      );
      await h.state.loginWithServicePin('123456', technicianName: 'Usta');
    case 'super':
      h.state
        ..setCurrentUserForTesting(const UserModel(
          id: 'super-1',
          email: 'yonetici@ornek.test',
          fullName: 'Yönetici',
          role: 'super_user',
        ))
        ..setAuthStatusForTesting(AuthStatus.authenticated);
    default:
      h.state
        ..setCurrentUserForTesting(const UserModel(
          id: 'staff-1',
          email: 'servis@ornek.test',
          fullName: 'Servis Ali',
          phone: '05551112233',
          role: 'service_user',
        ))
        ..setAuthStatusForTesting(AuthStatus.authenticated);
  }
  await doFlush();
  final access = ServiceSetupAccess.fromState(h.state)!;
  return ServiceHarness._(
    h: h,
    cloud: cloud,
    device: device,
    clock: clock,
    store: SetupStore(),
    access: access,
  );
}

/// Saati ilerleterek (FakeClock) ve olay kuyruğunu boşaltarak [condition] gerçekleşene kadar bekler.
Future<void> waitUntil(
  ServiceHarness env,
  bool Function() condition, {
  Duration step = const Duration(milliseconds: 250),
  int maxSteps = 600,
}) async {
  for (var i = 0; i < maxSteps; i++) {
    await pumpEventQueue();
    if (condition()) return;
    await env.clock.elapse(step);
  }
  await pumpEventQueue();
}

/// Bir mantık eyleminin (Future) bitmesini, arada saati ilerleterek bekler (zamanlayıcılara bağlı eylemler için).
Future<T> drive<T>(ServiceHarness env, Future<T> action, {Duration step = const Duration(milliseconds: 250), int maxSteps = 2000}) async {
  var done = false;
  late T value;
  Object? error;
  StackTrace? trace;
  unawaited(action.then((v) {
    value = v;
    done = true;
  }, onError: (Object e, StackTrace s) {
    error = e;
    trace = s;
    done = true;
  }));
  for (var i = 0; i < maxSteps && !done; i++) {
    await pumpEventQueue();
    if (done) break;
    await env.clock.elapse(step);
  }
  await pumpEventQueue();
  if (!done) throw StateError('Eylem zaman aşımına uğradı (sahte saat ${step * maxSteps} ilerletildi).');
  if (error != null) Error.throwWithStackTrace(error!, trace!);
  return value;
}

/// Kayıtlı tüm yerel depo değerlerini (gizli değer sızıntısı denetimi için) tek metne çevirir.
Future<String> dumpPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  final buffer = StringBuffer();
  for (final key in prefs.getKeys()) {
    buffer.writeln('$key=${jsonEncode(prefs.get(key))}');
  }
  return buffer.toString();
}
