import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../config/app_config.dart';
import 'clock.dart';

/// Pano kurulum ağına (SoftAP) süreç bağlama (Android).
///
/// **Sorun:** panonun kurulum/kurtarma Wi-Fi ağı (`AHBU-<MAC son 6>`, adres `192.168.4.1`) İNTERNETSİZDİR.
/// Android bu ağı "doğrulanmamış" sayar ve **mobil veri açıksa** uygulamaların varsayılan ağını hücresele
/// çevirir: uygulamanın `192.168.4.1` adresine attığı HTTP istekleri hücreselden çıkar ve başarısız olur.
///
/// **Çözüm (bu dosya + Android yerel kodu):** yalnız pano kurulum ağıyla konuşulan SÜRELERDE uygulama sürecini
/// Wi-Fi ağına bağlamak (`ConnectivityManager.requestNetwork` + `bindProcessToNetwork`), iş bitince (ya da
/// ağ kaybolunca) çözmek. Süreç bağlıyken uygulamanın bulut istekleri de Wi-Fi'den çıkar (internetsiz): bu
/// yüzden bağlama yalnız AP çağrılarının etrafındadır ([AutomationApiService] sarmalayıcısı) ve kısadır.
///
/// **Kanal sözleşmesi** (`ev_otomasyon/board_network`, StandardMethodCodec). Yerel taraf `BoardNetworkPlugin.kt`
/// (+ `BoardNetworkBinder.kt`, `BoardNetworkCore.kt`, `Ipv4Subnet.kt`); `MainActivity.configureFlutterEngine` yalnız
/// eklentiyi KAYDEDER:
///
/// | Yön | Çağrı | Yanıt |
/// |---|---|---|
/// | Dart -> yerel | `acquire {subnet: "192.168.4.0/24", timeoutMs: 5000}` (Dart HER ZAMAN [BoardNetworkBinding.defaultTimeout]'u gönderir; yerel varsayılan 8000) | `{status, detail?}` |
/// | Dart -> yerel | `release` | `{status: "released" \| "not_bound"}` |
/// | Dart -> yerel | `status` | `{bound: bool, sdk: int}` (bu dosya çağırmaz) |
/// | yerel -> Dart | `networkLost` | (yok; yerel taraf ÖNCE kendisi çözer, sonra bildirir) |
///
/// `acquire` durumları: `bound`, `already_bound` (süreç, bağlantı adresleri alt ağda olan Wi-Fi'ye bağlandı),
/// `not_on_board_network`, `no_wifi`, `timeout`, `permission_denied`, `unsupported`, `error` (süreç varsayılan
/// ağı DEĞİŞMEDİ). Yerel taraf TEK bağlamayı tutar; `acquire` idempotenttir; `release` her zaman güvenlidir.
///
/// **Süre bütçesi:** yerel taraf `timeout` ÜRETMEZ: işletim sistemi zaman aşımı ve "bağlı Wi-Fi yok" `no_wifi`
/// olarak gelir; ağ görüldükten sonra adres alt ağa uymazsa 3 sn'lik GRACE sonunda `not_on_board_network` gelir.
/// Yani yerel yanıt EN GEÇ `timeoutMs + 3 sn` sonra gelir; Dart üst sınırı ([AndroidBoardNetworkBinding.nativeGrace],
/// varsayılan 4 sn) bunun ÜSTÜNDEDİR. `timeout` durumu yalnız Dart üst sınırı dolunca (`dart_timeout`) üretilir.
///
/// **`detail`** yalnız tanı amaçlıdır (kullanıcıya gösterilmez; SSID/IP/parola İÇERMEZ). Bilinenler:
/// `other_subnet`, `no_ipv4_address`, `bind_returned_false`, `no_wifi_network`, `no_wifi_hardware`, `released`,
/// `other_subnet_pending`, `invalid_subnet`, `engine_detached`, `bind_denied` (ağ canlıyken işletim sistemi süreç
/// bağlamasını reddetti: tipik neden VPN; ipucu [BoardNetworkLease.bindDeniedHint]), `request_failed:<Sınıf>`,
/// `bind_failed:<Sınıf>`, `exception:<Sınıf>`; Dart tarafı üretirse: `dart_timeout`, `no_plugin`, `bad_response`,
/// `native_failure`, `disposed`.
///
/// **Kullanıcı gizliliği:** hiçbir yerde SSID, parola ya da anahtar taşınmaz/loglanmaz (yalnız alt ağ + durum).
/// Hata ayıklama günlüğü (yalnız hata ayıklama derlemesi) yalnız durum/ayrıntı belirteçlerini yazar.
enum BoardNetworkStatus {
  /// Süreç pano ağına bağlandı.
  bound('bound'),

