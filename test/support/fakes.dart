import 'dart:async';
import 'dart:convert';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/models/scheduled_rule_model.dart';
import 'package:ev_otomasyon/services/automation_api_service.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/services/biometric_auth_service.dart';
import 'package:ev_otomasyon/services/clock.dart';
import 'package:ev_otomasyon/services/ev_cloud_api_service.dart';
import 'package:ev_otomasyon/services/ev_mqtt_service.dart';
import 'package:ev_otomasyon/services/secure_storage_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'http_mocks.dart';

// =============================================================================
// Sahte saat
// =============================================================================

/// [FakeClock]'un varsayılan başlangıç zamanı. Misafir pencereleri gibi zamana bağlı test
/// verileri `DateTime.now()` değil bu değere (veya `harness.clock.now()`'a) göre kurulmalıdır.
final DateTime kTestNow = DateTime.utc(2026, 10, 1, 12);

/// Elle ilerletilen saat: zamanlayıcılar gerçek beklemeden deterministik tetiklenir.
///
/// `advance` zamanlayıcı geri çağrılarını **eşzamanlı** çalıştırır; ardından bekleyen
/// `Future` devamlarının işlenmesi için `await pumpEventQueue()` (flutter_test) ya da
/// [elapse] kullanın.
class FakeClock extends Clock {
  FakeClock([DateTime? start]) : _now = start ?? kTestNow;

  DateTime _now;
  final List<_FakeTimer> _timers = <_FakeTimer>[];

  @override
  DateTime now() => _now;

  /// Şu an etkin zamanlayıcı sayısı.
  int get activeTimerCount => _timers.where((t) => t.isActive).length;

  @override
  Timer timer(Duration duration, void Function() callback) {
    final timer = _FakeTimer(_now.add(duration), null, (_) => callback());
    _timers.add(timer);
    return timer;
  }

  @override
  Timer periodic(Duration period, void Function(Timer timer) callback) {
    final timer = _FakeTimer(_now.add(period), period, callback);
    _timers.add(timer);
    return timer;
  }

  /// Saati [duration] kadar ilerletir; süresi dolan zamanlayıcıları sırayla tetikler.
  void advance(Duration duration) {
    final target = _now.add(duration);
    while (true) {
      _FakeTimer? next;
      for (final timer in _timers) {
        if (!timer.isActive || timer.due.isAfter(target)) continue;
        if (next == null || timer.due.isBefore(next.due)) next = timer;
      }
      if (next == null) break;
      _now = next.due;
      next.fire();
    }
    _now = target;
    _timers.removeWhere((t) => !t.isActive);
  }

  /// Saati [duration] kadar ilerletir; **bir sonraki zamanlayıcıdan diğerine atlar** ve her
  /// zamanlayıcıdan sonra olay kuyruğunu boşaltır (async devamlar, o zamanlayıcının tetiklediği
  /// yeni zamanlayıcıları kurabilsin diye). [advance]'ın async eşdeğeridir; uzun süreler hızlıdır.
  Future<void> elapse(Duration duration, {Duration step = Duration.zero}) async {
    final target = _now.add(duration);
    await _flush();
    var guard = 0;
    while (guard++ < 100000) {
      _FakeTimer? next;
      for (final timer in _timers) {
        if (!timer.isActive || timer.due.isAfter(target)) continue;
        if (next == null || timer.due.isBefore(next.due)) next = timer;
      }
      if (next == null) break;
      if (next.due.isAfter(_now)) _now = next.due;
      next.fire();
      await _flush();
    }
    _now = target;
    _timers.removeWhere((t) => !t.isActive);
    await _flush();
  }

  Future<void> _flush() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}

class _FakeTimer implements Timer {
  _FakeTimer(this.due, this.period, this.callback);

  DateTime due;
  final Duration? period;
  final void Function(Timer timer) callback;
  bool _active = true;
  int _ticks = 0;

  @override
  bool get isActive => _active;

  @override
  int get tick => _ticks;

  void fire() {
    _ticks++;
    final p = period;
    if (p == null) {
      _active = false;
    } else {
      due = due.add(p);
    }
    callback(this);
  }

  @override
  void cancel() => _active = false;
}

// =============================================================================
// Güvenli depolama
// =============================================================================

/// Bellek içi güvenli depo (+ hata ve takılma enjekte etme).
class InMemorySecureStore implements SecureKeyValueStore {
  final Map<String, String> data = <String, String>{};

  /// `true` ise ilgili işlem `Exception` fırlatır (platform hatasını simüle eder).
  bool failReads = false;
  bool failWrites = false;
  bool failDeleteAll = false;

  /// Yalnızca bu anahtarların okunması hata verir (ör. yalnızca biyometrik tercih okunamasın).
  final Set<String> failReadKeys = <String>{};

  // --- Takılan platform çağrısı (süre sınırı testleri, PF-02) ---------------------------------
  //
  // Atanan `Completer` tamamlanana kadar işlem DÖNMEZ (Keystore/Keychain takılması). Tamamlanınca
  // işlem normal sürer; `completeError` ile tamamlanırsa GEÇ DÖNEN HATA simüle edilir (süre sınırını
  // aşmış bir çağrıda yutulmalı, ele alınmamış hata üretmemelidir). Zaman aşımına uğrayan çağrı iptal
  // edilemez: kapı sonradan açılırsa yazma yine uygulanır (platform işi sürer).

  /// `read` kapısı: değer kapı açıldıktan SONRA okunur (platform işe hiç başlayamadı).
  Completer<void>? hangReads;

  /// `write` VE `delete` kapısı (`failWrites` gibi ikisini de kapsar).
  Completer<void>? hangWrites;

  /// `deleteAll` kapısı (çıkıştaki toplu silme).
  Completer<void>? hangDeleteAll;

