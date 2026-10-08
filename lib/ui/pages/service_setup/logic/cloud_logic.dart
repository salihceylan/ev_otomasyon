import '../../../../models/api_models.dart';
import '../../../../models/automation_models.dart';
import '../../../../services/api_exception.dart';
import '../../../../services/automation_api_service.dart';
import '../service_target.dart';
import '../setup_context.dart';
import '../setup_problem.dart';
import '../setup_steps.dart';

/// Adım 6 - Bulut Bağlantısı.
///
/// Claim yanıtındaki **tek seferlik** cihaz kimliği (yoksa sunucudan yeniden üretilen) panoya yerel
/// ağdan `POST /api/mqtt/config` ile yazılır (sunucu adı DNS adıdır, port 8884). Kimlik yalnızca bellekte
/// durur: yazıldığı anda bırakılır, kaydedilmez/loglanmaz. Sonra sunucuda cihazın **çevrimiçi** olması ve
/// kimlik yazıldıktan **sonra** yeni bir durum iletisi (görülme zamanı ilerlemesi) alınması beklenir.
///
/// **Telefon bu adımda ev Wi-Fi ağındadır (internet var):** 5. adımda telefon panonun kurulum ağındaydı ve
/// internet yoktu. Cihaz yerel anahtarı bu adımda sunucudan (kaydedilmeden) alınır; panonun ev ağındaki
/// adresi (`wifi_sta_ip`) 5. adımda hedefe yazılmıştır. Claim yanıtındaki bulut kimliği uygulama kapanırsa
/// kaybolur: kimlik bellekte yoksa sunucudan yeniden üretilir (`POST /homes/:id/devices/:uuid/mqtt-credential`).
///
/// Bellekte bekleyen (claim'deki tek seferlik) kimlik varken pano sunucuda yeni görülmüş çevrimiçi ise (pano kimliğini
/// kendisi aldı: bootstrap, CONTRACTS §3f) bekleyen kimlik YAZILMAZ ve bırakılır; adım tamamlanır.
///
/// Pano sunucuda **zaten çevrimiçiyse** ve bellekte bekleyen (tek seferlik) kimlik yoksa bulut kimliği
/// DEĞİŞTİRİLMEZ (CONTRACTS §3d): çalışan panonun kimliğini yeniden üretip yazmak onu buluttan düşürür. Kural kipten
/// bağımsızdır: mevcut cihaz ("Mevcut cihazlarım -> Testleri yap"), geçici servis (PIN) oturumunda "Yeni Kurulum" ve
/// kayıttan devam eden personel kurulumu aynı davranır. Kimliği yalnız açık "Kimliği Yeniden Yaz"
/// ([rewriteCredential]) zorla yeniden üretir.
///
/// Geçiş koşulu: sunucu `online=true` + yeni durum. Zaman aşımında pano yerel durumundan
/// (`mqtt_configured`, `time_synced`, `mqtt_connected`, `wifi_connected`) neden-sonuç açıklaması üretilir.
class CloudLogic extends SetupLogic {
  CloudLogic(super.ctx);

  @override
  int get number => SetupSteps.cloud;

  /// Bulutun beklenme süresi.
  static const Duration waitLimit = Duration(seconds: 90);

  /// Bekleyen kimlik varken panonun "şu an buluta bağlı" sayılması için son görülmenin en çok bu kadar eski olması
  /// gerekir (sunucunun `online` bayrağı tek başına bayat olabilir).
  static const Duration freshSeen = Duration(minutes: 2);
  static const Duration pollInterval = Duration(seconds: 3);

  bool _credentialWritten = false;
  bool _online = false;
  bool _alreadyOnline = false;
  DateTime? _baselineSeen;
  DateTime? _lastSeenAt;
  DateTime? _waitStartedAt;
  DeviceStatus? _lanStatus;

  bool get credentialWritten => _credentialWritten;
  bool get online => _online;

  bool _keyMismatch = false;

  /// Ethernet'le doğrulanan panodaki anahtarın izi (`lk_fp`) sunucudakiyle uyuşmuyor (servis_kurulum-1): onaylı
  /// "Panonun Anahtarını Eşitle" ([syncBoardKey]) gerekir.
  bool get keyMismatch => _keyMismatch;

  /// Pano sunucuda zaten çevrimiçiydi: bulut kimliği yeniden üretilip yazılmadı.
  bool get alreadyOnline => _alreadyOnline;
  DateTime? get lastSeenAt => _lastSeenAt;

