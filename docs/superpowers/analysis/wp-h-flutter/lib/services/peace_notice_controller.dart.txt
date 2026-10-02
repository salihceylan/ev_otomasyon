import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/api_models.dart';
import '../models/capabilities.dart';
import 'automation_state.dart';
import 'ev_cloud_api_service.dart';
import 'push/peace_notice.dart';
import 'push/push_config.dart';
import 'push/push_coordinator.dart';
import 'push/push_gateway_factory.dart';
import 'push_token_api_adapter.dart';

/// "Bildirim izni penceresi daha önce soruldu mu" bayrağının küçük deposu.
///
/// Arayüzün yumuşak istemi (sistem penceresinden önceki açıklama) kullanıcıya YALNIZCA bir kez
/// gösterilsin diye kalıcıdır; testlerde bellek içi bir sahte verilir.
abstract class PromptStore {
  /// Daha önce soruldu mu. Okunamazsa `true` döner (okunamayan depoda her açılışta sormak rahatsız eder).
  Future<bool> wasPrompted();

  /// Sorulduğunu kalıcılaştırır (yazma hatası yutulur).
  Future<void> markPrompted();
}

/// [PromptStore]'un `shared_preferences` gerçeklemesi (cihaz bazlı; belirteç/sır içermez).
class SharedPrefsPromptStore implements PromptStore {
  SharedPrefsPromptStore({Future<SharedPreferences> Function()? prefs})
    : _prefs = prefs ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _prefs;

  static const String key = 'push_prompted';

  @override
  Future<bool> wasPrompted() async {
    try {
      return (await _prefs()).getBool(key) ?? false;
    } catch (_) {
      return true;
    }
  }

  @override
  Future<void> markPrompted() async {
    try {
      await (await _prefs()).setBool(key, true);
    } catch (_) {}
  }
}

/// Gece hatırlatması (açık kalan lambalar) istemci mantığı: push izni/kaydı, gelen bildirimi uygulama
/// içi afişe çevirme ve afişten "Hepsini kapat".
///
/// Sayfalara ve [AutomationState]'e DEĞİL uygulama kabuğuna bağlanır: yalnızca [AutomationState]'in
/// PUBLIC arayüzünü dinler/çağırır (addListener, sessionEvents, selectHome, refresh,
/// fetchPeaceNotification, cloudApi) ve çıkış kancasını ([AutomationState.addBeforeLogoutHook]) kullanır.
/// Arayüz bu denetleyiciyi dinleyip [pending] / [softPromptVisible] / [closeMessage] değerlerini çizer.
///
/// Tasarım ilkeleri:
/// * Hiçbir yöntem istisna fırlatmaz; push hataları/zaman aşımları [AutomationState] akışlarını bozmaz.
/// * Oturum bitince (çıkış, süre dolumu, servis oturumuna geçiş) yerel FCM belirteci geçersiz kılınır; rol
///   kaybı ve doğrudan mod gibi geçici uygunluk kayıplarında SİLİNMEZ.
/// * Push gönderim katmanı yapılandırılmadı (bu sürümde [createPushGateway] her zaman hareketsiz ağ geçidi
///   döndürür; Firebase/APNs kullanılmaz): koordinatör `unsupported` kalır, belirteç alınmaz ya da kaydedilmez
///   ve uygulama push'suz sürümle aynı davranır (yedek afiş yine çalışır).
/// * Sistem izin penceresi KENDİLİĞİNDEN açılmaz; yalnızca kullanıcı [requestPermission] derse açılır.
/// * Oturum/uygunluk değişince "nesil" artar: uçuştaki işlemler (ör. "Hepsini kapat") yeni oturuma
///   sonuç yansıtmaz.
/// * Ev adı, belirteç ve bildirim içeriği log'a yazılmaz.
class PeaceNoticeController extends ChangeNotifier with WidgetsBindingObserver {
  PeaceNoticeController({
    required this.state,
    PushCoordinator? push,
    PromptStore? promptStore,
    DateTime Function()? now,
  }) : _push = push ?? _defaultPush(state.cloudApi),
       _ownsPush = push == null,
       _promptStore = promptStore ?? SharedPrefsPromptStore(),
       _now = now ?? DateTime.now {
    _pushState = _push.state;
    _pushStateSub = _push.states.listen(_onPushState, onError: (Object _) {});
    _noticeSub = _push.notices.listen(_onNotice, onError: (Object _) {});
    _sessionSub = state.sessionEvents.listen(_onSessionEvent, onError: (Object _) {});
    state.addListener(_onStateChanged);
    _removeLogoutHook = state.addBeforeLogoutHook(_stopForLogout);
    try {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    } catch (_) {
      // Widget bağlayıcısı yok (saf Dart testi): yaşam döngüsü dinlenmez.
    }
    _evaluate();
    _syncFallback();
    _lockedSeen = isLocked;
  }