  /// Yanıt kapısı: değer kapıdan ÖNCE yakalanır (platform okumayı bitirip yanıtı geciktirir); kapı
  /// açılınca eski (yakalanan) değer döner.
  Completer<void>? readGate;

  /// Başlatılan `read` çağrıları (takılanlar ve hata verenler dahil).
  int startedReads = 0;

  /// Başlatılan `write` çağrıları (`delete` DEĞİL; hata/takılma dahil, girişte sayılır).
  int writeCount = 0;

  /// Başlatılan `deleteAll` çağrıları (hata/takılma dahil, girişte sayılır).
  int deleteAllCount = 0;

  final Map<String, int> _writesByKey = <String, int>{};

  /// Belirli bir anahtara yapılan `write` sayısı (ör. `ahbu_homes_cache`: gereksiz yeniden yazma denetimi).
  int writeCountFor(String key) => _writesByKey[key] ?? 0;

  @override
  Future<String?> read(String key) async {
    startedReads++;
    if (failReads || failReadKeys.contains(key)) throw Exception('okuma hatası');
    final hang = hangReads;
    if (hang != null) await hang.future;
    final value = data[key];
    final gate = readGate;
    if (gate != null) await gate.future;
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    writeCount++;
    _writesByKey[key] = writeCountFor(key) + 1;
    if (failWrites) throw Exception('yazma hatası');
    final hang = hangWrites;
    if (hang != null) await hang.future;
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failWrites) throw Exception('silme hatası');
    final hang = hangWrites;
    if (hang != null) await hang.future;
    data.remove(key);
  }

  @override
  Future<void> deleteAll() async {
    deleteAllCount++;
    if (failDeleteAll) throw Exception('toplu silme hatası');
    final hang = hangDeleteAll;
    if (hang != null) await hang.future;
    data.clear();
  }
}

/// Sonradan (StateHarness tarafından) bir saate bağlanabilen saat. Açıkça saat verilmediyse bağlanana
/// kadar ATIL bir [FakeClock]'a gider (zamanlayıcılar asla tetiklenmez, gerçek zaman kullanılmaz);
/// açıkça verildiyse hiç değişmez.
class _BindableClock extends Clock {
  _BindableClock(Clock? explicit)
      : _target = explicit ?? FakeClock(),
        _pinned = explicit != null;

  Clock _target;
  final bool _pinned;

  void bindIfUnset(Clock clock) {
    if (!_pinned) _target = clock;
  }

  @override
  DateTime now() => _target.now();

  @override
  Timer timer(Duration duration, void Function() callback) => _target.timer(duration, callback);

  @override
  Timer periodic(Duration period, void Function(Timer timer) callback) =>
      _target.periodic(period, callback);
}

/// `SecureStorageService` + bellek içi depo.
///
/// Süre sınırı zamanlayıcıları ([clock]) varsayılan olarak ATIL'dır: `StateHarness` kurulunca onun
/// `FakeClock`'una bağlanır (`h.clock.elapse(...)` takılan depo çağrısını zaman aşımına uğratır).
/// Harness'sız kullanımda zaman aşımı için [clock] verin; açıkça verilen saat hiç değiştirilmez.
class FakeStorage extends SecureStorageService {
  FakeStorage._(this.memory, this._clockRef, Duration? opTimeout)
      : super(store: memory, clock: _clockRef, opTimeout: opTimeout);

  /// [memory]: paylaşılan/önceden doldurulmuş bellek içi depo (verilmezse boş). [opTimeout]: üretim
  /// varsayılanını (6 sn) değiştirir.
  factory FakeStorage({InMemorySecureStore? memory, Clock? clock, Duration? opTimeout}) =>
      FakeStorage._(memory ?? InMemorySecureStore(), _BindableClock(clock), opTimeout);

  final InMemorySecureStore memory;
  final _BindableClock _clockRef;

  /// `StateHarness` bunu çağırır: açıkça saat verilmediyse süre sınırı zamanlayıcıları [clock]'tan kurulur.
  void bindClockIfUnset(Clock clock) => _clockRef.bindIfUnset(clock);

  /// Depodaki ham anahtarlar (sızıntı denetimi için).
  Iterable<String> get keys => memory.data.keys;

  bool get isEmpty => memory.data.isEmpty;
}

// =============================================================================
// Biyometrik
// =============================================================================

class FakeBiometric extends BiometricAuthService {
  /// [clock]/[probeTimeout]: yalnızca [hangSupported] için (üretim servisindeki sonda süre sınırı).
  /// Saat verilmezse `StateHarness` kurulunca onun `FakeClock`'una bağlanır (bkz. [bindClockIfUnset]).
  FakeBiometric({
    bool supported = false,
    bool authResult = true,
    String label = 'Parmak İzi',
    Clock? clock,
    Duration? probeTimeout,
  }) : this._(supported, authResult, label, _BindableClock(clock), probeTimeout);

  FakeBiometric._(this.supported, this.authResult, this.label, this._clockRef, Duration? probeTimeout)
      : _probeLimit = probeTimeout ?? BiometricAuthService.defaultProbeTimeout,
        super(clock: _clockRef, probeTimeout: probeTimeout);

  final _BindableClock _clockRef;
  final Duration _probeLimit;

  bool supported;
  bool authResult;
  String label;
  int authenticateCalls = 0;
  final List<String> reasons = <String>[];

  /// `isBiometricSupported` çağrı sayısı (gereksiz sondaları yakalamak için).
  int supportedCalls = 0;

  /// `getBiometricLabel` çağrı sayısı.
  int labelCalls = 0;

  /// Atanırsa `authenticate` bu `Completer` tamamlanana kadar bekler (gecikmeli doğrulama).
  Completer<bool>? pending;

