import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/api_models.dart';
import '../models/automation_models.dart';
import '../models/capabilities.dart';
import '../models/cloud_models.dart';
import '../models/endpoint_sync.dart';
import '../models/json_utils.dart';
import '../models/legal_models.dart';
import '../models/scheduled_rule_model.dart';
import '../utils/qr_claim_parser.dart';
import 'alarm_watch/alarm_watch_support.dart';
import 'alarm_watch/refresh_gate.dart';
import 'api_exception.dart';
import 'automation_api_service.dart';
import 'biometric_auth_service.dart';
import 'clock.dart';
import 'command_pipeline.dart';
import 'ev_cloud_api_service.dart';
import 'ev_mqtt_service.dart';
import 'secure_storage_service.dart';

export 'api_exception.dart' show ApiException, SessionEndReason;
export 'command_pipeline.dart'
    show CommandDispatch, CommandDispatchStatus, CommandFailure, CommandFailureReason;

enum ConnectionStateEnum { connecting, connected, offline }

enum AppMode { direct, cloud }

enum AuthStatus { checking, authenticated, unauthenticated }

/// Cihazın çevrimiçi bilgisi (`status` konusu / `GET /homes/:id/devices`).
enum DevicePresence { unknown, online, offline }

/// Çocuk kilidi durumu. **Bilinmeyen durum "kilit kapalı" olarak gösterilmez** (ebeveyn denetiminde
/// fail-open olmasın diye ayrı bir değerdir).
enum ChildLockStatus {
  /// Henüz cihazdan/sunucudan değer alınmadı (veya alınamadı).
  unknown,

  /// Kilit kapalı: duvar anahtarları serbest.
  unlocked,

  /// Kilit açık: duvar anahtarları devre dışı.
  locked,

  /// Aynı evdeki birden fazla panonun kilidi farklı (nadir; ör. pano değişimi sırasında).
  mixed,
}

/// Oturum olayları (tek merkezden): arayüz bunları dinleyip uygun ekranı/uyarıyı gösterir.
sealed class SessionEvent {
  const SessionEvent();
}

/// Refresh token kalıcı reddedildi / servis oturumu bitti: yerel oturum silindi, giriş ekranına dönülür.
final class SessionExpiredEvent extends SessionEvent {
  const SessionExpiredEvent(this.reason);

  final SessionEndReason reason;
}

/// Misafir süresi doldu (`403 GUEST_EXPIRED`): ev erişimi kapatıldı, ev listesi yenileniyor.
final class GuestExpiredEvent extends SessionEvent {
  const GuestExpiredEvent({this.homeId, this.homeName});

  final String? homeId;
  final String? homeName;
}

/// Kaynak nesnesi (kimlik) değişmedikçe aynı türetilmiş değeri döndüren küçük önbellek (PF-20): salt-okunur liste
/// görünümleri atama başına BİR kez kurulur (eskiden her `get` listeyi baştan kopyalardı). Kaynak listeler yerinde
/// DEĞİŞTİRİLMEZ, atamayla değiştirilir (kimlik değişir).
class _IdentityMemo<S extends Object, V extends Object> {
  S? _source;
  V? _value;

  V of(S source, V Function(S source) build) {
    final cached = _value;
    if (cached != null && identical(_source, source)) return cached;
    final built = build(source);
    _source = source;
    _value = built;
    return built;
  }
}

/// Panjur komutlarının iyimser hedefi (yalnızca iç kullanım).
class _ShutterTarget {
  const _ShutterTarget({this.pos, this.moving, this.direction});

  final int? pos;
  final bool? moving;
  final int? direction;
}

/// Eylemci komutunun İYİMSER hedefi. Yalnız güvenli yön (vanayı kapat, sireni/fanı kapat) iyimser gösterilir;
/// güvenli olmayan yön (vanayı aç, sireni/fanı aç) onaya kadar gerçek değerde kalır (hedef `null`).
class _ActuatorTarget {
  const _ActuatorTarget({this.pos, this.on});

  final ValvePos? pos;
  final bool? on;
}

/// Bir panonun uç nokta listesiyle UYUŞMAYAN yerleşiminin izlenmesi (yalnızca iç kullanım; WP-STATE2): en son görülen
/// yerleşim (imzası aynı kaldıkça) ve bu imza için harcanan sessiz yenileme denemesi.
class _LayoutWatch {
  _LayoutWatch(this.layout);

  final ReportedLayout layout;
  int attempts = 0;
}

/// Uygulamanın tek durum kaynağı (oturum, ev, bulut/yerel durum, komutlar).
///
/// Bağımlılıklar kurucudan enjekte edilir (CONTRACTS §5); verilmeyenler gerçek uygulamaları ile
/// oluşturulur ve bu sınıf tarafından kapatılır.
class AutomationState extends ChangeNotifier {
  AutomationState({
    EvCloudApiService? cloudApi,
    EvMqttService? mqttService,
    SecureStorageService? secureStorage,
    BiometricAuthService? biometricService,
    AutomationApiService? directApi,
    Clock? clock,
    bool autoInit = true,
    bool observeAppLifecycle = true,
    this._biometricRelockAfter = const Duration(seconds: 30),
    this._directPollInterval = const Duration(milliseconds: 1500),
    this._confirmTimeout = const Duration(milliseconds: 2500),
  })  : clock = clock ?? const SystemClock(),
        cloudApi = cloudApi ?? EvCloudApiService(clock: clock ?? const SystemClock()),
        mqttService = mqttService ?? EvMqttService(clock: clock ?? const SystemClock()),
        secureStorage = secureStorage ?? SecureStorageService(clock: clock ?? const SystemClock()),
        biometricService = biometricService ?? BiometricAuthService(clock: clock ?? const SystemClock()),
        directApi = directApi ??
            AutomationApiService(baseUrl: '', clock: clock ?? const SystemClock()),
        _ownsCloudApi = cloudApi == null,
        _ownsMqtt = mqttService == null,
        _ownsDirectApi = directApi == null {
    this.cloudApi
      ..onTokenRefreshed = _onTokenRefreshed
      ..onSessionExpired = _handleSessionExpired
      ..onGuestExpired = _handleGuestExpired
      ..onForbidden = _handleForbidden;
    if (alarmWatchPlatformSupported && this.cloudApi.refreshGate == null) {
      // Android: arka plan alarm izleyicisi (ayrı isolate) aynı oturum ailesini kullanabilir; yenileme süreç geneli
      // kapıyla ve depodaki en son token'la yapılır (eş zamanlı rotasyon oturum ailesini iptal ettirirdi).
      this.cloudApi
        ..refreshGate = IsolateRefreshGate()
        ..readStoredRefreshToken = this.secureStorage.getRefreshToken;
    }
    _bindMqtt();
    _failureSub = _pipeline.failures.listen(_onCommandFailure);
    if (observeAppLifecycle) _attachLifecycle();
    ready = autoInit ? _init() : Future<void>.value();
  }

  // ---------------------------------------------------------------------------
  // Bağımlılıklar
  // ---------------------------------------------------------------------------

  final Clock clock;
  final EvCloudApiService cloudApi;
  final EvMqttService mqttService;
  final SecureStorageService secureStorage;
  final BiometricAuthService biometricService;
  final AutomationApiService directApi;

  final bool _ownsCloudApi;
  final bool _ownsMqtt;
  final bool _ownsDirectApi;
  final Duration _biometricRelockAfter;
  final Duration _directPollInterval;
  final Duration _confirmTimeout;

  /// Başlangıç (`_init`) tamamlandığında biter (testler için).
  late final Future<void> ready;

  late final CommandPipeline _pipeline = CommandPipeline(
    clock: clock,
    confirmTimeout: _confirmTimeout,
    onChanged: _onPipelineChanged,
  );

  // SharedPreferences anahtarları (belirteç YOK; yalnızca SecureStorage'da).
  static const _prefsInstallId = 'ahbu_install_id';
  static const _prefsTheme = 'saved_theme_mode';
  static const _prefsMode = 'saved_app_mode';
  static const _prefsHost = 'saved_esp_host';
  static const _prefsSvcUuid = 'saved_service_device_uuid';
  static const _prefsSvcIp = 'saved_service_device_ip';
  static const _prefsSvcName = 'saved_service_device_name';
  static const _prefsActiveHome = 'saved_active_home_id';
  static const _prefsLegacyToken = 'saved_auth_token';

  /// Ev başına hatırlanan LAN panosu (kullanim-1): `lan_device_<evKimliği>` -> pano uid'i (gizli değil). İnternet yokken
  /// (cihaz listesi alınamaz) yerel anahtar bu kimlikle güvenli depodan bulunur.
  static const _prefsLanDevicePrefix = 'lan_device_';

  /// Ev başına doğrudan kip adresi (kullanim-3): `saved_esp_host_<evKimliği>`.
  static const _prefsHostPrefix = 'saved_esp_host_';

  /// Yerel anahtarın sunucudan son önden tazelendiği an (pano-6): `local_key_prefetch_<uid>` -> epoch ms.
  static const _prefsKeyPrefetchPrefix = 'local_key_prefetch_';

  /// Girişsiz yerel kipte anahtarı girilen panonun kimliği (bireysel-5).
  static const _prefsAnonLanDevice = 'saved_lan_device_uuid';

  // ---------------------------------------------------------------------------
  // Durum alanları
  // ---------------------------------------------------------------------------

  bool _isDisposed = false;
  int _sessionEpoch = 0;
  int _homeEpoch = 0;
  String _installId = '';

  AppMode _mode = AppMode.cloud;
  AuthStatus _authStatus = AuthStatus.checking;
  String? _sessionNotice;
  String? _storageError;

  // Doğrudan (LAN) mod
  DeviceStatus? _status;
  ConnectionStateEnum _connState = ConnectionStateEnum.connecting;
  String _host = '';
  Timer? _pollTimer;
  Future<void>? _pollInFlight;
  int _directFailures = 0;
  String? _directError;
  bool _localKeyRefreshTried = false;

  // LAN yoklaması durdurma/duraklatma (PF-01): kalıcı koşul (401/403 unprovisioned/anahtarsız özet) için
  // `_pollHalted`, süreli koşul (423) için `_pollNotBefore`. Periyodik zamanlayıcı tek kalır; geri çağrısı
  // erken döner. Kullanıcı eylemi / ön plana dönüş / yeni adres-anahtar `_resumeDirectPolling` ile sürdürür.
  bool _pollHalted = false;
  DateTime? _pollNotBefore;

  // Uçuştaki LAN isteğinin hedefi (PF-32): adres/anahtar değişirse eski uçuş devralınmaz, sonucu atılır.
  String? _pollFlightBase;
  String? _pollFlightKey;

  /// Ev kimliği -> hatırlanan LAN panosu uid'i (kullanim-1; `lan_device_<ev>` tercihlerinin bellek kopyası).
  final Map<String, String> _lanDeviceByHome = <String, String>{};

  /// Girişsiz yerel kipte anahtarı girilen panonun uid'i (bireysel-5; `saved_lan_device_uuid`).
  String? _anonLanDevice;

  /// Son LAN yanıtının pano kimliği (tam durumda `uid`, kısıtlı özette `device`) (bireysel-5).
  String? _lastLanUid;

  // Telemetri bildirim eşiği (PF-33): `uptime`/RSSI için SON BİLDİRİLEN değerler.
  int _telemetryUptimeSec = 0;
  int _telemetryRssi = 0;

  // Bulut / çok kiracılı durum
  UserModel? _currentUser;
  List<HomeModel> _homes = const [];
  HomeModel? _activeHome;
  bool _homesLoading = false;
  bool _homesLoaded = false;
  bool _homesFromCache = false;
  String? _homesError;
  Future<void>? _homesFlight;

  List<EndpointModel> _cloudEndpoints = const [];
  List<EndpointModel>? _endpointView;
  bool _endpointsLoading = false;
  bool _endpointsLoaded = false;
  String? _endpointsError;
  Future<void>? _cloudRefreshFlight;

  List<DeviceInfo> _devices = const [];
  DevicePresence _presence = DevicePresence.unknown;
  MqttLinkState _mqttLink = MqttLinkState.disconnected;
  final Map<int, ShutterRuntime> _shutterRuntime = <int, ShutterRuntime>{};

  /// Pano (`state.uid`, büyük harf) başına son güvenlik durumu (bulut kipi; `state v:3`). Eşitlik denetimli: özdeş
  /// kalp atışı bildirim üretmez (PF-04).
  final Map<String, SafetyState> _safetyByUid = <String, SafetyState>{};

  /// Pano anahtarı ([safetyByDevice] anahtarı) başına yapılandırma kopyasından gelen sensör/eylemci ADLARI [B12].
  /// `cfg.safety.rev/crc` değişince yeniden okunur: bulutta `GET …/devices/:uid/safety-config` (sunucunun `cfg_dump`
  /// kopyası), LAN'da `GET /api/safety/config` (CONTRACTS §1.5d, §2.6). Okunamazsa kimlik / uç nokta adı gösterilir.
  final Map<String, SafetyConfigNames> _safetyNames = <String, SafetyConfigNames>{};

  /// Pano anahtarı başına son `state`'in `uptime`'ı ve alındığı an (F2.B.9 geri sayımı: kalan süre
  /// `until_up - (uptime + geçen süre)`; `until_up` sabit olduğundan görünüm imzası her saniye değişmez).
  final Map<String, ({int uptime, DateTime at})> _armClock = <String, ({int uptime, DateTime at})>{};
  final Set<String> _safetyNamesInFlight = <String>{};
  final Map<String, DateTime> _safetyNamesRetryAt = <String, DateTime>{};
  static const Duration _safetyNamesRetry = Duration(seconds: 60);
  DeviceStatus? _lastLiveSnapshot;
  DateTime? _lastLiveSnapshotAt;

  /// Son **canlı** (retained olmayan) `state` zamanı: cihazın yaşadığının kanıtı. Cihaz `state`/`status`
  /// iletilerini QoS 0 yayınlar; kaybolan bir "online" status'u, broker'daki retained "offline"
  /// (LWT) iletisini geçerli bırakabilir. Taze bir canlı `state` varken retained "offline" yok sayılır.
  DateTime? _lastLiveStateAt;

  /// Canlı `state`'in "taze" sayıldığı süre (cihaz ~30 sn'de bir kalp atışı yayınlar: 3 kalp atışı).
  static const Duration _liveStateFreshness = Duration(seconds: 90);
  String? _lastDeviceIp;
  int _realtimeEpoch = -1;
  Timer? _reconcileTimer;

  /// Canlı kanalın (MQTT) bu ev için en son başlatıldığı an (kullanim-2): bu andan SONRA uygulanan ilk `state`, güvenlik
  /// görünümünün (alarm kartları) taze olduğunu kanıtlar. Arka plandan dönüşte eski harita bayat kalabilir.
  DateTime? _realtimeStartedAt;

  /// [awaitFreshSafety] bekleyicileri: [_applyCloudSnapshot] her uygulamada tamamlar.
  final List<Completer<void>> _snapshotWaiters = <Completer<void>>[];

  String? _servicePin;
  DateTime? _servicePinExpiry;
  Timer? _servicePinTimer;
  Timer? _serviceSessionTimer;
  Timer? _guestExpiryTimer;
  DateTime? _lastForbiddenRefresh;

  // Çocuk kilidi & huzur bildirimi
  // Cihaz bildirimi (MQTT `state.child_lock` / LAN `status`) TEK doğruluk kaynağıdır: pano uid'si
  // başına (LAN için '_lan'). REST (`GET /devices/child-lock`) yalnızca cihaz bildirimi yokken kullanılır.
  final Map<String, bool> _childLockByUid = <String, bool>{};
  bool? _childLockRest;

  // Sunucuda kayıtlı kilit NİYETİ (`POST/GET /devices/child-lock` -> `requested`) ve komutun
  // iletilemediği çevrimdışı panolar. Gerçek durum değil, bilgidir (gerçek durum cihaz bildirimidir).
  bool? _childLockRequested;
  List<String> _childLockOfflineDevices = const <String>[];
  DateTime? _childLockUpdatedAt;
  DateTime? _childLockDeviceAt;
  Map<String, dynamic>? _peaceNotificationData;

  // Zamanlı kurallar
  List<ScheduledRule> _scheduledRules = const [];
  bool _scheduledRulesLoading = false;
  String? _scheduledRulesError;

  // Biyometrik güvenlik
  bool _isBiometricEnabled = false;
  bool _isBiometricSupported = false;
  String _biometricLabel = 'Biyometrik Giriş';
  bool _shouldPromptBiometrics = false;
  bool _biometricChecking = false;
  bool _biometricFailed = false;
  bool _pendingRestore = false;
  bool _awaitingUnlock = false;

  // Yaşam döngüsü
  AppLifecycleListener? _lifecycleListener;
  bool _inBackground = false;
  DateTime? _backgroundedAt;

  // Servis cihazı seçimi (UUID + IP)
  String _selectedDeviceUuid = '';
  String _selectedDeviceIp = '';
  String? _selectedDeviceName;

  // Envanter & aboneler
  List<InventoryDeviceModel> _inventoryDevices = const [];
  Map<String, int> _inventoryStats = <String, int>{
    'total': 0,
    'in_stock': 0,
    'claimed': 0,
    'suspended': 0,
  };
  bool _inventoryLoading = false;
  String? _inventoryError;
  List<Map<String, dynamic>> _serviceSubscribers = const [];
  bool _subscribersLoading = false;
  String? _subscribersError;

  // Tema
  ThemeMode _themeMode = ThemeMode.dark;

  // Akışlar & abonelikler
  final _sessionEvents = StreamController<SessionEvent>.broadcast();
  StreamSubscription<MqttLinkState>? _mqttLinkSub;
  StreamSubscription<DeviceStateMessage>? _mqttStateSub;
  StreamSubscription<DevicePresenceMessage>? _mqttStatusSub;
  StreamSubscription<CommandFailure>? _failureSub;
  Future<void> _storageQueue = Future<void>.value();

  // Görünüm önbelleği (PF-20): `relayItems`/`shutterItems`/`status`/`cloudEndpoints` girdileri değişmedikçe AYNI
  // nesneyi döndürür (kart başına yeniden türetme yok). `_viewGen`, görünüm girdileri (uç noktalar, canlı panjur
  // durumu, LAN durumu, bekleyen komutlar) her değiştiğinde [_invalidateViews] ile artar: girdiyi değiştiren HER
  // yer onu çağırmalıdır (kaçırılırsa bayat görünüm; testler: `state_memo_test.dart`). Kaynak `_mode` anahtardadır.
  int _viewGen = 0;
  List<RelayItem>? _relayItemsMemo;
  int _relayItemsGen = -1;
  AppMode? _relayItemsMode;
  List<ShutterItem>? _shutterItemsMemo;
  int _shutterItemsGen = -1;
  AppMode? _shutterItemsMode;
  DeviceStatus? _statusMemo;
  int _statusGen = -1;
  Map<String, SafetyState>? _safetyMemo;
  int _safetyGen = -1;
  AppMode? _safetyMode;

  // `capabilities` önbelleği: kullanıcı, aktif ev (kimlik) ve misafir penceresinin O ANKİ sonucu aynı kaldıkça.
  Capabilities? _capsMemo;
  UserModel? _capsUser;
  HomeModel? _capsHome;
  bool _capsGuestExpired = false;

  // Salt-okunur liste/harita görünümleri (kaynak atandıkça bir kez kurulur).
  final _IdentityMemo<List<ScheduledRule>, List<ScheduledRule>> _rulesView = _IdentityMemo();
  final _IdentityMemo<List<InventoryDeviceModel>, List<InventoryDeviceModel>> _inventoryView = _IdentityMemo();
  final _IdentityMemo<Map<String, int>, Map<String, int>> _inventoryStatsView = _IdentityMemo();
  final _IdentityMemo<List<Map<String, dynamic>>, List<Map<String, dynamic>>> _subscribersView = _IdentityMemo();
  final _IdentityMemo<List<String>, List<String>> _offlineDevicesView = _IdentityMemo();

  // ---------------------------------------------------------------------------
  // Dışa açık okuma alanları
  // ---------------------------------------------------------------------------

  /// Oturum olayları: [SessionExpiredEvent], [GuestExpiredEvent].
  Stream<SessionEvent> get sessionEvents => _sessionEvents.stream;

  /// Geri alınan komutlar (arayüz snackbar gösterir). Mesaj Türkçe ve kullanıcıya gösterilebilir.
  Stream<CommandFailure> get commandFailures => _pipeline.failures;

  /// Komut hattı (testler/gelişmiş kullanım için).
  CommandPipeline get commandPipeline => _pipeline;

  AppMode get mode => _mode;
  AuthStatus get authStatus => _authStatus;
  bool get isAuthenticated => _authStatus == AuthStatus.authenticated;

  /// Doğrudan modda cihazın anlık durumu (bekleyen komutların iyimser değerleriyle birlikte). Girdiler
  /// değişmedikçe aynı nesne döner.
  DeviceStatus? get status {
    if (_statusGen != _viewGen) {
      _statusMemo = _viewStatus();
      _statusGen = _viewGen;
    }
    return _statusMemo;
  }

  /// Doğrudan mod bağlantı durumu; bulut modunda cihaz bilgisinden türetilir.
  ConnectionStateEnum get connState {
    if (_mode == AppMode.cloud) {
      switch (_presence) {
        case DevicePresence.online:
          return ConnectionStateEnum.connected;
        case DevicePresence.offline:
          return ConnectionStateEnum.offline;
        case DevicePresence.unknown:
          return ConnectionStateEnum.connecting;
      }
    }
    return _connState;
  }

  String get host => _host;

  /// MQTT broker bağlantısı (yalnızca bulut modunda anlamlı; canlı `state` akışı için).
  bool get brokerConnected => _mqttLink == MqttLinkState.connected;
  MqttLinkState get mqttLinkState => _mqttLink;

  /// Eski ad: [brokerConnected].
  bool get isMqttConnected => brokerConnected;

  /// Cihaz (pano) çevrimiçi bilgisi — **broker bağlantısından ayrı** bir alandır.
  DevicePresence get devicePresence => _presence;
  bool get deviceOnline => _presence == DevicePresence.online;

  /// Cihaza erişilebiliyor mu: bulutta cihaz çevrimiçi, doğrudan modda cihaz yanıt veriyor.
  bool get isConnected =>
      _mode == AppMode.cloud ? deviceOnline : _connState == ConnectionStateEnum.connected;

  UserModel? get currentUser => _currentUser;

  /// Sunucu parola değiştirmeyi zorunlu kıldı (`must_change_password`; ör. teknisyenin açtığı
  /// müşteri hesabı): arayüz **parola değiştirme ekranına zorlamalıdır** ([changePassword]).
  /// Başarılı değişimden sonra `false` olur; servis PIN oturumunda her zaman `false`.
  bool get mustChangePassword => !isServiceSession && (_currentUser?.mustChangePassword ?? false);

  AutomationApiService get api => directApi;
  List<HomeModel> get homes => _homes;
  HomeModel? get activeHome => _activeHome;
  HomeModel? homeById(String id) {
    for (final home in _homes) {
      if (home.id == id) return home;
    }
    return null;
  }

  /// Misafir süresi dolmuş evler (sunucu işaretledi veya pencere geçti).
  List<HomeModel> get expiredHomes {
    final now = clock.now();
    return _homes.where((h) => h.isGuestExpiredAt(now)).toList(growable: false);
  }

  bool get homesLoading => _homesLoading;

  /// Ev listesi **başarıyla** sunucudan alındı mı (boş liste ile hata ayırt edilir).
  bool get homesLoaded => _homesLoaded;
  bool get homesFromCache => _homesFromCache;

  /// Ev listesi yükleme hatası (kullanıcıya gösterilebilir). `null` = hata yok.
  String? get homesError => _homesError;

  /// Aktif evin uç noktaları (bekleyen komutların iyimser değerleriyle birlikte).
  List<EndpointModel> get cloudEndpoints => _endpointView ??= _computeEndpointView();
  bool get endpointsLoading => _endpointsLoading;
  bool get endpointsLoaded => _endpointsLoaded;
  String? get endpointsError => _endpointsError;
  List<DeviceInfo> get devices => _devices;

  /// Birleşik görünüm: aydınlatma / priz / darbe öğeleri (panjurlar hariç), moda göre. Girdiler değişmedikçe AYNI
  /// (salt-okunur) liste döner (PF-20): her röle kartı seçicisi tüm listeyi gezer, N kart x N uç noktada eskiden
  /// her erişim listeyi baştan türetirdi.
  List<RelayItem> get relayItems {
    final cached = _relayItemsMemo;
    if (cached != null && _relayItemsGen == _viewGen && _relayItemsMode == _mode) return cached;
    final built = _mode == AppMode.cloud
        ? relayItemsFromEndpoints(cloudEndpoints).where((r) => !r.isActuator).toList(growable: false)
        : (status?.controllableRelays ?? const <RelayItem>[]);
    final view = UnmodifiableListView<RelayItem>(built);
    _relayItemsMemo = view;
    _relayItemsGen = _viewGen;
    _relayItemsMode = _mode;
    return view;
  }

  /// Birleşik görünüm: **gerçek** panjurlar (benzersiz, `pair` 1 tabanlı), moda göre. Girdiler değişmedikçe AYNI
  /// (salt-okunur) liste döner (PF-20).
  List<ShutterItem> get shutterItems {
    final cached = _shutterItemsMemo;
    if (cached != null && _shutterItemsGen == _viewGen && _shutterItemsMode == _mode) return cached;
    final built = _mode == AppMode.cloud
        ? shutterItemsFromEndpoints(cloudEndpoints, _runtimeView())
        : (status?.shutters ?? const <ShutterItem>[]);
    final view = UnmodifiableListView<ShutterItem>(built);
    _shutterItemsMemo = view;
    _shutterItemsGen = _viewGen;
    _shutterItemsMode = _mode;
    return view;
  }

  /// Cihazın bildirdiği LAN IP'si (MQTT `state.ip`); doğrudan mod için öneri.
  String? get lastKnownDeviceIp => _lastDeviceIp;

  String? get servicePin => _servicePin;
  DateTime? get servicePinExpiry => _servicePinExpiry;

  /// Rol → yetki (CONTRACTS §1.4). UI kapıları ve metot denetimleri bunu kullanır. Kullanıcı, aktif ev ve misafir
  /// penceresinin O ANKİ sonucu (süresi doldu mu / başladı mı) değişmedikçe AYNI nesne döner (PF-20); pencere zamanla
  /// başlayınca/bitince her erişimde ucuzca yeniden hesaplanan [HomeModel.isGuestExpiredAt] anahtara girer.
  Capabilities get capabilities {
    final user = _currentUser;
    if (user == null || _authStatus != AuthStatus.authenticated) {
      return _anonymousLocalKey ? const Capabilities.localKeyHolder() : const Capabilities.none();
    }
    final home = _activeHome;
    final now = clock.now();
    final guestExpired = home != null && home.isGuestRole && home.isGuestExpiredAt(now);
    final cached = _capsMemo;
    if (cached != null &&
        identical(_capsUser, user) &&
        identical(_capsHome, home) &&
        _capsGuestExpired == guestExpired) {
      return cached;
    }
    DateTime? validUntil = home?.guestValidUntil;
    if (guestExpired) validUntil = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    final built = Capabilities(
      globalRole: user.role,
      homeRole: home?.role,
      guestValidUntil: validUntil,
      guestValidFrom: home?.guestValidFrom,
      now: now,
      hasActiveHome: home != null,
    );
    _capsMemo = built;
    _capsUser = user;
    _capsHome = home;
    _capsGuestExpired = guestExpired;
    return built;
  }

  bool get _anonymousLocalKey =>
      _currentUser == null &&
      _mode == AppMode.direct &&
      (directApi.localKey?.isNotEmpty ?? false);

  /// Küresel rol kısayolları (yetki için [capabilities] kullanın).
  bool get isSuperUser => _currentUser?.isSuperUser ?? false;
  bool get isServiceUser => _currentUser?.isServiceUser ?? false;
  bool get isServiceSession => cloudApi.isServiceSession || (_currentUser?.isServiceSession ?? false);
  bool get isServiceMode => isServiceUser || isServiceSession;
  bool get isServiceManagerOrSuper => isSuperUser || isServiceUser;

  /// Aktif evdeki rol kısayolları (**ev bazlı**).
  bool get isOwner => _activeHome?.homeRole == HomeRole.owner;
  bool get isGuest => _activeHome?.homeRole == HomeRole.guest;
  bool get isGuestExpired => capabilities.isGuestExpired;

  /// Aktif servis PIN oturumu (varsa) ve kalan süresi.
  ServiceSessionInfo? get serviceSession => cloudApi.serviceSession;
  Duration? get serviceSessionRemaining => cloudApi.serviceSession?.remaining(clock.now());

  /// Çocuk kilidi (bekleyen komutun iyimser değeriyle birlikte).
  bool get childLock => childLockStatus == ChildLockStatus.locked;

  /// Çocuk kilidi durumu (bekleyen komutun iyimser hedefi dahil). Bilinmeyen = [ChildLockStatus.unknown].
  ChildLockStatus get childLockStatus {
    final pending = _pipeline.pendingFor('childLock')?.target;
    if (pending is bool) return pending ? ChildLockStatus.locked : ChildLockStatus.unlocked;
    return _baseChildLockStatus();
  }

  ChildLockStatus _baseChildLockStatus() {
    if (_childLockByUid.isNotEmpty) {
      final values = _childLockByUid.values.toSet();
      if (values.length > 1) return ChildLockStatus.mixed;
      return values.single ? ChildLockStatus.locked : ChildLockStatus.unlocked;
    }
    final rest = _childLockRest;
    if (rest == null) return ChildLockStatus.unknown;
    return rest ? ChildLockStatus.locked : ChildLockStatus.unlocked;
  }

  /// Komut iletildi ama cihaz henüz doğrulamadı ("uygulanıyor…"). REST `delivered:true`
  /// "uygulandı" demek değildir; uygulandığını cihazın `state.child_lock` bildirimi gösterir.
  bool get childLockPending => _pipeline.isPending('childLock');

  /// Görünen değer güncel olmayabilir: cihaz çevrimdışı ya da canlı kanal kopuk ("son bilinen").
  bool get childLockStale {
    if (_baseChildLockStatus() == ChildLockStatus.unknown) return false;
    if (_mode == AppMode.direct) return _connState == ConnectionStateEnum.offline;
    return _presence == DevicePresence.offline || (!brokerConnected && _childLockByUid.isNotEmpty);
  }

  /// Görünen değerin en son alındığı zaman (bilinmiyorsa `null`).
  DateTime? get childLockUpdatedAt => _childLockUpdatedAt;

