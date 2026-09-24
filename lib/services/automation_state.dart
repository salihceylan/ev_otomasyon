import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/automation_models.dart';
import '../models/cloud_models.dart';
import '../models/scheduled_rule_model.dart';
import 'automation_api_service.dart';
import 'ev_cloud_api_service.dart';
import 'ev_mqtt_service.dart';
import 'secure_storage_service.dart';
import 'biometric_auth_service.dart';

enum ConnectionStateEnum { connecting, connected, offline }
enum AppMode { direct, cloud }
enum AuthStatus { checking, authenticated, unauthenticated }

class AutomationState extends ChangeNotifier {
  final AutomationApiService directApi = AutomationApiService();
  final EvCloudApiService cloudApi = EvCloudApiService();
  final EvMqttService mqttService = EvMqttService();
  final SecureStorageService secureStorage = SecureStorageService();
  final BiometricAuthService biometricService = BiometricAuthService();

  AppMode _mode = AppMode.direct;
  AuthStatus _authStatus = AuthStatus.checking;
  DeviceStatus? _status;
  ConnectionStateEnum _connState = ConnectionStateEnum.connecting;
  String _host = '192.168.1.30';
  Timer? _pollTimer;
  bool _isDisposed = false;

  // Cloud & Multi-Tenant State
  UserModel? _currentUser;
  List<HomeModel> _homes = [];
  HomeModel? _activeHome;
  List<EndpointModel> _cloudEndpoints = [];
  bool _isMqttConnected = false;
  String? _servicePin;
  DateTime? _servicePinExpiry;

  // Rollback Cache for Optimistic UI
  final Map<int, bool> _optimisticRelayStates = {};
  final Map<int, int> _optimisticShutterPositions = {};

  AppMode get mode => _mode;
  AuthStatus get authStatus => _authStatus;
  bool get isAuthenticated => _authStatus == AuthStatus.authenticated;
  DeviceStatus? get status => _status;
  ConnectionStateEnum get connState => _connState;
  String get host => _host;
  bool get isConnected {
    if (_mode == AppMode.cloud) {
      return _isMqttConnected || _connState == ConnectionStateEnum.connected;
    }
    return _connState == ConnectionStateEnum.connected;
  }

  UserModel? get currentUser => _currentUser;
  AutomationApiService get api => directApi;
  List<HomeModel> get homes => _homes;
  HomeModel? get activeHome => _activeHome;
  List<EndpointModel> get cloudEndpoints => _cloudEndpoints;
  bool get isMqttConnected => _isMqttConnected;
  String? get servicePin => _servicePin;
  DateTime? get servicePinExpiry => _servicePinExpiry;
  bool get isServiceMode => _currentUser?.role == 'installer';
  bool get isInstaller => _currentUser?.role == 'installer';
  bool get isOwner => _currentUser?.role == 'owner';
  bool get isMember => _currentUser?.role == 'member';
  bool get isGuest => _currentUser?.role == 'guest';

  // ADIM 17: Çocuk Kilidi & Gece Huzur Bildirimi
  bool _childLock = false;
  bool get childLock => _childLock;
  Map<String, dynamic>? _peaceNotificationData;
  Map<String, dynamic>? get peaceNotificationData => _peaceNotificationData;

  // ADIM 18: Zamanlı Otomasyon Kuralları
  List<ScheduledRule> _scheduledRules = [];
  List<ScheduledRule> get scheduledRules => List.unmodifiable(_scheduledRules);
  bool _scheduledRulesLoading = false;
  bool get scheduledRulesLoading => _scheduledRulesLoading;

  // ADIM 19: Biyometrik Güvenlik & Anlık Giriş
  bool _isBiometricEnabled = false;
  bool get isBiometricEnabled => _isBiometricEnabled;
  bool _isBiometricSupported = false;
  bool get isBiometricSupported => _isBiometricSupported;
  String _biometricLabel = 'Biyometrik Giriş';
  String get biometricLabel => _biometricLabel;
  bool _shouldPromptBiometrics = false;
  bool get shouldPromptBiometrics => _shouldPromptBiometrics;
  bool _biometricChecking = false;
  bool get biometricChecking => _biometricChecking;
  bool _biometricFailed = false;
  bool get biometricFailed => _biometricFailed;

  int get openLightsCount {
    if (_mode == AppMode.cloud) {
      return _cloudEndpoints.where((e) => e.isLight && e.currentState).length;
    } else if (_status != null) {
      return _status!.relays.where((r) => r.isLight && r.state).length;
    }
    return 0;
  }