  /// Süreç zaten pano ağına bağlıydı.
  alreadyBound('already_bound'),

  /// Telefon bir Wi-Fi'de ama pano kurulum ağında değil (bağlantı adresleri alt ağda değil).
  notOnBoardNetwork('not_on_board_network'),

  /// Telefonun bağlı bir Wi-Fi ağı yok.
  noWifi('no_wifi'),

  /// Dart tarafı üst sınırı dolana kadar yerel yanıt gelmedi (`dart_timeout`). Yerel taraf bu durumu ÜRETMEZ:
  /// işletim sistemi zaman aşımı ve "bağlı Wi-Fi yok" `no_wifi` olarak gelir.
  timeout('timeout'),

  /// Sistem ağ yönlendirme izni vermedi.
  permissionDenied('permission_denied'),

  /// Platform desteklemiyor (Android dışı, eski sürüm, yerel kod yok).
  unsupported('unsupported'),

  /// Beklenmeyen yerel hata.
  error('error');

  const BoardNetworkStatus(this.wire);

  /// Kanaldaki metin karşılığı.
  final String wire;

  /// Kanal metninden durum (bilinmeyen/bozuk değer [error]).
  static BoardNetworkStatus parse(Object? raw) {
    if (raw is String) {
      for (final value in values) {
        if (value.wire == raw) return value;
      }
    }
    return BoardNetworkStatus.error;
  }

  /// Süreç şu an pano ağına bağlı mı (sonuç olarak).
  bool get isBound => this == bound || this == alreadyBound;

  /// Bu durumda ağ hatasına eklenen Türkçe ipucu (yok: `null`). Ham teknik hata metni içermez.
  String? get hint {
    switch (this) {
      case BoardNetworkStatus.notOnBoardNetwork:
      case BoardNetworkStatus.noWifi:
        return 'Telefon pano kurulum ağına (AHBU-…) bağlı görünmüyor: Wi-Fi ayarlarından panonun ağına bağlanın.';
      case BoardNetworkStatus.timeout:
      case BoardNetworkStatus.error:
        return 'Pano ağına yönlenme kurulamadı: mobil veriyi kapatıp yeniden deneyin.';
      case BoardNetworkStatus.permissionDenied:
        return 'Telefon uygulamanın pano ağına yönlenmesine izin vermedi: mobil veriyi kapatıp yeniden deneyin.';
      case BoardNetworkStatus.bound:
      case BoardNetworkStatus.alreadyBound:
      case BoardNetworkStatus.unsupported:
        return null;
    }
  }
}

/// Bağlama hedefi: pano kurulum ağı adresi. **Yalnız** bu adrese bağlanılır:
///
/// * ham IPv4 (yazılı biçim kurallı: `192.168.4.1`; ondalık sekizli sayılar, baştaki sıfır yok),
/// * `192.168.0.0/16` içinde,
/// * ve yapılandırılmış kurulum ağı adresi ([AppConfig.deviceApHost], varsayılan `192.168.4.1`) ile AYNI.
///
/// Emülatör/QA adresleri (`10.0.2.2`, `127.0.0.1`, `localhost`), `*.local` ve **LAN doğrudan mod** (ev ağındaki
/// cihaz IP'si; internetli Wi-Fi) için hedef YOKTUR: süreç varsayılan ağı doğru kalır (bu adreslere bağlamak
/// internetli bir ağda gereksiz ve zararlıdır).
@immutable
class BoardNetworkTarget {
  const BoardNetworkTarget._(this.host, this.subnet);

  /// Ana makine (`192.168.4.1`).
  final String host;

  /// Ana makinenin /24 alt ağı (`192.168.4.0/24`): yerel tarafa `subnet` olarak gider.
  final String subnet;

  /// [host] pano kurulum ağı adresiyse hedef, değilse `null`. [apHost] verilmezse `AppConfig.current.deviceApHost`.
  static BoardNetworkTarget? tryParse(String? host, {String? apHost}) {
    final octets = _ipv4(host);
    if (octets == null || octets[0] != 192 || octets[1] != 168) return null;
    final ap = _ipv4(_hostOf(apHost ?? AppConfig.current.deviceApHost));
    if (ap == null || !listEquals(ap, octets)) return null;
    return BoardNetworkTarget._(octets.join('.'), '${octets[0]}.${octets[1]}.${octets[2]}.0/24');
  }

  /// `http://host[:port]` adresinin ana makinesi için [tryParse].
  static BoardNetworkTarget? forBaseUrl(String baseUrl, {String? apHost}) {
    if (baseUrl.isEmpty) return null;
    return tryParse(Uri.tryParse(baseUrl)?.host, apHost: apHost);
  }