  final AutomationState state;
  final PushCoordinator _push;
  final bool _ownsPush;
  final PromptStore _promptStore;
  final DateTime Function() _now;

  StreamSubscription<PushState>? _pushStateSub;
  StreamSubscription<PeaceNotice>? _noticeSub;
  StreamSubscription<SessionEvent>? _sessionSub;
  void Function()? _removeLogoutHook;
  bool _observing = false;
  bool _disposed = false;

  /// Oturum nesli: uygunluk kaybı / oturum bitişinde artar; uçuştaki işlemler eskiyse çekilir.
  int _sessionEpoch = 0;

  /// Son değerlendirmedeki uygunluk (yalnızca DEĞİŞİMDE harekete geçilir).
  bool _eligible = false;

  /// Dinleyicilere en son bildirilen kilit durumu ([isLocked]); değişince dinleyiciler uyarılır.
  bool _lockedSeen = false;

  /// Bu oturumun bitişinde yerel FCM belirtecini geçersiz kılma ZATEN istendi. Aynı bitiş birkaç yoldan
  /// (çıkış kancası, oturum bitti olayı, uygunluk kaybı) bildirilebilir; tek istek yeter. Yeni oturumda
  /// (uygun olunca) sıfırlanır.
  bool _localTokenInvalidated = false;

  PeaceNotice? _pending;
  PushState _pushState = PushState.idle;
  bool _softPromptVisible = false;
  bool _closing = false;
  String? _closeMessage;

  /// Kullanıcı kapattığı bildirimler (oturum boyunca; `dedupeKey`).
  final Set<String> _dismissed = <String>{};
  Map<String, dynamic>? _lastPeaceData;
  bool? _promptedCache;

  // ---------------------------------------------------------------------------
  // Okuma durumu
  // ---------------------------------------------------------------------------

  /// Gösterilecek afiş (push ya da yedek); yoksa `null`.
  PeaceNotice? get pending => _pending;

  /// Push kaydının durumu (ayar kartı için).
  PushState get pushState => _pushState;

  /// İzin işletim sisteminde açıkça reddedilmiş: arayüz sistem ayarlarına yönlendirmelidir.
  bool get pushPermissionDenied => _push.permissionDenied;

  /// Sistem izin penceresinden önceki açıklayıcı istem gösterilmeli mi (en çok bir kez).
  bool get softPromptVisible => _softPromptVisible;

  /// "Hepsini kapat" isteği sürüyor.
  bool get closing => _closing;

  /// Son "Hepsini kapat" sonucu/hatası (Türkçe, kullanıcıya gösterilebilir). [pending] kalksa bile
  /// [clearCloseMessage] ya da yeni bir [closeAll] çağrısına kadar kalır.
  String? get closeMessage => _closeMessage;

  /// Sunucu push kaydını KALICI reddetti ve otomatik yeniden deneme durdu (ayar kartı "yeniden dene"
  /// düğmesi göstermeli; geçici hatada `false`: o zaman kendiliğinden yeniden denenir).
  bool get pushRegistrationBlocked => _eligible && _push.registrationBlocked;

  /// Bu oturum gece hatırlatması için uygun mu (bulut modu, servis oturumu değil, owner/resident evi var).
  bool get isEligible => _eligible;

