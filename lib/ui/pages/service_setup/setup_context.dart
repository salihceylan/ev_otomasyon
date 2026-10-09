import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../config/app_config.dart';
import '../../../models/api_models.dart';
import '../../../models/automation_models.dart';
import '../../../services/automation_api_service.dart';
import '../../../services/automation_state.dart';
import '../../../services/clock.dart';
import '../../../services/ev_cloud_api_service.dart';
import 'device_link.dart';
import 'service_target.dart';
import 'setup_problem.dart';
import 'setup_steps.dart';

/// Sayfa kapanırken / denetleyici atılırken uçuştaki işlemlerin sessizce bırakılması.
class SetupCancelled implements Exception {
  const SetupCancelled();
}

/// İki **bağımsız** işi (ör. pano yerel ağ okuması + sunucu isteği) aynı anda başlatır ve ikisi de bitince sonuçlarını
/// verir: toplam bekleme iki sürenin toplamı yerine uzun olanıdır (telefon pano ağında değilken LAN kolu 4 sn'lik
/// bağlantı zaman aşımına kadar sürebilir; sunucu isteği bunun arkasında beklemesin).
///
/// Hata önceliği sıralı koddaki gibidir: [first] hata verdiyse onun hatası, yoksa [second]'ın hatası fırlatılır. Her iki
/// işin hatası da işlenmiş sayılır (işlenmemiş bir hata kalmaz); biri hata verince diğeri sonuna kadar beklenir, böylece
/// çağıran `run` bittiğinde uçuşta iş kalmaz.
Future<(A, B)> awaitBoth<A, B>(Future<A> first, Future<B> second) async {
  A? a;
  B? b;
  Object? firstError;
  StackTrace? firstTrace;
  Object? secondError;
  StackTrace? secondTrace;
  await Future.wait<void>(<Future<void>>[
    first.then<void>((value) => a = value, onError: (Object error, StackTrace trace) {
      firstError = error;
      firstTrace = trace;
    }),
    second.then<void>((value) => b = value, onError: (Object error, StackTrace trace) {
      secondError = error;
      secondTrace = trace;
    }),
  ]);
  final failure = firstError ?? secondError;
  if (failure != null) {
    Error.throwWithStackTrace(failure, (firstError != null ? firstTrace : secondTrace) ?? StackTrace.current);
  }
  return (a as A, b as B);
}

/// Adım mantıklarının ortak bağlamı: durum, saat, bulut istemcisi, pano bağlantısı ve hedef.
///
/// **Aktif ev okunmaz.** Claim sonrası tüm bulut çağrıları [target]'taki `homeId` ile yapılır.
class SetupContext {
  SetupContext({
    required this.state,
    required this.access,
    required this.link,
    required this.onNotify,
    required this.onPersist,
  });

  final AutomationState state;
  final ServiceSetupAccess access;
  final DeviceLink link;
  final VoidCallback onNotify;
  final VoidCallback onPersist;

  /// Kurulumun hedefi (claim sonrası / PIN oturumunda cihaz seçilince atanır).
  ServiceTarget? target;

  /// Claim yanıtındaki **tek seferlik** bulut kimliği; yalnızca bellekte tutulur, panoya yazılınca
  /// hemen bırakılır, hiçbir yere kaydedilmez/loglanmaz.
  DeviceMqttCredential? pendingCredential;

  /// Pano **ev ağındaki bir adresten** (kurulum ağı adresi DEĞİL) kimlik + anahtarla doğrulandı ve ev Wi-Fi
  /// ağına bağlı olduğunu bildirdi: 5. adımın (Wi-Fi) gerçek kanıtıdır (mevcut cihazda "Testleri yap").
  void Function(String host)? onLanVerified;

  /// Denetleyici oturum bitişini buraya yansıtır.
  bool sessionEnded = false;

  bool disposed = false;

  final List<Timer> _timers = <Timer>[];
  final List<Completer<void>> _delays = <Completer<void>>[];

  Clock get clock => state.clock;
  EvCloudApiService get cloud => state.cloudApi;

  ServiceTarget get requireTarget {
    final t = target;
    if (t == null) {
      throw const SetupProblemException(SetupProblem(
        kind: SetupProblemKind.validation,
        title: 'Cihaz henüz seçilmedi',
        why: 'Bu işlem için önce cihazın dairesi belirlenmeli.',
        todo: 'Önceki adımları tamamlayın.',
        retryable: false,
      ));
    }
    return t;
  }