  /// Doğrulama başarısız olduğunda bildirilecek neden (verilmezse "vazgeçildi").
  BiometricFailure? failure;
  BiometricFailure? _lastFailure;

  @override
  BiometricFailure? get lastFailure => _lastFailure;

  /// Atanırsa `isBiometricSupported` (platform sondası) bu `Completer` tamamlanana kadar DÖNMEZ ve
  /// tamamlanınca onun değerini döner. Üretim servisi gibi sonda süre sınırına tabidir: sınır içinde
  /// dönmezse `false` döner, geç dönen değer/hata yutulur (süre `FakeClock` ile ilerler).
  Completer<bool>? hangSupported;

  /// `StateHarness` bunu çağırır: açıkça saat verilmediyse sonda süre sınırı [clock]'tan kurulur.
  void bindClockIfUnset(Clock clock) => _clockRef.bindIfUnset(clock);

  bool _timedOut = false;

  /// Üretim servisindeki gibi: son destek sondası ([hangSupported]) süre sınırına takıldıysa `true`.
  @override
  bool get lastSupportProbeTimedOut => _timedOut;

  @override
  Future<bool> isBiometricSupported() async {
    supportedCalls++;
    _timedOut = false;
    final hang = hangSupported;
    if (hang == null) return supported;
    try {
      return await _clockRef.bound<bool>(hang.future, _probeLimit, () {
        _timedOut = true;
        return false;
      });
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String> getBiometricLabel() async {
    labelCalls++;
    return label;
  }

  @override
  Future<bool> authenticate({
    String reason = 'AHBU Ev Otomasyonu için kimliğinizi doğrulayın',
    bool biometricOnly = false,
  }) async {
    authenticateCalls++;
    reasons.add(reason);
    final wait = pending;
    final ok = wait != null ? await wait.future : supported && authResult;
    _lastFailure = ok ? null : (failure ?? BiometricFailure.canceled);
    return ok;
  }
}

// =============================================================================
// Bulut API
// =============================================================================

/// Gerçek `EvCloudApiService`'ten türeyen sahte: `AutomationState`'in kullandığı uçlar bellek
/// içi verilerle yanıtlanır; diğerleri `404` döndüren bir `MockClient`'e düşer.
/// Her çağrı [calls] listesine yazılır.
class FakeCloudApi extends EvCloudApiService {
  FakeCloudApi({super.clock})
      : super(
          baseUrl: 'https://fake.invalid/api',
          client: MockClient(
            (request) async => errorResponse(404, 'Kayıt bulunamadı.', code: 'NOT_FOUND'),
          ),
        );

  /// Çağrı günlüğü (`yöntem` veya `yöntem:argüman`).
  final List<String> calls = <String>[];

  List<HomeModel> homes = <HomeModel>[];
  Object? fetchHomesError;
  Completer<void>? fetchHomesGate;

  final Map<String, List<EndpointModel>> endpoints = <String, List<EndpointModel>>{};
  Object? fetchEndpointsError;

  /// Atanırsa `fetchEndpoints` bu kapı açılana kadar bekler (REST yığını yavaş/takılı; MQTT'nin ondan önce
  /// başladığını denetlemek için). Yanıt istek anındaki listeyle üretilir (`fetchHomesGate` gibi).
  Completer<void>? fetchEndpointsGate;

  final Map<String, List<DeviceInfo>> devicesByHome = <String, List<DeviceInfo>>{};

  /// Atanırsa `devices` bu hatayı fırlatır (cihaz listesi alınamadı; varlık yedeği/yeniden deneme testleri).
  Object? devicesError;

  MqttCredentials? credentials;
  Object? credentialsError;

  /// Komut gönderim davranışı (varsayılan: iletildi, cihaz çevrimiçi).
  Future<CommandResult> Function(String homeId, String deviceId, Map<String, dynamic> command)?
      sendCommandHandler;
  final List<Map<String, dynamic>> sentCommands = <Map<String, dynamic>>[];

  /// `GET /devices/child-lock/:home` yanıtı: `child_lock_enabled` (köprünün eşitlediği birleşik durum),
  /// sunucuda kayıtlı niyet (`requested`) ve pano satırları (CONTRACTS §1.5b).
  bool childLockValue = false;
  bool? childLockRequestedValue;
  DateTime? childLockRequestedAt;
  List<ChildLockDeviceInfo> childLockDevices = const <ChildLockDeviceInfo>[];
  Object? childLockError;

  /// Atanırsa `getChildLock` bu kapı açılana kadar bekler (bayat GET yarışını simüle etmek için).
  Completer<void>? childLockGate;
  Object? setChildLockError;

  /// `POST /devices/child-lock` davranışı (tipli sonuç). Varsayılan yol [setChildLockJson] / sunucu
  /// şekliyle (`{home_id, requested, delivered, device_online, command_id, offline_devices[]}`)
  /// üretilir ve gerçek `CommandResult.fromJson` ile çözülür; bu kanca ise sonucu doğrudan verir.
  Future<CommandResult> Function(String homeId, bool enabled)? setChildLockHandler;

  /// `POST /devices/child-lock` ham JSON gövdesi (CONTRACTS §1.5b şekli). `delivered:false`,
  /// `device_online:false`, `offline_devices`, `no_change` ve **eksik alan** (ör. `delivered` yok)
  /// bu kancayla simüle edilir. Yanıtta `child_lock_enabled` bulunmaz (gerçek sunucu gibi).
  Map<String, dynamic> Function(String homeId, bool enabled, String commandId)? setChildLockJson;

  /// `GET /devices/peace-notification/:home` yanıtı (SUNUCU anahtarlarıyla).
  Map<String, dynamic> peaceNotification = <String, dynamic>{
    'home_id': 'home',
    'peace_notification_enabled': true,
    'peace_notification_time': '23:30',
    'open_lights_count': 0,
    'open_shutters_count': 0,
    'summary_text': 'Tüm lambalar kapalı, eviniz huzur modunda.',
    'open_lights': <dynamic>[],
  };

  UserModel loginUser =
      const UserModel(id: 'user-1', email: 'ev@example.test', fullName: 'Test Kullanıcı', role: 'user');
  Object? loginError;
  int _loginCounter = 0;

  /// `GET /auth/capabilities` yanıtı (UYELIK-04). `null` (varsayılan): uç yok (eski sunucu, sahte HTTP 404) ->
  /// giriş ekranı telefonla (SMS) giriş düğmesini GİZLER (fail-closed). Düğmeye dayanan testler
  /// `AuthCapabilities(smsOtp: true, ...)` atar. Çağrı [calls]'a YAZILMAZ (giriş ekranını açan testlerin çağrı listesi
  /// beklentileri değişmesin); sayısı [authCapabilitiesCalls]'tadır.
  AuthCapabilities? authCapabilities;
  Object? authCapabilitiesError;
  int authCapabilitiesCalls = 0;

  /// `refreshSession` davranışı (varsayılan: gerçek istemci; sahte HTTP 404 -> kalıcı red).
  Future<bool> Function()? refreshHandler;

  /// `changePassword` / `logoutAll` hataları (ağ, yanlış parola ...).
  Object? changePasswordError;
  Object? logoutAllError;

  /// `revokeRefreshToken` çağrıldığı anda tetiklenir (çıkışta "önce yerel temizlik" sırasını denetlemek için).
  void Function(String refreshToken)? onRevoke;

  /// Servis girişi: dönen oturum (varsayılan 2 saat, `home-1`).
  ServiceSessionInfo? serviceSessionToReturn;
  Object? serviceLoginError;

  /// `POST /homes/:id/service-token` yanıtı (varsayılan: `123456`, 2 saat; PIN gerçek değildir).
  ServiceTokenModel? serviceTokenToReturn;
  Object? serviceTokenError;

  /// `POST /devices/claim` / acil sıfırlama / pano değişimi yanıtları (tek seferlik gizli alanlar dahil).
  ClaimResult? claimResultToReturn;
  Object? claimError;
  EmergencyResetResult? emergencyResetToReturn;
  ReplaceBoardResult? replaceBoardToReturn;

  /// Ev sahibi servis erişimi yönetimi yanıtları.
  List<ServiceTokenSummary> serviceTokens = <ServiceTokenSummary>[];
  List<ServiceSessionSummary> serviceSessions = <ServiceSessionSummary>[];
  RevokeServiceAccessResult revokeResult = const RevokeServiceAccessResult(revokedPins: 1, revokedSessions: 1);

  /// `POST /homes/:id/devices/:uuid/mqtt-credential` yanıtı (yer tutucu, gerçek olmayan kimlik).
  DeviceMqttCredential? deviceCredentialToReturn;

  List<HomeMember> members = <HomeMember>[];
  final List<String> removedMembers = <String>[];
  String localKeyValue = 'localkey-1234';
  Object? localKeyError;

  /// Atanırsa `localKey` bu kapı açılana kadar bekler (yavaş anahtar yenilemesi; dispose/mod değişimi yarışları).
  /// Dönen anahtar istek anındaki değerdir (`localKeyValue`); hata kapıdan SONRA okunur.
  Completer<void>? localKeyGate;

  /// `localKey` çağrılarının ev kimlikleri (servis sihirbazında aktif olmayan ev denetimi için).
  final List<String> localKeyHomeIds = <String>[];
  final List<String> revokedRefreshTokens = <String>[];

  List<ScheduledRule> rules = <ScheduledRule>[];

  @override
  Future<List<HomeModel>> fetchHomes() async {
    calls.add('fetchHomes');
    // Yanıt istek anındaki listeyle üretilir (kapı açılana kadar liste değişse de bayat yanıt simülasyonu).
    final snapshot = List<HomeModel>.of(homes);
    final gate = fetchHomesGate;
    if (gate != null) await gate.future;
    final error = fetchHomesError;
    if (error != null) throw error;
    return snapshot;
  }

  @override
  Future<List<EndpointModel>> fetchEndpoints(String homeId) async {
    calls.add('fetchEndpoints:$homeId');
    // Yanıt istek anındaki listeyle üretilir (kapı açılana kadar liste değişse de bayat yanıt simülasyonu).
    final snapshot = List<EndpointModel>.of(endpoints[homeId] ?? const <EndpointModel>[]);
    final gate = fetchEndpointsGate;
    if (gate != null) await gate.future;
    final error = fetchEndpointsError;
    if (error != null) throw error;
    return snapshot;
  }

  @override
  Future<List<DeviceInfo>> devices(String homeId) async {
    calls.add('devices:$homeId');
    final error = devicesError;
    if (error != null) throw error;
    return List<DeviceInfo>.of(devicesByHome[homeId] ?? const <DeviceInfo>[]);
  }

  @override
  Future<MqttCredentials> mqttCredentials(String homeId) async {
    calls.add('mqttCredentials:$homeId');
    final error = credentialsError;
    if (error != null) throw error;
    return credentials ??
        MqttCredentials(
          host: 'broker.fake.invalid',
          port: 8884,
          username: 'a_h_test_1',
          password: 'fake-secret-not-real',
          expiresAt: DateTime.now().toUtc().add(const Duration(hours: 12)),
          topicId: 'h_test',
        );
  }

  @override
  Future<CommandResult> sendCommand({
    required String homeId,
    required String deviceId,
    required Map<String, dynamic> command,
  }) async {
    calls.add('sendCommand:$deviceId');
    sentCommands.add(Map<String, dynamic>.of(command));
    final handler = sendCommandHandler;
    if (handler != null) return handler(homeId, deviceId, command);
    return CommandResult(delivered: true, deviceOnline: true, commandId: command['id'] as String?);
  }

  // --- Güvenlik modülü (tasarım §5.2.4) ---

  final List<ActuatorCall> actuatorCalls = <ActuatorCall>[];

  /// Eylemci komutu davranışı (varsayılan: iletildi, cihaz çevrimiçi, komut kimliği yankılanır).
  Future<CommandResult> Function(ActuatorCall call)? actuatorHandler;

  final List<({String alarmId, String commandId})> ackCalls = <({String alarmId, String commandId})>[];
  final List<({String deviceId, int zone, String commandId})> alarmTestCalls =
      <({String deviceId, int zone, String commandId})>[];

  /// `GET /homes/:id/alarms` yanıtı.
  List<AlarmRecord> alarmRecords = const <AlarmRecord>[];
  Object? alarmsError;

  @override
  Future<CommandResult> actuatorCommand({
    required String homeId,
    required String deviceId,
    required String actuatorId,
    required String to,
    required String commandId,
  }) async {
    final call = ActuatorCall(homeId: homeId, deviceId: deviceId, actuatorId: actuatorId, to: to, commandId: commandId);
    calls.add('actuator:$actuatorId:$to');
    actuatorCalls.add(call);
    final handler = actuatorHandler;
    if (handler != null) return handler(call);
    return CommandResult(delivered: true, deviceOnline: true, commandId: commandId);
  }

  @override
  Future<CommandResult> ackAlarm({required String homeId, required String alarmId, required String commandId}) async {
    calls.add('ackAlarm:$alarmId');
    ackCalls.add((alarmId: alarmId, commandId: commandId));
    return CommandResult(delivered: true, deviceOnline: true, commandId: commandId);
  }

  @override
  Future<CommandResult> alarmTest({
    required String homeId,
    required String deviceId,
    required int zone,
    required String commandId,
  }) async {
    calls.add('alarmTest:$zone');
    alarmTestCalls.add((deviceId: deviceId, zone: zone, commandId: commandId));
    return CommandResult(delivered: true, deviceOnline: true, commandId: commandId);
  }

  @override
  Future<List<AlarmRecord>> alarms(String homeId, {bool openOnly = true, String? before}) async {
    calls.add('alarms:$homeId');
    final error = alarmsError;
    if (error != null) throw error;
    return alarmRecords;
  }

  /// `GET /homes/:id/devices/:uid/safety-config` yanıtları (pano uid'i -> gövde). Yoksa `404 CONFIG_NOT_AVAILABLE`.
  final Map<String, Map<String, dynamic>> safetyConfigs = <String, Map<String, dynamic>>{};

  @override
  Future<Map<String, dynamic>> safetyConfig(String homeId, String deviceId) async {
    calls.add('safetyConfig:$deviceId');
    final body = safetyConfigs[deviceId.toUpperCase()];
    if (body == null) {
      throw const ApiException(statusCode: 404, code: 'CONFIG_NOT_AVAILABLE', message: 'Yapılandırma yok.');
    }
    return body;
  }

  @override
  Future<ChildLockInfo> fetchChildLockInfo(String homeId) async {
    calls.add('getChildLock');
    final gate = childLockGate;
    final value = childLockValue; // istek anındaki değer (bayat yanıt simülasyonu)
    final requested = childLockRequestedValue;
    if (gate != null) await gate.future;
    final error = childLockError;
    if (error != null) throw error;
    return ChildLockInfo(
      enabled: gate != null ? value : childLockValue,
      requested: gate != null ? requested : childLockRequestedValue,
      requestedAt: childLockRequestedAt,
      devices: childLockDevices,
    );
  }

  @override
  Future<CommandResult> setChildLock({required String homeId, required bool enabled}) async {
    calls.add('setChildLock:$enabled');
    final error = setChildLockError;
    if (error != null) throw error;
    final handler = setChildLockHandler;
    if (handler != null) return handler(homeId, enabled);
    final commandId = 'srv-${calls.length}';
    final json = setChildLockJson != null
        ? setChildLockJson!(homeId, enabled, commandId)
        : <String, dynamic>{
            'home_id': homeId,
            'requested': enabled,
            'delivered': true,
            'device_online': true,
            'command_id': commandId,
            'offline_devices': <String>[],
          };
    // Gerçek istemcideki çözümleme yolu: `delivered` yoksa iletildi SAYILMAZ.
    return CommandResult.fromJson(json, deliveredDefault: false);
  }

  @override
  Future<Map<String, dynamic>> getPeaceNotification(String homeId) async {
    calls.add('getPeaceNotification');
    return Map<String, dynamic>.of(peaceNotification);
  }

  Map<String, dynamic> _newFakeSession(UserModel user) {
    _loginCounter++;
    beginSession(accessToken: 'access-$_loginCounter', refreshToken: 'refresh-$_loginCounter');
    return <String, dynamic>{
      'access_token': 'access-$_loginCounter',
      'refresh_token': 'refresh-$_loginCounter',
      'user': user.toJson(),
    };
  }

  @override
  Future<Map<String, dynamic>> login(String identifier, String password) async {
    calls.add('login:$identifier');
    final error = loginError;
    if (error != null) throw error;
    return _newFakeSession(loginUser);
  }

  @override
  Future<Map<String, dynamic>> magicLogin(String token) async {
    calls.add('magicLogin');
    final error = loginError;
    if (error != null) throw error;
    return _newFakeSession(loginUser);
  }

  @override
  Future<AuthCapabilities> fetchAuthCapabilities() async {
    authCapabilitiesCalls++;
    final error = authCapabilitiesError;
    if (error != null) throw error;
    return authCapabilities ?? super.fetchAuthCapabilities();
  }

  @override
  Future<Map<String, dynamic>> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    calls.add('changePassword');
    final error = changePasswordError;
    if (error != null) throw error;
    return _newFakeSession(loginUser.copyWith(mustChangePassword: false));
  }

  @override
  Future<void> logoutAll() async {
    calls.add('logoutAll');
    final error = logoutAllError;
    if (error != null) throw error;
    clearSession();
  }

  @override
  Future<bool> refreshSession() async {
    calls.add('refreshSession');
    final handler = refreshHandler;
    if (handler != null) return handler();
    return super.refreshSession();
  }

  @override
  Future<ServiceSessionInfo> serviceLogin(String servicePin, {String? technicianName}) async {
    calls.add('serviceLogin');
    final error = serviceLoginError;
    if (error != null) throw error;
    final info = serviceSessionToReturn ??
        ServiceSessionInfo(
          homeId: 'home-1',
          homeName: 'Servis Evi',
          expiresAt: DateTime.now().toUtc().add(const Duration(hours: 2)),
          technicianName: technicianName ?? '',
        );
    beginSession(accessToken: 'service-access');
    restoreServiceSession(accessToken: 'service-access', info: info);
    return info;
  }

  @override
  Future<ServiceTokenModel> createServiceToken(String homeId) async {
    calls.add('createServiceToken:$homeId');
    final error = serviceTokenError;
    if (error != null) throw error;
    return serviceTokenToReturn ??
        ServiceTokenModel(pin: '123456', expiresAt: DateTime.now().toUtc().add(const Duration(hours: 2)));
  }

  @override
  Future<ClaimResult> claimDevice({
    required String deviceUuid,
    required String setupPin,
    String? homeName,
    String? targetOwner,
    String? otpCode,
  }) async {
    calls.add('claimDevice:$deviceUuid');
    final error = claimError;
    if (error != null) throw error;
    return claimResultToReturn ??
        ClaimResult(homeId: kHomeA, homeName: homeName ?? 'Yeni Ev', deviceUuid: deviceUuid);
  }

  @override
  Future<EmergencyResetResult> emergencyResetDevice({
    required String deviceUuid,
    required String confirmUid,
    required String reason,
    String? newOwnerIdentifier,
  }) async {
    calls.add('emergencyResetDevice:$deviceUuid');
    return emergencyResetToReturn ??
        EmergencyResetResult(action: 'UNCLAIMED', deviceUuid: deviceUuid, setupPin: '000000');
  }

  @override
  Future<ReplaceBoardResult> replaceBoard({
    required String homeId,
    String? oldDeviceUuid,
    required String newDeviceUuid,
    required String setupPin,
    String? reason,
  }) async {
    calls.add('replaceBoard:$newDeviceUuid');
    return replaceBoardToReturn ?? ReplaceBoardResult(newDeviceUuid: newDeviceUuid, homeId: homeId);
  }

  @override
  Future<List<ServiceTokenSummary>> listServiceTokens(String homeId) async {
    calls.add('listServiceTokens:$homeId');
    return List<ServiceTokenSummary>.of(serviceTokens);
  }

  @override
  Future<List<ServiceSessionSummary>> listServiceSessions(String homeId) async {
    calls.add('listServiceSessions:$homeId');
    return List<ServiceSessionSummary>.of(serviceSessions);
  }

  @override
  Future<RevokeServiceAccessResult> revokeServiceAccess(String homeId) async {
    calls.add('revokeServiceAccess:$homeId');
    return revokeResult;
  }

  @override
  Future<DeviceMqttCredential> reissueDeviceMqttCredential(String homeId, String deviceUuid) async {
    calls.add('reissueDeviceMqttCredential:$deviceUuid');
    return deviceCredentialToReturn ??
        const DeviceMqttCredential(
          host: 'broker.fake.invalid',
          port: 8884,
          username: 'd_h_test',
          password: 'fake-device-secret-not-real',
          topicId: 'h_test',
        );
  }

  @override
  Future<bool> revokeRefreshToken(String refreshToken, {String? accessToken}) async {
    calls.add('revokeRefreshToken');
    revokedRefreshTokens.add(refreshToken);
    onRevoke?.call(refreshToken);
    return true;
  }

  @override
  Future<String> localKey(String homeId, String deviceUuid) async {
    calls.add('localKey:$deviceUuid');
    localKeyHomeIds.add(homeId);
    final value = localKeyValue;
    final gate = localKeyGate;
    if (gate != null) await gate.future;
    final error = localKeyError;
    if (error != null) throw error;
    return value;
  }

  @override
  Future<List<HomeMember>> getHomeMembers(String homeId) async {
    calls.add('getHomeMembers:$homeId');
    return List<HomeMember>.of(members);
  }

  @override
  Future<bool> removeHomeMember(String homeId, String targetUserId) async {
    calls.add('removeHomeMember:$targetUserId');
    removedMembers.add(targetUserId);
    members = members.where((m) => m.userId != targetUserId).toList();
    return true;
  }

  @override
  Future<List<ScheduledRule>> getScheduledRules(String homeId) async {
    calls.add('getScheduledRules');
    return List<ScheduledRule>.of(rules);
  }

  int count(String prefix) => calls.where((c) => c == prefix || c.startsWith('$prefix:')).length;
}

// =============================================================================
// MQTT
// =============================================================================

/// `EvMqttService` yerine geçen sahte (yalnızca abonelik). Olayları testten üretin:
/// `emitState`, `emitPresence`, `setLink`.
class FakeMqtt implements EvMqttService {
  final _link = StreamController<MqttLinkState>.broadcast();
  final _state = StreamController<DeviceStateMessage>.broadcast();
  final _status = StreamController<DevicePresenceMessage>.broadcast();
  final _safety = StreamController<SafetyEvent>.broadcast();