  /// Beklemenin başladığı zaman (sayaç için); beklemiyorsa `null`.
  DateTime? get waitStartedAt => _waitStartedAt;

  /// Son yerel pano tanısı (varsa).
  DeviceStatus? get lanStatus => _lanStatus;

  bool get waiting => busy && _waitStartedAt != null;

  @override
  bool get isComplete => _online;

  /// Kimliği panoya yazar (henüz yazılmadıysa) ve bulutta çevrimiçi olmasını bekler.
  Future<bool> connectAndWait() => _connect(force: false);

  Future<bool> _connect({required bool force}) => run('Bulut bağlantısı kuruluyor', () async {
        final t = ctx.requireTarget;
        _online = false;
        _alreadyOnline = false;

        if (!_credentialWritten) {
          // Kimlik yazılmadan ÖNCE sunucudaki durum alınır: son görülme zamanının yazımdan sonra ilerlemesi
          // "yeni durum iletisi alındı" kanıtıdır (saat farkından etkilenmez).
          final current = _find(await ctx.cloud.devices(t.homeId), t.deviceUuid);
          if (!force && ctx.pendingCredential != null && current != null && _seenRecently(current)) {
            // Pano kimliğini kendisi aldı (bootstrap, CONTRACTS §3f): sunucu claim'deki tek seferlik kimliği silip yenisini
            // verdi. Bekleyen (artık silinmiş) kimlik YAZILMAZ — yazılırsa pano geçersiz kimlikle yeniden bağlanıp düşerdi.
            // Acil sıfırlama / pano değişiminde pano çevrimdışıdır; orada kimlik yine yazılır. Zorla yazım: "Kimliği
            // Yeniden Yaz".
            ctx.pendingCredential = null;
            _online = true;
            _alreadyOnline = true;
            _lastSeenAt = current.lastSeenAt;
            return;
          }
          if (!force && ctx.pendingCredential == null && current != null && current.online) {
            // Pano zaten buluttan görünüyor (kip ne olursa olsun): çalışan panonun kimliğine dokunulmaz.
            _online = true;
            _alreadyOnline = true;
            _lastSeenAt = current.lastSeenAt;
            return;
          }
          final api = await ctx.ensureDeviceReady();
          await _checkKeyFingerprint(api, t);
          _baselineSeen = current?.lastSeenAt;
          // Aktif ev bu eve ait olmayabilir: istemci yetki kapısı (aktif eve bağlı) atlanır, yetkiyi
          // sunucu (servis personeli / servis oturumu / süper) denetler.
          var credential = ctx.pendingCredential;
          credential ??= await ctx.cloud.reissueDeviceMqttCredential(t.homeId, t.deviceUuid);
          try {
            await api.configureMqtt(credential);
          } on LocalApiException catch (e) {
            // Pano kimliği kabul etmedi: bir sonraki denemede yeniden üretilir.
            if (e.isInvalidInput) ctx.pendingCredential = null;
            rethrow;
          }
          ctx.pendingCredential = null; // yazıldı: bellekten bırakılır
          _credentialWritten = true;
        }
        await _waitForCloud(t.homeId, t.deviceUuid);
      });

  static const SetupProblem _keyMismatchProblem = SetupProblem(
    kind: SetupProblemKind.deviceRejected,
    title: 'Panodaki anahtar sunucudakinden farklı',
    why: 'Pano Ethernet üzerinden anahtarsız erişilebildiği için fark bağlantıda görünmedi: panodaki cihaz anahtarının izi '
        'sunucudaki kayıtla uyuşmuyor. Bu haliyle pano bulut kimliğini kendisi alamaz ve ev sahibinin yerel erişimi çalışmaz.',
    todo: '"Panonun Anahtarını Eşitle"ye basın: panonun anahtarı sunucudakiyle değiştirilir.',
    retryable: false,
  );

  static const SetupProblem _keySyncFailed = SetupProblem(
    kind: SetupProblemKind.deviceRejected,
    title: 'Panonun anahtarı eşitlenemedi',
    why: 'Anahtar panoya yazıldı ama pano hâlâ farklı bir anahtar izi bildiriyor.',
    todo: 'Birkaç saniye bekleyip yeniden deneyin; olmazsa anahtarı servis yazılımıyla (USB) yazın.',
  );