  /// Oturum (servis PIN süresi veya hesap oturumu) bitti mi.
  bool get isSessionOver {
    // Biyometrik yeniden kilit oturum bitişi değildir: kilit açılınca sihirbaz aynı denetleyiciyle sürer.
    if (sessionEnded || (!state.isAuthenticated && !state.isBiometricLocked)) return true;
    final expires = access.sessionExpiresAt;
    return expires != null && !clock.now().isBefore(expires);
  }

  /// Oturum bittiyse eylemleri durdurur ("Oturum süresi doldu"); atıldıysa sessizce iptal eder.
  void ensureActive() {
    if (disposed) throw const SetupCancelled();
    if (isSessionOver) throw const SetupSessionExpiredException();
  }

  void notify() {
    if (!disposed) onNotify();
  }

  void persist() {
    if (!disposed) onPersist();
  }

  /// Saatle (`state.clock`) bekler; atılırsa bekleme hemen biter ve sonraki [ensureActive] iptal eder.
  Future<void> delay(Duration duration) {
    if (disposed) return Future<void>.value();
    final completer = Completer<void>();
    _delays.add(completer);
    late final Timer timer;
    timer = clock.timer(duration, () {
      if (!completer.isCompleted) completer.complete();
      _timers.remove(timer);
      _delays.remove(completer);
    });
    _timers.add(timer);
    return completer.future;
  }

  /// Saatle (`state.clock`) periyodik çağrı; denetleyici atılınca otomatik iptal edilir.
  Timer periodic(Duration period, void Function() callback) {
    final timer = clock.periodic(period, (_) {
      if (!disposed) callback();
    });
    _timers.add(timer);
    return timer;
  }

  /// [periodic] ile kurulan zamanlayıcıyı iptal eder.
  void cancelTimer(Timer? timer) {
    if (timer == null) return;
    timer.cancel();
    _timers.remove(timer);
  }

  /// Pano tarafından **reddedilen** son anahtar (yalnızca bellekte): aynı anahtar panoya yeniden
  /// gönderilmez (5 hatalı denemede pano 60 sn kilitlenir). Elle yeni anahtar girilince sıfırlanır.
  String? _rejectedKey;

  /// Bellekteki anahtar elle girildi (servis_kurulum-5): 6. adımda (internet var) sunucudaki anahtarla doğrulanır.
  bool _keyIsManual = false;

  /// Elle girilen anahtar sunucudaki kayıtla doğrulanamadı (sunucu anahtar vermedi / ulaşılamadı): 6. adımda uyarı.
  bool manualKeyUnverified = false;

  /// Hazırlanmamış (anahtarsız) pano: bulut ve teslim adımları yapılamaz (servis_kurulum-1).
  static const SetupProblem unprovisionedProblem = SetupProblem(
    kind: SetupProblemKind.deviceRejected,
    title: 'Pano hazırlanmamış',
    why: 'Panoda cihaz anahtarı yok; bulut kurulumu ve teslim yapılamaz.',
    todo: '5. adımda Panoyu Hazırla ile ilk hazırlığı yapın.',
    fixStep: SetupSteps.wifi,
  );

  /// Sunucudan (yetkiliyse) cihaz yerel anahtarını alır; verilmezse `null`.
  ///
  /// **Hiçbir yere kaydedilmez**: `AutomationState.localKeyFor` gibi güvenli depoya yazmaz (teknisyenin
  /// telefonunda müşteri panolarının LAN anahtarı kalmasın; kurulum yetkisi bitince de taşınmasın).
  /// Anahtar yalnızca [ServiceTarget.localKey] içinde (bellekte) tutulur. İstek **her zaman claim edilen
  /// eve** gider (aktif ev okunmaz). Süper kullanıcıya sunucu anahtar vermediği için ona hiç sorulmaz
  /// (anahtar elle girilir).
  ///
  /// Ağ/oturum hataları [ApiException] olarak yukarı verilir (internet yok ile "anahtar verilmedi" ayrılsın);
  /// 403/404 gibi "anahtar yok" yanıtları `null` döner.
  Future<String?> fetchLocalKey() async {
    final t = requireTarget;
    if (access.isSuperUser) return null;
    try {
      final key = await cloud.localKey(t.homeId, t.deviceUuid);
      return key.isEmpty ? null : key;
    } on ApiException catch (e) {
      if (e.isNetwork || e.isUnauthorized || e.isServiceSessionExpired || e.isServerError) rethrow;
      return null;
    }
  }