  MqttLinkState _linkState = MqttLinkState.disconnected;
  String? _topic;

  /// `start` çağrıları ve alınan kimlik.
  int startCount = 0;
  int stopCount = 0;
  MqttCredentials? lastCredentials;
  String? lastInstallId;
  Object? lastStartError;

  /// `start` sonrası otomatik bağlansın mı?
  bool autoConnect = true;

  @override
  Stream<MqttLinkState> get linkStates => _link.stream;

  @override
  MqttLinkState get linkState => _linkState;

  @override
  bool get isConnected => _linkState == MqttLinkState.connected;

  @override
  Stream<DeviceStateMessage> get stateMessages => _state.stream;

  @override
  Stream<DevicePresenceMessage> get statusMessages => _status.stream;

  @override
  Stream<SafetyEvent> get safetyEvents => _safety.stream;

  /// Güvenlik olayı üretir (gerçek servis bunu ardışık `state` farkından türetir).
  void emitSafetyEvent(SafetyEvent event) => _safety.add(event);

  @override
  int get droppedMessageCount => 0;

  @override
  MqttFailure get lastFailure => MqttFailure.none;

  @override
  String? get topicId => _topic;

  void setLink(MqttLinkState value) {
    if (_linkState == value) return;
    _linkState = value;
    _link.add(value);
  }

