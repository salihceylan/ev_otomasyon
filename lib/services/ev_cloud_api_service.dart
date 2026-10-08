import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../models/api_models.dart';
import '../models/cloud_models.dart';
import '../models/install_template_models.dart';
import '../models/json_utils.dart';
import '../models/safety_models.dart';
import '../models/scheduled_rule_model.dart';
import 'alarm_watch/refresh_gate.dart';
import 'api_exception.dart';
import 'clock.dart';

/// Refresh sonrası yeni belirteçleri kalıcı depolamaya yazar. **Beklenir**: yeniden denenen
/// istek, yeni (dönen) refresh token kaydedildikten sonra gönderilir. Bekleme **en çok 3 sn**'dir
/// (PF-02): takılı bir yazım tek-uçuş yenilemeyi ve bekleyen tüm 401 yeniden denemelerini sonsuza dek
/// bloklamaz; belirteçler zaten bellekte olduğundan yazım arka planda sürer (geç sonucu/hatası yutulur).
typedef TokenRefreshedCallback = FutureOr<void> Function(String accessToken, String? refreshToken);

/// Refresh token kalıcı olarak reddedildi / oturum bitti (tek merkezden; her oturum için bir kez).
typedef SessionExpiredCallback = void Function(SessionEndReason reason);

/// `403 GUEST_EXPIRED`: misafir süresi doldu. [homeId] isteğin ilgili olduğu ev (biliniyorsa).
typedef GuestExpiredCallback = void Function(String? homeId);

/// `403 FORBIDDEN` (misafir dışı yetki reddi): rol değişmiş olabilir; ev listesi yenilenmelidir.
typedef ForbiddenCallback = void Function(String? homeId);

/// Tek bir `_call`'ın toplam süre bütçesi (PF-09). Bütçe dolunca bekleyen çağırana ağ hatası döner ve
/// [expired] kalkar: terk edilen iç koşu (`_callOnce`) artık refresh başlatmaz ve isteği yeniden göndermez
/// (çağıran hata aldıktan sonra bir POST'un "hayalet" ikinci kez gitmesi engellenir).
class _Budget {
  _Budget(this.limit);

  final Duration limit;
  bool expired = false;

  /// Bütçe aşımı hatası: `_sendRaw` zaman aşımıyla AYNI biçimde ağ hatası (`cause` = [TimeoutException]);
  /// arayüz "sunucu zamanında yanıt vermedi" ile "internet yok"u ayırt edebilir.
  ApiException exceeded() => ApiException.network(
        cause: TimeoutException('REST çağrısı toplam süre bütçesini aştı', limit),
        message: 'Sunucu zamanında yanıt vermedi. Tekrar deneyin.',
      );
}

/// Bulut REST istemcisi (CONTRACTS §1).
///
/// * Singleton **değildir**; kurucudan `baseUrl` / `http.Client` / `Clock` alır (test için örneklenebilir).
/// * Tüm yanıtlar merkezi `_decode` ile çözülür; hatalar [ApiException]'dır
///   (`status`, `code`, `message`, `retryAfter`).
/// * Yalnızca **401**'de ve **tek-uçuşlu** (aynı anda en fazla bir refresh) belirteç yenilenir; aynı
///   istek en fazla bir kez yeniden denenir. **403 hiçbir zaman refresh tetiklemez.**
/// * Ağ hatası / 5xx / 429 sırasında oturum **korunur**; yalnızca refresh'in kalıcı reddi
///   [onSessionExpired]'ı tetikler.
/// * Her çağrının TOPLAM süresi sınırlıdır (istek zaman aşımı + 4 sn; komutlarda 10 sn): 401 yolundaki
///   istek + refresh + yeniden deneme süreleri ardışık birikmez (PF-09).
/// * Oturum nesli sayacı: çıkıştan sonra gelen refresh yanıtı yazılmaz.
/// * Gömülü sır (yönetici API anahtarı vb.) **yoktur**; yetki yalnızca JWT ile sağlanır.
class EvCloudApiService {
  EvCloudApiService({
    String? baseUrl,
    http.Client? client,
    this._clock = const SystemClock(),
  })  : baseUrl = baseUrl ?? AppConfig.current.apiBaseUrl,
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  /// REST kök adresi (`.../api`); uçlar `/v1/...` ile çağrılır.
  String baseUrl;

  final http.Client _client;
  final bool _ownsClient;
  final Clock _clock;

  String? _authToken;
  String? _refreshToken;
  int _generation = 0;
  ServiceSessionInfo? _serviceSession;
  Future<bool>? _refreshInFlight;
  bool _disposed = false;

  /// `_call` toplam süre bütçesi = istek başına zaman aşımı + bu pay (PF-09): GET için 10 + 4 = 14 sn
  /// (eskiden 401 yolunda 10+10+10 sn).
  static const Duration _callBudgetSlack = Duration(seconds: 4);

  /// Komut çağrılarının (`sendCommand`/`controlEndpoint`/`setChildLock`) toplam bütçesi: komut hattının toplam
  /// üst sınırıyla (`CommandPipeline.maxTotal` = 10 sn, CONTRACTS §5) uyumlu; REST çağrısı, komut geri
  /// alındıktan sonra uzun süre "terk edilmiş" olarak yaşamaz (eskiden 8+10+8 sn).
  static const Duration _commandBudget = Duration(seconds: 10);

  /// Refresh sonrası belirteç yazımı ([onTokenRefreshed]) için bekleme üst sınırı (PF-02).
  static const Duration _tokenPersistLimit = Duration(seconds: 3);

  /// Yenilenen belirteçleri kalıcı depolamaya yazar (await edilir).
  TokenRefreshedCallback? onTokenRefreshed;

  /// Refresh kalıcı reddedilince / servis oturumu bitince çağrılır.
  SessionExpiredCallback? onSessionExpired;

  /// Süreç geneli yenileme kapısı (Android arka plan alarm izleyicisiyle aynı oturum ailesi paylaşılırken). Verilirse
  /// yenileme kapı tutularak yapılır ve önce [readStoredRefreshToken] ile depodaki EN SON token benimsenir: diğer
  /// isolate token'ı bu arada döndürmüş olabilir; eski token'ın yeniden kullanımı sunucuda bütün oturum ailesini iptal
  /// eder (CONTRACTS §1.2). `null` (varsayılan): davranış eskisiyle aynı.
  RefreshGate? refreshGate;

  /// Güvenli depodaki güncel refresh token (yalnız [refreshGate] ile kullanılır).
  Future<String?> Function()? readStoredRefreshToken;

  /// Depoda olduğunu en son BİLDİĞİMİZ refresh token (depodan geri yükleme, giriş ve BAŞARILI kalıcı yazımda güncellenir).
  /// Depo yalnız bundan FARKLIYSA (başka isolate döndürmüş) benimsenir: kendi kalıcı yazımımız başarısız olduysa depoda
  /// eski (kullanılmış) token kalır ve onu geri almak sunucuda bütün oturum ailesini iptal ettirirdi.
  String? _storedRefreshSeen;

  /// `true` (arka plan izleyicisi): depoda token yoksa kullanıcı çıkış yapmıştır; yenileme YAPILMAZ ve oturum biter
  /// (silinmiş oturumun belirteçleri yeniden üretilip depoya yazılmasın). Ön plan uygulamasında `false`.
  bool storedSessionIsAuthoritative = false;

  /// Kapı tutulurken beklenecek kalıcı yazımın en uzun süresi: yazım bitmeden kapı bırakılırsa diğer isolate eski
  /// token'ı okuyabilir.
  static const Duration _gatedPersistLimit = Duration(seconds: 10);

  /// `GUEST_EXPIRED` alınınca çağrılır.
  GuestExpiredCallback? onGuestExpired;

  /// Misafir dışı `403 FORBIDDEN` alınınca çağrılır.
  ForbiddenCallback? onForbidden;

  // ---------------------------------------------------------------------------
  // Oturum durumu
  // ---------------------------------------------------------------------------

  String? get authToken => _authToken;
  String? get currentRefreshToken => _refreshToken;

  /// Her yeni oturumda / çıkışta artar (gecikmeli refresh yanıtının yazılmasını engeller).
  int get sessionGeneration => _generation;

  /// Yerel belirteç var mı (erişim veya yenileme).
  bool get hasSession => _authToken != null || _refreshToken != null;

  /// Aktif servis PIN oturumu (varsa).
  ServiceSessionInfo? get serviceSession => _serviceSession;
  bool get isServiceSession => _serviceSession != null;

  /// Kayıtlı belirteci geri yükler (oturum nesli artmaz).
  void setAuthToken(String? token) {
    _authToken = (token == null || token.isEmpty) ? null : token;
  }

  void setRefreshToken(String? token) {
    _refreshToken = (token == null || token.isEmpty) ? null : token;
    _storedRefreshSeen = _refreshToken; // depodan geri yüklenen değer
  }

  /// Yeni bir oturum başlatır (giriş sonrası). Önceki oturumdan kalan işlemler geçersiz olur.
  void beginSession({required String accessToken, String? refreshToken}) {
    _generation++;
    _serviceSession = null;
    _authToken = accessToken;
    _refreshToken = (refreshToken == null || refreshToken.isEmpty) ? null : refreshToken;
    _storedRefreshSeen = _refreshToken; // giriş belirteçleri hemen depoya yazılır
  }

  /// Kayıtlı servis PIN oturumunu geri yükler (uygulama yeniden açıldığında).
  void restoreServiceSession({required String accessToken, required ServiceSessionInfo info}) {
    _generation++;
    _authToken = accessToken;
    _refreshToken = null;
    _serviceSession = info;
  }

  /// Yerel oturumu siler (çıkış). Uçuştaki bir refresh'in sonucu artık yazılmaz.
  void clearSession() {
    _generation++;
    _authToken = null;
    _refreshToken = null;
    _storedRefreshSeen = null;
    _serviceSession = null;
  }

  void dispose() {
    _disposed = true;
    if (_ownsClient) _client.close();
  }

  // ---------------------------------------------------------------------------
  // HTTP çekirdeği
  // ---------------------------------------------------------------------------

  static String _seg(String value) => Uri.encodeComponent(value);

  Uri _uri(String path, [Map<String, String>? query]) {
    final uri = Uri.parse('$baseUrl$path');
    return (query == null || query.isEmpty) ? uri : uri.replace(queryParameters: query);
  }

