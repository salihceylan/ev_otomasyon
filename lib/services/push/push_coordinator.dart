import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'peace_notice.dart';
import 'push_gateway.dart';
import 'safety_notice.dart';

/// Push belirteci uçlarını çağıran katman (uygulamada `EvCloudApiService` üzerinden sağlanır).
///
/// Hata sözleşmesi: kalıcı red (ör. 400 `VALIDATION`, 401 oturum sonu, 403 servis oturumu) için
/// [PushRegistrationRejected] fırlatılır; başka her istisna (ağ, zaman aşımı, 5xx, 429) GEÇİCİ sayılır
/// ve koordinatör geri çekilerek yeniden dener.
abstract class PushTokenApi {
  /// `PUT /api/v1/me/push-tokens`.
  Future<void> registerPushToken({required String token, required String platform, String? appVersion});

  /// `DELETE /api/v1/me/push-tokens`.
  Future<void> unregisterPushToken(String token);
}

/// Sunucu belirteç kaydını KALICI olarak reddetti: aynı istek yinelense de sonuç değişmez.
///
/// Koordinatör bu durumda kendiliğinden yeniden denemeyi bırakır (sunucuyu boş yere yormamak ve
/// pil/ağ harcamamak için); yalnızca yeni oturum, yeni belirteç ya da kullanıcının açık eylemi
/// ([PushCoordinator.requestPermissionAndRegister]) yeniden dener.
class PushRegistrationRejected implements Exception {
  const PushRegistrationRejected([this.reason]);

  /// İsteğe bağlı kısa neden (örn. HTTP durum kodu); sır içermemelidir.
  final String? reason;

  @override
  String toString() => reason == null ? 'PushRegistrationRejected' : 'PushRegistrationRejected($reason)';
}

/// Push kaydının arayüze yansıyan durumu.
enum PushState {
  /// Bu cihaz/derleme push desteklemiyor ya da push gönderim katmanı yapılandırılmamış (bu sürümde hep böyle:
  /// sessizce kapalı).
  unsupported,

  /// Oturum yok / koordinatör durduruldu.
  idle,

  /// Bildirim izni yok; kullanıcı ayardan açana kadar kayıt yapılmaz.
  needsPermission,

  /// Belirteç sunucuya kaydediliyor.
  registering,

  /// Belirteç sunucuda kayıtlı.
  registered,

  /// Kayıt başarısız (geçici ise geri çekilmeyle yeniden denenir, kalıcı ise durur).
  failed,
}

/// Gece hatırlatması push'unun istemci tarafı durum makinesi.
///
/// Sorumluluklar: izin → belirteç → sunucuya kayıt (tekilleştirilmiş, geri çekilmeli), belirteç yenileme,
/// çıkışta kaydı silme ve gelen bildirimleri güvenle [PeaceNotice] olayına çevirip tekilleştirerek iletme.
///
/// Tasarım ilkeleri:
/// * Hiçbir genel durum yok; gateway, api, saat ve rastgelelik dışarıdan verilir (testler fakeAsync ile
///   gerçek zamanlayıcı kullanmadan çalışır).
/// * Herkese açık yöntemler asla istisna fırlatmaz; gateway/api hataları durum makinesinin içinde çözülür.
/// * Tüm işlemler tek bir sıraya dizilir (tek uçuşlu): ardışık `start/stop/refresh` çağrıları yarış üretmez.
/// * `stop`, sıradaki işlemleri BEKLEMEDEN eski oturumu geçersiz kılar ("nesil" sayacı): uçuştaki bir
///   işlem döndüğünde nesil değiştiyse durumu değiştirmeden çekilir.
/// * Dış çağrıların hiçbiri sonsuza dek beklenmez: gateway/api çağrıları [stepTimeout] ile sınırlıdır ve
///   `stop` hangi işlem uçuşta olursa olsun en çok [unregisterTimeout] sonra döner (çıkış ekranı donmasın).
/// * Token, başlık/gövde ve ev kimliği hiçbir yere yazdırılmaz.
class PushCoordinator {
  PushCoordinator({
    required this.gateway,
    required this.api,
    required this.platform,
    this.appVersion,
    DateTime Function()? now,
    this.reRegisterAfter = const Duration(hours: 24),
    this.retryBase = const Duration(seconds: 30),
    this.retryMax = const Duration(minutes: 15),
    this.unregisterTimeout = const Duration(seconds: 3),
    this.stepTimeout = const Duration(seconds: 30),
    Random? random,
  }) : assert(platform == 'android' || platform == 'ios', 'platform android|ios olmalı'),
       _now = now ?? DateTime.now,
       // Güvenlikle ilgisiz: yalnızca yeniden deneme zamanlarını dağıtmak (thundering herd) için.
       _random = random ?? Random();