  static final RegExp _ipv4Pattern = RegExp(
    r'^(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})$',
  );

  static List<int>? _ipv4(String? text) {
    if (text == null) return null;
    final match = _ipv4Pattern.firstMatch(text.trim());
    if (match == null) return null;
    final octets = <int>[for (var i = 1; i <= 4; i++) int.parse(match.group(i)!)];
    return octets.every((o) => o <= 255) ? octets : null;
  }

  /// `host` ya da `host:port` -> ana makine.
  static String? _hostOf(String hostPort) => Uri.tryParse('http://${hostPort.trim()}')?.host;

  @override
  String toString() => 'BoardNetworkTarget($host, $subnet)';
}

/// [BoardNetworkBinding.acquire] sonucu: "pano ağına bağlama kirası". İş bitince [release] edilir (idempotent).
///
/// Kira sayaçlıdır: yerel bağlama, son kira bırakılana kadar korunur. Bağlama **başarısız** olduysa kira yine
/// de verilir ([status] açıklar; [isBound] `false`): çağıran en-iyi-çabayla devam eder (davranış, bağlama
/// olmayan sürümden kötü olmaz) ve ağ hatasına [failureHint] ekleyebilir.
class BoardNetworkLease {
  BoardNetworkLease({
    required this.status,
    this.detail,
    this._onRelease,
    this._isActive,
  });

  /// Bırakılacak bir kaynağı olmayan kira (başarısız/desteklenmeyen sonuç).
  BoardNetworkLease.unbound(this.status, {this.detail})
      : _onRelease = null,
        _isActive = null;

  /// Bağlama sonucu.
  final BoardNetworkStatus status;

  /// Yerel taraftan gelen kısa teknik not (yalnız tanı amaçlı; kullanıcıya gösterilmez).
  final String? detail;

  final Future<void> Function()? _onRelease;
  final bool Function()? _isActive;
  Future<void>? _releasing;

  /// [release] çağrıldı mı.
  bool get isReleased => _releasing != null;

  /// Süreç şu an pano ağına bağlı mı: bağlama kurulmuş, kira bırakılmamış ve ağ kaybolmamış.
  bool get isBound => !isReleased && status.isBound && (_isActive?.call() ?? true);

  /// Bağlama kurulmuştu ama ağ sonradan kayboldu (yerel `networkLost`) ya da bağlama yenilendi.
  bool get isLost => !isReleased && status.isBound && !(_isActive?.call() ?? true);

  /// Yerel `error` durumunun `detail` değeri: ağ canlıyken işletim sistemi süreç bağlamasını REDDETTİ (tipik
  /// neden: atlanamaz bir VPN etkin). Bkz. [bindDeniedHint].
  static const String bindDeniedDetail = 'bind_denied';

  /// [bindDeniedDetail] için ağ hatasına eklenen ipucu (bağlama reddedilince "pano ağında değilsiniz" demek yanlış olur).
  static const String bindDeniedHint =
      'Pano ağına yönlenme reddedildi: telefonda VPN (özel ağ) açıksa kapatıp yeniden deneyin.';

  /// Ağ hatasına eklenecek ipucu: bağlama başarısızsa durumun ipucu ([bindDeniedDetail] için VPN ipucu), bağlama
  /// kaybolduysa "ağda değil" ipucu, başarılı/desteklenmiyorsa `null`.
  String? get failureHint {
    if (isLost) return BoardNetworkStatus.notOnBoardNetwork.hint;
    if (status == BoardNetworkStatus.error && detail == bindDeniedDetail) return bindDeniedHint;
    return status.hint;
  }

  /// Kirayı bırakır (idempotent; hata FIRLATMAZ). Son kira bırakılınca yerel bağlama çözülür: varsayılan olarak HEMEN
  /// ve bu Future yerel `release`'in yanıtından sonra tamamlanır ([AndroidBoardNetworkBinding.linger] > 0 verilmişse
  /// o kadar beklenir).
  Future<void> release() => _releasing ??= _doRelease();

  Future<void> _doRelease() async {
    try {
      await _onRelease?.call();
    } catch (_) {
      // Bırakma her zaman güvenli: yerel hata uygulamayı etkilemez.
    }
  }

  @override
  String toString() => 'BoardNetworkLease($status${isReleased ? ', released' : ''})';
}

/// Uygulama sürecini pano kurulum ağına bağlayan hizmet (platforma göre [instance]).
abstract class BoardNetworkBinding {
  const BoardNetworkBinding();