  /// Pano Ethernet adresinden doğrulandıysa (orada `auth/check` her zaman 200: anahtar uyuşmazlığı görünmez) panonun
  /// `lk_fp`'si sunucunun `local_key_fp`'siyle karşılaştırılır (servis_kurulum-1; CONTRACTS sözleşme 1). Personel / servis
  /// PIN oturumunda; süper yöneticiye sunucu anahtar vermez. Biri iz bildirmiyorsa (eski firmware / sunucu) karşılaştırma
  /// yapılmaz. Uygulama HMAC hesaplamaz.
  Future<void> _checkKeyFingerprint(AutomationApiService api, ServiceTarget t) async {
    _keyMismatch = false;
    if (ctx.access.isSuperUser || !_onEthernet(t)) return;
    final ({String key, String? fp}) info;
    try {
      info = await ctx.cloud.localKeyInfo(t.homeId, t.deviceUuid);
    } on ApiException catch (e) {
      if (e.isNetwork || e.isUnauthorized || e.isServiceSessionExpired || e.isServerError) rethrow;
      return; // anahtar verilmedi: karşılaştırma yapılamaz
    }
    final serverFp = info.fp;
    if (serverFp == null) return;
    final status = await api.fetchStatus();
    ctx.ensureActive();
    final boardFp = status.lkFp;
    if (boardFp == null || boardFp == serverFp) return;
    _keyMismatch = true;
    throw const SetupProblemException(_keyMismatchProblem);
  }

  /// Hedef adres panonun Ethernet adresi mi (son kimlik yoklamasından).
  bool _onEthernet(ServiceTarget t) {
    final id = ctx.link.lastIdentity;
    return id != null && id.ethConnected == true && id.ethIp.isNotEmpty && id.ethIp == t.ip.trim();
  }

  /// Panonun anahtarını sunucudakiyle eşitler (onaylı; servis_kurulum-1): `POST /api/auth/rekey` Ethernet'ten anahtarsız
  /// da kabul edilir (karar 1). Sonra durum yeniden okunur; izler eşleşmezse sorun bildirilir. Süper yöneticide yoktur.
  Future<bool> syncBoardKey() => run('Panonun anahtarı eşitleniyor', () async {
        if (ctx.access.isSuperUser) return;
        final t = ctx.requireTarget;
        final api = await ctx.ensureDeviceReady();
        final info = await ctx.cloud.localKeyInfo(t.homeId, t.deviceUuid);
        await api.rekey(info.key);
        ctx.ensureActive();
        ctx.useManualKey(info.key, manual: false);
        final status = await (await ctx.ensureDeviceReady()).fetchStatus();
        ctx.ensureActive();
        if (info.fp != null && status.lkFp != null && status.lkFp != info.fp) {
          throw const SetupProblemException(_keySyncFailed);
        }
        _keyMismatch = false;
      });

  /// Kimliği sunucudan yeniden üretip panoya yeniden yazar (eski kimlik geçersiz olur).
  Future<bool> rewriteCredential() {
    _credentialWritten = false;
    ctx.pendingCredential = null;
    return _connect(force: true);
  }

  DeviceInfo? _find(List<DeviceInfo> devices, String uid) {
    for (final d in devices) {
      if (d.deviceUuid.toUpperCase() == uid.toUpperCase()) return d;
    }
    return null;
  }

  /// Sunucu panoyu çevrimiçi gösteriyor VE son görülme yeni (saat farkına karşı ileri tarih de kabul).
  bool _seenRecently(DeviceInfo d) {
    if (!d.online) return false;
    final seen = d.lastSeenAt;
    if (seen == null) return false;
    return ctx.clock.now().difference(seen) <= freshSeen;
  }

  bool _isFresh(DeviceInfo d) {
    if (!d.online) return false;
    final base = _baselineSeen;
    if (base == null) return true; // daha önce hiç görülmemişti: çevrimiçi olması yeterli
    final seen = d.lastSeenAt;
    return seen != null && seen.isAfter(base);
  }