  final PushGateway gateway;
  final PushTokenApi api;

  /// Sunucuya giden platform değeri: `android` | `ios`.
  final String platform;

  /// Sunucuya giden uygulama sürümü (örn. `1.0.0+1`); bilinmiyorsa `null`.
  final String? appVersion;

  /// Aynı belirteç bu süre dolmadan sunucuya yeniden gönderilmez; dolunca `last_seen_at` tazelenir.
  final Duration reRegisterAfter;

  /// İlk yeniden deneme gecikmesi; her başarısızlıkta ikiye katlanır.
  final Duration retryBase;

  /// Yeniden deneme gecikmesinin üst sınırı (sapma sonrası da aşılmaz).
  final Duration retryMax;

  /// Çıkışta belirteç silme isteğinin en çok bekleneceği süre; aynı zamanda [stop]'un toplam üst süresidir.
  final Duration unregisterTimeout;

  /// Tek bir gateway/api adımının (başlatma, izin durumu, token alma, sunucuya kayıt) üst süresi.
  /// Dolarsa adım geçici hata sayılır; böylece takılan bir platform/ağ çağrısı tek uçuşlu sırayı
  /// süresiz kilitleyip sonraki oturumların kaydını engellemez. Kullanıcının yanıtını beklediği
  /// sistem izin penceresi (`requestPermission`) bu sınıra TABİ DEĞİLDİR.
  final Duration stepTimeout;

  final DateTime Function() _now;
  final Random _random;

  /// Aynı bildirimin tekrar iletilmeyeceği pencere (aynı bildirim hem `onMessage` hem `opened` hem de
  /// `initial` yolundan gelebilir; sunucu da yeniden göndermiş olabilir).
  static const Duration noticeDedupeWindow = Duration(minutes: 10);

  // Düşmanca/hatalı bir akışın belleği şişirmesini önleyen üst sınırlar.

  /// Tekilleştirme için hatırlanan en çok bildirim sayısı (aşılırsa en eskisi unutulur).
  static const int maxSeenNotices = 64;

  /// Dinleyici yokken tamponlanan en çok bildirim sayısı (aşılırsa en eskisi atılır).
  static const int maxBufferedNotices = 8;

  /// Güvenlik bildiriminin tamponda geçerli kaldığı süre (F2.C.4): uygulamayı açan alarm dokunuşu, arayüz dinlemeye
  /// başlamadan önce gelse de kaybolmaz; yarım saatten eski alarm yönlendirmesi yapılmaz.
  static const Duration safetyBufferMaxAge = Duration(minutes: 30);

  // Üstel büyüme taşmasın: 2^16 * 30 sn zaten her makul retryMax'ı aşar.
  static const int _maxBackoffExponent = 16;

  final StreamController<PushState> _states = StreamController<PushState>.broadcast();
  late final StreamController<PeaceNotice> _notices = StreamController<PeaceNotice>.broadcast(
    onListen: _flushBufferedNotices,
  );
  late final StreamController<SafetyPushNotice> _safetyNotices = StreamController<SafetyPushNotice>.broadcast(
    onListen: _flushBufferedSafetyNotices,
  );

  PushState _state = PushState.idle;
  PushPermission _permission = PushPermission.notDetermined;

  bool _running = false;
  bool _disposed = false;

  /// Oturum nesli: `start` (yeni oturum) ve `stop` her çağrıldığında artar; uçuştaki işlemler
  /// kendi nesillerini karşılaştırıp eskiyse çekilir.
  int _epoch = 0;

  bool _initialMessageRead = false;
  bool _blocked = false;
  int _retryAttempt = 0;
  Timer? _retryTimer;
  final List<StreamSubscription<Object?>> _subscriptions = <StreamSubscription<Object?>>[];

  // Sunucunun hâlâ bildiğini düşündüğümüz son belirteç. YALNIZCA silme isteği başlatılınca (ya da
  // yeni bir belirteç kaydedilince) değişir: `stop(unregister: false)` onu korur ki sonraki bir
  // `stop(unregister: true)` (çıkış) silebilsin.
  String? _registeredToken;

  // Belirtecin ne zaman TAZELENDİĞİ; `null` ise bir sonraki `start` sunucuya yeniden kaydeder
  // (oturum kapandığında ya da sonuç belirsiz kaldığında sıfırlanır).
  DateTime? _registeredAt;