  /// Yerel `acquire` çağrısına verilen varsayılan bekleme (`timeoutMs`). Yerel taraf en geç bunun 3 sn (GRACE)
  /// sonrasına kadar yanıt verir; Dart üst sınırı ([AndroidBoardNetworkBinding.nativeGrace]) bunu kapsar.
  static const Duration defaultTimeout = Duration(seconds: 5);

  /// Hata/yönerge metninde kullanılan yedek cümle: bağlantı kurulamazsa mobil veriyi kapatıp yeniden deneyin.
  static const String mobileDataFallback = 'Bağlantı kurulamazsa mobil veriyi kapatıp yeniden deneyin.';

  /// Android'de kullanıcıya gösterilen ÖN BİLGİ yönergesi: mobil veri açık kalabilir. Bir HATA metninde bunu
  /// kullanmayın ("açık kalabilir" demek, az önce başarısız olmuş bağlantının yanında çelişir): orada
  /// [mobileDataFallback] yeter.
  static const String mobileDataAdvice =
      'Mobil veri açık kalabilir; uygulama pano ağını otomatik kullanır. $mobileDataFallback';

  static BoardNetworkBinding? _override;
  static BoardNetworkBinding? _platformDefault;

  /// Etkin bağlama: testlerde [overrideForTesting] ile verilen, yoksa platformun varsayılanı
  /// ([createForPlatform]: Android `AndroidBoardNetworkBinding`, diğer her yer `NoopBoardNetworkBinding`).
  static BoardNetworkBinding get instance => _override ?? (_platformDefault ??= createForPlatform());

  /// Yalnızca testlerde: etkin bağlamayı değiştirir. `null` verilirse platform varsayılanına dönülür
  /// (test sonunda `overrideForTesting(null)` ile geri alın).
  @visibleForTesting
  static void overrideForTesting(BoardNetworkBinding? binding) => _override = binding;

  /// Platforma göre bağlama: yalnız `!kIsWeb && Platform.isAndroid` iken [AndroidBoardNetworkBinding],
  /// diğer her yerde (iOS, masaüstü, web) [NoopBoardNetworkBinding] (HİÇBİR kanal çağrısı yapılmaz).
  /// [isAndroid] yalnızca testlerde platformu taklit etmek içindir.
  static BoardNetworkBinding createForPlatform({bool? isAndroid}) {
    final android = isAndroid ?? (!kIsWeb && Platform.isAndroid);
    return android ? AndroidBoardNetworkBinding() : const NoopBoardNetworkBinding();
  }

  /// Platform pano ağına otomatik yönlenmeyi destekliyor mu (arayüz yönergeleri bunu kullanır).
  bool get isSupported;

  /// [host] pano kurulum ağı adresiyse süreci o Wi-Fi ağına bağlar ve bir kira döner. **Asla fırlatmaz**:
  /// başarısızlık [BoardNetworkLease.status] ile bildirilir. [host] pano ağı adresi değilse (LAN, emülatör...)
  /// bağlama yapılmaz (`unsupported` kira, yerel çağrı yok).
  Future<BoardNetworkLease> acquire({required String host, Duration timeout = defaultTimeout});

  /// Kaynakları (zamanlayıcı, kanal dinleyicisi) bırakır; açık bağlama varsa en iyi çabayla çözülür.
  void dispose();
}

/// Android dışı her yerde (iOS, masaüstü, web): bağlama yoktur; HİÇBİR kanal çağrısı yapılmaz.
class NoopBoardNetworkBinding extends BoardNetworkBinding {
  const NoopBoardNetworkBinding();

  @override
  bool get isSupported => false;

  @override
  Future<BoardNetworkLease> acquire({required String host, Duration timeout = BoardNetworkBinding.defaultTimeout}) =>
      Future<BoardNetworkLease>.value(BoardNetworkLease.unbound(BoardNetworkStatus.unsupported));

  @override
  void dispose() {}
}