  // TEMA YÖNETİMİ: Karanlık / Aydınlık Mod (Varsayılan: Karanlık)
  ThemeMode _themeMode = ThemeMode.dark;
  ThemeMode get themeMode => _themeMode;

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_theme_mode', mode.name);
    } catch (e) {
      debugPrint('Tema modu kaydedilemedi: $e');
    }
  }

  @visibleForTesting
  void setThemeModeForTesting(ThemeMode mode) {
    _themeMode = mode;
    notifyListeners();
  }

  @visibleForTesting
  void setStatusForTesting(DeviceStatus? val) {
    _status = val;
    notifyListeners();
  }

  @visibleForTesting
  void setCloudEndpointsForTesting(List<EndpointModel> val) {
    _cloudEndpoints = val;
    notifyListeners();
  }

  @visibleForTesting
  void setModeForTesting(AppMode val) {
    _mode = val;
    notifyListeners();
  }

  @visibleForTesting
  void setScheduledRulesForTesting(List<ScheduledRule> rules) {
    _scheduledRules = List.from(rules);
    notifyListeners();
  }

  AutomationState() {
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    _host = prefs.getString('saved_esp_host') ?? '192.168.1.30';
    directApi.updateHost(_host);

    // Kayıtlı tema modunu yükle (Varsayılan: Karanlık)
    final savedTheme = prefs.getString('saved_theme_mode');
    if (savedTheme == 'light') {
      _themeMode = ThemeMode.light;
    } else if (savedTheme == 'system') {
      _themeMode = ThemeMode.system;
    } else {
      _themeMode = ThemeMode.dark;
    }

    final savedMode = await secureStorage.getAppMode() ?? prefs.getString('saved_app_mode');
    // Bulut-öncelikli (Cloud-first) mimari: Dış ağ ve mobil veride kopma olmaması için varsayılan buluttur
    if (savedMode == 'direct') {
      _mode = AppMode.direct;
    } else {
      _mode = AppMode.cloud;
    }

    cloudApi.onTokenRefreshed = (newAccess, newRefresh) async {
      await secureStorage.saveAuthToken(newAccess);
      if (newRefresh != null && newRefresh.isNotEmpty) {
        await secureStorage.saveRefreshToken(newRefresh);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_auth_token', newAccess);
    };

    // Güvenli depolamadan şifreli access ve refresh token'ları oku
    final secureToken = await secureStorage.getAuthToken();
    final savedToken = secureToken ?? prefs.getString('saved_auth_token');
    final savedRefreshToken = await secureStorage.getRefreshToken();

    if (savedRefreshToken != null && savedRefreshToken.isNotEmpty) {
      cloudApi.setRefreshToken(savedRefreshToken);
    }

    _isBiometricSupported = await biometricService.isBiometricSupported();
    _isBiometricEnabled = await secureStorage.isBiometricEnabled();
    if (_isBiometricSupported) {
      _biometricLabel = await biometricService.getBiometricLabel();
    }

    if (savedToken != null && savedToken.isNotEmpty) {
      cloudApi.setAuthToken(savedToken);
      _currentUser = await secureStorage.getUser();
      try {
        await fetchHomes();
        await _checkBiometricOnLaunch();
        if (_mode == AppMode.cloud && _activeHome != null) {
          await _connectMqttForHome(_activeHome!);
        }
      } catch (e) {
        // Access token süresi dolmuş olabilir (15 dk); 1 yıllık refresh token ile sessizce kurtar
        if (savedRefreshToken != null && savedRefreshToken.isNotEmpty) {
          try {
            final refreshed = await cloudApi.refreshToken(token: savedRefreshToken);
            final newAccess = (refreshed['access_token'] ?? refreshed['token']) as String;
            await secureStorage.saveAuthToken(newAccess);
            if (refreshed['refresh_token'] != null) {
              await secureStorage.saveRefreshToken(refreshed['refresh_token'] as String);
            }
            await fetchHomes();
            await _checkBiometricOnLaunch();
            if (_mode == AppMode.cloud && _activeHome != null) {
              await _connectMqttForHome(_activeHome!);
            }
          } catch (rfErr) {
            debugPrint('Refresh token ile oturum yenilenemedi: $rfErr');
            _authStatus = AuthStatus.unauthenticated;
          }
        } else {
          debugPrint('Kayıtlı oturum yenilenemedi: $e');
          _authStatus = AuthStatus.unauthenticated;
        }
      }
    } else if (savedRefreshToken != null && savedRefreshToken.isNotEmpty) {
      // Yalnızca refresh token kalmışsa bile yeni access token alıp otomatik gir
      try {
        final refreshed = await cloudApi.refreshToken(token: savedRefreshToken);
        final newAccess = (refreshed['access_token'] ?? refreshed['token']) as String;
        await secureStorage.saveAuthToken(newAccess);
        if (refreshed['refresh_token'] != null) {
          await secureStorage.saveRefreshToken(refreshed['refresh_token'] as String);
        }
        _currentUser = await secureStorage.getUser();
        await fetchHomes();
        await _checkBiometricOnLaunch();
        if (_mode == AppMode.cloud && _activeHome != null) {
          await _connectMqttForHome(_activeHome!);
        }
      } catch (e) {
        _authStatus = AuthStatus.unauthenticated;
      }
    } else {
      _authStatus = AuthStatus.unauthenticated;
    }

    if (_mode == AppMode.direct) {
      await refresh();
      _startPolling();
    }
    if (_isDisposed) return;
    notifyListeners();
  }

  Future<void> _checkBiometricOnLaunch() async {
    if (_isBiometricEnabled && _isBiometricSupported) {
      _biometricChecking = true;
      notifyListeners();
      final authenticated = await biometricService.authenticate(
        reason: 'AHBU Ev Otomasyonu için $_biometricLabel doğrulaması yapın',
      );
      _biometricChecking = false;
      if (authenticated) {
        _biometricFailed = false;
        _authStatus = AuthStatus.authenticated;
      } else {
        _biometricFailed = true;
        _authStatus = AuthStatus.checking;
      }
    } else {
      _authStatus = AuthStatus.authenticated;
    }
  }

  Future<void> setMode(AppMode newMode) async {
    _mode = newMode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_app_mode', newMode == AppMode.cloud ? 'cloud' : 'direct');
    
    if (_mode == AppMode.direct) {
      _startPolling();
      await refresh();
    } else {
      _pollTimer?.cancel();
      if (_activeHome != null) {
        await _connectMqttForHome(_activeHome!);
      }
    }
    notifyListeners();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      if (!_isDisposed && _mode == AppMode.direct) {
        refresh(silent: true);
      }
    });
  }

  Future<void> setHost(String newHost) async {
    _host = newHost.trim();
    directApi.updateHost(_host);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_esp_host', _host);
    _connState = ConnectionStateEnum.connecting;
    notifyListeners();
    await refresh();
  }

  Future<void> refresh({bool silent = false}) async {
    if (_mode == AppMode.direct) {
      try {
        final st = await directApi.fetchStatus();
        _status = st;
        _childLock = st.childLock;
        _connState = ConnectionStateEnum.connected;
        notifyListeners();
      } catch (e) {
        if (!silent || _status == null) {
          _connState = ConnectionStateEnum.offline;
          notifyListeners();
        }
      }
    } else {
      // Cloud Mode refresh
      if (_activeHome != null) {
        try {
          final endpoints = await cloudApi.fetchEndpoints(_activeHome!.id);
          _cloudEndpoints = endpoints;
          cloudApi.getChildLock(_activeHome!.id).then((cl) {
            _childLock = cl;
            notifyListeners();
          }).catchError((_) {});
          fetchPeaceNotification();
          if (!_isMqttConnected) {
            await _connectMqttForHome(_activeHome!);
          }
          _connState = ConnectionStateEnum.connected;
          notifyListeners();
        } catch (e) {
          if (!_isMqttConnected) {
            if (!silent) {
              _connState = ConnectionStateEnum.offline;
              notifyListeners();
            }
          }
        }
      }
    }
  }

  // --- Cloud Auth & Multi-Tenant İşlemleri ---

  Future<bool> _handleAuthSuccess(Map<String, dynamic> res) async {
    final token = (res['access_token'] ?? res['token']) as String;
    final refreshToken = res['refresh_token'] as String?;

    final user = UserModel.fromJson(res['user'] as Map<String, dynamic>, token: token);
    _currentUser = user;

    await secureStorage.saveAuthToken(token);
    if (refreshToken != null && refreshToken.isNotEmpty) {
      await secureStorage.saveRefreshToken(refreshToken);
      cloudApi.setRefreshToken(refreshToken);
    }
    await secureStorage.saveUser(user);
    await secureStorage.saveAppMode('cloud');

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_auth_token', token);

    // ADIM 19: İlk giriş sonrası biyometrik prompt kontrolü
    final promptShown = await secureStorage.isBiometricPromptShown();
    final isSupported = await biometricService.isBiometricSupported();
    if (isSupported && !promptShown && !_isBiometricEnabled) {
      _shouldPromptBiometrics = true;
    }

    _authStatus = AuthStatus.authenticated;
    await fetchHomes();
    setMode(AppMode.cloud);
    notifyListeners();
    return true;
  }

  /// ADIM 19: Biyometrik Girişi Aç / Kapat
  Future<void> toggleBiometric(bool enabled) async {
    _isBiometricEnabled = enabled;
    await secureStorage.saveBiometricEnabled(enabled);
    notifyListeners();
  }

  /// ADIM 19: Doğrulama Yaparak Biyometrik Girişi Etkinleştir
  Future<bool> enableBiometricWithVerification() async {
    final success = await biometricService.authenticate(
      reason: 'AHBU Ev Otomasyonu için $_biometricLabel doğrulaması yapın',
    );
    if (success) {
      _isBiometricEnabled = true;
      await secureStorage.saveBiometricEnabled(true);
      await secureStorage.saveBiometricPromptShown(true);
      _shouldPromptBiometrics = false;
      notifyListeners();
      return true;
    }
    return false;
  }

  /// ADIM 19: Biyometrik Giriş İsteğini Reddet (Daha Sonra)
  Future<void> dismissBiometricPrompt() async {
    _shouldPromptBiometrics = false;
    await secureStorage.saveBiometricPromptShown(true);
    notifyListeners();
  }

  /// ADIM 19: Biyometrik Doğrulamayı Yeniden Dene
  Future<bool> retryBiometricAuth() async {
    _biometricChecking = true;
    _biometricFailed = false;
    notifyListeners();

    final authenticated = await biometricService.authenticate(
      reason: 'AHBU Ev Otomasyonu için $_biometricLabel doğrulaması yapın',
    );
    _biometricChecking = false;
    if (authenticated) {
      _biometricFailed = false;
      _authStatus = AuthStatus.authenticated;
      if (_mode == AppMode.cloud && _activeHome != null) {
        await _connectMqttForHome(_activeHome!);
      }
      notifyListeners();
      return true;
    } else {
      _biometricFailed = true;
      notifyListeners();
      return false;
    }
  }

  /// ADIM 19: Şifre ile Giriş Ekranına Düş (Fallback)
  void fallbackToPasswordLogin() {
    _biometricChecking = false;
    _biometricFailed = false;
    _authStatus = AuthStatus.unauthenticated;
    notifyListeners();
  }

  @visibleForTesting
  void setAuthStatusForTesting(AuthStatus status) {
    _authStatus = status;
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

  Future<bool> login(String identifier, String password) async {
    try {
      final res = await cloudApi.login(identifier, password);
      return await _handleAuthSuccess(res);
    } catch (e) {
      debugPrint('Login hatası: $e');
      rethrow;
    }
  }

  Future<bool> register({
    required String fullName,
    required String email,
    required String password,
    String? phone,
  }) async {
    try {
      final res = await cloudApi.register(
        fullName: fullName,
        email: email,
        password: password,
        phone: phone,
      );
      return await _handleAuthSuccess(res);
    } catch (e) {
      debugPrint('Register hatası: $e');
      rethrow;
    }
  }

  /// ADIM 18: Google Sign-In ile Giriş
  Future<bool> loginWithGoogle({
    String? idToken,
    String? email,
    String? name,
    String? googleId,
  }) async {
    try {
      final res = await cloudApi.loginWithGoogle(
        idToken: idToken,
        email: email,
        name: name,
        googleId: googleId,
      );
      return await _handleAuthSuccess(res);
    } catch (e) {
      debugPrint('Google login hatası: $e');
      rethrow;
    }
  }

  /// ADIM 18: Sign in with Apple ile Giriş
  Future<bool> loginWithApple({
    String? identityToken,
    required String userId,
    String? email,
    String? name,
  }) async {
    try {
      final res = await cloudApi.loginWithApple(
        identityToken: identityToken,
        userId: userId,
        email: email,
        name: name,
      );
      return await _handleAuthSuccess(res);
    } catch (e) {
      debugPrint('Apple login hatası: $e');
      rethrow;
    }
  }

  /// ADIM 18: Telefon OTP Kodu Talep Et
  Future<Map<String, dynamic>> sendPhoneOtp(String phone) async {
    return await cloudApi.sendPhoneOtp(phone);
  }

  /// ADIM 18: Telefon OTP Kodu Doğrula ve Giriş Yap
  Future<bool> verifyPhoneOtp(String phone, String code) async {
    try {
      final res = await cloudApi.verifyPhoneOtp(phone, code);
      return await _handleAuthSuccess(res);
    } catch (e) {
      debugPrint('OTP login hatası: $e');
      rethrow;
    }
  }

  Future<bool> loginWithServicePin(String pin) async {
    try {
      final res = await cloudApi.serviceLogin(pin);
      final token = (res['access_token'] ?? res['token']) as String;
      final user = UserModel.fromJson(res['user'] as Map<String, dynamic>, token: token);
      _currentUser = user;

      await secureStorage.saveAuthToken(token);
      await secureStorage.saveUser(user);
      await secureStorage.saveAppMode('cloud');

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_auth_token', token);

      _authStatus = AuthStatus.authenticated;
      await fetchHomes();
      setMode(AppMode.cloud);
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Servis login hatası: $e');
      rethrow;
    }
  }

  /// ADIM 20: Şifre Sıfırlama Talebi (OTP & Magic Link)
  Future<Map<String, dynamic>> forgotPassword(String identifier) async {
    return await cloudApi.forgotPassword(identifier);
  }

  /// ADIM 20: OTP Kodu veya Token ile Şifre Yenileme ve Otomatik Giriş
  Future<bool> resetPassword({
    required String identifier,
    String? otpCode,
    String? code,
    String? token,
    required String newPassword,
  }) async {
    try {
      final res = await cloudApi.resetPassword(
        identifier: identifier,
        otpCode: otpCode,
        code: code,
        token: token,
        newPassword: newPassword,
      );

      // Şifre sıfırlama yanıtında kullanıcı ve token varsa otomatik oturum aç
      if (res['user'] != null && (res['access_token'] != null || res['token'] != null)) {
        return await _handleAuthSuccess(res);
      }
      return true;
    } catch (e) {
      debugPrint('Reset password hatası: $e');
      rethrow;
    }
  }

  /// ADIM 20: Sihirli Bağlantı (Magic Link) ile Tek Tıkla Oturum Açma
  Future<bool> loginWithMagicLink(String token) async {
    try {
      final res = await cloudApi.magicLogin(token);
      return await _handleAuthSuccess(res);
    } catch (e) {
      debugPrint('Magic login hatası: $e');
      rethrow;
    }
  }

  Future<void> logout() async {
    _currentUser = null;
    _homes = [];
    _activeHome = null;
    _cloudEndpoints = [];
    _authStatus = AuthStatus.unauthenticated;
    _mode = AppMode.cloud;
    _pollTimer?.cancel();
    await cloudApi.logout();
    mqttService.disconnect();
    _isMqttConnected = false;

    await secureStorage.clearAll();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('saved_auth_token');
    await prefs.remove('saved_app_mode');
    await setMode(AppMode.cloud);
    notifyListeners();
  }

  Future<Map<String, dynamic>> claimDevice(
    String deviceUuid,
    String setupPin, {
    String? homeName,
    int? homeId,
    String? targetOwner,
  }) async {
    try {
      final res = await cloudApi.claimDevice(
        deviceUuid: deviceUuid,
        setupPin: setupPin,
        homeName: homeName,
        homeId: homeId ?? _activeHome?.id,
        targetOwner: targetOwner,
      );

      final dynamic claimedHomeRaw = res['home'];
      final int? targetHomeId = res['home_id'] ??
          (claimedHomeRaw is Map ? claimedHomeRaw['id'] as int? : null) ??
          homeId ??
          _activeHome?.id;

      await fetchHomes();

      if (_homes.isNotEmpty) {
        final targetHome = (targetHomeId != null)
            ? _homes.firstWhere((h) => h.id == targetHomeId, orElse: () => _homes.first)
            : _homes.first;
        await selectHome(targetHome);
      }

      notifyListeners();
      return res;
    } catch (e) {
      debugPrint('Claim hatası: $e');
      rethrow;
    }
  }

  /// ADIM 11: Teknisyenin sistemi test edip "Çalışır" olarak devreye alması
  Future<Map<String, dynamic>> commissionSystem({String? notes}) async {
    if (_activeHome == null) throw Exception('Aktif ev seçilmedi');
    try {
      final res = await cloudApi.commissionSystem(_activeHome!.id, notes: notes);
      notifyListeners();
      return res;
    } catch (e) {
      debugPrint('Commissioning hatası: $e');
      rethrow;
    }
  }

  /// ADIM 11: Devreye alma durumunu sorgulama
  Future<Map<String, dynamic>?> getCommissioningStatus() async {
    if (_activeHome == null) return null;
    try {
      return await cloudApi.getCommissioningStatus(_activeHome!.id);
    } catch (e) {
      debugPrint('getCommissioningStatus hatası: $e');
      return null;
    }
  }

  /// ADIM 11: Kontrol noktası güncelleme (İsim, Oda, Panjur Kalibrasyon Süresi)
  Future<bool> updateEndpoint({
    required int endpointId,
    String? name,
    String? room,
    String? type,
    int? shutterDurationSec,
  }) async {
    if (_activeHome == null) return false;
    try {
      await cloudApi.updateEndpoint(
        homeId: _activeHome!.id,
        endpointId: endpointId,
        name: name,
        room: room,
        type: type,
        shutterDurationSec: shutterDurationSec,
      );
      await fetchEndpoints(_activeHome!.id);
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('updateEndpoint hatası: $e');
      return false;
    }
  }

  Future<void> fetchEndpoints([dynamic homeId]) async {
    final targetHomeId = homeId ?? _activeHome?.effectiveId ?? _activeHome?.id;
    if (targetHomeId == null || targetHomeId == 0 || targetHomeId == '0') return;
    try {
      final eps = await cloudApi.fetchEndpoints(targetHomeId);
      _cloudEndpoints = eps;
      notifyListeners();
    } catch (e) {
      debugPrint('fetchEndpoints hatası: $e');
    }
  }

  Future<Map<String, dynamic>> createHomeInvitation(
    dynamic homeId, {
    String role = 'member',
    int? durationHours,
    String? validFrom,
    String? validUntil,
    String? guestName,
  }) async {
    try {
      final res = await cloudApi.createInvitation(
        homeId,
        role: role,
        durationHours: durationHours,
        validFrom: validFrom,
        validUntil: validUntil,
        guestName: guestName,
      );
      notifyListeners();
      return res;
    } catch (e) {
      debugPrint('createHomeInvitation hatası: $e');
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> fetchHomeMembers([dynamic homeId]) async {
    final targetHomeId = homeId ?? _activeHome?.effectiveId ?? _activeHome?.id;
    if (targetHomeId == null || targetHomeId == 0 || targetHomeId == '0') return [];
    try {
      return await cloudApi.getHomeMembers(targetHomeId);
    } catch (e) {
      debugPrint('fetchHomeMembers hatası: $e');
      return [];
    }
  }

  Future<bool> removeHomeMember(dynamic targetUserId, [dynamic homeId]) async {
    final targetHomeId = homeId ?? _activeHome?.effectiveId ?? _activeHome?.id;
    if (targetHomeId == null || targetHomeId == 0 || targetHomeId == '0') return false;
    try {
      final success = await cloudApi.removeHomeMember(targetHomeId, targetUserId);
      notifyListeners();
      return success;
    } catch (e) {
      debugPrint('removeHomeMember hatası: $e');
      rethrow;
    }
  }

  Future<Map<String, dynamic>> joinHome(String code) async {
    try {
      final res = await cloudApi.joinHome(code);
      await fetchHomes();
      if (_homes.isNotEmpty) {
        final joinedHomeData = res['home'];
        final int? joinedHomeId = joinedHomeData is Map ? joinedHomeData['id'] as int? : null;
        if (joinedHomeId != null) {
          final target = _homes.firstWhere((h) => h.id == joinedHomeId, orElse: () => _homes.first);
          await selectHome(target);
        } else {
          await selectHome(_homes.first);
        }
      }
      notifyListeners();
      return res;
    } catch (e) {
      debugPrint('joinHome hatası: $e');
      rethrow;
    }
  }

  /// ADIM 13: Ev Sahibi - Daire Devir Sürecini Başlatma
  Future<Map<String, dynamic>> initiateHomeTransfer({String? targetIdentifier, dynamic homeId}) async {
    final targetHomeId = homeId ?? _activeHome?.idStr ?? _activeHome?.id;
    if (targetHomeId == null) throw Exception('Aktif daire bulunamadı');
    try {
      final res = await cloudApi.initiateTransfer(targetHomeId, targetIdentifier: targetIdentifier);
      notifyListeners();
      return res;
    } catch (e) {
      debugPrint('initiateHomeTransfer hatası: $e');
      rethrow;
    }
  }

  /// ADIM 13: Yeni Kullanıcı - Devir Kodunu Kabul Etme ve Daireyi Devralma
  Future<Map<String, dynamic>> acceptHomeTransfer(String transferCode) async {
    try {
      final res = await cloudApi.acceptTransfer(transferCode);
      await fetchHomes();
      if (_homes.isNotEmpty) {
        final transferredHomeData = res['home'];
        final String? tHomeId = transferredHomeData is Map ? transferredHomeData['id']?.toString() : null;
        if (tHomeId != null) {
          final target = _homes.firstWhere((h) => h.idStr == tHomeId || h.id.toString() == tHomeId, orElse: () => _homes.first);
          await selectHome(target);
        } else {
          await selectHome(_homes.first);
        }
      }
      notifyListeners();
      return res;
    } catch (e) {
      debugPrint('acceptHomeTransfer hatası: $e');
      rethrow;
    }
  }

  /// ADIM 13: Dairenin Bekleyen Devir Durumunu Sorgulama
  Future<Map<String, dynamic>?> getHomeTransferStatus([dynamic homeId]) async {
    final targetHomeId = homeId ?? _activeHome?.idStr ?? _activeHome?.id;
    if (targetHomeId == null) return null;
    try {
      return await cloudApi.getTransferStatus(targetHomeId);
    } catch (e) {
      debugPrint('getHomeTransferStatus hatası: $e');
      return null;
    }
  }

  /// ADIM 13: Devir İşlemini İptal Etme
  Future<bool> cancelHomeTransfer([dynamic homeId]) async {
    final targetHomeId = homeId ?? _activeHome?.idStr ?? _activeHome?.id;
    if (targetHomeId == null) return false;
    try {
      final success = await cloudApi.cancelTransfer(targetHomeId);
      notifyListeners();
      return success;
    } catch (e) {
      debugPrint('cancelHomeTransfer hatası: $e');
      rethrow;
    }
  }

  /// ADIM 13: Teknisyen / Acil Sıfırlama - Cihazı Sıfırlama / Yeni Malik Atama
  Future<Map<String, dynamic>> emergencyResetDevice({
    required String deviceUuid,
    required String reason,
    String? newOwnerIdentifier,
  }) async {
    try {
      final res = await cloudApi.emergencyResetDevice(
        deviceUuid: deviceUuid,
        reason: reason,
        newOwnerIdentifier: newOwnerIdentifier,
      );
      await fetchHomes();
      notifyListeners();
      return res;
    } catch (e) {
      debugPrint('emergencyResetDevice hatası: $e');
      rethrow;
    }
  }

  /// ADIM 14: Smart AP Fallback Modunda (192.168.4.1) panonun gördüğü Wi-Fi ağlarını tara
  Future<List<Map<String, dynamic>>> scanRecoveryWifiNetworks() async {
    try {
      return await api.scanWifiNetworks();
    } catch (e) {
      debugPrint('scanRecoveryWifiNetworks hatası: $e');
      return [];
    }
  }

  /// ADIM 14: Smart AP Fallback Modunda panoya yeni Wi-Fi SSID ve şifresini aktar
  Future<bool> sendRecoveryWifiCredentials(String ssid, String pass) async {
    try {
      final success = await api.connectWifi(ssid, pass);
      notifyListeners();
      return success;
    } catch (e) {
      debugPrint('sendRecoveryWifiCredentials hatası: $e');
      rethrow;
    }
  }

  /// ADIM 16: Sistem Doktoru (Self-Diagnostic) Teşhis Raporu
  Future<Map<String, dynamic>> fetchSystemDiagnostic() async {
    final homeId = _activeHome?.effectiveId ??
        (_activeHome?.idStr.isNotEmpty == true ? _activeHome!.idStr : (_activeHome?.id != 0 ? _activeHome?.id : null));
    if (homeId == null) {
      throw Exception('Aktif daire seçili değil.');
    }
    return await cloudApi.fetchSystemDiagnostic(homeId);
  }

  /// ADIM 16: Felaket Kurtarma - Tek Tıkla Pano Değişimi
  Future<Map<String, dynamic>> replaceBoard({
    String? oldDeviceUuid,
    required String newDeviceUuid,
    required String setupPin,
    String? reason,
  }) async {
    final homeId = _activeHome?.effectiveId ??
        (_activeHome?.idStr.isNotEmpty == true ? _activeHome!.idStr : (_activeHome?.id != 0 ? _activeHome?.id : null));
    if (homeId == null) {
      throw Exception('Aktif daire seçili değil.');
    }
    final res = await cloudApi.replaceBoard(
      homeId: homeId,
      oldDeviceUuid: oldDeviceUuid,
      newDeviceUuid: newDeviceUuid,
      setupPin: setupPin,
      reason: reason,
    );
    await fetchEndpoints();
    notifyListeners();
    return res;
  }

  Future<void> fetchHomes() async {
    try {
      _homes = await cloudApi.fetchHomes();
      if (_homes.isNotEmpty && _activeHome == null) {
        await selectHome(_homes.first);
      }
      notifyListeners();
    } catch (e) {
      debugPrint('fetchHomes hatası: $e');
    }
  }

  Future<void> selectHome(HomeModel home) async {
    _activeHome = home;
    notifyListeners();

    try {
      _cloudEndpoints = await cloudApi.fetchEndpoints(home.id);
      notifyListeners();
    } catch (e) {
      debugPrint('fetchEndpoints hatası: $e');
    }

    await _connectMqttForHome(home);
  }

  Future<void> _connectMqttForHome(HomeModel home) async {
    mqttService.disconnect();
    final connected = await mqttService.connect(
      username: home.mqttUsername,
      password: 'PassHome101!Sec', // PostgreSQL mqtt_users tablosundaki doğrulanmış şifre
      homeId: home.mqttUsername,
    );
    _isMqttConnected = connected;
    if (connected && _mode == AppMode.cloud) {
      _connState = ConnectionStateEnum.connected;
    }
    notifyListeners();

    if (connected) {
      // Gelen MQTTS Cihaz Çevrimiçi/Çevrimdışı Durumunu dinle
      mqttService.statusStream.listen((statusData) {
        final st = statusData['status']?.toString().toLowerCase();
        if (st == 'online') {
          _connState = ConnectionStateEnum.connected;
        } else if (st == 'offline') {
          _connState = ConnectionStateEnum.offline;
        }
        notifyListeners();
      });

      // Gelen MQTTS State mesajlarını dinle
      mqttService.stateStream.listen((data) {
        _handleMqttStateUpdate(data);
      });
    }
  }

  void _handleMqttStateUpdate(Map<String, dynamic> data) {
    bool changed = false;

    // Tek bir röle güncellemesi
    if (data.containsKey('relay') && data.containsKey('state')) {
      final ch = data['relay'] as int;
      final st = data['state'] == true || data['state'] == 1;

      final idx = _cloudEndpoints.indexWhere((e) => e.channel == ch);
      if (idx != -1) {
        _cloudEndpoints[idx] = _cloudEndpoints[idx].copyWith(currentState: st);
        changed = true;
      }
    }

    // Panjur güncellemesi
    if (data.containsKey('shutter') && data.containsKey('percent')) {
      final pIdx = data['shutter'] as int;
      final pos = data['percent'] as int;
      final ch = pIdx * 2 + 1; // Panjur rölesi kanalı

      final idx = _cloudEndpoints.indexWhere((e) => e.channel == ch || (e.channel ~/ 2) == pIdx);
      if (idx != -1) {
        _cloudEndpoints[idx] = _cloudEndpoints[idx].copyWith(shutterPosition: pos);
        changed = true;
      }
    }

    // Tüm röleler toplu state dizisi (Düz bool dizisi veya ESP32 nesne dizisi)
    if (data.containsKey('relays') && data['relays'] is List) {
      final list = data['relays'] as List<dynamic>;
      for (int i = 0; i < list.length; i++) {
        final item = list[i];
        int ch = i + 1;
        bool st = false;

        if (item is Map) {
          ch = (item['id'] is int ? item['id'] : int.tryParse(item['id'].toString())) ?? (i + 1);
          st = item['state'] == true || item['state'] == 1;
        } else {
          st = item == true || item == 1;
        }

        final idx = _cloudEndpoints.indexWhere((e) => e.channel == ch);
        if (idx != -1) {
          _cloudEndpoints[idx] = _cloudEndpoints[idx].copyWith(currentState: st);
          changed = true;
        }
      }
    }

    // ESP32 toplu panjur listesi (shutters: [{"pair": 1, "pos": 0}])
    if (data.containsKey('shutters') && data['shutters'] is List) {
      final sList = data['shutters'] as List<dynamic>;
      for (final item in sList) {
        if (item is Map) {
          final pair = (item['pair'] is int ? item['pair'] : int.tryParse(item['pair'].toString())) ?? 1;
          final pos = (item['pos'] is int ? item['pos'] : int.tryParse(item['pos'].toString())) ?? 0;
          final ch = (pair - 1) * 2 + 1;

          final idx = _cloudEndpoints.indexWhere((e) => e.channel == ch || (e.channel ~/ 2) == (pair - 1));
          if (idx != -1) {
            _cloudEndpoints[idx] = _cloudEndpoints[idx].copyWith(shutterPosition: pos);
            changed = true;
          }
        }
      }
    }

    if (changed) {
      _connState = ConnectionStateEnum.connected;
      notifyListeners();
    }
  }

  // --- Cihaz Sahiplenme & Teknisyen Token ---

  Future<String> generateServiceToken({int durationHours = 2}) async {
    if (_activeHome == null) throw Exception('Önce bir daire seçilmelidir');
    final res = await cloudApi.createServiceToken(_activeHome!.id, durationHours: durationHours);
    _servicePin = res.pin;
    _servicePinExpiry = res.expiresAt;
    notifyListeners();
    return res.pin;
  }

  // --- Birleşik Röle ve Panjur Kontrolleri (Optimistic UI Destekli) ---

  Future<void> toggleRelay(int channel) async {
    if (_mode == AppMode.direct) {
      // Yerel Optimistic Update
      if (_status != null) {
        final rIdx = _status!.relays.indexWhere((r) => r.id == channel);
        if (rIdx != -1) {
          final oldState = _status!.relays[rIdx].state;
          _optimisticRelayStates[channel] = oldState;
        }
      }
      try {
        await directApi.toggleRelay(channel);
        await refresh(silent: true);
      } catch (e) {
        // Rollback
        await refresh(silent: true);
      }
    } else {
      // Cloud MQTTS / REST Optimistic Update
      final idx = _cloudEndpoints.indexWhere((e) => e.channel == channel);
      if (idx != -1) {
        final oldState = _cloudEndpoints[idx].currentState;
        _optimisticRelayStates[channel] = oldState;
        _cloudEndpoints[idx] = _cloudEndpoints[idx].copyWith(currentState: !oldState);
        notifyListeners();

        try {
          if (_isMqttConnected && _activeHome != null) {
            mqttService.sendRelayCommand(_activeHome!.mqttUsername, channel, !oldState);
          } else if (_activeHome != null) {
            await cloudApi.controlEndpoint(_activeHome!.id, _cloudEndpoints[idx].id, 'toggle');
          }
        } catch (e) {
          // Optimistic Rollback (2.5 sn sonra eski durum geri gelir)
          Timer(const Duration(milliseconds: 2500), () {
            if (_optimisticRelayStates.containsKey(channel)) {
              _cloudEndpoints[idx] = _cloudEndpoints[idx].copyWith(currentState: _optimisticRelayStates[channel]);
              _optimisticRelayStates.remove(channel);
              notifyListeners();
            }
          });
        }
      }
    }
  }

  Future<void> triggerImpulse(int channel) async {
    if (_mode == AppMode.direct) {
      await directApi.triggerImpulse(channel);
      await refresh(silent: true);
    } else {
      final idx = _cloudEndpoints.indexWhere((e) => e.channel == channel);
      if (idx != -1 && _activeHome != null) {
        if (_isMqttConnected) {
          mqttService.sendRelayCommand(_activeHome!.mqttUsername, channel, true);
        } else {
          await cloudApi.controlEndpoint(_activeHome!.id, _cloudEndpoints[idx].id, 'impulse');
        }
      }
    }
  }

  Future<void> setShutterPosition(int pairIndex, int percent) async {
    final ch = pairIndex * 2 + 1;
    final oldPos = _optimisticShutterPositions[pairIndex] ?? 0;
    _optimisticShutterPositions[pairIndex] = percent;

    if (_mode == AppMode.direct) {
      try {
        await directApi.cmdShutter(pairIndex, 'pos');
        await refresh(silent: true);
      } catch (e) {
        // Rollback on failure
        Timer(const Duration(milliseconds: 2500), () {
          _optimisticShutterPositions[pairIndex] = oldPos;
          notifyListeners();
        });
      }
    } else {
      final idx = _cloudEndpoints.indexWhere((e) => e.channel == ch || (e.channel ~/ 2) == pairIndex);
      if (idx != -1) {
        final prevEp = _cloudEndpoints[idx];
        _cloudEndpoints[idx] = prevEp.copyWith(shutterPosition: percent);
        notifyListeners();

        try {
          if (_isMqttConnected && _activeHome != null) {
            mqttService.sendShutterCommand(_activeHome!.mqttUsername, pairIndex, 'pos', percent: percent);
          } else if (_activeHome != null) {
            await cloudApi.controlEndpoint(_activeHome!.id, prevEp.id, 'pos', value: percent);
          }
        } catch (e) {
          // Optimistic Rollback after 2.5s if not confirmed
          Timer(const Duration(milliseconds: 2500), () {
            if (_optimisticShutterPositions[pairIndex] == percent) {
              _cloudEndpoints[idx] = prevEp;
              _optimisticShutterPositions[pairIndex] = prevEp.shutterPosition;
              notifyListeners();
            }
          });
        }
      }
    }
  }

  int getShutterPosition(int pairIndex) {
    if (_optimisticShutterPositions.containsKey(pairIndex)) {
      return _optimisticShutterPositions[pairIndex]!;
    }
    if (_mode == AppMode.cloud) {
      final ch = pairIndex * 2 + 1;
      final ep = _cloudEndpoints.firstWhere(
        (e) => e.channel == ch || (e.channel ~/ 2) == pairIndex,
        orElse: () => EndpointModel(id: 0, homeId: 0, channel: ch, name: '', room: '', endpointType: 'shutter', currentState: false),
      );
      return ep.shutterPosition;
    }
    return 0;
  }

  Future<void> cmdShutter(int pairIndex, String action, {int? percent}) async {
    if (action == 'pos' && percent != null) {
      await setShutterPosition(pairIndex, percent);
      return;
    }

    if (_mode == AppMode.direct) {
      await directApi.cmdShutter(pairIndex, action);
      await refresh(silent: true);
    } else {
      if (_activeHome != null) {
        if (_isMqttConnected) {
          mqttService.sendShutterCommand(_activeHome!.mqttUsername, pairIndex, action, percent: percent);
        } else {
          final ch = pairIndex * 2 + 1;
          final ep = _cloudEndpoints.firstWhere((e) => e.channel == ch || (e.channel ~/ 2) == pairIndex, orElse: () => _cloudEndpoints.first);
          await cloudApi.controlEndpoint(_activeHome!.id, ep.id, action, value: percent);
        }
      }
    }
  }

  Future<void> cmdAll(String command) async {
    if (_mode == AppMode.direct) {
      await directApi.cmdAll(command);
      await refresh(silent: true);
    } else {
      if (_activeHome != null) {
        if (_isMqttConnected) {
          mqttService.sendScenarioCommand(_activeHome!.mqttUsername, command);
        }
      }
    }
  }

  /// ADIM 17: Çocuk Kilidi Değiştirme
  Future<bool> toggleChildLock(bool enabled) async {
    _childLock = enabled;
    notifyListeners();

    try {
      if (_mode == AppMode.direct) {
        await directApi.setChildLock(enabled);
      } else if (_activeHome != null) {
        await cloudApi.setChildLock(homeId: _activeHome!.id, enabled: enabled);
      }
      return true;
    } catch (e) {
      debugPrint('Çocuk kilidi değiştirme hatası: $e');
      return false;
    }
  }

  /// ADIM 17: Gece Huzur Bildirimi Verisini Çekme
  Future<Map<String, dynamic>?> fetchPeaceNotification() async {
    if (_mode == AppMode.cloud && _activeHome != null) {
      try {
        final data = await cloudApi.getPeaceNotification(_activeHome!.id);
        _peaceNotificationData = data;
        notifyListeners();
        return data;
      } catch (e) {
        debugPrint('Huzur bildirimi çekme hatası: $e');
      }
    }
    return null;
  }

  /// ADIM 17: Tek Tıkla Açık Lambaları Kapatma ("Hepsini Kapat")
  Future<int> closeAllOpenLights() async {
    final countBefore = openLightsCount;
    try {
      if (_mode == AppMode.direct) {
        await directApi.cmdAll('lightsoff');
        await refresh(silent: true);
      } else if (_activeHome != null) {
        await cloudApi.closeAllOpenLights(_activeHome!.id);
        await refresh(silent: true);
        await fetchPeaceNotification();
      }
      return countBefore;
    } catch (e) {
      debugPrint('Açık lambaları kapatma hatası: $e');
      rethrow;
    }
  }

  /// ADIM 17: Gece Huzur Bildirimi Ayarlarını Güncelleme
  Future<void> updatePeaceNotificationSettings({bool? enabled, String? time, String? notificationTime}) async {
    final targetTime = time ?? notificationTime;
    if (_mode == AppMode.cloud && _activeHome != null) {
      await cloudApi.updatePeaceNotification(
        _activeHome!.id,
        enabled: enabled,
        notificationTime: targetTime,
      );
      await fetchPeaceNotification();
    }
  }


  // ── ADIM 18: Zamanlı Otomasyon Kuralları ─────────────────────────────────

  /// Evin zamanlı kurallarını API'den çek
  Future<void> fetchScheduledRules() async {
    if (_activeHome == null || _mode != AppMode.cloud) return;
    _scheduledRulesLoading = true;
    if (!_isDisposed) notifyListeners();
    try {
      final data = await cloudApi.getScheduledRules(_activeHome!.id);
      _scheduledRules = (data['rules'] as List<dynamic>? ?? [])
          .map((r) => ScheduledRule.fromJson(r as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[ScheduledRules] fetch hatası: $e');
    } finally {
      _scheduledRulesLoading = false;
      if (!_isDisposed) notifyListeners();
    }
  }

  /// Yeni kural oluştur
  Future<void> createScheduledRule({
    required int channel,
    required String channelType,
    required String action,
    required int hour,
    required int minute,
    required List<int> daysOfWeek,
    String? label,
    int? deviceId,
  }) async {
    if (_activeHome == null) return;
    await cloudApi.createScheduledRule(_activeHome!.id, {
      'channel': channel,
      'channel_type': channelType,
      'action': action,
      'hour': hour,
      'minute': minute,
      'days_of_week': daysOfWeek,
      'label': label,
      'device_id': deviceId,
    });
    await fetchScheduledRules();
  }

  /// Kural güncelle (etkin/devre dışı veya tam güncelleme)
  Future<void> updateScheduledRule(int ruleId, Map<String, dynamic> updates) async {
    if (_activeHome == null) return;
    await cloudApi.updateScheduledRule(_activeHome!.id, ruleId, updates);
    await fetchScheduledRules();
  }

  /// Kural sil
  Future<void> deleteScheduledRule(int ruleId) async {
    if (_activeHome == null) return;
    await cloudApi.deleteScheduledRule(_activeHome!.id, ruleId);
    _scheduledRules = _scheduledRules.where((r) => r.id != ruleId).toList();
    if (!_isDisposed) notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _pollTimer?.cancel();
    mqttService.dispose();
    super.dispose();
  }
}