  /// Oturum verisi gösterilmeyen bir kapı görünümü: oturum kilitli ([AuthStatus.checking]: biyometrik yeniden kilit /
  /// açılışta doğrulama) ya da zorunlu parola değişimi (oturum açık + [AutomationState.mustChangePassword]; AuthGate
  /// bu görünümde pano/oturum verisi göstermez). Afiş, istem ve sonuç iletisi bu ekranlarda GÖSTERİLMEMELİDİR (ev adı
  /// ve oda/lamba özeti görünür kalırdı; "Hepsini kapat" parola değişmeden çalışırdı); durum, kilit açılınca / parola
  /// değişince kaldığı yerden gösterilir. Bekleyen afiş KORUNUR (bunlar oturum bitişi değildir).
  bool get isLocked => _eligible && (state.authStatus == AuthStatus.checking || state.mustChangePassword);

  // ---------------------------------------------------------------------------
  // Varsayılan koordinatör
  // ---------------------------------------------------------------------------

  static const String _appVersion = String.fromEnvironment('APP_VERSION');

  static PushCoordinator _defaultPush(EvCloudApiService api) {
    final config = PushConfig.fromEnvironment();
    return PushCoordinator(
      // Push gönderim katmanı yapılandırılmadı: hiçbir platform kanalına dokunmayan (no-op) ağ geçidi; davranış
      // push'suz sürümle aynıdır. [config] bu sürümde yok sayılır.
      gateway: createPushGateway(config),
      api: CloudPushTokenApi(api),
      platform: defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
      appVersion: _appVersion.isEmpty ? null : _appVersion,
    );
  }

  // ---------------------------------------------------------------------------
  // Uygunluk ve yaşam döngüsü
  // ---------------------------------------------------------------------------

  /// Sunucu yalnızca `owner` ve `resident` rolündeki kullanıcılara gönderir; misafir/servis push almaz.
  bool _computeEligible() {
    if (!state.isAuthenticated || state.isServiceSession || state.mode != AppMode.cloud) return false;
    for (final home in state.homes) {
      final role = home.homeRole;
      if (role == HomeRole.owner || role == HomeRole.resident) return true;
    }
    return false;
  }

  void _onStateChanged() {
    if (_disposed) return;
    try {
      _evaluate();
      _syncFallback();
      final locked = isLocked;
      if (locked != _lockedSeen) {
        _lockedSeen = locked;
        _notify();
      }
    } catch (_) {
      // AutomationState bildirimini asla bozma.
    }
  }

  /// Uygunluk yalnızca değiştiğinde push başlatılır/durdurulur. Kimlik doğrulama durumu [AuthStatus.checking]
  /// iken (biyometrik yeniden kilit, soğuk açılışta doğrulama) durum BELİRSİZDİR: hiçbir şey değerlendirilmez,
  /// önceki durum korunur (kilit oturum bitişi değildir; kilit açılınca eski uygunlukla aynıysa yeniden
  /// başlatma/kayıt olmaz).
  void _evaluate() {
    if (state.authStatus == AuthStatus.checking) return;
    final eligible = _computeEligible();
    if (eligible == _eligible) return;
    _eligible = eligible;
    if (eligible) {
      _localTokenInvalidated = false;
      // İzin penceresi kendiliğinden açılmaz: yalnızca durum bakılır (needsPermission -> yumuşak istem).
      _fire(() => _push.start(promptForPermission: false));
    } else {
      _resetSession();
      // Oturum bittiyse (çıkış / süre dolumu / servis oturumu) yerel FCM belirteci de geçersiz kılınır;
      // oturum açık kalıp yalnızca uygunluk kaybolduysa (rol kaybı, doğrudan mod) belirteç SİLİNMEZ:
      // bu geçici olabilir ve sunucu alıcıları anlık rolden hesaplar.
      final invalidate = _takeSessionEndInvalidation();
      _fire(() => _push.stop(unregister: false, invalidateLocalToken: invalidate));
    }
  }

  /// Oturum gerçekten bitti mi: oturum açık değil ([AuthStatus.unauthenticated]) ya da servis (PIN) oturumuna
  /// geçildi. [AuthStatus.checking] (kilitli) oturum bitişi DEĞİLDİR.
  bool get _sessionEnded => state.authStatus == AuthStatus.unauthenticated || state.isServiceSession;

  /// Oturum bitmişse ve bu bitiş için yerel belirteç iptali henüz istenmediyse `true` döner ve istenmiş
  /// sayar (birden çok yoldan gelen aynı bitişte tek istek).
  bool _takeSessionEndInvalidation() {
    if (!_sessionEnded || _localTokenInvalidated) return false;
    _localTokenInvalidated = true;
    return true;
  }