  /// Anahtar elle girildi (8-32 görünür ASCII). [manual] `false`: anahtar sunucudan alındı (elle doğrulama gerekmez).
  void useManualKey(String key, {bool manual = true}) {
    final t = requireTarget;
    _rejectedKey = null;
    _keyIsManual = manual;
    manualKeyUnverified = false;
    target = t.copyWith(localKey: key);
    link.useKey(key);
  }

  /// Elle girilen ve pano tarafından kabul edilen anahtar sunucudakiyle karşılaştırılır (servis_kurulum-5). Farklıysa
  /// panonun anahtarı sunucudakine çevrilir (`rekey`): panonun kendi bulut kimliğini alması (bootstrap) ve ev sahibinin
  /// yerel erişimi sunucu anahtarıyla çalışır. Sunucu anahtarı alınamazsa elle girilenle devam edilir ve uyarı gösterilir.
  /// Süper yöneticiye sunucu anahtar vermediği için çağrılmaz. Dönüş: kullanılacak anahtar.
  Future<String> _reconcileManualKey(String manual) async {
    String? server;
    try {
      server = await fetchLocalKey();
    } on ApiException catch (e) {
      if (e.isServiceSessionExpired || e.isUnauthorized) rethrow;
      server = null; // ağ / sunucu hatası: doğrulanamadı
    }
    ensureActive();
    if (server == null || server.isEmpty) {
      manualKeyUnverified = true;
      return manual;
    }
    manualKeyUnverified = false;
    if (server == manual) {
      _keyIsManual = false;
      return manual;
    }
    await link.verifiedApi.rekey(server);
    ensureActive();
    link.useKey(server);
    final ok = await link.verifiedApi.checkKey();
    ensureActive();
    if (!ok) {
      link.invalidate(dropKey: true);
      target = requireTarget.copyWith(clearLocalKey: true);
      throw const SetupProblemException(_keyRejected);
    }
    _keyIsManual = false;
    return server;
  }

  static const SetupProblem _keyUnavailable = SetupProblem(
    kind: SetupProblemKind.unauthorized,
    title: 'Cihaz anahtarı alınamadı',
    why: 'Anahtar sunucudan alınamadı (yetkiniz yok, kayıt bulunamadı ya da süper yönetici hesabıyla '
        'girdiniz: sunucu süper yöneticiye cihaz anahtarı vermez).',
    todo: 'Fabrika/servis kaydındaki anahtarı elle girin. Servis personeli hesabıyla ya da kurulum PIN\'iyle '
        'girdiyseniz "Tekrar dene"ye basın.',
  );

  static const SetupProblem _keyRejected = SetupProblem(
    kind: SetupProblemKind.unauthorized,
    title: 'Pano cihaz anahtarını kabul etmedi',
    why: 'Sunucudaki anahtar panoda tanımlı değil (pano yeniden anahtarlanmış ya da başka bir anahtarla kurulmuş '
        'olabilir). Pano kilitlenmesin diye aynı anahtar yeniden gönderilmedi.',
    todo: 'Fabrika/servis kaydındaki güncel anahtarı elle girin. Anahtarı bilmiyorsanız yöneticiden alın.',
  );

