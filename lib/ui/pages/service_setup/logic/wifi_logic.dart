import 'dart:convert';

import '../../../../services/automation_api_service.dart';
import '../device_link.dart';
import '../setup_context.dart';
import '../setup_problem.dart';
import '../setup_steps.dart';
import 'identify_logic.dart';

/// Adım 5 - Wi-Fi Kurulumu (**internetsiz ve anahtarsız**).
///
/// Telefon panonun kurulum ağına (AP) bağlıyken internet YOKTUR; bu yüzden bu adım hiçbir sunucu çağrısı
/// ve cihaz anahtarı gerektirmez: Wi-Fi uçları (`scan`, `connect`, `wifi/status`) AP'den anahtarsız çalışır
/// (cihaza özel WPA2 AP parolasını bilmek = fiziksel erişim; CONTRACTS §3d). Akış:
///
/// 1. Telefon kurulum ağına bağlanır, pano **kimliği** anahtarsız `GET /api/status` ile doğrulanır
///    ([checkDevice]; yanlış panoya hiçbir bilgi gitmez).
/// 2. Ev Wi-Fi bilgisi E2'nin paylaşılan Wi-Fi bileşeniyle ([WifiProvisionPanel]) gönderilir; bileşenin
///    sonucu [acceptWifiResult] ile buraya bildirilir. Geçiş koşulu: pano ev ağına bağlandığını bildirdi
///    (`wifi_connect_state: success` + IP) ya da ev ağındaki IP'den doğrulandı ([confirmLanIp]).
///    "Gönderildi" bağlandı demek değildir.
/// 3. Panonun ev ağındaki IP'si (`wifi_sta_ip`) hedefe yazılır; sonraki adım (6) telefon ev ağına dönünce
///    internetle yerel anahtarı sunucudan alır.
///
/// Yalnızca **hazırlanmamış** (fabrika sonrası, anahtarsız) pano için bir istisna vardır: ilk hazırlık
/// (`factory/init`) cihaz anahtarını panoya yazar; bu yüzden [provision] anahtarı bellekten (claim sırasında
/// internetliyken alınmış) kullanır.
///
/// Wi-Fi şifresi ve kurulum ağı parolası bu sınıfta SAKLANMAZ (yalnızca çağrı boyunca geçer).
class WifiLogic extends SetupLogic {
  WifiLogic(super.ctx);

  @override
  int get number => SetupSteps.wifi;

  static const String checkLabel = 'Panoya bağlanılıyor';
  static const String lanLabel = 'Panoya ev ağından bağlanılıyor';
  static const String provisionLabel = 'Pano ilk kez hazırlanıyor';
  static const String fetchKeyLabel = 'Cihaz anahtarı sunucudan alınıyor';
  static const String ethLabel = 'Panoya Ethernet adresinden bağlanılıyor';

  /// Kurulum ağı (AP) için **anahtarsız** pano istemcisi: `X-Device-Key` bu istemciye HİÇ uygulanmaz
  /// (Wi-Fi uçları AP'den anahtarsız çalışır; internet yokken anahtar zaten alınamaz).
  AutomationApiService? _apApi;

  /// Wi-Fi bileşeninin ([WifiProvisionPanel]) kullanacağı anahtarsız kurulum ağı istemcisi.
  AutomationApiService get apApi => _apApi ??= ctx.link.createApi(IdentifyLogic.apHost);

  DeviceIdentity? _identity;
  bool _needsProvision = false;
  bool _awaitingReconnect = false;
  WifiConnectResult? _lastResult;
  bool _connected = false;
  bool _lostContact = false;
  String? _homeIp;
  bool _ethernetMode = false;
  bool _viaEthernet = false;

  /// Ethernet'le ev ağında ama hazırlanmamış panonun adresi (ilk hazırlık bu adrese yapılır; servis_kurulum-1).
  String? _ethProvisionIp;

  /// Teknisyen "Pano kabloyla (Ethernet) bağlı" yolunu seçti (ya da pano Ethernet bildirdi): kurulum ağı ve ev Wi-Fi
  /// bilgisi adımları gizlenir; pano Ethernet IP'sinden doğrulanır ([confirmEthernet]).
  bool get ethernetMode => _ethernetMode;

