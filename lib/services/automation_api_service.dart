import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode, kIsWeb;
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../models/api_models.dart';
import '../models/automation_models.dart';
import '../models/install_template_models.dart';
import '../models/json_utils.dart';
import 'board_network_binding.dart';
import 'clock.dart';

/// Hazırlanmamış (provizyonsuz) pano mesajı, servis rolü OLMAYAN kullanıcıya (bireysel-13): açamayacağı servis sihirbazına
/// yönlendirilmez; satıcı / yetkili servis ve ev sahibinin verebileceği servis PIN'i söylenir. Servis rolündeki kullanıcı
/// (personel, süper, servis PIN oturumu) sihirbaz yönlendirmesini görür.
const String kUnprovisionedBoardUserMessage =
    'Bu pano ilk hazırlığı (provizyon) görmemiş; bu haliyle buluta bağlanamaz. Satıcınıza / yetkili servise başvurun; '
    'ev sahibiyseniz servise Yetkili Servis İçin Geçici PIN verebilirsiniz (servis 5. adımda Panoyu Hazırla ile '
    'tamamlar).';

/// Cihazın yerel (LAN / AP) HTTP API hatası (CONTRACTS §3).
///
/// Gövde biçimi: `{"error":"unauthorized"}`, `{"error":"locked","retry_after":60}`,
/// `{"error":"unprovisioned"}`. [toString] yalnızca kullanıcıya gösterilebilir mesajı verir.
class LocalApiException implements Exception {
  const LocalApiException({
    required this.statusCode,
    required this.message,
    this.code,
    this.retryAfter,
    this.hint,
    this.path,
  });

  /// `0` = cihaza ulaşılamadı / zaman aşımı.
  final int statusCode;
  final String? code;
  final String message;
  final Duration? retryAfter;

  /// Ağ hatasına, panonun kurulum ağına yönlenme ([BoardNetworkBinding], Android) başarısız olduğu için eklenen
  /// Türkçe ipucu; [message] bunu zaten içerir. Yalnızca [isNetwork] hatalarında ve bağlama başarısızken dolar.
  final String? hint;

  /// Doğrulama hatasında sorunlu alanın yolu (`{"error":"invalid_runtime","path":"relays[3].runtime_s"}`; şablon
  /// uygulama, CONTRACTS §3e). Diğer uçlarda `null`.
  final String? path;

  factory LocalApiException.network([Object? cause]) => const LocalApiException(
        statusCode: 0,
        code: 'network',
        message: 'Cihaza ulaşılamadı. Aynı ağda olduğunuzdan ve adresin doğru olduğundan emin olun.',
      );

  factory LocalApiException.notConfigured() => const LocalApiException(
        statusCode: 0,
        code: 'not_configured',
        message: 'Cihaz adresi ayarlanmadı.',
      );

  factory LocalApiException.invalid(String message) =>
      LocalApiException(statusCode: 400, code: 'invalid', message: message);

  factory LocalApiException.cancelled() => const LocalApiException(
        statusCode: 0,
        code: 'cancelled',
        message: 'İşlem iptal edildi.',
      );

  bool get isNetwork => statusCode == 0 && code == 'network';

  /// Yanlış / eksik `X-Device-Key` (401).
  bool get isUnauthorized => statusCode == 401;

  /// Çok sayıda yanlış anahtar denemesi (423; [retryAfter] bekleme).
  bool get isLocked => statusCode == 423;

  /// Cihaz henüz kurulmamış (`local_key` yok): yalnızca fabrika kurulumu çalışır.
  bool get isUnprovisioned => statusCode == 403 && code == 'unprovisioned';

  /// `factory/init` reddedildi: cihaz zaten kurulmuş (anahtar tanımlı) (403 `already_provisioned`).
  bool get isAlreadyProvisioned => statusCode == 403 && code == 'already_provisioned';

  /// Cihaz meşgul: panjur hareketliyken yapılandırma ya da başka bir Wi-Fi denemesi sürerken
  /// (409 `busy`), iş kuyruğu dolu (503 `queue_full` / `busy`). Biraz bekleyip yeniden denenebilir.
  bool get isBusy =>
      (statusCode == 409 && code == 'busy') ||
      (statusCode == 503 && (code == 'busy' || code == 'queue_full'));

  /// İstek kaynağı / ana makine adı cihazın DNS-rebinding savunması tarafından reddedildi
  /// (400 `bad_host`, 403 `bad_origin`).
  bool get isHostRejected => code == 'bad_host' || code == 'bad_origin';

  /// Girdi cihaz tarafından kabul edilmedi (400 `invalid_*` / `unknown_command` ...).
  bool get isInvalidInput => statusCode == 400;

  bool get isCancelled => code == 'cancelled';

  @override
  String toString() => message;
}

/// Cihazın yerel HTTP API istemcisi (doğrudan / LAN ve kurtarma AP modu).
///
/// * Her istekte `X-Device-Key` gönderilir ([localKey]; anahtar loglanmaz).
/// * Panjur `pair` parametresi **1 tabanlıdır**; `pos` için `val` **zorunludur**.
/// * Başarı: HTTP 2xx. Hata: [LocalApiException] (401/423/403/400, ağ hatası).
/// * Adresi panonun kurulum ağı (`AppConfig.deviceApHost`, varsayılan `192.168.4.1`) olan çağrılar, Android'de
///   [BoardNetworkBinding] ile sarılır: süreç yalnızca istek süresince pano Wi-Fi ağına bağlanır (mobil veri
///   açıkken istek hücreselden çıkmasın). LAN / emülatör / `*.local` adreslerinde hiçbir şey değişmez.
class AutomationApiService {
  AutomationApiService({
    String? baseUrl,
    this.localKey,
    http.Client? client,
    this._clock = const SystemClock(),
    this._boardNetwork,
  })  : baseUrl = baseUrl ?? AppConfig.current.deviceApBaseUrl,
        _client = client ?? _createDefaultClient(),
        _ownsClient = client == null;

  /// Varsayılan (enjekte EDİLMEMİŞ) istemcide cihaza TCP bağlanma denemesinin üst sınırı (PF-36).
  static const Duration _connectionTimeout = Duration(seconds: 4);

  /// Enjekte edilmemiş istemci: bağlanma süresi sınırlıdır. `http.Client()`'ın `HttpClient`'ında
  /// `connectionTimeout` yoktur; `_sendOnce`'ın `future.timeout(...)`'u yalnızca bekleyen kodu bırakır, dart:io'nun
  /// bağlantı denemesini İPTAL ETMEZ: yönlendirilemeyen ağda (ör. cihaz kapalı/başka alt ağ) her yoklama
  /// işletim sistemi zaman aşımına kadar yaşayan bir soket bırakabilirdi (Windows VM'de ölçülen: Dart düzeyi
  /// 4 sn zaman aşımından sonra SYN_SENT ≈16 sn daha sürdü; Android için tahmin 75-130 sn, ÖLÇÜLMEDİ).
  /// `HttpClient.connectionTimeout` dolunca dart:io bağlantı görevini iptal eder ve `SocketException` fırlatır
  /// (`_sendOnce` bunu [LocalApiException.network]'e çevirir; aynı ölçümde 4 sn'de iptal, SYN_SENT kalmadı).
  ///
  /// İstemci yine `http.Client()` ile kurulur (doğrudan `IOClient` DEĞİL): `http.runWithClient` ile verilen istemci
  /// (testler buna dayanır) ve web'deki tarayıcı istemcisi aynen korunur; yalnızca bu çağrının oluşturduğu dart:io
  /// `HttpClient`'a süre sınırı verilir ([_ConnectionTimeoutOverrides]).
  static http.Client _createDefaultClient() => kIsWeb
      ? http.Client()
      : HttpOverrides.runWithHttpOverrides(http.Client.new, _ConnectionTimeoutOverrides(_connectionTimeout));