  /// Panoya doğrulanmış (kimlik + anahtar) yerel bağlantı kurar ve istemciyi döndürür.
  ///
  /// Anahtar sırası: elle girilen / bellekteki anahtar, yoksa sunucu (internet gerekir; kurulum ağında
  /// DEĞİL, ev ağında çağrılır). Pano anahtarı **reddederse** eskimiş olabileceği için sunucudan taze anahtar
  /// alınır ve yalnızca **farklıysa** bir kez daha denenir; reddedilen anahtar hedefte bırakılmaz.
  Future<AutomationApiService> ensureDeviceReady({bool refreshKey = false}) async {
    ensureActive();
    final t = requireTarget;
    if (!refreshKey && link.isReadyFor(t.ip)) return link.verifiedApi;
    if (t.ip.trim().isEmpty) throw LocalApiException.notConfigured();

    var fromServer = false;
    String? key = refreshKey ? null : (t.localKey ?? link.key);
    if (key == null || key.isEmpty) {
      key = await fetchLocalKey();
      fromServer = true;
      _keyIsManual = false;
      ensureActive();
    }
    if (key == null || key.isEmpty) throw const SetupProblemException(_keyUnavailable);
    if (key == _rejectedKey) throw const SetupProblemException(_keyRejected);

    // 1) Kimlik: anahtar gönderilmeden panonun beklenen cihaz olduğu doğrulanır.
    link.useKey(key);
    final identity = await link.probe(t.ip, expectedUid: t.deviceUuid);
    ensureActive();
    // Hazırlanmamış pano (anahtarsız): bulut / teslim yapılamaz; kayıttan devamda da 6-9. adımlar kapanır (servis_kurulum-1).
    if (identity.provisioned == false) throw const SetupProblemException(unprovisionedProblem);
    // 2) Anahtar pano tarafından kabul ediliyor mu?
    var accepted = await link.verifiedApi.checkKey();
    ensureActive();
    if (!accepted && !fromServer) {
      // Elimizdeki anahtar eskimiş olabilir: sunucudan taze anahtarı al, yalnızca farklıysa bir kez dene.
      final rejected = key;
      final fresh = await fetchLocalKey();
      ensureActive();
      if (fresh != null && fresh.isNotEmpty && fresh != rejected) {
        key = fresh;
        link.useKey(key);
        accepted = await link.verifiedApi.checkKey();
        ensureActive();
      }
    }
    if (!accepted) {
      _rejectedKey = key;
      link.invalidate(dropKey: true);
      target = requireTarget.copyWith(clearLocalKey: true);
      throw const SetupProblemException(_keyRejected);
    }
    // Elle girilen anahtar kabul edildi: sunucudakiyle eşitlenir (servis_kurulum-5; süper yöneticide sunucu anahtarı yok).
    if (_keyIsManual && !access.isSuperUser) key = await _reconcileManualKey(key);
    _rejectedKey = null;
    link.markKeyChecked();
    target = requireTarget.copyWith(localKey: key);
    final host = t.ip.trim();
    if ((link.lastIdentity?.onHomeNetwork ?? false) && host != AppConfig.current.deviceApHost) {
      onLanVerified?.call(host);
    }
    return link.verifiedApi;
  }

  /// Panoya yapılan bir anahtarlı çağrıyı sarar: gerekirse bağlantıyı kurar; bağlantı/anahtar hatasında
  /// bağlantıyı geçersiz sayar (sonraki çağrı yeniden doğrular). Pano anahtarı **reddederse** anahtar
  /// hedeften de silinir (aynı anahtar tekrar tekrar gönderilip pano kilitlenmesin).
  ///
  /// 401'den sonra çağrı **bir kez** kendiliğinden yinelenir (M4-01): sunucu bekleyen anahtarı panoya bağlantı
  /// doğrulandıktan sonra iletip takas etmiş olabilir. Yinelemede [ensureDeviceReady] anahtar boş olduğu için sunucudan
  /// taze anahtarı alır; sunucu reddedilen anahtarı yeniden verirse `_keyRejected` ile durur (panoya ikinci yanlış
  /// deneme gitmez). Firmware anahtarı komuttan önce denetlediğinden 401 komutun uygulanmadığı anlamına gelir; yineleme
  /// güvenlidir. Süper yöneticiye sunucu anahtar vermediği için yinelenmez (elle girilen anahtar reddedildi demektir).
  Future<T> deviceCall<T>(Future<T> Function(AutomationApiService api) action, {bool retried = false}) async {
    final api = await ensureDeviceReady();
    try {
      return await action(api);
    } on LocalApiException catch (e) {
      if (e.isNetwork || e.isUnauthorized) link.invalidate(dropKey: e.isUnauthorized);
      if (e.isUnauthorized) {
        _rejectedKey = target?.localKey ?? _rejectedKey;
        final t = target;
        if (t != null) target = t.copyWith(clearLocalKey: true);
        if (!retried && !access.isSuperUser) return deviceCall(action, retried: true);
      }
      rethrow;
    }
  }