  /// Adım Ethernet bağlantısıyla tamamlandı (teslim özeti: "Pano ev ağına Ethernet ile bağlı").
  bool get viaEthernet => _viaEthernet;

  /// Ethernet yolunu açar/kapatır (Wi-Fi akışı aynen kalır).
  void setEthernetMode(bool on) {
    if (_ethernetMode == on) return;
    _ethernetMode = on;
    clearProblem();
    ctx.notify();
  }

  /// Panoya ulaşıldı ve kimliği beklenen cihazla eşleşti (anahtarsız doğrulandı).
  DeviceIdentity? get identity => _identity;

  /// Pano henüz hazırlanmamış (anahtar yok): önce ilk hazırlık gerekir.
  bool get needsProvision => _needsProvision;

  /// Hazırlanmamış Ethernet panosunun adresi (biliniyorsa).
  String? get ethProvisionIp => _ethProvisionIp;

  /// İlk hazırlık yapıldı; pano kurulum ağını yeniden başlatıyor (telefon yeniden bağlanmalı).
  bool get awaitingReconnect => _awaitingReconnect;

  /// Pano doğrulandı ve hazır: ev Wi-Fi bilgisi gönderilebilir (Wi-Fi bileşeni etkinleşir).
  bool get deviceReady => _identity != null && !_needsProvision;

  /// Son ev Wi-Fi bağlanma denemesinin sonucu.
  WifiConnectResult? get lastResult => _lastResult;

  /// Pano ev ağına bağlandı.
  bool get connected => _connected;

  /// Deneme sırasında panoyla bağlantı koptu (pano kurulum ağını kapatmış olabilir): sonuç belirsiz.
  bool get lostContact => _lostContact;

  /// Panonun ev ağındaki IP adresi (biliniyorsa).
  String? get homeIp => _homeIp;

  /// İlk hazırlık için bellekte bir cihaz anahtarı var mı.
  bool get hasProvisionKey => (ctx.target?.localKey ?? ctx.link.key)?.isNotEmpty ?? false;

  @override
  bool get isComplete => _connected;

  // Arayüz oluşturulurken / her tuş vuruşunda çalışan doğrulamalar için bir kez derlenen kalıplar.
  static final RegExp _uidPattern = RegExp(r'^AHBU-S3-([0-9A-F]{6})$');
  static final RegExp _schemePattern = RegExp(r'^https?://', caseSensitive: false);
  static final RegExp _forbiddenHostChars = RegExp(r'[/?#@\s]');

  /// Telefonun bağlanacağı kurulum ağının tahmini adı (UID'den): `AHBU-S3-A1B2C3` -> `AHBU-A1B2C3`.
  static String? apSsidFor(String uid) {
    final match = _uidPattern.firstMatch(uid.toUpperCase());
    return match == null ? null : 'AHBU-${match.group(1)}';
  }

  /// Telefon kurulum ağında mı yoksa pano zaten ev ağında mı (hedef adres kurulum ağı adresi mi).
  bool get usingSetupNetwork => ctx.target?.ip == IdentifyLogic.apHost || (ctx.target?.ip.isEmpty ?? true);

  /// Adres kutusu için hızlı doğrulama: geçerli yerel adres ise `null`.
  static String? validateHost(String raw) {
    var text = raw.trim();
    const invalid = 'Adres geçersiz. Yerel ağ IP adresi yazın (ör. 192.168.1.40).';
    if (text.isEmpty) return 'Panonun IP adresini yazın (ör. 192.168.1.40).';
    text = text.replaceFirst(_schemePattern, '');
    if (text.contains(_forbiddenHostChars)) return invalid;
    final uri = Uri.tryParse('http://$text');
    if (uri == null || uri.host.isEmpty || uri.hasQuery) return invalid;
    return AutomationApiService.isAllowedDeviceHost(uri.host) ? null : invalid;
  }