  Future<void> _waitForCloud(String homeId, String uid) async {
    final start = ctx.clock.now();
    _waitStartedAt = start;
    final deadline = start.add(waitLimit);
    ctx.notify();
    try {
      while (true) {
        ctx.ensureActive();
        // Yerel tanı (en iyi çaba) ve sunucu listesi birbirine bağlı değil: birlikte beklenir. Telefon pano ağında
        // değilken yerel kol 4 sn'lik bağlantı zaman aşımına kadar sürebilir; sunucu isteği onun arkasında beklemez.
        final (_, devices) = await awaitBoth(_readLan(), ctx.cloud.devices(homeId));
        final device = _find(devices, uid);
        if (device != null && _isFresh(device)) {
          _online = true;
          _lastSeenAt = device.lastSeenAt;
          return;
        }
        if (!ctx.clock.now().add(pollInterval).isBefore(deadline)) break;
        await ctx.delay(pollInterval);
        ctx.notify();
      }
    } finally {
      _waitStartedAt = null;
    }
    throw SetupProblemException(_timeoutProblem());
  }

  /// Panonun yerel durumunu [_lanStatus]'a okur (en iyi çaba): panoya ulaşılamıyorsa `null` olur (hata beklemeyi
  /// bozmaz). Anahtar/kimlik sorunları ([SetupProblemException]) ve iptal/oturum bitişi olduğu gibi yukarı verilir.
  Future<void> _readLan() async {
    try {
      _lanStatus = await ctx.deviceCall((api) => api.fetchStatus());
    } on LocalApiException {
      _lanStatus = null;
    }
  }

  SetupProblem _timeoutProblem() {
    final lan = _lanStatus;
    if (lan == null) {
      return const SetupProblem(
        kind: SetupProblemKind.deviceNetwork,
        title: 'Pano 90 saniyede buluta bağlanamadı',
        why: 'Panoya yerel ağdan ulaşılamıyor; telefon ev ağından ayrılmış veya pano kapanmış olabilir.',
        todo: 'Telefonunuzun ev Wi-Fi ağında olduğunu ve panonun ışıklarının yandığını kontrol edin, sonra "Tekrar dene"ye basın.',
      );
    }
    // Ethernet'li pano Wi-Fi'ye bağlı olmayabilir: "Wi-Fi'den düştü" yalnız ev ağında hiç görünmeyen panoya söylenir.
    if (!lan.onHomeNetwork) {
      return const SetupProblem(
        kind: SetupProblemKind.deviceNetwork,
        title: 'Pano ev Wi-Fi ağından düştü',
        why: 'Pano ev ağına bağlı olduğunu bildirmiyor.',
        todo: '5. adıma dönüp ev Wi-Fi bilgisini yeniden gönderin.',
        fixStep: SetupSteps.wifi,
      );
    }
    if (lan.mqttConfigured == false) {
      return const SetupProblem(
        kind: SetupProblemKind.deviceRejected,
        title: 'Bulut kimliği panoya kaydedilmemiş',
        why: 'Pano bulut kimliğinin kayıtlı olmadığını bildiriyor.',
        todo: '"Kimliği Yeniden Yaz"a basın.',
      );
    }
    if (lan.timeSynced == false) {
      return const SetupProblem(
        kind: SetupProblemKind.network,
        title: 'Pano saati internetten alamıyor',
        why: 'Güvenli bağlantı için pano saati internetten (NTP) almalı; ev modeminin internet erişimi yok ya da engelli.',
        todo: 'Modemin internete çıktığını başka bir cihazla doğrulayın; modemi kapatıp açın ve "Tekrar dene"ye basın.',
      );
    }
    if (lan.mqttConnected == false) {
      return const SetupProblem(
        kind: SetupProblemKind.network,
        title: 'Pano sunucuya güvenli bağlanamıyor',
        why: 'Pano ev ağında ve saati doğru ama bulut sunucusuna (8884 numaralı güvenli bağlantı) ulaşamıyor: '
            'modem/güvenlik duvarı bağlantıyı engelliyor olabilir ya da kimlik reddedildi.',
        todo: 'Modemi yeniden başlatın. Olmazsa "Kimliği Yeniden Yaz"a basın. Hâlâ olmuyorsa telefonun mobil '
            'internet paylaşımı (hotspot) ile deneyin.',
      );
    }
    return const SetupProblem(
      kind: SetupProblemKind.timeout,
      title: 'Pano bağlı görünüyor ama sunucuda henüz çevrimiçi değil',
      why: 'Pano bulut bağlantısını kurduğunu bildiriyor; sunucu henüz durum iletisini kaydetmedi.',
      todo: 'Biraz bekleyip "Tekrar dene"ye basın.',
    );
  }

  @override
  Map<String, dynamic> snapshot() => <String, dynamic>{'online': _online};

  @override
  void restore(Map<String, dynamic> json) {
    _online = json['online'] == true;
  }
}