  /// Kurtarma / yerel kurulum AP'si (`AppConfig.deviceApHost`, varsayılan `192.168.4.1`) için istemci.
  /// Sihirbazlar bu fabrikayı kullanır (kendi örneği; ana durumun adresini değiştirmez).
  factory AutomationApiService.recoveryAp({
    String? localKey,
    http.Client? client,
    Clock clock = const SystemClock(),
    BoardNetworkBinding? boardNetwork,
  }) =>
      AutomationApiService(
        baseUrl: AppConfig.current.deviceApBaseUrl,
        localKey: localKey,
        client: client,
        clock: clock,
        boardNetwork: boardNetwork,
      );

  /// `http://host[:port]` (boş = adres ayarlanmadı).
  String baseUrl;

  /// `X-Device-Key` değeri (8–32 karakter). Anahtarsız yalnızca kısıtlı `status` özeti çalışır.
  String? localKey;

  final http.Client _client;
  final bool _ownsClient;
  final Clock _clock;

  /// Pano ağına süreç bağlama (isteğe bağlı; verilmezse çağrı anında [BoardNetworkBinding.instance]).
  final BoardNetworkBinding? _boardNetwork;

  bool get isConfigured => baseUrl.isNotEmpty;

  /// Aynı ayarlarla (adres + anahtar) ayrı bir istemci.
  AutomationApiService copyWith({String? baseUrl, String? localKey}) => AutomationApiService(
        baseUrl: baseUrl ?? this.baseUrl,
        localKey: localKey ?? this.localKey,
        client: _client,
        clock: _clock,
        boardNetwork: _boardNetwork,
      );

  void dispose() {
    if (_ownsClient) _client.close();
  }

  /// `192.168.1.30`, `192.168.1.30:80`, `http://...` biçimlerini kabul eder (cihaz TLS konuşmaz:
  /// `https://` öneki `http://`ye çevrilir). Geçersizse adres "ayarlanmadı" olur (sessizce başka
  /// bir adrese gidilmez).
  ///
  /// **Yalnızca yerel adresler kabul edilir** ([isAllowedDeviceHost]): `X-Device-Key` açık metin
  /// gider, yanlışlıkla/kötü niyetle girilmiş internet adresine sızmamalıdır; ayrıca cihaz kendi
  /// tarafında ana makine allow-list'i uygular (`400 bad_host`).
  void updateHost(String newHost) {
    var text = newHost.trim();
    if (text.isEmpty) {
      baseUrl = '';
      return;
    }
    final scheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').firstMatch(text);
    if (scheme != null) {
      final lower = scheme.group(0)!.toLowerCase();
      if (lower != 'http://' && lower != 'https://') {
        baseUrl = '';
        return;
      }
      text = text.substring(scheme.end);
    }
    while (text.endsWith('/')) {
      text = text.substring(0, text.length - 1);
    }
    if (text.isEmpty || text.contains(RegExp(r'[/?#@\s]'))) {
      baseUrl = '';
      return;
    }
    final uri = Uri.tryParse('http://$text');
    if (uri == null || uri.host.isEmpty || uri.hasQuery || uri.userInfo.isNotEmpty) {
      baseUrl = '';
      return;
    }
    if (uri.hasPort && (uri.port < 1 || uri.port > 65535)) {
      baseUrl = '';
      return;
    }
    if (!isAllowedDeviceHost(uri.host)) {
      baseUrl = '';
      return;
    }
    baseUrl = 'http://$text';
  }

  static final RegExp _mdnsName = RegExp(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*\.local$');

  /// Cihaz adresi olabilir mi (CONTRACTS §3b ana makine allow-list'i): `localhost`, `*.local` veya
  /// **yerel** (özel / link-local / loopback / CGNAT) IPv4. Genel internet adresleri ve IPv6 ✖.
  static bool isAllowedDeviceHost(String host) {
    final h = host.trim().toLowerCase();
    if (h.isEmpty) return false;
    if (h == 'localhost') return true;
    if (h.endsWith('.local')) return h.length <= 253 && _mdnsName.hasMatch(h);
    final parts = h.split('.');
    if (parts.length != 4) return false;
    final octets = <int>[];
    for (final part in parts) {
      if (!RegExp(r'^\d{1,3}$').hasMatch(part)) return false;
      final value = int.parse(part);
      if (value > 255) return false;
      octets.add(value);
    }
    final a = octets[0];
    final b = octets[1];
    if (a == 10 || a == 127) return true; // 10/8 (emülatör 10.0.2.2 dahil), loopback
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 192 && b == 168) return true;
    if (a == 169 && b == 254) return true; // link-local
    if (a == 100 && b >= 64 && b <= 127) return true; // CGNAT / Tailscale
    return false;
  }

  // ---------------------------------------------------------------------------
  // HTTP çekirdeği
  // ---------------------------------------------------------------------------