  Future<http.Response> _sendRaw(
    String method,
    Uri uri, {
    Object? body,
    required bool auth,
    required Duration timeout,
  }) async {
    if (_disposed) throw ApiException.network(message: 'İstemci kapatıldı.');
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (auth && _authToken != null) 'Authorization': 'Bearer $_authToken',
    };
    final encoded = body == null ? null : jsonEncode(body);
    try {
      final Future<http.Response> future;
      switch (method) {
        case 'GET':
          future = _client.get(uri, headers: headers);
        case 'POST':
          future = _client.post(uri, headers: headers, body: encoded ?? '{}');
        case 'PUT':
          future = _client.put(uri, headers: headers, body: encoded ?? '{}');
        case 'PATCH':
          future = _client.patch(uri, headers: headers, body: encoded ?? '{}');
        case 'DELETE':
          future = _client.delete(uri, headers: headers, body: encoded);
        default:
          throw ArgumentError('Desteklenmeyen HTTP yöntemi: $method');
      }
      return await future.timeout(timeout);
    } on TimeoutException catch (e) {
      throw ApiException.network(cause: e, message: 'Sunucu zamanında yanıt vermedi. Tekrar deneyin.');
    } on IOException catch (e) {
      throw ApiException.network(cause: e);
    } on http.ClientException catch (e) {
      throw ApiException.network(cause: e);
    }
  }

  Map<String, dynamic> _parseBody(http.Response res) {
    if (res.bodyBytes.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
      final map = asMap(decoded);
      if (map != null) return map;
      return <String, dynamic>{'data': decoded};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  String? _codeOf(http.Response res) => asNonEmptyString(_parseBody(res)['code']);

  /// 5xx yanıtlarında sunucu mesajının kullanıcıya gösterilmesine izin verilen kodlar: sunucu bu
  /// iki hata için mesajı bilerek açar (e-posta/SMS gönderilemedi, özellik yapılandırılmamış);
  /// diğer her 5xx'te genel mesaj kullanılır (iç ayrıntı sızmaz).
  static const Set<String> _exposedServerErrorCodes = <String>{
    'DELIVERY_FAILED',
    'SERVICE_UNAVAILABLE',
  };

  /// Kullanıcıya gösterilecek sunucu mesajı için üst uzunluk sınırı.
  static const int _maxServerMessageLength = 300;

  ApiException _toException(http.Response res, Map<String, dynamic> body) {
    final status = res.statusCode;
    final code = asNonEmptyString(body['code']);
    final serverMessage = asNonEmptyString(body['message']) ?? asNonEmptyString(body['error']);
    // 5xx: sunucunun iç mesajı gösterilmez (sözleşme: genel mesaj); yalnızca bilerek açılan kodlar.
    final showServerMessage = serverMessage != null &&
        (status < 500 || (code != null && _exposedServerErrorCodes.contains(code)));
    // Faz 2 kodları (gaz kısıtı, alarm kipi, yapılandırma kuyruğu): uygulamanın kendi metni [ApiException.clientMessages].
    final clientMessage = (status >= 400 && status < 500 && code != null) ? ApiException.clientMessages[code] : null;
    final message = clientMessage ??
        (!showServerMessage
            ? ApiException.defaultMessageFor(status)
            : (serverMessage.length > _maxServerMessageLength
                ? serverMessage.substring(0, _maxServerMessageLength)
                : serverMessage));
    Duration? retryAfter;
    String? header;
    for (final entry in res.headers.entries) {
      if (entry.key.toLowerCase() == 'retry-after') header = entry.value;
    }
    final headerSeconds = header == null ? null : int.tryParse(header.trim());
    final bodySeconds = asInt(body['retry_after'] ?? body['retryAfter']);
    final seconds = headerSeconds ?? bodySeconds;
    if (seconds != null && seconds > 0) retryAfter = Duration(seconds: seconds);
    final resendSeconds = asInt(body['resend_after'] ?? body['resendAfter']);
    final remaining = asInt(body['remaining_attempts'] ?? body['remainingAttempts']);
    final offlineRaw = asList(body['offline_devices'] ?? body['offlineDevices']);
    return ApiException(
      statusCode: status,
      code: code,
      message: message,
      retryAfter: retryAfter,
      resendAfter: (resendSeconds != null && resendSeconds > 0) ? Duration(seconds: resendSeconds) : null,
      remainingAttempts: (remaining != null && remaining >= 0) ? remaining : null,
      deviceOnline: asBool(body['device_online'] ?? body['deviceOnline']),
      offlineDevices: <String>[
        for (final item in offlineRaw ?? const <dynamic>[])
          if (asNonEmptyString(item) != null) asNonEmptyString(item)!,
      ],
      // 4xx gövdesi (koda özgü ek alanlar; ör. SOLE_OWNER ev listesi). 5xx'te iç ayrıntı taşınmaz.
      details: status < 500 ? body : null,
    );
  }

  /// 2xx -> gövde; aksi halde [ApiException]. `success:false` taşıyan 2xx de hatadır.
  Map<String, dynamic> _decode(http.Response res) {
    final body = _parseBody(res);
    if (res.statusCode >= 200 && res.statusCode < 300) {
      if (body['success'] == false) {
        throw ApiException(
          statusCode: res.statusCode,
          code: asNonEmptyString(body['code']),
          message: asNonEmptyString(body['message']) ?? 'İşlem tamamlanamadı.',
        );
      }
      return body;
    }
    throw _toException(res, body);
  }

  /// Kimlik doğrulamalı/doğrulamasız tek çağrı noktası.
  ///
  /// **Toplam süre bütçesi (PF-09):** 401 yolunda istek + refresh + yeniden deneme süreleri eskiden ARDIŞIK
  /// birikirdi (GET 10+10+10 sn, komut 8+10+8 sn); `_sendRaw`'daki zaman aşımı yalnız tek isteği sınırlar.
  /// Artık çağrının TAMAMI en çok [totalBudget] sürer (varsayılan: [timeout] + 4 sn); dolunca çağırana ağ
  /// hatası ([ApiException.isNetwork], `cause` = [TimeoutException]) döner ve oturum KORUNUR. Süresi dolan iç
  /// koşu iptal edilemez ama refresh başlatmaz ve isteği yeniden göndermez ([_Budget]); uçuştaki refresh
  /// sürer ve dönen belirteçler yine uygulanır (rotasyon kaybolmaz).
  Future<Map<String, dynamic>> _call(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    bool auth = true,
    String? homeId,
    Duration timeout = const Duration(seconds: 10),
    Duration? totalBudget,
  }) {
    final budget = _Budget(totalBudget ?? timeout + _callBudgetSlack);
    return _clock.bound<Map<String, dynamic>>(
      _callOnce(method, path, budget, body: body, query: query, auth: auth, homeId: homeId, timeout: timeout),
      budget.limit,
      () {
        budget.expired = true;
        throw budget.exceeded();
      },
    );
  }

  /// [_call]'ın asıl gövdesi (istek + 401'de tek-uçuş refresh + tek yeniden deneme). Çağıranın bütçesi dolduysa
  /// ([_Budget.expired]) refresh ve yeniden deneme gönderimi YAPILMAZ.
  Future<Map<String, dynamic>> _callOnce(
    String method,
    String path,
    _Budget budget, {
    required Object? body,
    required Map<String, String>? query,
    required bool auth,
    required String? homeId,
    required Duration timeout,
  }) async {
    final uri = _uri(path, query);

    if (auth) {
      // Yerel servis oturumu süresi dolmuşsa sunucuya gitmeden oturumu kapat.
      final session = _serviceSession;
      if (session != null && session.isExpiredAt(_clock.now())) {
        _expire(SessionEndReason.serviceSessionExpired);
        throw const ApiException(
          statusCode: 401,
          code: 'SERVICE_SESSION_EXPIRED',
          message: 'Servis oturumunuzun süresi doldu.',
        );
      }
    }

    final generation = _generation;
    var res = await _sendRaw(method, uri, body: body, auth: auth, timeout: timeout);

    if (auth && res.statusCode == 401) {
      final code = _codeOf(res);
      if (_serviceSession != null || code == 'SERVICE_SESSION_EXPIRED') {
        // Servis oturumunun refresh'i yoktur: oturum biter.
        _expire(SessionEndReason.serviceSessionExpired);
      } else if (_refreshToken != null && generation == _generation) {
        // Terk edilen (bütçesi dolan) iç koşu refresh başlatmaz: çağıran zaten ağ hatası aldı.
        if (budget.expired) throw budget.exceeded();
        // Yalnızca 401'de, tek-uçuş refresh; sonra aynı istek en fazla bir kez yeniden denenir.
        final refreshed = await _refreshSingleFlight(code == 'INVALID_TOKEN'
            ? SessionEndReason.invalidToken
            : SessionEndReason.refreshRejected);
        if (refreshed && generation != _generation) {
          // Refresh sırasında oturum değişti (çıkış/yeni giriş): isteği yeniden deneme.
          throw _toException(res, _parseBody(res));
        }
        if (refreshed) {
          // Bütçe refresh sürerken dolduysa isteği YENİDEN GÖNDERME (hayalet gönderim: çağıran hata aldı).
          if (budget.expired) throw budget.exceeded();
          res = await _sendRaw(method, uri, body: body, auth: auth, timeout: timeout);
        }
      } else if (generation == _generation) {
        _expire(SessionEndReason.noRefreshToken);
      }
    }

    if (res.statusCode == 403) {
      final code = _codeOf(res);
      if (code == 'GUEST_EXPIRED') {
        onGuestExpired?.call(homeId);
      } else {
        onForbidden?.call(homeId);
      }
    }

    return _decode(res);
  }

  void _expire(SessionEndReason reason) {
    if (_authToken == null && _refreshToken == null && _serviceSession == null) return;
    _generation++;
    _authToken = null;
    _refreshToken = null;
    _serviceSession = null;
    onSessionExpired?.call(reason);
  }

  // ---------------------------------------------------------------------------
  // Belirteç yenileme (tek-uçuş)
  // ---------------------------------------------------------------------------

  /// Mevcut refresh token ile oturumu yeniler. Aynı anda gelen çağrılar **tek** istekte birleşir
  /// (refresh token her kullanımda döner; paralel iki kullanım "yeniden kullanım" sayılırdı).
  ///
  /// `true`: yenilendi. `false`: refresh token yok / kalıcı reddedildi (oturum kapandı ve
  /// [onSessionExpired] çağrıldı) / yenileme sırasında oturum değişti. Ağ hatası ve 5xx/429'da
  /// oturum korunur ve [ApiException] fırlatılır.
  Future<bool> refreshSession() => _refreshSingleFlight(SessionEndReason.refreshRejected);

  Future<bool> _refreshSingleFlight(SessionEndReason rejectionReason) {
    final existing = _refreshInFlight;
    if (existing != null) return existing;
    final future = _doRefresh(rejectionReason);
    _refreshInFlight = future;
    future.whenComplete(() {
      if (identical(_refreshInFlight, future)) _refreshInFlight = null;
    }).ignore();
    return future;
  }

  Future<bool> _doRefresh(SessionEndReason rejectionReason) {
    final gate = refreshGate;
    if (gate == null) return _doRefreshNow(rejectionReason);
    return gate.run(() async {
      final reader = readStoredRefreshToken;
      if (reader != null && _refreshToken != null) {
        String? stored;
        var readOk = false;
        try {
          stored = await reader();
          readOk = true;
        } catch (_) {
          // Depo okunamadı: bellekteki token ile sürdürülür.
        }
        if (readOk && (stored == null || stored.isEmpty) && storedSessionIsAuthoritative) {
          _expire(rejectionReason); // çıkış yapılmış: yenilenmez
          return false;
        }
        // Diğer isolate token'ı döndürdüyse (depo son bildiğimizden FARKLI) yenisi benimsenir; depo boşsa (çıkış) ya da
        // depoda hâlâ son bildiğimiz değer varsa (kendi kalıcı yazımımız başarısız olmuş olabilir) bellekteki sürer.
        if (stored != null && stored.isNotEmpty && _refreshToken != null && stored != _storedRefreshSeen) {
          _refreshToken = stored;
          _storedRefreshSeen = stored;
        }
      }
      final ok = await _doRefreshNow(rejectionReason, waitPersist: true);
      return ok;
    });
  }

  Future<bool> _doRefreshNow(SessionEndReason rejectionReason, {bool waitPersist = false}) async {
    final generation = _generation;
    final token = _refreshToken;
    if (token == null) return false;

    final res = await _sendRaw(
      'POST',
      _uri('/v1/auth/refresh'),
      body: <String, dynamic>{'refresh_token': token},
      auth: false,
      timeout: const Duration(seconds: 10),
    );

    // Çıkış / yeni giriş oldu: bu yanıt eski oturuma aittir, yazılmaz.
    if (generation != _generation) return false;

    final status = res.statusCode;
    if (status >= 200 && status < 300) {
      final body = _parseBody(res);
      final payload = asMap(body['data']) ?? body;
      final access = asNonEmptyString(payload['access_token'] ?? payload['token']);
      if (access == null) {
        throw const ApiException(
          statusCode: 502,
          code: 'BAD_RESPONSE',
          message: 'Sunucu geçersiz bir oturum yanıtı verdi.',
        );
      }
      // Dönen (rotasyon) yeni refresh token; yoksa eskisi geçerli kalır.
      final newRefresh = asNonEmptyString(payload['refresh_token']) ?? token;
      _authToken = access;
      _refreshToken = newRefresh;
      final callback = onTokenRefreshed;
      if (callback != null) {
        // Kalıcı yazım BEKLENİR ama en çok [_tokenPersistLimit] (PF-02): takılı güvenli depo, tek-uçuş yenilemeyi
        // ve bekleyen TÜM 401 yeniden denemelerini sonsuza dek bloklamasın. Belirteçler zaten bellekte; yazım
        // arka planda sürer (süreyi aşan yazımın geç sonucu/hatası yutulur; süre içinde biten yazımın hatası
        // aynen iletilir).
        var persisted = false;
        await _clock.bound<void>(
          Future<void>.sync(() async {
            await callback(access, newRefresh);
            persisted = true;
          }),
          waitPersist ? _gatedPersistLimit : _tokenPersistLimit,
          () {},
        );
        if (generation != _generation) return false; // depolama beklenirken çıkış yapıldı
        if (persisted) _storedRefreshSeen = newRefresh; // depoda artık bu var
      } else {
        _storedRefreshSeen = newRefresh; // kalıcı yazım yok (test/yalın istemci): bellek = kaynak
      }
      return true;
    }

    // Geçici hata: oturum KORUNUR.
    if (status >= 500 || status == 429 || status == 408) {
      throw _toException(res, _parseBody(res));
    }

    // 400/401/403/404 ...: refresh token kalıcı olarak reddedildi.
    _expire(rejectionReason);
    return false;
  }

  // ---------------------------------------------------------------------------
  // Yanıt yardımcıları
  // ---------------------------------------------------------------------------

  /// `data` (Map) varsa onu, yoksa gövdenin kendisini döndürür.
  Map<String, dynamic> _data(Map<String, dynamic> body) => asMap(body['data']) ?? body;

  /// Liste: `data` doğrudan liste ya da `data[key]` / `body[key]`.
  List<dynamic> _list(Map<String, dynamic> body, [String? key]) {
    final data = body['data'];
    if (data is List) return data;
    final map = asMap(data);
    if (key != null && map != null && map[key] is List) return map[key] as List;
    if (key != null && body[key] is List) return body[key] as List;
    return const <dynamic>[];
  }

  T _parseOrThrow<T>(T Function() parse) {
    try {
      return parse();
    } on FormatException {
      throw const ApiException(
        statusCode: 502,
        code: 'BAD_RESPONSE',
        message: 'Sunucu beklenmeyen bir yanıt verdi.',
      );
    }
  }

  /// Giriş/kayıt/OTP yanıtındaki belirteçleri yeni oturum olarak uygular ve yükü döndürür.
  Map<String, dynamic> _applyAuth(Map<String, dynamic> body, {bool requireTokens = true}) {
    final payload = _data(body);
    final access = asNonEmptyString(payload['access_token'] ?? payload['token']);
    if (access == null) {
      if (requireTokens) {
        throw const ApiException(
          statusCode: 502,
          code: 'BAD_RESPONSE',
          message: 'Sunucu geçersiz bir oturum yanıtı verdi.',
        );
      }
      return payload;
    }
    beginSession(accessToken: access, refreshToken: asNonEmptyString(payload['refresh_token']));
    return payload;
  }

  // ---------------------------------------------------------------------------
  // Kimlik doğrulama
  // ---------------------------------------------------------------------------

  /// E-posta/telefon + parola ile giriş. Parola **kırpılmaz**.
  Future<Map<String, dynamic>> login(String identifier, String password) async {
    final body = await _call(
      'POST',
      '/v1/auth/login',
      body: <String, dynamic>{'identifier': identifier.trim(), 'password': password},
      auth: false,
    );
    return _applyAuth(body);
  }

  /// Yeni kullanıcı kaydı.
  Future<Map<String, dynamic>> register({
    required String fullName,
    required String email,
    required String password,
    String? phone,
  }) async {
    final body = await _call(
      'POST',
      '/v1/auth/register',
      body: <String, dynamic>{
        'full_name': fullName.trim(),
        'email': email.trim(),
        'password': password,
        if (phone != null && phone.trim().isNotEmpty) 'phone': phone.trim(),
      },
      auth: false,
    );
    return _applyAuth(body);
  }

  /// Google ile giriş: **yalnızca doğrulanmış kimlik jetonu** gönderilir; `email`/kimlik alanlarına
  /// sunucu güvenmez (CONTRACTS §1.2).
  Future<Map<String, dynamic>> loginWithGoogle({required String idToken}) async {
    final body = await _call(
      'POST',
      '/v1/auth/google',
      body: <String, dynamic>{'id_token': idToken},
      auth: false,
    );
    return _applyAuth(body);
  }

  /// Apple ile giriş: kimlik jetonu zorunlu; [fullName] yalnızca ilk girişte Apple'ın verdiği
  /// görünen ad (jetonda bulunmaz) ve doğrulama için kullanılmaz. [nonce]: Apple isteğine
  /// verilen **ham** nonce (verilirse sunucu jetondaki SHA-256 nonce ile eşleştirir; tekrar
  /// oynatma savunması).
  Future<Map<String, dynamic>> loginWithApple({
    required String identityToken,
    String? fullName,
    String? nonce,
  }) async {
    final body = await _call(
      'POST',
      '/v1/auth/apple',
      body: <String, dynamic>{
        'identity_token': identityToken,
        if (fullName != null && fullName.trim().isNotEmpty) 'full_name': fullName.trim(),
        if (nonce != null && nonce.isNotEmpty) 'nonce': nonce,
      },
      auth: false,
    );
    return _applyAuth(body);
  }

  /// Telefon OTP kodu gönder. Yanıt: [CodeChallenge] (`expires_in`, `resend_after`). Çok sık
  /// istekte `429 RATE_LIMITED` ([ApiException.resendAfter] / [ApiException.retryAfter]); gönderim
  /// sağlayıcısı yoksa `503 DELIVERY_FAILED`.
  Future<CodeChallenge> sendPhoneOtp(String phone) async {
    final body = await _call(
      'POST',
      '/v1/auth/otp/send',
      body: <String, dynamic>{'phone': phone.trim()},
      auth: false,
    );
    return CodeChallenge.fromJson(_data(body));
  }

  /// Telefon OTP kodunu doğrula ve giriş yap. Hatalı kodda `401 INVALID_CREDENTIALS` ve
  /// [ApiException.remainingAttempts]; deneme hakkı bitince `429` ([ApiException.retryAfter]).
  Future<Map<String, dynamic>> verifyPhoneOtp(String phone, String code) async {
    final body = await _call(
      'POST',
      '/v1/auth/otp/verify',
      body: <String, dynamic>{'phone': phone.trim(), 'code': code.trim()},
      auth: false,
    );
    return _applyAuth(body);
  }

  /// Şifre sıfırlama talebi: 6 haneli kod + tek kullanımlık bağlantı e-postası. Hesap var olsun
  /// ya da olmasın aynı yanıt döner (varlık sızmaz). Yanıt: [CodeChallenge] (`expires_in`,
  /// `resend_after`); e-posta gönderilemezse `503 DELIVERY_FAILED`.
  Future<CodeChallenge> forgotPassword(String identifier) async {
    final body = await _call(
      'POST',
      '/v1/auth/forgot-password',
      body: <String, dynamic>{'identifier': identifier.trim()},
      auth: false,
    );
    return CodeChallenge.fromJson(_data(body));
  }

  /// OTP kodu **veya** sihirli bağlantı belirteci ile yeni şifre. Yeni parola **kırpılmaz**.
  /// Kodla sıfırlamada [identifier] (e-posta/telefon) zorunludur; bağlantı [token]'ı ile
  /// sıfırlamada gerekmez. Yanıt belirteç taşıyorsa oturum otomatik başlatılır. Hatalı kodda
  /// `400 VALIDATION` + [ApiException.remainingAttempts]; süresi dolmuş/kullanılmış bağlantıda
  /// `400`/`410`.
  Future<Map<String, dynamic>> resetPassword({
    String? identifier,
    String? code,
    String? token,
    required String newPassword,
  }) async {
    final hasToken = token != null && token.trim().isNotEmpty;
    final hasCode = code != null && code.trim().isNotEmpty;
    if (!hasToken && !hasCode) {
      throw ApiException.validation('Doğrulama kodu veya bağlantı gerekli.');
    }
    if (!hasToken && (identifier == null || identifier.trim().isEmpty)) {
      throw ApiException.validation('E-posta veya telefon gerekli.');
    }
    final body = await _call(
      'POST',
      '/v1/auth/reset-password',
      body: <String, dynamic>{
        if (identifier != null && identifier.trim().isNotEmpty) 'identifier': identifier.trim(),
        if (hasCode) 'code': code.trim(),
        if (hasToken) 'token': token.trim(),
        'new_password': newPassword,
      },
      auth: false,
    );
    return _applyAuth(body, requireTokens: false);
  }

  /// Sunucunun giriş yöntemi yetenekleri (`GET /auth/capabilities`, **kimliksiz**; UYELIK-04):
  /// `{sms_otp, google, apple}`. Eski sunucuda uç yoktur (`404`): [ApiException] fırlatılır ve çağıran bunu
  /// "yetenek yok" sayar (fail-closed). Kimliksiz uç olduğundan 401 refresh / oturum sonu tetiklemez.
  Future<AuthCapabilities> fetchAuthCapabilities() async {
    final body = await _call(
      'GET',
      '/v1/auth/capabilities',
      auth: false,
      timeout: const Duration(seconds: 8),
    );
    return AuthCapabilities.fromJson(_data(body));
  }

  /// Sihirli bağlantı ile tek seferlik giriş (POST; GET ile oturum açılmaz).
  Future<Map<String, dynamic>> magicLogin(String token) async {
    final body = await _call(
      'POST',
      '/v1/auth/magic-login',
      body: <String, dynamic>{'token': token.trim()},
      auth: false,
    );
    return _applyAuth(body);
  }

  /// Mevcut parola ile parola değiştirir (`POST /auth/change-password`; servis oturumu ✖).
  ///
  /// Sunucu **diğer tüm cihazların** oturumlarını kapatır ve bu cihaz için **yeni belirteçler**
  /// döndürür: yeni oturum otomatik uygulanır ([sessionGeneration] artar) ve dönen yük
  /// (`user`, `homes`) verilir. Yanlış mevcut parolada `400 INVALID_CREDENTIALS`. Parolalar
  /// **kırpılmaz**.
  Future<Map<String, dynamic>> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    if (isServiceSession) throw ApiException.forbidden();
    if (currentPassword.isEmpty) throw ApiException.validation('Mevcut parola zorunludur.');
    if (newPassword.isEmpty) throw ApiException.validation('Yeni parola zorunludur.');
    final generation = _generation;
    final body = await _call(
      'POST',
      '/v1/auth/change-password',
      body: <String, dynamic>{
        'current_password': currentPassword,
        'new_password': newPassword,
      },
    );
    // İstek sürerken çıkış / başka kullanıcıyla giriş olduysa dönen belirteçler ESKİ oturuma aittir:
    // uygulanmaz (yeni oturumun belirteçleri ezilmez, çıkış yapılmış istemciye belirteç yazılmaz).
    if (generation != _generation) return _data(body);
    return _applyAuth(body);
  }

  /// Tüm cihazlardaki oturumları sonlandırır (`POST /auth/logout-all`; servis oturumu ✖).
  /// Başarıda bu cihazın yerel oturumu da silinir. Hata (ağ/5xx) **fırlatılır ve yerel oturum
  /// korunur**: kullanıcı işlemin gerçekleşmediğini bilmelidir.
  Future<void> logoutAll() async {
    if (isServiceSession) throw ApiException.forbidden();
    final generation = _generation;
    await _call('POST', '/v1/auth/logout-all');
    // İstek sürerken başka bir oturum açıldıysa (farklı kullanıcı) o oturum silinmez.
    if (generation == _generation) clearSession();
  }

  /// Çıkış: **önce yerel oturum silinir**, sonra (en iyi çaba) sunucuda refresh token iptal edilir.
  Future<void> logout() async {
    final refresh = _refreshToken;
    final access = _authToken;
    clearSession();
    if (refresh != null) {
      await revokeRefreshToken(refresh, accessToken: access);
    }
  }

  /// Verilen refresh token'ı sunucuda iptal eder (mevcut oturumdan bağımsız; asla fırlatmaz).
  Future<bool> revokeRefreshToken(String refreshToken, {String? accessToken}) async {
    try {
      final res = await _sendRaw(
        'POST',
        _uri('/v1/auth/logout'),
        body: <String, dynamic>{'refresh_token': refreshToken},
        auth: false,
        timeout: const Duration(seconds: 5),
      );
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// 6 haneli servis PIN'i ile **tek eve kapsamlı** 2 saatlik servis oturumu (CONTRACTS §1.3).
  /// Refresh token yoktur; süre [ServiceSessionInfo.expiresAt] ile izlenir.
  Future<ServiceSessionInfo> serviceLogin(String servicePin, {String? technicianName}) async {
    final body = await _call(
      'POST',
      '/v1/auth/service-login',
      body: <String, dynamic>{
        'service_pin': servicePin.trim(),
        if (technicianName != null && technicianName.trim().isNotEmpty)
          'technician_name': technicianName.trim(),
      },
      auth: false,
    );
    final payload = _data(body);
    final access = asNonEmptyString(payload['access_token'] ?? payload['token']);
    final home = asMap(payload['home']);
    final homeId = asNonEmptyString(home?['id'] ?? payload['home_id']);
    if (access == null || homeId == null) {
      throw const ApiException(
        statusCode: 502,
        code: 'BAD_RESPONSE',
        message: 'Sunucu geçersiz bir servis oturumu yanıtı verdi.',
      );
    }
    final expiresIn = asInt(payload['expires_in']) ?? 7200;
    final info = ServiceSessionInfo(
      homeId: homeId,
      homeName: asString(home?['name'] ?? payload['home_name']) ?? '',
      expiresAt: _clock.now().add(Duration(seconds: expiresIn)),
      technicianName: technicianName?.trim() ?? '',
    );
    beginSession(accessToken: access);
    _serviceSession = info;
    return info;
  }

  // ---------------------------------------------------------------------------
  // Bildirim (push) jetonu
  // ---------------------------------------------------------------------------

  static final RegExp _pushTokenPattern = RegExp(r'^[\x21-\x7E]{20,512}$');

  /// Bu cihazın bildirim (FCM) jetonunu kullanıcıya bağlar (`PUT /me/push-tokens`; servis oturumu ✖).
  /// Jeton **loglanmaz**. [platform]: `android` | `ios`.
  Future<void> registerPushToken({
    required String token,
    required String platform,
    String? appVersion,
  }) async {
    if (isServiceSession) throw ApiException.forbidden(); // kullanıcı satırı yok: jeton bağlanamaz
    final clean = token.trim();
    if (!_pushTokenPattern.hasMatch(clean)) {
      throw ApiException.validation('Bildirim anahtarı geçersiz.');
    }
    final p = platform.trim().toLowerCase();
    if (p != 'android' && p != 'ios') {
      throw ApiException.validation('Platform android veya ios olmalıdır.');
    }
    final version = appVersion?.trim();
    if (version != null && version.length > 32) {
      throw ApiException.validation('Uygulama sürümü en fazla 32 karakter olabilir.');
    }
    await _call(
      'PUT',
      '/v1/me/push-tokens',
      body: <String, dynamic>{
        'token': clean,
        'platform': p,
        if (version != null && version.isNotEmpty) 'app_version': version,
      },
    );
  }

  /// Bu cihazın bildirim jetonunu kaldırır (`DELETE /me/push-tokens`; çıkıştan **önce** çağrılmalıdır:
  /// çıkış sonrası kimlik doğrulama yoktur). İdempotenttir.
  Future<void> unregisterPushToken(String token) async {
    if (isServiceSession) throw ApiException.forbidden();
    final clean = token.trim();
    if (!_pushTokenPattern.hasMatch(clean)) {
      throw ApiException.validation('Bildirim anahtarı geçersiz.');
    }
    await _call('DELETE', '/v1/me/push-tokens', body: <String, dynamic>{'token': clean});
  }

  // ---------------------------------------------------------------------------
  // Evler ve uç noktalar
  // ---------------------------------------------------------------------------

  /// Kullanıcının yetkili olduğu evler (`role` ev bazlıdır).
  Future<List<HomeModel>> fetchHomes() async {
    final body = await _call('GET', '/v1/homes', timeout: const Duration(seconds: 10));
    return parseList(_list(body, 'homes'), HomeModel.fromJson, label: 'Home');
  }

  /// Bir daireye ait uç noktalar (röle, lamba, panjur).
  Future<List<EndpointModel>> fetchEndpoints(String homeId) async {
    final body = await _call(
      'GET',
      '/v1/homes/${_seg(homeId)}/endpoints',
      homeId: homeId,
    );
    return parseList(_list(body, 'endpoints'), EndpointModel.fromJson, label: 'Endpoint');
  }

  /// MQTT bağlantısı için **salt-okunur, süreli** kimlik (`POST /homes/:homeId/mqtt-credentials`).
  Future<MqttCredentials> mqttCredentials(String homeId) async {
    final body = await _call(
      'POST',
      '/v1/homes/${_seg(homeId)}/mqtt-credentials',
      homeId: homeId,
    );
    return _parseOrThrow(() => MqttCredentials.fromJson(_data(body)));
  }

  /// Cihaza komut gönderir (`POST /devices/:id/command`). Buluttan tüm komutlar buradan geçer;
  /// uygulama MQTT'ye yayın yapmaz.
  ///
  /// [deviceId]: cihaz kimliği (`AHBU-...`). Çevrimdışı cihazda `409 DEVICE_OFFLINE` fırlatılır.
  /// [command]: CONTRACTS §2.3 yükü (1 tabanlı indeksler, isteğe bağlı `id`).
  Future<CommandResult> sendCommand({
    required String homeId,
    required String deviceId,
    required Map<String, dynamic> command,
  }) async {
    final body = await _call(
      'POST',
      '/v1/devices/${_seg(deviceId)}/command',
      body: <String, dynamic>{'home_id': homeId, 'command': command},
      homeId: homeId,
      timeout: const Duration(seconds: 8),
      totalBudget: _commandBudget,
    );
    return CommandResult.fromJson(_data(body));
  }

  /// Eski uç nokta tabanlı kontrol (`POST /homes/:homeId/endpoints/:id/control`); sonuç türü
  /// [CommandResult]'tır. Yeni kod [sendCommand] kullanır.
  Future<CommandResult> controlEndpoint(
    String homeId,
    String endpointId, {
    String? cmd,
    bool? state,
    int? pos,
  }) async {
    final body = await _call(
      'POST',
      '/v1/homes/${_seg(homeId)}/endpoints/${_seg(endpointId)}/control',
      body: <String, dynamic>{
        'cmd': ?cmd,
        'state': ?state,
        'pos': ?pos,
      },
      homeId: homeId,
      timeout: const Duration(seconds: 8),
      totalBudget: _commandBudget,
    );
    return CommandResult.fromJson(_data(body));
  }

  // ---------------------------------------------------------------------------
  // Güvenlik modülü (tasarım §5.2.4; sunucu WP-S4). Yanıt `delivered` alanı taşımazsa iletildi SAYILMAZ (fail-closed):
  // güvenlik komutunun "uygulandı" iddiası kanıtsız kabul edilmez. Onay panonun `state`'inden (`last_id` / `last_rej`).
  // ---------------------------------------------------------------------------

  /// Eylemci komutu: `POST /homes/:homeId/devices/:deviceId/actuators/:actuatorId {to, id}` (CONTRACTS §1.5d). [to]:
  /// vana için `closed|open`, siren/fan/genel için `on|off` (panoya `{"actuator":…, "to":…, "uid":…, "id":…}` olarak
  /// gider; §2.6). [commandId] panoya aynen iletilir ve `last_id` / `last_rej.id`'de geri yankılanır.
  /// Sunucu ret kodları (409): `ZONE_ALARM_ACTIVE`, `GAS_LOCAL_ONLY`, `FIRMWARE_UNSUPPORTED`, `DEVICE_OFFLINE`.
  Future<CommandResult> actuatorCommand({
    required String homeId,
    required String deviceId,
    required String actuatorId,
    required String to,
    required String commandId,
  }) async {
    final body = await _call(
      'POST',
      '/v1/homes/${_seg(homeId)}/devices/${_seg(deviceId)}/actuators/${_seg(actuatorId)}',
      body: <String, dynamic>{'to': to, 'id': commandId},
      homeId: homeId,
      timeout: const Duration(seconds: 8),
      totalBudget: _commandBudget,
    );
    return CommandResult.fromJson(_data(body), deliveredDefault: false);
  }

  /// Alarm onayı / susturma: `POST /homes/:homeId/alarms/:alarmId/ack {id}`. Panoya giden `alarm_ack`'in `aid`'si
  /// sunucudaki kayıttan gelir; bayatsa pano `stale_ack` ile reddeder [Y-9]. Pano çevrimdışıysa sunucu isteği kaydeder.
  Future<CommandResult> ackAlarm({
    required String homeId,
    required String alarmId,
    required String commandId,
  }) async {
    final body = await _call(
      'POST',
      '/v1/homes/${_seg(homeId)}/alarms/${_seg(alarmId)}/ack',
      body: <String, dynamic>{'id': commandId},
      homeId: homeId,
      timeout: const Duration(seconds: 8),
      totalBudget: _commandBudget,
    );
    return CommandResult.fromJson(_data(body), deliveredDefault: false);
  }

  /// Hırsız alarmı kipi (F2.B.7): `POST /homes/:homeId/devices/:deviceId/arm {mode, id}` (`off` = çözme). Yanıt
  /// güvenlik komutlarıyla aynı (`{delivered, applied, command_id}`); ret `409 DEVICE_REJECTED reason:not_ready`,
  /// `409 FIRMWARE_UNSUPPORTED`, `409 DEVICE_OFFLINE` (kuyruğa alınmaz).
  Future<CommandResult> armCommand({
    required String homeId,
    required String deviceId,
    required String mode,
    required String commandId,
  }) async {
    final body = await _call(
      'POST',
      '/v1/homes/${_seg(homeId)}/devices/${_seg(deviceId)}/arm',
      body: <String, dynamic>{'mode': mode, 'id': commandId},
      homeId: homeId,
      timeout: const Duration(seconds: 8),
      totalBudget: _commandBudget,
    );
    return CommandResult.fromJson(_data(body), deliveredDefault: false);
  }

  /// Bölge testi: `POST /homes/:homeId/devices/:deviceId/alarm-test {zone, id}`.
  Future<CommandResult> alarmTest({
    required String homeId,
    required String deviceId,
    required int zone,
    required String commandId,
  }) async {
    final body = await _call(
      'POST',
      '/v1/homes/${_seg(homeId)}/devices/${_seg(deviceId)}/alarm-test',
      body: <String, dynamic>{'zone': zone, 'id': commandId},
      homeId: homeId,
      timeout: const Duration(seconds: 8),
      totalBudget: _commandBudget,
    );
    return CommandResult.fromJson(_data(body), deliveredDefault: false);
  }

  /// Alarm listesi: `GET /homes/:homeId/alarms?state=open|all&before=<alarm id>` -> `data: {items:[…], next_before}`
  /// (CONTRACTS §1.5d; yeniden eskiye). [before] bir önceki sayfanın `next_before`'u (alarm kimliği). Bozuk kayıt
  /// listeyi düşürmez.
  Future<List<AlarmRecord>> alarms(String homeId, {bool openOnly = true, String? before}) async {
    final body = await _call(
      'GET',
      '/v1/homes/${_seg(homeId)}/alarms',
      query: <String, String>{
        'state': openOnly ? 'open' : 'all',
        if (before != null && before.isNotEmpty) 'before': before,
      },
      homeId: homeId,
    );
    final items = _list(body, 'items');
    return parseList(items.isNotEmpty ? items : _list(body, 'alarms'), AlarmRecord.fromJson, label: 'Alarm');
  }

  /// Panonun güvenlik yapılandırma kopyası (sensör/eylemci/bölge ADLARI; state'te ad yoktur [B12]):
  /// `GET /homes/:homeId/devices/:deviceId/safety-config` -> `{device_uuid, rev, crc, updated_at, policy, zones,
  /// lights, sensors, actuators}` (panonun `GET /api/safety/config` biçimi). Kopya henüz yoksa `404
  /// CONFIG_NOT_AVAILABLE` ([ApiException]).
  Future<Map<String, dynamic>> safetyConfig(String homeId, String deviceId) async {
    final body = await _call(
      'GET',
      '/v1/homes/${_seg(homeId)}/devices/${_seg(deviceId)}/safety-config',
      homeId: homeId,
    );
    return _data(body);
  }

  /// Buluttan yapılandırma yaması (Faz 2 F2.D.1, D.6): `POST /homes/:homeId/devices/:deviceId/safety-config`
  /// gövde `{base_rev, set|del, id}` (TEK öğe; [patch] `{"set":{…}}` ya da `{"del":{…}}`). Yanıt `data`:
  /// `200 {applied:true, rev, crc, command_id}`, `202 {applied:null, command_id}` (pano 10 sn'de yanıt vermedi),
  /// `202 {queued:true, position, expires_at, command_id}` (pano çevrimdışı; 24 sa kuyruk). Ret: `409
  /// CONFIG_CHANGED_ON_DEVICE` (`data:{rev, crc, copy_rev}`), `CONFIG_PENDING`, `CONFIG_QUEUE_FULL`,
  /// `CONFIG_NOT_AVAILABLE`, `FIRMWARE_UNSUPPORTED`, `ZONE_ALARM_ACTIVE`; `400 CONFIG_INVALID|PAYLOAD_TOO_LARGE`;
  /// `503 DEVICE_BUSY`; `507 DEVICE_STORAGE_FULL` -> [ApiException].
  Future<Map<String, dynamic>> patchSafetyConfig({
    required String homeId,
    required String deviceId,
    required int baseRev,
    required Map<String, dynamic> patch,
    required String commandId,
  }) async {
    final body = await _call(
      'POST',
      '/v1/homes/${_seg(homeId)}/devices/${_seg(deviceId)}/safety-config',
      body: <String, dynamic>{...patch, 'base_rev': baseRev, 'id': commandId},
      homeId: homeId,
      timeout: const Duration(seconds: 14),
      totalBudget: const Duration(seconds: 18),
    );
    return _data(body);
  }

  /// Bekleyen (çevrimdışı panoya kuyruklanmış) yapılandırma yamalarını iptal eder: `DELETE …/safety-config/pending`
  /// -> `{dropped: n}` (F2.D.2).
  Future<int> clearSafetyConfigPending(String homeId, String deviceId) async {
    final body = await _call(
      'DELETE',
      '/v1/homes/${_seg(homeId)}/devices/${_seg(deviceId)}/safety-config/pending',
      homeId: homeId,
    );
    return asInt(_data(body)['dropped']) ?? 0;
  }

  /// Evin cihazları: `[{ device_uuid, name, online, last_seen_at, firmware }]`.
  Future<List<DeviceInfo>> devices(String homeId) async {
    final body = await _call('GET', '/v1/homes/${_seg(homeId)}/devices', homeId: homeId);
    return parseList(_list(body, 'devices'), DeviceInfo.fromJson, label: 'Device');
  }

  /// LAN doğrudan modu için cihaz yerel anahtarı (`X-Device-Key`). Yalnızca owner/resident/
  /// staff/servis oturumu. Anahtar loglanmaz; `SecureStorage`'da saklanmalıdır.
  Future<String> localKey(String homeId, String deviceUuid) async {
    final body = await _call(
      'GET',
      '/v1/homes/${_seg(homeId)}/devices/${_seg(deviceUuid)}/local-key',
      homeId: homeId,
    );
    final key = asNonEmptyString(_data(body)['local_key']);
    if (key == null || key.length < 8 || key.length > 32) {
      throw const ApiException(
        statusCode: 502,
        code: 'BAD_RESPONSE',
        message: 'Sunucu geçersiz bir cihaz anahtarı verdi.',
      );
    }
    return key;
  }

  /// Uç nokta günceller: ad, oda, (isteğe bağlı tip) ve panjur motor süresi (1..300 sn).
  Future<Map<String, dynamic>> updateEndpoint({
    required String homeId,
    required String endpointId,
    String? name,
    String? room,
    String? type,
    int? shutterDurationSec,
  }) async {
    if (shutterDurationSec != null && (shutterDurationSec < 1 || shutterDurationSec > 300)) {
      throw ApiException.validation('Panjur süresi 1 ile 300 saniye arasında olmalıdır.');
    }
    final body = await _call(
      'PUT',
      '/v1/homes/${_seg(homeId)}/endpoints/${_seg(endpointId)}',
      body: <String, dynamic>{
        'name': ?name,
        'room': ?room,
        'type': ?type,
        'shutter_duration_sec': ?shutterDurationSec,
      },
      homeId: homeId,
    );
    return _data(body);
  }

  // ---------------------------------------------------------------------------
  // Devreye alma / servis
  // ---------------------------------------------------------------------------

  /// Devreye alma (`POST /homes/:homeId/commissioning`). Zorunlu 5 kontrol **ayrı alanlarla**
  /// gönderilir; `tests_passed` **sunucuda** hesaplanır (istemci göndermez).
  Future<CommissioningResult> commission({
    required String homeId,
    required String deviceUuid,
    required CommissioningChecks checks,
    String? notes,
  }) async {
    final body = await _call(
      'POST',
      '/v1/homes/${_seg(homeId)}/commissioning',
      body: <String, dynamic>{
        'device_uuid': deviceUuid.trim().toUpperCase(),
        'checks': checks.toJson(),
        if (notes != null && notes.trim().isNotEmpty) 'notes': notes.trim(),
      },
      homeId: homeId,
    );
    return CommissioningResult.fromJson(_data(body));
  }

  /// Dairenin devreye alma durumu.
  Future<Map<String, dynamic>> getCommissioningStatus(String homeId) async {
    final body = await _call('GET', '/v1/homes/${_seg(homeId)}/commissioning-status', homeId: homeId);
    return _data(body);
  }

  /// Ev sahibi: servis PIN'i üretir (6 hane, 2 saat, tek kullanımlık; yeni PIN eskisini iptal eder).
  Future<ServiceTokenModel> createServiceToken(String homeId) async {
    final body = await _call('POST', '/v1/homes/${_seg(homeId)}/service-token', homeId: homeId);
    return _parseOrThrow(() => ServiceTokenModel.fromJson(_data(body), now: _clock.now()));
  }

  /// Ev sahibi: servis PIN geçmişi (`GET /homes/:homeId/service-tokens`). **PIN değeri dönmez**
  /// (yalnızca üretim anında bir kez gösterilir); durum `active|used|expired|revoked`.
  Future<List<ServiceTokenSummary>> listServiceTokens(String homeId) async {
    final body = await _call('GET', '/v1/homes/${_seg(homeId)}/service-tokens', homeId: homeId);
    return parseList(_list(body, 'tokens'), ServiceTokenSummary.fromJson, label: 'ServiceToken');
  }

  /// Ev sahibi: evde açık servis (PIN) oturumları (`GET /homes/:homeId/service-sessions`).
  Future<List<ServiceSessionSummary>> listServiceSessions(String homeId) async {
    final body = await _call('GET', '/v1/homes/${_seg(homeId)}/service-sessions', homeId: homeId);
    return parseList(_list(body, 'sessions'), ServiceSessionSummary.fromJson, label: 'ServiceSession');
  }

  /// Ev sahibi: kullanılmamış tüm servis PIN'lerini ve açık servis oturumlarını iptal eder
  /// (`POST /homes/:homeId/service-access/revoke`).
  Future<RevokeServiceAccessResult> revokeServiceAccess(String homeId) async {
    final body = await _call(
      'POST',
      '/v1/homes/${_seg(homeId)}/service-access/revoke',
      homeId: homeId,
    );
    return RevokeServiceAccessResult.fromJson(_data(body));
  }

  /// Cihazın bulut (MQTT) kimliğini yeniden üretir (`POST /homes/:homeId/devices/:uuid/mqtt-credential`;
  /// owner / servis personeli / servis oturumu / süper). Parola **yalnızca bu yanıtta** gelir:
  /// kurulum sihirbazı hemen `AutomationApiService.configureMqtt` ile panoya yazar; saklamaz/loglamaz.
  /// Eski cihaz kimliği geçersiz olur.
  Future<DeviceMqttCredential> reissueDeviceMqttCredential(String homeId, String deviceUuid) async {
    final body = await _call(
      'POST',
      '/v1/homes/${_seg(homeId)}/devices/${_seg(deviceUuid.trim().toUpperCase())}/mqtt-credential',
      homeId: homeId,
      timeout: const Duration(seconds: 15),
    );
    return _parseOrThrow(() => DeviceMqttCredential.fromJson(_data(body)));
  }

  /// Servis sorumlusu: müşteriye cihaz kurulum onay (OTP) kodu gönderir.
  Future<Map<String, dynamic>> requestClaimOtp({
    required String deviceUuid,
    required String targetOwner,
  }) async {
    final body = await _call(
      'POST',
      '/v1/devices/claim/request-otp',
      body: <String, dynamic>{
        'device_uuid': deviceUuid.trim().toUpperCase(),
        'target_owner': targetOwner.trim(),
      },
    );
    return _data(body);
  }

  /// Cihaz sahiplenme (claim). `home_id` gönderilmez (sunucu kabul etmez). `targetOwner` varsa
  /// OTP zorunludur ve yalnızca servis personeli/süper kullanıcı kullanabilir.
  Future<ClaimResult> claimDevice({
    required String deviceUuid,
    required String setupPin,
    String? homeName,
    String? targetOwner,
    String? otpCode,
  }) async {
    final body = await _call(
      'POST',
      '/v1/devices/claim',
      body: <String, dynamic>{
        'device_uuid': deviceUuid.trim().toUpperCase(),
        'setup_pin': setupPin.trim(),
        if (homeName != null && homeName.trim().isNotEmpty) 'home_name': homeName.trim(),
        if (targetOwner != null && targetOwner.trim().isNotEmpty)
          'target_owner': targetOwner.trim(),
        if (otpCode != null && otpCode.trim().isNotEmpty) 'otp_code': otpCode.trim(),
      },
    );
    return _parseOrThrow(() => ClaimResult.fromJson(_data(body)));
  }

  /// Acil sıfırlama (CONTRACTS §1.4 / §1.5b): gerekçe ≥ 15 karakter + cihaz UUID'sinin yazarak teyidi.
  /// Yanıt [EmergencyResetResult]: `UNCLAIMED` -> yeni kurulum PIN'i, `REASSIGNED` -> yeni sahip +
  /// cihaz kimliği (**tek seferlik**). Kısmi başarısızlıkta **HTTP 200 + `warnings` + `partial`**:
  /// arayüz uyarıları göstermelidir. `REVOKED`/`SUSPENDED` cihazı yalnız süper kullanıcı sıfırlar.
  Future<EmergencyResetResult> emergencyResetDevice({
    required String deviceUuid,
    required String confirmUid,
    required String reason,
    String? newOwnerIdentifier,
  }) async {
    final body = await _call(
      'POST',
      '/v1/devices/emergency-reset',
      body: <String, dynamic>{
        'device_uuid': deviceUuid.trim().toUpperCase(),
        'confirm_uid': confirmUid.trim().toUpperCase(),
        'reason': reason.trim(),
        if (newOwnerIdentifier != null && newOwnerIdentifier.trim().isNotEmpty)
          'new_owner_identifier': newOwnerIdentifier.trim(),
      },
      timeout: const Duration(seconds: 20),
    );
    return EmergencyResetResult.fromJson(_data(body));
  }

  /// Sistem doktoru (tanılama) raporu.
  Future<Map<String, dynamic>> fetchSystemDiagnostic(String homeId) async {
    final body = await _call('GET', '/v1/devices/diagnostic/${_seg(homeId)}', homeId: homeId);
    return _data(body);
  }

  /// Pano değişimi (felaket kurtarma). Çok cihazlı evde [oldDeviceUuid] zorunludur. Yanıt
  /// [ReplaceBoardResult]: yeni pano kimliği (**tek seferlik**), taşınan kanal sayısı, panjur süresi
  /// ve çocuk kilidi senkronu (`pending_device_online`) ve olası `warnings`.
  Future<ReplaceBoardResult> replaceBoard({
    required String homeId,
    String? oldDeviceUuid,
    required String newDeviceUuid,
    required String setupPin,
    String? reason,
  }) async {
    final body = await _call(
      'POST',
      '/v1/devices/replace-board',
      body: <String, dynamic>{
        'home_id': homeId,
        'new_device_uuid': newDeviceUuid.trim().toUpperCase(),
        'setup_pin': setupPin.trim(),
        if (oldDeviceUuid != null && oldDeviceUuid.trim().isNotEmpty)
          'old_device_uuid': oldDeviceUuid.trim().toUpperCase(),
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
      },
      homeId: homeId,
      timeout: const Duration(seconds: 20),
    );
    return _parseOrThrow(() => ReplaceBoardResult.fromJson(_data(body)));
  }

  // ---------------------------------------------------------------------------
  // Çocuk kilidi / huzur bildirimi
  // ---------------------------------------------------------------------------

  /// Çocuk kilidini ayarlar (`POST /devices/child-lock`). Yanıt `{ home_id, requested, delivered,
  /// device_online, command_id, offline_devices[], no_change? }` (CONTRACTS §1.5b): yanıtta
  /// **`child_lock_enabled` YOKTUR**; REST yalnızca niyeti kaydeder. **`delivered` "komut iletildi"
  /// demektir, "uygulandı" değil**; uygulandığını cihazın `state.child_lock` bildirimi gösterir.
  /// `delivered` alanı yoksa iletildi SAYILMAZ (fail-closed). Tüm panolar çevrimdışıysa `409
  /// DEVICE_OFFLINE` ([ApiException.offlineDevices]); bazıları çevrimdışıysa [CommandResult.offlineDevices]
  /// dolu döner (komut yalnızca çevrimiçi panolara gitti). Ev başına hız sınırı: 6/dk + 30/sa (`429`).
  Future<CommandResult> setChildLock({required String homeId, required bool enabled}) async {
    final body = await _call(
      'POST',
      '/v1/devices/child-lock',
      body: <String, dynamic>{'home_id': homeId, 'enabled': enabled},
      homeId: homeId,
      timeout: const Duration(seconds: 8),
      totalBudget: _commandBudget,
    );
    return CommandResult.fromJson(_data(body), deliveredDefault: false);
  }

  /// Çocuk kilidi durumu (`GET /devices/child-lock/:homeId`): birleşik durum, sunucuda kayıtlı
  /// niyet (`requested`), tutarlılık ve pano satırları. **Hata durumunda fırlatır** (hata "kilitsiz"
  /// sanılmaz); `child_lock_enabled` yoksa `BAD_RESPONSE`.
  Future<ChildLockInfo> fetchChildLockInfo(String homeId) async {
    final body = await _call('GET', '/v1/devices/child-lock/${_seg(homeId)}', homeId: homeId);
    try {
      return ChildLockInfo.fromJson(_data(body));
    } on FormatException {
      throw const ApiException(
        statusCode: 502,
        code: 'BAD_RESPONSE',
        message: 'Çocuk kilidi durumu okunamadı.',
      );
    }
  }

  /// [fetchChildLockInfo]'nun kısa yolu: yalnızca birleşik kilit durumu. **Hata durumunda fırlatır.**
  Future<bool> getChildLock(String homeId) async => (await fetchChildLockInfo(homeId)).enabled;

  Future<Map<String, dynamic>> getPeaceNotification(String homeId) async {
    final body = await _call('GET', '/v1/devices/peace-notification/${_seg(homeId)}', homeId: homeId);
    return _data(body);
  }

  Future<Map<String, dynamic>> updatePeaceNotification(
    String homeId, {
    bool? enabled,
    String? notificationTime,
  }) async {
    final body = await _call(
      'PUT',
      '/v1/devices/peace-notification/${_seg(homeId)}',
      body: <String, dynamic>{
        'enabled': ?enabled,
        'notification_time': ?notificationTime,
      },
      homeId: homeId,
    );
    return _data(body);
  }

  /// Açık lambaları tek tıkla kapat; yanıt gerçek kapatılan sayıyı taşır.
  ///
  /// İmza bilerek tek konumsal parametredir (test yardımcılarındaki sahteler bu imzayla geçersiz kılar).
  /// Sunucu v2'de `include_shutters` alanı YOKSA varsayılan olarak panjurlar da iner; pano düğmesi yalnızca
  /// lambaları kapatmalıdır, bu yüzden `include_shutters: false` HER ZAMAN açıkça gönderilir.
  /// Bildirim afişinden kapatma için [closeAllForNotice] kullanılır.
  Future<Map<String, dynamic>> closeAllOpenLights(String homeId) async {
    final body = await _call(
      'POST',
      '/v1/devices/peace-notification/close-all',
      body: <String, dynamic>{'home_id': homeId, 'include_shutters': false},
      homeId: homeId,
    );
    return _data(body);
  }

  /// Gece hatırlatması afişinden "Hepsini kapat" (sunucu v2): aynı uç.
  ///
  /// [noticeId] verilirse o bildirim kaydı çözülsün diye iletilir. [includeShutters] HER ZAMAN açıkça
  /// gönderilir (sunucu varsayılanına güvenilmez); varsayılan `true`'dur (afiş açık panjurları da sayar).
  Future<Map<String, dynamic>> closeAllForNotice(
    String homeId, {
    int? noticeId,
    bool includeShutters = true,
  }) async {
    final body = await _call(
      'POST',
      '/v1/devices/peace-notification/close-all',
      body: <String, dynamic>{
        'home_id': homeId,
        'notice_id': ?noticeId,
        'include_shutters': includeShutters,
      },
      homeId: homeId,
    );
    return _data(body);
  }

  // ---------------------------------------------------------------------------
  // Aile: davet, üyeler, devir
  // ---------------------------------------------------------------------------

  /// Davet kodu / QR üretir. [role] yalnızca `resident` veya `guest` (`owner` yalnızca devirle).
  /// Misafir süresi en çok 72 saattir.
  Future<InvitationModel> createInvitation(
    String homeId, {
    String role = 'resident',
    int? durationHours,
    DateTime? validFrom,
    DateTime? validUntil,
    String? guestName,
  }) async {
    if (role != 'resident' && role != 'guest') {
      throw ApiException.validation('Davet yalnızca aile bireyi veya misafir için üretilebilir.');
    }
    if (durationHours != null && (durationHours < 1 || durationHours > 72)) {
      throw ApiException.validation('Davet süresi 1 ile 72 saat arasında olmalıdır.');
    }
    if (validFrom != null && validUntil != null && !validFrom.isBefore(validUntil)) {
      throw ApiException.validation('Başlangıç zamanı bitişten önce olmalıdır.');
    }
    final body = await _call(
      'POST',
      '/v1/homes/${_seg(homeId)}/invitations',
      body: <String, dynamic>{
        'role': role,
        'duration_hours': ?durationHours,
        'valid_from': ?validFrom?.toUtc().toIso8601String(),
        'valid_until': ?validUntil?.toUtc().toIso8601String(),
        if (guestName != null && guestName.trim().isNotEmpty) 'guest_name': guestName.trim(),
      },
      homeId: homeId,
    );
    final source = asMap(body['invitation']) ?? _data(body);
    return _parseOrThrow(() => InvitationModel.fromJson(source, now: _clock.now()));
  }

  /// Davet koduyla / QR ile eve katıl.
  Future<JoinHomeResult> joinHome(String code) async {
    final body = await _call(
      'POST',
      '/v1/homes/join',
      body: <String, dynamic>{'code': code.trim()},
    );
    final source = body['home'] != null ? body : _data(body);
    return JoinHomeResult.fromJson(source);
  }

  /// Ev üyeleri ve süreli misafirler. Kimlikler UUID **String**'tir.
  Future<List<HomeMember>> getHomeMembers(String homeId) async {
    final body = await _call('GET', '/v1/homes/${_seg(homeId)}/members', homeId: homeId);
    return parseList(_list(body, 'members'), HomeMember.fromJson, label: 'HomeMember');
  }

  /// Ev sahibi: üyeyi / misafiri evden çıkarır. [targetUserId] UUID **String**.
  Future<bool> removeHomeMember(String homeId, String targetUserId) async {
    await _call(
      'DELETE',
      '/v1/homes/${_seg(homeId)}/members/${_seg(targetUserId)}',
      homeId: homeId,
    );
    return true;
  }

  /// Daire devrini başlatır (48 saat geçerli kod). Hedef kimlik (e-posta/telefon) **zorunludur**.
  Future<TransferInfo> initiateTransfer(String homeId, {required String targetIdentifier}) async {
    final target = targetIdentifier.trim();
    if (target.isEmpty) {
      throw ApiException.validation('Devir için hedef e-posta veya telefon zorunludur.');
    }
    final body = await _call(
      'POST',
      '/v1/homes/${_seg(homeId)}/transfer-initiate',
      body: <String, dynamic>{'target_identifier': target},
      homeId: homeId,
    );
    final source = asMap(body['transfer']) ?? _data(body);
    return _parseOrThrow(() => TransferInfo.fromJson(source));
  }

  /// Devir kodunu kabul edip daireyi devralır.
  Future<TransferAcceptResult> acceptTransfer(String transferCode) async {
    final body = await _call(
      'POST',
      '/v1/homes/transfer-accept',
      body: <String, dynamic>{'transfer_code': transferCode.trim()},
    );
    final source = body['home'] != null ? body : _data(body);
    return TransferAcceptResult.fromJson(source);
  }

  /// Bekleyen devir (yoksa `null`).
  Future<Map<String, dynamic>?> getTransferStatus(String homeId) async {
    final body = await _call('GET', '/v1/homes/${_seg(homeId)}/transfer-status', homeId: homeId);
    final data = _data(body);
    return asMap(data['pendingTransfer'] ?? data['pending_transfer']);
  }

  Future<bool> cancelTransfer(String homeId) async {
    await _call('POST', '/v1/homes/${_seg(homeId)}/transfer-cancel', homeId: homeId);
    return true;
  }

  // ---------------------------------------------------------------------------
  // Zamanlı kurallar
  // ---------------------------------------------------------------------------

  /// Evin zamanlı kuralları. Bozuk tek bir kayıt listeyi düşürmez.
  Future<List<ScheduledRule>> getScheduledRules(String homeId) async {
    final body = await _call('GET', '/v1/homes/${_seg(homeId)}/scheduled-rules', homeId: homeId);
    return parseList(_list(body, 'rules'), ScheduledRule.fromJson, label: 'ScheduledRule');
  }

  /// Yeni kural (gövde için `ScheduledRule.createPayload`: snake_case, `channel` 1 tabanlı).
  Future<Map<String, dynamic>> createScheduledRule(String homeId, Map<String, dynamic> ruleData) async {
    final body = await _call(
      'POST',
      '/v1/homes/${_seg(homeId)}/scheduled-rules',
      body: ruleData,
      homeId: homeId,
    );
    return _data(body);
  }

  Future<Map<String, dynamic>> updateScheduledRule(
    String homeId,
    String ruleId,
    Map<String, dynamic> updates,
  ) async {
    final body = await _call(
      'PUT',
      '/v1/homes/${_seg(homeId)}/scheduled-rules/${_seg(ruleId)}',
      body: updates,
      homeId: homeId,
    );
    return _data(body);
  }

  Future<void> deleteScheduledRule(String homeId, String ruleId) async {
    await _call(
      'DELETE',
      '/v1/homes/${_seg(homeId)}/scheduled-rules/${_seg(ruleId)}',
      homeId: homeId,
    );
  }

  // ---------------------------------------------------------------------------
  // Süper yönetici & servis yönetimi (yetki yalnızca JWT ile; API anahtarı YOK)
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> listAdminUsers({
    String? role,
    String? search,
    bool? isActive,
    int limit = 50,
    int offset = 0,
  }) async {
    final body = await _call(
      'GET',
      '/v1/admin/users',
      query: <String, String>{
        'limit': limit.toString(),
        'offset': offset.toString(),
        if (role != null && role.isNotEmpty) 'role': role,
        if (search != null && search.isNotEmpty) 'search': search,
        if (isActive != null) 'is_active': isActive.toString(),
      },
    );
    return _data(body);
  }

  /// Kullanıcı oluşturur. **Servis personeli parola belirleyemez** (`403 FORBIDDEN`): [password]
  /// verilmezse hesap `pending_invite` olur ve etkinleştirme e-postası gider (yanıtta
  /// `invite_sent`, `invite_warning`). Yalnızca süper kullanıcı parola verebilir; bu durumda
  /// kullanıcı ilk girişte parola değiştirmeye zorlanır (`must_change_password`).
  Future<Map<String, dynamic>> createAdminUser({
    required String fullName,
    required String email,
    String? password,
    String? phone,
    required String role,
    String? adminNotes,
  }) async {
    final body = await _call(
      'POST',
      '/v1/admin/users',
      body: <String, dynamic>{
        'full_name': fullName.trim(),
        'email': email.trim(),
        if (password != null && password.isNotEmpty) 'password': password,
        if (phone != null && phone.trim().isNotEmpty) 'phone': phone.trim(),
        'role': role,
        if (adminNotes != null && adminNotes.trim().isNotEmpty) 'admin_notes': adminNotes.trim(),
      },
    );
    return _data(body);
  }

  /// Kullanıcı günceller. Parola değiştirmek yalnızca süper kullanıcıya açıktır (servis personeli
  /// için `sendAdminUserReset` kullanılır); **başka bir süper kullanıcının** parolası için
  /// [currentPassword] (kendi mevcut parolanız) zorunludur (`403 REAUTH_REQUIRED`). Kendi parolanız
  /// için `changePassword` kullanılır.
  Future<Map<String, dynamic>> updateAdminUser(
    String userId, {
    String? fullName,
    String? phone,
    String? role,
    String? password,
    String? currentPassword,
    bool? isActive,
    String? adminNotes,
  }) async {
    final body = await _call(
      'PATCH',
      '/v1/admin/users/${_seg(userId)}',
      body: <String, dynamic>{
        'full_name': ?fullName,
        'phone': ?phone,
        'role': ?role,
        if (password != null && password.isNotEmpty) 'password': password,
        if (currentPassword != null && currentPassword.isNotEmpty)
          'current_password': currentPassword,
        'is_active': ?isActive,
        'admin_notes': ?adminNotes,
      },
    );
    return _data(body);
  }

  /// Kullanıcıya sıfırlama / hesap etkinleştirme bağlantısı gönderir (`POST /admin/users/:id/send-reset`).
  /// Servis personeli yalnızca kendi oluşturduğu kullanıcılara gönderebilir. Yanıt:
  /// `{ sent, purpose: reset|account_setup, expires_at }`; e-posta gönderilemezse `503 DELIVERY_FAILED`.
  Future<Map<String, dynamic>> sendAdminUserReset(String userId) async {
    final body = await _call('POST', '/v1/admin/users/${_seg(userId)}/send-reset');
    return _data(body);
  }

  Future<Map<String, dynamic>> deleteAdminUser(String userId, {bool hard = false}) async {
    final body = await _call(
      'DELETE',
      '/v1/admin/users/${_seg(userId)}',
      query: <String, String>{'hard': hard.toString()},
    );
    return body;
  }

  Future<Map<String, dynamic>> getServiceSummary() async {
    final body = await _call('GET', '/v1/admin/service-summary');
    return _data(body);
  }

  /// Cihaz envanteri (süper kullanıcı; servis personeli yalnızca kendi stoku).
  Future<Map<String, dynamic>> fetchDeviceInventory({
    String? status,
    String? search,
    int limit = 100,
    int offset = 0,
  }) async {
    final body = await _call(
      'GET',
      '/v1/admin/inventory',
      query: <String, String>{
        'limit': limit.toString(),
        'offset': offset.toString(),
        if (status != null && status.isNotEmpty && status.toUpperCase() != 'ALL')
          'status': status.toUpperCase(),
        if (search != null && search.trim().isNotEmpty) 'search': search.trim(),
      },
    );
    return _data(body);
  }

  Future<Map<String, dynamic>> updateInventoryDeviceStatus(String uuid, String status) async {
    final body = await _call(
      'PATCH',
      '/v1/admin/inventory/${_seg(uuid)}/status',
      body: <String, dynamic>{'status': status},
    );
    return _data(body);
  }

  Future<bool> deleteInventoryDevice(String uuid) async {
    await _call('DELETE', '/v1/admin/inventory/${_seg(uuid)}');
    return true;
  }

  // ---------------------------------------------------------------------------
  // Site ve kurulum şablonları (CONTRACTS §3e; yalnız `service_user` + `super_user`, servis PIN oturumu 403)
  // ---------------------------------------------------------------------------

  /// Siteler: `GET /sites` -> `[{id, name, address, city, district, ..., flat_count}]`.
  Future<List<InstallSite>> listInstallSites() async {
    final body = await _call('GET', '/v1/sites');
    return parseList(_list(body, 'sites'), InstallSite.fromJson, label: 'Site');
  }

  /// Şablon listesi: `GET /templates?site_id=&include_global=1`. [siteId] `null` ise yalnız genel (standart) şablonlar
  /// istenir; [includeGlobal] site şablonlarına genel şablonları da ekletir.
  Future<List<InstallTemplateSummary>> listInstallTemplates({String? siteId, bool includeGlobal = true}) async {
    final body = await _call(
      'GET',
      '/v1/templates',
      query: <String, String>{
        if (siteId != null && siteId.isNotEmpty) 'site_id': siteId,
        if (includeGlobal) 'include_global': '1',
      },
    );
    return parseList(_list(body, 'templates'), InstallTemplateSummary.fromJson, label: 'Template');
  }

  /// Şablonun güncel sürümü (gövdesiyle): `GET /templates/:id` -> `{..., body}`.
  Future<InstallTemplate> installTemplate(String templateId) async {
    final body = await _call('GET', '/v1/templates/${_seg(templateId)}');
    return _parseOrThrow(() => InstallTemplate.fromJson(_data(body)));
  }

  /// Şablonun belirli bir sürümü: `GET /templates/:id/versions/:version` -> gövde.
  Future<InstallTemplate> installTemplateVersion(String templateId, int version) async {
    final body = await _call('GET', '/v1/templates/${_seg(templateId)}/versions/$version');
    return _parseOrThrow(() => InstallTemplate.fromJson(<String, dynamic>{'id': templateId, ..._data(body)}));
  }

  /// Karta şablon yazımının kaydı (K-Ş6): `POST /template-writes` gövde `{device_uuid, template_id, version,
  /// flat_id?, via: "usb"|"eth"|"lan", result: "ok"|"error", error_code?}`. Sihirbaz Wi-Fi LAN üzerinden yazdığı için
  /// `via: "lan"` gönderir.
  Future<void> recordTemplateWrite({
    required String deviceUuid,
    required String templateId,
    required int version,
    required String via,
    required bool ok,
    String? errorCode,
    String? flatId,
  }) async {
    await _call(
      'POST',
      '/v1/template-writes',
      body: <String, dynamic>{
        'device_uuid': deviceUuid,
        'template_id': templateId,
        'version': version,
        if (flatId != null && flatId.isNotEmpty) 'flat_id': flatId,
        'via': via,
        'result': ok ? 'ok' : 'error',
        if (!ok && errorCode != null && errorCode.isNotEmpty) 'error_code': errorCode,
      },
    );
  }

  /// Servis sorumlusunun devreye aldığı aboneler/panolar.
  Future<List<Map<String, dynamic>>> fetchServiceSubscribers() async {
    final body = await _call('GET', '/v1/service/subscribers');
    return _list(body, 'subscribers').map(asMap).whereType<Map<String, dynamic>>().toList();
  }

  /// Home Admin (ev sahibi) yetkisi atama / devretme. Mevcut bir sahip varsa devir, sahibe giden
  /// onay kodu ([otpCode]; önce [requestAssignAdminOtp]) ile yapılır. Sahibe ulaşılamıyorsa **yalnızca süper
  /// kullanıcı** [force] + gerekçeyle ([reason], en az 15 karakter) zorla atayabilir.
  Future<Map<String, dynamic>> assignHomeAdmin({
    required String homeId,
    required String fullName,
    String? email,
    String? phone,
    String? otpCode,
    bool force = false,
    String? reason,
  }) async {
    final body = await _call(
      'POST',
      '/v1/service/subscribers/${_seg(homeId)}/assign-admin',
      body: <String, dynamic>{
        'full_name': fullName.trim(),
        if (email != null && email.isNotEmpty) 'email': email.trim(),
        if (phone != null && phone.isNotEmpty) 'phone': phone.trim(),
        if (otpCode != null && otpCode.trim().isNotEmpty) 'otp_code': otpCode.trim(),
        if (force) 'force': true,
        if (force && reason != null) 'reason': reason.trim(),
      },
      homeId: homeId,
    );
    return _data(body);
  }

  // --- Servis paneli (WP-F) --------------------------------------------------------------------
  // Arayüz paketi F tarafından eklenen AYRIK blok. Sunucu uçları: B2 (service_panel).

  /// Aboneler sayfası (`GET /service/subscribers?q=&limit=&offset=`). Yanıt `data`:
  /// `{subscribers: [...], total, count, limit, offset}` (B2); dizi ya da `items` anahtarı da kabul edilir.
  Future<({List<Map<String, dynamic>> items, int? total})> fetchServiceSubscribersPage({
    int limit = 50,
    int offset = 0,
    String? search,
  }) async {
    final body = await _call(
      'GET',
      '/v1/service/subscribers',
      query: <String, String>{
        'limit': limit.toString(),
        'offset': offset.toString(),
        if (search != null && search.trim().isNotEmpty) 'q': search.trim(),
      },
    );
    final data = _data(body);
    final raw = body['data'] is List
        ? body['data'] as List
        : (asList(data['subscribers']) ?? asList(data['items']) ?? asList(body['subscribers']) ?? asList(body['items']));
    return (
      items: (raw ?? const <dynamic>[]).map(asMap).whereType<Map<String, dynamic>>().toList(),
      total: asInt(data['total'] ?? body['total']),
    );
  }

  /// Home Admin devrinde **mevcut sahibe** onay kodu gönderir
  /// (`POST /service/subscribers/:homeId/assign-admin/request-otp`). Kod, atanacak kişiye bağlıdır:
  /// [fullName] ve [email]/[phone] gönderilir (sunucu bu kimlikle eşleştirir).
  ///
  /// Dairede sahip yoksa `otpRequired=false` döner (kod gerekmez; doğrudan atama yapılır).
  Future<({bool otpRequired, CodeChallenge challenge, String? ownerHint})> requestAssignAdminOtp(
    String homeId, {
    required String fullName,
    String? email,
    String? phone,
  }) async {
    final body = await _call(
      'POST',
      '/v1/service/subscribers/${_seg(homeId)}/assign-admin/request-otp',
      body: <String, dynamic>{
        'full_name': fullName.trim(),
        if (email != null && email.isNotEmpty) 'email': email.trim(),
        if (phone != null && phone.isNotEmpty) 'phone': phone.trim(),
      },
      homeId: homeId,
    );
    final data = _data(body);
    return (
      otpRequired: asBool(data['otp_required']) ?? true,
      challenge: CodeChallenge.fromJson(data),
      ownerHint: asNonEmptyString(data['owner_hint']),
    );
  }

  /// Etiket yeniden üretimi (yalnızca süper kullanıcı; `POST /admin/inventory/:uid/reissue-label`):
  /// yeni kurulum PIN'i + yerel anahtar **yalnızca bu yanıtta** gelir.
  Future<Map<String, dynamic>> reissueInventoryLabel(String uuid) async {
    final body = await _call(
      'POST',
      '/v1/admin/inventory/${_seg(uuid.trim().toUpperCase())}/reissue-label',
      timeout: const Duration(seconds: 15),
    );
    return _data(body);
  }

  // --- Hesap silme (E2) ---------------------------------------------------------------------
  // Arayüz paketi E2 tarafından eklenen AYRIK blok (D çekirdeğinin dışında). Sunucu ucu: B2.

  /// Hesabı kalıcı olarak siler (`DELETE /api/v1/auth/account`; mağaza gereksinimi).
  ///
  /// * Parolalı hesap: [password] (kırpılmaz).
  /// * Sosyal giriş (Google/Apple/SMS) hesabı: [confirm] = `SİL`.
  ///
  /// Kullanıcı, başka üyesi ya da panosu olan bazı evlerin **tek sahibi** ise sunucu `409 SOLE_OWNER` döndürür
  /// ([ApiException.isSoleOwner]; ev listesi [soleOwnedHomesOf] ile okunur): önce daire devredilmelidir. Üyesiz ve
  /// panosuz tek sahipli daireler engel değildir: hesapla birlikte silinir ve sayısı yanıtta `released_homes`'tur
  /// ([AccountDeletionResult.releasedHomes]; eski sunucu vermez: 0). Başarıda yerel oturum silinmez; çağıran
  /// ([AutomationState.deleteAccount]) çıkışı yapar. Servis PIN oturumunda yasak.
  Future<AccountDeletionResult> deleteAccount({String? password, String? confirm}) async {
    if (isServiceSession) throw ApiException.forbidden();
    final hasPassword = password != null && password.isNotEmpty;
    final confirmText = confirm?.trim() ?? '';
    if (!hasPassword && confirmText.isEmpty) {
      throw ApiException.validation('Hesabı silmek için parolanızı girin veya onay ifadesini yazın.');
    }
    final body = await _call(
      'DELETE',
      '/v1/auth/account',
      body: <String, dynamic>{
        if (hasPassword) 'password': password,
        if (!hasPassword) 'confirm': confirmText,
      },
    );
    final released = asInt(_data(body)['released_homes'] ?? body['released_homes']);
    return AccountDeletionResult(releasedHomes: (released != null && released > 0) ? released : 0);
  }

  /// Davet / devir kodunu **tüketmeden** önizler (`POST /api/v1/homes/join-preview`): ev adı, sakin
  /// sayısı. Sunucu bu ucu henüz sağlamıyorsa (404/405) `null` döner ve arayüz önizlemesiz onay
  /// adımına geçer; kod geçersiz/süresi dolmuşsa (410) [ApiException] fırlatılır.
  Future<JoinCodePreview?> previewJoinCode(String code) async {
    try {
      final body = await _call(
        'POST',
        '/v1/homes/join-preview',
        body: <String, dynamic>{'code': code.trim()},
        timeout: const Duration(seconds: 8),
      );
      final data = _data(body);
      if (data.isEmpty) return null;
      return JoinCodePreview.fromJson(data);
    } on ApiException catch (e) {
      if (e.statusCode == 404 || e.statusCode == 405) return null;
      rethrow;
    }
  }
}

/// `409 SOLE_OWNER` yanıtındaki ev (kullanıcının tek sahibi olduğu daire).
class SoleOwnedHome {
  const SoleOwnedHome({required this.id, required this.name, this.otherMemberCount, this.deviceCount});

  final String id;
  final String name;

  /// Dairedeki diğer üye sayısı (`other_member_count`; sunucu verdiyse).
  final int? otherMemberCount;

  /// Dairedeki pano sayısı (`device_count`; sunucu verdiyse).
  final int? deviceCount;
}

/// [error] (`SOLE_OWNER`) içindeki ev listesini okur: `homes`/`data.homes`/`sole_owner_homes`
/// altında `{id, name}` kayıtları ya da yalnızca kimlik metinleri. Liste yoksa boş döner (arayüz
/// kullanıcının kendi `owner` evlerini gösterir).
List<SoleOwnedHome> soleOwnedHomesOf(ApiException error) {
  final details = error.details;
  if (details == null) return const <SoleOwnedHome>[];
  final raw = asList(details['homes']) ??
      asList(asMap(details['data'])?['homes']) ??
      asList(details['sole_owner_homes']) ??
      asList(details['sole_owned_homes']);
  if (raw == null) return const <SoleOwnedHome>[];
  final out = <SoleOwnedHome>[];
  for (final item in raw) {
    final map = asMap(item);
    final id = asNonEmptyString(map?['id'] ?? map?['home_id'] ?? item);
    if (id == null) continue;
    out.add(
      SoleOwnedHome(
        id: id,
        name: asNonEmptyString(map?['name'] ?? map?['home_name']) ?? 'Daire',
        otherMemberCount: asInt(map?['other_member_count']),
        deviceCount: asInt(map?['device_count']),
      ),
    );
  }
  return out;
}

/// Davet / devir kodu önizlemesi (`previewJoinCode`).
class JoinCodePreview {
  const JoinCodePreview({
    required this.isTransfer,
    this.homeName,
    this.residentCount,
    this.role,
    this.expiresAt,
    this.alreadyMember = false,
    this.guestValidFrom,
    this.guestValidUntil,
  });

  /// `true`: daire devri (yıkıcı: mevcut sakinlerin erişimi kalkar), `false`: aile/misafir daveti.
  final bool isTransfer;
  final String? homeName;
  final int? residentCount;

  /// Davet edilen rol (`resident` | `guest`); devirde `owner`.
  final String? role;
  final DateTime? expiresAt;

  /// Kullanıcı bu dairenin zaten üyesi (`already_member`): davet tüketilmez, rol değişmez.
  final bool alreadyMember;

  /// Misafir davetinde erişim penceresi (UTC; arayüz `toLocal()` ile gösterir).
  final DateTime? guestValidFrom;
  final DateTime? guestValidUntil;

  factory JoinCodePreview.fromJson(Map<String, dynamic> json) {
    final home = asMap(json['home']);
    final kind = (asNonEmptyString(json['kind'] ?? json['type']) ?? '').toLowerCase();
    return JoinCodePreview(
      isTransfer: kind == 'transfer' || (asBool(json['is_transfer']) ?? false),
      homeName: asNonEmptyString(json['home_name'] ?? home?['name']),
      residentCount: asInt(json['resident_count'] ?? json['residents_count'] ?? json['member_count']),
      role: asNonEmptyString(json['role']),
      expiresAt: asDate(json['expires_at'] ?? json['valid_until']),
      alreadyMember: asBool(json['already_member']) ?? false,
      guestValidFrom: asDate(json['guest_valid_from']),
      guestValidUntil: asDate(json['guest_valid_until']),
    );
  }
}