  /// Panoya kurulum ağından bağlanır ve **kimliğini anahtarsız** doğrular. Pano hazırlanmamışsa
  /// ([DeviceIdentity.provisioned] `false`) ilk hazırlık kartı açılır.
  Future<bool> checkDevice() => run(checkLabel, () async {
        final t = ctx.requireTarget;
        if (t.ip.isEmpty) ctx.target = t.copyWith(ip: IdentifyLogic.apHost);
        _identity = null;
        _needsProvision = false;
        // Wi-Fi bilgisi gönderilecek pano **kurulum ağındaki** (AP) panodur; kimliği anahtarsız doğrulanır.
        final identity = await DeviceIdentity.verify(apApi, t.deviceUuid);
        _identity = identity;
        // Kimlik kurulum ağından doğrulandı: hedef kurulum ağı adresidir (mevcut cihaz / kayıttan devamdaki eski ev IP'si
        // değil; servis_kurulum-7). Ev IP'sini sonra Wi-Fi sonucu ya da IP doğrulaması yazar.
        ctx.target = ctx.requireTarget.copyWith(ip: IdentifyLogic.apHost);
        // Pano kablolu ağda olduğunu bildiriyor: Wi-Fi bilgisi gerekmez, Ethernet yolu önerilir. Hazırlanmamış pano bu yola
        // alınmaz: önce ilk hazırlık (servis_kurulum-1).
        if (identity.ethConnected == true && identity.provisioned != false) _ethernetMode = true;
        if (identity.provisioned == false) {
          _needsProvision = true;
          return;
        }
        _awaitingReconnect = false;
      });

  /// Cihaz anahtarı elle girildi (8-32 görünür ASCII): ilk hazırlıkta kullanılmak üzere bellekte tutulur. [confirm] ikinci
  /// yazımdır (servis_kurulum-5): uyuşmazsa anahtar kullanılmaz ("Panoyu Hazırla" kapalı kalır); yanlış anahtar panonun
  /// bulut bağlantısını bozar ve USB gerektirir.
  bool useManualKey(String key, {String? confirm}) {
    if (!AutomationApiService.isValidLocalKey(key)) {
      fail(const SetupProblem(
        kind: SetupProblemKind.validation,
        title: 'Cihaz anahtarı geçersiz',
        why: 'Anahtar 8-32 karakter olmalı; boşluk içeremez.',
        todo: 'Anahtarı fabrika/servis kaydından aynen kopyalayın.',
        retryable: false,
      ));
      return false;
    }
    if (confirm != null && confirm != key) {
      fail(const SetupProblem(
        kind: SetupProblemKind.validation,
        title: 'Anahtarlar eşleşmiyor',
        why: 'İkinci kez yazılan anahtar ilkiyle aynı değil.',
        todo: 'Anahtarı iki alana da aynen yazın. Yanlış anahtar panonun bulut bağlantısını bozar ve USB gerektirir.',
        retryable: false,
      ));
      return false;
    }
    clearProblem();
    ctx.useManualKey(key);
    ctx.notify();
    return true;
  }

  /// İlk hazırlık için anahtarı sunucudan alır (telefonun **internete bağlı** olması gerekir; kurulum
  /// ağında internet yoktur). Anahtar yalnızca bellekte tutulur.
  Future<bool> fetchKeyForProvision() => run(fetchKeyLabel, () async {
        final key = await ctx.fetchLocalKey();
        if (key == null || key.isEmpty) {
          throw const SetupProblemException(SetupProblem(
            kind: SetupProblemKind.unauthorized,
            title: 'Cihaz anahtarı alınamadı',
            why: 'Sunucu bu hesaba cihaz anahtarı vermedi (süper yönetici hesabı ya da yetki yok).',
            todo: 'Fabrika/servis kaydındaki anahtarı elle girin.',
            retryable: false,
          ));
        }
        ctx.useManualKey(key, manual: false); // sunucudan alındı: elle girilmiş sayılmaz (servis_kurulum-5)
      });