  @override
  Future<void> start({
    required MqttCredentialsProvider credentialsProvider,
    String? installId,
    String? fallbackTopicId,
  }) async {
    startCount++;
    lastInstallId = installId;
    lastStartError = null;
    setLink(MqttLinkState.connecting);
    try {
      lastCredentials = await credentialsProvider();
      _topic = lastCredentials!.topicId;
      if (autoConnect) setLink(MqttLinkState.connected);
    } catch (e) {
      lastStartError = e;
      setLink(MqttLinkState.disconnected);
    }
  }

  @override
  Future<void> stop() async {
    stopCount++;
    _topic = null;
    setLink(MqttLinkState.disconnected);
  }

  @override
  Future<void> disconnect() => stop();

  @override
  void ingestBatch(List<MqttInboundMessage> batch) {}

  @override
  void dispose() {
    _link.close();
    _state.close();
    _status.close();
    _safety.close();
  }

  /// Cihaz `state` iletisi üretir.
  void emitState(DeviceStatus status, {bool retained = false}) {
    _state.add(DeviceStateMessage(
      topicId: _topic ?? 'h_test',
      status: status,
      retained: retained,
      receivedAt: DateTime.now(),
    ));
  }

  /// MQTT v2 `state` JSON'undan (CONTRACTS §2.4) ileti üretir.
  void emitStateJson(Map<String, dynamic> json, {bool retained = false}) =>
      emitState(DeviceStatus.fromJson(json, filterPhantomShutters: false), retained: retained);