/// Android: `ev_otomasyon/board_network` kanalı üzerinden yerel taraf ile konuşur (sözleşme: [BoardNetworkStatus]).
///
/// **Kira sayaçlıdır:** ilk kira yerel `acquire`'ı BİR kez çağırır; eşzamanlı `acquire`'lar aynı sonucu paylaşır;
/// bağlama son kira bırakılana kadar korunur. Son kira bırakılınca (varsayılan: HEMEN, [linger] = sıfır) yerel
/// `release` çağrılır VE bırakma Future'ı bu çağrının yanıtından sonra tamamlanır: çağrı dönünce süreç artık pano
/// ağına bağlı değildir. (Bekleme/linger KAPALI tutulur: bekleme açıkken bırakma hemen dönerdi ve ardından
/// başlayan bir bulut isteği — ör. yerel anahtarı sunucudan yenileme — hâlâ internetsiz pano ağından çıkardı.)
/// [linger] > 0 verilirse son kira bırakılınca o kadar beklenir; bekleme sırasında yeni `acquire` gelirse bekleme
/// iptal edilir ve mevcut bağlama kullanılır (bağlama/çözme çalkantısı olmaz).
/// Yerel `networkLost` olayı gelince Dart durumu sıfırlanır, açık kiralar pasifleşir ([BoardNetworkLease.isBound]
/// `false`; bırakmaları yine güvenli), sonraki `acquire` yeniden bağlar.
///
/// **Hata/zaman aşımı:** yerel hata, [MissingPluginException] (yerel kod yok) ve takılı yerel çağrı istisna
/// FIRLATMAZ; durum `error`/`unsupported`/`timeout` olur. Dart tarafı da her yerel çağrıya üst sınır koyar
/// (`acquire` için `timeout + nativeGrace`): takılı yerel çağrı uygulamayı kilitlemez. Yerel taraf `unsupported`
/// derse ya da yerel eklenti yoksa özellik KALICI kapanır ([isSupported] `false`; arayüz eski yönergeye döner).
///
/// Zamanlayıcılar enjekte edilen [Clock] ile kurulur (testlerde sahte saat) ve [dispose] hepsini temizler.
/// Hata ayıklama derlemesinde durum/ayrıntı belirteçleri (SSID/IP/anahtar ASLA) `debugPrint` ile yazılır
/// (`adb logcat -s BoardNetwork flutter`); kurucudaki `log` parametresiyle yönlendirilebilir.
class AndroidBoardNetworkBinding extends BoardNetworkBinding {
  AndroidBoardNetworkBinding({
    this.linger = Duration.zero,
    this.nativeGrace = defaultNativeGrace,
    this._clock = const SystemClock(),
    this._channel = const MethodChannel(channelName),
    this._log = _debugLog,
  });

  /// Kanal adı (yerel taraf birebir aynısını kaydeder).
  static const String channelName = 'ev_otomasyon/board_network';

  /// Yerel `acquire` en geç `timeoutMs + 3 sn` (yerel GRACE) sonra yanıt verir: ağ en son saniyede görülürse ve adresi
  /// alt ağa uymazsa karar 3 sn sonra gelir. Dart üst sınırı bunun ÜSTÜNDE olmalıdır; yoksa geç ama DOĞRU bir yerel
  /// sonuç (`not_on_board_network`) yanlışlıkla `timeout` olur (ve yanlış ipucu: "mobil veriyi kapatın"). 3 sn + 1 sn pay.
  /// Aynı süre yerel `release` çağrısının Dart üst sınırıdır.
  static const Duration defaultNativeGrace = Duration(seconds: 4);

  /// Son kira bırakıldıktan sonra yerel `release` öncesi bekleme. Varsayılan `Duration.zero` = hemen (bkz. sınıf belgesi).
  final Duration linger;

  /// Yerel çağrıya verilen sürenin üstüne eklenen pay (Dart tarafı üst sınırı); bkz. [defaultNativeGrace].
  final Duration nativeGrace;

  final Clock _clock;
  final MethodChannel _channel;
  final void Function(String message) _log;

  /// Hata ayıklama günlüğü: yalnız hata ayıklama derlemesinde yazar (release'te hiçbir şey). YALNIZ durum ve ayrıntı
  /// belirteçleri yazılır; SSID, IP, alt ağ, anahtar ve parola ASLA.
  static void _debugLog(String message) {
    if (kDebugMode) debugPrint('[BoardNetwork/Dart] $message');
  }

  _Session? _current;
  final Set<_NativeCall> _inflight = <_NativeCall>{};
  bool _handlerInstalled = false;
  bool _unsupported = false;
  bool _disposed = false;

  static const String _noPlugin = 'no_plugin';
  static const String _unsupportedDetail = 'unsupported';
  static const _Outcome _disposedOutcome = _Outcome(BoardNetworkStatus.unsupported, 'disposed');

  /// Android'de `true`; ama yerel eklenti yoksa / yerel taraf `unsupported` derse (kalıcı) ya da [dispose] sonrası `false`.
  /// Arayüz yönergeleri ve [AutomationApiService] sarmalayıcısı buna bakar: özellik çalışmıyorsa "mobil veri açık
  /// kalabilir" denmez, eski yönerge gösterilir ve pano çağrıları gereksiz kira açmaz.
  @override
  bool get isSupported => !_unsupported && !_disposed;