  /// Kurulum ağı parolası denetimi (uygulama-ekranlar-3): 8-32 bayt, ikinci yazımla aynı ve etiket karekodu okunduysa
  /// ([labelPassword]) etiketteki parolayla aynı. Panonun ilk hazırlığı geri alınamaz (sonraki `factory/init` 403
  /// `already_provisioned`): yanlış parola etiketi kalıcı geçersiz kılar, kurtarma USB ister. Geçersizse sorun yazılır.
  bool _apPassValid(String apPass, String apPassConfirm, String? labelPassword) {
    final bytes = utf8.encode(apPass).length;
    if (bytes < 8 || bytes > 32) {
      fail(const SetupProblem(
        kind: SetupProblemKind.validation,
        title: 'Kurulum ağı parolası geçersiz',
        why: 'Parola 8-32 karakter olmalı.',
        todo: 'Pano etiketindeki "AĞ PAROLASI (AP)" değerini aynen yazın.',
        retryable: false,
      ));
      return false;
    }
    if (apPass != apPassConfirm) {
      fail(const SetupProblem(
        kind: SetupProblemKind.validation,
        title: 'Kurulum ağı parolası doğrulanamadı',
        why: 'Kurulum ağı parolaları eşleşmiyor.',
        todo: 'Etiketteki "AĞ PAROLASI (AP)" değerini iki alana da aynen yazın ya da etiketteki kurulum ağı karekodunu '
            'okutun.',
        retryable: false,
      ));
      return false;
    }
    if (labelPassword != null && apPass != labelPassword) {
      fail(const SetupProblem(
        kind: SetupProblemKind.validation,
        title: 'Kurulum ağı parolası doğrulanamadı',
        why: 'Yazdığınız parola etiketteki parolayla eşleşmiyor.',
        todo: 'Parolayı etiketteki gibi yazın ya da etiketteki kurulum ağı karekodunu yeniden okutun; pano başka bir '
            'parolayla hazırlanırsa etiketteki parola geçersiz kalır.',
        retryable: false,
      ));
      return false;
    }
    return true;
  }

  /// Panonun ilk hazırlığı: yerel anahtar + kurulum ağı parolası panoya yazılır (`factory/init`).
  /// Pano kurulum ağını bu parolayla (WPA2) yeniden başlatır: telefon yeniden bağlanmalıdır. [apPassConfirm] parolanın
  /// ikinci yazımı, [labelPassword] etiket karekodundan okunan parola (okunduysa); uyuşmazsa panoya yazılmaz.
  Future<bool> provision({required String apPass, required String apPassConfirm, String? labelPassword}) {
    if (!_apPassValid(apPass, apPassConfirm, labelPassword)) return Future<bool>.value(false);
    return run(provisionLabel, () async {
      final t = ctx.requireTarget;
      final key = t.localKey ?? ctx.link.key;
      if (key == null || key.isEmpty) {
        throw const SetupProblemException(SetupProblem(
          kind: SetupProblemKind.unauthorized,
          title: 'Cihaz anahtarı yok',
          why: 'Panoyu hazırlamak için cihaz anahtarı gerekiyor; kurulum ağında internet olmadığı için sunucudan '
              'alınamıyor.',
          todo: '"Anahtarı Sunucudan Al"a basın (telefon internete bağlıyken) ya da fabrika/servis kaydındaki '
              'anahtarı elle girin.',
          retryable: false,
        ));
      }
      // Anahtarlı olmayan bu çağrıdan önce de kimlik doğrulanır (yanlış panoya yazılmaz). Bu yol DAİMA kurulum ağı
      // adresidir (servis_kurulum-7): mevcut cihaz / kayıttan devamda hedefte eski ev IP'si kalmış olabilir. Ethernet yolu:
      // [provisionViaEthernet].
      await ctx.link.probe(IdentifyLogic.apHost, expectedUid: t.deviceUuid);
      ctx.link.useKey(key);
      await ctx.link.verifiedApi.factoryInit(localKey: key, apPass: apPass);
      ctx.link.invalidate();
      ctx.target = ctx.requireTarget.copyWith(ip: IdentifyLogic.apHost, localKey: key);
      _needsProvision = false;
      _awaitingReconnect = true;
      _identity = null;
    });
  }