  /// `status` (online/offline) iletisi üretir.
  void emitPresence(bool online, {bool retained = false}) {
    _status.add(DevicePresenceMessage(
      topicId: _topic ?? 'h_test',
      online: online,
      retained: retained,
      receivedAt: DateTime.now(),
    ));
  }
}

/// [FakeCloudApi.actuatorCommand] çağrı kaydı.
class ActuatorCall {
  const ActuatorCall({
    required this.homeId,
    required this.deviceId,
    required this.actuatorId,
    required this.to,
    required this.commandId,
  });

  final String homeId;
  final String deviceId;
  final String actuatorId;
  final String to;
  final String commandId;
}

/// `MqttTransport` sahtesi: gerçek `EvMqttService` döngüsünü (yenileme/yeniden bağlanma) sınar.
class FakeMqttTransport implements MqttTransport {
  final batches = StreamController<List<MqttInboundMessage>>.broadcast();
  final disconnects = StreamController<void>.broadcast();
  final subscribeFailuresController = StreamController<String>.broadcast();

  MqttConnectOutcome outcome = const MqttConnectOutcome.ok();

  /// Atanırsa `connect` bu kapı açılana kadar DÖNMEZ (TCP/TLS kurulumu takıldı; PF-27). Kimlik/istemci
  /// alanları kapıdan ÖNCE yazılır (takılı bağlanma denemesi izlenebilsin); kapı açılınca [outcome] döner.
  Completer<void>? connectGate;
  final List<String> subscriptions = <String>[];
  MqttCredentials? credentials;
  String? clientId;
  bool? secure;
  bool closed = false;