  /// Oturum/uygunluk bitti: afiş, kapatılanlar, istem ve uçuştaki işlemler sıfırlanır.
  void _resetSession() {
    _sessionEpoch++;
    final changed = _pending != null || _softPromptVisible || _closing || _closeMessage != null;
    _pending = null;
    _softPromptVisible = false;
    _closing = false;
    _closeMessage = null;
    _dismissed.clear();
    _lastPeaceData = state.peaceNotificationData;
    if (changed) _notify();
  }

  void _onSessionEvent(SessionEvent event) {
    if (_disposed || event is! SessionExpiredEvent) return;
    // Oturum belirteci zaten geçersiz: sunucuya silme isteği 401 verir, o yüzden denenmez. Ama FCM belirteci
    // cihazda GEÇERLİ kalır ve sunucu satırı kullanıcıya bağlı kalır: sunucu bir satırı yalnızca FCM
    // `UNREGISTERED` görünce kapatır, başarılı gönderimde kapatmaz. Bu yüzden belirteç YERELDE geçersiz kılınır
    // (sonraki gönderim UNREGISTERED döner ve sunucu satırı kapatır); çevrimdışıysa silinemeyebilir (bilinen
    // sınır). Durum bildirimi (uygunluk kaybı) olaydan önce gelmiş olabilir: tek istek yeter. Soğuk
    // açılışta (bu çalışmada push hiç başlamadan) süresi dolmuş oturum da önceki oturumun belirtecini siler.
    _eligible = false;
    _resetSession();
    if (!_localTokenInvalidated) {
      _localTokenInvalidated = true;
      _fire(() => _push.stop(unregister: false, invalidateLocalToken: true));
    }
  }