  // Bu cihazda geçerli bir FCM belirteci olabilir mi. Başlangıçta `true` (önceki çalışmadan kalma belirteç
  // bilinemez); belirteç alınınca/yenilenince `true`, yerel silme başlayınca `false`, silme başarısız
  // olursa tekrar `true` (bir sonraki çıkışta yeniden denenir).
  bool _localTokenMayBeLive = true;

  // Uçuştaki yerel belirteç iptali (tek uçuş); yeni oturum `getToken` çağırmadan önce bunu bekler ki
  // yeni oturumun belirtecini yanlışlıkla silmesin.
  Future<void>? _localInvalidation;

  // Uçuştaki (kuyruk dışı) silme isteği: yeni oturumun kaydı, aynı belirteç için silme bitmeden
  // gitmesin diye `_sync` başında beklenir (yoksa PUT'un DELETE'ten önce işlenme riski doğar).
  Future<void>? _pendingUnregister;

  // noticeKey -> ilk iletilme zamanı (ekleme sırasına göre; en eskisi başta).
  final LinkedHashMap<String, DateTime> _seenNotices = LinkedHashMap<String, DateTime>();
  final List<PeaceNotice> _bufferedNotices = <PeaceNotice>[];
  final List<SafetyPushNotice> _bufferedSafetyNotices = <SafetyPushNotice>[];

  Future<void> _tail = Future<void>.value();

  /// Geçerli durum.
  PushState get state => _state;

  /// Durum değişimleri (yalnızca gerçek değişimde, broadcast).
  Stream<PushState> get states => _states.stream;

  /// Gece hatırlatması olayları (broadcast): ön plan + dokunma + kapalıyken açılış, `noticeId`'ye
  /// göre 10 dk içinde tekilleştirilmiş. Hiç dinleyici yokken gelenler (en çok 8 adet, 10 dk) ilk
  /// dinleyiciye iletilir; böylece uygulamayı açan bildirime dokunuş, arayüz dinlemeye başlamadan
  /// önce gelse de kaybolmaz. Akış [stop] ile KAPANMAZ, yalnızca [dispose] ile kapanır.
  Stream<PeaceNotice> get notices => _notices.stream;

  /// Güvenlik bildirimleri (`safety_alarm` / `safety_info`; F2.C.4), broadcast. Gece hatırlatması akışından ayrıdır;
  /// tekilleştirme penceresi ortaktır (anahtar önekleri çakışmaz). Dinleyici yokken gelenler (en çok 8, 30 dk) ilk
  /// dinleyiciye iletilir. [stop] ile KAPANMAZ, yalnız [dispose] ile kapanır.
  Stream<SafetyPushNotice> get safetyNotices => _safetyNotices.stream;

  /// Sunucu belirteç kaydını KALICI olarak reddetti ([PushRegistrationRejected]) ve otomatik yeniden
  /// deneme durdu: durum [PushState.failed] ve kendiliğinden düzelmez. Geçici başarısızlıkta (ağ, 5xx,
  /// 429, zaman aşımı) `false`'tur: koordinatör geri çekilerek kendisi yeniden dener. Arayüz bu durumda
  /// "otomatik yeniden denenecek" demek yerine elle yeniden deneme ([retryRegistration]) sunmalıdır.
  bool get registrationBlocked => _running && _blocked && _state == PushState.failed;

  /// Kullanıcının açık eylemiyle kaydı yeniden dener: kalıcı red bayrağını ve geri çekilme sayacını
  /// sıfırlar. Bildirim izni PENCERESİ AÇMAZ (izin yoksa yalnızca [PushState.needsPermission] olunur).
  /// Oturum yokken etkisizdir. Asla fırlatmaz.
  Future<void> retryRegistration() {
    if (_disposed || !_running) return Future<void>.value();
    _blocked = false;
    _retryAttempt = 0;
    final epoch = _epoch;
    return _enqueue(() => _sync(epoch, prompt: false));
  }

  /// Arayüzün "Bildirim izni kapalı" uyarısını göstermesi için: izin açıkça reddedilmiş.
  bool get permissionDenied => _permission == PushPermission.denied;

  // ---------------------------------------------------------------------------
  // Herkese açık yaşam döngüsü
  // ---------------------------------------------------------------------------