  /// Tüm cihaz istekleri BURADAN geçer; adres pano kurulum ağıysa kira al -> istek -> (finally) bırak.
  Future<http.Response> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    Duration timeout = const Duration(seconds: 4),
    bool sendKey = true,
  }) =>
      _withBoardNetwork(
        () => _sendOnce(method, path, query: query, body: body, timeout: timeout, sendKey: sendKey),
      );

  // ---------------------------------------------------------------------------
  // Pano kurulum ağına yönlenme (Android; BoardNetworkBinding)
  // ---------------------------------------------------------------------------

  _BoardScope? _boardScope;

  /// [action] çalışırken (Android'de) süreci pano kurulum ağına bağlar: kira al -> [action] -> `finally` bırak.
  ///
  /// * Yalnızca adres pano kurulum ağıysa ([BoardNetworkTarget]: `AppConfig.deviceApHost`, ham IPv4,
  ///   `192.168.0.0/16`) ve platform destekliyorsa devreye girer; LAN / emülatör / `*.local` adreslerinde
  ///   ve desteklemeyen platformda [action] AYNEN (ek bekleme olmadan) çalışır.
  /// * Aynı örnekteki iç içe/eşzamanlı çağrılar TEK kirayı paylaşır: uzun işlemler ([awaitWifiConnection],
  ///   tarama döngüsü, [connectWifiAndWait]) tüm süre boyunca tek kira tutar; iç istekler ona katılır.
  /// * Bağlama başarısız olsa da istek YİNE DE denenir (davranış bağlamasız sürümden kötü olmaz); istek ağ
  ///   hatasıyla ([LocalApiException.isNetwork]) biterse ve bağlama başarısızsa hataya Türkçe ipucu eklenir.
  Future<T> _withBoardNetwork<T>(Future<T> Function() action) {
    final binding = _boardNetwork ?? BoardNetworkBinding.instance;
    if (!binding.isSupported) return action();
    final target = BoardNetworkTarget.forBaseUrl(baseUrl);
    if (target == null) return action();
    return _runOnBoardNetwork(binding, target.host, action);
  }

  Future<T> _runOnBoardNetwork<T>(BoardNetworkBinding binding, String host, Future<T> Function() action) async {
    var scope = _boardScope;
    if (scope == null || scope.host != host) {
      scope = _BoardScope(host, _acquireBoardLease(binding, host));
      _boardScope = scope;
    }
    scope.users++;
    BoardNetworkLease? lease;
    try {
      lease = await scope.lease;
      return await action();
    } on LocalApiException catch (e, stack) {
      final hinted = _withBoardHint(e, lease);
      if (hinted == null) rethrow;
      Error.throwWithStackTrace(hinted, stack);
    } finally {
      if (--scope.users == 0) {
        if (identical(_boardScope, scope)) _boardScope = null;
        await _releaseBoardLease(scope);
      }
    }
  }

  /// Kira alma asla fırlatmamalı; fırlatırsa (kötü davranan bağlama) çağrı bağlamasız sürüm gibi sürer.
  Future<BoardNetworkLease> _acquireBoardLease(BoardNetworkBinding binding, String host) async {
    try {
      return await binding.acquire(host: host);
    } catch (e) {
      // Yutulan istisna: yalnız TÜRÜ yazılır (hata ayıklama derlemesinde); ileti metni/adres yazılmaz.
      if (kDebugMode) debugPrint('[BoardNetwork/Dart] acquire istisnası yutuldu (${e.runtimeType})');
      return BoardNetworkLease.unbound(BoardNetworkStatus.error, detail: 'acquire_failed');
    }
  }

  Future<void> _releaseBoardLease(_BoardScope scope) async {
    try {
      await (await scope.lease).release();
    } catch (_) {
      // Bırakma sonucu isteğin sonucunu değiştirmez.
    }
  }

  /// Ağ hatasına bağlama ipucunu ekler (zaten ipucu varsa ya da ipucu yoksa `null`: hata olduğu gibi kalır).
  LocalApiException? _withBoardHint(LocalApiException e, BoardNetworkLease? lease) {
    if (!e.isNetwork || e.hint != null || lease == null) return null;
    final hint = lease.failureHint;
    if (hint == null) return null;
    return LocalApiException(
      statusCode: e.statusCode,
      code: e.code,
      message: '${e.message} $hint',
      retryAfter: e.retryAfter,
      hint: hint,
    );
  }

  Future<http.Response> _sendOnce(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    Duration timeout = const Duration(seconds: 4),
    bool sendKey = true,
  }) async {
    if (!isConfigured) throw LocalApiException.notConfigured();
    final base = Uri.parse(baseUrl);
    final uri = Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: path,
      queryParameters: (query == null || query.isEmpty) ? null : query,
    );
    final key = sendKey ? localKey : null;
    final headers = <String, String>{
      'Accept': 'application/json',
      if (method != 'GET') 'Content-Type': 'application/json',
      if (key != null && key.isNotEmpty) 'X-Device-Key': key,
    };
    try {
      final Future<http.Response> future;
      switch (method) {
        case 'GET':
          future = _client.get(uri, headers: headers);
        case 'POST':
          future = _client.post(uri, headers: headers, body: body == null ? null : jsonEncode(body));
        default:
          throw ArgumentError('Desteklenmeyen HTTP yöntemi: $method');
      }
      return _check(await future.timeout(timeout));
    } on TimeoutException catch (e) {
      throw LocalApiException.network(e);
    } on IOException catch (e) {
      throw LocalApiException.network(e);
    } on http.ClientException catch (e) {
      throw LocalApiException.network(e);
    }
  }

  Map<String, dynamic> _json(http.Response res) {
    if (res.bodyBytes.isEmpty) return <String, dynamic>{};
    try {
      // Geçersiz UTF-8 (ör. bozuk SSID baytları) yanıtı çökertmez.
      return asMap(jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true))) ??
          <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// Cihaz hata kodu (`{"error":"…"}`) -> Türkçe mesaj (CONTRACTS §3b).
  static const Map<String, String> _errorMessages = <String, String>{
    'invalid_ssid': 'Ağ adı geçersiz (1–32 bayt olmalı).',
    'invalid_password': 'Wi-Fi şifresi geçersiz (boş ya da 8–63 karakter olmalı).',
    'invalid_key': 'Cihaz anahtarı geçersiz (8–32 görünür karakter, boşluksuz).',
    'invalid_ap_pass': 'Kurulum ağı parolası geçersiz (8–32 karakter olmalı).',
    'invalid_value': 'Gönderilen değer cihaz tarafından kabul edilmedi.',
    'invalid_json': 'Cihaz isteği anlayamadı (geçersiz veri).',
    'empty_body': 'Cihaz isteği anlayamadı (boş veri).',
    'unknown_command': 'Cihaz bu komutu tanımıyor (sürüm uyumsuz olabilir).',
    'bad_host': 'Cihaz bu adresle erişimi reddetti. Cihazın IP adresini kullanın.',
    'bad_origin': 'Cihaz isteğin kaynağını reddetti.',
    'already_provisioned': 'Cihaz zaten kurulmuş (anahtar tanımlı).',
    'unprovisioned': 'Cihaz henüz kurulmamış.',
    'busy': 'Cihaz şu anda meşgul. Biraz bekleyip tekrar deneyin.',
    'queue_full': 'Cihaz şu anda yoğun. Biraz bekleyip tekrar deneyin.',
    'storage': 'Cihaz ayarı belleğine yazamadı. Tekrar deneyin.',
    'storage_error': 'Cihaz ayarı belleğine yazamadı. Tekrar deneyin.',
    'too_large': 'Gönderilen veri cihaz için çok büyük.',
    // Güvenlik uçları (CONTRACTS §2.6 "LAN yanıtları")
    'timeout': 'Pano komutu zamanında işleyemedi. Durumu kontrol edip yeniden deneyin.',
    'unknown_field': 'Cihaz isteği anlayamadı (sürüm uyumsuz olabilir).',
    'uid_mismatch': 'İstek başka bir panoya ait.',
    'invalid_actuator': 'Geçersiz güvenlik cihazı kimliği.',
    'invalid_zone': 'Geçersiz bölge.',
    'invalid_aid': 'Geçersiz alarm kimliği.',
    'invalid_id': 'Geçersiz komut kimliği.',
    'invalid_after': 'Geçersiz olay kimliği.',
    // Kurulum şablonu (CONTRACTS §3e, `POST /api/template/apply`)
    'armed': 'Hırsız alarmı kurulu; önce alarm çözülmeli.',
  };

  http.Response _check(http.Response res) {
    if (res.statusCode >= 200 && res.statusCode < 300) return res;
    final body = _json(res);
    final error = asNonEmptyString(body['error']);
    final status = res.statusCode;
    Duration? retryAfter;
    final bodyRetry = asInt(body['retry_after']);
    int? headerRetry;
    for (final entry in res.headers.entries) {
      if (entry.key.toLowerCase() == 'retry-after') headerRetry = int.tryParse(entry.value.trim());
    }
    final seconds = bodyRetry ?? headerRetry;
    if (seconds != null && seconds > 0) retryAfter = Duration(seconds: seconds);

    String message;
    if (status == 401) {
      message = 'Cihaz anahtarı geçersiz. Cihaz anahtarını yeniden alın.';
    } else if (status == 423) {
      message = 'Cihaz çok fazla hatalı deneme nedeniyle kilitlendi. Biraz bekleyin.';
    } else if (error == 'cfg_invalid' && isSafetyRejectCode(asNonEmptyString(body['detail']))) {
      message = safetyRejectMessage(asNonEmptyString(body['detail'])); // bilinen doğrulama ayrıntısı (sensor_bridge_unsupported)
    } else if (error != null && _errorMessages.containsKey(error)) {
      message = _errorMessages[error]!;
    } else if (isSafetyRejectCode(error)) {
      message = safetyRejectMessage(error); // güvenlik ret kodu (zone_latched, gas_local_only ...)
    } else if (status == 400) {
      message = 'Cihaz isteği kabul etmedi.';
    } else if (status == 404) {
      message = 'Cihaz bu özelliği desteklemiyor (sürüm uyumsuz olabilir).';
    } else if (status == 413) {
      message = _errorMessages['too_large']!;
    } else if (status == 415) {
      message = 'Cihaz isteği anlayamadı (içerik türü).';
    } else if (status == 429) {
      message = 'Cihaz çok sık istek aldı. Biraz bekleyip tekrar deneyin.';
    } else if (status == 502) {
      message = 'Cihazın genişleme modülü yanıt vermedi.';
    } else if (status == 503) {
      message = _errorMessages['busy']!;
    } else {
      message = 'Cihaz isteği tamamlayamadı (Kod: $status).';
    }
    throw LocalApiException(
      statusCode: status,
      code: error,
      message: message,
      retryAfter: retryAfter,
      path: asNonEmptyString(body['path']),
    );
  }

  // ---------------------------------------------------------------------------
  // Durum
  // ---------------------------------------------------------------------------

  /// Cihazın tam durumu (anahtarla). Anahtar yoksa yalnızca **kısıtlı özet** gelir
  /// ([DeviceStatus.restricted]); yanlış anahtarda `401`.
  Future<DeviceStatus> fetchStatus() async {
    final res = await _send('GET', '/api/status', timeout: const Duration(seconds: 4));
    return DeviceStatus.fromJson(_json(res));
  }

  /// Anahtar **göndermeden** kısıtlı özet: cihaz kimliği (`uid`), ad, sürüm, `provisioned` ve
  /// `wifiConnected`. Kurulum sihirbazı cihazın kurulu olup olmadığını (`provisioned`) yanlış
  /// anahtar kilidine (423) takılmadan buradan okur.
  Future<DeviceStatus> fetchPublicStatus() async {
    final res = await _send(
      'GET',
      '/api/status',
      timeout: const Duration(seconds: 4),
      sendKey: false,
    );
    return DeviceStatus.fromJson(_json(res));
  }

  /// Wi-Fi servis akışı durumu: `GET /api/wifi/status` (CONTRACTS §3d) -> `wifi_connect_state`
  /// (`idle|connecting|success|failed`), `wifi_connect_reason`, `wifi_connected`, `wifi_sta_ssid/ip`,
  /// `wifi_rssi`, `ap_active` (`wifiApActive`). Panonun WPA2 kurulum ağından (SoftAP) gelen istek için
  /// **anahtarsız** çalışır (internet/giriş gerekmez); [localKey] varsa gönderilir. Eski yazılımda uç
  /// yoktur (`404`): [awaitWifiConnection] bu durumda [fetchStatus]'a düşer.
  Future<DeviceStatus> fetchWifiStatus() async {
    final res = await _send('GET', '/api/wifi/status', timeout: const Duration(seconds: 4));
    final json = Map<String, dynamic>.of(_json(res));
    if (!json.containsKey('wifi_ap_active') && json.containsKey('ap_active')) {
      json['wifi_ap_active'] = json['ap_active']; // tam status'taki alan adına eşle
    }
    return DeviceStatus.fromJson(json);
  }

  // ---------------------------------------------------------------------------
  // Komutlar (1 tabanlı numaralar)
  // ---------------------------------------------------------------------------

  void _checkRelay(int channel) {
    if (channel < 1 || channel > 64) {
      throw LocalApiException.invalid('Röle numarası 1 tabanlıdır (1..64).');
    }
  }

  /// Rölenin durumunu açıkça ayarlar (idempotent; `toggle` yerine tercih edilir).
  Future<bool> setRelay(int channel, bool on) async {
    _checkRelay(channel);
    await _send('POST', '/api/relay', query: <String, String>{
      'ch': '$channel',
      'state': on ? '1' : '0',
    });
    return true;
  }

  Future<bool> toggleRelay(int channel) async {
    _checkRelay(channel);
    await _send('POST', '/api/relay', query: <String, String>{'ch': '$channel', 'cmd': 'toggle'});
    return true;
  }

  /// Darbe/tetik rölesi (`state=1`).
  Future<bool> triggerImpulse(int channel) => setRelay(channel, true);

  // ---------------------------------------------------------------------------
  // Güvenlik modülü (tasarım §3.5; gövde MQTT `cmd` ile aynı, LAN'da `uid` gerekmez). Yanıt `{ok, id, rej?}`:
  // `rej` komutun işlendiğinde yazılan ret kodudur (`last_rej` ile aynı kodlar) -> [LocalApiException] (409, kod).
  // ---------------------------------------------------------------------------

  /// Eylemci komutu: `POST /api/actuator {actuator, to, id?}`; [to] `closed|open|on|off` (MQTT `cmd` ile aynı gövde;
  /// firmware bilinmeyen alanı `400 unknown_field` ile reddeder).
  Future<void> postActuator(String actuatorId, String to, {String? id}) async {
    if (actuatorId.isEmpty || actuatorId.length > 8) throw LocalApiException.invalid('Geçersiz eylemci kimliği.');
    if (!const <String>{'closed', 'open', 'on', 'off'}.contains(to)) {
      throw LocalApiException.invalid('Geçersiz eylemci hedefi.');
    }
    final res = await _send(
      'POST',
      '/api/actuator',
      body: <String, dynamic>{'actuator': actuatorId, 'to': to, 'id': ?id},
      timeout: const Duration(seconds: 5),
    );
    _throwIfRejected(res);
  }

  /// Alarm onayı / susturma: `POST /api/alarm/ack {zone, aid?, id?}` ([aid] bayatsa pano `stale_ack` döner).
  Future<void> ackAlarm(int zone, {String? aid, String? id}) async {
    if (zone < 1 || zone > 4) throw LocalApiException.invalid('Geçersiz bölge.');
    final res = await _send(
      'POST',
      '/api/alarm/ack',
      body: <String, dynamic>{'zone': zone, 'aid': ?aid, 'id': ?id},
      timeout: const Duration(seconds: 5),
    );
    _throwIfRejected(res);
  }

  /// Hırsız alarmı kipi (F2.B.7): `POST /api/arm {mode, id?}` (`off` = çözme). Yanıt `{ok, id, rej?}`; `rej`
  /// (`not_ready` ...) [LocalApiException] olur.
  Future<void> postArm(String mode, {String? id}) async {
    if (!const <String>{'away', 'home', 'off'}.contains(mode)) throw LocalApiException.invalid('Geçersiz alarm kipi.');
    final res = await _send(
      'POST',
      '/api/arm',
      body: <String, dynamic>{'mode': mode, 'id': ?id},
      timeout: const Duration(seconds: 5),
    );
    _throwIfRejected(res);
  }

  /// Bölge testi: `POST /api/alarm/test {zone, id?}`.
  Future<void> testAlarm(int zone, {String? id}) async {
    if (zone < 1 || zone > 4) throw LocalApiException.invalid('Geçersiz bölge.');
    final res = await _send(
      'POST',
      '/api/alarm/test',
      body: <String, dynamic>{'zone': zone, 'id': ?id},
      timeout: const Duration(seconds: 5),
    );
    _throwIfRejected(res);
  }

  /// İnternetsiz alarm geçmişi: `GET /api/events?after=<eid>` -> `{bn, events:[…], more}` (halka 32 olay, sayfa en çok
  /// 16; K5, CONTRACTS §2.6). `more` doluysa son eid'den sonrası sırayla okunur (en çok [maxPages] sayfa); bilinmeyen
  /// `after` panoda baştan döner, yinelenen eid atlanır. Bozuk öğe atlanır.
  Future<List<DeviceEventRecord>> fetchEvents({String? after, int maxPages = 4}) async {
    final out = <DeviceEventRecord>[];
    final seen = <String>{};
    var cursor = after;
    for (var page = 0; page < maxPages; page++) {
      final res = await _send(
        'GET',
        '/api/events',
        query: <String, String>{'after': ?cursor},
        timeout: const Duration(seconds: 4),
      );
      final body = _json(res);
      final raw = asList(body['events'] ?? body['data']) ?? const <dynamic>[];
      for (final e in parseList(raw, DeviceEventRecord.fromJson, label: 'Event')) {
        if (seen.add(e.eid)) out.add(e);
      }
      String? last;
      for (final item in raw.reversed) {
        last = asNonEmptyString(asMap(item)?['eid']);
        if (last != null) break;
      }
      if (asBool(body['more']) != true || last == null || last == cursor) break;
      cursor = last;
    }
    return out;
  }

  /// Güvenlik yapılandırması (LAN; CONTRACTS §2.6): `GET /api/safety/config` -> `{rev, crc, policy, zones, lights,
  /// sensors, actuators}` (adlar dahil). Sihirbaz `rev`'i iyimser eşzamanlılık için okur (`base_rev`).
  Future<Map<String, dynamic>> fetchSafetyConfig() async {
    final res = await _send('GET', '/api/safety/config', timeout: const Duration(seconds: 5));
    return _json(res);
  }

  /// TEK öğelik yapılandırma yaması (CONTRACTS §2.6): `POST /api/safety/config` gövdesi
  /// `{base_rev?, set:{sensor|actuator|policy|zone|light:{…}}}` ya da `{base_rev?, del:{sensor|actuator:"a2"}}`;
  /// yanıt `200 {status:"ok", rev, crc}`. Ret:
  /// `400 cfg_invalid` (`detail`), `403 local_loosen_forbidden` (yerel anahtarla gevşetme yasak, karar 7.2b-7),
  /// `409 cfg_conflict` / `zone_latched`, `500 storage_error`, `503 busy` -> [LocalApiException] (kod + Türkçe metin).
  Future<Map<String, dynamic>> saveSafetyConfig(Map<String, dynamic> body) async {
    final res = await _send('POST', '/api/safety/config', body: body, timeout: const Duration(seconds: 8));
    _throwIfRejected(res);
    return _json(res);
  }

  /// Yamaları SIRAYLA uygular; her isteğin `base_rev`'i bir öncekinin yanıtındaki `rev`'dir (ilki [baseRev]). Bir yama
  /// reddedilirse durur ve hatayı fırlatır (öncekiler panoda kalır; sihirbaz yeniden okuyup kalanı yazar). Dönüş: son
  /// `rev` ve `crc` (yama yoksa [baseRev]).
  Future<({int rev, String? crc})> applySafetyConfigPatches(List<Map<String, dynamic>> patches, {required int baseRev}) async {
    var rev = baseRev;
    String? crc;
    for (final patch in patches) {
      final res = await saveSafetyConfig(<String, dynamic>{'base_rev': rev, ...patch});
      final next = asInt(res['rev']);
      if (next == null) {
        throw const LocalApiException(
          statusCode: 502,
          code: 'bad_response',
          message: 'Pano yapılandırma yanıtı anlaşılamadı (sürüm uyumsuz olabilir).',
        );
      }
      rev = next;
      crc = asNonEmptyString(res['crc']);
    }
    return (rev: rev, crc: crc);
  }

  void _throwIfRejected(http.Response res) {
    final body = _json(res);
    final rej = asNonEmptyString(body['rej'])?.toLowerCase();
    if (rej == null) return;
    throw LocalApiException(statusCode: 409, code: rej, message: safetyRejectMessage(rej));
  }

  /// Panjur komutu: [pair] **1 tabanlı**; [action] `up|down|stop|step|pos`; `pos` için [value]
  /// (0..100) **zorunludur**.
  Future<bool> cmdShutter(int pair, String action, {int? value}) async {
    if (pair < 1 || pair > 32) {
      throw LocalApiException.invalid('Panjur numarası 1 tabanlıdır (1..32).');
    }
    const actions = <String>{'up', 'down', 'stop', 'step', 'pos'};
    if (!actions.contains(action)) {
      throw LocalApiException.invalid('Geçersiz panjur komutu.');
    }
    final query = <String, String>{'pair': '$pair', 'cmd': action};
    if (action == 'pos') {
      if (value == null || value < 0 || value > 100) {
        throw LocalApiException.invalid('Konum 0 ile 100 arasında olmalıdır.');
      }
      query['val'] = '$value';
    }
    await _send('POST', '/api/relay', query: query);
    return true;
  }

  Future<bool> setShutterPosition(int pair, int value) => cmdShutter(pair, 'pos', value: value);

  static const Map<String, String> _allCommands = <String, String>{
    'lightsoff': 'lightsoff',
    'all_lights_off': 'lightsoff',
    'all_off': 'lightsoff',
    'shuttersdown': 'shuttersdown',
    'all_shutters_down': 'shuttersdown',
    'shuttersup': 'shuttersup',
    'all_shutters_up': 'shuttersup',
    'shuttersstop': 'shuttersstop',
    'all_shutters_stop': 'shuttersstop',
  };

  /// Toplu komut: `lightsoff | shuttersdown | shuttersup | shuttersstop` (veya `all_*` eş anlamlıları).
  Future<bool> cmdAll(String command) async {
    final mapped = _allCommands[command];
    if (mapped == null) throw LocalApiException.invalid('Geçersiz toplu komut.');
    await _send('POST', '/api/all', query: <String, String>{'cmd': mapped});
    return true;
  }

  // ---------------------------------------------------------------------------
  // Kurulum şablonu (firmware v1.3.0+; CONTRACTS §3e, docs/contracts/template/README.md)
  // ---------------------------------------------------------------------------

  /// Panoda yüklü şablon: `GET /api/template` (KEYED). Eski firmware (v1.2.x) bu ucu bilmez: `404`
  /// ([LocalApiException.statusCode] 404) -> çağıran "pano yazılımını güncelleyin" der.
  Future<BoardTemplateInfo> fetchTemplate() async {
    final res = await _send('GET', '/api/template', timeout: const Duration(seconds: 5));
    return BoardTemplateInfo.fromJson(_json(res));
  }

  /// Şablonu panoya atomik olarak uygular: `POST /api/template/apply` (KEYED) gövde [envelope] =
  /// `{"template": {...ahbu-template/1...}, "label": "..."}`. Ana yapılandırma + güvenlik birlikte yazılır; herhangi
  /// biri geçersizse panoda hiçbir şey değişmez. Ret ([LocalApiException], kod + varsa [LocalApiException.path]):
  /// `400 <doğrulama kodu>` (`path`), `403 local_loosen_forbidden` (LAN'dan güvenlik gevşetme yasak; USB ile yazılır),
  /// `409 zone_latched` / `armed` / `busy`, `507 storage`; eski firmware `404`.
  Future<TemplateApplyResult> applyTemplate(Map<String, dynamic> envelope) async {
    final res = await _send('POST', '/api/template/apply', body: envelope, timeout: const Duration(seconds: 15));
    return TemplateApplyResult.fromJson(_json(res));
  }

  // ---------------------------------------------------------------------------
  // Yapılandırma / Wi-Fi / çocuk kilidi
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> fetchConfig() async {
    final res = await _send('GET', '/api/config', timeout: const Duration(seconds: 5));
    return _json(res);
  }

  Future<bool> saveConfig(Map<String, dynamic> config) async {
    await _send('POST', '/api/config', body: config, timeout: const Duration(seconds: 6));
    return true;
  }

  /// Panonun gördüğü 2.4 GHz Wi-Fi ağlarını tarar (arka planda; `scanning` iken yoklanır).
  /// [refresh] true ise önbellek atlanıp yeni tarama başlatılır. [isCancelled] true dönerse
  /// tarama bırakılır ([LocalApiException.isCancelled]).
  Future<List<Map<String, dynamic>>> scanWifiNetworks({
    bool refresh = false,
    bool Function()? isCancelled,
  }) =>
      _withBoardNetwork(() => _scanWifiNetworks(refresh: refresh, isCancelled: isCancelled));

  Future<List<Map<String, dynamic>>> _scanWifiNetworks({
    bool refresh = false,
    bool Function()? isCancelled,
  }) async {
    var firstRequest = true;
    for (var attempt = 0; attempt < 12; attempt++) {
      if (isCancelled?.call() == true) throw LocalApiException.cancelled();
      final query = (refresh && firstRequest) ? <String, String>{'refresh': '1'} : null;
      firstRequest = false;
      final res = await _send('GET', '/api/wifi/scan', query: query, timeout: const Duration(seconds: 8));
      final json = _json(res);
      if (json['status'] != 'scanning') {
        final networks = (asList(json['networks']) ?? const <dynamic>[])
            .map(asMap)
            .whereType<Map<String, dynamic>>()
            .toList()
          ..sort((a, b) => (asInt(b['rssi']) ?? -100).compareTo(asInt(a['rssi']) ?? -100));
        return networks;
      }
      final wait = Completer<void>();
      _clock.timer(const Duration(milliseconds: 1200), wait.complete); // cihaz: 1–2 sn arayla yeniden sor
      await wait.future;
    }
    throw const LocalApiException(
      statusCode: 0,
      code: 'timeout',
      message: 'Ağ taraması zaman aşımına uğradı. Tekrar deneyin.',
    );
  }

  /// [scanWifiNetworks]'in tipli sürümü: ağlar sinyal gücüne göre sıralı, **aynı adlı ağlar tekilleştirilmiş**
  /// (en güçlüsü kalır), SSID'siz (gizli) kayıtlar atılmış.
  Future<List<WifiNetwork>> scanWifi({bool refresh = false, bool Function()? isCancelled}) async {
    final raw = await scanWifiNetworks(refresh: refresh, isCancelled: isCancelled);
    final best = <String, WifiNetwork>{};
    for (final item in raw) {
      final WifiNetwork network;
      try {
        network = WifiNetwork.fromJson(item);
      } on FormatException {
        continue;
      }
      final existing = best[network.ssid];
      if (existing == null || network.rssi > existing.rssi) best[network.ssid] = network;
    }
    return best.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
  }

  /// Panoya ev Wi-Fi bilgilerini gönderir; cihaz `200 {"status":"connecting"}` yanıtlar ve ~0,5 sn
  /// sonra bağlanmayı dener. **Bu çağrının dönmesi bağlandı demek DEĞİLDİR**: sonuç [fetchWifiStatus]
  /// (eski yazılımda [fetchStatus]) -> `wifiConnectState` (`success` yalnızca başarı) ile yoklanır
  /// ([awaitWifiConnection] / [connectWifiAndWait] bunu yapar). Cihaz başka bir deneme sürerken
  /// `409 busy`; AP kaynaklı anahtarsız istekte dakikada 6'dan fazlasında `429` (`retryAfter`).
  ///
  /// SSID/parola **kırpılmaz** (baş/son boşluk geçerlidir). SSID 1..32 bayt (UTF-8), parola
  /// 0 (açık ağ) veya 8..63 bayt olmalıdır.
  Future<void> connectWifi(String ssid, String pass) async {
    final ssidBytes = utf8.encode(ssid).length;
    final passBytes = utf8.encode(pass).length;
    if (ssidBytes < 1 || ssidBytes > 32) {
      throw LocalApiException.invalid('Ağ adı 1 ile 32 bayt arasında olmalıdır.');
    }
    if (passBytes != 0 && (passBytes < 8 || passBytes > 63)) {
      throw LocalApiException.invalid('Wi-Fi şifresi 8 ile 63 karakter arasında olmalıdır.');
    }
    await _send(
      'POST',
      '/api/wifi/connect',
      body: <String, dynamic>{'ssid': ssid, 'pass': pass},
      timeout: const Duration(seconds: 8),
    );
  }

  /// Wi-Fi bağlanma denemesinin sonucunu bekler: [fetchWifiStatus] (`GET /api/wifi/status`; AP
  /// kaynaklı istekte anahtarsız çalışır) ile `wifiConnectState` yoklanır. Uç yoksa (`404`: eski
  /// yazılım) [fetchStatus]'a (`GET /api/status`) düşülür; bu tercih bekleme boyunca korunur.
  ///
  /// * `success` -> [WifiConnectOutcome.success] (+ pano `wifiStaIp`).
  /// * `failed` -> [WifiConnectOutcome.failed] (+ `wifi_err_reason_t` nedeni; 0 = zaman aşımı/bilinmiyor).
  /// * [timeout] dolarsa -> [WifiConnectOutcome.timedOut].
  /// * Yoklama sırasında cihaza ulaşılamazsa (pano bağlandığında kurulum AP'sini kapatır ve telefon
  ///   AP'den düşer) -> **belirsiz**: [WifiConnectOutcome.lostContact]; başarısızlık sanılmaz.
  ///   Aynı şekilde, en az bir okuma yapıldıktan SONRA gelen `401` (AP kaynaklı anahtarsız yol kapandı:
  ///   ör. pano bağlandı ve modem ağı da `192.168.4.x`) belirsizdir; İLK okumadan önce gelen `401`/`403`/`423`
  ///   ise yeniden fırlatılır.
  /// * [isCancelled] `true` dönerse [LocalApiException.cancelled] fırlatılır.
  ///
  /// Pano kurulum ağı adresinde (Android) bekleme **baştan sona tek bir** pano ağı kirası tutar ([BoardNetworkBinding]):
  /// yoklamalar, yeniden denemeler, iptal ve zaman aşımı dahil her çıkış yolunda bırakılır.
  Future<WifiConnectResult> awaitWifiConnection({
    Duration timeout = const Duration(seconds: 40),
    Duration interval = const Duration(milliseconds: 1500),
    bool Function()? isCancelled,
  }) =>
      _withBoardNetwork(() => _awaitWifiConnection(timeout: timeout, interval: interval, isCancelled: isCancelled));

  Future<WifiConnectResult> _awaitWifiConnection({
    required Duration timeout,
    required Duration interval,
    bool Function()? isCancelled,
  }) async {
    final deadline = _clock.now().add(timeout);
    var observed = false; // en az bir kez cihazdan durum okundu
    var legacyStatus = false; // eski yazılım: /api/wifi/status yok -> /api/status ile yokla
    Future<DeviceStatus> poll() async {
      if (!legacyStatus) {
        try {
          return await fetchWifiStatus();
        } on LocalApiException catch (e) {
          if (e.statusCode != 404) rethrow;
          legacyStatus = true;
        }
      }
      return fetchStatus();
    }

    while (true) {
      if (isCancelled?.call() == true) throw LocalApiException.cancelled();
      try {
        final status = await poll();
        observed = true;
        switch (status.wifiConnectState) {
          case WifiConnectState.success:
            return WifiConnectResult(
              WifiConnectOutcome.success,
              ipAddress: status.wifiStaIp.isEmpty ? null : status.wifiStaIp,
              status: status,
            );
          case WifiConnectState.failed:
            return WifiConnectResult(
              WifiConnectOutcome.failed,
              reason: status.wifiConnectReason,
              status: status,
            );
          case WifiConnectState.idle:
          case WifiConnectState.connecting:
          case WifiConnectState.unknown:
            break;
        }
      } on LocalApiException catch (e) {
        if (e.isCancelled) rethrow;
        // AP kaynaklı anahtarsız yol yoklama SIRASINDA kapandıysa (ör. pano bağlandı ve modemin ağı da kurulum
        // ağıyla aynı 192.168.4.x alt ağında: CONTRACTS §3d alt ağ çakışması; ya da kurulum ağı kapandı), daha
        // önce en az bir okuma yapıldığından sonuç BELİRSİZDİR: yetki hatası/başarısızlık sanılmaz.
        if (e.isUnauthorized && observed) {
          return const WifiConnectResult(WifiConnectOutcome.lostContact);
        }
        if (e.isUnauthorized || e.isLocked || e.isUnprovisioned) rethrow;
        if (e.isNetwork && observed) {
          return const WifiConnectResult(WifiConnectOutcome.lostContact);
        }
        // Henüz hiç okunamadı / geçici hata: süre dolana kadar yeniden dene.
      }
      if (!_clock.now().add(interval).isBefore(deadline)) {
        return const WifiConnectResult(WifiConnectOutcome.timedOut);
      }
      final done = Completer<void>();
      _clock.timer(interval, done.complete);
      await done.future;
    }
  }

  /// [connectWifi] + [awaitWifiConnection]: bilgileri gönderir ve sonucu bekler.
  Future<WifiConnectResult> connectWifiAndWait(
    String ssid,
    String pass, {
    Duration timeout = const Duration(seconds: 40),
    bool Function()? isCancelled,
  }) =>
      // Gönderme + bekleme TEK pano ağı kirası altında (arada bağlama çözülüp yeniden kurulmaz).
      _withBoardNetwork(() async {
        await connectWifi(ssid, pass);
        return awaitWifiConnection(timeout: timeout, isCancelled: isCancelled);
      });

  // ---------------------------------------------------------------------------
  // Provizyon (kurulum sihirbazı: fabrika / servis)
  // ---------------------------------------------------------------------------

  static final RegExp _localKeyPattern = RegExp(r'^[\x21-\x7E]{8,32}$');

  /// Yerel anahtar biçimi: 8–32 görünür ASCII, boşluksuz (cihaz doğrulaması ile aynı).
  static bool isValidLocalKey(String? key) => key != null && _localKeyPattern.hasMatch(key);

  /// Provizyonsuz cihazın ilk kurulumu (`POST /api/factory/init {local_key, ap_pass}`); **anahtar
  /// başlığı gönderilmez** (cihazda henüz anahtar yok). Başarıda [localKey] yeni anahtara ayarlanır
  /// ve kurulum AP'si WPA2 + [apPass] ile yeniden başlar (telefon yeniden bağlanmalıdır). Cihaz
  /// zaten kuruluysa `403 already_provisioned` ([LocalApiException.isAlreadyProvisioned]).
  /// Değerler **loglanmaz**.
  Future<void> factoryInit({required String localKey, required String apPass}) async {
    if (!isValidLocalKey(localKey)) {
      throw LocalApiException.invalid(_errorMessages['invalid_key']!);
    }
    if (apPass.length < 8 || apPass.length > 32) {
      throw LocalApiException.invalid(_errorMessages['invalid_ap_pass']!);
    }
    await _send(
      'POST',
      '/api/factory/init',
      body: <String, dynamic>{'local_key': localKey, 'ap_pass': apPass},
      timeout: const Duration(seconds: 8),
      sendKey: false,
    );
    this.localKey = localKey;
  }

  /// Yerel anahtarı **mevcut anahtarla** değiştirir (`POST /api/auth/rekey {local_key}`). Başarıda
  /// [localKey] yeni anahtara ayarlanır. Sunucudaki kayıtlı anahtar ayrıca `set_local_key` ile
  /// (backend) güncellenir; bu yöntem yalnızca cihaza yazar.
  Future<void> rekey(String newKey) async {
    if (!isValidLocalKey(newKey)) {
      throw LocalApiException.invalid(_errorMessages['invalid_key']!);
    }
    await _send(
      'POST',
      '/api/auth/rekey',
      body: <String, dynamic>{'local_key': newKey},
      timeout: const Duration(seconds: 8),
    );
    localKey = newKey;
  }

  /// Elimizdeki [localKey] cihaz tarafından kabul ediliyor mu (`GET /api/auth/check`)?
  /// `true`: kabul; `false`: anahtar yanlış (401). Kilit (423), kurulmamış cihaz (403) ve ağ hataları
  /// [LocalApiException] olarak fırlatılır.
  Future<bool> checkKey() async {
    try {
      await _send('GET', '/api/auth/check', timeout: const Duration(seconds: 4));
      return true;
    } on LocalApiException catch (e) {
      if (e.isUnauthorized) return false;
      rethrow;
    }
  }

  /// Doğrudan mod çocuk kilidi durumu (`GET /api/child-lock` -> `{"child_lock":bool}`). Hata veya
  /// alan yoksa **fırlatır** (hata "kilitsiz" sanılmaz).
  Future<bool> fetchChildLock() async {
    final res = await _send('GET', '/api/child-lock', timeout: const Duration(seconds: 4));
    final value = asBool(_json(res)['child_lock']);
    if (value == null) {
      throw const LocalApiException(
        statusCode: 502,
        code: 'bad_response',
        message: 'Cihaz çocuk kilidi durumunu bildirmedi.',
      );
    }
    return value;
  }

  /// Panoya bulut (MQTT) kimliğini yazar (`POST /api/mqtt/config {server, port, user, pass}`;
  /// `X-Device-Key` zorunlu). Kimlik sunucudan **tek seferlik** gelir (`ClaimResult.deviceCredential`,
  /// `EvCloudApiService.reissueDeviceMqttCredential`); parola **loglanmaz ve saklanmaz**. Cihaz
  /// kabul edince MQTT bağlantısını yenilemeye çalışır; bağlandığı `status` / cihaz listesiyle doğrulanır.
  /// Cihaz sınırları: sunucu adı geçerli ana makine, port 1..65535, kullanıcı ≤ 47, parola ≤ 63 bayt.
  Future<void> configureMqtt(DeviceMqttCredential credential) async {
    final host = credential.host.trim();
    final user = credential.username;
    final pass = credential.password;
    if (host.isEmpty || host.length > 253 || RegExp(r'[\s/\\?#@]').hasMatch(host)) {
      throw LocalApiException.invalid('Bulut sunucu adresi geçersiz.');
    }
    if (credential.port < 1 || credential.port > 65535) {
      throw LocalApiException.invalid('Bulut sunucu portu geçersiz.');
    }
    final userBytes = utf8.encode(user).length;
    final passBytes = utf8.encode(pass).length;
    if (userBytes < 1 || userBytes > 47) {
      throw LocalApiException.invalid('Bulut kullanıcı adı geçersiz.');
    }
    if (passBytes < 1 || passBytes > 63) {
      throw LocalApiException.invalid('Bulut parolası geçersiz.');
    }
    await _send(
      'POST',
      '/api/mqtt/config',
      body: credential.toLanConfigBody(),
      timeout: const Duration(seconds: 8),
    );
  }

  /// Doğrudan mod çocuk kilidi (`POST /api/child-lock {"enabled":bool}`; cihaz `queued` yanıtlar:
  /// uygulandığı bir sonraki `status` yoklamasında `child_lock` ile doğrulanır). 400/401/423 -> [LocalApiException].
  Future<bool> setChildLock(bool enabled) async {
    await _send('POST', '/api/child-lock', body: <String, dynamic>{'enabled': enabled});
    return true;
  }
}