  static const SetupProblem _ethNoKey = SetupProblem(
    kind: SetupProblemKind.unauthorized,
    title: 'Cihaz anahtarı yok',
    why: 'Panoyu hazırlamak için cihaz anahtarı gerekiyor; sunucu bu hesaba anahtar vermedi (süper yönetici hesabı ya da '
        'yetki yok).',
    todo: 'Fabrika/servis kaydındaki anahtarı elle (iki kez) girin, sonra "Panoyu Hazırla"ya basın.',
    retryable: false,
  );

  static const SetupProblem _ethProvisionUnconfirmed = SetupProblem(
    kind: SetupProblemKind.deviceRejected,
    title: 'Pano hazırlanmış görünmüyor',
    why: 'İlk hazırlık gönderildi ama pano hâlâ cihaz anahtarı olmadığını bildiriyor.',
    todo: 'Birkaç saniye bekleyip "Panoyu Hazırla"yı yeniden deneyin; olmazsa panoyu servis yazılımıyla (USB) hazırlayın.',
  );

  /// Ethernet'le ev ağındaki **hazırlanmamış** panonun ilk hazırlığı (servis_kurulum-1): `factory/init` panonun Ethernet
  /// adresine gider (karar 2: her arayüzden kabul edilir). Telefon ev ağındadır (internet var): anahtar bellekte yoksa
  /// sunucudan alınır (süper yöneticide elle girilir). Hazırlıktan sonra pano yeniden okunur; `provisioned` doğrulanmadan
  /// adım tamamlanmaz.
  Future<bool> provisionViaEthernet({
    required String ip,
    required String apPass,
    required String apPassConfirm,
    String? labelPassword,
  }) {
    if (!_apPassValid(apPass, apPassConfirm, labelPassword)) return Future<bool>.value(false);
    final error = validateHost(ip);
    if (error != null) {
      fail(SetupProblem(
        kind: SetupProblemKind.validation,
        title: 'Pano adresi geçersiz',
        why: error,
        todo: 'Modem arayüzündeki cihaz listesinden panonun kablolu (Ethernet) IP adresine bakın.',
        retryable: false,
      ));
      return Future<bool>.value(false);
    }
    return run(provisionLabel, () async {
      final clean = ip.trim();
      final t = ctx.requireTarget;
      var key = t.localKey ?? ctx.link.key;
      if (key == null || key.isEmpty) {
        key = await ctx.fetchLocalKey();
        ctx.ensureActive();
        if (key != null && key.isNotEmpty) ctx.useManualKey(key, manual: false);
      }
      if (key == null || key.isEmpty) throw const SetupProblemException(_ethNoKey);
      // Kimlik anahtarsız doğrulanır (yanlış panoya yazılmaz).
      await ctx.link.probe(clean, expectedUid: t.deviceUuid);
      ctx.link.useKey(key);
      await ctx.link.verifiedApi.factoryInit(localKey: key, apPass: apPass);
      ctx.link.invalidate();
      final after = await ctx.link.probe(clean, expectedUid: t.deviceUuid);
      ctx.ensureActive();
      if (after.provisioned != true) throw const SetupProblemException(_ethProvisionUnconfirmed);
      ctx.target = ctx.requireTarget.copyWith(ip: clean, localKey: key);
      _identity = after;
      _needsProvision = false;
      _ethProvisionIp = null;
      _connected = true;
      _viaEthernet = true;
      _ethernetMode = true;
      _lostContact = false;
      _homeIp = clean;
    });
  }

  /// Ağ kurulumunu baştan yapar (servis_kurulum-7): mevcut cihazda / kayıttan devamda tamamlanmış 5. adım (ör. yanlış ev
  /// ağı, modem değişti) yeniden yapılabilsin. Pano ve sunucuya istek atılmaz; kayıt güncellenir.
  void restartNetworkSetup() {
    if (busy) return;
    _connected = false;
    _viaEthernet = false;
    _ethernetMode = false;
    _lostContact = false;
    _awaitingReconnect = false;
    _needsProvision = false;
    _ethProvisionIp = null;
    _identity = null;
    _lastResult = null;
    _homeIp = null;
    clearProblem();
    ctx.link.invalidate();
    ctx.notify();
    ctx.persist();
  }