  /// Oturum açık ve rol uygun olduğunda çağrılır. Idempotent: oturum zaten açıksa yalnızca durumu
  /// yeniden değerlendirir (aynı belirteç için sunucuya yeni istek gitmez).
  ///
  /// [promptForPermission] doğruysa izin yokken sistem izin penceresi gösterilir; yanlışsa yalnızca
  /// [PushState.needsPermission] olunur (ilk açılışta kullanıcıyı habersiz bir pencereyle karşılamamak için).
  Future<void> start({bool promptForPermission = false}) {
    if (_disposed) return Future<void>.value();
    if (!_running) {
      // Yeni oturum: önceki oturumun reddi/geri çekilmesi ve "başlangıç mesajı okundu" bilgisi taşınmaz.
      _running = true;
      _epoch++;
      _initialMessageRead = false;
      _blocked = false;
      _retryAttempt = 0;
    }
    final epoch = _epoch;
    return _enqueue(() => _sync(epoch, prompt: promptForPermission));
  }

  /// Kullanıcı ayarlardan "Bildirimleri aç" dediğinde: izin istenir, verilirse kayıt yapılır.
  /// Önceki kalıcı red de burada sıfırlanır (açık kullanıcı eylemi yeniden denemeyi hak eder).
  Future<void> requestPermissionAndRegister() {
    if (_disposed || !_running) return Future<void>.value();
    _blocked = false;
    final epoch = _epoch;
    return _enqueue(() => _sync(epoch, prompt: true));
  }

  /// Uygulama öne geldiğinde: izin değişmiş mi, belirteç döndü mü, kayıt eskidi mi bakar.
  /// Beklemedeki geri çekilme zamanlayıcısı varsa beklemeden hemen dener.
  Future<void> refresh() {
    if (_disposed || !_running) return Future<void>.value();
    final epoch = _epoch;
    return _enqueue(() => _sync(epoch, prompt: false));
  }

  /// Çıkış / ev kaybı / [dispose] öncesi çağrılır.
  ///
  /// Abonelikleri ve zamanlayıcıları HEMEN iptal eder (uçuştaki işlemler bir sonraki adımda çekilir).
  /// [unregister] doğruysa bilinen belirteç kuyruğa GİRMEDEN hemen silinir; uçuşta bir kayıt isteği varsa
  /// ve sonradan başarıyla sonuçlanırsa o belirteç de arka planda silinir (aksi halde çıkış yapmış
  /// kullanıcıya bildirim gitmeye devam ederdi). Dönüş, uçuştaki işlemlere ve silme isteğine
  /// bakılmaksızın EN ÇOK [unregisterTimeout] sonra gelir; hata ve zaman aşımı yutulur.
  /// [unregister] yanlışsa sunucudaki kayıt hatırlanır (sonraki `stop(unregister: true)` silebilir).
  ///
  /// [invalidateLocalToken] (varsayılan: [unregister] değeri) doğruysa bu cihazın FCM belirteci YERELDE de
  /// geçersiz kılınır ([PushGateway.deleteToken]); sunucu `DELETE` denemesinden BAĞIMSIZDIR (onun
  /// başarısına/başarısızlığına/zaman aşımına bakılmaz) ve onunla eşzamanlı başlar. Gerekçe: sunucu satırı
  /// yalnızca FCM `UNREGISTERED` görünce kapatır; belirteç yerelde geçerli kalırsa çıkış yapmış telefona
  /// bildirim akmaya devam eder. Oturum bitince (silme isteği 401 verecekken) `stop(unregister: false,
  /// invalidateLocalToken: true)` kullanılır; rol kaybı gibi geçici durdurmada belirteç SİLİNMEZ.
  /// Toplam bekleme yine en çok [unregisterTimeout]'tur. Aynı belirteç için ikinci çağrı yeniden silmez
  /// (tek uçuş; yeni belirteç alınana ya da silme başarısız olana kadar). [notices] akışı kapanmaz.
  Future<void> stop({bool unregister = true, bool? invalidateLocalToken}) {
    if (_disposed) return Future<void>.value();
    final invalidate = invalidateLocalToken ?? unregister;
    _running = false;
    _epoch++;
    _blocked = false;
    _retryAttempt = 0;
    _permission = PushPermission.notDetermined;
    _teardown();
    if (_state != PushState.unsupported) _setState(PushState.idle);

    // Yeni oturum belirteci yeniden kaydetmeli: tazelik bilgisi atılır, ama sunucunun bildiği
    // belirteç (`_registeredToken`) silinmedikçe korunur.
    _registeredAt = null;

    final work = <Future<void>>[];
    if (unregister) {
      final known = _takeRegisteredToken();
      if (known != null) work.add(_unregisterNow(known));
    }
    if (invalidate) {
      // Yerel belirteç iptali sunucu isteğiyle EŞZAMANLI başlar ve onun sonucuna bakmaz.
      work.add(_invalidateLocalToken());
      if (!unregister) _takeRegisteredToken(); // sunucuya silme gitmeyecek: eski belirteç artık geçersiz
    }
    // Uçuştaki bir kayıt sonradan başarıyla dönerse onu temizler; kuyruk takılırsa beklenmez (aşağıdaki sınır).
    work.add(_enqueue(() => _unregisterLateLanding(unregister, invalidate)));
    return Future.wait(work).timeout(unregisterTimeout, onTimeout: () => <void>[]).then((_) {});
  }