/// [AutomationApiService.awaitWifiConnection] sonucu.
enum WifiConnectOutcome {
  /// Pano ev Wi-Fi'sine bağlandı (`wifi_connect_state: success`).
  success,

  /// Bağlanamadı (`failed`); neden [WifiConnectResult.reason] / [WifiConnectResult.message].
  failed,

  /// Süre doldu; durum hâlâ `connecting`/`idle`.
  timedOut,

  /// Deneme sırasında cihazla bağlantı koptu (pano AP'yi kapatmış olabilir): **belirsiz**. Telefonu
  /// ev ağına/internete alıp bulut cihaz listesinden (`online`) doğrulayın.
  lostContact,
}

class WifiConnectResult {
  const WifiConnectResult(this.outcome, {this.reason = 0, this.ipAddress, this.status});

  final WifiConnectOutcome outcome;

  /// Başarısızlıkta `wifi_err_reason_t` (0 = bilinmiyor / zaman aşımı).
  final int reason;

  /// Başarıda panonun ev ağındaki IP adresi.
  final String? ipAddress;

  /// Son okunan cihaz durumu.
  final DeviceStatus? status;

  bool get isSuccess => outcome == WifiConnectOutcome.success;

  /// Kullanıcıya gösterilebilir Türkçe açıklama.
  String get message {
    switch (outcome) {
      case WifiConnectOutcome.success:
        return 'Pano ev ağına bağlandı.';
      case WifiConnectOutcome.failed:
        return failureMessage(reason);
      case WifiConnectOutcome.timedOut:
        return 'Bağlantı zaman aşımına uğradı. Ağ adını ve şifreyi kontrol edip tekrar deneyin.';
      case WifiConnectOutcome.lostContact:
        return 'Panoyla bağlantı koptu. Pano ev ağına bağlanmış olabilir; telefonunuzu ev ağına '
            'alıp durumu kontrol edin.';
    }
  }