  /// Sunucuda kayıtlı en son kilit **isteği** (`requested`); hiç istek yoksa / bilinmiyorsa `null`.
  /// Gerçek durum [childLockStatus]'tur (cihaz bildirimi); bu yalnızca niyettir.
  bool? get childLockRequested => _childLockRequested;

  /// Sunucudaki istek, cihazın bildirdiği durumdan farklı: istek henüz cihazlara uygulanmadı (ör. pano
  /// çevrimdışı) ve çevrimiçi olunca uygulanacak. Durum bilinmiyorsa `false` (varsayım yapılmaz).
  bool get childLockAwaitingDevices {
    final requested = _childLockRequested;
    if (requested == null) return false;
    switch (_baseChildLockStatus()) {
      case ChildLockStatus.locked:
        return !requested;
      case ChildLockStatus.unlocked:
        return requested;
      case ChildLockStatus.mixed:
        return true;
      case ChildLockStatus.unknown:
        return false;
    }
  }

  /// Çocuk kilidi komutunun iletilemediği çevrimdışı panolar (son REST yanıtından): kilit bu panolarda
  /// uygulanmamış olabilir. Çok panolu evlerde arayüz "bazı panolar çevrimdışı" uyarısı gösterir.
  List<String> get childLockOfflineDevices =>
      _offlineDevicesView.of(_childLockOfflineDevices, List<String>.unmodifiable);

  Map<String, dynamic>? get peaceNotificationData => _peaceNotificationData;

  /// [peaceNotificationData]'nın tipli görünümü (`enabled`/`peace_notification_enabled` ve
  /// `time`/`peace_notification_time` anahtar adlarının ikisini de okur).
  PeaceNotificationSettings? get peaceSettings {
    final data = _peaceNotificationData;
    return data == null ? null : PeaceNotificationSettings.fromJson(data);
  }

  List<ScheduledRule> get scheduledRules => _rulesView.of(_scheduledRules, List<ScheduledRule>.unmodifiable);
  bool get scheduledRulesLoading => _scheduledRulesLoading;
  String? get scheduledRulesError => _scheduledRulesError;

  bool get isBiometricEnabled => _isBiometricEnabled;
  bool get isBiometricSupported => _isBiometricSupported;
  String get biometricLabel => _biometricLabel;
  bool get shouldPromptBiometrics => _shouldPromptBiometrics;
  bool get biometricChecking => _biometricChecking;
  bool get biometricFailed => _biometricFailed;

  List<InventoryDeviceModel> get inventoryDevices =>
      _inventoryView.of(_inventoryDevices, List<InventoryDeviceModel>.unmodifiable);
  Map<String, int> get inventoryStats => _inventoryStatsView.of(_inventoryStats, Map<String, int>.unmodifiable);
  bool get inventoryLoading => _inventoryLoading;
  String? get inventoryError => _inventoryError;
  List<Map<String, dynamic>> get serviceSubscribers =>
      _subscribersView.of(_serviceSubscribers, List<Map<String, dynamic>>.unmodifiable);
  bool get subscribersLoading => _subscribersLoading;
  String? get subscribersError => _subscribersError;

  /// Oturum sona erdiğinde giriş ekranında gösterilecek tek seferlik mesaj.
  String? get sessionNotice => _sessionNotice;

  /// Güvenli depolama hatası (oturum cihaza kaydedilemedi vb.). `null` = hata yok.
  String? get storageError => _storageError;

  /// Doğrudan moddaki son hata (anahtar geçersiz, adres yok ...).
  String? get directError => _directError;

  /// LAN yoklaması anahtar sorunu yüzünden DURDU (`401`, `403 unprovisioned`, anahtarsız kısıtlı özet):
  /// kullanıcı anahtarı girene / "Yeniden dene"ye basana ya da ön plana dönene kadar cihaza istek atılmaz
  /// (bayat anahtarla yoklamak cihazın hatalı-deneme kilidini (423) tetikler). Bağlantı `connected` kalır.
  bool get directNeedsKey => _pollHalted;

  /// Cihaz çok sayıda hatalı denemeyle KİLİTLENDİ (`423`): yoklama bu ana kadar bekler (`Retry-After` + 1 sn);
  /// kilit yoksa `null`. Bağlantı `connected` kalır, `status` yoktur ([directError] mesajı gösterir).
  DateTime? get directBlockedUntil => _pollNotBefore;

  String get selectedDeviceUuid => _selectedDeviceUuid;
  String get selectedDeviceIp => _selectedDeviceIp;
  String get selectedDeviceName =>
      _selectedDeviceName ?? (_selectedDeviceUuid.isEmpty ? '' : _selectedDeviceUuid);
  bool get hasSelectedDevice => _selectedDeviceUuid.isNotEmpty;

  /// Doğrudan mod için yerel cihaz anahtarı kayıtlı mı.
  bool get hasLocalKey => directApi.localKey?.isNotEmpty ?? false;

  int get openLightsCount {
    if (_mode == AppMode.cloud) {
      return cloudEndpoints.where((e) => e.isLight && !e.isActuator && e.currentState).length;
    }
    return status?.controllableRelays.where((r) => r.isLight && r.state).length ?? 0;
  }

  ThemeMode get themeMode => _themeMode;

  // ---------------------------------------------------------------------------
  // Yaşam döngüsü: başlatma / kapatma
  // ---------------------------------------------------------------------------

  @override
  void notifyListeners() {
    if (_isDisposed) return;
    super.notifyListeners();
  }

  void _log(String message) {
    if (kDebugMode) debugPrint('[AutomationState] $message');
  }

  Future<void> _init() async {
    try {
      await _initInner();
    } catch (e) {
      _log('Başlatma hatası: ${e.runtimeType}');
      if (_authStatus == AuthStatus.checking && !_awaitingUnlock) {
        _authStatus = AuthStatus.unauthenticated;
      }
    } finally {
      notifyListeners();
    }
  }

  Future<void> _initInner() async {
    final epoch = _sessionEpoch; // çıkış / yeni giriş sürerken geç dönen okuma eski oturumu kurmasın (PF-29)
    final prefs = await SharedPreferences.getInstance();
    _installId = _loadInstallId(prefs);

    // Eski sürümlerin SharedPreferences'a yazdığı belirteç yedeği silinir (artık yalnızca SecureStorage).
    if (prefs.containsKey(_prefsLegacyToken)) await prefs.remove(_prefsLegacyToken);

    _host = prefs.getString(_prefsHost) ?? '';
    directApi.updateHost(_host);
    _loadLanDevicePrefs(prefs);

    final savedTheme = prefs.getString(_prefsTheme);
    _themeMode = savedTheme == 'light'
        ? ThemeMode.light
        : (savedTheme == 'system' ? ThemeMode.system : ThemeMode.dark);

    // Bulut-öncelikli: kayıt yoksa bulut.
    _mode = prefs.getString(_prefsMode) == 'direct' ? AppMode.direct : AppMode.cloud;

    _selectedDeviceUuid = prefs.getString(_prefsSvcUuid) ?? '';
    _selectedDeviceIp = prefs.getString(_prefsSvcIp) ?? '';
    _selectedDeviceName = prefs.getString(_prefsSvcName);

    // Beş bağımsız depo okuması EŞZAMANLI (PF-13); her biri kendi süre sınırıyla (6 sn) değer ya da hata kaydına
    // döner. Belirteçler: yalnızca SecureStorage. Okuma hatası "oturum yok" ile karıştırılmaz.
    final (tokenRead, refreshRead, userRead, serviceRead, flagRead) = await (
      _readStore<String?>(secureStorage.getAuthToken),
      _readStore<String?>(secureStorage.getRefreshToken),
      _readStore<UserModel?>(secureStorage.getUser),
      _readStore<ServiceSessionInfo?>(secureStorage.getServiceSession),
      _readStore<bool>(secureStorage.isBiometricEnabled),
    ).wait;
    if (_isStaleSession(epoch)) return;

    // Dört oturum okumasından biri hatalıysa: storageError + oturum yok (yarım oturum kurulmaz; saklı
    // belirteçler SİLİNMEZ, sonraki açılışta okunabilir).
    final sessionError = tokenRead.error ?? refreshRead.error ?? userRead.error ?? serviceRead.error;
    if (sessionError != null) _storageError = sessionError.message;
    final String? token = sessionError == null ? tokenRead.value : null;
    final String? refresh = sessionError == null ? refreshRead.value : null;
    final UserModel? storedUser = sessionError == null ? userRead.value : null;
    final ServiceSessionInfo? serviceInfo = sessionError == null ? serviceRead.value : null;
    final flagError = flagRead.error;
    if (flagError != null) _storageError ??= flagError.message;

    final hasRefresh = refresh != null && refresh.isNotEmpty;
    final hasTokens = (token != null && token.isNotEmpty) || hasRefresh;

    // Biyometrik destek sondası (platform kanalı, ≤ 3 sn): yalnız korunacak bir oturum varken ya da tercih
    // okunamadığında (fail-closed karar için) çalışır; oturumsuz açılış platform kanalına gitmez (PF-13).
    //
    // İlk kullanım istemi (WP-BIO2): biyometrik kilidi KAPALI (tercih okunabildi ve false) bir kullanıcı oturumu
    // geri yüklenirken "istem gösterildi" kaydı sondayla EŞZAMANLI okunur (takılmada süreler toplanmaz; beş oturum
    // okuması bittikten sonra başlar). Servis oturumunda ve kilit açıkken okunmaz (istem yok). Karar
    // `_startSession`'dan ÖNCE verilir: DashboardPage `shouldPromptBiometrics`'ı ilk karede okur.
    var probeTimedOut = false;
    Future<({bool? value, SecureStorageException? error})>? promptShownRead;
    if (hasTokens || flagError != null) {
      final lockOff = flagError == null && !(flagRead.value ?? false);
      if (hasTokens && serviceInfo == null && lockOff) {
        promptShownRead = _readStore<bool>(secureStorage.isBiometricPromptShown);
      }
      _isBiometricSupported = await biometricService.isBiometricSupported();
      probeTimedOut = biometricService.lastSupportProbeTimedOut;
      if (_isBiometricSupported) _biometricLabel = await biometricService.getBiometricLabel();
      if (_isStaleSession(epoch)) return;
    }
    // Kilit: tercih AÇIK (okunamazsa AÇIK varsayılır: fail-closed) ve cihaz destekliyor — ya da destek sondası
    // yanıt vermedi (kilidi atlamak yerine kilitli kal; ekran "yeniden dene / şifre ile giriş" sunar).
    final lockCapable = _isBiometricSupported || probeTimedOut;
    _isBiometricEnabled = flagError == null ? (flagRead.value ?? false) : lockCapable;
    final lockRequired = _isBiometricEnabled && lockCapable;

    if (!hasTokens) {
      _authStatus = AuthStatus.unauthenticated;
      await _afterInitWithoutSession();
      return;
    }

    // Servis oturumu: süresi dolmamışsa geri yükle, dolduysa sil.
    if (serviceInfo != null) {
      if (serviceInfo.isExpiredAt(clock.now()) || token == null) {
        await _wipeStorageQuietly();
        if (_isStaleSession(epoch)) return;
        _authStatus = AuthStatus.unauthenticated;
        await _afterInitWithoutSession();
        return;
      }
      cloudApi.restoreServiceSession(accessToken: token, info: serviceInfo);
      _currentUser = UserModel(
        id: '',
        email: '',
        fullName: serviceInfo.technicianName.isEmpty ? 'Servis Teknisyeni' : serviceInfo.technicianName,
        role: 'service_session',
      );
    } else {
      cloudApi.setAuthToken(token);
      cloudApi.setRefreshToken(refresh);
      _currentUser = storedUser ?? _userFromJwt(token ?? refresh);
      if (_currentUser == null) {
        if (!hasRefresh) {
          // Kullanıcı bilinmiyor, belirteçten türetilemiyor ve yenileme belirteci de yok: bozuk kayıt, temiz başla.
          cloudApi.clearSession();
          await _wipeStorageQuietly();
          if (_isStaleSession(epoch)) return;
          _authStatus = AuthStatus.unauthenticated;
          await _afterInitWithoutSession();
          return;
        }
        // Kullanıcı kaydı yok/bozuk ama yenileme belirteci var (WP-BIO2): oturum SİLİNMEZ (belirteç sunucuda hâlâ
        // geçerli olabilir; silmek kullanıcıyı gereksiz yere giriş ekranına düşürürdü). Çözülemeyen erişim belirteci
        // kullanılmaz: `_startSession` önce yeniler ve kullanıcıyı yenilenen JWT'den türetir. Sunucu reddederse oturum
        // olayıyla kapanır; ağ hatasında belirteçler kalır (sonraki açılış yeniden dener).
        cloudApi.setAuthToken(null);
      }
    }

    _pendingRestore = true;
    if (lockRequired) {
      // Kilitliyken ağ / MQTT BAŞLAMAZ: önce biyometrik doğrulama.
      _awaitingUnlock = true;
      _authStatus = AuthStatus.checking;
      notifyListeners();
      await _unlockWithBiometrics();
      return;
    }
    if (promptShownRead != null) {
      // İlk kullanım istemi kararı (geri yükleme; giriş yolundaki `_handleAuthSuccess` ile aynı kural). Fail-safe:
      // kayıt okunamadıysa ya da cihaz desteklemiyorsa (sonda zaman aşımı dahil) istem YOK. Karar bir kez verilir:
      // "Daha Sonra" / "Etkinleştir" kaydı yazar (`dismissBiometricPrompt` / `enableBiometricWithVerification`).
      final promptRead = await promptShownRead;
      if (_isStaleSession(epoch)) return;
      _shouldPromptBiometrics = _isBiometricSupported && promptRead.error == null && promptRead.value != true;
    }
    await _startSession();
  }

  /// Oturum nesli [epoch]'tan farklılaştı (çıkış / yeni giriş) ya da durum kapatıldı: bekleyen eski iş sonucunu
  /// UYGULAMAMALI (geç dönen okuma / doğrulama eski oturumu yeniden kurmasın).
  bool _isStaleSession(int epoch) => _isDisposed || epoch != _sessionEpoch;

  /// Tek depo okuması: [SecureStorageException]'ı (hata / 6 sn zaman aşımı) fırlatmaz, kayda çevirir; paralel
  /// okumalarda biri düşünce diğerlerinin sonucu korunur.
  Future<({T? value, SecureStorageException? error})> _readStore<T>(Future<T> Function() read) async {
    try {
      return (value: await read(), error: null);
    } on SecureStorageException catch (e) {
      return (value: null, error: e);
    }
  }

  Future<void> _afterInitWithoutSession() async {
    if (_mode == AppMode.direct) {
      await _prepareDirect();
      _startPolling();
      await refresh();
    }
  }

  String _loadInstallId(SharedPreferences prefs) {
    final existing = prefs.getString(_prefsInstallId);
    if (existing != null && existing.length >= 16) return existing;
    final random = Random.secure();
    final id = List<String>.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    prefs.setString(_prefsInstallId, id);
    return id;
  }