  /// E2'nin Wi-Fi bileşeninin ([WifiProvisionPanel]) bağlanma sonucunu geçiş koşuluna çevirir. Başarı
  /// **yalnızca** panonun `success` bildirmesiyle sayılır.
  void acceptWifiResult(WifiConnectResult result) {
    _lastResult = result;
    _lostContact = false;
    _connected = false;
    clearProblem();
    switch (result.outcome) {
      case WifiConnectOutcome.success:
        _connected = true;
        final ip = result.ipAddress;
        if (ip != null && ip.isNotEmpty && validateHost(ip) == null) {
          _homeIp = ip;
          ctx.target = ctx.requireTarget.copyWith(ip: ip);
        }
        ctx.link.invalidate();
      case WifiConnectOutcome.failed:
        fail(SetupProblem(
          kind: SetupProblemKind.deviceRejected,
          title: 'Pano ev Wi-Fi ağına bağlanamadı',
          why: result.message,
          todo: _failedTodo(result.reason),
        ));
      case WifiConnectOutcome.timedOut:
        fail(SetupProblem(
          kind: SetupProblemKind.timeout,
          title: 'Bağlantı zaman aşımına uğradı',
          why: result.message,
          todo: 'Ağ adını ve şifreyi kontrol edin; modemin panoya yakın olduğundan emin olup yeniden deneyin.',
        ));
      case WifiConnectOutcome.lostContact:
        _lostContact = true;
        ctx.link.invalidate();
    }
    ctx.notify();
    ctx.persist();
  }

  static String _failedTodo(int reason) {
    switch (reason) {
      case 2:
      case 15:
      case 202:
      case 204:
        return 'Wi-Fi şifresini kontrol edin (büyük/küçük harfe dikkat edin) ve yeniden deneyin.';
      case 201:
        return 'Ağ adını kontrol edin. Modem 5 GHz\'e ayarlıysa pano bağlanamaz: 2.4 GHz ağı seçin. '
            'Panoyu modeme yaklaştırın.';
      default:
        return 'Ağ adını ve şifreyi kontrol edin; modemi kısa süre kapatıp açın ve yeniden deneyin.';
    }
  }

  /// Pano ev ağında (kurulum ağı kapandı ya da pano zaten ev ağında): IP adresiyle bağlanıp pano kimliği
  /// anahtarsız doğrulanır ve `wifi_connected` bilgisine bakılır (anahtar ve internet gerekmez).
  Future<bool> confirmLanIp(String ip) {
    final error = validateHost(ip);
    if (error != null) {
      fail(SetupProblem(
        kind: SetupProblemKind.validation,
        title: 'Pano adresi geçersiz',
        why: error,
        todo: 'Modem arayüzündeki cihaz listesinden panonun IP adresine bakın.',
        retryable: false,
      ));
      return Future<bool>.value(false);
    }
    return run(lanLabel, () async {
      final clean = ip.trim();
      final t = ctx.requireTarget;
      final identity = await ctx.link.probe(clean, expectedUid: t.deviceUuid);
      if (!identity.onHomeNetwork) {
        throw const SetupProblemException(SetupProblem(
          kind: SetupProblemKind.deviceRejected,
          title: 'Pano ev Wi-Fi ağına bağlı görünmüyor',
          why: 'Panoya ulaşıldı ama ev Wi-Fi ağına bağlı olduğunu bildirmiyor.',
          todo: 'Ev Wi-Fi bilgisini yeniden gönderin.',
        ));
      }
      ctx.target = t.copyWith(ip: clean);
      _identity = identity;
      _connected = true;
      _viaEthernet = !identity.wifiConnected && identity.ethConnected == true;
      _lostContact = false;
      _homeIp = clean;
    });
  }