  /// ESP-IDF `wifi_err_reason_t` -> kullanıcı mesajı (yalnızca yaygın nedenler).
  static String failureMessage(int reason) {
    switch (reason) {
      case 2: // AUTH_EXPIRE
      case 15: // 4WAY_HANDSHAKE_TIMEOUT
      case 202: // AUTH_FAIL
      case 204: // HANDSHAKE_TIMEOUT
        return 'Wi-Fi şifresi hatalı görünüyor. Şifreyi kontrol edip tekrar deneyin.';
      case 201: // NO_AP_FOUND
        return 'Ağ bulunamadı. Ağ adını kontrol edin ve panonun menzilinde olduğundan emin olun.';
      case 0:
        return 'Bağlanılamadı (zaman aşımı). Ağ adını ve şifreyi kontrol edip tekrar deneyin.';
      default:
        return 'Bağlanılamadı (kod: $reason). Ağ adını ve şifreyi kontrol edip tekrar deneyin.';
    }
  }
}

/// Kapsam içinde oluşturulan dart:io [HttpClient]'a `connectionTimeout` verir (PF-36). Önceki geçersiz kılmalar
/// (testlerin `HttpOverrides.global`'ı, `HttpOverrides.runZoned`) korunur: istemci önce onlarla oluşturulur,
/// sonra süre sınırı atanır.
class _ConnectionTimeoutOverrides extends HttpOverrides {
  _ConnectionTimeoutOverrides(this._timeout) : _previous = HttpOverrides.current;

  final Duration _timeout;
  final HttpOverrides? _previous;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      (_previous?.createHttpClient(context) ?? super.createHttpClient(context))..connectionTimeout = _timeout;
}

/// Bir [AutomationApiService] örneğinin açık pano ağı kirası: eşzamanlı / iç içe çağrılar TEK kirayı paylaşır;
/// son kullanıcı bitince kira bırakılır.
class _BoardScope {
  _BoardScope(this.host, this.lease);

  final String host;
  final Future<BoardNetworkLease> lease;

  /// Kirayı kullanan açık çağrı sayısı.
  int users = 0;
}