  UserModel? _userFromJwt(String? token) {
    if (token == null) return null;
    final parts = token.split('.');
    if (parts.length != 3) return null;
    try {
      final claims = asMap(jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))));
      final id = asNonEmptyString(claims?['sub']);
      if (claims == null || id == null) return null;
      return UserModel(id: id, email: '', fullName: '', role: asNonEmptyString(claims['role']) ?? 'user');
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _lifecycleListener?.dispose();
    _cancelAllTimers();
    _mqttLinkSub?.cancel();
    _mqttStateSub?.cancel();
    _mqttStatusSub?.cancel();
    _failureSub?.cancel();
    _pipeline.dispose();
    _sessionEvents.close();
    if (_ownsMqtt) {
      mqttService.dispose();
    } else {
      unawaited(mqttService.stop());
    }
    if (_ownsCloudApi) cloudApi.dispose();
    if (_ownsDirectApi) directApi.dispose();
    super.dispose();
  }

  void _cancelAllTimers() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _reconcileTimer?.cancel();
    _reconcileTimer = null;
    _servicePinTimer?.cancel();
    _servicePinTimer = null;
    _serviceSessionTimer?.cancel();
    _serviceSessionTimer = null;
    _guestExpiryTimer?.cancel();
    _guestExpiryTimer = null;
    _loadRetryTimer?.cancel();
    _loadRetryTimer = null;
    _resetLayoutRefresh();
  }

  // ---------------------------------------------------------------------------
  // Depolama kuyruğu (sıralı yazma; çıkıştan sonra eski oturum yazamaz)
  // ---------------------------------------------------------------------------

  /// Depolama işlemlerini sıraya alır. [epoch] verilirse ve bu arada oturum değiştiyse işlem
  /// **çalıştırılmaz** (çıkıştan sonra gecikmeli token yazımı olmaz). Hatalar yutulmaz:
  /// [storageError] olarak yüzeye çıkar. [rethrowErrors] `true` ise hata ayrıca çağırana iletilir (uyelik-3: API
  /// istemcisi yazımın başarısız olduğunu bilmelidir); kuyruk bundan etkilenmez (sonraki işlemler sürer).
  Future<void> _enqueueStorage(Future<void> Function() operation, {int? epoch, bool rethrowErrors = false}) {
    final run = _storageQueue.then((_) async {
      if (epoch != null && epoch != _sessionEpoch) return;
      try {
        await operation();
      } on SecureStorageException catch (e) {
        _storageError = e.message;
        notifyListeners();
        if (rethrowErrors) rethrow;
      } catch (_) {
        _storageError = 'Güvenli depolama kullanılamıyor.';
        notifyListeners();
        if (rethrowErrors) rethrow;
      }
    });
    _storageQueue = run.catchError((Object _) {}); // kuyruk kopmasın
    return run;
  }

  void clearStorageError() {
    if (_storageError == null) return;
    _storageError = null;
    notifyListeners();
  }

  Future<void> _onTokenRefreshed(String accessToken, String? refreshToken) {
    final epoch = _sessionEpoch;
    return _enqueueStorage(() async {
      // Önce YENİ yenileme belirteci, sonra erişim belirteci (WP-BIO2). Sunucu her yenilemede yenisini verir
      // (rotasyon) ve eskisinin yeniden kullanımını "çalıntı" sayıp tüm oturum ailesini iptal eder: iki yazım
      // arasında uygulama ölürse "eski yenileme + yeni erişim" kalır ve ilk yenilemede oturum zorla kapanırdı.
      // Ters artık ("yeni yenileme + eski erişim") zararsızdır: ilk 401 sessizce yeniler.
      if (refreshToken != null && refreshToken.isNotEmpty) {
        await secureStorage.saveRefreshToken(refreshToken);
      }
      await secureStorage.saveAuthToken(accessToken);
    }, epoch: epoch, rethrowErrors: true); // yazım hatası istemciye bildirilir (uyelik-3)
  }

  Future<void> _wipeStorageQuietly() => _enqueueStorage(() => secureStorage.clearAll());

  Future<void> _clearUserPrefs() async {
    // Ev başına LAN panosu / adres ve girişsiz pano kimliği önceki kullanıcıya aittir (kullanim-1/3, bireysel-5).
    _lanDeviceByHome.clear();
    _anonLanDevice = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsLegacyToken);
      await prefs.remove(_prefsMode);
      await prefs.remove(_prefsHost);
      await prefs.remove(_prefsSvcUuid);
      await prefs.remove(_prefsSvcIp);
      await prefs.remove(_prefsSvcName);
      await prefs.remove(_prefsActiveHome);
      await prefs.remove(_prefsAnonLanDevice);
      for (final key in prefs.getKeys().toList()) {
        if (key.startsWith(_prefsLanDevicePrefix) ||
            key.startsWith(_prefsHostPrefix) ||
            key.startsWith(_prefsKeyPrefetchPrefix)) {
          await prefs.remove(key);
        }
      }
    } catch (_) {}
  }

  /// `lan_device_<ev>` ve `saved_lan_device_uuid` tercihlerini belleğe alır (açılışta).
  void _loadLanDevicePrefs(SharedPreferences prefs) {
    _lanDeviceByHome.clear();
    try {
      for (final key in prefs.getKeys()) {
        if (!key.startsWith(_prefsLanDevicePrefix)) continue;
        final uid = QrClaimParser.normalizeUid(prefs.getString(key));
        if (uid != null) _lanDeviceByHome[key.substring(_prefsLanDevicePrefix.length)] = uid;
      }
      _anonLanDevice = QrClaimParser.normalizeUid(prefs.getString(_prefsAnonLanDevice));
    } catch (_) {}
  }

  Future<void> _savePref(String key, String value) async {
    try {
      await (await SharedPreferences.getInstance()).setString(key, value);
    } catch (_) {}
  }

  /// Aktif ev için LAN panosunu hatırlar (kullanim-1). Servis personelinin elle seçtiği cihaz ([selectDevice]) eve
  /// yazılmaz: o seçim aktif evden bağımsızdır.
  void _rememberLanDevice(String uuid) {
    final home = _activeHome;
    if (home == null || _selectedDeviceUuid.isNotEmpty) return;
    if (_lanDeviceByHome[home.id] == uuid) return;
    _lanDeviceByHome[home.id] = uuid;
    unawaited(_savePref('$_prefsLanDevicePrefix${home.id}', uuid));
  }

  /// Aktif evin doğrudan kip adresi (kullanim-3): `saved_esp_host_<ev>`, yoksa genel `saved_esp_host`.
  Future<void> _loadHomeHost(String homeId) async {
    String? host;
    try {
      final prefs = await SharedPreferences.getInstance();
      host = prefs.getString('$_prefsHostPrefix$homeId') ?? prefs.getString(_prefsHost);
    } catch (_) {}
    _host = host ?? '';
    directApi.updateHost(_host);
  }

  // ---------------------------------------------------------------------------
  // Oturum sıfırlama (tek merkez) ve oturum olayları
  // ---------------------------------------------------------------------------

  /// Kullanıcı kapsamlı **tüm** alanları, abonelikleri, zamanlayıcıları, servis PIN'ini ve
  /// bekleyen komutları sıfırlar. [clearApiSession] `false` ise API istemcisinin (yeni açılan)
  /// oturumu korunur (giriş sırasında önceki kullanıcının artıklarını silmek için).
  void _resetSessionState({bool clearApiSession = true}) {
    _sessionEpoch++;
    _homeEpoch++;
    _cancelAllTimers();
    _pipeline.cancelAll();
    unawaited(mqttService.stop());
    _mqttLink = MqttLinkState.disconnected;

    _currentUser = null;
    _homes = const [];
    _activeHome = null;
    _homesLoading = false;
    _homesLoaded = false;
    _homesFromCache = false;
    _homesError = null;
    _homesFlight = null;
    _homesCacheDigest = null;
    _resetHomeScopedState();

    _inventoryDevices = const [];
    _inventoryStats = <String, int>{'total': 0, 'in_stock': 0, 'claimed': 0, 'suspended': 0};
    _inventoryLoading = false;
    _inventoryError = null;
    _serviceSubscribers = const [];
    _subscribersLoading = false;
    _subscribersError = null;

    _isBiometricEnabled = false;
    _shouldPromptBiometrics = false;
    _biometricChecking = false;
    _biometricFailed = false;
    _pendingRestore = false;
    _awaitingUnlock = false;
    _retryFlight = null; // eski oturumun "yeniden dene" uçuşu yeni oturumun denemesini yutmasın

    _selectedDeviceUuid = '';
    _selectedDeviceIp = '';
    _selectedDeviceName = null;
    _host = '';
    directApi.updateHost('');
    directApi.localKey = null;
    _directError = null;
    _directFailures = 0;
    _localKeyRefreshTried = false;
    _resumeDirectPolling();
    _status = null;
    _invalidateViews();
    _connState = ConnectionStateEnum.connecting;
    _mode = AppMode.cloud;
    _inBackground = false;
    _backgroundedAt = null;

    if (clearApiSession) cloudApi.clearSession();
  }

  /// Ev kapsamlı **tüm** önbellekleri sıfırlar (ev değişiminde ve oturum sıfırlamada).
  void _resetHomeScopedState() {
    _pipeline.cancelAll();
    _cloudEndpoints = const [];
    _invalidateViews();
    _endpointsLoading = false;
    _endpointsLoaded = false;
    _endpointsError = null;
    _cloudRefreshFlight = null;
    _devices = const [];
    _presence = DevicePresence.unknown;
    _shutterRuntime.clear();
    _safetyByUid.clear();
    _armClock.clear();
    _safetyNames.clear();
    _safetyNamesInFlight.clear();
    _safetyNamesRetryAt.clear();
    _lastLiveSnapshot = null;
    _lastLiveSnapshotAt = null;
    _lastLiveStateAt = null;
    _lastDeviceIp = null;
    _realtimeEpoch = -1;
    _resetChildLockKnowledge();
    _peaceNotificationData = null;
    _scheduledRules = const [];
    _scheduledRulesLoading = false;
    _scheduledRulesError = null;
    _servicePin = null;
    _servicePinExpiry = null;
    _servicePinTimer?.cancel();
    _servicePinTimer = null;
    _reconcileTimer?.cancel();
    _reconcileTimer = null;
    _guestExpiryTimer?.cancel();
    _guestExpiryTimer = null;
    _loadRetryTimer?.cancel();
    _loadRetryTimer = null;
    _loadRetryCount = 0;
    _resetLayoutRefresh(); // eski evin yerleşim izlemesi ve bekleyen yenilemesi yeni eve taşınmaz
    _devicesFailed = false;
    _status = null;
    _invalidateViews();
    _directFailures = 0;
    _resumeDirectPolling();
  }

  /// Çocuk kilidi bilgisini "bilinmiyor"a döndürür (ev/mod/oturum değişiminde).
  void _resetChildLockKnowledge() {
    _childLockByUid.clear();
    _childLockRest = null;
    _childLockRequested = null;
    _childLockOfflineDevices = const <String>[];
    _childLockUpdatedAt = null;
    _childLockDeviceAt = null;
  }

  void _handleSessionExpired(SessionEndReason reason) {
    if (_isDisposed || _authStatus == AuthStatus.unauthenticated) return;
    // API istemcisi kalıcı reddi kendisi temizler; yerel süre dolumunda (servis oturumu zamanlayıcısı)
    // belirteç hâlâ bellekte olabilir: süresi dolmuş belirteçle istek gitmesin.
    if (cloudApi.hasSession) cloudApi.clearSession();
    _resetSessionState(clearApiSession: false);
    _authStatus = AuthStatus.unauthenticated;
    _sessionNotice = reason == SessionEndReason.serviceSessionExpired
        ? 'Servis oturumunuzun süresi doldu. Yeni bir servis PIN\'i gerekir.'
        : 'Oturumunuz sona erdi. Lütfen tekrar giriş yapın.';
    if (!_sessionEvents.isClosed) _sessionEvents.add(SessionExpiredEvent(reason));
    unawaited(_enqueueStorage(() => secureStorage.clearAll()));
    unawaited(_clearUserPrefs());
    notifyListeners();
  }

  void _handleGuestExpired(String? homeId) {
    if (_isDisposed) return;
    final id = homeId ?? _activeHome?.id;
    if (id == null) return;
    final home = homeById(id);
    // Süresi dolan evin yerel verisi ve canlı bağlantısı kapatılır.
    if (_activeHome?.id == id) {
      _homeEpoch++;
      unawaited(mqttService.stop());
      _mqttLink = MqttLinkState.disconnected;
      _resetHomeScopedState();
      _activeHome = (home ?? _activeHome)!
          .copyWith(serverMarkedExpired: true, accessState: HomeAccessState.expired);
    }
    _homes = [
      for (final h in _homes)
        h.id == id ? h.copyWith(serverMarkedExpired: true, accessState: HomeAccessState.expired) : h,
    ];
    if (!_sessionEvents.isClosed) {
      _sessionEvents.add(GuestExpiredEvent(homeId: id, homeName: home?.name));
    }
    notifyListeners();
    // Sunucudaki gerçek durumla ev listesini tazele.
    unawaited(fetchHomes(autoSelect: false));
  }

  /// Cihaz çevrimdışı olduğu için geri alınan komut, cihazın çevrimdışı olduğunu da kanıtlar.
  void _onCommandFailure(CommandFailure failure) {
    if (failure.reason == CommandFailureReason.offline && _mode == AppMode.cloud) {
      _presence = DevicePresence.offline;
      notifyListeners();
    }
    // İletildi ama cihaz doğrulamadı ya da yanıt alınamadı (ağ / zaman aşımı; kullanim-9): komut uygulanmış olabilir;
    // gerçek durumu hemen yeniden oku (bulutta tek anlık görüntü, doğrudan kipte LAN yoklaması).
    if ((failure.reason == CommandFailureReason.timeout || failure.reason == CommandFailureReason.network) &&
        !_inBackground &&
        (isAuthenticated || _mode == AppMode.direct)) {
      unawaited(refresh(silent: true));
    }
  }

  void _handleForbidden(String? homeId) {
    if (_isDisposed || !isAuthenticated) return;
    final now = clock.now();
    final last = _lastForbiddenRefresh;
    if (last != null && now.difference(last) < const Duration(seconds: 30)) return;
    _lastForbiddenRefresh = now;
    // Rol değişmiş olabilir: ev listesini (ve rolleri) yenile.
    unawaited(fetchHomes(autoSelect: false));
  }

  void clearSessionNotice() {
    if (_sessionNotice == null) return;
    _sessionNotice = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Uygulama yaşam döngüsü (AppLifecycleListener)
  // ---------------------------------------------------------------------------

  void _attachLifecycle() {
    try {
      _lifecycleListener = AppLifecycleListener(onStateChange: handleLifecycleState);
    } catch (_) {
      // Widget bağlayıcısı yok (saf Dart testi): yaşam döngüsü dinlenmez.
    }
  }

  /// Uygulama yaşam döngüsü geçişleri. Arka planda MQTT + yoklama durur; ön plana dönüşte tek
  /// snapshot alınır ve gerekirse biyometrik yeniden kilit uygulanır.
  void handleLifecycleState(AppLifecycleState state) {
    if (_isDisposed || _biometricChecking) return; // biyometrik istem uygulamayı duraklatabilir
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _enterBackground();
      case AppLifecycleState.resumed:
        _enterForeground();
      case AppLifecycleState.inactive:
        break;
    }
  }

  void _enterBackground() {
    if (_inBackground) return;
    _inBackground = true;
    _backgroundedAt = clock.now();
    _pollTimer?.cancel();
    _pollTimer = null;
    _reconcileTimer?.cancel();
    _reconcileTimer = null;
    _loadRetryTimer?.cancel(); // arka planda ağ çağrısı yok; ön plana dönüş zaten tek snapshot alır
    _loadRetryTimer = null;
    _resetLayoutRefresh(); // aynı gerekçe: ön plana dönüşteki snapshot listeyi zaten yeniler
    _pipeline.cancelAll();
    unawaited(mqttService.stop());
    _mqttLink = MqttLinkState.disconnected;
    notifyListeners();
  }

  void _enterForeground() {
    if (!_inBackground) return;
    _inBackground = false;
    final away = _backgroundedAt == null ? Duration.zero : clock.now().difference(_backgroundedAt!);
    _backgroundedAt = null;

    if (isAuthenticated && _isBiometricEnabled && _isBiometricSupported && away >= _biometricRelockAfter) {
      // Yeniden kilit: doğrulanana kadar ağ/MQTT başlamaz.
      _awaitingUnlock = true;
      _pendingRestore = false;
      _authStatus = AuthStatus.checking;
      _biometricFailed = false;
      notifyListeners();
      unawaited(_unlockWithBiometrics());
      return;
    }
    if (_authStatus == AuthStatus.checking && _awaitingUnlock) return; // kilitli kal
    unawaited(_resumeSession());
  }

  /// Ön plana dönüş: roller + tek snapshot + canlı bağlantıyı yeniden başlat.
  Future<void> _resumeSession() async {
    if (_isDisposed || _inBackground) return;
    if (_mode == AppMode.direct) {
      _startPolling();
      await refresh(silent: true);
      return;
    }
    if (!isAuthenticated) return;
    // Ev listesi (roller) + tek snapshot + canlı kanal EŞZAMANLI (PF-03): ardışık beklemek 3 tur x 10 sn olabilir. Servis
    // PIN oturumu da kapsanır (kullanim-6): ev listesi orada erken döner, canlı kanal (MQTT) yeniden kurulur.
    await Future.wait<void>(<Future<void>>[
      fetchHomes(autoSelect: false),
      refresh(silent: true),
      _startRealtime(),
    ]);
  }

  @visibleForTesting
  bool get isInBackground => _inBackground;

  // ---------------------------------------------------------------------------
  // Biyometrik güvenlik
  // ---------------------------------------------------------------------------

  /// Etkileşimli biyometrik istemin üst sınırı (PF-30): istem kullanıcı beklemesidir (bu yüzden uzun), ama
  /// askıda kalıp yaşam döngüsünü ([handleLifecycleState]) ve splash kaçışını sonsuza dek kilitlemesin.
  /// Süre dolunca istem "başarısız" sayılır (`biometricFailed`; yeniden dene / şifre ile giriş sunulur).
  static const Duration _biometricPromptLimit = Duration(minutes: 2);

  /// Biyometrik kilit açma (açılış, yeniden kilit, "yeniden dene"). Sağlamlık maddeleri (B4–B7: oturum nesli,
  /// servis istisnası, arka plan bayrakları) `test/services/biometric_robustness_test.dart` içinde sınanır.
  Future<bool> _unlockWithBiometrics() async {
    final epoch = _sessionEpoch; // await'ten ÖNCE: doğrulama sürerken oturum biterse sonuç başka oturuma aittir (B6)
    _biometricChecking = true;
    _biometricFailed = false;
    _authStatus = AuthStatus.checking;
    notifyListeners();
    var ok = false;
    try {
      ok = await clock.bound<bool>(
        biometricService.authenticate(
          reason: 'AHBU Ev Otomasyonu için $_biometricLabel doğrulaması yapın',
        ),
        _biometricPromptLimit,
        () => false,
      );
    } catch (e) {
      // Enjekte edilen servis fırlattı (üretim sarmalayıcısı fırlatmaz): doğrulanmadı sayılır; kilitli kalınır ve
      // kilit ekranı "yeniden dene / şifre ile giriş" sunar. `unawaited` çağrılarda işlenmemiş hata ve takılı
      // "doğrulanıyor" durumu (yaşam döngüsü kapısı sonsuza dek kapalı) oluşmaz (B7). Yalnız tür günlüğe yazılır.
      _log('Biyometrik doğrulama hatası: ${e.runtimeType}');
    } finally {
      // Bayrak yalnız BU oturumun denemesi için sıfırlanır: oturum değiştiyse `_resetSessionState` zaten sıfırladı ve
      // yeni oturumun / denemenin kendi `_biometricChecking` değerine eski denemenin sonu dokunmamalı.
      if (!_isStaleSession(epoch)) _biometricChecking = false;
    }
    // Doğrulama sürerken oturum değişti (çıkış / yeni giriş) ya da durum kapandı: sonuç başka oturuma aittir.
    if (_isStaleSession(epoch)) return false;
    if (!ok) {
      _biometricFailed = true;
      notifyListeners();
      return false;
    }
    _isBiometricSupported = true; // doğrulama başarılı: cihaz destekliyor (sonda zaman aşımıyla false kalmış olabilir)
    _biometricFailed = false;
    _awaitingUnlock = false;
    // İstem ancak ön planda yanıtlanabilir. Açılışta "paused" doğrulama BAŞLAMADAN önce işlendiyse ve "resumed" istem
    // sırasında kapı yüzünden yutulduysa `_inBackground` takılı kalırdı: `_resumeSession` hiçbir şey başlatmaz (MQTT yok)
    // ve bayat `_backgroundedAt` sonraki kısa arka plan gezisini gereksiz yere yeniden kilitlerdi (B5).
    _inBackground = false;
    _backgroundedAt = null;
    if (_pendingRestore) {
      await _startSession();
    } else {
      _authStatus = AuthStatus.authenticated;
      notifyListeners();
      await _resumeSession();
    }
    return true;
  }

  Future<bool>? _retryFlight;

  /// Biyometrik doğrulamayı yeniden dener; başarıda oturum ağ/MQTT ile başlatılır. Süren bir deneme varsa
  /// onun sonucunu döndürür (çift dokunuş ikinci istem açmaz, oturumu iki kez başlatmaz). Fırlatmaz: servis
  /// hatası "doğrulanamadı" (`false`) sayılır.
  Future<bool> retryBiometricAuth() {
    final existing = _retryFlight;
    if (existing != null) return existing;
    late final Future<bool> future;
    future = _unlockWithBiometrics().whenComplete(() {
      if (identical(_retryFlight, future)) _retryFlight = null;
    });
    _retryFlight = future;
    return future;
  }

  /// Şifre ile girişe düş: yerel belirteçler/MQTT temizlenir ve refresh token sunucuda iptal edilir.
  Future<void> fallbackToPasswordLogin() => logout();

  /// Biyometrik girişi aç/kapat. **Her iki yönde de doğrulama istenir** (kapatmak için de).
  Future<bool> toggleBiometric(bool enabled) async {
    if (enabled == _isBiometricEnabled) return true;
    if (!_isBiometricSupported) return false;
    final epoch = _sessionEpoch; // await'ten ÖNCE: doğrulama sürerken çıkış olursa tercih yazılmasın (PF-30)
    final verified = await biometricService.authenticate(
      reason: enabled
          ? 'AHBU Ev Otomasyonu için $_biometricLabel girişini etkinleştirin'
          : 'Biyometrik girişi kapatmak için kimliğinizi doğrulayın',
    );
    if (!verified) return false;
    if (_isStaleSession(epoch)) return false;
    _isBiometricEnabled = enabled;
    // Doğrulama arka plandayken (ör. Android <= 9 cihaz kimlik bilgisi etkinliği) tamamlandı ve sonuç "resumed"dan
    // ÖNCE geldiyse, bayat `_backgroundedAt` ön plana dönüşte yeni etkinleştirmeyi hemen yeniden kilitletir. Kullanıcı
    // kimliğini az önce doğruladı: bekleme süresi şimdi başlar (B4).
    if (_backgroundedAt != null) _backgroundedAt = clock.now();
    unawaited(_enqueueStorage(() => secureStorage.saveBiometricEnabled(enabled), epoch: epoch));
    notifyListeners();
    return true;
  }

  /// İlk giriş istemindeki "Etkinleştir": doğrulama yapar ve tercihi kaydeder.
  Future<bool> enableBiometricWithVerification() async {
    final ok = await toggleBiometric(true);
    if (ok) {
      _shouldPromptBiometrics = false;
      unawaited(_enqueueStorage(() => secureStorage.saveBiometricPromptShown(true), epoch: _sessionEpoch));
      notifyListeners();
    }
    return ok;
  }

  /// İlk giriş istemindeki "Daha Sonra".
  Future<void> dismissBiometricPrompt() async {
    _shouldPromptBiometrics = false;
    unawaited(_enqueueStorage(() => secureStorage.saveBiometricPromptShown(true), epoch: _sessionEpoch));
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Giriş / kayıt / çıkış
  // ---------------------------------------------------------------------------

  // Sunucunun giriş yöntemi yetenekleri (UYELIK-04): yalnız BAŞARILI yanıt bellekte tutulur (uygulama oturumu
  // boyunca; sunucu düzeyinde bilgidir, kullanıcıya bağlı değildir). 404 (eski sunucu) / ağ hatası önbelleğe alınmaz:
  // giriş ekranı bir sonraki açılışta yeniden sorar; o ana kadar isteğe bağlı yöntemler gizlidir (fail-closed).
  AuthCapabilities? _authCapabilities;
  Future<AuthCapabilities>? _authCapabilitiesFlight;

  /// Bu uygulama oturumunda sunucudan alınmış giriş yetenekleri; henüz alınmadıysa / alınamadıysa `null`.
  AuthCapabilities? get authCapabilities => _authCapabilities;

  /// Giriş ekranı açılışında çağrılır (`GET /auth/capabilities`): önbellekte varsa istek atılmaz; eşzamanlı
  /// çağrılar tek istekte birleşir. Fırlatmaz: uç yok (404) / hata -> [AuthCapabilities.none].
  Future<AuthCapabilities> loadAuthCapabilities() {
    final cached = _authCapabilities;
    if (cached != null) return Future<AuthCapabilities>.value(cached);
    return _authCapabilitiesFlight ??= _fetchAuthCapabilities();
  }

  Future<AuthCapabilities> _fetchAuthCapabilities() async {
    try {
      final caps = await cloudApi.fetchAuthCapabilities();
      _authCapabilities = caps;
      return caps;
    } on ApiException catch (e) {
      _log('Giriş yetenekleri alınamadı (${e.statusCode})');
      return AuthCapabilities.none;
    } catch (_) {
      return AuthCapabilities.none;
    } finally {
      _authCapabilitiesFlight = null;
    }
  }

  Future<bool> login(String identifier, String password) async {
    final previous = cloudApi.currentRefreshToken;
    final res = await cloudApi.login(identifier, password);
    return _handleAuthSuccess(res, previousRefreshToken: previous);
  }

  /// Yeni hesap. [acceptTermsVersion]: kayıt ekranında onaylanan Kullanıcı Sözleşmesi sürümü (onay hesapla birlikte
  /// kaydedilir); güncel değilse `409 LEGAL_VERSION_MISMATCH` fırlar ve hesap açılmaz.
  Future<bool> register({
    required String fullName,
    required String email,
    required String password,
    String? phone,
    int? acceptTermsVersion,
  }) async {
    final previous = cloudApi.currentRefreshToken;
    final res = await cloudApi.register(
      fullName: fullName,
      email: email,
      password: password,
      phone: phone,
      acceptTermsVersion: acceptTermsVersion,
    );
    return _handleAuthSuccess(res, previousRefreshToken: previous);
  }

  /// Google ile giriş: yalnızca doğrulanmış kimlik jetonu ([idToken]) gönderilir.
  Future<bool> loginWithGoogle({required String idToken}) async {
    final previous = cloudApi.currentRefreshToken;
    final res = await cloudApi.loginWithGoogle(idToken: idToken);
    return _handleAuthSuccess(res, previousRefreshToken: previous);
  }

  /// Apple ile giriş: kimlik jetonu zorunlu; [fullName] yalnızca ilk girişte Apple'ın verdiği ad;
  /// [nonce] Apple isteğine verilen **ham** nonce'tur (verilirse sunucu jetonla eşleştirir).
  Future<bool> loginWithApple({
    required String identityToken,
    String? fullName,
    String? nonce,
  }) async {
    final previous = cloudApi.currentRefreshToken;
    final res = await cloudApi.loginWithApple(
      identityToken: identityToken,
      fullName: fullName,
      nonce: nonce,
    );
    return _handleAuthSuccess(res, previousRefreshToken: previous);
  }

  /// Telefon OTP kodu gönderir. Yanıt: [CodeChallenge] (`expiresIn`, `resendAfter`); arayüz
  /// `resendAfter` dolmadan "Yeniden gönder"i kapalı tutar. Hata: [ApiException]
  /// (`isRateLimited` -> `resendAfter`/`retryAfter`, `isDeliveryFailed`).
  Future<CodeChallenge> sendPhoneOtp(String phone) => cloudApi.sendPhoneOtp(phone);

  Future<bool> verifyPhoneOtp(String phone, String code) async {
    final previous = cloudApi.currentRefreshToken;
    final res = await cloudApi.verifyPhoneOtp(phone, code);
    return _handleAuthSuccess(res, previousRefreshToken: previous);
  }

  /// Şifre sıfırlama kodu + bağlantısı ister. Yanıt: [CodeChallenge] (`expiresIn`, `resendAfter`).
  Future<CodeChallenge> forgotPassword(String identifier) => cloudApi.forgotPassword(identifier);

  /// OTP kodu **veya** sihirli bağlantı belirteci ile yeni şifre. Kodla sıfırlamada [identifier]
  /// zorunludur; bağlantı [token]'ı ile gerekmez. Yanıt oturum taşıyorsa otomatik giriş yapılır.
  /// Hatalı kodda [ApiException.remainingAttempts] kalan hakkı verir.
  ///
  /// Dönüş: `true` = yanıt oturum taşıdı ve o oturum açıldı (açık oturum varsa değişti); `false` = yalnız şifre
  /// yenilendi, oturum DEĞİŞMEDİ.
  Future<bool> resetPassword({
    String? identifier,
    String? code,
    String? token,
    required String newPassword,
  }) async {
    final previous = cloudApi.currentRefreshToken;
    // Açık oturumun hesabı sıfırlanıyorsa sunucu bu cihazın MQTT bağlantısını da atar (bkz. [_credentialRotation]).
    final res = await _duringCredentialRotation(
      () => cloudApi.resetPassword(
        identifier: identifier,
        code: code,
        token: token,
        newPassword: newPassword,
      ),
    );
    if (res['user'] != null && (res['access_token'] != null || res['token'] != null)) {
      return _handleAuthSuccess(res, previousRefreshToken: previous);
    }
    return false;
  }

  /// Sihirli bağlantı ile tek seferlik giriş (`POST /auth/magic-login`). [token], bağlantının
  /// URL **parçasından** (`#token=`) okunur (`MagicLinkParser`); GET ile gönderilmez.
  Future<bool> loginWithMagicLink(String token) async {
    final previous = cloudApi.currentRefreshToken;
    final res = await cloudApi.magicLogin(token);
    return _handleAuthSuccess(res, previousRefreshToken: previous);
  }

  /// Mevcut parola ile parola değiştirir (`POST /auth/change-password`; servis oturumu ✖).
  ///
  /// Sunucu **diğer tüm cihazların** oturumlarını kapatır ve bu cihaz için yeni belirteçler verir:
  /// belirteçler güvenli depolamaya yazılır (beklenir), yerel veriler (ev, uç noktalar, MQTT)
  /// korunur ve [mustChangePassword] temizlenir. Yanlış mevcut parola:
  /// [ApiException.isInvalidCredentials]. Parolalar kırpılmaz.
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final user = _currentUser;
    if (user == null || !isAuthenticated || isServiceSession) throw ApiException.forbidden();
    if (currentPassword.isEmpty) throw ApiException.validation('Mevcut parolanızı girin.');
    if (newPassword.isEmpty) throw ApiException.validation('Yeni parolanızı girin.');
    if (newPassword == currentPassword) {
      throw ApiException.validation('Yeni parola mevcut parolayla aynı olamaz.');
    }
    final epoch = _sessionEpoch;
    // Sunucu bu cihazın MQTT kimliğini de silip bağlantıyı atar: atılan bağlantı taze kimliği YENİ belirteçle ister
    // (bkz. [_credentialRotation]); sonra kendiliğinden yeni kimlikle yeniden bağlanır.
    final res = await _duringCredentialRotation(
      () => cloudApi.changePassword(
        currentPassword: currentPassword,
        newPassword: newPassword,
      ),
    );
    if (epoch != _sessionEpoch) return; // bu arada oturum kapandı
    final access = cloudApi.authToken;
    final refresh = cloudApi.currentRefreshToken;
    var updated = user;
    final userMap = asMap(res['user']);
    if (userMap != null) {
      try {
        updated = UserModel.fromJson(userMap);
      } on FormatException {
        updated = user;
      }
    }
    // Parola değişti: zorunlu değişim bayrağı kesin olarak kalkmıştır.
    updated = updated.copyWith(mustChangePassword: false);
    _currentUser = updated;
    notifyListeners();
    // Dönen (rotasyon) belirteçler yazılmadan dönülmez: uygulama şimdi kapansa eski (iptal
    // edilmiş) belirteçlerle açılmasın.
    await _enqueueStorage(() async {
      if (access != null) await secureStorage.saveAuthToken(access);
      if (refresh != null) await secureStorage.saveRefreshToken(refresh);
      await secureStorage.saveUser(updated);
      cloudApi.markRefreshPersisted(refresh); // uyelik-3: yazım doğrulandı
    }, epoch: epoch);
  }

  final List<Future<void> Function()> _beforeLogoutHooks = <Future<void> Function()>[];

  /// Çıkış kancalarının yerel temizliği en çok bekleteceği süre. Kancalar (ör. push belirtecini sunucudan
  /// silme isteği) `logout()` BAŞINDA eşzamanlı başlatılır: istek henüz geçerli oturum belirteciyle gönderilmiş
  /// olur. Ağ kötüyken (çıkışın en çok istendiği an) oturum ekranda açık ve kullanılabilir kalmasın diye bu
  /// süre dolunca yerel temizlik HEMEN yapılır; kancalar arka planda tamamlanmaya devam eder.
  static const Duration _logoutHookGrace = Duration(seconds: 1);

  /// Tek bir kancanın üst süresi (arka planda da geçerli); dolunca hata gibi yutulur.
  static const Duration _logoutHookLimit = Duration(seconds: 3);

  // Başlatılmış kanca çalıştırması ve ait olduğu oturum nesli: aynı oturumda eşzamanlı ikinci `logout()`
  // aynı çalıştırmayı paylaşır (kancalar ikinci kez çalışmaz); yeni oturumun çıkışı yenisini başlatır.
  Future<void>? _logoutHooksFlight;
  int _logoutHooksEpoch = -1;

  /// `logout()` başında (oturum belirteci henüz geçerliyken) çalışacak geri çağrı ekler (ör. push belirtecini
  /// silmek). Kancalar EŞZAMANLI başlatılır; çıkış yalnızca en çok 1 sn bekler, süre dolsa da yerel temizlik
  /// hemen yapılır ve kancalar arka planda sürer (her biri en çok 3 sn). Hata ve zaman aşımı yutulur, çıkışı
  /// ENGELLEMEZ. Kancalar YALNIZCA `logout()`'ta çalışır ([logoutAll] sunucuda başarısız olursa kullanıcı
  /// oturumda kalır). Döndürülen geri çağrı kancayı kaldırır.
  void Function() addBeforeLogoutHook(Future<void> Function() hook) {
    _beforeLogoutHooks.add(hook);
    return () => _beforeLogoutHooks.remove(hook);
  }

  /// Kancaları (bu oturum için zaten başlatılmadıysa) eşzamanlı başlatır; tek çalıştırmayı döndürür.
  Future<void> _startBeforeLogoutHooks() {
    final existing = _logoutHooksFlight;
    if (existing != null && _logoutHooksEpoch == _sessionEpoch) return existing;
    final flight = Future.wait(<Future<void>>[
      for (final hook in List<Future<void> Function()>.of(_beforeLogoutHooks))
        Future<void>.sync(hook).timeout(_logoutHookLimit).then((_) {}, onError: (Object _) {}),
    ]).then((_) {});
    _logoutHooksFlight = flight;
    _logoutHooksEpoch = _sessionEpoch;
    return flight;
  }

  /// [flight]'ı en çok [_logoutHookGrace] bekler; bitince beklemeyi hemen keser (zamanlayıcı iptal edilir).
  Future<void> _awaitLogoutHooksBriefly(Future<void> flight) {
    final gate = Completer<void>();
    final timer = Timer(_logoutHookGrace, () {
      if (!gate.isCompleted) gate.complete();
    });
    unawaited(
      flight.then((_) {
        timer.cancel();
        if (!gate.isCompleted) gate.complete();
      }),
    );
    return gate.future;
  }

  /// **Tüm cihazlardaki** oturumları sonlandırır ve bu cihazdan da çıkar (`POST /auth/logout-all`).
  /// Sunucu işlemi başarısız olursa ([ApiException]) **çıkış yapılmaz**: kullanıcı işlemin
  /// gerçekleşmediğini görür ve yeniden dener. Servis PIN oturumunda yalnızca yerel çıkıştır.
  ///
  /// Çıkış kancaları burada ÇALIŞMAZ: sunucuda başarısız olursa oturum (ve push) sürmelidir. Başarılıysa
  /// [logout]'a düşülür ve kancalar orada çalışır (API istemcisi belirteçleri silmiş olabilir: sunucuya
  /// silme isteği başarısız olabilir, yerel işlemler bundan bağımsızdır).
  Future<void> logoutAll() async {
    if (!isAuthenticated) return;
    if (!isServiceSession) {
      // Sunucu bu cihazın MQTT bağlantısını da atar: yanıt beklenmeden eski belirteçle kimlik istenmez.
      await _duringCredentialRotation(cloudApi.logoutAll); // başarıda yerel belirteçler de silinir
    }
    await logout();
  }

  /// 6 haneli servis PIN'i ile **tek eve kapsamlı** 2 saatlik servis oturumu. Önceki yerel oturum
  /// (varsa) sıfırlanır; süre izlenir ve bitince oturum kapanır ([SessionExpiredEvent]).
  Future<bool> loginWithServicePin(String pin, {String? technicianName}) async {
    final previousRefresh = cloudApi.currentRefreshToken;
    final info = await cloudApi.serviceLogin(pin, technicianName: technicianName);
    final access = cloudApi.authToken;

    _resetSessionState(clearApiSession: false);
    final epoch = _sessionEpoch;
    _sessionNotice = null;
    _currentUser = UserModel(
      id: '',
      email: '',
      fullName: info.technicianName.isEmpty ? 'Servis Teknisyeni' : info.technicianName,
      role: 'service_session',
    );
    final home = HomeModel(id: info.homeId, name: info.homeName, role: 'service_session');
    _homes = [home];
    _homesLoaded = true;
    _authStatus = AuthStatus.authenticated;
    _mode = AppMode.cloud;

    unawaited(_enqueueStorage(() async {
      await secureStorage.clearAll();
      if (access != null) await secureStorage.saveAuthToken(access);
      await secureStorage.saveServiceSession(info);
    }, epoch: epoch));
    unawaited(_clearUserPrefs());
    if (previousRefresh != null) unawaited(cloudApi.revokeRefreshToken(previousRefresh));

    _scheduleServiceSessionExpiry(info);
    notifyListeners();
    await selectHome(home);
    return true;
  }

  void _scheduleServiceSessionExpiry(ServiceSessionInfo info) {
    _serviceSessionTimer?.cancel();
    if (_isDisposed) return; // dispose sırasında süren zincir sonradan zamanlayıcı kurmasın (PF-34)
    final remaining = info.remaining(clock.now());
    _serviceSessionTimer = clock.timer(remaining, () {
      _handleSessionExpired(SessionEndReason.serviceSessionExpired);
    });
  }

  Future<bool> _handleAuthSuccess(Map<String, dynamic> res, {String? previousRefreshToken}) async {
    final userMap = asMap(res['user']);
    UserModel? user;
    try {
      user = userMap == null ? null : UserModel.fromJson(userMap);
    } on FormatException {
      user = null;
    }
    final access = cloudApi.authToken;
    final refresh = cloudApi.currentRefreshToken;
    if (user == null || access == null) {
      cloudApi.clearSession();
      throw const ApiException(
        statusCode: 502,
        code: 'BAD_RESPONSE',
        message: 'Sunucu geçersiz bir oturum yanıtı verdi.',
      );
    }

    // Hesap değiştirme / yeniden giriş: önceki kullanıcının TÜM yerel verisi silinir.
    _resetSessionState(clearApiSession: false);
    final epoch = _sessionEpoch;
    _sessionNotice = null;
    _currentUser = user;
    _authStatus = AuthStatus.authenticated;
    _mode = AppMode.cloud;

    unawaited(_enqueueStorage(() async {
      await secureStorage.clearAll();
      await secureStorage.saveAuthToken(access);
      if (refresh != null) await secureStorage.saveRefreshToken(refresh);
      await secureStorage.saveUser(user!);
      // Yazım gerçekten bitti (uyelik-3): istemci depodaki token'ı artık bilir (başka isolate döndürürse benimser).
      cloudApi.markRefreshPersisted(refresh);
    }, epoch: epoch));
    unawaited(_clearUserPrefs());
    if (previousRefreshToken != null && previousRefreshToken != refresh) {
      unawaited(cloudApi.revokeRefreshToken(previousRefreshToken));
    }

    // İlk giriş sonrası biyometrik istem kararı. Üç bağımsız sonda EŞZAMANLI (her biri süre sınırlı) ve bildirimden
    // ÖNCE biter: DashboardPage `shouldPromptBiometrics`'ı ilk karede BİR kez okur (unawaited YAPILMAZ).
    final (promptRead, supported, label) = await (
      _readStore<bool>(secureStorage.isBiometricPromptShown),
      biometricService.isBiometricSupported(),
      biometricService.getBiometricLabel(),
    ).wait;
    _isBiometricSupported = supported;
    if (supported) _biometricLabel = label;
    if (_isStaleSession(epoch)) return true; // sonda sürerken oturum değişti: istem kararı başka oturuma ait
    _shouldPromptBiometrics = supported && promptRead.error == null && promptRead.value != true;
    notifyListeners();

    // Ev listesi (rol dahil): bir ağ turu beklenir; ilk evin seçimi + REST yığını + canlı kanal ARKA PLANDA sürer
    // (PF-39). Beklenirse telefon-OTP / şifre sıfırlama / sihirli bağlantı diyalogları (PopScope canPop: !busy)
    // hepsi bitene kadar açık kalırdı (_startSession ile aynı desen).
    await fetchHomes(autoSelect: false);
    unawaited(_selectInitialHome());
    return true;
  }

  /// Çıkış. Sıra: (1) varsa çıkış kancaları (ör. push belirtecini silme) oturum belirteci HÂLÂ geçerliyken
  /// EŞZAMANLI başlatılır ve en çok 1 sn beklenir (süre dolsa da sonraki adımlara geçilir, kancalar arka
  /// planda sürer; aynı oturumda eşzamanlı ikinci `logout()` kancaları yeniden çalıştırmaz); (2) **yerel
  /// temizlik** (tüm kullanıcı kapsamlı alanlar, abonelikler, zamanlayıcılar, servis PIN, MQTT, güvenli
  /// depolama, `saved_service_device_*`); (3) sunucuda refresh token iptali (en iyi çaba; ağ hatası çıkışı
  /// engellemez). Kanca yoksa hiçbir `await` olmadan doğrudan (2)'ye geçilir.
  Future<void> logout() async {
    if (_beforeLogoutHooks.isNotEmpty) await _awaitLogoutHooksBriefly(_startBeforeLogoutHooks());
    final refresh = cloudApi.currentRefreshToken;
    // Servis (PIN) oturumu sunucuda da kapatılır (uyelik-12): istek yerel temizlikten ÖNCE oturumun JWT'siyle başlatılır;
    // beklenmez (en çok 3 sn; hata çıkışı engellemez). Aksi halde PIN oturumu 2 saat boyunca sunucuda açık kalırdı.
    final serviceToken = isServiceSession ? cloudApi.authToken : null;
    if (serviceToken != null) unawaited(cloudApi.revokeServiceSession(serviceToken));
    _resetSessionState();
    _authStatus = AuthStatus.unauthenticated;
    _sessionNotice = null;
    notifyListeners();
    await _enqueueStorage(() => secureStorage.clearAll());
    await _clearUserPrefs();
    if (refresh != null) unawaited(cloudApi.revokeRefreshToken(refresh));
  }

  Future<void> _startSession() async {
    final epoch = _sessionEpoch;
    _pendingRestore = false;
    if (isServiceSession) {
      final info = cloudApi.serviceSession!;
      final home = HomeModel(id: info.homeId, name: info.homeName, role: 'service_session');
      _homes = [home];
      _homesLoaded = true;
      _authStatus = AuthStatus.authenticated;
      _scheduleServiceSessionExpiry(info);
      notifyListeners();
      await selectHome(home);
      return;
    }

    // Yalnızca refresh token varsa önce yenile. Yalnız sunucunun KALICI reddi (4xx) oturumu kapatır: API istemcisi
    // bunu oturum olayıyla bildirir (`_handleSessionExpired`: yerel temizlik, giriş ekranı). Ağ hatası / 5xx / 429'da
    // oturum KORUNUR: aşağıda önbellek-önce ya da ağ-öncelikli akış sürer; ilk 401'de tek-uçuş yenileme yeniden denenir.
    if (cloudApi.authToken == null && cloudApi.currentRefreshToken != null) {
      try {
        final ok = await cloudApi.refreshSession();
        if (epoch != _sessionEpoch) return; // oturum sona erdi (olay üretildi) ya da değişti
        if (!ok) {
          // Kalıcı ret normalde oturum olayıyla (epoch artar) biter. Olaysız `false` (savunma; üretim istemcisi
          // üretmez): açılış ekranında takılı kalmak yerine giriş ekranı; saklı belirteçler SİLİNMEZ.
          if (_authStatus == AuthStatus.checking) {
            _authStatus = AuthStatus.unauthenticated;
            notifyListeners();
          }
          return;
        }
      } on ApiException catch (e) {
        _log('Oturum yenilenemedi (${e.statusCode})');
        if (epoch != _sessionEpoch) return;
      }
    }

    // Kullanıcı kaydı yoktu ve saklı belirteçten türetilememişti (bkz. `_initInner`): yenilenen erişim JWT'sinden
    // türetilir ve kayıt onarılır. Türetilemiyorsa (yenileme ağ yüzünden olmadı / yanıt çözülemedi) KULLANICISIZ oturum
    // kurulmaz ("authenticated" + kullanıcı yok olmaz); saklı belirteçler silinmez: ağ gelince sonraki açılış dener.
    if (_currentUser == null) {
      final derived = _userFromJwt(cloudApi.authToken);
      if (derived == null) {
        cloudApi.clearSession();
        _authStatus = AuthStatus.unauthenticated;
        notifyListeners();
        await _afterInitWithoutSession();
        return;
      }
      _currentUser = derived;
      unawaited(_enqueueStorage(() => secureStorage.saveUser(derived), epoch: epoch));
    }

    // Önbellek-önce (SWR) açılış (PF-03): saklı ev listesi (yalnız yerel depo okuması) varsa pano HEMEN açılır ve
    // sunucuyla arka planda uzlaşılır (kapalı kalan uygulamada saklı erişim jetonu çoğunlukla bitmiştir: ağ-öncelikli
    // açılış 401 -> yenileme -> yeniden = 3 ardışık tur beklerdi). `homesFromCache` BU pencerede set EDİLMEZ: yalnız ağ
    // hatasında (çevrimiçi kullanıcıya "Çevrimdışısınız" şeridi çıkmasın); `homesLoading` zaten true'dur.
    final cached = await _loadCachedHomesForStart();
    if (epoch != _sessionEpoch) return;
    if (cached.isNotEmpty) {
      _homes = cached;
      _homesCacheDigest = _homesDigest(_currentUser!.id, cached);
      _authStatus = AuthStatus.authenticated;
      notifyListeners();
      unawaited(fetchHomes(autoSelect: false)); // rol / üyelik değişimini uzlaştırır (_reconcileHomes)
      if (_mode == AppMode.direct) {
        await _startDirectSession(epoch);
      } else {
        unawaited(_selectInitialHome());
        unawaited(_syncLegalStatus(epoch));
      }
      return;
    }

    // Önbellek yok (ya da okunamadı): ağ-öncelikli akış.
    await fetchHomes(autoSelect: false);
    if (epoch != _sessionEpoch) return;
    _authStatus = AuthStatus.authenticated;
    notifyListeners();

    if (_mode == AppMode.direct) {
      await _startDirectSession(epoch);
    } else {
      unawaited(_selectInitialHome());
      unawaited(_syncLegalStatus(epoch));
    }
  }

  /// Doğrudan (LAN) kipte oturum açılışı (kullanim-1): önce aktif ev seçilir (komut/yetki kapıları ev rolüne bakar;
  /// `selectHome`'un doğrudan dalı adres + anahtarı hazırlayıp durumu okur), sonra yoklama başlar. Ev yoksa (dairesiz
  /// hesap) eldeki adres/anahtarla sürer.
  Future<void> _startDirectSession(int epoch) async {
    await _selectInitialHome();
    if (_isStaleSession(epoch)) return;
    if (_activeHome == null) {
      await _prepareDirect();
      await refresh();
    }
    _startPolling();
  }

  /// Saklı ev listesi (yalnız bu kullanıcı için). Okuma hatası [storageError]'a yazılır ve boş liste döner
  /// (ağ-öncelikli akışa dönülür).
  Future<List<HomeModel>> _loadCachedHomesForStart() async {
    final user = _currentUser;
    if (user == null || user.id.isEmpty) return const <HomeModel>[];
    try {
      return await secureStorage.loadHomesCache(user.id);
    } on SecureStorageException catch (e) {
      _storageError = e.message;
      return const <HomeModel>[];
    }
  }

  // ---------------------------------------------------------------------------
  // Evler
  // ---------------------------------------------------------------------------

  /// Ev listesini (**ev bazlı rollerle**) sunucudan yeniler. Hata ayrımı: başarıda [homesLoaded]
  /// true olur; hata [homesError]'a yazılır; çevrimdışıyken önbellekteki evler gösterilir; 401'de
  /// oturum kapanır ([SessionExpiredEvent]).
  Future<void> fetchHomes({bool autoSelect = true}) {
    final existing = _homesFlight;
    if (existing != null) return existing;
    late final Future<void> future;
    future = _fetchHomesImpl(autoSelect).whenComplete(() {
      if (identical(_homesFlight, future)) _homesFlight = null;
    });
    _homesFlight = future;
    return future;
  }

  Future<void> _fetchHomesImpl(bool autoSelect) async {
    if (_isDisposed || _currentUser == null) return;
    if (isServiceSession) return; // servis oturumunun tek evi giriş sırasında bellidir
    final epoch = _sessionEpoch;
    _homesLoading = true;
    _homesError = null;
    notifyListeners();
    try {
      final list = await cloudApi.fetchHomes();
      if (epoch != _sessionEpoch) return;
      _homes = list;
      _homesLoaded = true;
      _homesFromCache = false;
      _persistHomesCache(list);
      await _reconcileHomes(autoSelect: autoSelect, epoch: epoch);
      if (epoch == _sessionEpoch) _maybePrefetchLocalKey();
    } on ApiException catch (e) {
      if (epoch != _sessionEpoch) return;
      if (e.isUnauthorized) return; // oturum kapatma olayı zaten işlendi
      _homesError = e.message;
      if (e.isNetwork && !_homesLoaded) {
        await _loadHomesFromCache(epoch, autoSelect);
      }
    } catch (_) {
      if (epoch == _sessionEpoch) _homesError = 'Evler yüklenemedi. Lütfen tekrar deneyin.';
    } finally {
      if (epoch == _sessionEpoch) {
        _homesLoading = false;
        notifyListeners();
      }
    }
  }

  // Son BAŞARIYLA yazılan (ya da önbellekten okunan) ev listesinin özeti (PF-35): içerik değişmedikçe her başarılı
  // `fetchHomes`'ta güvenli depoya (Keystore/Keychain, pahalı) tümden yeniden yazılmaz. Oturum sıfırlanınca düşer.
  String? _homesCacheDigest;

  static String _homesDigest(String userId, List<HomeModel> homes) =>
      '$userId|${jsonEncode(<Object?>[for (final home in homes) home.toJson()])}';

  void _persistHomesCache(List<HomeModel> homes) {
    final user = _currentUser;
    if (user == null || user.id.isEmpty) return;
    final digest = _homesDigest(user.id, homes);
    if (digest == _homesCacheDigest) return;
    final epoch = _sessionEpoch;
    unawaited(_enqueueStorage(() async {
      await secureStorage.saveHomesCache(user.id, homes);
      // Özet yalnız BAŞARILI yazımda kaydedilir: hata sonrası aynı liste yeniden denenir.
      if (epoch == _sessionEpoch) _homesCacheDigest = digest;
    }, epoch: epoch));
  }

  Future<void> _loadHomesFromCache(int epoch, bool autoSelect) async {
    final user = _currentUser;
    if (user == null) return;
    try {
      final cached = await secureStorage.loadHomesCache(user.id);
      if (epoch != _sessionEpoch || cached.isEmpty) return;
      _homes = cached;
      _homesFromCache = true;
      await _reconcileHomes(autoSelect: autoSelect, epoch: epoch);
    } on SecureStorageException catch (e) {
      _storageError = e.message;
    }
  }

  /// Aktif ev hâlâ listede mi / rolü değişti mi; aktif ev yoksa uygun olanı seç.
  Future<void> _reconcileHomes({required bool autoSelect, required int epoch}) async {
    final active = _activeHome;
    if (active != null) {
      final match = homeById(active.id);
      if (match == null) {
        // Erişim kaybedildi (üye çıkarıldı / devir): ev bağlamı kapatılır.
        _homeEpoch++;
        unawaited(mqttService.stop());
        _mqttLink = MqttLinkState.disconnected;
        _resetHomeScopedState();
        _activeHome = null;
        // Doğrudan kipte kalınırsa ev seçimi ve komut kapıları çıkmaza girer (kullanim-1/bireysel-5): buluta dönülür.
        // Beklenmez: bulut kipine geçiş ev listesini yeniler ve o yenileme şu an uçuştaki bu yenilemedir.
        if (_mode == AppMode.direct) unawaited(setMode(AppMode.cloud));
      } else if (match.role != active.role ||
          match.guestValidUntil != active.guestValidUntil ||
          match.serverMarkedExpired != active.serverMarkedExpired) {
        _activeHome = match;
        _scheduleGuestExpiry();
        if (match.isGuestExpiredAt(clock.now())) {
          // Misafir süresi doldu: yerel veri ve canlı bağlantı kapatılır (sızıntı yok).
          _homeEpoch++;
          unawaited(mqttService.stop());
          _mqttLink = MqttLinkState.disconnected;
          _resetHomeScopedState();
        } else if (!_inBackground) {
          unawaited(refresh(silent: true));
        }
      } else {
        _activeHome = match;
      }
    }
    if (epoch != _sessionEpoch) return;
    if (_activeHome == null && autoSelect && _homes.isNotEmpty) {
      final pick = await _pickInitialHome();
      if (epoch != _sessionEpoch) return;
      if (pick != null) await selectHome(pick);
    }
  }

  Future<HomeModel?> _pickInitialHome() async {
    final now = clock.now();
    final usable = _homes.where((h) => !h.isGuestExpiredAt(now)).toList();
    // Yalnızca süresi dolmuş misafir evleri varsa biri seçilir: veri/ağ yüklenmez, ancak
    // `capabilities.isGuestExpired` ile "süre doldu" ekranı gösterilebilir.
    if (usable.isEmpty) return _homes.isEmpty ? null : _homes.first;
    String? saved;
    try {
      saved = (await SharedPreferences.getInstance()).getString(_prefsActiveHome);
    } catch (_) {}
    for (final home in usable) {
      if (home.id == saved) return home;
    }
    return usable.first;
  }

  Future<void> _selectInitialHome() async {
    if (_activeHome != null || _homes.isEmpty) return;
    final epoch = _sessionEpoch;
    final pick = await _pickInitialHome();
    // Bu arada oturum kapandı (çıkış) ya da ev zaten seçildi: eski seçim uygulanmaz. Liste önbellekten açılışta
    // sunucuyla uzlaşmış olabilir: seçim GÜNCEL listeden yapılır (artık listelenmeyen ev seçilmez).
    if (_isStaleSession(epoch) || _activeHome != null) return;
    final fresh = pick == null ? null : homeById(pick.id);
    if (fresh != null) await selectHome(fresh);
  }

  /// Aktif evi değiştirir: ev kapsamlı **tüm** önbellekler (uç noktalar, cihazlar, durum, kurallar,
  /// servis PIN, bekleyen komutlar, MQTT) sıfırlanır; yeni evin verisi yüklenir.
  Future<void> selectHome(HomeModel home) async {
    if (_isDisposed) return; // dispose sırasında süren zincir (ör. claim sonrası ev seçimi) REST/MQTT başlatmasın (PF-34)
    _homeEpoch++;
    unawaited(mqttService.stop());
    _mqttLink = MqttLinkState.disconnected;
    _resetHomeScopedState();
    _activeHome = home;
    _scheduleGuestExpiry();
    unawaited(_saveActiveHomeId(home.id));
    notifyListeners();

    if (home.isGuestExpiredAt(clock.now())) return; // süresi dolmuş misafir: veri/ağ yok

    if (_mode == AppMode.cloud) {
      // REST yenilemesi ve canlı kanal EŞZAMANLI (PF-03): MQTT REST yığınının (3 ardışık tur olabilir) arkasında
      // beklemez; REST yanıtı beklenirken gelen daha yeni canlı `state` REST'in üzerine uygulanır (_loadEndpoints).
      await Future.wait<void>(<Future<void>>[refresh(), _startRealtime()]);
      _maybePrefetchLocalKey();
    } else {
      // Ev değişti (kullanim-3): önceki evin panosu (anahtar + adres + uçuştaki yoklama) yeni eve taşınmaz.
      final epoch = _homeEpoch;
      directApi.localKey = null;
      _localKeyRefreshTried = false;
      _pollInFlight = null;
      _lastLanUid = null;
      await _loadHomeHost(home.id);
      if (_isDisposed || epoch != _homeEpoch) return;
      await _prepareDirect();
      if (epoch != _homeEpoch) return;
      await refresh();
    }
  }

  Future<void> _saveActiveHomeId(String id) async {
    try {
      await (await SharedPreferences.getInstance()).setString(_prefsActiveHome, id);
    } catch (_) {}
  }

  void _scheduleGuestExpiry() {
    _guestExpiryTimer?.cancel();
    _guestExpiryTimer = null;
    if (_isDisposed) return; // dispose sırasında süren zincir sonradan zamanlayıcı kurmasın (PF-34)
    final home = _activeHome;
    if (home == null || !home.isGuestRole) return;
    final until = home.guestValidUntil;
    if (until == null) return;
    final remaining = until.difference(clock.now());
    if (remaining.isNegative) return;
    final id = home.id;
    // Pencere `valid_until` DAHİL geçerlidir (CONTRACTS §1.4): zamanlayıcı sınırı biraz aşınca
    // tetiklenir. Tam sınırda (süre = 0) tetiklenseydi pencere hâlâ geçerli sayılır, yeniden kurulan
    // sıfır süreli zamanlayıcı döngüye girerdi.
    _guestExpiryTimer = clock.timer(
      remaining + const Duration(milliseconds: 500),
      () => _handleGuestExpired(id),
    );
  }

  // ---------------------------------------------------------------------------
  // Mod, adres, cihaz seçimi
  // ---------------------------------------------------------------------------

  /// Wi-Fi sihirbazında anahtarsız durumda görülen panoların hazırlık bilgisi (bireysel-13; yalnız bellekte): pano kimliği
  /// -> `provisioned`. Sahiplenme diyaloğu hazırlanmamış panoda eşlemeden önce uyarır.
  final Map<String, bool> _boardProvisioned = <String, bool>{};

  /// Wi-Fi sihirbazı bir panonun hazırlık durumunu gördü (`null` = bilinmiyor; kayıt silinir).
  void noteBoardProvisioned(String uid, bool? provisioned) {
    final id = QrClaimParser.normalizeUid(uid);
    if (id == null) return;
    if (provisioned == null) {
      _boardProvisioned.remove(id);
    } else {
      _boardProvisioned[id] = provisioned;
    }
  }

  /// Pano bu oturumda Wi-Fi sihirbazında hazırlanmamış (`provisioned:false`) görüldü.
  bool isKnownUnprovisioned(String uid) {
    final id = QrClaimParser.normalizeUid(uid);
    return id != null && _boardProvisioned[id] == false;
  }

  /// Bulut / doğrudan mod. Doğrudan moda yalnızca yetkili kullanıcılar (veya oturumsuz yerel mod)
  /// geçebilir; reddedilirse `false` döner.
  Future<bool> setMode(AppMode newMode) async {
    if (newMode == _mode) return true;
    if (newMode == AppMode.direct && isAuthenticated && !capabilities.canSwitchMode) return false;

    _pipeline.cancelAll();
    _resetLayoutRefresh(); // bulut yerleşim yenilemesi mod değişince geçersiz (yeniden bulut moduna dönüşte snapshot alınır)
    _mode = newMode;
    _resetChildLockKnowledge(); // kaynak değişti (LAN <-> bulut)
    unawaited(_saveMode(newMode));
    notifyListeners();

    if (newMode == AppMode.direct) {
      unawaited(mqttService.stop());
      _mqttLink = MqttLinkState.disconnected;
      _status = null;
      _invalidateViews();
      _directFailures = 0;
      _connState = ConnectionStateEnum.connecting;
      final home = _activeHome;
      if (home != null) await _loadHomeHost(home.id); // ev başına adres (kullanim-3)
      await _prepareDirect();
      _startPolling();
      await refresh();
    } else {
      _pollTimer?.cancel();
      _pollTimer = null;
      _resumeDirectPolling(); // LAN durdurma / 423 engeli doğrudan moda aittir: bulutta "anahtar/kilit" kalıntısı kalmaz
      _status = null;
      _invalidateViews();
      if (isAuthenticated) {
        if (_activeHome != null) {
          // Buluta dönüş: snapshot + canlı kanal EŞZAMANLI (PF-03). Ev listesi burada YENİLENMEZ (eskiden de değildi;
          // sabitlenmiş test harness'ı boş sahte ev listesiyle çalışır: yenileme aktif evi düşürürdü).
          await Future.wait<void>(<Future<void>>[refresh(), _startRealtime()]);
        } else {
          await fetchHomes();
        }
      }
    }
    notifyListeners();
    return true;
  }

  Future<void> _saveMode(AppMode mode) async {
    try {
      await (await SharedPreferences.getInstance())
          .setString(_prefsMode, mode == AppMode.cloud ? 'cloud' : 'direct');
    } catch (_) {}
  }

  void _requireHostEdit() {
    if (isAuthenticated && !capabilities.canEditDeviceHost) throw ApiException.forbidden();
  }

  /// Doğrudan mod cihaz adresi (`host` veya `host:port`).
  Future<void> setHost(String newHost) async {
    _requireHostEdit();
    final trimmed = newHost.trim();
    directApi.updateHost(trimmed);
    if (trimmed.isNotEmpty && !directApi.isConfigured) {
      directApi.updateHost(_host); // geçersiz adres: önceki adres korunur
      throw ApiException.validation('Geçersiz cihaz adresi.');
    }
    _host = trimmed;
    _lastLanUid = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsHost, _host);
      final home = _activeHome;
      if (home != null) await prefs.setString('$_prefsHostPrefix${home.id}', _host); // kullanim-3
    } catch (_) {}
    _connState = ConnectionStateEnum.connecting;
    _directFailures = 0;
    _status = null;
    _invalidateViews();
    _resumeDirectPolling(); // yeni adres: durdurma / 423 beklemesi eski adrese aitti
    notifyListeners();
    await refresh();
  }

  /// Servis sorumlusunun üzerinde çalışacağı cihazı (UUID + IP) seçmesi.
  Future<void> selectDevice({required String uuid, required String ip, String? name}) async {
    _requireHostEdit();
    final cleanUuid = uuid.trim().isEmpty ? '' : QrClaimParser.normalizeUid(uuid);
    if (cleanUuid == null) throw ApiException.validation('Geçersiz cihaz kimliği.');
    final cleanIp = ip.trim();
    final previousHost = _host;
    directApi.updateHost(cleanIp);
    if (cleanIp.isNotEmpty && !directApi.isConfigured) {
      directApi.updateHost(previousHost); // geçersiz adres: önceki adres korunur
      throw ApiException.validation('Geçersiz cihaz adresi.');
    }
    _selectedDeviceUuid = cleanUuid;
    _selectedDeviceIp = cleanIp;
    _selectedDeviceName = name?.trim();
    _host = _selectedDeviceIp;
    directApi.localKey = null;
    _localKeyRefreshTried = false;
    _resumeDirectPolling(); // yeni cihaz: eski cihazın durdurma / 423 beklemesi geçersiz
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsSvcUuid, _selectedDeviceUuid);
      await prefs.setString(_prefsSvcIp, _selectedDeviceIp);
      await prefs.setString(_prefsHost, _host);
      if (_selectedDeviceName != null) {
        await prefs.setString(_prefsSvcName, _selectedDeviceName!);
      } else {
        await prefs.remove(_prefsSvcName);
      }
    } catch (_) {}
    await _resolveLocalKey();
    if (_mode == AppMode.direct) unawaited(refresh(silent: true));
  }

  Future<void> updateSelectedDeviceIp(String newIp) async {
    _requireHostEdit();
    final cleanIp = newIp.trim();
    final previousHost = _host;
    directApi.updateHost(cleanIp);
    if (cleanIp.isNotEmpty && !directApi.isConfigured) {
      directApi.updateHost(previousHost); // geçersiz adres: önceki adres korunur
      throw ApiException.validation('Geçersiz cihaz adresi.');
    }
    _selectedDeviceIp = cleanIp;
    _host = _selectedDeviceIp;
    _resumeDirectPolling(); // yeni adres: durdurma / 423 beklemesi eski adrese aitti
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsSvcIp, _selectedDeviceIp);
      await prefs.setString(_prefsHost, _host);
    } catch (_) {}
    if (_mode == AppMode.direct) unawaited(refresh(silent: true));
  }

  Future<void> updateSelectedDeviceUuid(String newUuid) async {
    _requireHostEdit();
    final clean = newUuid.trim().isEmpty ? '' : QrClaimParser.normalizeUid(newUuid);
    if (clean == null) throw ApiException.validation('Geçersiz cihaz kimliği.');
    _selectedDeviceUuid = clean;
    directApi.localKey = null;
    _localKeyRefreshTried = false;
    _resumeDirectPolling(); // yeni cihaz kimliği: eski cihazın durdurma / 423 beklemesi geçersiz
    notifyListeners();
    try {
      await (await SharedPreferences.getInstance()).setString(_prefsSvcUuid, _selectedDeviceUuid);
    } catch (_) {}
    await _resolveLocalKey();
  }

  /// Cihaz yerel anahtarını elle kaydeder (8–32 karakter). Anahtar loglanmaz.
  Future<void> setLocalKey(String key) async {
    final clean = key.trim();
    if (clean.length < 8 || clean.length > 32) {
      throw ApiException.validation('Cihaz anahtarı 8 ile 32 karakter arasında olmalıdır.');
    }
    directApi.localKey = clean;
    _resumeDirectPolling(); // yeni anahtar: durdurulmuş yoklama sürer ve HEMEN denenir (depo yazımı beklenmez)
    if (_mode == AppMode.direct) unawaited(refresh(silent: true));
    // Anahtarın ait olduğu pano (bireysel-5): girişsiz kullanıcıda adresteki pano esastır; girişlide aktif evin panosu.
    final anonymous = _currentUser == null;
    var uuid = anonymous ? (_lastLanUid ?? _localKeyDeviceUuid()) : (_localKeyDeviceUuid() ?? _lastLanUid);
    if (uuid == null && directApi.isConfigured) {
      try {
        uuid = (await directApi.fetchStatus()).uid; // en iyi çaba: kısıtlı özet de `device` taşır
      } catch (_) {}
    }
    final id = QrClaimParser.normalizeUid(uuid);
    if (id != null) {
      await _enqueueStorage(() => secureStorage.saveLocalKey(id, clean));
      if (anonymous) {
        _anonLanDevice = id;
        await _savePref(_prefsAnonLanDevice, id); // girişsiz açılışta anahtar bu kimlikle geri yüklenir
      } else {
        _rememberLanDevice(id);
      }
    }
    notifyListeners();
  }

  /// Bir cihazın yerel anahtarı: önce güvenli depolama, yoksa (yetkiliyse) sunucudan alınıp saklanır.
  ///
  /// [homeId]: cihazın bağlı olduğu ev (verilmezse aktif ev). Servis sihirbazında **az önce sahiplenilen
  /// ev aktif ev değildir** (`claimDevice` servis akışında evi seçmez): `homeId: claim.homeId` verin.
  /// Aktif olmayan ev için istemci yetki kapısı yoktur (sunucu karar verir: owner/resident/staff/servis
  /// oturumu; süper kullanıcı ✖ olduğundan hiç sorulmaz).
  Future<String?> localKeyFor(String deviceUuid, {String? homeId, bool forceRefresh = false}) async =>
      (await _lookupLocalKey(deviceUuid, homeId: homeId, forceRefresh: forceRefresh)).key;

  /// [localKeyFor] gövdesi + "sunucudan yanıt alındı mı" bilgisi ([serverAnswered]): sunucuya hiç gidilmediyse
  /// (anahtar depodaydı / cihaz-yetki yok) ya da ağ hatası olduysa `false`; sunucu anahtarı ya da bir hata
  /// YANITI (403/404/5xx ...) verdiyse `true`.
  Future<({String? key, bool serverAnswered})> _lookupLocalKey(
    String deviceUuid, {
    String? homeId,
    bool forceRefresh = false,
  }) async {
    final uuid = QrClaimParser.normalizeUid(deviceUuid);
    if (uuid == null) return (key: null, serverAnswered: false);
    String? key;
    var serverAnswered = false;
    if (!forceRefresh) {
      try {
        key = await secureStorage.getLocalKey(uuid);
      } on SecureStorageException catch (e) {
        _storageError = e.message;
      }
    }
    final String? targetHomeId = homeId ?? _activeHome?.id;
    final bool otherHome = homeId != null && homeId != _activeHome?.id;
    final bool allowed = otherHome ? !isSuperUser : capabilities.canFetchLocalKey;
    if (key == null && isAuthenticated && targetHomeId != null && allowed) {
      try {
        key = await cloudApi.localKey(targetHomeId, uuid);
        serverAnswered = true;
        final saved = key;
        await _enqueueStorage(() => secureStorage.saveLocalKey(uuid, saved));
      } on ApiException catch (e) {
        _directError = e.message;
        serverAnswered = !e.isNetwork;
      }
    }
    return (key: key, serverAnswered: serverAnswered);
  }

  String? _localKeyDeviceUuid() {
    if (_selectedDeviceUuid.isNotEmpty) return _selectedDeviceUuid;
    final ref = _primaryDeviceRef();
    final fromCloud = ref == null ? null : QrClaimParser.normalizeUid(ref);
    if (fromCloud != null) return fromCloud;
    final home = _activeHome;
    if (home != null) return _lanDeviceByHome[home.id]; // kullanim-1: internetsiz açılışta hatırlanan pano
    return _currentUser == null ? _anonLanDevice : null; // bireysel-5: girişsiz yerel kip
  }

  /// Anahtarı çözer (depo, yoksa/`forceRefresh` ise sunucu) ve `directApi.localKey`'e yazar. Dönen değer:
  /// sunucudan YANIT alındı mı (`serverAnswered`); cihaz bilinmiyorsa `false`.
  Future<bool> _resolveLocalKey({bool forceRefresh = false}) async {
    final uuid = _localKeyDeviceUuid();
    if (uuid == null) return false;
    final epoch = _homeEpoch;
    final result = await _lookupLocalKey(uuid, forceRefresh: forceRefresh);
    if (epoch != _homeEpoch) return false; // ev değişti (kullanim-3): eski evin anahtarı yeni eve yazılmaz
    final key = result.key;
    if (key != null) {
      directApi.localKey = key;
      _rememberLanDevice(uuid); // kullanim-1: internetsiz açılışta da bu pano bulunsun
    }
    notifyListeners();
    return result.serverAnswered;
  }

  /// Önden tazeleme aralığı (pano-6; cihaz başına).
  static const Duration _localKeyPrefetchEvery = Duration(hours: 12);

  /// Önden tazelemesi uçuşta olan panolar.
  final Set<String> _localKeyPrefetchFlight = <String>{};

  /// Bulut kipinde aktif evin birincil panosunun yerel anahtarını, güvenli depoda zaten varsa (yerel kip kullanılmış),
  /// cihaz başına en çok 12 saatte bir sunucudan tazeler (pano-6): sunucu anahtarı döndürdükten sonra internet kesilirse
  /// yerel kip güncel anahtarla çalışır. En iyi çaba: beklenmez, hatalar yutulur (depodaki anahtar korunur); anahtar
  /// yetkisi olmayan rolde (misafir, süper) yapılmaz. Mevcut 401 -> tek tazeleme davranışı aynen sürer.
  void _maybePrefetchLocalKey() {
    if (_isDisposed || _mode != AppMode.cloud || !isAuthenticated || _inBackground) return;
    final home = _activeHome;
    // Servis PIN oturumunda yapılmaz: teknisyen telefonunda müşteri anahtarı tutulmaz (sihirbaz anahtarı yalnız bellekte).
    if (home == null || !capabilities.canFetchLocalKey || capabilities.isServiceSession) return;
    final ref = _primaryDeviceRef();
    final uuid = ref == null ? null : QrClaimParser.normalizeUid(ref);
    if (uuid == null || !_localKeyPrefetchFlight.add(uuid)) return;
    final epoch = _sessionEpoch;
    unawaited(() async {
      try {
        final stored = await secureStorage.getLocalKey(uuid);
        if (stored == null || _isStaleSession(epoch)) return;
        final prefs = await SharedPreferences.getInstance();
        final stampKey = '$_prefsKeyPrefetchPrefix$uuid';
        final last = prefs.getInt(stampKey);
        final now = clock.now().millisecondsSinceEpoch;
        if (last != null && now >= last && now - last < _localKeyPrefetchEvery.inMilliseconds) return;
        final fresh = await cloudApi.localKey(home.id, uuid);
        if (_isStaleSession(epoch)) return;
        if (fresh != stored) await _enqueueStorage(() => secureStorage.saveLocalKey(uuid, fresh), epoch: epoch);
        await prefs.setInt(stampKey, now);
      } catch (_) {
        // En iyi çaba: ağ / yetki hatası yerel kipteki mevcut anahtarı etkilemez.
      } finally {
        _localKeyPrefetchFlight.remove(uuid);
      }
    }());
  }

  /// Anahtarı sunucudan BİR kez yeniler (401 / anahtarsız özet). Yenileme hakkı yalnız sunucudan YANIT alınan
  /// denemede tüketilir: ağ hatasında ya da cihaz/yetki yokken (sunucuya gidilmediğinde) sonraki 401'de
  /// yeniden denenir (internet gelince anahtar yine alınabilsin).
  Future<void> _refreshLocalKeyOnce() async {
    _localKeyRefreshTried = true; // eşzamanlı ikinci yenileme olmasın
    final answered = await _resolveLocalKey(forceRefresh: true);
    if (!answered) _localKeyRefreshTried = false;
  }

  /// [_prepareDirect]'in en iyi çaba cihaz listesi isteğinin üst süresi (internet yokken LAN açılışı bekletilmez).
  static const Duration _directDevicesLimit = Duration(seconds: 4);

  Future<void> _prepareDirect() async {
    directApi.updateHost(_host);
    // Aktif evin pano kimliği bilinmiyorsa (doğrudan kipte açılış; kullanim-1) bulut cihaz listesi en iyi çabayla alınır:
    // anahtar o kimlikle depodan / sunucudan bulunur. Hata yutulur (internet yok: hatırlanan LAN panosu kullanılır).
    final home = _activeHome;
    if (isAuthenticated && home != null && _devices.isEmpty && capabilities.canViewState) {
      final epoch = _homeEpoch;
      try {
        final list = await clock.bound<List<DeviceInfo>?>(cloudApi.devices(home.id), _directDevicesLimit, () => null);
        if (list != null && epoch == _homeEpoch) _devices = list;
      } catch (_) {}
    }
    if (directApi.localKey == null) await _resolveLocalKey();
  }

  /// Aktif evin beklenen pano kimlikleri (kullanim-3): bulut cihaz listesi, hatırlanan LAN panosu ve personelin elle
  /// seçtiği cihaz. Boş küme = bilinmiyor (denetim yapılmaz).
  Set<String> _expectedLanUids() {
    final home = _activeHome;
    if (home == null) return const <String>{};
    final out = <String>{};
    for (final d in _devices) {
      final uid = QrClaimParser.normalizeUid(d.deviceUuid);
      if (uid != null) out.add(uid);
    }
    final remembered = _lanDeviceByHome[home.id];
    if (remembered != null) out.add(remembered);
    if (_selectedDeviceUuid.isNotEmpty) out.add(_selectedDeviceUuid.toUpperCase());
    return out;
  }

  static const String _lanBoardMismatch = 'Bu adresteki pano seçili daireye ait değil. Adresi kontrol edin.';

  // ---------------------------------------------------------------------------
  // Yenileme (snapshot)
  // ---------------------------------------------------------------------------

  /// Tek bir anlık görüntü alır: doğrudan modda cihaz durumu; bulutta evler (aktif ev yoksa) ve
  /// aktif evin uç noktaları/cihazları.
  Future<void> refresh({bool silent = false}) async {
    if (_isDisposed) return;
    if (_mode == AppMode.direct) {
      if (!silent) _resumeDirectPolling(); // kullanıcının "Yeniden dene"si / çekip bırak: yoklama sürer
      await _directRefresh(silent: silent);
    } else {
      await _cloudRefresh(silent: silent);
    }
  }

  Future<void> _cloudRefresh({required bool silent}) {
    final existing = _cloudRefreshFlight;
    if (existing != null) return existing;
    late final Future<void> future;
    future = _cloudRefreshImpl(silent).whenComplete(() {
      if (identical(_cloudRefreshFlight, future)) _cloudRefreshFlight = null;
    });
    _cloudRefreshFlight = future;
    return future;
  }

  Future<void> _cloudRefreshImpl(bool silent) async {
    if (!isAuthenticated) return;
    final home = _activeHome;
    if (home == null) {
      // Aktif ev yok: önce ev listesini al (eski kod burada hiçbir şey yapmıyordu).
      await fetchHomes();
      return;
    }
    if (home.isGuestExpiredAt(clock.now())) return;
    final caps = capabilities;
    if (!caps.canViewState) return;
    final epoch = _homeEpoch;
    if (!silent) _loadRetryCount = 0; // kullanıcı eylemi: yeni bir otomatik deneme zinciri

    // Yükleyiciler yalnız ALAN atar; TEK bildirim hepsi bittikten sonra gelir (PF-04: eskiden 4-5 bildirim).
    await Future.wait<void>([
      _loadEndpoints(home, epoch, silent: silent, notify: false),
      _loadDevices(home, epoch, notify: false),
      _loadChildLock(home, epoch, notify: false), // salt-okunur görüntüleme herkese (misafir dahil); değiştirme ayrıca kapılı
      if (caps.canChangeChildLock) _fetchPeace(notify: false),
    ]);
    if (epoch != _homeEpoch || _isDisposed) return; // ev değişti / çıkış: sonuç eski eve aitti
    _applyPresenceFallback();
    _invalidateViews();
    notifyListeners();
    _scheduleLoadRetry(epoch);
  }

  // PF-11: ilk yükleme başarısız kalırsa sınırlı otomatik yeniden deneme (2, 5, 15, 30 sn; en çok 4; sessiz).
  static const List<Duration> _loadRetryDelays = <Duration>[
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];
  Timer? _loadRetryTimer;
  int _loadRetryCount = 0;

  /// Cihaz listesi son denemede alınamadı (PF-11): yeniden denenir; çevrimiçilik uç noktalardan türetilebilir.
  bool _devicesFailed = false;

  /// Uç nokta listesi hiç yüklenemediyse ([endpointsError] ve [endpointsLoaded] false) ya da cihaz listesi
  /// alınamadıysa [_loadRetryDelays] kadar sonra sessiz yenileme planlar. Ev değişiminde, arka plana geçişte,
  /// çıkışta ve `dispose`'ta iptal olur.
  void _scheduleLoadRetry(int epoch) {
    _loadRetryTimer?.cancel();
    _loadRetryTimer = null;
    final needed = (_endpointsError != null && !_endpointsLoaded) || _devicesFailed;
    if (!needed) {
      _loadRetryCount = 0;
      return;
    }
    if (_isDisposed || _inBackground || epoch != _homeEpoch || _loadRetryCount >= _loadRetryDelays.length) return;
    final delay = _loadRetryDelays[_loadRetryCount++];
    _loadRetryTimer = clock.timer(delay, () {
      _loadRetryTimer = null;
      if (_isDisposed || _inBackground || epoch != _homeEpoch || _mode != AppMode.cloud) return;
      unawaited(refresh(silent: true));
    });
  }

  /// Cihaz listesi alınamadıysa (ya da boşsa) çevrimiçilik uç noktaların `device_online` bilgisinden türetilir
  /// ([_loadDevices] ile aynı kural: yalnız canlı kanal bağlı değilken ya da durum bilinmiyorken). Liste
  /// BAŞARIYLA geldiyse o esastır; canlı kanal bağlıyken canlı bilgi ezilmez.
  void _applyPresenceFallback() {
    if (!_devicesFailed && _devices.isNotEmpty) return;
    if (_presence != DevicePresence.unknown && brokerConnected) return;
    var known = false;
    var anyOnline = false;
    for (final endpoint in _cloudEndpoints) {
      final online = endpoint.deviceOnline;
      if (online == null) continue;
      known = true;
      if (online) anyOnline = true;
    }
    if (known) _presence = anyOnline ? DevicePresence.online : DevicePresence.offline;
  }

  /// [notify] `false` ise yalnız alan atar ([_cloudRefreshImpl] tek bildirim yapar). [reportError] `false` ise hata
  /// [endpointsError]'a yazılmaz (arka plandaki isteğe bağlı yerleşim yenilemesi, [_runLayoutRefresh]: son bilinen liste
  /// ekranda kalır, "Cihazlar güncellenemedi" şeridi çıkmaz); başarı yine hatayı temizler. [preferLive] `true` ise en son
  /// canlı anlık görüntü, istekten ÖNCE gelmiş olsa bile REST'in üzerine uygulanır: uç noktaların `current_state` /
  /// `current_position` değerini yalnız köprü canlı `state`'ten yazar ve veritabanı canlı iletinin milisaniyeler gerisinde
  /// kalabilir; canlı iletiyle tetiklenen yerleşim yenilemesi (anlık görüntü her zaman taze) kartı bu gecikmeli değerle
  /// geri çevirmez.
  Future<void> _loadEndpoints(
    HomeModel home,
    int epoch, {
    required bool silent,
    bool notify = true,
    bool reportError = true,
    bool preferLive = false,
  }) async {
    if (!silent) {
      _endpointsLoading = true;
      _endpointsError = null;
      notifyListeners();
    }
    final requestedAt = clock.now();
    try {
      final list = await cloudApi.fetchEndpoints(home.id);
      if (epoch != _homeEpoch) return;
      var next = list;
      // REST yanıtı beklenirken daha yeni bir canlı `state` geldiyse onu REST'in üzerine uygula.
      final live = _lastLiveSnapshot;
      final liveAt = _lastLiveSnapshotAt;
      if (live != null && liveAt != null && (preferLive || liveAt.isAfter(requestedAt))) {
        next = applyStatusToEndpoints(next, live).endpoints;
      }
      _cloudEndpoints = next;
      _invalidateViews();
      _endpointsLoaded = true;
      _endpointsError = null;
      // MQTT kopukken komut onayı REST yoklamasından da doğrulanabilir (yalnız bekleyen komut varsa: boşuna
      // `statusFromEndpoints` türetilmez).
      if (_pipeline.hasPending) _pipeline.observe(statusFromEndpoints(next));
    } on ApiException catch (e) {
      if (epoch != _homeEpoch) return;
      if (reportError && !e.isUnauthorized) _endpointsError = e.message;
    } catch (_) {
      if (reportError && epoch == _homeEpoch) _endpointsError = 'Cihazlar yüklenemedi. Lütfen tekrar deneyin.';
    } finally {
      if (epoch == _homeEpoch) {
        _endpointsLoading = false;
        _invalidateViews();
        if (notify) notifyListeners();
      }
    }
  }

  /// [notify] `false` ise yalnız alan atar ([_cloudRefreshImpl] tek bildirim yapar).
  Future<void> _loadDevices(HomeModel home, int epoch, {bool notify = true}) async {
    try {
      final list = await cloudApi.devices(home.id);
      if (epoch != _homeEpoch) return;
      _devices = list;
      _devicesFailed = false;
      if (_pruneSafetyForDevices(list)) {
        _invalidateViews();
        if (notify) notifyListeners();
      }
      // Canlı `status` kanalı yokken (veya henüz bilinmiyorsa) REST bilgisi kullanılır.
      if (list.isNotEmpty && (_presence == DevicePresence.unknown || !brokerConnected)) {
        _presence = list.any((d) => d.online) ? DevicePresence.online : DevicePresence.offline;
      }
      if (notify) notifyListeners();
    } on ApiException catch (e) {
      if (epoch == _homeEpoch) _devicesFailed = true;
      _log('Cihaz listesi alınamadı (${e.statusCode})');
    } catch (_) {
      if (epoch == _homeEpoch) _devicesFailed = true;
    }
  }

  /// Bulut cihaz listesi yenilenince evde artık olmayan panoların güvenlik durumu, alarm saati ve ad kopyası düşer
  /// (guvenlik-1): değiştirilen / çıkarılan panonun son (ya da retained) `state`'i oturum boyunca alarm kartı
  /// göstermez. Pano kimliği bilinmeyen (`''`) kayıt korunur. Bir şey silindiyse `true` (çağıran bildirir).
  bool _pruneSafetyForDevices(List<DeviceInfo> devices) {
    final known = <String>{for (final d in devices) d.deviceUuid.toUpperCase()};
    bool stale(String key) => key.isNotEmpty && !known.contains(key.toUpperCase());
    final before = _safetyByUid.length;
    _safetyByUid.removeWhere((key, _) => stale(key));
    _armClock.removeWhere((key, _) => stale(key));
    _safetyNames.removeWhere((key, _) => stale(key));
    _safetyNamesRetryAt.removeWhere((key, _) => stale(key));
    return _safetyByUid.length != before;
  }

  /// REST çocuk kilidi anlık görüntüsü. **Cihaz bildirimi esastır**: canlı kanal bağlıyken cihazdan
  /// değer biliniyorsa veya istek sırasında daha yeni bir cihaz bildirimi geldiyse REST sonucu
  /// uygulanmaz (bayat GET, daha yeni MQTT durumunu ezmesin). Hata/401/403/5xx durumunda değer
  /// "kapalı"ya DÖNMEZ: bilinmiyorsa bilinmiyor kalır.
  ///
  /// [notify] `false` ise yalnız alan atar ([_cloudRefreshImpl] tek bildirim yapar).
  Future<void> _loadChildLock(HomeModel home, int epoch, {bool notify = true}) async {
    final requestedAt = clock.now();
    try {
      final info = await cloudApi.fetchChildLockInfo(home.id);
      if (epoch != _homeEpoch) return;
      // Sunucudaki niyet ve çevrimdışı pano bilgisi gerçek durumu ezmez; ayrı alanlardır.
      _childLockRequested = info.requested;
      _childLockOfflineDevices = info.offlineDevices;
      final deviceAt = _childLockDeviceAt;
      final deviceNewer = deviceAt != null && deviceAt.isAfter(requestedAt);
      final deviceAuthoritative = brokerConnected && _childLockByUid.isNotEmpty;
      if (deviceNewer || deviceAuthoritative) {
        if (notify) notifyListeners();
        return;
      }
      if (!brokerConnected) {
        // Canlı kanal yok: önceden alınmış cihaz bildirimleri bayat olabilir (ör. başka telefondan
        // değişti); sunucunun pano bazlı özeti (`devices[]`) en taze bilgidir ve bayat değerlerin
        // yerine geçer. Kanal dönünce cihaz bildirimleri yine esas olur.
        _childLockByUid.clear();
        for (final device in info.devices) {
          _childLockByUid[device.deviceUuid] = device.enabled;
        }
      }
      _childLockRest = info.enabled;
      _childLockUpdatedAt = clock.now();
      if (notify) notifyListeners();
    } on ApiException catch (e) {
      _log('Çocuk kilidi okunamadı (${e.statusCode})');
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Gerçek zamanlı: MQTT (yalnızca abonelik)
  // ---------------------------------------------------------------------------

  void _bindMqtt() {
    _mqttLinkSub = mqttService.linkStates.listen((state) {
      _mqttLink = state;
      notifyListeners();
    });
    _mqttStateSub = mqttService.stateMessages.listen(_onDeviceState);
    _mqttStatusSub = mqttService.statusMessages.listen(_onDevicePresence);
  }

  /// Oturum kimliği döndürülürken (parola değişimi / sıfırlama, tüm cihazlardan çıkış) tamamlanacak gelecek
  /// (UYELIK-02). Sunucu bu işlemlerde kullanıcının TÜM uygulama MQTT kimliklerini (bu cihazınki dahil) silip
  /// bağlantıları atar ve eski erişim belirtecini geçersiz kılar. Atılan bağlantı yeniden kurulurken taze kimlik
  /// işlem yanıtı (yeni belirteçler) gelmeden ESKİ belirteçle istenirse 401 -> iptal edilmiş refresh -> yanlışlıkla
  /// oturum sonu yarışı olurdu: MQTT kimlik sağlayıcısı işlem bitene kadar bekler.
  Future<void>? _credentialRotation;

  Future<T> _duringCredentialRotation<T>(Future<T> Function() action) async {
    final done = Completer<void>();
    _credentialRotation = done.future;
    try {
      return await action();
    } finally {
      if (identical(_credentialRotation, done.future)) _credentialRotation = null;
      done.complete();
    }
  }

  Future<void> _startRealtime() async {
    if (_isDisposed || // dispose sırasında süren zincir sonradan MQTT bağlantısı kurmasın (PF-34)
        _mode != AppMode.cloud ||
        _activeHome == null ||
        !isAuthenticated ||
        _inBackground ||
        _awaitingUnlock) {
      return;
    }
    if (!capabilities.canViewState) return;
    final home = _activeHome!;
    final epoch = _homeEpoch;
    _realtimeEpoch = epoch;
    _realtimeStartedAt = clock.now();
    Future<MqttCredentials> fetchCredentials() {
      if (epoch != _homeEpoch) {
        throw const ApiException(statusCode: 404, code: 'STALE', message: 'Ev değişti.');
      }
      return cloudApi.mqttCredentials(home.id);
    }

    await mqttService.start(
      credentialsProvider: () {
        // Kimlik döndürme sürüyorsa yanıt beklenir (bkz. [_credentialRotation]); yoksa zamanlama aynen.
        final rotation = _credentialRotation;
        return rotation == null ? fetchCredentials() : rotation.then((_) => fetchCredentials());
      },
      installId: _installId,
      fallbackTopicId: home.mqttTopicId,
    );
  }

  void _onDeviceState(DeviceStateMessage message) {
    if (_isDisposed || _realtimeEpoch != _homeEpoch || _activeHome == null) return;
    _applyCloudSnapshot(message.status, retained: message.retained);
  }

  /// Cihaz çevrimiçilik (`status` konusu) iletisi.
  ///
  /// * `online` (canlı veya retained) -> çevrimiçi.
  /// * **canlı** `offline` (LWT / planlı yeniden başlatma) -> çevrimdışı (kesin).
  /// * **retained** `offline` tarihsel bir değerdir (eski LWT ya da QoS 0'da kaybolan "online"):
  ///   taze bir canlı `state` varsa yok sayılır; yoksa çevrimdışı kabul edilir ve ilk canlı `state`
  ///   ([_applyCloudSnapshot]) bunu düzeltir. Retained ileti hiçbir zaman cihazı **kalıcı**
  ///   çevrimdışı yapmaz.
  void _onDevicePresence(DevicePresenceMessage message) {
    if (_isDisposed || _realtimeEpoch != _homeEpoch || _activeHome == null) return;
    if (!message.online && message.retained && _hasFreshLiveState()) return;
    _presence = message.online ? DevicePresence.online : DevicePresence.offline;
    notifyListeners();
  }

  bool _hasFreshLiveState() {
    final at = _lastLiveStateAt;
    return at != null && clock.now().difference(at) <= _liveStateFreshness;
  }

  /// Cihaz `state` anlık görüntüsünü uç noktalara, panjur hareket bilgisine ve çocuk kilidine uygular;
  /// bekleyen komutları onaylar.
  ///
  /// Yalnız GÖRÜNÜR bir şey değiştiyse bildirir (PF-04): cihaz kalp atışı ~30 sn'de bir özdeş `state` yayınlar
  /// ve her ileti tüm arayüzü uyandırmamalıdır. Zaman damgaları (çocuk kilidi etiket saati, son canlı ileti)
  /// her iletide tazelenir ama bildirim üretmez. Bekleyen komutun onayı kendi bildirimini yapar.
  void _applyCloudSnapshot(DeviceStatus snapshot, {required bool retained}) {
    final sync = applyStatusToEndpoints(_cloudEndpoints, snapshot);
    var changed = sync.changed;
    if (sync.changed) {
      _cloudEndpoints = sync.endpoints;
    }
    for (final shutter in snapshot.shutters) {
      final known = _shutterRuntime[shutter.pair];
      final base = known ?? const ShutterRuntime();
      final differs = base.moving != shutter.isMoving ||
          base.direction != shutter.direction ||
          base.target != shutter.target;
      if (known == null || differs) {
        _shutterRuntime[shutter.pair] = ShutterRuntime(
          moving: shutter.isMoving,
          direction: shutter.direction,
          target: shutter.target,
        );
      }
      if (differs) changed = true;
    }
    if (snapshot.childLockKnown) {
      final uid = snapshot.uid ?? '';
      if (_childLockByUid[uid] != snapshot.childLock) {
        _childLockByUid[uid] = snapshot.childLock;
        changed = true;
      }
      _childLockDeviceAt = clock.now();
      _childLockUpdatedAt = _childLockDeviceAt; // "son bilinen" etiket saati bayat kalmasın (bildirimsiz)
    }
    if (snapshot.ip.isNotEmpty && snapshot.ip != _lastDeviceIp) {
      _lastDeviceIp = snapshot.ip;
      changed = true;
    }
    final safetyKey = snapshot.uid?.toUpperCase() ?? '';
    final safety = snapshot.safety;
    if ((safety.supported || _safetyByUid.containsKey(safetyKey)) && _safetyByUid[safetyKey] != safety) {
      _safetyByUid[safetyKey] = safety; // desteklenmeyen (eski yazılım) değer de yazılır: görünümden düşer
      changed = true;
    }
    if (safety.supported) _ensureSafetyNames(safetyKey, safety); // ad kopyası (cfg rev değişince)
    if (safety.arm != null) _armClock[safetyKey] = (uptime: snapshot.uptimeSec, at: clock.now());
    if (!retained) {
      // Canlı ileti = cihaz yaşıyor (retained "offline" status'u da düzeltilir). Saklı/retained
      // `state` çevrimiçiliği KANITLAMAZ.
      if (_presence != DevicePresence.online) {
        _presence = DevicePresence.online;
        changed = true;
      }
      _lastLiveStateAt = clock.now();
    }
    _lastLiveSnapshot = snapshot;
    _lastLiveSnapshotAt = clock.now();
    _pipeline.observe(snapshot);
    if (changed) {
      _invalidateViews();
      notifyListeners();
    }
    if (!retained) _watchEndpointLayout(snapshot); // bayat (retained) ileti yerleşim kararına esas olmaz
    if (_snapshotWaiters.isNotEmpty) {
      final waiters = List<Completer<void>>.of(_snapshotWaiters);
      _snapshotWaiters.clear();
      for (final w in waiters) {
        if (!w.isCompleted) w.complete();
      }
    }
  }

  /// Bildirim yönlendirmesi için (kullanim-2): [homeId] evinin güvenlik görünümü, canlı kanal (yeniden) başladıktan
  /// SONRA gelen bir `state` ile tazelendi mi? Tazelenmediyse ilk anlık görüntü en çok [timeout] beklenir; zaman
  /// aşımında ya da ev değişince `false` (çağıran "alarm kapanmış" diye karar VERMEMELİDİR). Doğrudan (LAN) kipte durum
  /// yoklamayla okunduğundan `true`.
  Future<bool> awaitFreshSafety({required String homeId, required Duration timeout}) async {
    if (_mode == AppMode.direct) return true;
    bool fresh() {
      final started = _realtimeStartedAt;
      final at = _lastLiveSnapshotAt;
      return !_isDisposed &&
          _mode == AppMode.cloud &&
          _activeHome?.id == homeId &&
          _realtimeEpoch == _homeEpoch &&
          started != null &&
          at != null &&
          !at.isBefore(started);
    }

    if (fresh()) return true;
    // Ev farklı ya da durum görme yetkisi yok (süresi dolmuş misafir): canlı kanal hiç kurulmaz, beklemek boşunadır.
    if (_isDisposed || _activeHome?.id != homeId || !capabilities.canViewState) return false;
    final epoch = _homeEpoch;
    final waiter = Completer<void>();
    _snapshotWaiters.add(waiter);
    final arrived = await clock.bound<bool>(waiter.future.then((_) => true), timeout, () => false);
    _snapshotWaiters.remove(waiter);
    if (!arrived || epoch != _homeEpoch) return false;
    return fresh();
  }

  /// Aktif evin sunucudaki AÇIK alarm kayıtları (kullanim-2: canlı durum gelmediyse alarmın kapandığını doğrulamak için).
  Future<List<AlarmRecord>> fetchOpenAlarms() async {
    final home = _activeHome;
    if (home == null) return const <AlarmRecord>[];
    return cloudApi.alarms(home.id, openOnly: true);
  }

  /// Doğrudan (LAN) kipte adresteki panonun [homeId] evine ait olduğu doğrulandı mı (kullanim-3): durum alınmış ve pano
  /// kimliği evin beklenen panolarından biri ([deviceUid] verilirse o pano). Kimlik/küme bilinmiyorsa `false`.
  bool lanBoardBelongsTo(String homeId, {String? deviceUid}) {
    if (_mode != AppMode.direct || _activeHome?.id != homeId) return false;
    final uid = _status?.uid?.toUpperCase();
    if (uid == null) return false;
    if (deviceUid != null && deviceUid.toUpperCase() != uid) return false;
    return _expectedLanUids().contains(uid);
  }

  // ---------------------------------------------------------------------------
  // Pano yerleşimi ↔ uç nokta listesi uyuşmazlığı: gecikmeli SESSİZ yenileme (WP-STATE2)
  // ---------------------------------------------------------------------------
  //
  // Sunucu köprüsü, panonun canlı `state`'indeki yerleşimi (röle türleri, panjur çiftleri, kanal sayısı) ~1 sn içinde
  // buluttaki uç noktalara eşitler (CONTRACTS §2.4b). Açık uygulamanın `_cloudEndpoints` listesi bunu kendiliğinden
  // görmez: ör. 5-6. kanallar panjur olunca ekranda eski lamba kartları kalır (sunucu panjur kanalına gelen röle
  // komutunu 400 ile reddeder; yine de kartlar yanıltıcıdır). Bu yüzden CANLI
  // `state`'in yerleşimi listeyle uyuşmuyorsa ([ReportedLayout.compareWith]) gecikmeli, sessiz TEK bir uç nokta
  // yüklemesi planlanır. Sınırlar:
  //
  // * Denetim yalnız hafif bir karşılaştırmadır (O(kanal)); özdeş kalp atışı hiçbir iş/bildirim üretmez (PF-04).
  // * Tek zamanlayıcı (debounce): bekleyen zamanlayıcı varken yenisi kurulmaz. Yerleşim imzası değişirse (pano yeniden
  //   ayarlandı) zamanlayıcı baştan, 2 sn'ye kurulur.
  // * Pano başına, aynı imza için en çok 3 deneme: 2 sn, +10 sn, +30 sn (sunucu eşitlemesi en geç bir kalp atışında,
  //   30 sn; küçülmede ikinci görüş için bir kalp atışı daha gerekir). Sonra imza DEĞİŞENE ya da uyuşma sağlanana
  //   kadar DURUR: ENDPOINT_LAYOUT_SYNC=off ya da sunucu hatasında sonsuz istek yoktur. Uyuşma sağlanınca ya da imza
  //   değişince o panonun sayacı sıfırlanır. Bir istek tüm panoları birlikte görür (deneme ortak harcanır).
  // * Bekleyen komut varken yenileme en çok 5 kez 1 sn ertelenir (deneme sayılmaz): komut onayı/iyimser değer REST
  //   gecikmesiyle (veritabanı ile canlı `state` arasındaki kısa fark) yarışmasın.
  // * Hareket/animasyon yok; yükleme göstergesi yok (`silent`); hata göstergesi yok; yalnız liste DEĞİŞTİYSE bildirir.
  // * Ev değişimi, arka plan, çıkış, mod değişimi ve `dispose` bekleyen zamanlayıcıyı iptal eder ([_resetLayoutRefresh]).

  /// Deneme gecikmeleri (her biri bir önceki denemenin SONUNDAN itibaren; ilk deneme uyuşmazlığın görüldüğü andan).
  static const List<Duration> _layoutRefreshDelays = <Duration>[
    Duration(seconds: 2),
    Duration(seconds: 10),
    Duration(seconds: 30),
  ];

  /// Bekleyen komut yüzünden erteleme adımı ve en çok erteleme sayısı.
  static const Duration _layoutRefreshBusyDelay = Duration(seconds: 1);
  static const int _layoutRefreshMaxBusyDeferrals = 5;

  Timer? _layoutRefreshTimer;
  bool _layoutRefreshInFlight = false;
  int _layoutRefreshBusyDeferrals = 0;

  /// Uyuşmayan yerleşimi olan panolar (anahtar: [ReportedLayout.device]).
  final Map<String, _LayoutWatch> _layoutWatches = <String, _LayoutWatch>{};

  /// Canlı bir `state`'in yerleşimini uç nokta listesiyle karşılaştırır; uyuşmazsa izlemeye alır ve yenileme planlar.
  void _watchEndpointLayout(DeviceStatus snapshot) {
    if (_isDisposed || _inBackground || _mode != AppMode.cloud || _activeHome == null || !_endpointsLoaded) return;
    if (!isAuthenticated) return; // oturum yokken (kilitli/çıkış) REST yapılamaz: izleme/zamanlayıcı kurulmaz
    final layout = ReportedLayout.from(snapshot);
    if (layout == null) return; // sunucunun da eşitlemeyeceği (kısıtlı / eksik / tutarsız) ileti: karar verilemez
    final verdict = layout.compareWith(_cloudEndpoints);
    if (verdict == EndpointLayoutVerdict.unknown) return;
    final watch = _layoutWatches[layout.device];
    if (verdict == EndpointLayoutVerdict.match) {
      if (watch == null) return;
      _layoutWatches.remove(layout.device); // uyuştu: bu panonun sayacı sıfırlandı
      if (_layoutWatches.isEmpty) _cancelLayoutRefreshTimer();
      return;
    }
    if (watch == null || watch.layout.signature != layout.signature) {
      _layoutWatches[layout.device] = _LayoutWatch(layout); // yeni ya da değişen yerleşim: deneme sayacı sıfırdan
      _scheduleLayoutRefresh(restart: true);
    } else {
      _scheduleLayoutRefresh(); // aynı imza (kalp atışı): zamanlayıcı varsa dokunulmaz
    }
  }

  void _cancelLayoutRefreshTimer() {
    _layoutRefreshTimer?.cancel();
    _layoutRefreshTimer = null;
    _layoutRefreshBusyDeferrals = 0;
  }

  /// İzlemeyi ve bekleyen zamanlayıcıyı bırakır (ev değişimi, arka plan, çıkış, mod değişimi, `dispose`). Uçuştaki
  /// istek bitince sonucu kendi başına işler ([_runLayoutRefresh]); yeni zamanlayıcı kurmaz.
  void _resetLayoutRefresh() {
    _cancelLayoutRefreshTimer();
    _layoutWatches.clear();
  }

  /// Deneme hakkı kalan izleme varsa zamanlayıcıyı kurar. Uçuşta istek varken ya da (restart yoksa) zamanlayıcı
  /// bekliyorken hiçbir şey yapmaz (debounce).
  void _scheduleLayoutRefresh({bool restart = false}) {
    if (_isDisposed || _inBackground || _mode != AppMode.cloud || _activeHome == null) return;
    if (_layoutRefreshInFlight) return;
    if (_layoutRefreshTimer != null && !restart) return;
    int? attempts;
    for (final watch in _layoutWatches.values) {
      if (watch.attempts >= _layoutRefreshDelays.length) continue;
      if (attempts == null || watch.attempts < attempts) attempts = watch.attempts;
    }
    if (attempts == null) return; // tüm izlemelerin denemesi doldu: imza değişene / uyuşana kadar durur
    _layoutRefreshBusyDeferrals = 0;
    _armLayoutRefresh(_layoutRefreshDelays[attempts]);
  }

  void _armLayoutRefresh(Duration delay) {
    _layoutRefreshTimer?.cancel();
    final epoch = _homeEpoch;
    _layoutRefreshTimer = clock.timer(delay, () {
      _layoutRefreshTimer = null;
      unawaited(_runLayoutRefresh(epoch));
    });
  }

  /// Liste bu arada başka yoldan yenilendiyse (çekip yenile, komut sonrası uzlaşma...) uyuşan izlemeleri bırakır.
  void _pruneLayoutWatches() {
    _layoutWatches.removeWhere((_, watch) => watch.layout.compareWith(_cloudEndpoints) != EndpointLayoutVerdict.mismatch);
  }

  /// Zamanlayıcı tetiklendi: uyuşmazlık sürüyorsa uç noktaları SESSİZCE yeniden yükler, sonra yeniden değerlendirir.
  Future<void> _runLayoutRefresh(int epoch) async {
    final home = _activeHome;
    if (_isDisposed || _inBackground || epoch != _homeEpoch || _mode != AppMode.cloud || home == null) return;
    // Oturum/yetki arada kaybolduysa REST yapılmaz (canlı iletiler koşullar dönünce izlemeyi yeniden kurar).
    if (!isAuthenticated || home.isGuestExpiredAt(clock.now()) || !capabilities.canViewState) return;
    _pruneLayoutWatches();
    if (_layoutWatches.isEmpty) return; // artık uyuşuyor: istek yok
    if (_pipeline.hasPending && _layoutRefreshBusyDeferrals < _layoutRefreshMaxBusyDeferrals) {
      _layoutRefreshBusyDeferrals++;
      _armLayoutRefresh(_layoutRefreshBusyDelay);
      return;
    }
    _layoutRefreshBusyDeferrals = 0;
    for (final watch in _layoutWatches.values) {
      watch.attempts++; // tek istek tüm uyuşmayan panolar için denemedir
    }
    _layoutRefreshInFlight = true;
    try {
      final flight = _cloudRefreshFlight;
      if (flight != null) {
        await flight; // tam yenileme zaten uç noktaları yüklüyor: paralel ikinci istek açılmaz
      } else {
        final before = _cloudEndpoints;
        final hadError = _endpointsError != null;
        await _loadEndpoints(home, epoch, silent: true, notify: false, reportError: false, preferLive: true);
        final cleared = hadError && _endpointsError == null;
        if (!_isDisposed && epoch == _homeEpoch && (cleared || !sameEndpointList(before, _cloudEndpoints))) {
          notifyListeners(); // yalnız görünür bir şey değiştiyse (liste ya da kaybolan hata şeridi)
        }
      }
    } catch (_) {
      // Sessiz: hata kullanıcıya yansıtılmaz; deneme hakkı kaldıysa sonraki deneme yeniden dener.
    } finally {
      _layoutRefreshInFlight = false;
    }
    if (_isDisposed || epoch != _homeEpoch) return;
    _pruneLayoutWatches();
    _scheduleLayoutRefresh();
  }

  // ---------------------------------------------------------------------------
  // Doğrudan (LAN) mod: tek-uçuşlu yoklama
  // ---------------------------------------------------------------------------

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (_isDisposed || _inBackground || _mode != AppMode.direct) return;
    _resumeDirectPolling(); // mod değişimi / ön plana dönüş: kalıcı durdurma ve 423 beklemesi kalkar
    _pollTimer = clock.periodic(_directPollInterval, (_) {
      if (_isDisposed || _mode != AppMode.direct || _inBackground || _pollHalted) return;
      final notBefore = _pollNotBefore;
      if (notBefore != null && clock.now().isBefore(notBefore)) return; // 423: Retry-After dolana kadar yoklanmaz
      unawaited(_directRefresh(silent: true)); // engeli (süresi dolmuş) isteğin kendisi kaldırır ya da yeniler
    });
  }

  /// 423 `Retry-After` için üst sınır: cihaz (firmware) 60 sn kilitler; hatalı/abartılı bir değer yoklamayı saatlerce
  /// susturmasın.
  static const Duration _maxLockWait = Duration(minutes: 5);

  /// LAN yoklamasının kalıcı durdurmasını ve 423 beklemesini kaldırır (kullanıcı eylemi, ön plana dönüş,
  /// yeni adres/anahtar). Yalnızca yoklama kapısını açar; isteği çağıran atar.
  void _resumeDirectPolling() {
    _pollHalted = false;
    _pollNotBefore = null;
  }

  /// Aynı anda yalnızca **bir** istek uçuşta olur; ardışık 3 hata sonrası cihaz çevrimdışı sayılır
  /// (kullanıcı tetiklemeli yenilemede ilk hatada). Uçuş, başlatıldığı adres + anahtar için geçerlidir:
  /// ikisinden biri değiştiyse eski uçuş devralınmaz (yenisi ayrı başlar) ve eski uçuşun sonucu atılır.
  Future<void> _directRefresh({required bool silent}) {
    final base = directApi.baseUrl;
    final key = directApi.localKey;
    final existing = _pollInFlight;
    if (existing != null && base == _pollFlightBase && key == _pollFlightKey) return existing;
    late final Future<void> future;
    future = _directRefreshImpl(silent, base, key).whenComplete(() {
      if (identical(_pollInFlight, future)) _pollInFlight = null;
    });
    _pollInFlight = future;
    _pollFlightBase = base;
    _pollFlightKey = key;
    return future;
  }

  Future<void> _directRefreshImpl(bool silent, String base, String? key) async {
    if (!directApi.isConfigured) {
      final changed = _connState != ConnectionStateEnum.offline || _directError == null;
      _connState = ConnectionStateEnum.offline;
      _directError = 'Cihaz adresi ayarlanmadı.';
      if (changed) notifyListeners();
      return;
    }
    final epoch = _homeEpoch;
    final beforeConn = _connState;
    final beforeError = _directError;
    // Yoklama engeli (423) bu isteğin başında kalkar; yine 423 gelirse yeni zamanla yeniden kurulur. Görünen engel
    // zamanı değiştiyse (ör. kilit yenilendi) arayüz de bilgilendirilir: bayat "şu ana kadar kilitli" görmez.
    final blockedBefore = _pollNotBefore;
    _pollNotBefore = null;
    var changed = false;
    // Uçuş sırasında adres/anahtar değiştiyse sonuç eski hedefe aittir: atılır (yenisi ayrı uçuştadır).
    bool stale() => base != directApi.baseUrl || key != directApi.localKey;
    try {
      final st = await directApi.fetchStatus();
      if (epoch != _homeEpoch || _mode != AppMode.direct || stale()) return;
      final previous = _status;
      final lanUid = st.uid?.toUpperCase();
      if (lanUid != null) _lastLanUid = lanUid;
      final expected = _expectedLanUids();
      if (lanUid != null && expected.isNotEmpty && !expected.contains(lanUid)) {
        // Adresteki pano seçili daireye ait değil (kullanim-3): başka evin panosu gösterilmez/kontrol edilmez. Durum yok:
        // komutlar reddedilir; komut hattı bu panonun durumunu gözlemez. Kullanıcı adresi düzeltene dek yoklama durur.
        changed = previous != null;
        _directFailures = 0;
        _status = null;
        _invalidateViews();
        _connState = ConnectionStateEnum.connected;
        _directError = _lanBoardMismatch;
        _pollHalted = true;
      } else if (st.restricted) {
        // Anahtarsız kısıtlı özet: cihaza ulaşıldı ama kontrol edilemez ("boş cihaz" sanılmaz).
        changed = previous != null;
        _directFailures = 0;
        _status = null;
        _invalidateViews();
        _connState = ConnectionStateEnum.connected;
        // Hazırlanmamış pano: servis rolü olmayan kullanıcı sihirbazı açamaz; satıcı / servis yönlendirmesi (bireysel-13).
        final serviceRole = isAuthenticated && (isServiceSession || isServiceUser || isSuperUser);
        final message = st.provisioned == false
            ? (serviceRole ? 'Cihaz henüz kurulmamış. Servis kurulumunu tamamlayın.' : kUnprovisionedBoardUserMessage)
            : 'Cihaz anahtarı gerekli. Anahtarı girin veya hesabınızla giriş yapın.';
        _directError = message;
        if (st.provisioned != false && !_localKeyRefreshTried && isAuthenticated) {
          await _refreshLocalKeyOnce();
          if (epoch != _homeEpoch) return;
          _directError = message; // bulut hatası cihazın mesajını ezmesin
        }
        // Anahtar hâlâ yok: kullanıcı anahtarı girene / "Yeniden dene"ye basana dek yoklama yok.
        if (!hasLocalKey) _pollHalted = true;
      } else {
        // Telemetri (uptime/RSSI) `sameAs`'ta yok sayılır; kartı dondurmamak için kaba eşikle bildirilir.
        final telemetryMoved = (st.uptimeSec - _telemetryUptimeSec).abs() >= 60 ||
            (st.wifiStaRssi - _telemetryRssi).abs() >= 10;
        changed = previous == null || !previous.sameAs(st) || telemetryMoved;
        if (changed) {
          _telemetryUptimeSec = st.uptimeSec;
          _telemetryRssi = st.wifiStaRssi;
        }
        _directFailures = 0;
        _directError = null;
        _resumeDirectPolling(); // anahtar çalışıyor: durdurma / 423 beklemesi yok
        _status = st;
        _invalidateViews();
        if (st.safety.supported) _ensureSafetyNames(st.uid ?? st.safety.deviceUid ?? '_lan', st.safety);
        if (st.safety.arm != null) {
          _armClock[st.uid ?? st.safety.deviceUid ?? '_lan'] = (uptime: st.uptimeSec, at: clock.now());
        }
        if (st.childLockKnown) {
          _childLockByUid['_lan'] = st.childLock;
          _childLockDeviceAt = clock.now();
          _childLockUpdatedAt = _childLockDeviceAt; // bildirimsiz: "son bilinen" saati her yoklamada taze
        }
        if (st.ip.isNotEmpty) _lastDeviceIp = st.ip;
        _connState = ConnectionStateEnum.connected;
        _pipeline.observe(st);
      }
    } on LocalApiException catch (e) {
      if (epoch != _homeEpoch || stale()) return;
      if (e.isUnauthorized || e.isUnprovisioned) {
        // Cihaza ulaşıldı ama anahtar geçersiz/yok: bir kez sunucudan yeniden al.
        _directError = e.message;
        _directFailures = 0;
        final keyBefore = directApi.localKey;
        if (!_localKeyRefreshTried && isAuthenticated) {
          await _refreshLocalKeyOnce();
          if (epoch != _homeEpoch) return;
        }
        if (directApi.localKey == keyBefore) {
          // Anahtar değişmedi (yenilenemedi ya da sunucudaki de aynı): cihazı bayat anahtarla yormadan DUR
          // (5 hatalı deneme cihazı 60 sn kilitler). Cihaza ulaşıldı: çevrimdışı DEĞİL, ama kontrol edilemez.
          changed = _status != null;
          _status = null;
          _invalidateViews();
          _connState = ConnectionStateEnum.connected;
          _directError = e.message; // bulut hatası cihazın mesajını ezmesin
          _pollHalted = true;
        }
      } else if (e.isLocked) {
        // Cihaz çok sayıda hatalı denemeyle kilitlendi (423): ulaşıldı; Retry-After (+1 sn) dolana kadar yoklanmaz.
        changed = _status != null;
        _directFailures = 0;
        _status = null;
        _invalidateViews();
        _connState = ConnectionStateEnum.connected;
        _directError = e.message;
        final wait = e.retryAfter ?? const Duration(seconds: 60);
        _pollNotBefore = clock.now().add((wait > _maxLockWait ? _maxLockWait : wait) + const Duration(seconds: 1));
      } else {
        _directFailures++;
        if (!silent || _directFailures >= 3) _connState = ConnectionStateEnum.offline;
        _directError = e.message;
      }
    } catch (_) {
      if (epoch != _homeEpoch || stale()) return;
      _directFailures++;
      if (!silent || _directFailures >= 3) _connState = ConnectionStateEnum.offline;
    }
    if (epoch == _homeEpoch) {
      // Değişim yoksa bildirme: her 1.5 sn yoklamada tüm arayüz yeniden çizilmesin.
      if (changed || _connState != beforeConn || _directError != beforeError || _pollNotBefore != blockedBefore) {
        _invalidateViews();
        notifyListeners();
      }
    }
  }

  void _pollSoon() {
    _reconcileTimer?.cancel();
    if (_isDisposed) return; // komut yanıtı dispose'tan sonra dönebilir (PF-34)
    _reconcileTimer = clock.timer(const Duration(milliseconds: 250), () {
      if (!_isDisposed && _mode == AppMode.direct && !_inBackground) unawaited(_directRefresh(silent: true));
    });
  }

  /// MQTT kopukken (iyimser değer onay penceresinde) REST ile gerçek durumu yeniden oku.
  void _scheduleReconcile() {
    _reconcileTimer?.cancel();
    if (_isDisposed) return; // PF-34
    _reconcileTimer = clock.timer(const Duration(milliseconds: 900), () {
      if (_isDisposed || _inBackground) return;
      if (_mode == AppMode.cloud) {
        unawaited(refresh(silent: true));
      } else {
        unawaited(_directRefresh(silent: true));
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Görünüm: gerçek durum + bekleyen (iyimser) komutlar
  // ---------------------------------------------------------------------------

  /// Görünüm girdileri (uç noktalar, canlı panjur durumu, LAN durumu, bekleyen komutlar) değişti: türetilmiş
  /// değerler ([cloudEndpoints], [relayItems], [shutterItems], [status]) bir sonraki erişimde yeniden kurulur
  /// (PF-20). Bu girdileri değiştiren HER yer, bildirimden ÖNCE bunu çağırmalıdır.
  void _invalidateViews() {
    _endpointView = null;
    _viewGen++;
  }

  void _onPipelineChanged() {
    _invalidateViews();
    notifyListeners();
  }

  List<EndpointModel> _computeEndpointView() {
    if (!_pipeline.hasPending) return _cloudEndpoints;
    return <EndpointModel>[
      for (final endpoint in _cloudEndpoints) _overlayEndpoint(endpoint),
    ];
  }

  EndpointModel _overlayEndpoint(EndpointModel endpoint) {
    if (endpoint.isShutter) {
      final target = _pipeline.pendingFor('shutter:${endpoint.pair}')?.target;
      if (target is _ShutterTarget && target.pos != null) {
        return endpoint.copyWith(shutterPosition: target.pos);
      }
      return endpoint;
    }
    final target = _pipeline.pendingFor('relay:${endpoint.channel}')?.target;
    return target is bool ? endpoint.copyWith(currentState: target) : endpoint;
  }

  Map<int, ShutterRuntime> _runtimeView() {
    if (!_pipeline.hasPending) return _shutterRuntime;
    final merged = Map<int, ShutterRuntime>.of(_shutterRuntime);
    for (final pending in _pipeline.pending) {
      final target = pending.target;
      if (!pending.key.startsWith('shutter:') || target is! _ShutterTarget) continue;
      final pair = int.tryParse(pending.key.substring('shutter:'.length));
      if (pair == null) continue;
      if (target.moving != null || target.direction != null) {
        final base = merged[pair] ?? const ShutterRuntime();
        merged[pair] = ShutterRuntime(
          moving: target.moving ?? base.moving,
          direction: target.direction ?? base.direction,
          target: target.pos ?? base.target,
        );
      }
    }
    return merged;
  }

  DeviceStatus? _viewStatus() {
    final base = _status;
    if (base == null || !_pipeline.hasPending) return base;
    final relays = <RelayItem>[
      for (final relay in base.relays)
        () {
          final target = _pipeline.pendingFor('relay:${relay.id}')?.target;
          return target is bool ? relay.copyWith(state: target) : relay;
        }(),
    ];
    final shutters = <ShutterItem>[
      for (final shutter in base.shutters)
        () {
          final target = _pipeline.pendingFor('shutter:${shutter.pair}')?.target;
          if (target is! _ShutterTarget) return shutter;
          return shutter.copyWith(
            pos: target.pos,
            isMoving: target.moving,
            direction: target.direction,
          );
        }(),
    ];
    final lock = _pipeline.pendingFor('childLock')?.target;
    return base.copyWith(
      relays: relays,
      shutters: shutters,
      childLock: lock is bool ? lock : null,
    );
  }

  // ---------------------------------------------------------------------------
  // Komutlar (REST -> komut hattı; doğrudan modda LAN -> komut hattı)
  // ---------------------------------------------------------------------------

  bool _controlAllowed({String key = 'control'}) {
    if (capabilities.canControlDevices) return true;
    _pipeline.emitFailure(CommandFailure(
      key: key,
      reason: CommandFailureReason.forbidden,
      message: 'Bu işlem için yetkiniz yok.',
    ));
    return false;
  }

  void _reject(
    String key,
    String message, {
    CommandFailureReason reason = CommandFailureReason.rejected,
    String? code,
  }) {
    _pipeline.emitFailure(CommandFailure(key: key, reason: reason, message: message, code: code));
  }

  /// Komutun onay politikası: canlı `state` kanalı varsa cihaz onayı beklenir; bulutta kanal
  /// kopukken iyimser değer onay penceresi boyunca tutulur (hata göstermeden bırakılır).
  CommandConfirmMode get _stateConfirmMode =>
      (_mode == AppMode.cloud && !brokerConnected) ? CommandConfirmMode.settle : CommandConfirmMode.state;

  String? _primaryDeviceRef() {
    if (_devices.isNotEmpty) {
      final online = _devices.where((d) => d.online);
      return (online.isNotEmpty ? online.first : _devices.first).deviceUuid;
    }
    for (final endpoint in _cloudEndpoints) {
      final ref = endpoint.deviceUuid ?? endpoint.deviceId;
      if (ref != null) return ref;
    }
    return null;
  }

  Future<CommandDispatch> _submit({
    required String key,
    required Object? original,
    required Object? target,
    required Future<CommandResult> Function(String commandId) send,
    ConfirmPredicate? confirms,
    CommandConfirmMode? mode,
    String? targetUid,
  }) async {
    final effective = mode ?? _stateConfirmMode;
    final dispatch = await _pipeline.submit(
      targetUid: targetUid,
      key: key,
      original: original,
      target: target,
      send: (id) async {
        final result = await send(id);
        if (_mode == AppMode.direct) _pollSoon();
        return result;
      },
      confirms: confirms,
      mode: effective,
    );
    if (dispatch.ok && effective != CommandConfirmMode.state) _scheduleReconcile();
    return dispatch;
  }

  Future<bool> _dispatch({
    required String key,
    required Object? original,
    required Object? target,
    required Future<CommandResult> Function(String commandId) send,
    ConfirmPredicate? confirms,
    CommandConfirmMode? mode,
    String? targetUid,
  }) async =>
      (await _submit(
        key: key,
        original: original,
        target: target,
        send: send,
        confirms: confirms,
        mode: mode,
        targetUid: targetUid,
      ))
          .ok;

  EndpointModel? _relayEndpoint(int channel) {
    for (final endpoint in cloudEndpoints) {
      if (!endpoint.isShutter && endpoint.channel == channel) return endpoint;
    }
    return null;
  }

  EndpointModel? _shutterEndpoint(int pair) {
    for (final endpoint in primaryShutterEndpoints(cloudEndpoints)) {
      if (endpoint.pair == pair) return endpoint;
    }
    return null;
  }

  /// Röle durumunu açıkça ayarlar (`{"relay": N, "state": bool}`; idempotent).
  /// Dönen değer: komut iletildi mi (cihaz onayı ve olası geri alma [commandFailures] ile bildirilir).
  Future<bool> setRelay(int channel, bool on) async {
    final key = 'relay:$channel';
    if (channel < 1) {
      _reject(key, 'Geçersiz röle numarası.', reason: CommandFailureReason.validation);
      return false;
    }
    if (!_controlAllowed(key: key)) return false;
    if (_rejectIfActuatorChannel(key, channel)) return false;

    if (_mode == AppMode.direct) {
      final relay = status?.relayById(channel);
      if (relay == null) {
        _reject(key, 'Röle bulunamadı.');
        return false;
      }
      return _dispatch(
        key: key,
        original: relay.state,
        target: on,
        send: (_) async {
          await directApi.setRelay(channel, on);
          return CommandResult.accepted;
        },
        confirms: CommandConfirm.relay(channel, on),
      );
    }

    final home = _activeHome;
    final endpoint = _relayEndpoint(channel);
    final ref = endpoint == null ? null : (endpoint.deviceUuid ?? endpoint.deviceId ?? _primaryDeviceRef());
    if (home == null || endpoint == null || ref == null) {
      _reject(key, 'Kontrol noktası bulunamadı.');
      return false;
    }
    return _dispatch(
      key: key,
      original: endpoint.currentState,
      target: on,
      targetUid: endpoint.deviceUuid,
      send: (id) => cloudApi.sendCommand(
        homeId: home.id,
        deviceId: ref,
        command: <String, dynamic>{'relay': channel, 'state': on, 'id': id},
      ),
      confirms: CommandConfirm.relay(channel, on),
    );
  }

  /// Rölenin görünen durumunu tersine çevirir (`state` açıkça gönderilir; `toggle` değil).
  Future<bool> toggleRelay(int channel) {
    final current = _mode == AppMode.direct
        ? status?.relayById(channel)?.state
        : _relayEndpoint(channel)?.currentState;
    return setRelay(channel, !(current ?? false));
  }

  /// Darbe/tetik rölesi: iletim başarılıysa tamamlanır (iyimser değer yok).
  Future<bool> triggerImpulse(int channel) async {
    final key = 'impulse:$channel';
    if (channel < 1) {
      _reject(key, 'Geçersiz röle numarası.', reason: CommandFailureReason.validation);
      return false;
    }
    if (!_controlAllowed(key: key)) return false;
    if (_rejectIfActuatorChannel(key, channel)) return false;
    if (_mode == AppMode.direct) {
      return _dispatch(
        key: key,
        original: null,
        target: null,
        mode: CommandConfirmMode.delivery,
        send: (_) async {
          await directApi.triggerImpulse(channel);
          return CommandResult.accepted;
        },
      );
    }
    final home = _activeHome;
    final endpoint = _relayEndpoint(channel);
    final ref = endpoint == null ? null : (endpoint.deviceUuid ?? endpoint.deviceId ?? _primaryDeviceRef());
    if (home == null || endpoint == null || ref == null) {
      _reject(key, 'Kontrol noktası bulunamadı.');
      return false;
    }
    return _dispatch(
      key: key,
      original: null,
      target: null,
      mode: CommandConfirmMode.delivery,
      targetUid: endpoint.deviceUuid,
      send: (id) => cloudApi.sendCommand(
        homeId: home.id,
        deviceId: ref,
        command: <String, dynamic>{'relay': channel, 'state': true, 'id': id},
      ),
    );
  }

  /// Panjur konumu (0 = kapalı, 100 = açık). [pair] **1 tabanlıdır**. Aralık dışı değer reddedilir
  /// (sessizce kırpılmaz).
  Future<bool> setShutterPosition(int pair, int percent) async {
    final key = 'shutter:$pair';
    if (pair < 1) {
      _reject(key, 'Geçersiz panjur numarası.', reason: CommandFailureReason.validation);
      return false;
    }
    if (percent < 0 || percent > 100) {
      _reject(key, 'Panjur konumu 0 ile 100 arasında olmalıdır.', reason: CommandFailureReason.validation);
      return false;
    }
    if (!_controlAllowed(key: key)) return false;
    final original = getShutterPosition(pair);

    if (_mode == AppMode.direct) {
      if (status?.shutterByPair(pair) == null) {
        _reject(key, 'Panjur bulunamadı.');
        return false;
      }
      return _dispatch(
        key: key,
        original: original,
        target: _ShutterTarget(pos: percent),
        send: (_) async {
          await directApi.cmdShutter(pair, 'pos', value: percent);
          return CommandResult.accepted;
        },
        confirms: CommandConfirm.shutterPosition(pair, percent),
      );
    }

    final home = _activeHome;
    final endpoint = _shutterEndpoint(pair);
    final ref = endpoint == null ? null : (endpoint.deviceUuid ?? endpoint.deviceId ?? _primaryDeviceRef());
    if (home == null || endpoint == null || ref == null) {
      _reject(key, 'Panjur bulunamadı.');
      return false;
    }
    return _dispatch(
      key: key,
      original: original,
      target: _ShutterTarget(pos: percent),
      targetUid: endpoint.deviceUuid,
      send: (id) => cloudApi.sendCommand(
        homeId: home.id,
        deviceId: ref,
        command: <String, dynamic>{'shutter': pair, 'pos': percent, 'id': id},
      ),
      confirms: CommandConfirm.shutterPosition(pair, percent),
    );
  }

  // ---------------------------------------------------------------------------
  // Güvenlik modülü: durum (tasarım §5.3.2) ve komutlar (vana / siren / fan / alarm onayı / bölge testi)
  // ---------------------------------------------------------------------------
  //
  // İyimser arayüz kuralı (güvenlik): yalnız GÜVENLİ yön iyimser gösterilir. Vanayı kapatmak ve sireni/fanı kapatmak
  // anında görünür (ret/zaman aşımında geri alınır); vanayı AÇMAK, sireni/fanı AÇMAK ve alarm onayı panonun `state`
  // onayına kadar gerçek değerde kalır (yalnız "uygulanıyor" göstergesi: [isActuatorPending], [isAlarmAckPending]).
  // Gerekçe: kullanıcı açık görünen bir vanaya güvenip evden çıkmamalı; ret (`last_rej`) ANINDA geri alınır.

  /// Güvenlik durumu, pano (`uid`) başına; yalnız güvenlik destekleyen panolar. Doğrudan (LAN) kipte tek pano.
  /// Adlar uç nokta / röle adlarından (kanal eşlemesi) doldurulur [B12]; bekleyen güvenli-yön komutları yansıtılır.
  /// Girdiler değişmedikçe AYNI harita döner (PF-20).
  Map<String, SafetyState> get safetyByDevice {
    final cached = _safetyMemo;
    if (cached != null && _safetyGen == _viewGen && _safetyMode == _mode) return cached;
    final out = <String, SafetyState>{};
    if (_mode == AppMode.direct) {
      final st = _status;
      if (st != null && st.safety.supported) {
        final key = st.uid ?? st.safety.deviceUid ?? '_lan';
        _ensureSafetyNames(key, st.safety);
        out[key] = _decorateSafety(st.safety, key);
      }
    } else {
      for (final entry in _safetyByUid.entries) {
        if (!entry.value.supported) continue;
        _ensureSafetyNames(entry.key, entry.value);
        out[entry.key] = _decorateSafety(entry.value, entry.key);
      }
    }
    final view = Map<String, SafetyState>.unmodifiable(out);
    _safetyMemo = view;
    _safetyGen = _viewGen;
    _safetyMode = _mode;
    return view;
  }

  /// Birincil (tek panolu evde tek) güvenlik durumu: etkin alarmı olan pano önceliklidir. Hiçbir pano güvenlik
  /// desteklemiyorsa (ya da henüz `state` gelmediyse) [SafetyState.unsupported]: güvenlik bölümü gizlenir.
  SafetyState get safety {
    final all = safetyByDevice.values;
    if (all.isEmpty) return SafetyState.unsupported;
    for (final s in all) {
      if (s.hasActiveAlarm) return s;
    }
    return all.first;
  }

  /// Bütün panoların normal olmayan bölgeleri (alarm, arıza, test); [AlarmItem.deviceUid] damgalı.
  List<AlarmItem> get alarmItems => <AlarmItem>[for (final s in safetyByDevice.values) ...s.alarms];

  /// Bütün panoların eylemcileri (iyimser güvenli-yön değerleriyle).
  List<ActuatorItem> get actuatorItems => <ActuatorItem>[for (final s in safetyByDevice.values) ...s.actuators];

  List<SensorItem> get sensorItems => <SensorItem>[for (final s in safetyByDevice.values) ...s.sensors];

  /// Evde (herhangi bir panoda) kilitli gaz alarmı sürüyor (Faz 2 F2.A.4): arayüz lamba/priz/panjur komutundan ve
  /// hızlı senaryodan önce "elektrik anahtarlamak kıvılcım oluşturabilir" onayı ister. Komut engellenmez.
  bool get hasOpenGasAlarm => alarmItems.any((a) => a.isActive && a.kind == 'gas');

  /// Yapılandırma kopyasındaki adlar [_safetyNames] (eylemci adı yoksa röle kanalının uç nokta / röle adı) ve bekleyen
  /// güvenli-yön komutları.
  SafetyState _decorateSafety(SafetyState base, String key) {
    final cfg = _safetyNames[key];
    final names = <String, String>{};
    for (final a in base.actuators) {
      final name = cfg?.actuators[a.id] ?? _actuatorName(a);
      if (name != null) names[a.id] = name;
    }
    final sensorNames = cfg?.sensors ?? const <String, String>{};
    final exproof = cfg?.exproof ?? const <String>{};
    final sensorFlags = cfg?.sensorFlags ?? const <String, int>{};
    var out = (names.isEmpty && sensorNames.isEmpty && exproof.isEmpty && sensorFlags.isEmpty)
        ? base
        : base.withNames(actuators: names, sensors: sensorNames, exproof: exproof, sensorFlags: sensorFlags);
    if (_pipeline.hasPending) {
      var touched = false;
      final actuators = <ActuatorItem>[
        for (final a in out.actuators)
          () {
            final target = _pipeline.pendingFor(_actuatorKey(a))?.target;
            if (target is! _ActuatorTarget) return a;
            touched = true;
            return a.copyWith(pos: target.pos, on: target.on);
          }(),
      ];
      if (touched) {
        out = SafetyState(
          supported: out.supported,
          configured: out.configured,
          policy: out.policy,
          safeMode: out.safeMode,
          caps: out.caps,
          sensors: out.sensors,
          alarms: out.alarms,
          actuators: List<ActuatorItem>.unmodifiable(actuators),
          zones: out.zones,
          lastRej: out.lastRej,
          deviceUid: out.deviceUid,
          cfgRev: out.cfgRev,
          cfgCrc: out.cfgCrc,
          arm: out.arm,
        );
      }
    }
    return out;
  }

  /// Ad kopyası bu yapılandırmaya (`cfg.safety.rev/crc`) ait değilse arka planda okur (pano başına tek uçuş; hata ya da
  /// henüz eski bulut kopyasında 60 sn sonra yeniden). Yapılandırılmamış panoda (rev yok) hiçbir şey yapmaz.
  void _ensureSafetyNames(String key, SafetyState state) {
    if (!state.supported || !state.configured || state.cfgRev == null) return;
    final cached = _safetyNames[key];
    if (cached != null && cached.matches(state)) return;
    if (_safetyNamesInFlight.contains(key)) return;
    final retryAt = _safetyNamesRetryAt[key];
    if (retryAt != null && clock.now().isBefore(retryAt)) return;
    final direct = _mode == AppMode.direct;
    final home = _activeHome;
    final uid = state.deviceUid ?? ((key.isEmpty || key == '_lan') ? null : key);
    if (!direct && (home == null || uid == null)) return;
    final epoch = _sessionEpoch;
    _safetyNamesInFlight.add(key);
    unawaited(() async {
      try {
        final json = direct ? await directApi.fetchSafetyConfig() : await cloudApi.safetyConfig(home!.id, uid!);
        if (_isStaleSession(epoch)) return;
        final names = SafetyConfigNames.fromJson(json);
        _safetyNames[key] = names;
        if (names.matches(state)) {
          _safetyNamesRetryAt.remove(key);
        } else {
          _safetyNamesRetryAt[key] = clock.now().add(_safetyNamesRetry); // bulut kopyası henüz eski olabilir
        }
        _invalidateViews();
        notifyListeners();
      } catch (_) {
        if (!_isStaleSession(epoch)) _safetyNamesRetryAt[key] = clock.now().add(_safetyNamesRetry);
      } finally {
        _safetyNamesInFlight.remove(key);
      }
    }());
  }

  String? _actuatorName(ActuatorItem a) {
    if (_mode == AppMode.direct) return _status?.relayById(a.relay)?.name;
    final uid = a.deviceUid;
    for (final endpoint in _cloudEndpoints) {
      if (endpoint.isShutter || endpoint.channel != a.relay) continue;
      final epUid = endpoint.deviceUuid?.toUpperCase();
      if (uid == null || epUid == null || epUid == uid) return endpoint.name;
    }
    return null;
  }

  /// Bir panonun HAM güvenlik durumu (iyimser değer yok): komut ön denetimleri buna bakar.
  SafetyState _rawSafetyFor(String? uid) {
    if (_mode == AppMode.direct) return _status?.safety ?? SafetyState.unsupported;
    final key = uid?.toUpperCase();
    if (key != null && _safetyByUid.containsKey(key)) return _safetyByUid[key]!;
    if (key == null && _safetyByUid.length == 1) return _safetyByUid.values.first;
    return SafetyState.unsupported;
  }

  /// Vanayı uygulamadan açmanın önündeki engel (ham durumdan; iyimser değer yok): `null` = açılabilir. Arayüz düğmeyi
  /// devre dışı bırakıp gerekçeyi ([safetyRejectMessage]) yazar; [openValve] aynı denetimi ağa çıkmadan yineler.
  String? valveOpenBlockReason(ActuatorItem valve) {
    if (valve.isGasValve) return 'gas_local_only';
    return _rawSafetyFor(valve.deviceUid).openBlockReason(valve);
  }

  /// Alarm geçmişi (plan 2.6): bulutta sunucunun alarm kayıtları (açık + kapanmış), doğrudan (LAN) kipte panonun son
  /// olayları (`GET /api/events`, internetsiz; K5). Hata çağırana fırlatılır (sayfa yeniden deneme gösterir).
  Future<AlarmHistory> fetchAlarmHistory() async {
    if (_mode == AppMode.direct) {
      final events = await directApi.fetchEvents();
      return AlarmHistory.local(events);
    }
    final home = _activeHome;
    if (home == null) return const AlarmHistory.cloud(<AlarmRecord>[]);
    final records = await cloudApi.alarms(home.id, openOnly: false);
    return AlarmHistory.cloud(records);
  }

  static String _scoped(String base, String? uid) => uid == null ? base : '$base@$uid';
  String _actuatorKey(ActuatorItem a) => _scoped('actuator:${a.id}', a.deviceUid);
  String _alarmAckKey(int zone, String? uid) => _scoped('alarm:ack:$zone', uid);

  /// Eylemci komutu yolda / onay bekliyor ("uygulanıyor" göstergesi).
  bool isActuatorPending(ActuatorItem a) => _pipeline.isPending(_actuatorKey(a));

  /// Alarm onayı yolda / panonun susturma ya da kilit kaldırma bildirimini bekliyor.
  bool isAlarmAckPending(AlarmItem alarm) => _pipeline.isPending(_alarmAckKey(alarm.zone, alarm.deviceUid));

  /// Düz röle komutu güvenlik eylemcisi kanalına gidiyorsa yerelde reddeder (firmware ve sunucu da reddeder; ağ
  /// gidiş-dönüşü ve yanıltıcı iyimser değer önlenir). Eylemcisiz panoda hiçbir zaman tutmaz.
  bool _rejectIfActuatorChannel(String key, int channel) {
    final isActuator = _mode == AppMode.direct
        ? (_status?.relayById(channel)?.isActuator ?? false)
        : (_relayEndpoint(channel)?.isActuator ?? false);
    if (!isActuator) return false;
    _reject(key, safetyRejectMessage('actuator_relay'), code: 'actuator_relay');
    return true;
  }

  bool _safetyAllowed(String key, bool allowed) {
    if (allowed) return true;
    _reject(key, 'Bu işlem için yetkiniz yok.', reason: CommandFailureReason.forbidden);
    return false;
  }

  /// Vanayı KAPATIR (güvenli yön; her durumda serbest, misafir dahil). İyimser: anında "kapatıldı" görünür.
  Future<bool> closeValve(ActuatorItem valve) async {
    final key = _actuatorKey(valve);
    if (!valve.isValve) {
      _reject(key, 'Bu cihaz bir vana değil.', reason: CommandFailureReason.validation);
      return false;
    }
    if (!_safetyAllowed(key, capabilities.canCloseActuators)) return false;
    return _actuatorCommand(
      valve,
      'closed',
      optimistic: const _ActuatorTarget(pos: ValvePos.cmdClosed),
      confirms: CommandConfirm.valvePos(valve.id, closed: true, uid: valve.deviceUid),
    );
  }

  /// Vanayı AÇAR. İyimser DEĞİL. Yalnız bölgeler normal, sensörler `ok` ve kuru, pano güvenli kipte değilken; gaz
  /// vanası uygulamadan hiçbir zaman açılmaz [Y-3][K-4]. Engel varsa ağa çıkmadan gerekçeli ret ([CommandFailure.code]).
  Future<bool> openValve(ActuatorItem valve) async {
    final key = _actuatorKey(valve);
    if (!valve.isValve) {
      _reject(key, 'Bu cihaz bir vana değil.', reason: CommandFailureReason.validation);
      return false;
    }
    if (valve.isGasValve) {
      _reject(key, safetyRejectMessage('gas_local_only'), code: 'gas_local_only');
      return false;
    }
    if (!_safetyAllowed(key, capabilities.canControlActuators)) return false;
    final reason = _rawSafetyFor(valve.deviceUid).openBlockReason(valve);
    if (reason != null) {
      _reject(key, safetyRejectMessage(reason), code: reason);
      return false;
    }
    return _actuatorCommand(
      valve,
      'open',
      confirms: CommandConfirm.valvePos(valve.id, closed: false, uid: valve.deviceUid),
    );
  }

  /// Gaz alarmı sürerken havalandırmayı durdurma reddinin metni (sunucu 403 FORBIDDEN ile aynı; guvenlik-7).
  static const String gasFanStopForbidden = 'Gaz alarmı sürerken havalandırmayı yalnız ev sahibi/üyeleri durdurabilir.';

  /// [actuator] çalışan bir fan ve bölgesinde (aynı pano) etkin gaz alarmı (latched/fault) sürüyor (guvenlik-7): fanı
  /// durdurmak yalnız alarm onay yetkisi olanlara açıktır ve arayüz onay ister (havalandırma gaz birikimini önler).
  bool isGasVentilationRunning(ActuatorItem actuator) {
    if (actuator.kind != ActuatorKind.fan || actuator.on != true) return false;
    final safety = _rawSafetyFor(actuator.deviceUid);
    for (final alarm in safety.alarms) {
      if (!alarm.isActive || !actuator.zones.contains(alarm.zone)) continue;
      if (alarmHazardKinds(alarm, safety.sensors).contains('gas')) return true;
    }
    return false;
  }

  /// Siren / fan / genel eylemci. Kapatma (güvenli yön) misafir dahil serbest ve iyimser; açma iyimser değil. Gaz alarmı
  /// sürerken çalışan fanı yalnız alarm onay yetkisi olan durdurur (guvenlik-7).
  Future<bool> setActuatorOn(ActuatorItem actuator, bool on) async {
    final key = _actuatorKey(actuator);
    if (actuator.isValve) {
      _reject(key, 'Vana için Vanayı Aç / Vanayı Kapat kullanılır.', reason: CommandFailureReason.validation);
      return false;
    }
    if (!on && !capabilities.canAckAlarm && isGasVentilationRunning(actuator)) {
      _reject(key, gasFanStopForbidden, reason: CommandFailureReason.forbidden);
      return false;
    }
    if (!_safetyAllowed(key, on ? capabilities.canControlActuators : capabilities.canCloseActuators)) return false;
    return _actuatorCommand(
      actuator,
      on ? 'on' : 'off',
      optimistic: on ? null : const _ActuatorTarget(on: false),
      confirms: CommandConfirm.actuatorOn(actuator.id, on, uid: actuator.deviceUid),
    );
  }

  Future<bool> _actuatorCommand(
    ActuatorItem actuator,
    String to, {
    _ActuatorTarget? optimistic,
    required ConfirmPredicate confirms,
  }) async {
    final key = _actuatorKey(actuator);
    if (_mode == AppMode.direct) {
      return _dispatch(
        key: key,
        original: null,
        target: optimistic,
        send: (id) async {
          await directApi.postActuator(actuator.id, to, id: id);
          return CommandResult.accepted;
        },
        confirms: confirms,
      );
    }
    final home = _activeHome;
    final ref = actuator.deviceUid ?? _primaryDeviceRef();
    if (home == null || ref == null) {
      _reject(key, 'Güvenlik cihazı bulunamadı.');
      return false;
    }
    return _dispatch(
      key: key,
      original: null,
      target: optimistic,
      targetUid: actuator.deviceUid,
      send: (id) => cloudApi.actuatorCommand(
        homeId: home.id,
        deviceId: ref,
        actuatorId: actuator.id,
        to: to,
        commandId: id,
      ),
      confirms: confirms,
    );
  }

  /// Alarmı onaylar: ıslakken susturur, kuruyken (≥ `dry_hold`) kilidi kaldırır (§5.1.3). İyimser DEĞİL. Onay alarm
  /// kimliğini (`aid`) taşır: arada yeni alarm oluştuysa pano `stale_ack` ile reddeder [Y-9]. Bulutta sunucudaki
  /// alarm kaydı `aid` ile bulunur (kayıt henüz yoksa ağa komut gitmez, anlaşılır ret).
  Future<bool> ackAlarm(AlarmItem alarm) async {
    final key = _alarmAckKey(alarm.zone, alarm.deviceUid);
    if (!_safetyAllowed(key, capabilities.canAckAlarm)) return false;
    final confirms = CommandConfirm.alarmSilencedOrCleared(alarm.zone, uid: alarm.deviceUid);
    if (_mode == AppMode.direct) {
      return _dispatch(
        key: key,
        original: null,
        target: null,
        send: (id) async {
          await directApi.ackAlarm(alarm.zone, aid: alarm.aid, id: id);
          return CommandResult.accepted;
        },
        confirms: confirms,
      );
    }
    final home = _activeHome;
    if (home == null) {
      _reject(key, 'Aktif daire seçili değil.');
      return false;
    }
    return _dispatch(
      key: key,
      original: null,
      target: null,
      targetUid: alarm.deviceUid,
      send: (id) async {
        final record = await _findAlarmRecord(home.id, alarm);
        if (record == null) {
          throw const ApiException(
            statusCode: 409,
            code: 'ALARM_NOT_FOUND',
            message: 'Alarm kaydı sunucuya henüz ulaşmadı. Birkaç saniye sonra yeniden deneyin.',
          );
        }
        return cloudApi.ackAlarm(homeId: home.id, alarmId: record.id, commandId: id);
      },
      confirms: confirms,
    );
  }

  Future<AlarmRecord?> _findAlarmRecord(String homeId, AlarmItem alarm) async {
    final records = await cloudApi.alarms(homeId);
    final uid = alarm.deviceUid?.toUpperCase();
    AlarmRecord? byZone;
    for (final r in records) {
      // Hırsız alarmı satırı onaylanmaz, çözülür (F2.B.9): tehlike alarmı onayında aranmaz.
      if (!r.isOpen || r.zone != alarm.zone || r.kind == 'intrusion') continue;
      if (uid != null && r.deviceUuid != null && r.deviceUuid != uid) continue;
      if (alarm.aid != null && r.aid == alarm.aid) return r;
      byZone ??= alarm.aid == null ? r : null;
    }
    return byZone;
  }

  // ---------------------------------------------------------------------------
  // Hırsız alarmı kipi (Faz 2 F2.B.9): kurma/çözme iyimser DEĞİL (onaya kadar "Uygulanıyor…").
  // ---------------------------------------------------------------------------

  String _armKey(String? uid) => _scoped('arm', uid?.toUpperCase());

  /// Kurma/çözme komutu yolda / panonun onayını bekliyor.
  bool isArmPending(String? uid) => _pipeline.isPending(_armKey(uid));

  /// Çıkış/giriş gecikmesinin kalan saniyesi (F2.B.7 `until_up`); gecikme yoksa `null`, süre dolduysa 0.
  int? armRemainingSec(String? uid) {
    final key = uid?.toUpperCase();
    final arm = _decoratedSafetyFor(key).arm;
    final until = arm?.untilUp;
    if (arm == null || until == null || (arm.st != ArmStatus.exit && arm.st != ArmStatus.entry)) return null;
    final ref = _armClock[key] ?? (_armClock.length == 1 ? _armClock.values.first : null);
    if (ref == null) return null;
    final elapsed = clock.now().difference(ref.at).inSeconds;
    final left = until - ref.uptime - elapsed;
    return left < 0 ? 0 : left;
  }

  SafetyState _decoratedSafetyFor(String? uid) {
    final all = safetyByDevice;
    final key = uid?.toUpperCase();
    if (key != null && all.containsKey(key)) return all[key]!;
    if (key == null && all.length == 1) return all.values.first;
    if (_mode == AppMode.direct && all.length == 1) return all.values.first;
    return SafetyState.unsupported;
  }

  /// [mode] kipinde kurmanın önündeki engel (ağa çıkmadan; F2.B.9): "Kurulamaz: Salon penceresi açık." `null` = hazır.
  /// Çözme (`off`) hiçbir zaman engellenmez.
  String? armBlockReason(String? uid, ArmMode mode) {
    if (!mode.isArmed) return null;
    final blocked = _decoratedSafetyFor(uid).armBlockSensors(mode);
    if (blocked.isEmpty) return null;
    final parts = <String>[for (final s in blocked) s.ok ? '${s.displayName} açık' : '${s.displayName} yanıt vermiyor'];
    return 'Kurulamaz: ${parts.join(', ')}.';
  }

  /// Alarm kipini kurar (`home`/`away`) ya da çözer (`off`). Bulutta `POST …/arm`, LAN'da `POST /api/arm`. Yetki
  /// ([Capabilities.canArm]), yetenek (`caps` `intrusion`) ve hazırlık ([armBlockReason]) ağa çıkmadan denetlenir.
  Future<bool> setArmMode(String? deviceUid, ArmMode mode) async {
    final uid = deviceUid?.toUpperCase();
    final key = _armKey(uid);
    if (mode == ArmMode.unknown) {
      _reject(key, 'Geçersiz alarm kipi.', reason: CommandFailureReason.validation);
      return false;
    }
    if (!_safetyAllowed(key, capabilities.canArm)) return false;
    final raw = _mode == AppMode.direct ? (_status?.safety ?? SafetyState.unsupported) : _rawSafetyFor(uid);
    if (!raw.supportsIntrusion) {
      _reject(key, "Bu pano yazılımı alarm kipini desteklemiyor; v1.2.1'e güncelleyin.", code: 'FIRMWARE_UNSUPPORTED');
      return false;
    }
    final block = armBlockReason(uid, mode);
    if (block != null) {
      _reject(key, block, code: 'not_ready');
      return false;
    }
    final confirms = CommandConfirm.armMode(mode.wire, uid: uid);
    if (_mode == AppMode.direct) {
      return _dispatch(
        key: key,
        original: null,
        target: null,
        send: (id) async {
          await directApi.postArm(mode.wire, id: id);
          return CommandResult.accepted;
        },
        confirms: confirms,
      );
    }
    final home = _activeHome;
    final ref = uid ?? _primaryDeviceRef();
    if (home == null || ref == null) {
      _reject(key, 'Pano bulunamadı.');
      return false;
    }
    return _dispatch(
      key: key,
      original: null,
      target: null,
      targetUid: uid,
      send: (id) async {
        try {
          return await cloudApi.armCommand(homeId: home.id, deviceId: ref, mode: mode.wire, commandId: id);
        } on ApiException catch (e) {
          // Kurma bağlamında "güvenlik modülü desteklenmiyor" değil, "alarm kipi desteklenmiyor" (F2.B.9).
          if (e.statusCode == 409 && e.code == 'FIRMWARE_UNSUPPORTED') {
            throw ApiException(statusCode: 409, code: 'ARM_FIRMWARE_UNSUPPORTED', message: e.message);
          }
          rethrow;
        }
      },
      confirms: confirms,
    );
  }

  /// Bölge testi (§5.1.1 NORMAL -> TEST): vanalar kapanır, siren 3 sn çalar, geri bildirim süresi ölçülür. İletim
  /// yeterlidir (test kısa sürer; sonucu `state`/`test_result` gösterir).
  Future<bool> testZone(int zone, {String? deviceUid}) async {
    final key = _scoped('alarm:test:$zone', deviceUid?.toUpperCase());
    if (zone < 1 || zone > 4) {
      _reject(key, 'Geçersiz bölge.', reason: CommandFailureReason.validation);
      return false;
    }
    if (!_safetyAllowed(key, capabilities.canTestSafety)) return false;
    if (_mode == AppMode.direct) {
      return _dispatch(
        key: key,
        original: null,
        target: null,
        mode: CommandConfirmMode.delivery,
        send: (id) async {
          await directApi.testAlarm(zone, id: id);
          return CommandResult.accepted;
        },
      );
    }
    final home = _activeHome;
    final ref = deviceUid ?? _primaryDeviceRef();
    if (home == null || ref == null) {
      _reject(key, 'Pano bulunamadı.');
      return false;
    }
    return _dispatch(
      key: key,
      original: null,
      target: null,
      mode: CommandConfirmMode.delivery,
      targetUid: deviceUid,
      send: (id) => cloudApi.alarmTest(homeId: home.id, deviceId: ref, zone: zone, commandId: id),
    );
  }

  /// Panjurun görünen konumu (bekleyen komutun hedefi dahil); bulunamazsa 0.
  int getShutterPosition(int pair) {
    if (_mode == AppMode.direct) return status?.shutterByPair(pair)?.pos ?? 0;
    return _shutterEndpoint(pair)?.shutterPosition ?? 0;
  }

  /// Panjur komutu: [action] `up|down|stop|step|pos` (`pos` için [percent]). [pair] **1 tabanlıdır**.
  Future<bool> cmdShutter(int pair, String action, {int? percent}) async {
    if (action == 'pos') {
      if (percent == null) {
        _reject('shutter:$pair', 'Konum değeri gerekli.', reason: CommandFailureReason.validation);
        return false;
      }
      return setShutterPosition(pair, percent);
    }
    final key = 'shutter:$pair';
    const actions = <String>{'up', 'down', 'stop', 'step'};
    if (pair < 1 || !actions.contains(action)) {
      _reject(key, 'Geçersiz panjur komutu.', reason: CommandFailureReason.validation);
      return false;
    }
    if (!_controlAllowed(key: key)) return false;

    _ShutterTarget? target;
    ConfirmPredicate? confirms;
    switch (action) {
      case 'up':
        target = const _ShutterTarget(moving: true, direction: 1);
        confirms = CommandConfirm.shutterUp(pair);
      case 'down':
        target = const _ShutterTarget(moving: true, direction: 2);
        confirms = CommandConfirm.shutterDown(pair);
      case 'stop':
        target = const _ShutterTarget(moving: false, direction: 0);
        confirms = CommandConfirm.shutterStopped(pair);
      default: // step
        target = null;
        confirms = null;
    }
    final mode = action == 'step' ? CommandConfirmMode.delivery : null;
    final original = _ShutterTarget(pos: getShutterPosition(pair));

    if (_mode == AppMode.direct) {
      if (status?.shutterByPair(pair) == null) {
        _reject(key, 'Panjur bulunamadı.');
        return false;
      }
      return _dispatch(
        key: key,
        original: original,
        target: target,
        mode: mode,
        send: (_) async {
          await directApi.cmdShutter(pair, action);
          return CommandResult.accepted;
        },
        confirms: confirms,
      );
    }

    final home = _activeHome;
    final endpoint = _shutterEndpoint(pair);
    final ref = endpoint == null ? null : (endpoint.deviceUuid ?? endpoint.deviceId ?? _primaryDeviceRef());
    if (home == null || endpoint == null || ref == null) {
      _reject(key, 'Panjur bulunamadı.');
      return false;
    }
    return _dispatch(
      key: key,
      original: original,
      target: target,
      mode: mode,
      targetUid: endpoint.deviceUuid,
      send: (id) => cloudApi.sendCommand(
        homeId: home.id,
        deviceId: ref,
        command: <String, dynamic>{'shutter': pair, 'cmd': action, 'id': id},
      ),
      confirms: confirms,
    );
  }

  static const Map<String, String> _groupAliases = <String, String>{
    'lightsoff': 'all_lights_off',
    'all_lights_off': 'all_lights_off',
    'all_off': 'all_lights_off',
    'shuttersup': 'all_shutters_up',
    'all_shutters_up': 'all_shutters_up',
    'shuttersdown': 'all_shutters_down',
    'all_shutters_down': 'all_shutters_down',
    'shuttersstop': 'all_shutters_stop',
    'all_shutters_stop': 'all_shutters_stop',
  };

  /// Toplu komut (`lightsoff | shuttersup | shuttersdown | shuttersstop` veya `all_*`). Misafir ✖.
  Future<bool> cmdAll(String command) async {
    final canonical = _groupAliases[command];
    final key = 'group:${canonical ?? command}';
    if (canonical == null) {
      _reject(key, 'Geçersiz toplu komut.', reason: CommandFailureReason.validation);
      return false;
    }
    if (!capabilities.canUseGroupCommands) {
      _reject(key, 'Bu işlem için yetkiniz yok.', reason: CommandFailureReason.forbidden);
      return false;
    }
    if (_mode == AppMode.direct) {
      return _dispatch(
        key: key,
        original: null,
        target: null,
        mode: CommandConfirmMode.delivery,
        send: (_) async {
          await directApi.cmdAll(canonical);
          return CommandResult.accepted;
        },
      );
    }
    final home = _activeHome;
    final ref = _primaryDeviceRef();
    if (home == null || ref == null) {
      _reject(key, 'Cihaz bulunamadı.');
      return false;
    }
    return _dispatch(
      key: key,
      original: null,
      target: null,
      mode: CommandConfirmMode.delivery,
      send: (id) => cloudApi.sendCommand(
        homeId: home.id,
        deviceId: ref,
        command: <String, dynamic>{'cmd': canonical, 'id': id},
      ),
    );
  }

  /// Çocuk kilidini ayarlar ve **tipli sonuç** döndürür ([CommandDispatch]).
  ///
  /// Akış: iyimser hedef anında görünür ([childLockStatus]) ve [childLockPending] true olur;
  /// REST/LAN iletimi başarılıysa komut **"uygulanıyor"** durumundadır (`delivered:true`
  /// "uygulandı" demek DEĞİLDİR); cihazın `state.child_lock` bildirimi hedefi doğrularsa
  /// tamamdır. İletim hatası (409 `DEVICE_OFFLINE`, 403, 502, ağ, `delivered=false`, LAN 4xx)
  /// **anında**, iletimden sonra [CommandPipeline.confirmTimeout] içinde doğrulama gelmezse
  /// **zaman aşımıyla** geri alınır ve [commandFailures] olayı üretilir. Bekleyen komut varken
  /// gelen `refresh()`/GET sonuçları görünen değeri EZMEZ. Hızlı ardışık çağrılar tek bekleyen
  /// komutta birleşir (en çok bir uçuşta + bir sıradaki istek; son niyet kazanır).
  Future<CommandDispatch> setChildLock(bool enabled) async {
    const key = 'childLock';
    if (!capabilities.canChangeChildLock) {
      const failure = CommandFailure(
        key: key,
        reason: CommandFailureReason.forbidden,
        message: 'Bu işlem için yetkiniz yok.',
      );
      _pipeline.emitFailure(failure);
      return const CommandDispatch.failed(failure);
    }
    final original = childLockStatus;
    if (_mode == AppMode.direct) {
      return _submit(
        key: key,
        original: original,
        target: enabled,
        send: (_) async {
          await directApi.setChildLock(enabled);
          return CommandResult.accepted;
        },
        confirms: CommandConfirm.childLock(enabled),
      );
    }
    final home = _activeHome;
    if (home == null) {
      const failure = CommandFailure(
        key: key,
        reason: CommandFailureReason.rejected,
        message: 'Aktif daire seçili değil.',
      );
      _pipeline.emitFailure(failure);
      return const CommandDispatch.failed(failure);
    }
    final mode = _stateConfirmMode;
    final epoch = _homeEpoch;
    final dispatch = await _submit(
      key: key,
      original: original,
      target: enabled,
      mode: mode,
      send: (_) => cloudApi.setChildLock(homeId: home.id, enabled: enabled),
      confirms: CommandConfirm.childLock(enabled),
    );
    final result = dispatch.result;
    if (epoch != _homeEpoch) return dispatch; // ev değişti/çıkış: eski evin bilgisi yazılmaz
    if (dispatch.ok && result != null) {
      // Yanıtta gerçek durum yoktur (`child_lock_enabled` YOK): yalnızca niyet ve çevrimdışı panolar.
      _childLockRequested = result.requested ?? enabled;
      _childLockOfflineDevices = result.offlineDevices;
      notifyListeners();
    } else if (!dispatch.ok && dispatch.failure?.reason == CommandFailureReason.offline) {
      final error = dispatch.failure?.error;
      if (error is ApiException && error.offlineDevices.isNotEmpty) {
        _childLockOfflineDevices = error.offlineDevices;
        notifyListeners();
      }
    }
    // Canlı `state` kanalı yokken (MQTT kopuk) cihaz onayı gelmez: sunucunun kabulü en iyi bilgidir.
    // Canlı kanal varken gerçek değer YALNIZCA cihazın `state.child_lock` bildirimiyle değişir.
    // Sunucu `no_change` derse (çevrimiçi pano zaten hedefi bildiriyor) yeni `state` gelmeyebilir.
    if (dispatch.ok && (mode == CommandConfirmMode.settle || dispatch.result?.noChange == true)) {
      _commitChildLockOptimistically(enabled);
    }
    return dispatch;
  }

  void _commitChildLockOptimistically(bool enabled) {
    for (final key in _childLockByUid.keys.toList()) {
      _childLockByUid[key] = enabled;
    }
    _childLockRest = enabled;
    _childLockUpdatedAt = clock.now();
    notifyListeners();
  }

  /// Eski kısa yol: [setChildLock] sonucu "iletildi mi". **Arayüz bu değere güvenmemelidir**
  /// (çift dokunuşta önceki çağrı `false` döner, ret/zaman aşımı sonradan [commandFailures] ile
  /// bildirilir); durum için [childLockStatus] / [childLockPending] kullanın.
  Future<bool> toggleChildLock(bool enabled) async => (await setChildLock(enabled)).ok;

  // ---------------------------------------------------------------------------
  // Huzur bildirimi
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>?> fetchPeaceNotification() => _fetchPeace(notify: true);

  /// [notify] `false` ise yalnız alan atar ([_cloudRefreshImpl] tek bildirim yapar).
  Future<Map<String, dynamic>?> _fetchPeace({required bool notify}) async {
    final home = _activeHome;
    if (_mode != AppMode.cloud || home == null || !capabilities.canChangeChildLock) return null;
    final epoch = _homeEpoch;
    try {
      final data = await cloudApi.getPeaceNotification(home.id);
      if (epoch != _homeEpoch) return null;
      _peaceNotificationData = data;
      if (notify) notifyListeners();
      return data;
    } on ApiException catch (e) {
      _log('Huzur bildirimi alınamadı (${e.statusCode})');
    } catch (_) {}
    return null;
  }

  /// Açık lambaları tek tıkla kapat; kapatılan **gerçek** sayıyı döndürür.
  Future<int> closeAllOpenLights() async {
    if (!capabilities.canUseGroupCommands) throw ApiException.forbidden();
    final before = openLightsCount;
    if (_mode == AppMode.direct) {
      await directApi.cmdAll('lightsoff');
      await refresh(silent: true);
      return before;
    }
    final home = _activeHome;
    if (home == null) throw ApiException.validation('Aktif daire seçili değil.');
    final res = CloseAllResult.fromJson(await cloudApi.closeAllOpenLights(home.id));
    unawaited(refresh(silent: true));
    unawaited(fetchPeaceNotification());
    return res.closedCount ?? before;
  }

  Future<void> updatePeaceNotificationSettings({bool? enabled, String? time, String? notificationTime}) async {
    if (!capabilities.canChangeChildLock) throw ApiException.forbidden();
    final home = _activeHome;
    if (_mode != AppMode.cloud || home == null) return;
    await cloudApi.updatePeaceNotification(
      home.id,
      enabled: enabled,
      notificationTime: time ?? notificationTime,
    );
    await fetchPeaceNotification();
  }

  // ---------------------------------------------------------------------------
  // Servis PIN, cihaz sahiplenme, devreye alma, pano değişimi
  // ---------------------------------------------------------------------------

  /// Ev sahibi: servis teknisyeni için 2 saatlik tek kullanımlık PIN üretir.
  Future<String> generateServicePin() async {
    if (!capabilities.canGenerateServicePin) throw ApiException.forbidden();
    final home = _activeHome;
    if (home == null) throw ApiException.validation('Önce bir daire seçilmelidir.');
    final epoch = _homeEpoch;
    final token = await cloudApi.createServiceToken(home.id);
    if (epoch != _homeEpoch || _isDisposed) return token.pin; // tek seferlik PIN yine de döner; durum/zamanlayıcı kurulmaz
    _servicePin = token.pin;
    _servicePinExpiry = token.expiresAt;
    _servicePinTimer?.cancel();
    final remaining = token.expiresAt.difference(clock.now());
    if (!remaining.isNegative) {
      _servicePinTimer = clock.timer(remaining, () {
        _servicePin = null;
        _servicePinExpiry = null;
        notifyListeners();
      });
    }
    notifyListeners();
    return token.pin;
  }

  /// Ev sahibi: servis PIN geçmişi (`active|used|expired|revoked`). **PIN değeri dönmez.**
  Future<List<ServiceTokenSummary>> fetchServiceTokens() async {
    if (!capabilities.canGenerateServicePin) throw ApiException.forbidden();
    final home = _activeHome;
    if (home == null) throw ApiException.validation('Önce bir daire seçilmelidir.');
    return cloudApi.listServiceTokens(home.id);
  }

  /// Ev sahibi: evde açık servis (PIN) oturumları.
  Future<List<ServiceSessionSummary>> fetchServiceSessions() async {
    if (!capabilities.canGenerateServicePin) throw ApiException.forbidden();
    final home = _activeHome;
    if (home == null) throw ApiException.validation('Önce bir daire seçilmelidir.');
    return cloudApi.listServiceSessions(home.id);
  }

  /// Ev sahibi: kullanılmamış tüm servis PIN'lerini ve açık servis oturumlarını iptal eder
  /// ("servis erişimini kapat"). Ekranda gösterilen PIN de silinir.
  Future<RevokeServiceAccessResult> revokeServiceAccess() async {
    if (!capabilities.canGenerateServicePin) throw ApiException.forbidden();
    final home = _activeHome;
    if (home == null) throw ApiException.validation('Önce bir daire seçilmelidir.');
    final epoch = _homeEpoch;
    final result = await cloudApi.revokeServiceAccess(home.id);
    if (epoch == _homeEpoch) {
      _servicePin = null;
      _servicePinExpiry = null;
      _servicePinTimer?.cancel();
      _servicePinTimer = null;
      notifyListeners();
    }
    return result;
  }

  /// Cihazın bulut (MQTT) kimliğini yeniden üretir (owner / servis personeli / servis oturumu /
  /// süper kullanıcı). Parola **yalnızca bu dönüşte** bulunur (saklanmaz): kurulum sihirbazı
  /// `AutomationApiService.configureMqtt` ile panoya yazar. Eski cihaz kimliği geçersiz olur.
  Future<DeviceMqttCredential> reissueDeviceMqttCredential({
    required String deviceUuid,
    String? homeId,
  }) async {
    if (!capabilities.canReissueDeviceCredential) throw ApiException.forbidden();
    final targetHome = homeId ?? _activeHome?.id;
    if (targetHome == null) throw ApiException.validation('Aktif daire seçilmedi.');
    final uuid = QrClaimParser.normalizeUid(deviceUuid);
    if (uuid == null) throw ApiException.validation('Geçersiz cihaz kimliği.');
    return cloudApi.reissueDeviceMqttCredential(targetHome, uuid);
  }

  /// Servis sorumlusu: müşteriye cihaz kurulum onay OTP'si gönderir.
  Future<Map<String, dynamic>> requestClaimOtp({
    required String deviceUuid,
    required String targetOwner,
  }) async {
    if (!capabilities.canClaimDevice) throw ApiException.forbidden();
    return cloudApi.requestClaimOtp(deviceUuid: deviceUuid, targetOwner: targetOwner);
  }

  /// Cihaz sahiplenme (claim). Servis personeli/süper kullanıcı müşteri adına eşlerken (`targetOwner`)
  /// müşterinin evi kendi aktif evi yapılmaz; ev listesi yine de yenilenir.
  Future<ClaimResult> claimDevice(
    String deviceUuid,
    String setupPin, {
    String? homeName,
    String? targetOwner,
    String? otpCode,
  }) async {
    if (!capabilities.canClaimDevice) throw ApiException.forbidden();
    final result = await cloudApi.claimDevice(
      deviceUuid: deviceUuid,
      setupPin: setupPin,
      homeName: homeName,
      targetOwner: targetOwner,
      otpCode: otpCode,
    );
    final isStaffFlow = capabilities.isStaff || isSuperUser;
    // Sonuç (cihaz kimliği) sunucudan BİR kez gelir: ev listesi yenilemesi/ev seçimi en iyi çaba ve sınırlıdır
    // (PF-44); yavaş ağda arka planda sürer, sonuç hemen döner.
    await _bestEffort(_refreshAfterClaim(result, isStaffFlow));
    notifyListeners();
    return result;
  }

  Future<void> _refreshAfterClaim(ClaimResult result, bool isStaffFlow) async {
    await fetchHomes(autoSelect: false);
    if (!isStaffFlow) {
      final claimed = homeById(result.homeId);
      if (claimed != null) await selectHome(claimed);
    }
  }

  /// Tek seferlik sırlı bir sonuçtan SONRAKİ ağ yenilemesi: en çok [_bestEffortLimit] beklenir, hata/zaman aşımı
  /// yutulur (iş arka planda sürer; sonuç zaten alınmıştır ve bir daha verilmez).
  static const Duration _bestEffortLimit = Duration(seconds: 3);

  Future<void> _bestEffort(Future<void> work) async {
    try {
      await clock.bound<void>(work, _bestEffortLimit, () {});
    } catch (_) {}
  }

  /// Devreye alma (commissioning): zorunlu 5 kontrol ayrı alanlarla gönderilir; `tests_passed`
  /// sunucuda hesaplanır ve [CommissioningResult.testsPassed] ile döner.
  Future<CommissioningResult> commission({
    required CommissioningChecks checks,
    String? notes,
    String? deviceUuid,
    String? homeId,
  }) async {
    if (!capabilities.canCommission) throw ApiException.forbidden();
    final targetHome = homeId ?? _activeHome?.id;
    final uuid = deviceUuid ?? (_selectedDeviceUuid.isNotEmpty ? _selectedDeviceUuid : _localKeyDeviceUuid());
    if (targetHome == null) throw ApiException.validation('Aktif daire seçilmedi.');
    if (uuid == null) throw ApiException.validation('Cihaz kimliği belirtilmedi.');
    return cloudApi.commission(homeId: targetHome, deviceUuid: uuid, checks: checks, notes: notes);
  }

  Future<Map<String, dynamic>?> getCommissioningStatus() async {
    final home = _activeHome;
    if (home == null) return null;
    return cloudApi.getCommissioningStatus(home.id);
  }

  /// Uç nokta günceller: ad/oda ve panjur motor süresi (1..300 sn). Hata **fırlatılır**.
  Future<void> updateEndpoint({
    required String endpointId,
    String? name,
    String? room,
    String? type,
    int? shutterDurationSec,
  }) async {
    if (!capabilities.canCalibrate) throw ApiException.forbidden();
    final home = _activeHome;
    if (home == null) throw ApiException.validation('Aktif daire seçilmedi.');
    await cloudApi.updateEndpoint(
      homeId: home.id,
      endpointId: endpointId,
      name: name,
      room: room,
      type: type,
      shutterDurationSec: shutterDurationSec,
    );
    await refresh(silent: true);
  }

  /// Uç noktaları yeniden yükler.
  Future<void> fetchEndpoints([String? homeId]) async {
    final home = homeId == null ? _activeHome : homeById(homeId);
    if (home == null) return;
    await _loadEndpoints(home, _homeEpoch, silent: false);
  }

  /// Acil sıfırlama: gerekçe ≥ 15 karakter + cihaz UUID'sinin yazarak teyidi (yanıt yeni PIN'i bir kez içerir).
  Future<EmergencyResetResult> emergencyResetDevice({
    required String deviceUuid,
    required String confirmUid,
    required String reason,
    String? newOwnerIdentifier,
  }) async {
    if (!capabilities.canEmergencyReset) throw ApiException.forbidden();
    if (reason.trim().length < 15) {
      throw ApiException.validation('Gerekçe en az 15 karakter olmalıdır.');
    }
    final uuid = QrClaimParser.normalizeUid(deviceUuid);
    final confirm = QrClaimParser.normalizeUid(confirmUid);
    if (uuid == null || confirm == null || uuid != confirm) {
      throw ApiException.validation('Cihaz kimliği teyidi eşleşmiyor.');
    }
    final res = await cloudApi.emergencyResetDevice(
      deviceUuid: uuid,
      confirmUid: confirm,
      reason: reason,
      newOwnerIdentifier: newOwnerIdentifier,
    );
    // Yanıt tek seferlik sır (yeni PIN / yerel anahtar / cihaz kimliği) taşır: yenileme en iyi çaba, sınırlı (PF-44).
    await _bestEffort(fetchHomes(autoSelect: false));
    return res;
  }

  Future<Map<String, dynamic>> fetchSystemDiagnostic() async {
    final home = _activeHome;
    if (home == null) throw ApiException.validation('Aktif daire seçili değil.');
    return cloudApi.fetchSystemDiagnostic(home.id);
  }

  /// Pano değişimi (çok cihazlı evde [oldDeviceUuid] zorunludur).
  Future<ReplaceBoardResult> replaceBoard({
    String? oldDeviceUuid,
    required String newDeviceUuid,
    required String setupPin,
    String? reason,
  }) async {
    if (!capabilities.canReplaceBoard) throw ApiException.forbidden();
    final home = _activeHome;
    if (home == null) throw ApiException.validation('Aktif daire seçili değil.');
    final res = await cloudApi.replaceBoard(
      homeId: home.id,
      oldDeviceUuid: oldDeviceUuid,
      newDeviceUuid: newDeviceUuid,
      setupPin: setupPin,
      reason: reason,
    );
    // Yanıt tek seferlik yeni pano kimliği taşır: yenileme en iyi çaba, sınırlı (PF-44).
    await _bestEffort(refresh(silent: true));
    return res;
  }

  // ---------------------------------------------------------------------------
  // Aile: davet, üyeler, devir
  // ---------------------------------------------------------------------------

  String _homeIdOrActive(String? homeId) {
    final id = homeId ?? _activeHome?.id;
    if (id == null || id.isEmpty) throw ApiException.validation('Aktif daire seçili değil.');
    return id;
  }

  Future<InvitationModel> createHomeInvitation({
    String? homeId,
    String role = 'resident',
    int? durationHours,
    DateTime? validFrom,
    DateTime? validUntil,
    String? guestName,
  }) async {
    if (!capabilities.canInvite) throw ApiException.forbidden();
    return cloudApi.createInvitation(
      _homeIdOrActive(homeId),
      role: role,
      durationHours: durationHours,
      validFrom: validFrom,
      validUntil: validUntil,
      guestName: guestName,
    );
  }

  /// Ev üyeleri / misafirler (UUID String kimlikler). Hata **fırlatılır** (boş liste ile karışmaz).
  Future<List<HomeMember>> fetchHomeMembers([String? homeId]) async {
    // Biyometrik yeniden kilit (checking) ya da oturum yokken üye verisi okunmaz/yenilenmez.
    if (!isAuthenticated) throw ApiException.forbidden();
    return cloudApi.getHomeMembers(_homeIdOrActive(homeId));
  }

  /// Aktif evin bekleyen davetleri (ev_uyelik-6). Yalnız üye yönetebilen rol (ev sahibi / süper).
  Future<List<PendingInvitation>> fetchPendingInvitations([String? homeId]) async {
    if (!capabilities.canManageMembers) throw ApiException.forbidden();
    return cloudApi.listInvitations(_homeIdOrActive(homeId));
  }

  /// Bekleyen daveti iptal eder (ev_uyelik-6). Kullanılmış / süresi dolmuş davette sunucu `404` döner.
  Future<void> revokeInvitation(String invitationId, [String? homeId]) async {
    if (!capabilities.canManageMembers) throw ApiException.forbidden();
    await cloudApi.revokeInvitation(_homeIdOrActive(homeId), invitationId);
  }

  /// Üyeyi/misafiri evden çıkarır ([targetUserId] UUID String). Yalnızca ev sahibi.
  Future<bool> removeHomeMember(String targetUserId, [String? homeId]) async {
    if (!capabilities.canManageMembers) throw ApiException.forbidden();
    final ok = await cloudApi.removeHomeMember(_homeIdOrActive(homeId), targetUserId);
    notifyListeners();
    return ok;
  }

  /// Davet koduyla eve katıl; ev listesi (rol) yenilenir ve katılınan ev seçilir.
  Future<JoinHomeResult> joinHome(String code) async {
    final result = await cloudApi.joinHome(code);
    await fetchHomes(autoSelect: false);
    final id = result.homeId;
    final joined = id == null ? null : homeById(id);
    if (joined != null) {
      await selectHome(joined);
    } else if (_activeHome == null) {
      await _selectInitialHome();
    }
    notifyListeners();
    return result;
  }

  /// Ev sahibi: daire devrini başlatır (hedef kimlik **zorunlu**).
  Future<TransferInfo> initiateHomeTransfer({required String targetIdentifier, String? homeId}) async {
    if (!capabilities.canTransferOwnership) throw ApiException.forbidden();
    return cloudApi.initiateTransfer(_homeIdOrActive(homeId), targetIdentifier: targetIdentifier);
  }

  /// Devir kodunu kabul eder; ev listesi (rol) yenilenir ve devralınan ev seçilir.
  Future<TransferAcceptResult> acceptHomeTransfer(String transferCode) async {
    final result = await cloudApi.acceptTransfer(transferCode);
    await fetchHomes(autoSelect: false);
    final id = result.homeId;
    final home = id == null ? null : homeById(id);
    if (home != null) {
      await selectHome(home);
    } else if (_activeHome == null) {
      await _selectInitialHome();
    }
    notifyListeners();
    return result;
  }

  Future<Map<String, dynamic>?> getHomeTransferStatus([String? homeId]) async {
    if (!isAuthenticated) throw ApiException.forbidden(); // kilitliyken devir bilgisi okunmaz
    final id = homeId ?? _activeHome?.id;
    if (id == null) return null;
    return cloudApi.getTransferStatus(id);
  }

  Future<bool> cancelHomeTransfer([String? homeId]) async {
    if (!capabilities.canTransferOwnership) throw ApiException.forbidden();
    final ok = await cloudApi.cancelTransfer(_homeIdOrActive(homeId));
    notifyListeners();
    return ok;
  }

  // ---------------------------------------------------------------------------
  // Zamanlı kurallar
  // ---------------------------------------------------------------------------

  Future<void> fetchScheduledRules() async {
    final home = _activeHome;
    if (home == null || _mode != AppMode.cloud) return;
    final epoch = _homeEpoch;
    _scheduledRulesLoading = true;
    _scheduledRulesError = null;
    notifyListeners();
    try {
      final rules = await cloudApi.getScheduledRules(home.id);
      if (epoch != _homeEpoch) return;
      _scheduledRules = rules;
    } on ApiException catch (e) {
      if (epoch == _homeEpoch) _scheduledRulesError = e.message;
    } catch (_) {
      if (epoch == _homeEpoch) _scheduledRulesError = 'Kurallar yüklenemedi.';
    } finally {
      if (epoch == _homeEpoch) {
        _scheduledRulesLoading = false;
        notifyListeners();
      }
    }
  }

  /// Yeni kural. [channel] **1 tabanlıdır** (röle numarası veya panjur çifti).
  Future<void> createScheduledRule({
    required int channel,
    required String channelType,
    required String action,
    required int hour,
    required int minute,
    required List<int> daysOfWeek,
    String? label,
    String? deviceId,
  }) async {
    if (!capabilities.canManageRules) throw ApiException.forbidden();
    final error = ScheduledRule.validate(
      channel: channel,
      channelType: channelType,
      action: action,
      hour: hour,
      minute: minute,
      daysOfWeek: daysOfWeek,
    );
    if (error != null) throw ApiException.validation(error);
    final home = _activeHome;
    if (home == null) throw ApiException.validation('Aktif daire seçili değil.');
    await cloudApi.createScheduledRule(
      home.id,
      ScheduledRule.createPayload(
        channel: channel,
        channelType: channelType,
        action: action,
        hour: hour,
        minute: minute,
        daysOfWeek: daysOfWeek,
        label: label,
        deviceId: deviceId,
      ),
    );
    await fetchScheduledRules();
  }

  /// Kural güncelle (snake_case anahtarlar: `enabled`, `action`, `hour`, `minute`, `days_of_week`, `label`).
  Future<void> updateScheduledRule(String ruleId, Map<String, dynamic> updates) async {
    if (!capabilities.canManageRules) throw ApiException.forbidden();
    final home = _activeHome;
    if (home == null) return;
    await cloudApi.updateScheduledRule(home.id, ruleId, updates);
    await fetchScheduledRules();
  }

  Future<void> deleteScheduledRule(String ruleId) async {
    if (!capabilities.canManageRules) throw ApiException.forbidden();
    final home = _activeHome;
    if (home == null) return;
    await cloudApi.deleteScheduledRule(home.id, ruleId);
    _scheduledRules = _scheduledRules.where((r) => r.id != ruleId).toList();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Cihaz envanteri & servis aboneleri
  // ---------------------------------------------------------------------------

  Future<void> fetchInventory({String? status, String? search}) async {
    if (!capabilities.canViewInventory) throw ApiException.forbidden();
    final epoch = _sessionEpoch;
    _inventoryLoading = true;
    _inventoryError = null;
    notifyListeners();
    try {
      final res = await cloudApi.fetchDeviceInventory(status: status, search: search);
      if (epoch != _sessionEpoch) return;
      _inventoryDevices = parseList(res['items'], InventoryDeviceModel.fromJson, label: 'Inventory');
      final stats = asMap(res['stats']);
      if (stats != null) {
        _inventoryStats = <String, int>{
          'total': asInt(stats['total']) ?? _inventoryDevices.length,
          'in_stock': asInt(stats['in_stock']) ?? 0,
          'claimed': asInt(stats['claimed']) ?? 0,
          'suspended': asInt(stats['suspended']) ?? 0,
          'revoked': asInt(stats['revoked']) ?? 0,
        };
      }
    } on ApiException catch (e) {
      if (epoch == _sessionEpoch) _inventoryError = e.message;
    } catch (_) {
      if (epoch == _sessionEpoch) _inventoryError = 'Envanter yüklenemedi.';
    } finally {
      if (epoch == _sessionEpoch) {
        _inventoryLoading = false;
        notifyListeners();
      }
    }
  }

  Future<bool> updateInventoryStatus(String uuid, String newStatus) async {
    if (!capabilities.canManageInventory) throw ApiException.forbidden();
    await cloudApi.updateInventoryDeviceStatus(uuid, newStatus);
    _inventoryDevices = [
      for (final d in _inventoryDevices)
        d.deviceUuid == uuid ? d.copyWith(status: newStatus, updatedAt: clock.now().toUtc()) : d,
    ];
    notifyListeners();
    return true;
  }

  /// Kurulum PIN kilidini kaldırır (yalnız süper yönetici; bireysel-7). Anahtar ve PIN değişmez.
  Future<void> clearInventoryPinLock(String uuid) async {
    if (!capabilities.canManageInventory) throw ApiException.forbidden();
    await cloudApi.clearInventoryPinLock(uuid);
  }

  /// Envanterden siler. Sahiplenilmiş cihaz silinemez.
  Future<bool> deleteDeviceFromInventory(String uuid) async {
    if (!capabilities.canManageInventory) throw ApiException.forbidden();
    final existing = _inventoryDevices.where((d) => d.deviceUuid == uuid).firstOrNull;
    if (existing != null && existing.isClaimed) {
      throw ApiException.validation('Sahiplenilmiş cihaz envanterden silinemez.');
    }
    await cloudApi.deleteInventoryDevice(uuid);
    _inventoryDevices = _inventoryDevices.where((d) => d.deviceUuid != uuid).toList();
    notifyListeners();
    return true;
  }

  Future<void> fetchServiceSubscribers() async {
    if (!capabilities.canViewInventory) throw ApiException.forbidden();
    final epoch = _sessionEpoch;
    _subscribersLoading = true;
    _subscribersError = null;
    notifyListeners();
    try {
      final list = await cloudApi.fetchServiceSubscribers();
      if (epoch != _sessionEpoch) return;
      _serviceSubscribers = list;
    } on ApiException catch (e) {
      if (epoch == _sessionEpoch) _subscribersError = e.message;
    } catch (_) {
      if (epoch == _sessionEpoch) _subscribersError = 'Abone listesi yüklenemedi.';
    } finally {
      if (epoch == _sessionEpoch) {
        _subscribersLoading = false;
        notifyListeners();
      }
    }
  }

  /// Home Admin (ev sahibi) yetkisi atama; başarıda abone listesi yenilenir.
  Future<Map<String, dynamic>> assignHomeAdmin({
    required String homeId,
    required String fullName,
    String? email,
    String? phone,
  }) async {
    if (!capabilities.canViewInventory) throw ApiException.forbidden();
    final result = await cloudApi.assignHomeAdmin(
      homeId: homeId,
      fullName: fullName,
      email: email,
      phone: phone,
    );
    await fetchServiceSubscribers();
    return result;
  }

  // ---------------------------------------------------------------------------
  // Kurtarma / yerel Wi-Fi yardımcıları (192.168.4.1 veya pano yerel IP'si)
  // ---------------------------------------------------------------------------

  /// Wi-Fi taraması (doğrudan istemci). Kurtarma sihirbazı kendi `AutomationApiService.recoveryAp()`
  /// örneğini kullanmalıdır; bu yöntem ana doğrudan istemciyi kullanır.
  Future<List<Map<String, dynamic>>> scanRecoveryWifiNetworks() =>
      directApi.scanWifiNetworks(refresh: true);

  Future<void> sendRecoveryWifiCredentials(String ssid, String pass) =>
      directApi.connectWifi(ssid, pass);

  // ---------------------------------------------------------------------------
  // Tema
  // ---------------------------------------------------------------------------

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    try {
      await (await SharedPreferences.getInstance()).setString(_prefsTheme, mode.name);
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Test yardımcıları
  // ---------------------------------------------------------------------------

  @visibleForTesting
  void setThemeModeForTesting(ThemeMode mode) {
    _themeMode = mode;
    notifyListeners();
  }

  @visibleForTesting
  void setStatusForTesting(DeviceStatus? value) {
    _status = value;
    _invalidateViews();
    notifyListeners();
  }

  @visibleForTesting
  void setCloudEndpointsForTesting(List<EndpointModel> value) {
    _cloudEndpoints = List<EndpointModel>.of(value);
    _invalidateViews();
    _endpointsLoaded = true;
    notifyListeners();
  }

  @visibleForTesting
  void setModeForTesting(AppMode value) {
    _mode = value;
    notifyListeners();
  }

  @visibleForTesting
  void setScheduledRulesForTesting(List<ScheduledRule> rules) {
    _scheduledRules = List<ScheduledRule>.of(rules);
    notifyListeners();
  }

  @visibleForTesting
  void setCurrentUserForTesting(UserModel? user) {
    _currentUser = user;
    notifyListeners();
  }

  @visibleForTesting
  void setHomesForTesting(List<HomeModel> homes, {HomeModel? activeHome}) {
    _homes = List<HomeModel>.of(homes);
    _homesLoaded = true;
    _activeHome = activeHome ?? (homes.isNotEmpty ? homes.first : null);
    notifyListeners();
  }

  @visibleForTesting
  void setSelectedDeviceForTesting({required String uuid, required String ip, String? name}) {
    _selectedDeviceUuid = uuid;
    _selectedDeviceIp = ip;
    _selectedDeviceName = name;
    _host = ip;
    directApi.updateHost(ip);
    notifyListeners();
  }

  @visibleForTesting
  void setAuthStatusForTesting(AuthStatus value) {
    _authStatus = value;
    notifyListeners();
  }

  @visibleForTesting
  void setBiometricForTesting({
    bool? isSupported,
    bool? isEnabled,
    bool? checking,
    bool? failed,
    String? label,
    bool? shouldPrompt,
    AuthStatus? authStatus,
  }) {
    if (isSupported != null) _isBiometricSupported = isSupported;
    if (isEnabled != null) _isBiometricEnabled = isEnabled;
    if (checking != null) _biometricChecking = checking;
    if (failed != null) _biometricFailed = failed;
    if (label != null) _biometricLabel = label;
    if (shouldPrompt != null) _shouldPromptBiometrics = shouldPrompt;
    if (authStatus != null) _authStatus = authStatus;
    notifyListeners();
  }

  @visibleForTesting
  void setInventoryDevicesForTesting(List<InventoryDeviceModel> devices, {Map<String, int>? stats}) {
    _inventoryDevices = List<InventoryDeviceModel>.of(devices);
    if (stats != null) _inventoryStats = Map<String, int>.of(stats);
    notifyListeners();
  }

  @visibleForTesting
  void setServiceSubscribersForTesting(List<Map<String, dynamic>> subscribers) {
    _serviceSubscribers = List<Map<String, dynamic>>.of(subscribers);
    notifyListeners();
  }

  @visibleForTesting
  void setDevicesForTesting(List<DeviceInfo> devices, {DevicePresence? presence}) {
    _devices = List<DeviceInfo>.of(devices);
    if (presence != null) _presence = presence;
    notifyListeners();
  }

  @visibleForTesting
  void setPresenceForTesting(DevicePresence presence) {
    _presence = presence;
    notifyListeners();
  }

  /// Testlerde MQTT yerine doğrudan bir `state` anlık görüntüsü işler.
  @visibleForTesting
  void applyDeviceStateForTesting(DeviceStatus snapshot, {bool retained = false}) {
    _realtimeEpoch = _homeEpoch;
    _applyCloudSnapshot(snapshot, retained: retained);
  }

  // --- Hesap silme (E2) ---------------------------------------------------------------------
  // Arayüz paketi E2 tarafından eklenen AYRIK blok (D çekirdeğinin dışında).

  /// Hesabı kalıcı olarak siler; başarıda yerel oturum tamamen temizlenir (çıkış). Parolalı hesapta
  /// [password], sosyal giriş hesabında [confirm] (`SİL`) gerekir. Kullanıcı, başka üyesi ya da panosu olan
  /// bazı evlerin tek sahibi ise [ApiException.isSoleOwner] fırlatılır ve **hiçbir şey silinmez** (önce devir).
  /// Üyesiz + panosuz tek sahipli daireler engel değildir; sunucu onları da siler
  /// ([AccountDeletionResult.releasedHomes]).
  Future<AccountDeletionResult> deleteAccount({String? password, String? confirm}) async {
    if (!isAuthenticated || isServiceSession) throw ApiException.forbidden();
    final result = await cloudApi.deleteAccount(password: password, confirm: confirm);
    await logout();
    return result;
  }

  /// Davet / devir kodunun önizlemesi (ev adı, sakin sayısı). Sunucu ucu yoksa `null`.
  Future<JoinCodePreview?> previewJoinCode(String code) async {
    if (!isAuthenticated || isServiceSession) throw ApiException.forbidden();
    return cloudApi.previewJoinCode(code);
  }

  // --- Yasal metinler (Kullanıcı Sözleşmesi / KVKK) -------------------------------------------------------------
  // AYRIK blok. Sunucu sözleşmesi: `GET /legal`, `GET /legal/:id`, `POST /legal/accept`, kullanıcıdaki `legal` nesnesi.

  /// Oturumdaki kullanıcı, uygulamayı kullanmaya devam etmeden önce Kullanıcı Sözleşmesi'nin güncel sürümünü onaylamalı
  /// mı (`user.legal.needs_acceptance`; giriş kapısı `TermsAcceptancePage`'i gösterir). Sunucu bunu yalnız kesinleşmiş
  /// (`final`) metin için ve personel dışı hesaplarda `true` döndürür. Personel (süper yönetici / servis sorumlusu), servis
  /// PIN oturumu ve yerel ağ (LAN) kipinde HİÇBİR ZAMAN `true` değildir: ağ gerektiren bir onaya kullanıcı kilitlenmez.
  bool get needsTermsAcceptance {
    final user = _currentUser;
    if (user == null || !isAuthenticated || _mode != AppMode.cloud || isServiceSession) return false;
    if (user.isServiceManagerOrSuper || user.isServiceSession) return false;
    return user.legal.needsAcceptance;
  }

  /// Yasal metin listesi (herkese açık; kayıt ekranı güncel sözleşme sürümünü buradan alır).
  Future<List<LegalDocumentInfo>> fetchLegalDocuments() => cloudApi.fetchLegalDocuments();

  /// Tek yasal metin (`terms` | `privacy`; herkese açık).
  Future<LegalDocument> fetchLegalDocument(String id) => cloudApi.fetchLegalDocument(id);

  /// Kullanıcı Sözleşmesi'nin [version] sürümünü onaylar: `POST /legal/accept`, ardından kullanıcı `GET /auth/me` ile
  /// yenilenir (yetkili durum sunucudadır). Onay kaydedildi ama `/auth/me` alınamadıysa (ağ) yerel durum güncellenir:
  /// kullanıcı çıkmaza düşmez. Sürüm güncel değilse `409 LEGAL_VERSION_MISMATCH` ([ApiException.isLegalVersionMismatch])
  /// iletilir ve durum DEĞİŞMEZ (arayüz güncel metni yükleyip yeniden sorar). Servis PIN oturumunda yasak.
  Future<void> acceptTerms(int version) async {
    if (_currentUser == null || !isAuthenticated || isServiceSession) throw ApiException.forbidden();
    final epoch = _sessionEpoch;
    await cloudApi.acceptLegalDocument(document: LegalDocumentKind.terms.id, version: version);
    if (_isStaleSession(epoch)) return;
    var refreshed = false;
    try {
      refreshed = await refreshCurrentUser();
    } catch (e) {
      _log('Kullanıcı yenilenemedi (${e is ApiException ? e.statusCode : e.runtimeType})');
    }
    if (refreshed || _isStaleSession(epoch)) return;
    final current = _currentUser;
    if (current == null) return;
    _applyUserUpdate(current.copyWith(legal: current.legal.withAcceptedTerms(version)), epoch);
  }

  /// Oturumdaki kullanıcıyı sunucudan yeniler (`GET /auth/me`) ve saklar. `false`: oturum yok / servis oturumu / yanıt
  /// başka hesaba ait ya da çözülemedi (durum değişmez). Ağ ve sunucu hataları [ApiException] olarak iletilir.
  Future<bool> refreshCurrentUser() async {
    final user = _currentUser;
    if (user == null || user.id.isEmpty || !isAuthenticated || isServiceSession) return false;
    final epoch = _sessionEpoch;
    final payload = await cloudApi.fetchMe();
    if (_isStaleSession(epoch)) return false;
    final fresh = _userFromMe(payload);
    if (fresh == null || fresh.id != user.id) return false;
    _applyUserUpdate(fresh, epoch);
    return true;
  }

  /// Geri yüklenen bulut oturumunda yasal durumu sunucuyla eşitler (arka planda, sessiz): saklı kullanıcı kaydı eski
  /// olabilir (ör. sözleşme bu arada kesinleşti ya da yeni sürümü yayımlandı). YALNIZ `legal` alanı güncellenir (ad,
  /// rol gibi alanlar oturum açılışındaki davranışıyla kalır); ağ hatası yutulur ve saklı durum korunur (onay bekleyen
  /// kullanıcı kapıyı atlayamaz). Yanıt gelene kadar kullanıcı kaydı değiştiyse (ör. sözleşme onaylandı ve `GET /auth/me`
  /// ile yenilendi) bu yanıt ESKİDİR ve uygulanmaz: aksi halde onaydan önceki durum kapıyı yeniden açardı.
  Future<void> _syncLegalStatus(int epoch) async {
    final user = _currentUser;
    if (user == null || user.id.isEmpty || _mode != AppMode.cloud || isServiceSession || _isStaleSession(epoch)) return;
    try {
      final payload = await cloudApi.fetchMe();
      if (_isStaleSession(epoch) || !identical(_currentUser, user)) return;
      final fresh = _userFromMe(payload);
      if (fresh == null || fresh.id != user.id || fresh.legal == user.legal) return;
      _applyUserUpdate(user.copyWith(legal: fresh.legal), epoch);
    } catch (e) {
      _log('Yasal metin durumu alınamadı (${e is ApiException ? e.statusCode : e.runtimeType})');
    }
  }

  /// `GET /auth/me` yükündeki kullanıcı; yoksa / çözülemezse `null`.
  UserModel? _userFromMe(Map<String, dynamic> payload) {
    final map = asMap(payload['user']);
    if (map == null) return null;
    try {
      return UserModel.fromJson(map);
    } on FormatException {
      return null;
    }
  }

  /// Oturumdaki kullanıcı kaydını değiştirir, bildirir ve güvenli depoya yazar (oturum değiştiyse yazılmaz).
  void _applyUserUpdate(UserModel updated, int epoch) {
    _currentUser = updated;
    notifyListeners();
    unawaited(_enqueueStorage(() => secureStorage.saveUser(updated), epoch: epoch));
  }
}