  /// Çıkış başlarken (oturum belirteci henüz geçerliyken) push belirtecini sunucudan siler VE yerelde geçersiz
  /// kılar. [AutomationState.logout] kancayı yalnızca `logout()` içinde, eşzamanlı başlatır ve yerel
  /// temizliği en çok 1 sn bekletir; kanca arka planda sürer (en çok 3 sn: [PushCoordinator.unregisterTimeout]).
  /// `logoutAll` sunucuda başarısız olursa kanca ÇALIŞMAZ, oturum ve push sürer.
  Future<void> _stopForLogout() async {
    if (_disposed) return;
    _localTokenInvalidated = true; // çıkış sonrası uygunluk kaybı aynı belirteci ikinci kez silmesin
    await _push.stop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed || state != AppLifecycleState.resumed || !_eligible) return;
    _fire(_push.refresh);
  }

  // ---------------------------------------------------------------------------
  // Push durumu ve yumuşak istem
  // ---------------------------------------------------------------------------

  void _onPushState(PushState next) {
    if (_disposed) return;
    _pushState = next;
    if (next != PushState.needsPermission) {
      _softPromptVisible = false;
    } else {
      _maybeShowSoftPrompt();
    }
    _notify();
  }

  Future<bool> _wasPrompted() async {
    final cached = _promptedCache;
    if (cached != null) return cached;
    bool prompted;
    try {
      prompted = await _promptStore.wasPrompted();
    } catch (_) {
      prompted = true;
    }
    return _promptedCache = prompted;
  }

  Future<void> _persistPrompted() async {
    _promptedCache = true;
    try {
      await _promptStore.markPrompted();
    } catch (_) {}
  }

  void _maybeShowSoftPrompt() {
    if (_disposed || _softPromptVisible || !_eligible) return;
    if (_pushState != PushState.needsPermission || pushPermissionDenied) return;
    final epoch = _sessionEpoch;
    _fire(() async {
      final prompted = await _wasPrompted();
      if (_disposed || epoch != _sessionEpoch || prompted || !_eligible || _softPromptVisible) return;
      if (_pushState != PushState.needsPermission || pushPermissionDenied) return;
      _softPromptVisible = true;
      _notify();
    });
  }

  /// "Bildirimleri aç": bayrağı kalıcılaştırır, sistem izin penceresini açar, verilirse kaydeder.
  /// (Ayar kartındaki düğme de bunu kullanır.)
  Future<void> requestPermission() async {
    if (_disposed) return;
    try {
      _softPromptVisible = false;
      _notify();
      await _persistPrompted();
      await _push.requestPermissionAndRegister();
    } catch (_) {
      // Koordinatör fırlatmaz; yine de arayüzü düşürme.
    }
    // İzin reddedilirse durum `needsPermission` kalır (olay üretilmez): `pushPermissionDenied` yeniden okunsun.
    _notify();
  }

  /// Ayar kartındaki "Yeniden dene" (kalıcı red sonrası): kaydı elle yeniden dener; izin penceresi AÇMAZ.
  Future<void> retryPushRegistration() async {
    if (_disposed || !_eligible) return;
    try {
      await _push.retryRegistration();
    } catch (_) {
      // Koordinatör fırlatmaz; yine de arayüzü düşürme.
    }
    _notify();
  }

  /// "Şimdi değil": bir daha sorma (ayar kartındaki düğme kalır).
  Future<void> dismissSoftPrompt() async {
    if (_disposed) return;
    _softPromptVisible = false;
    _notify();
    await _persistPrompted();
  }

  // ---------------------------------------------------------------------------
  // Gelen bildirim ve yedek afiş
  // ---------------------------------------------------------------------------

  void _onNotice(PeaceNotice notice) {
    if (_disposed) return;
    try {
      if (!state.isAuthenticated || state.isServiceSession) return;
      // Ev listesi yüklüyken bildirimin evi bu kullanıcının evlerinden biri DEĞİLSE yok say: aynı cihazda
      // önceki hesabın belirteci hâlâ canlıysa o hesabın ev adı/özeti yeni kullanıcıya afiş olmasın.
      if (state.homes.isNotEmpty && state.homeById(notice.homeId) == null) return;
      if (_dismissed.contains(notice.dedupeKey)) return;

      // Bildirime dokunarak gelindiyse (arka plan/kapalı) ilgili eve geç; ön planda gelen başka evin
      // bildirimi yalnızca afiş olur (kullanıcının açık ev ekranını zorla değiştirme).
      if (notice.source != PeaceNoticeSource.foreground && state.activeHome?.id != notice.homeId) {
        final home = state.homeById(notice.homeId);
        if (home != null) _fire(() => state.selectHome(home));
      }

      _pending = notice;
      _notify();

      // Afişteki sayı bayat olabilir (kullanıcı bu arada kapatmış olabilir): gerçek durumu tazele.
      if (state.activeHome?.id == notice.homeId) {
        _fire(state.fetchPeaceNotification);
        _fire(() => state.refresh(silent: true));
      }
    } catch (_) {}
  }

  /// Push gelmediyse (izin yok, FCM yapılandırılmamış, telefon kapalıydı) ayar yanıtından afiş üretir.
  void _syncFallback() {
    final data = state.peaceNotificationData;
    if (identical(data, _lastPeaceData)) return;
    _lastPeaceData = data;
    if (!_eligible) return;

    final current = _pending;
    if (current != null && data != null && _finishedByFreshData(data, current)) {
      // TAZE ve etkin eve ait veri işin bittiğini söylüyor (lambalar kapanmış ya da kayıt çözülmüş):
      // afiş KAYNAĞINA BAKILMADAN kalkar (push afişi de bayat kalmasın).
      _pending = null;
      _notify();
      return;
    }

    final fallback = data == null
        ? null
        : PeaceNotice.fromSettings(data, homeName: state.activeHome?.name, now: _now());
    if (fallback == null) {
      // Lambalar kapandı / bildirim çözüldü / veri bayat: yalnızca YEDEK afişi kaldır (push kaynaklıya,
      // veri taze değilse, dokunma).
      if (current != null && current.source == PeaceNoticeSource.settings) {
        _pending = null;
        _notify();
      }
      return;
    }
    if (_dismissed.contains(fallback.dedupeKey)) return;
    if (current != null) return; // gösterilen afiş (push) önceliklidir; aynı bildirimse zaten var
    _pending = fallback;
    _notify();
  }

  /// [data] TAZE (`stale == false`), etkin eve ve afişin evine ait mi VE [notice]'in işinin bittiğini mi
  /// söylüyor: canlı açık lamba + panjur sayıları ikisi de 0 (YALNIZ tüm cihazlar çevrimiçiyken: sayılar
  /// yalnızca canlı cihazlardan gelir, çevrimdışı cihazın lambaları bilinmez) ya da `last_notice` aynı
  /// bildirim ve çözülmüş.
  bool _finishedByFreshData(Map<String, dynamic> data, PeaceNotice notice) {
    if (data['stale'] != false) return false;
    final homeId = data['home_id'];
    if (homeId is! String || homeId != notice.homeId || homeId != state.activeHome?.id) return false;

    final lights = _count(data['open_lights_count']);
    final shutters = _count(data['open_shutters_count']);
    final devicesTotal = _count(data['devices_total']);
    final devicesOnline = _count(data['devices_online']);
    final allOnline =
        devicesTotal != null && devicesOnline != null && devicesTotal > 0 && devicesOnline == devicesTotal;
    if (allOnline && lights != null && shutters != null && lights == 0 && shutters == 0) return true;

    final last = data['last_notice'];
    if (last is Map && notice.noticeId != null && _count(last['id']) == notice.noticeId) {
      if (last['status'] == 'resolved' || last['resolved_at'] != null) return true;
    }
    return false;
  }

  /// JSON sayacı: tam sayı ya da rakam metni; aksi halde `null` (bilinmiyor).
  static int? _count(Object? raw) {
    if (raw is int) return raw;
    if (raw is String && RegExp(r'^[0-9]{1,9}$').hasMatch(raw)) return int.tryParse(raw);
    return null;
  }

  // ---------------------------------------------------------------------------
  // Eylemler
  // ---------------------------------------------------------------------------

  /// Afişteki "Kapat": aynı afiş bu oturumda bir daha gösterilmez.
  void dismiss() {
    final current = _pending;
    if (_disposed || current == null) return;
    _dismissed.add(current.dedupeKey);
    _pending = null;
    _notify();
  }

  /// [closeMessage]'ı temizler (arayüz mesajı gösterdikten sonra).
  void clearCloseMessage() {
    if (_disposed || _closeMessage == null) return;
    _closeMessage = null;
    _notify();
  }

  /// Afişteki "Hepsini kapat": bildirim kimliğini sunucuya iletir (bildirim kaydı çözülür). Panjurlar YALNIZCA
  /// afiş açık panjur sayıyorsa (`openShutters > 0`) inecek şekilde `include_shutters` AÇIKÇA gönderilir.
  /// Sonuç [closeMessage]'a yazılır; hiçbir koşulda istisna fırlatmaz.
  Future<void> closeAll() async {
    final notice = _pending;
    if (_disposed || notice == null || _closing) return;

    final epoch = _sessionEpoch;
    _closeMessage = null;
    _closing = true;
    _notify();

    String? message;
    try {
      message = await _closeAllImpl(notice, epoch);
    } on ApiException catch (e) {
      message = e.message.isEmpty ? 'Lambalar kapatılamadı. Lütfen tekrar deneyin.' : e.message;
    } catch (_) {
      message = 'Lambalar kapatılamadı. Lütfen tekrar deneyin.';
    }
    // Oturum bu arada bitti/değişti: sonuç yeni oturuma yansımaz (sıfırlama zaten yapıldı).
    if (_disposed || epoch != _sessionEpoch) return;

    _closing = false;
    if (message != null) _closeMessage = message;
    _notify();
    _fire(() => state.refresh(silent: true));
    _fire(state.fetchPeaceNotification);
  }

  /// Başarılı/uyarılı sonuç için kullanıcıya gösterilecek metni döndürür; hata fırlatabilir.
  Future<String?> _closeAllImpl(PeaceNotice notice, int epoch) async {
    if (state.mode != AppMode.cloud) return 'Bu işlem yalnızca bulut modunda yapılabilir.';

    // Bildirim başka eve aitse önce o eve geç (afişin başlığı ev adını gösterir; kullanıcı onu kapatmak istiyor).
    if (state.activeHome?.id != notice.homeId) {
      final home = state.homeById(notice.homeId);
      if (home == null) return 'Bu bildirim bir daireye ait; daireyi seçip yeniden deneyin.';
      await state.selectHome(home);
      if (_disposed || epoch != _sessionEpoch) return null;
    }
    final home = state.activeHome;
    if (home == null || home.id != notice.homeId) {
      return 'Bu bildirim bir daireye ait; daireyi seçip yeniden deneyin.';
    }
    if (!state.capabilities.canUseGroupCommands) return 'Bu işlem için yetkiniz yok.';

    final json = await state.cloudApi.closeAllForNotice(
      home.id,
      noticeId: notice.noticeId,
      includeShutters: notice.openShutters > 0,
    );
    if (_disposed || epoch != _sessionEpoch) return null;
    final result = CloseAllResult.fromJson(json);
    final serverMessage = result.message.trim();

    if (result.skippedCount == 0) {
      // Komut gitti ya da yapacak bir şey yoktu ve güvenle kapatılamayan öğe kalmadı: afiş, `resolved`
      // ya da `nothing_to_do` ayrımına BAKILMADAN kalkar (örn. başka sakin kaydı zaten çözmüşse sunucu
      // `resolved:false` döner ama iş bitmiştir).
      if (_pending?.dedupeKey == notice.dedupeKey) dismiss();
    }
    if (result.nothingToDo) {
      // Komut gönderilmedi: "kapatıldı" DENMEZ; sunucu mesajı olduğu gibi gösterilir.
      return serverMessage.isNotEmpty
          ? serverMessage
          : 'Sunucu kayıtlarına göre açık lamba ya da panjur görünmüyor; cihaza komut gönderilmedi.';
    }
    if (result.skippedCount > 0) {
      // Bazı öğeler güvenle kapatılamadı: afiş açık kalır. Sunucu iletisi KULLANILMAZ: gerçek ileti ~166
      // karakterdir ve kritik talimat ("elle kontrol edin") SONDADIR; büyük yazıda SnackBar'ın satır sınırı
      // sonunu keser. Burada KISA ve talimatı BAŞA alan bir ileti üretilir.
      return _partialCloseMessage(result);
    }
    return serverMessage.isNotEmpty ? serverMessage : 'Kapatma komutu gönderildi.';
  }

  /// Kısmi sonuç ([CloseAllResult.skippedCount] > 0) için kısa Türkçe ileti (53-72 karakter).
  ///
  /// "Komut gönderildi" yalnızca komutun cihaza GERÇEKTEN iletildiği ve en az bir lamba/panjur
  /// hedeflendiği kanıtlıysa söylenir; sayı bilinmiyorsa (`null`) ya da cihaza iletilmediyse söylenmez.
  static String _partialCloseMessage(CloseAllResult result) {
    final skipped = result.skippedCount;
    final commandSent = result.delivered && ((result.closedCount ?? 0) > 0 || (result.closedShutters ?? 0) > 0);
    return commandSent
        ? 'Komut gönderildi; $skipped öğe uzaktan kapatılamadı, lütfen elle kontrol edin.'
        : '$skipped öğe uzaktan kapatılamadı; lütfen elle kontrol edin.';
  }

  // ---------------------------------------------------------------------------
  // Yardımcılar
  // ---------------------------------------------------------------------------

  /// Dispose sonrası bildirim göndermez (geç gelen olaylar sessizce yok sayılır).
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// Beklenmeyen hataların yakalanmamış istisna olarak sızmasını önler.
  void _fire(Future<void> Function() action) {
    unawaited(Future<void>.sync(action).then<void>((_) {}, onError: (Object _) {}));
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _sessionEpoch++;
    unawaited(_pushStateSub?.cancel());
    unawaited(_noticeSub?.cancel());
    unawaited(_sessionSub?.cancel());
    _pushStateSub = null;
    _noticeSub = null;
    _sessionSub = null;
    state.removeListener(_onStateChanged);
    _removeLogoutHook?.call();
    _removeLogoutHook = null;
    if (_observing) {
      try {
        WidgetsBinding.instance.removeObserver(this);
      } catch (_) {}
      _observing = false;
    }
    // Kendi oluşturduğumuz koordinatörü kapatırız (kaydı SİLMEZ; çıkışta kanca zaten sildi).
    if (_ownsPush) _fire(_push.dispose);
    super.dispose();
  }
}