  @override
  Stream<List<MqttInboundMessage>> get messageBatches => batches.stream;

  @override
  Stream<void> get disconnected => disconnects.stream;

  @override
  Stream<String> get subscribeFailures => subscribeFailuresController.stream;

  @override
  Future<MqttConnectOutcome> connect({
    required MqttCredentials credentials,
    required String clientId,
    required bool secure,
    required Duration timeout,
  }) async {
    this.credentials = credentials;
    this.clientId = clientId;
    this.secure = secure;
    final gate = connectGate;
    if (gate != null) await gate.future;
    return outcome;
  }

  @override
  void subscribe(String topic) => subscriptions.add(topic);

  @override
  void close() {
    closed = true;
  }

  /// Aktarım üzerinden bir ileti grubu "alınmış" gibi davranır.
  void deliver(List<MqttInboundMessage> batch) => batches.add(batch);

  /// Bağlantı koptu.
  void drop() => disconnects.add(null);
}

// =============================================================================
// Test donanımı
// =============================================================================

/// `AutomationState` + tüm sahteler tek pakette.
class StateHarness {
  StateHarness._({
    required this.clock,
    required this.cloud,
    required this.mqtt,
    required this.storage,
    required this.biometric,
    required this.directMock,
    required this.direct,
    required this.state,
  });

