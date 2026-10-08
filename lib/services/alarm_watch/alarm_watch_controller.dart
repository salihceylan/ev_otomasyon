import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;

import '../automation_state.dart';
import '../push/safety_notice.dart';
import 'alarm_notice.dart';
import 'alarm_watch_models.dart';
import 'alarm_watch_service.dart';

/// "Arka planda alarm bildirimi" ayarının ön plan denetleyicisi (Android; Firebase'siz).
///
/// * Kapalı başlar. En az bir evde **ev rolü sahip / sakin** olan kullanıcı açabilir ([eligible]; guvenlik-12: kendi
///   evinin sahibi olan servis sorumlusu / süper kullanıcı dahil); misafir, müşteri evindeki servis üyeliği ve servis
///   oturumu ✖.
/// * Servis kendini durdurmuş olabilir (ör. şifre değişince oturumu bitti; uyelik-4): ön plana dönüşte ve durum
///   değişimlerinde (en çok 60 sn'de bir) gerçek durumu sorar; ayar açıkken çalışmıyorsa yeniden başlatır.
/// * Açınca: bildirim izni (Android 13+) istenir, ayar (kullanıcı + uygun evler) paylaşılan depoya yazılır ve ön plan
///   servisi başlatılır. Kapatınca servis durur.
/// * Çıkış yapılınca (ya da oturum kesin olarak bitince) ayar kapanır ve servis durur; başka kullanıcı girerse aynısı.
///   Ev listesi değişince servis için kayıtlı liste güncellenir; ayar açıkken servis çalışmıyorsa (ör. oturum bitip
///   yeniden girildi) yeniden başlatılır.
/// * Alarm bildirimine dokunuş [openedNotices] ile mevcut alarm yönlendirmesine ([SafetyPushNotice], "opened") verilir.
class AlarmWatchController extends ChangeNotifier {
  AlarmWatchController({
    required this.state,
    AlarmWatchPlatform? platform,
    AlarmWatchStore? store,
  })  : platform = platform ?? createAlarmWatchPlatform(),
        _repo = AlarmWatchSettingsRepository(store ?? (_defaultStore())) {
    state.addListener(_onStateChanged);
    try {
      _lifecycle = AppLifecycleListener(onResume: handleResume);
    } catch (_) {
      // Widget bağlayıcısı yok (saf Dart testi): yaşam döngüsü dinlenmez.
    }
  }

  AppLifecycleListener? _lifecycle;

  /// Durum değişimlerinde servisin gerçekten çalışıp çalışmadığının en sık sorulma aralığı (uyelik-4).
  static const Duration _runningCheckEvery = Duration(seconds: 60);
  DateTime? _lastRunningCheck;

  static AlarmWatchStore _defaultStore() =>
      alarmWatchPlatformSupported ? PrefsAlarmWatchStore() : MemoryAlarmWatchStore();

  final AutomationState state;
  final AlarmWatchPlatform platform;
  final AlarmWatchSettingsRepository _repo;

  final StreamController<SafetyPushNotice> _opened = StreamController<SafetyPushNotice>.broadcast();
  StreamSubscription<String>? _tapSub;

  AlarmWatchSettings _settings = AlarmWatchSettings.off;
  bool _loaded = false;
  bool _busy = false;
  bool _disposed = false;
  bool _notificationsAllowed = false;
  bool _batteryExempt = false;
  bool _running = false;
  String? _message;
  Future<void>? _initFuture;
  List<WatchedHome> _lastHomes = const <WatchedHome>[];

  /// Özellik bu cihazda var mı (yalnız Android).
  bool get supported => platform.isSupported;

  /// Oturumdaki kullanıcı bu özelliği kullanabilir mi (owner/resident olduğu bir ev var; servis rolü değil).
  bool get eligible => state.isAuthenticated && eligibleHomes.isNotEmpty;

  /// İzlenecek evler (owner/resident).
  List<WatchedHome> get eligibleHomes =>
      eligibleWatchHomes(globalRole: state.currentUser?.role, homes: state.homes);

  bool get loaded => _loaded;
  bool get enabled => _settings.enabled;
  bool get busy => _busy;
  bool get notificationsAllowed => _notificationsAllowed;
  bool get batteryExempt => _batteryExempt;
  bool get running => _running;

  /// Son işlemin kullanıcıya gösterilecek açıklaması (hata/uyarı); yoksa `null`.
  String? get message => _message;

  /// Alarm bildirimine dokunuşlar (uygulamanın alarm yönlendirmesine bağlanır).
  Stream<SafetyPushNotice> get openedNotices => _opened.stream;

  /// Ayar kaydını ve izinleri okur; bildirimi uygulamayı başlattıysa dokunuşu iletir. Tekrar çağrı aynı işi bekler.
  Future<void> init() => _initFuture ??= _init();

  Future<void> _init() async {
    if (!platform.isSupported) {
      _loaded = true;
      _notify();
      return;
    }
    _tapSub = platform.taps.listen(_onTap);
    _settings = await _repo.load();
    await _refreshPlatformState();
    _loaded = true;
    _notify();
    final launch = await platform.takeLaunchPayload();
    if (launch != null) _onTap(launch);
    _onStateChanged();
  }

  Future<void> _refreshPlatformState() async {
    _notificationsAllowed = await platform.notificationsAllowed();
    _batteryExempt = await platform.batteryOptimizationIgnored();
    _running = await platform.isRunning();
  }