  /// Pano durumunu [done] koşulunu sağlayana kadar yoklar; süre dolarsa `null`.
  Future<DeviceStatus?> pollStatus(
    bool Function(DeviceStatus status) done, {
    Duration timeout = const Duration(seconds: 3),
    Duration interval = const Duration(milliseconds: 300),
  }) async {
    final deadline = clock.now().add(timeout);
    while (true) {
      ensureActive();
      final status = await deviceCall((api) => api.fetchStatus());
      if (done(status)) return status;
      if (!clock.now().add(interval).isBefore(deadline)) return null;
      await delay(interval);
    }
  }

  void dispose() {
    disposed = true;
    for (final timer in List<Timer>.of(_timers)) {
      timer.cancel();
    }
    _timers.clear();
    for (final completer in List<Completer<void>>.of(_delays)) {
      if (!completer.isCompleted) completer.complete();
    }
    _delays.clear();
  }
}

/// Bir adımın mantığı: tek-uçuşlu eylem çalıştırıcı, hata -> [SetupProblem] çevirisi, "tekrar dene".
abstract class SetupLogic {
  SetupLogic(this.ctx);

  final SetupContext ctx;

  /// Adım numarası (1..10).
  int get number;

  /// Bu adımın geçiş koşulu **gerçek cihaz/sunucu yanıtıyla** sağlandı mı.
  bool get isComplete;

  /// Kalıcı kayda yazılacak gizli olmayan veri (boş olabilir).
  Map<String, dynamic> snapshot() => const <String, dynamic>{};

  /// Kayıttan geri yükleme (gizli olmayan veri).
  void restore(Map<String, dynamic> json) {}

  /// Denetleyici atılırken (kaynak bırakma: istemci, zamanlayıcı ...). Varsayılan: yapılacak şey yok.
  void dispose() {}

  bool _busy = false;
  String? _busyLabel;
  SetupProblem? _problem;
  Future<void> Function()? _retry;

  bool get busy => _busy;
  String? get busyLabel => _busyLabel;
  SetupProblem? get problem => _problem;
  bool get canRetry => !_busy && _retry != null && (_problem?.retryable ?? false);

  /// Başarısız son eylemi yeniden çalıştırır.
  Future<void> retry() async {
    final retry = _retry;
    if (retry != null && !_busy) await retry();
  }

  /// Hata mesajını elle temizler (kullanıcı alanı düzeltince).
  void clearProblem() {
    if (_problem == null && _retry == null) return;
    _problem = null;
    _retry = null;
    ctx.notify();
  }

  /// Süren eylemin ilerleme metnini günceller (uzun beklemelerde ne beklendiği görünsün; eylem yoksa yok sayılır).
  @protected
  void updateBusyLabel(String label) {
    if (!_busy || _busyLabel == label) return;
    _busyLabel = label;
    ctx.notify();
  }

  /// Dışarıdan hazır bir sorun bildirir (ör. girdi doğrulaması).
  @protected
  void fail(SetupProblem problem, {Future<void> Function()? retry}) {
    _problem = problem;
    _retry = retry;
    ctx.notify();
  }

  /// [action]'ı tek-uçuşlu çalıştırır. Başarıda `true`. Hata [SetupProblem]'e çevrilir ve "Tekrar dene"
  /// aynı eylemi yinelemek üzere kaydedilir. Oturum bitişi / iptal özel ele alınır.
  @protected
  Future<bool> run(String label, Future<void> Function() action) async {
    if (_busy) return false;
    _busy = true;
    _busyLabel = label;
    _problem = null;
    _retry = null;
    ctx.notify();
    var ok = true;
    try {
      ctx.ensureActive();
      await action();
    } on SetupCancelled {
      return false;
    } on SetupSessionExpiredException {
      ctx.sessionEnded = true;
      _problem = SetupProblems.expired();
      ok = false;
    } catch (error) {
      if (ctx.disposed) return false;
      if (error is ApiException && (error.isServiceSessionExpired || error.isUnauthorized)) {
        ctx.sessionEnded = true;
      }
      final problem = SetupProblems.fromError(error, step: number);
      _problem = problem;
      _retry = () => run(label, action);
      ok = false;
    } finally {
      _busy = false;
      _busyLabel = null;
      ctx.notify();
    }
    if (ok) ctx.persist();
    return ok;
  }
}