  /// Koordinatörü kapatır: kaydı SİLMEZ (silmek için önce `stop(unregister: true)` çağrılır), akışları kapatır.
  Future<void> dispose() async {
    if (_disposed) return;
    await stop(unregister: false);
    _disposed = true;
    _bufferedNotices.clear();
    _bufferedSafetyNotices.clear();
    _seenNotices.clear();
    await _states.close();
    await _notices.close();
    await _safetyNotices.close();
  }

  // ---------------------------------------------------------------------------
  // İç: sıra ve durum
  // ---------------------------------------------------------------------------

  /// İşlemleri tek tek çalıştırır; bir işlemin hatası sırayı bozmaz ve dışarı sızmaz.
  Future<void> _enqueue(Future<void> Function() operation) {
    final done = Completer<void>();
    final previous = _tail;
    _tail = done.future;
    previous.then((_) async {
      try {
        await operation();
      } catch (_) {
        // Durum makinesi dışarıya istisna vermez; beklenmeyen hata görmezden gelinir (log yok: sır riski).
      }
      done.complete();
    });
    return done.future;
  }

  bool _isCurrent(int epoch) => !_disposed && epoch == _epoch;

  void _setState(PushState next) {
    if (_state == next || _disposed) return;
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  void _teardown() {
    _retryTimer?.cancel();
    _retryTimer = null;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }

  // ---------------------------------------------------------------------------
  // İç: izin -> belirteç -> kayıt
  // ---------------------------------------------------------------------------

  Future<void> _sync(int epoch, {required bool prompt}) async {
    if (!_isCurrent(epoch)) return;
    // Bekleyen otomatik yeniden deneme bu denemeyle birleşir (sonuç başarısızsa yenisi kurulur).
    _retryTimer?.cancel();
    _retryTimer = null;

    // Önceki oturumun belirteç silme isteği bitmeden aynı belirteç yeniden kaydedilmez (en çok unregisterTimeout).
    final pendingUnregister = _pendingUnregister;
    if (pendingUnregister != null) {
      await pendingUnregister;
      if (!_isCurrent(epoch)) return;
    }
    // Aynı şekilde yerel belirteç iptali (en çok unregisterTimeout) bitmeden yeni belirteç alınmaz.
    final pendingLocal = _localInvalidation;
    if (pendingLocal != null) {
      await pendingLocal;
      if (!_isCurrent(epoch)) return;
    }

    if (!gateway.isSupported) {
      _setState(PushState.unsupported);
      return;
    }

    final initialized = await _initializeGateway(epoch);
    if (!_isCurrent(epoch) || !initialized) return;
    if (!gateway.isSupported) {
      // Başlatma sonrası destek düştü (ör. geçersiz yapılandırma): sessizce kapalı.
      _setState(PushState.unsupported);
      return;
    }

    _listenToMessages(epoch);
    // Başlangıç mesajı beklenmez: iOS eklentisi onu "toplandı" bayrağına kadar tutabilir ve bu bekleme
    // kaydı geciktirmemeli. Mesaj gelince (oturum hâlâ geçerliyse) iletilir.
    unawaited(_readInitialMessage(epoch));

    // Kalıcı red sonrası otomatik denemeler durur (açık kullanıcı eylemi/yeni oturum/yeni belirteç hariç).
    if (_blocked) return;

    var permission = await _guard(gateway.permissionStatus, PushPermission.notDetermined, limit: stepTimeout);
    if (!_isCurrent(epoch)) return;

    if (permission != PushPermission.granted && permission != PushPermission.unsupported && prompt) {
      permission = await _guard(gateway.requestPermission, PushPermission.notDetermined);
      if (!_isCurrent(epoch)) return;
    }
    _permission = permission;

    switch (permission) {
      case PushPermission.unsupported:
        _setState(PushState.unsupported);
        return;
      case PushPermission.denied:
      case PushPermission.notDetermined:
        _setState(PushState.needsPermission);
        return;
      case PushPermission.granted:
        break;
    }

    final token = await _guard<String?>(gateway.getToken, null, limit: stepTimeout);
    if (token != null && token.isNotEmpty) _localTokenMayBeLive = true; // oturum eskise de belirteç var
    if (!_isCurrent(epoch)) return;
    if (token == null || token.isEmpty) {
      // iOS'ta APNs belirteci henüz gelmemiş ya da ağ yok: geçici sayılır.
      _fail(epoch, retry: true);
      return;
    }
    await _register(epoch, token);
  }

  Future<bool> _initializeGateway(int epoch) async {
    try {
      await gateway.initialize().timeout(stepTimeout);
      return true;
    } on TimeoutException {
      // Takılan başlatma "desteklenmiyor" demek değildir (ağ/platform yavaş olabilir): geçici sayılır;
      // gateway başlatmayı tek uçuşlu önbelleklediğinden sonraki deneme aynı işi bekler.
      if (_isCurrent(epoch)) _fail(epoch, retry: true);
      return false;
    } catch (_) {
      // Sözleşmeye göre başarısızlık `isSupported=false` ile bildirilir; fırlatan bir gateway'i de
      // aynı şekilde "desteklenmiyor" sayarız (yeniden denemek yapılandırmayı düzeltmez).
      if (_isCurrent(epoch)) _setState(PushState.unsupported);
      return false;
    }
  }

  /// Gateway çağrısı hata verirse (ya da [limit] içinde dönmezse) varsayılanı döndürür; koordinatör
  /// hiçbir zaman fırlatmaz ve takılan bir çağrıda sonsuza dek beklemez.
  Future<T> _guard<T>(Future<T> Function() call, T fallback, {Duration? limit}) async {
    try {
      final future = call();
      return await (limit == null ? future : future.timeout(limit));
    } catch (_) {
      return fallback;
    }
  }

  /// [token]'ı gerekiyorsa sunucuya kaydeder. Aynı belirteç + [reRegisterAfter] dolmadan istek atmaz.
  Future<void> _register(int epoch, String token) async {
    if (_isFresh(token)) {
      _retryAttempt = 0;
      _setState(PushState.registered);
      return;
    }

    _setState(PushState.registering);
    try {
      await api.registerPushToken(token: token, platform: platform, appVersion: appVersion).timeout(stepTimeout);
    } on PushRegistrationRejected {
      if (!_isCurrent(epoch)) return;
      // Kalıcı red: aynı isteği yinelemek sonucu değiştirmez; otomatik deneme durur.
      _blocked = true;
      _setState(PushState.failed);
      return;
    } on TimeoutException {
      // Sonuç BELİRSİZ: istek sunucuya ulaşıp kaydı yapmış olabilir. Çıkışta silinebilsin diye belirteç
      // hatırlanır; tazelik tanınmaz ki bir sonraki deneme yeniden göndersin.
      _registeredToken = token;
      _registeredAt = null;
      if (_isCurrent(epoch)) _fail(epoch, retry: true);
      return;
    } catch (_) {
      if (_isCurrent(epoch)) _fail(epoch, retry: true);
      return;
    }

    // Sunucu belirteci KABUL ETTİ: oturum bu arada kapanmış olsa bile kaydı hatırlarız ki `stop`'un
    // arka plan temizliği silebilsin. Tazelik, durum ve zamanlayıcı yalnızca oturum hâlâ geçerliyse
    // değişir (kapanmış oturumun kaydı yeni oturumda "taze" sayılmamalı: yeni kullanıcı yeniden bağlar).
    _registeredToken = token;
    if (!_isCurrent(epoch)) {
      _registeredAt = null;
      return;
    }
    _registeredAt = _now();
    _retryAttempt = 0;
    _setState(PushState.registered);
  }

  bool _isFresh(String token) {
    final at = _registeredAt;
    if (_registeredToken != token || at == null) return false;
    final age = _now().difference(at);
    // Saat geriye alındıysa (negatif yaş) güvenmeyip yeniden kaydederiz.
    return !age.isNegative && age < reRegisterAfter;
  }

  void _fail(int epoch, {required bool retry}) {
    _setState(PushState.failed);
    if (retry) _scheduleRetry(epoch);
  }

  /// retryBase · 2^n, retryMax ile sınırlı, ±%20 sapmalı (aynı anda kopan çok cihaz sunucuya aynı
  /// saniyede yüklenmesin diye). Sapma sonrası da retryMax aşılmaz.
  void _scheduleRetry(int epoch) {
    if (!_isCurrent(epoch)) return;
    _retryTimer?.cancel();
    final exponent = min(_retryAttempt, _maxBackoffExponent);
    _retryAttempt++;
    final rawMs = min(retryMax.inMilliseconds, retryBase.inMilliseconds * (1 << exponent));
    final jitter = 0.8 + 0.4 * _random.nextDouble();
    final delayMs = min(retryMax.inMilliseconds, max(1, (rawMs * jitter).round()));
    _retryTimer = Timer(Duration(milliseconds: delayMs), () {
      _retryTimer = null;
      if (!_isCurrent(epoch)) return;
      unawaited(_enqueue(() => _sync(epoch, prompt: false)));
    });
  }

  // ---------------------------------------------------------------------------
  // İç: belirteç yenileme ve gelen mesajlar
  // ---------------------------------------------------------------------------

  /// Mesaj ve belirteç akışlarına oturum başına BİR kez abone olur (abonelikler `stop`ta iptal edilir).
  void _listenToMessages(int epoch) {
    if (_subscriptions.isNotEmpty) return;
    _subscribe<String>(() => gateway.onTokenRefresh, (token) => _onTokenRefreshed(epoch, token));
    _subscribe<PushMessage>(
      () => gateway.onForegroundMessage,
      (message) => _handleMessage(epoch, message, PeaceNoticeSource.foreground),
    );
    _subscribe<PushMessage>(
      () => gateway.onMessageOpened,
      (message) => _handleMessage(epoch, message, PeaceNoticeSource.opened),
    );
  }

  void _subscribe<T>(Stream<T> Function() source, void Function(T) onData) {
    try {
      // Akış hataları (ör. platform tarafı) sessizce yutulur: dinleme kopmaz, log'a bir şey düşmez.
      _subscriptions.add(source().listen(onData, onError: (Object _) {}));
    } catch (_) {
      // Akış alınamadı: bu kaynak olmadan devam edilir (belirteç yine `refresh` ile yakalanır).
    }
  }

  Future<void> _readInitialMessage(int epoch) async {
    // Platform başlangıç mesajını zaten bir kez verir; biz de oturum başına en çok bir kez soruyoruz
    // (her `refresh`te sormak, tüketilmiş mesajı yeniden iletme riskini boşuna doğurur).
    if (_initialMessageRead) return;
    _initialMessageRead = true;
    final message = await _guard<PushMessage?>(gateway.getInitialMessage, null);
    if (message == null || !_isCurrent(epoch)) return;
    _handleMessage(epoch, message, PeaceNoticeSource.initial);
  }

  void _onTokenRefreshed(int epoch, String token) {
    if (!_isCurrent(epoch) || token.isEmpty) return;
    _localTokenMayBeLive = true;
    unawaited(
      _enqueue(() async {
        if (!_isCurrent(epoch)) return;
        // İzin yokken kayıt yapılmaz: izin verilince belirteç zaten alınıp kaydedilecek.
        if (_permission != PushPermission.granted) return;
        // Yeni belirteç yeni bir fırsattır: önceki kalıcı red bu belirteç için geçerli olmayabilir.
        _blocked = false;
        // Eski belirteci silmeye uğraşmayız: FCM onu zaten geçersiz kıldı; sunucu 404/UNREGISTERED ile temizler.
        await _register(epoch, token);
      }),
    );
  }

  void _handleMessage(int epoch, PushMessage message, PeaceNoticeSource source) {
    if (!_isCurrent(epoch)) return;
    final now = _now();
    final notice = PeaceNotice.tryParse(
      message.data,
      title: message.title,
      body: message.body,
      source: source,
      now: now,
    );
    if (notice == null) {
      _handleSafetyMessage(message, source, now);
      return;
    }
    // Tanınmayan/bozuk mesaj sessizce yok sayılır (içeriği loglamak kişisel veri sızdırabilir).
    if (!_markSeen(notice.dedupeKey, now)) return;

    if (_notices.hasListener) {
      _notices.add(notice);
    } else {
      _bufferedNotices.add(notice);
      if (_bufferedNotices.length > maxBufferedNotices) _bufferedNotices.removeAt(0);
    }
  }

  /// Gece hatırlatması değilse güvenlik bildirimi olarak denenir (F2.C.4); tanınmayan mesaj sessizce atılır.
  void _handleSafetyMessage(PushMessage message, PeaceNoticeSource source, DateTime now) {
    final notice = SafetyPushNotice.tryParse(
      message.data,
      title: message.title,
      body: message.body,
      source: source,
      now: now,
    );
    if (notice == null || !_markSeen(notice.dedupeKey, now)) return;
    if (_safetyNotices.hasListener) {
      _safetyNotices.add(notice);
    } else {
      _bufferedSafetyNotices.add(notice);
      if (_bufferedSafetyNotices.length > maxBufferedNotices) _bufferedSafetyNotices.removeAt(0);
    }
  }

  void _flushBufferedSafetyNotices() {
    if (_bufferedSafetyNotices.isEmpty) return;
    scheduleMicrotask(() {
      if (_disposed || _safetyNotices.isClosed || !_safetyNotices.hasListener) return;
      final now = _now();
      final pending = List<SafetyPushNotice>.of(_bufferedSafetyNotices);
      _bufferedSafetyNotices.clear();
      for (final notice in pending) {
        if (now.difference(notice.receivedAt) < safetyBufferMaxAge) _safetyNotices.add(notice);
      }
    });
  }

  /// `true`: ilk kez görüldü (iletilmeli). Aynı anahtar pencere içinde ikinci kez gelirse `false`.
  bool _markSeen(String key, DateTime now) {
    _seenNotices.removeWhere((_, at) => now.difference(at) >= noticeDedupeWindow);
    if (_seenNotices.containsKey(key)) return false;
    _seenNotices[key] = now;
    while (_seenNotices.length > maxSeenNotices) {
      _seenNotices.remove(_seenNotices.keys.first);
    }
    return true;
  }

  /// İlk dinleyici bağlandığında, dinleyici yokken biriken (ve süresi dolmamış) olayları iletir.
  void _flushBufferedNotices() {
    if (_bufferedNotices.isEmpty) return;
    // Olay `onListen` içinde değil, bir sonraki mikro görevde gönderilir: abonelik tamamen kurulmuş olsun.
    scheduleMicrotask(() {
      if (_disposed || _notices.isClosed || !_notices.hasListener) return;
      final now = _now();
      final pending = List<PeaceNotice>.of(_bufferedNotices);
      _bufferedNotices.clear();
      for (final notice in pending) {
        if (now.difference(notice.receivedAt) < noticeDedupeWindow) _notices.add(notice);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // İç: çıkışta kaydı silme
  // ---------------------------------------------------------------------------

  /// Sunucunun bildiği belirteci alır ve hemen "bilinmiyor"a çeker (silme isteği tek sefer gitsin).
  String? _takeRegisteredToken() {
    final token = _registeredToken;
    _registeredToken = null;
    _registeredAt = null;
    return token;
  }

  /// Kuyruğa girmeden silme isteği başlatır; yeni oturumun kaydı bitmesini bekleyebilsin diye izlenir.
  Future<void> _unregisterNow(String token) {
    final future = _deleteToken(token);
    _pendingUnregister = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_pendingUnregister, future)) _pendingUnregister = null;
      }),
    );
    return future;
  }