  /// İzinleri yeniden okur (kullanıcı sistem ayarlarından dönünce).
  Future<void> refreshPermissions() async {
    if (!platform.isSupported) return;
    await _refreshPlatformState();
    _notify();
  }

  /// Özelliği açar. Bildirim izni verilmezse açılmaz (`false`).
  Future<bool> enable() async {
    if (!platform.isSupported || _busy) return false;
    final user = state.currentUser;
    final homes = eligibleHomes;
    if (!state.isAuthenticated || user == null || homes.isEmpty) {
      _message = 'Bu özellik yalnız ev sahibi ve ev sakinleri içindir.';
      _notify();
      return false;
    }
    _busy = true;
    _message = null;
    _notify();
    try {
      var allowed = await platform.notificationsAllowed();
      if (!allowed) allowed = await platform.requestNotifications();
      _notificationsAllowed = allowed;
      if (!allowed) {
        _message = 'Bildirim izni verilmedi. Telefon ayarlarından bu uygulamanın bildirimlerini açın.';
        return false;
      }
      _settings = AlarmWatchSettings(enabled: true, userId: user.id, homes: homes);
      _lastHomes = homes;
      await _repo.save(_settings);
      final started = await platform.start();
      _running = started || await platform.isRunning();
      if (!_running) {
        _message = 'Arka plan servisi başlatılamadı. Telefonu yeniden başlatıp tekrar deneyin.';
      }
      _batteryExempt = await platform.batteryOptimizationIgnored();
      return true;
    } catch (_) {
      _message = 'Ayar kaydedilemedi. Lütfen tekrar deneyin.';
      return false;
    } finally {
      _busy = false;
      _notify();
    }
  }

  /// Özelliği kapatır (servis durur).
  Future<void> disable() async {
    if (!platform.isSupported) return;
    _busy = true;
    _message = null;
    _notify();
    try {
      _settings = _settings.copyWith(enabled: false);
      await _repo.save(_settings);
      await platform.stop();
      _running = false;
    } catch (_) {
      // Kayıt yazılamadı: servis yine de durdurulmaya çalışıldı.
    } finally {
      _busy = false;
      _notify();
    }
  }

  /// Pil optimizasyonu muafiyeti ister (bazı markalar arka plan uygulamalarını kapatır).
  Future<void> requestBatteryExemption() async {
    if (!platform.isSupported) return;
    await platform.requestBatteryExemption();
    _batteryExempt = await platform.batteryOptimizationIgnored();
    _notify();
  }

  void _onTap(String payload) {
    final notice = alarmPayloadToNotice(payload);
    if (notice != null && !_opened.isClosed) _opened.add(notice);
  }

  AuthStatus? _lastStatus;

  void _onStateChanged() {
    if (_disposed || !_loaded || !platform.isSupported || _busy) return;
    final status = state.authStatus;
    final authChanged = status != _lastStatus;
    _lastStatus = status;
    if (status == AuthStatus.checking) return;
    if (!_settings.enabled) return;
    final user = state.currentUser;
    if (status == AuthStatus.unauthenticated || user == null || (_settings.userId != null && _settings.userId != user.id)) {
      // Çıkış / başka kullanıcı: arka planda başkasının (ya da çıkış yapılmış) evleri izlenmez.
      unawaited(disable());
      return;
    }
    if (!state.homesLoaded) return;
    final homes = eligibleHomes;
    if (homes.isEmpty) {
      unawaited(disable());
      return;
    }
    if (!listEquals(homes, _lastHomes)) {
      _lastHomes = homes;
      _settings = _settings.copyWith(homes: homes);
      unawaited(_repo.save(_settings).catchError((Object _) {}));
    }
    // Yeniden giriş sonrası (servis oturum bitince kendini durdurmuş olabilir) gerçek durum yeniden sorulur.
    if (authChanged) _running = false;
    if (!_running) {
      unawaited(_ensureRunning());
    } else {
      unawaited(_checkRunning()); // en çok 60 sn'de bir (uyelik-4)
    }
  }

  /// Uygulama ön plana döndü (uyelik-4): servis bu arada kendini durdurmuş olabilir; gerçek durum hemen sorulur.
  void handleResume() => unawaited(_checkRunning(force: true));

  /// Ayar açık, oturum açık ve uygun ev varken servis çalışmıyorsa yeniden başlatır. [force] değilse en çok
  /// [_runningCheckEvery]'de bir platforma sorulur.
  Future<void> _checkRunning({bool force = false}) async {
    if (_disposed || !_loaded || !platform.isSupported || _busy) return;
    if (!_settings.enabled || !state.isAuthenticated || eligibleHomes.isEmpty) return;
    final now = state.clock.now();
    final last = _lastRunningCheck;
    if (!force && last != null && now.difference(last) < _runningCheckEvery) return;
    _lastRunningCheck = now;
    try {
      final running = await platform.isRunning();
      if (_disposed) return;
      if (running != _running) {
        _running = running;
        _notify();
      }
      if (!running) await _ensureRunning();
    } catch (_) {
      // Platform sorgusu en iyi çabadır.
    }
  }

  bool _starting = false;

  Future<void> _ensureRunning() async {
    if (_starting) return;
    _starting = true;
    try {
      if (await platform.isRunning()) {
        _running = true;
        return;
      }
      _running = await platform.start();
      _notify();
    } catch (_) {
    } finally {
      _starting = false;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _lifecycle?.dispose();
    state.removeListener(_onStateChanged);
    _tapSub?.cancel();
    _opened.close();
    super.dispose();
  }
}