  @override
  Future<BoardNetworkLease> acquire({required String host, Duration timeout = BoardNetworkBinding.defaultTimeout}) async {
    final target = BoardNetworkTarget.tryParse(host);
    if (target == null) {
      // Savunma: pano ağı olmayan adres için ASLA yerel bağlama yapılmaz (çağıran korumasından bağımsız).
      return BoardNetworkLease.unbound(BoardNetworkStatus.unsupported, detail: 'not_board_network_host');
    }
    if (_disposed) return BoardNetworkLease.unbound(BoardNetworkStatus.unsupported, detail: 'disposed');
    if (_unsupported) return BoardNetworkLease.unbound(BoardNetworkStatus.unsupported, detail: _unsupportedDetail);

    _installHandler();
    // Eşzamanlı çağrılar için burası tamamen EŞZAMANLI çalışır: oturum açılır/katılınır ve kira sayacı artar.
    final session = _joinable(target.subnet) ?? _open(target.subnet, timeout);
    session.leases++;
    session.lingerTimer?.cancel();
    session.lingerTimer = null;

    final outcome = await session.result;
    return BoardNetworkLease(
      status: outcome.status,
      detail: outcome.detail,
      onRelease: () => _release(session),
      isActive: () => _isActive(session),
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final session = _current;
    _current = null;
    session?.lingerTimer?.cancel();
    session?.lingerTimer = null;
    session?.superseded = true;
    for (final call in List<_NativeCall>.of(_inflight)) {
      _settle(call, error: StateError('disposed'));
    }
    // Kanal bu örnekçe kullanıldıysa (işleyici kuruldu) yerel tarafta bağlama ya da yanıtı beklenen `acquire` kalmış
    // olabilir (ör. alt ağ değişimi ya da acquire sürerken dispose): en iyi çabayla çöz. `release` her zaman güvenli
    // ve idempotenttir (zamanlayıcısız; yanıt beklenmez).
    final mayHaveNativeState = _handlerInstalled && !_unsupported;
    if (_handlerInstalled) {
      _handlerInstalled = false;
      _channel.setMethodCallHandler(null);
    }
    if (mayHaveNativeState) {
      try {
        unawaited(_channel.invokeMethod<Object?>('release').then<void>((_) {}, onError: (Object _) {}));
      } catch (_) {
        // dispose asla fırlatmaz (kanalın kendisi eşzamanlı fırlatsa bile).
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Oturum (tek yerel bağlama) yönetimi
  // ---------------------------------------------------------------------------

  bool _isActive(_Session s) => !_disposed && !s.lost && !s.superseded;

  /// Aynı alt ağ için paylaşılabilir oturum: yerel `acquire` sürüyorsa ya da bağlı ve sağlamsa. Sonuçlanmış
  /// BAŞARISIZ oturum paylaşılmaz (başarısızlık yapışkan değil: yeni `acquire` yeniden dener).
  _Session? _joinable(String subnet) {
    final s = _current;
    if (s == null || s.subnet != subnet || s.lost || s.superseded) return null;
    if (!s.settled) return s;
    return s.status.isBound ? s : null;
  }

  _Session _open(String subnet, Duration timeout) {
    final previous = _current;
    final session = _Session(subnet);
    _current = session;
    if (previous != null) {
      previous.superseded = true;
      previous.lingerTimer?.cancel();
      previous.lingerTimer = null;
    }
    session.result = _run(session, previous, timeout);
    return session;
  }

  Future<_Outcome> _run(_Session session, _Session? previous, Duration timeout) async {
    if (previous != null) {
      // Yerel taraf TEK bağlama tutar: önceki (başka alt ağ / başarısız) oturumun bağlaması çözülmeden yenisi kurulmaz.
      final before = await previous.result;
      // Her await'ten sonra: dispose araya girdiyse YENİ yerel çağrı (acquire) yapılmaz ve zamanlayıcı kurulmaz
      // (yoksa yerel taraf bağlayıp Dart onu hiç çözmezdi: dispose sonrası release/networkLost duyulmaz).
      if (_disposed) return _disposedOutcome;
      if (before.status.isBound && !previous.lost) {
        await _callQuietly('release');
        if (_disposed) return _disposedOutcome;
      }
    }
    final outcome = await _nativeAcquire(session.subnet, timeout);
    session.status = outcome.status;
    session.settled = true;
    _log('acquire -> ${outcome.status.wire} (${outcome.detail ?? '-'})');
    // Yerel kod yok ya da yerel taraf "unsupported" dedi (ör. eski Android): kalıcı; kanal bir daha çağrılmaz.
    if (outcome.status == BoardNetworkStatus.unsupported) {
      _unsupported = true;
      if (outcome.detail == _noPlugin) {
        _log('yerel eklenti kayıtlı değil: pano ağına yönlenme KAPALI (MainActivity.configureFlutterEngine kaydını denetleyin)');
      }
    }
    return outcome;
  }

  Future<void> _release(_Session s) async {
    if (s.leases > 0) s.leases--;
    if (s.leases > 0 || !identical(_current, s) || _disposed) return;
    if (linger <= Duration.zero) {
      await _finish(s);
      return;
    }
    s.lingerTimer?.cancel();
    s.lingerTimer = _clock.timer(linger, () {
      s.lingerTimer = null;
      unawaited(_finish(s));
    });
  }

  Future<void> _finish(_Session s) async {
    if (s.leases > 0 || !identical(_current, s) || _disposed) return;
    _current = null;
    if (_unsupported) return;
    await _callQuietly('release');
  }

  void _installHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler(_onNativeCall);
  }

  Future<Object?> _onNativeCall(MethodCall call) async {
    if (call.method == 'networkLost') _onNetworkLost();
    return null;
  }

  /// Yerel taraf bağlanan ağın kaybolduğunu bildirdi (ÖNCE kendisi çözdü): Dart durumu sıfırlanır, açık kiralar
  /// pasifleşir; bu oturumun kiraları bırakılınca yerel `release` ÇAĞRILMAZ (yerel taraf zaten çözdü).
  void _onNetworkLost() {
    final s = _current;
    if (s == null || !s.settled || !s.status.isBound) {
      _log('networkLost: bağlı oturum yok; yok sayıldı');
      return;
    }
    _log('networkLost: yerel taraf bağlamayı çözdü; kiralar pasifleşti');
    s.lost = true;
    s.lingerTimer?.cancel();
    s.lingerTimer = null;
    _current = null;
  }

  // ---------------------------------------------------------------------------
  // Yerel çağrılar (üst sınırlı, istisnasız)
  // ---------------------------------------------------------------------------

  Future<_Outcome> _nativeAcquire(String subnet, Duration timeout) async {
    try {
      final raw = await _invoke(
        'acquire',
        <String, Object?>{'subnet': subnet, 'timeoutMs': timeout.inMilliseconds},
        timeout + nativeGrace,
      );
      if (raw is Map) {
        final detail = raw['detail'];
        return _Outcome(BoardNetworkStatus.parse(raw['status']), detail is String ? detail : null);
      }
      return const _Outcome(BoardNetworkStatus.error, 'bad_response');
    } on MissingPluginException {
      return const _Outcome(BoardNetworkStatus.unsupported, _noPlugin);
    } on TimeoutException {
      return const _Outcome(BoardNetworkStatus.timeout, 'dart_timeout');
    } on PlatformException catch (e) {
      final code = e.code.toLowerCase();
      final denied = code.contains('permission') || code.contains('security');
      return _Outcome(denied ? BoardNetworkStatus.permissionDenied : BoardNetworkStatus.error, e.code);
    } catch (e) {
      // Yutulan istisna: yalnız TÜRÜ günlüğe yazılır (ileti metni değil).
      _log('acquire: beklenmeyen hata (${e.runtimeType})');
      return const _Outcome(BoardNetworkStatus.error, 'native_failure');
    }
  }

  Future<void> _callQuietly(String method) async {
    try {
      await _invoke(method, null, nativeGrace);
      _log('$method -> tamam');
    } catch (e) {
      // Bırakma her zaman güvenli: hata/zaman aşımı uygulamayı etkilemez (yalnız tür günlüğe yazılır).
      _log('$method: yutulan hata (${e.runtimeType})');
    }
  }

  /// Yerel çağrı + Dart tarafı üst sınırı ([limit]; enjekte saatle). Üst sınır dolarsa [TimeoutException].
  /// [dispose] sonrasında YENİ yerel çağrı yapılmaz (hemen `StateError('disposed')`).
  Future<Object?> _invoke(String method, Object? arguments, Duration limit) {
    if (_disposed) return Future<Object?>.error(StateError('disposed'));
    final call = _NativeCall();
    _inflight.add(call);
    call.timer = _clock.timer(limit, () => _settle(call, error: TimeoutException('yerel çağrı zaman aşımı', limit)));
    try {
      _channel.invokeMethod<Object?>(method, arguments).then<void>(
            (value) => _settle(call, value: value),
            onError: (Object error, StackTrace stack) => _settle(call, error: error, stack: stack),
          );
    } catch (error, stack) {
      _settle(call, error: error, stack: stack);
    }
    return call.completer.future;
  }

  void _settle(_NativeCall call, {Object? value, Object? error, StackTrace? stack}) {
    if (call.completer.isCompleted) return;
    call.timer?.cancel();
    call.timer = null;
    _inflight.remove(call);
    if (error != null) {
      call.completer.completeError(error, stack);
    } else {
      call.completer.complete(value);
    }
  }
}

/// Tek yerel bağlama oturumu (Dart'ın bildiği kadarıyla).
class _Session {
  _Session(this.subnet);

  final String subnet;

  /// Yerel `acquire` sonucu (oturum açılırken atanır; tüm katılanlar bunu bekler).
  late final Future<_Outcome> result;

  /// Açık kira sayısı.
  int leases = 0;

  /// Yerel `acquire` sonuçlandı mı ve sonucu.
  bool settled = false;
  BoardNetworkStatus status = BoardNetworkStatus.error;

  /// Yerel `networkLost` geldi (yerel taraf zaten çözdü).
  bool lost = false;

  /// Yerini yeni bir oturum aldı (kiraları pasif; bırakmaları yerel çağrı yapmaz).
  bool superseded = false;

  Timer? lingerTimer;
}

class _Outcome {
  const _Outcome(this.status, this.detail);

  final BoardNetworkStatus status;
  final String? detail;
}

class _NativeCall {
  final Completer<Object?> completer = Completer<Object?>();
  Timer? timer;
}

/// Yalnızca testler için: yerel taraf olmadan [BoardNetworkBinding] sözleşmesini taklit eder ve KAYIT tutar
/// (çağrı sırası, açık kira sayısı); durum zorlanabilir.
///
/// [events] listesi test tarafından başka olaylarla (örn. sahte HTTP isteği) paylaşılabilir; böylece
/// "kira ÖNCE alındı, istek SONRA, bırakma EN SON" sırası tek listede doğrulanır.
@visibleForTesting
class FakeBoardNetworkBinding extends BoardNetworkBinding {
  FakeBoardNetworkBinding({
    this.status = BoardNetworkStatus.bound,
    this.supported = true,
    List<String>? events,
  }) : events = events ?? <String>[];

  /// Sonraki `acquire` sonuçlarının durumu (durum zorlama). [script] doluysa önce o kullanılır.
  BoardNetworkStatus status;

  /// [isSupported] yanıtı.
  bool supported;

  /// Doluysa `acquire` bunu FIRLATIR (kötü davranan bağlama).
  Object? acquireError;

  /// Doluysa kira bırakma bunu FIRLATIR (kira bunu yutar; çağıranı etkilemez).
  Object? releaseError;

  /// Doluysa `acquire` bu tamamlanana kadar bekler (kira alma sürerken isteğin henüz yapılmadığını sınamak için).
  Completer<void>? acquireGate;

  /// Olay kaydı: `acquire:<host>` ve `release` (sırayla).
  final List<String> events;

  /// `acquire` çağrılarının ana makineleri ve bekleme süreleri.
  final List<String> hosts = <String>[];
  final List<Duration> timeouts = <Duration>[];

  int acquireCount = 0;
  int releaseCount = 0;
  bool disposed = false;

  final List<BoardNetworkStatus> _script = <BoardNetworkStatus>[];
  int _active = 0;
  int _epoch = 0;

  /// Şu an bırakılmamış kira sayısı.
  int get activeLeases => _active;

  /// Sonraki `acquire` çağrıları için sırayla kullanılacak durumlar (bitince [status]).
  void script(List<BoardNetworkStatus> statuses) => _script
    ..clear()
    ..addAll(statuses);

  /// Ağ kaybını taklit eder: o ana kadar verilmiş kiralar pasifleşir (bırakmaları güvenli kalır).
  void loseNetwork() => _epoch++;

  @override
  bool get isSupported => supported;

  @override
  Future<BoardNetworkLease> acquire({required String host, Duration timeout = BoardNetworkBinding.defaultTimeout}) async {
    acquireCount++;
    hosts.add(host);
    timeouts.add(timeout);
    events.add('acquire:$host');
    final gate = acquireGate;
    if (gate != null) await gate.future;
    final failure = acquireError;
    if (failure != null) throw failure;
    final result = _script.isEmpty ? status : _script.removeAt(0);
    _active++;
    final epoch = _epoch;
    return BoardNetworkLease(
      status: result,
      onRelease: () async {
        releaseCount++;
        _active--;
        events.add('release');
        final error = releaseError;
        if (error != null) throw error;
      },
      isActive: () => epoch == _epoch,
    );
  }

  @override
  void dispose() => disposed = true;
}