  /// Kuyrukta, uçuştaki işlemler bittikten sonra çalışır: `stop` sonrası başarıyla dönen bir kayıt varsa siler
  /// ([unregister]) ya da yerel belirteç zaten geçersiz kılındıysa ([invalidate]) hatırlamadan atar.
  Future<void> _unregisterLateLanding(bool unregister, bool invalidate) async {
    if (!unregister) {
      if (invalidate) _takeRegisteredToken();
      return;
    }
    final token = _takeRegisteredToken();
    if (token != null) await _deleteToken(token);
  }

  /// Yerel FCM belirtecini geçersiz kılar (tek uçuş). Belirteç yoksa ya da zaten silindiyse hiçbir şey yapmaz.
  Future<void> _invalidateLocalToken() {
    final inFlight = _localInvalidation;
    if (inFlight != null) return inFlight;
    if (!_localTokenMayBeLive) return Future<void>.value();
    _localTokenMayBeLive = false;
    final future = _deleteLocalToken();
    _localInvalidation = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_localInvalidation, future)) _localInvalidation = null;
      }),
    );
    return future;
  }

  /// `gateway.deleteToken()`'ı en çok [unregisterTimeout] bekler; asla fırlatmaz. Başarısızlıkta (çevrimdışı,
  /// zaman aşımı) belirteç "hâlâ geçerli olabilir" sayılır ve sonraki çıkışta yeniden denenir.
  Future<void> _deleteLocalToken() async {
    try {
      await gateway.deleteToken().timeout(unregisterTimeout);
    } catch (_) {
      _localTokenMayBeLive = true;
    }
  }

  /// `DELETE` isteğini en çok [unregisterTimeout] bekler; asla fırlatmaz.
  Future<void> _deleteToken(String token) async {
    try {
      await api.unregisterPushToken(token).timeout(unregisterTimeout);
    } catch (_) {
      // Zaman aşımı/ağ/oturum hatası: çıkış engellenmez. Sunucu satırı burada silinemese bile belirteç
      // yerelde geçersiz kılınır ([_invalidateLocalToken]); sonraki gönderim FCM `UNREGISTERED` döner
      // ve sunucu satırı kapatır. (Bir sonraki girişte belirteç yeniden bağlanır.)
    }
  }
}