  final FakeClock clock;
  final FakeCloudApi cloud;
  final FakeMqtt mqtt;
  final FakeStorage storage;
  final FakeBiometric biometric;
  final MockApi directMock;
  final AutomationApiService direct;
  final AutomationState state;

  /// [autoInit] `false` (varsayılan): durum elle kurulur (`setHomesForTesting` vb.).
  factory StateHarness({
    bool autoInit = false,
    bool biometricSupported = false,
    Duration biometricRelockAfter = const Duration(seconds: 30),
    Duration confirmTimeout = const Duration(milliseconds: 2500),
    Duration directPollInterval = const Duration(milliseconds: 1500),
    FakeClock? clock,
    FakeCloudApi? cloud,
    FakeMqtt? mqtt,
    FakeStorage? storage,
    FakeBiometric? biometric,
  }) {
    final fakeClock = clock ?? FakeClock();
    final fakeCloud = cloud ?? FakeCloudApi(clock: fakeClock);
    final fakeMqtt = mqtt ?? FakeMqtt();
    final fakeStorage = storage ?? FakeStorage();
    final fakeBiometric = biometric ?? FakeBiometric(supported: biometricSupported);
    // Depo/biyometrik sonda süre sınırları (PF-02) harness saatiyle ilerler: `h.storage.memory.hangReads`
    // atanıp `await h.clock.elapse(...)` çağrılırsa takılan çağrı zaman aşımına uğrar. Açıkça `clock:`
    // verilmiş `FakeStorage`/`FakeBiometric` değiştirilmez. Normal (hemen dönen) işlemler sınır
    // zamanlayıcısını tamamlanır tamamlanmaz iptal eder (`activeTimerCount` kalıcı artmaz).
    fakeStorage.bindClockIfUnset(fakeClock);
    fakeBiometric.bindClockIfUnset(fakeClock);
    final mock = MockApi();
    final direct = AutomationApiService(baseUrl: '', client: mock.client);
    final state = AutomationState(
      cloudApi: fakeCloud,
      mqttService: fakeMqtt,
      secureStorage: fakeStorage,
      biometricService: fakeBiometric,
      directApi: direct,
      clock: fakeClock,
      autoInit: autoInit,
      observeAppLifecycle: false,
      biometricRelockAfter: biometricRelockAfter,
      confirmTimeout: confirmTimeout,
      directPollInterval: directPollInterval,
    );
    return StateHarness._(
      clock: fakeClock,
      cloud: fakeCloud,
      mqtt: fakeMqtt,
      storage: fakeStorage,
      biometric: fakeBiometric,
      directMock: mock,
      direct: direct,
      state: state,
    );
  }

  void dispose() => state.dispose();
}

// =============================================================================
// Hazır test verileri
// =============================================================================

/// UUID biçimli ev kimliği örneği.
const String kHomeA = '11111111-1111-4111-8111-111111111111';
const String kHomeB = '22222222-2222-4222-8222-222222222222';

HomeModel testHome({String id = kHomeA, String name = 'Ev A', String role = 'owner', String topic = 'h_test'}) =>
    HomeModel(id: id, name: name, role: role, mqttTopicId: topic);

/// Karışık yerleşim: 1–2 lamba, 3–4 panjur çifti (pair 1), 5 lamba, 6 priz.
List<EndpointModel> testEndpoints({String homeId = kHomeA, String deviceUuid = 'AHBU-S3-TEST01'}) {
  EndpointModel ep(
    String id,
    int channel,
    String type,
    String name, {
    int? pair,
    bool state = false,
    int pos = 0,
  }) =>
      EndpointModel(
        id: id,
        homeId: homeId,
        deviceId: 'dev-internal',
        deviceUuid: deviceUuid,
        channel: channel,
        shutterPair: pair,
        name: name,
        room: 'Salon',
        endpointType: type,
        currentState: state,
        shutterPosition: pos,
      );
  return <EndpointModel>[
    ep('e1', 1, 'light', 'Avize'),
    ep('e2', 2, 'light', 'Spot'),
    ep('e3', 3, 'shutter', 'Salon Panjur Yukarı', pair: 2, pos: 30),
    ep('e4', 4, 'shutter', 'Salon Panjur Aşağı', pair: 2, pos: 30),
    ep('e5', 5, 'light', 'Mutfak'),
    ep('e6', 6, 'plug', 'Priz'),
  ];
}

/// Cihaz `state` yükü (CONTRACTS §2.4) üretir.
Map<String, dynamic> stateJson({
  String uid = 'AHBU-S3-TEST01',
  Map<int, bool> relays = const <int, bool>{},
  List<Map<String, dynamic>> shutters = const <Map<String, dynamic>>[],
  bool? childLock,
  String? lastId,
  String? ip,
}) {
  return <String, dynamic>{
    'v': 2,
    'uid': uid,
    'fw': '1.1.0',
    'seq': 1,
    'child_lock': ?childLock,
    'last_id': ?lastId,
    'ip': ?ip,
    'relays': <Map<String, dynamic>>[
      for (final e in relays.entries) <String, dynamic>{'id': e.key, 'name': 'R${e.key}', 'type': 'light', 'state': e.value},
    ],
    'shutters': shutters,
    'dis': <Map<String, dynamic>>[],
  };
}

/// Hızlı JSON gösterimi (test hata mesajları için).
String pretty(Object? value) => const JsonEncoder.withIndent('  ').convert(value);

/// `package:http` yanıtı için kısayol.
http.Response noContent() => http.Response('', 204);
