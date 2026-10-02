import 'dart:async';
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
import '../models/scheduled_rule_model.dart';
import '../utils/qr_claim_parser.dart';
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

/// Panjur komutlarının iyimser hedefi (yalnızca iç kullanım).
class _ShutterTarget {
  const _ShutterTarget({this.pos, this.moving, this.direction});

  final int? pos;
  final bool? moving;
  final int? direction;
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
        secureStorage = secureStorage ?? SecureStorageService(),
        biometricService = biometricService ?? BiometricAuthService(),
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

  /// Doğrudan modda cihazın anlık durumu (bekleyen komutların iyimser değerleriyle birlikte).
  DeviceStatus? get status => _viewStatus();

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

  /// Birleşik görünüm: aydınlatma / priz / darbe öğeleri (panjurlar hariç), moda göre.
  List<RelayItem> get relayItems => _mode == AppMode.cloud
      ? relayItemsFromEndpoints(cloudEndpoints)
      : (status?.controllableRelays ?? const <RelayItem>[]);

  /// Birleşik görünüm: **gerçek** panjurlar (benzersiz, `pair` 1 tabanlı), moda göre.
  List<ShutterItem> get shutterItems => _mode == AppMode.cloud
      ? shutterItemsFromEndpoints(cloudEndpoints, _runtimeView())
      : (status?.shutters ?? const <ShutterItem>[]);

  /// Cihazın bildirdiği LAN IP'si (MQTT `state.ip`); doğrudan mod için öneri.
  String? get lastKnownDeviceIp => _lastDeviceIp;

  String? get servicePin => _servicePin;
  DateTime? get servicePinExpiry => _servicePinExpiry;