  /// Ethernet yolu: pano ev ağına kabloyla bağlı. Panonun Ethernet IP'sinden kimlik doğrulanır (kablolu ağdan gelen
  /// istek panoda anahtarsız yetkilidir; CONTRACTS §3e) ve `eth_connected` bilgisine bakılır. Yanıt Ethernet alanlarını
  /// taşımıyorsa (anahtarsız özet) bellekteki anahtarla tam durum okunur. Kurulum ağı ve internet gerekmez.
  Future<bool> confirmEthernet(String ip) {
    final error = validateHost(ip);
    if (error != null) {
      fail(SetupProblem(
        kind: SetupProblemKind.validation,
        title: 'Pano adresi geçersiz',
        why: error,
        todo: 'Modem arayüzündeki cihaz listesinden panonun kablolu (Ethernet) IP adresine bakın.',
        retryable: false,
      ));
      return Future<bool>.value(false);
    }
    return run(ethLabel, () async {
      final clean = ip.trim();
      final t = ctx.requireTarget;
      final identity = await ctx.link.probe(clean, expectedUid: t.deviceUuid);
      if (identity.provisioned == false) {
        // Ethernet'ten anahtarsız erişim provizyonsuz panoda da çalışır (karar 1) ama pano bu haliyle buluta bağlanamaz:
        // adım tamamlanmaz, ilk hazırlık istenir (servis_kurulum-1).
        _identity = identity;
        _needsProvision = true;
        _ethProvisionIp = clean;
        throw const SetupProblemException(SetupProblem(
          kind: SetupProblemKind.deviceRejected,
          title: 'Pano hazırlanmamış (cihaz anahtarı yok)',
          why: 'Pano Ethernet ile ev ağında ama ilk hazırlığı (cihaz anahtarı) yapılmamış; bu haliyle buluta bağlanamaz.',
          todo: "Etiketteki AP parolasını girip Panoyu Hazırla'ya basın.",
          retryable: false,
        ));
      }
      var eth = identity.ethConnected;
      if (eth == null) {
        final key = t.localKey ?? ctx.link.key;
        if (key != null && key.isNotEmpty) {
          try {
            ctx.link.useKey(key);
            final status = await ctx.link.verifiedApi.fetchStatus();
            eth = status.onEthernet;
          } on LocalApiException catch (e) {
            if (e.isNetwork) rethrow;
            ctx.link.invalidate();
          }
        }
      }
      ctx.ensureActive();
      if (eth != true) {
        throw const SetupProblemException(SetupProblem(
          kind: SetupProblemKind.deviceRejected,
          title: 'Pano Ethernet bağlantısı bildirmiyor',
          why: 'Panoya bu adresten ulaşıldı ama kablolu (Ethernet) ağa bağlı olduğunu bildirmiyor. Pano yazılımı '
              'v1.3.0\'dan eskiyse Ethernet desteklenmez.',
          todo: 'Ethernet kablosunu ve modemdeki ışığı kontrol edin; adresin panonun kablolu IP\'si olduğundan emin olun. '
              'Olmazsa Wi-Fi ile kurun ("Pano kabloyla bağlı" seçimini kapatın).',
        ));
      }
      ctx.target = ctx.requireTarget.copyWith(ip: clean);
      _identity = identity;
      _connected = true;
      _viaEthernet = true;
      _lostContact = false;
      _homeIp = clean;
      ctx.link.invalidate();
    });
  }

  /// 6-9. adımlarda pano ev ağındaki IP'sinden kimlik + anahtarla doğrulandı: pano ev ağına bağlıdır.
  void markConnectedOnLan(String ip) {
    if (_connected) return;
    _connected = true;
    _lostContact = false;
    _homeIp = ip;
    ctx.notify();
    ctx.persist();
  }

  @override
  void dispose() {
    _apApi?.dispose();
    _apApi = null;
  }

  @override
  Map<String, dynamic> snapshot() => <String, dynamic>{
        'connected': _connected,
        'lost': _lostContact,
        if (_viaEthernet) 'eth': true,
      };

  @override
  void restore(Map<String, dynamic> json) {
    _connected = json['connected'] == true;
    _lostContact = !_connected && json['lost'] == true;
    _viaEthernet = _connected && json['eth'] == true;
    _ethernetMode = _viaEthernet;
  }
}