  /// Rol → yetki (CONTRACTS §1.4). UI kapıları ve metot denetimleri bunu kullanır.
  Capabilities get capabilities {
    final user = _currentUser;
    if (user == null || _authStatus != AuthStatus.authenticated) {
      return _anonymousLocalKey ? const Capabilities.localKeyHolder() : const Capabilities.none();
    }
    final home = _activeHome;
    final now = clock.now();
    DateTime? validUntil = home?.guestValidUntil;
    if (home != null && home.isGuestRole && home.isGuestExpiredAt(now)) {
      validUntil = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
    return Capabilities(
      globalRole: user.role,
      homeRole: home?.role,
      guestValidUntil: validUntil,
      guestValidFrom: home?.guestValidFrom,
      now: now,
      hasActiveHome: home != null,
    );
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
  List<String> get childLockOfflineDevices => List<String>.unmodifiable(_childLockOfflineDevices);

  Map<String, dynamic>? get peaceNotificationData => _peaceNotificationData;

  /// [peaceNotificationData]'nın tipli görünümü (`enabled`/`peace_notification_enabled` ve
  /// `time`/`peace_notification_time` anahtar adlarının ikisini de okur).
  PeaceNotificationSettings? get peaceSettings {
    final data = _peaceNotificationData;
    return data == null ? null : PeaceNotificationSettings.fromJson(data);
  }

  List<ScheduledRule> get scheduledRules => List.unmodifiable(_scheduledRules);
  bool get scheduledRulesLoading => _scheduledRulesLoading;
  String? get scheduledRulesError => _scheduledRulesError;

  bool get isBiometricEnabled => _isBiometricEnabled;
  bool get isBiometricSupported => _isBiometricSupported;
  String get biometricLabel => _biometricLabel;
  bool get shouldPromptBiometrics => _shouldPromptBiometrics;
  bool get biometricChecking => _biometricChecking;
  bool get biometricFailed => _biometricFailed;

  List<InventoryDeviceModel> get inventoryDevices => List.unmodifiable(_inventoryDevices);
  Map<String, int> get inventoryStats => Map.unmodifiable(_inventoryStats);
  bool get inventoryLoading => _inventoryLoading;
  String? get inventoryError => _inventoryError;
  List<Map<String, dynamic>> get serviceSubscribers => List.unmodifiable(_serviceSubscribers);
  bool get subscribersLoading => _subscribersLoading;
  String? get subscribersError => _subscribersError;

  /// Oturum sona erdiğinde giriş ekranında gösterilecek tek seferlik mesaj.
  String? get sessionNotice => _sessionNotice;

  /// Güvenli depolama hatası (oturum cihaza kaydedilemedi vb.). `null` = hata yok.
  String? get storageError => _storageError;

  /// Doğrudan moddaki son hata (anahtar geçersiz, adres yok ...).
  String? get directError => _directError;

  String get selectedDeviceUuid => _selectedDeviceUuid;
  String get selectedDeviceIp => _selectedDeviceIp;
  String get selectedDeviceName =>
      _selectedDeviceName ?? (_selectedDeviceUuid.isEmpty ? '' : _selectedDeviceUuid);
  bool get hasSelectedDevice => _selectedDeviceUuid.isNotEmpty;

  /// Doğrudan mod için yerel cihaz anahtarı kayıtlı mı.
  bool get hasLocalKey => directApi.localKey?.isNotEmpty ?? false;

  int get openLightsCount {
    if (_mode == AppMode.cloud) {
      return cloudEndpoints.where((e) => e.isLight && e.currentState).length;
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
    final prefs = await SharedPreferences.getInstance();
    _installId = _loadInstallId(prefs);

    // Eski sürümlerin SharedPreferences'a yazdığı belirteç yedeği silinir (artık yalnızca SecureStorage).
    if (prefs.containsKey(_prefsLegacyToken)) await prefs.remove(_prefsLegacyToken);

    _host = prefs.getString(_prefsHost) ?? '';
    directApi.updateHost(_host);

    final savedTheme = prefs.getString(_prefsTheme);
    _themeMode = savedTheme == 'light'
        ? ThemeMode.light
        : (savedTheme == 'system' ? ThemeMode.system : ThemeMode.dark);

    // Bulut-öncelikli: kayıt yoksa bulut.
    _mode = prefs.getString(_prefsMode) == 'direct' ? AppMode.direct : AppMode.cloud;

    _selectedDeviceUuid = prefs.getString(_prefsSvcUuid) ?? '';
    _selectedDeviceIp = prefs.getString(_prefsSvcIp) ?? '';
    _selectedDeviceName = prefs.getString(_prefsSvcName);

    _isBiometricSupported = await biometricService.isBiometricSupported();
    if (_isBiometricSupported) _biometricLabel = await biometricService.getBiometricLabel();

    // Belirteçler: yalnızca SecureStorage. Okuma hatası "oturum yok" ile karıştırılmaz.
    String? token;
    String? refresh;
    ServiceSessionInfo? serviceInfo;
    UserModel? storedUser;
    try {
      token = await secureStorage.getAuthToken();
      refresh = await secureStorage.getRefreshToken();
      storedUser = await secureStorage.getUser();
      serviceInfo = await secureStorage.getServiceSession();
    } on SecureStorageException catch (e) {
      _storageError = e.message;
    }

    // Biyometrik tercih: okunamazsa kilit AÇIK varsayılır (fail-closed).
    try {
      _isBiometricEnabled = await secureStorage.isBiometricEnabled();
    } on SecureStorageException catch (e) {
      _storageError ??= e.message;
      _isBiometricEnabled = _isBiometricSupported;
    }

    final hasTokens = (token != null && token.isNotEmpty) || (refresh != null && refresh.isNotEmpty);
    if (!hasTokens) {
      _authStatus = AuthStatus.unauthenticated;
      await _afterInitWithoutSession();
      return;
    }

    // Servis oturumu: süresi dolmamışsa geri yükle, dolduysa sil.
    if (serviceInfo != null) {
      if (serviceInfo.isExpiredAt(clock.now()) || token == null) {
        await _wipeStorageQuietly();
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
        // Kullanıcı bilinmiyor ve belirteçten de türetilemiyor: bozuk kayıt, temiz başla.
        cloudApi.clearSession();
        await _wipeStorageQuietly();
        _authStatus = AuthStatus.unauthenticated;
        await _afterInitWithoutSession();
        return;
      }
    }

    _pendingRestore = true;
    if (_isBiometricEnabled && _isBiometricSupported) {
      // Kilitliyken ağ / MQTT BAŞLAMAZ: önce biyometrik doğrulama.
      _awaitingUnlock = true;
      _authStatus = AuthStatus.checking;
      notifyListeners();
      await _unlockWithBiometrics();
      return;
    }
    await _startSession();
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
  }

  // ---------------------------------------------------------------------------
  // Depolama kuyruğu (sıralı yazma; çıkıştan sonra eski oturum yazamaz)
  // ---------------------------------------------------------------------------

  /// Depolama işlemlerini sıraya alır. [epoch] verilirse ve bu arada oturum değiştiyse işlem
  /// **çalıştırılmaz** (çıkıştan sonra gecikmeli token yazımı olmaz). Hatalar yutulmaz:
  /// [storageError] olarak yüzeye çıkar.
  Future<void> _enqueueStorage(Future<void> Function() operation, {int? epoch}) {
    final run = _storageQueue.then((_) async {
      if (epoch != null && epoch != _sessionEpoch) return;
      try {
        await operation();
      } on SecureStorageException catch (e) {
        _storageError = e.message;
        notifyListeners();
      } catch (_) {
        _storageError = 'Güvenli depolama kullanılamıyor.';
        notifyListeners();
      }
    });
    _storageQueue = run;
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
      await secureStorage.saveAuthToken(accessToken);
      if (refreshToken != null && refreshToken.isNotEmpty) {
        await secureStorage.saveRefreshToken(refreshToken);
      }
    }, epoch: epoch);
  }

  Future<void> _wipeStorageQuietly() => _enqueueStorage(() => secureStorage.clearAll());

  Future<void> _clearUserPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsLegacyToken);
      await prefs.remove(_prefsMode);
      await prefs.remove(_prefsHost);
      await prefs.remove(_prefsSvcUuid);
      await prefs.remove(_prefsSvcIp);
      await prefs.remove(_prefsSvcName);
      await prefs.remove(_prefsActiveHome);
    } catch (_) {}
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

    _selectedDeviceUuid = '';
    _selectedDeviceIp = '';
    _selectedDeviceName = null;
    _host = '';
    directApi.updateHost('');
    directApi.localKey = null;
    _directError = null;
    _directFailures = 0;
    _localKeyRefreshTried = false;
    _status = null;
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
    _endpointView = null;
    _endpointsLoading = false;
    _endpointsLoaded = false;
    _endpointsError = null;
    _cloudRefreshFlight = null;
    _devices = const [];
    _presence = DevicePresence.unknown;
    _shutterRuntime.clear();
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
    _status = null;
    _directFailures = 0;
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
    // İletildi ama cihaz doğrulamadı: komut uygulanmış olabilir; gerçek durumu hemen yeniden oku.
    if (failure.reason == CommandFailureReason.timeout &&
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
    if (!isAuthenticated || isServiceSession) {
      if (isServiceSession) await refresh(silent: true);
      return;
    }
    await fetchHomes(autoSelect: false);
    await refresh(silent: true);
    await _startRealtime();
  }

  @visibleForTesting
  bool get isInBackground => _inBackground;

  // ---------------------------------------------------------------------------
  // Biyometrik güvenlik
  // ---------------------------------------------------------------------------

  Future<bool> _unlockWithBiometrics() async {
    _biometricChecking = true;
    _biometricFailed = false;
    _authStatus = AuthStatus.checking;
    notifyListeners();
    final ok = await biometricService.authenticate(
      reason: 'AHBU Ev Otomasyonu için $_biometricLabel doğrulaması yapın',
    );
    _biometricChecking = false;
    if (_isDisposed) return false;
    if (!ok) {
      _biometricFailed = true;
      notifyListeners();
      return false;
    }
    _biometricFailed = false;
    _awaitingUnlock = false;
    if (_pendingRestore) {
      await _startSession();
    } else {
      _authStatus = AuthStatus.authenticated;
      notifyListeners();
      await _resumeSession();
    }
    return true;
  }

  /// Biyometrik doğrulamayı yeniden dener; başarıda oturum ağ/MQTT ile başlatılır.
  Future<bool> retryBiometricAuth() => _unlockWithBiometrics();

  /// Şifre ile girişe düş: yerel belirteçler/MQTT temizlenir ve refresh token sunucuda iptal edilir.
  Future<void> fallbackToPasswordLogin() => logout();

  /// Biyometrik girişi aç/kapat. **Her iki yönde de doğrulama istenir** (kapatmak için de).
  Future<bool> toggleBiometric(bool enabled) async {
    if (enabled == _isBiometricEnabled) return true;
    if (!_isBiometricSupported) return false;
    final verified = await biometricService.authenticate(
      reason: enabled
          ? 'AHBU Ev Otomasyonu için $_biometricLabel girişini etkinleştirin'
          : 'Biyometrik girişi kapatmak için kimliğinizi doğrulayın',
    );
    if (!verified) return false;
    _isBiometricEnabled = enabled;
    unawaited(_enqueueStorage(() => secureStorage.saveBiometricEnabled(enabled), epoch: _sessionEpoch));
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

  Future<bool> login(String identifier, String password) async {
    final previous = cloudApi.currentRefreshToken;
    final res = await cloudApi.login(identifier, password);
    return _handleAuthSuccess(res, previousRefreshToken: previous);
  }

  Future<bool> register({
    required String fullName,
    required String email,
    required String password,
    String? phone,
  }) async {
    final previous = cloudApi.currentRefreshToken;
    final res = await cloudApi.register(
      fullName: fullName,
      email: email,
      password: password,
      phone: phone,
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
  Future<bool> resetPassword({
    String? identifier,
    String? code,
    String? token,
    required String newPassword,
  }) async {
    final previous = cloudApi.currentRefreshToken;
    final res = await cloudApi.resetPassword(
      identifier: identifier,
      code: code,
      token: token,
      newPassword: newPassword,
    );
    if (res['user'] != null && (res['access_token'] != null || res['token'] != null)) {
      return _handleAuthSuccess(res, previousRefreshToken: previous);
    }
    return true;
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
    final res = await cloudApi.changePassword(
      currentPassword: currentPassword,
      newPassword: newPassword,
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
      await cloudApi.logoutAll(); // başarıda yerel belirteçler de silinir
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
    }, epoch: epoch));
    unawaited(_clearUserPrefs());
    if (previousRefreshToken != null && previousRefreshToken != refresh) {
      unawaited(cloudApi.revokeRefreshToken(previousRefreshToken));
    }

    // İlk giriş sonrası biyometrik istem kararı.
    try {
      final promptShown = await secureStorage.isBiometricPromptShown();
      final supported = await biometricService.isBiometricSupported();
      _isBiometricSupported = supported;
      if (supported) _biometricLabel = await biometricService.getBiometricLabel();
      _shouldPromptBiometrics = supported && !promptShown;
    } on SecureStorageException {
      _shouldPromptBiometrics = false;
    }
    notifyListeners();

    // Ev listesi (rol dahil) ve ilk ev.
    await fetchHomes();
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

    // Yalnızca refresh token varsa önce yenile.
    if (cloudApi.authToken == null && cloudApi.currentRefreshToken != null) {
      try {
        final ok = await cloudApi.refreshSession();
        if (!ok || epoch != _sessionEpoch) return; // oturum sona erdi (olay üretildi)
      } on ApiException catch (e) {
        _log('Oturum yenilenemedi (${e.statusCode})');
      }
    }

    await fetchHomes(autoSelect: false);
    if (epoch != _sessionEpoch) return;
    _authStatus = AuthStatus.authenticated;
    notifyListeners();

    if (_mode == AppMode.direct) {
      await _prepareDirect();
      _startPolling();
      await refresh();
    } else {
      unawaited(_selectInitialHome());
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
    if (_currentUser == null) return;
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

  void _persistHomesCache(List<HomeModel> homes) {
    final user = _currentUser;
    if (user == null || user.id.isEmpty) return;
    unawaited(_enqueueStorage(() => secureStorage.saveHomesCache(user.id, homes), epoch: _sessionEpoch));
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
    final pick = await _pickInitialHome();
    if (pick != null && _activeHome == null) await selectHome(pick);
  }

  /// Aktif evi değiştirir: ev kapsamlı **tüm** önbellekler (uç noktalar, cihazlar, durum, kurallar,
  /// servis PIN, bekleyen komutlar, MQTT) sıfırlanır; yeni evin verisi yüklenir.
  Future<void> selectHome(HomeModel home) async {
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
      await refresh();
      await _startRealtime();
    } else {
      await _prepareDirect();
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

  /// Bulut / doğrudan mod. Doğrudan moda yalnızca yetkili kullanıcılar (veya oturumsuz yerel mod)
  /// geçebilir; reddedilirse `false` döner.
  Future<bool> setMode(AppMode newMode) async {
    if (newMode == _mode) return true;
    if (newMode == AppMode.direct && isAuthenticated && !capabilities.canSwitchMode) return false;

    _pipeline.cancelAll();
    _mode = newMode;
    _resetChildLockKnowledge(); // kaynak değişti (LAN <-> bulut)
    unawaited(_saveMode(newMode));
    notifyListeners();

    if (newMode == AppMode.direct) {
      unawaited(mqttService.stop());
      _mqttLink = MqttLinkState.disconnected;
      _status = null;
      _directFailures = 0;
      _connState = ConnectionStateEnum.connecting;
      await _prepareDirect();
      _startPolling();
      await refresh();
    } else {
      _pollTimer?.cancel();
      _pollTimer = null;
      _status = null;
      if (isAuthenticated) {
        if (_activeHome != null) {
          await refresh();
          await _startRealtime();
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
    try {
      await (await SharedPreferences.getInstance()).setString(_prefsHost, _host);
    } catch (_) {}
    _connState = ConnectionStateEnum.connecting;
    _directFailures = 0;
    _status = null;
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
    final uuid = _localKeyDeviceUuid();
    if (uuid != null) {
      await _enqueueStorage(() => secureStorage.saveLocalKey(uuid, clean));
    }
    notifyListeners();
  }

  /// Bir cihazın yerel anahtarı: önce güvenli depolama, yoksa (yetkiliyse) sunucudan alınıp saklanır.
  ///
  /// [homeId]: cihazın bağlı olduğu ev (verilmezse aktif ev). Servis sihirbazında **az önce sahiplenilen
  /// ev aktif ev değildir** (`claimDevice` servis akışında evi seçmez): `homeId: claim.homeId` verin.
  /// Aktif olmayan ev için istemci yetki kapısı yoktur (sunucu karar verir: owner/resident/staff/servis
  /// oturumu; süper kullanıcı ✖ olduğundan hiç sorulmaz).
  Future<String?> localKeyFor(String deviceUuid, {String? homeId, bool forceRefresh = false}) async {
    final uuid = QrClaimParser.normalizeUid(deviceUuid);
    if (uuid == null) return null;
    String? key;
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
        final saved = key;
        await _enqueueStorage(() => secureStorage.saveLocalKey(uuid, saved));
      } on ApiException catch (e) {
        _directError = e.message;
      }
    }
    return key;
  }

  String? _localKeyDeviceUuid() {
    if (_selectedDeviceUuid.isNotEmpty) return _selectedDeviceUuid;
    final ref = _primaryDeviceRef();
    return ref == null ? null : QrClaimParser.normalizeUid(ref);
  }

  Future<void> _resolveLocalKey({bool forceRefresh = false}) async {
    final uuid = _localKeyDeviceUuid();
    if (uuid == null) return;
    final key = await localKeyFor(uuid, forceRefresh: forceRefresh);
    if (key != null) directApi.localKey = key;
    notifyListeners();
  }

  Future<void> _prepareDirect() async {
    directApi.updateHost(_host);
    if (directApi.localKey == null) await _resolveLocalKey();
  }

  // ---------------------------------------------------------------------------
  // Yenileme (snapshot)
  // ---------------------------------------------------------------------------

  /// Tek bir anlık görüntü alır: doğrudan modda cihaz durumu; bulutta evler (aktif ev yoksa) ve
  /// aktif evin uç noktaları/cihazları.
  Future<void> refresh({bool silent = false}) async {
    if (_mode == AppMode.direct) {
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

    await Future.wait<void>([
      _loadEndpoints(home, epoch, silent: silent),
      _loadDevices(home, epoch),
      _loadChildLock(home, epoch), // salt-okunur görüntüleme herkese (misafir dahil); değiştirme ayrıca kapılı
      if (caps.canChangeChildLock) fetchPeaceNotification(),
    ]);
  }

  Future<void> _loadEndpoints(HomeModel home, int epoch, {required bool silent}) async {
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
      if (live != null && liveAt != null && liveAt.isAfter(requestedAt)) {
        next = applyStatusToEndpoints(next, live).endpoints;
      }
      _cloudEndpoints = next;
      _endpointView = null;
      _endpointsLoaded = true;
      _endpointsError = null;
      // MQTT kopukken komut onayı REST yoklamasından da doğrulanabilir.
      _pipeline.observe(statusFromEndpoints(next));
    } on ApiException catch (e) {
      if (epoch != _homeEpoch) return;
      if (!e.isUnauthorized) _endpointsError = e.message;
    } catch (_) {
      if (epoch == _homeEpoch) _endpointsError = 'Cihazlar yüklenemedi. Lütfen tekrar deneyin.';
    } finally {
      if (epoch == _homeEpoch) {
        _endpointsLoading = false;
        _endpointView = null;
        notifyListeners();
      }
    }
  }

  Future<void> _loadDevices(HomeModel home, int epoch) async {
    try {
      final list = await cloudApi.devices(home.id);
      if (epoch != _homeEpoch) return;
      _devices = list;
      // Canlı `status` kanalı yokken (veya henüz bilinmiyorsa) REST bilgisi kullanılır.
      if (list.isNotEmpty && (_presence == DevicePresence.unknown || !brokerConnected)) {
        _presence = list.any((d) => d.online) ? DevicePresence.online : DevicePresence.offline;
      }
      notifyListeners();
    } on ApiException catch (e) {
      _log('Cihaz listesi alınamadı (${e.statusCode})');
    } catch (_) {}
  }

  /// REST çocuk kilidi anlık görüntüsü. **Cihaz bildirimi esastır**: canlı kanal bağlıyken cihazdan
  /// değer biliniyorsa veya istek sırasında daha yeni bir cihaz bildirimi geldiyse REST sonucu
  /// uygulanmaz (bayat GET, daha yeni MQTT durumunu ezmesin). Hata/401/403/5xx durumunda değer
  /// "kapalı"ya DÖNMEZ: bilinmiyorsa bilinmiyor kalır.
  Future<void> _loadChildLock(HomeModel home, int epoch) async {
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
        notifyListeners();
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
      notifyListeners();
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

  Future<void> _startRealtime() async {
    if (_mode != AppMode.cloud ||
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
    await mqttService.start(
      credentialsProvider: () {
        if (epoch != _homeEpoch) {
          throw const ApiException(statusCode: 404, code: 'STALE', message: 'Ev değişti.');
        }
        return cloudApi.mqttCredentials(home.id);
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
  void _applyCloudSnapshot(DeviceStatus snapshot, {required bool retained}) {
    final sync = applyStatusToEndpoints(_cloudEndpoints, snapshot);
    if (sync.changed) {
      _cloudEndpoints = sync.endpoints;
    }
    for (final shutter in snapshot.shutters) {
      _shutterRuntime[shutter.pair] = ShutterRuntime(
        moving: shutter.isMoving,
        direction: shutter.direction,
        target: shutter.target,
      );
    }
    if (snapshot.childLockKnown) {
      _childLockByUid[snapshot.uid ?? ''] = snapshot.childLock;
      _childLockDeviceAt = clock.now();
      _childLockUpdatedAt = _childLockDeviceAt;
    }
    if (snapshot.ip.isNotEmpty) _lastDeviceIp = snapshot.ip;
    if (!retained) {
      // Canlı ileti = cihaz yaşıyor (retained "offline" status'u da düzeltilir). Saklı/retained
      // `state` çevrimiçiliği KANITLAMAZ.
      _presence = DevicePresence.online;
      _lastLiveStateAt = clock.now();
    }
    _lastLiveSnapshot = snapshot;
    _lastLiveSnapshotAt = clock.now();
    _pipeline.observe(snapshot);
    _endpointView = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Doğrudan (LAN) mod: tek-uçuşlu yoklama
  // ---------------------------------------------------------------------------

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (_inBackground || _mode != AppMode.direct) return;
    _pollTimer = clock.periodic(_directPollInterval, (_) {
      if (!_isDisposed && _mode == AppMode.direct && !_inBackground) {
        unawaited(_directRefresh(silent: true));
      }
    });
  }

  /// Aynı anda yalnızca **bir** istek uçuşta olur; ardışık 3 hata sonrası cihaz çevrimdışı sayılır
  /// (kullanıcı tetiklemeli yenilemede ilk hatada).
  Future<void> _directRefresh({required bool silent}) {
    final existing = _pollInFlight;
    if (existing != null) return existing;
    late final Future<void> future;
    future = _directRefreshImpl(silent).whenComplete(() {
      if (identical(_pollInFlight, future)) _pollInFlight = null;
    });
    _pollInFlight = future;
    return future;
  }

  Future<void> _directRefreshImpl(bool silent) async {
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
    var changed = false;
    try {
      final st = await directApi.fetchStatus();
      if (epoch != _homeEpoch || _mode != AppMode.direct) return;
      final previous = _status;
      if (st.restricted) {
        // Anahtarsız kısıtlı özet: cihaza ulaşıldı ama kontrol edilemez ("boş cihaz" sanılmaz).
        changed = previous != null;
        _directFailures = 0;
        _status = null;
        _connState = ConnectionStateEnum.connected;
        _directError = st.provisioned == false
            ? 'Cihaz henüz kurulmamış. Servis kurulumunu tamamlayın.'
            : 'Cihaz anahtarı gerekli. Anahtarı girin veya hesabınızla giriş yapın.';
        if (st.provisioned != false && !_localKeyRefreshTried && isAuthenticated) {
          _localKeyRefreshTried = true;
          await _resolveLocalKey(forceRefresh: true);
        }
        if (epoch == _homeEpoch) {
          _endpointView = null;
          notifyListeners();
        }
        return;
      }
      changed = previous == null || !previous.sameAs(st);
      _directFailures = 0;
      _directError = null;
      _status = st;
      if (st.childLockKnown) {
        final before = _childLockByUid['_lan'];
        _childLockByUid['_lan'] = st.childLock;
        _childLockDeviceAt = clock.now();
        if (before != st.childLock) _childLockUpdatedAt = _childLockDeviceAt;
      }
      if (st.ip.isNotEmpty) _lastDeviceIp = st.ip;
      _connState = ConnectionStateEnum.connected;
      _pipeline.observe(st);
    } on LocalApiException catch (e) {
      if (epoch != _homeEpoch) return;
      if (e.isUnauthorized || e.isUnprovisioned) {
        // Cihaza ulaşıldı ama anahtar geçersiz/yok: bir kez sunucudan yeniden al.
        _directError = e.message;
        _directFailures = 0;
        if (!_localKeyRefreshTried && isAuthenticated) {
          _localKeyRefreshTried = true;
          await _resolveLocalKey(forceRefresh: true);
        }
      } else {
        _directFailures++;
        if (!silent || _directFailures >= 3) _connState = ConnectionStateEnum.offline;
        _directError = e.message;
      }
    } catch (_) {
      _directFailures++;
      if (!silent || _directFailures >= 3) _connState = ConnectionStateEnum.offline;
    }
    if (epoch == _homeEpoch) {
      // Değişim yoksa bildirme: her 1.5 sn yoklamada tüm arayüz yeniden çizilmesin.
      if (changed || _connState != beforeConn || _directError != beforeError) {
        _endpointView = null;
        notifyListeners();
      }
    }
  }

  void _pollSoon() {
    _reconcileTimer?.cancel();
    _reconcileTimer = clock.timer(const Duration(milliseconds: 250), () {
      if (_mode == AppMode.direct && !_inBackground) unawaited(_directRefresh(silent: true));
    });
  }

  /// MQTT kopukken (iyimser değer onay penceresinde) REST ile gerçek durumu yeniden oku.
  void _scheduleReconcile() {
    _reconcileTimer?.cancel();
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

  void _onPipelineChanged() {
    _endpointView = null;
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

  void _reject(String key, String message, {CommandFailureReason reason = CommandFailureReason.rejected}) {
    _pipeline.emitFailure(CommandFailure(key: key, reason: reason, message: message));
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
  }) async {
    final effective = mode ?? _stateConfirmMode;
    final dispatch = await _pipeline.submit(
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
  }) async =>
      (await _submit(
        key: key,
        original: original,
        target: target,
        send: send,
        confirms: confirms,
        mode: mode,
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
      send: (id) => cloudApi.sendCommand(
        homeId: home.id,
        deviceId: ref,
        command: <String, dynamic>{'shutter': pair, 'pos': percent, 'id': id},
      ),
      confirms: CommandConfirm.shutterPosition(pair, percent),
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

  Future<Map<String, dynamic>?> fetchPeaceNotification() async {
    final home = _activeHome;
    if (_mode != AppMode.cloud || home == null || !capabilities.canChangeChildLock) return null;
    final epoch = _homeEpoch;
    try {
      final data = await cloudApi.getPeaceNotification(home.id);
      if (epoch != _homeEpoch) return null;
      _peaceNotificationData = data;
      notifyListeners();
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
    if (epoch != _homeEpoch) return token.pin;
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
    await fetchHomes(autoSelect: false);
    if (!isStaffFlow) {
      final claimed = homeById(result.homeId);
      if (claimed != null) await selectHome(claimed);
    }
    notifyListeners();
    return result;
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
    await fetchHomes(autoSelect: false);
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
    await refresh(silent: true);
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
    _endpointView = null;
    notifyListeners();
  }

  @visibleForTesting
  void setCloudEndpointsForTesting(List<EndpointModel> value) {
    _cloudEndpoints = List<EndpointModel>.of(value);
    _endpointView = null;
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
  /// [password], sosyal giriş hesabında [confirm] (`SİL`) gerekir. Kullanıcı bazı evlerin tek sahibi
  /// ise [ApiException.isSoleOwner] fırlatılır ve **hiçbir şey silinmez** (önce devir).
  Future<void> deleteAccount({String? password, String? confirm}) async {
    if (!isAuthenticated || isServiceSession) throw ApiException.forbidden();
    await cloudApi.deleteAccount(password: password, confirm: confirm);
    await logout();
  }

  /// Davet / devir kodunun önizlemesi (ev adı, sakin sayısı). Sunucu ucu yoksa `null`.
  Future<JoinCodePreview?> previewJoinCode(String code) async {
    if (!isAuthenticated || isServiceSession) throw ApiException.forbidden();
    return cloudApi.previewJoinCode(code);
  }
}
