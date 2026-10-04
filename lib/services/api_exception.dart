/// Sunucu (REST) hatası. CONTRACTS §1.1: `{ success:false, message, code }`.
///
/// [toString] yalnızca kullanıcıya gösterilebilir Türkçe mesajı döndürür; böylece eski
/// arayüz kodundaki `e.toString().replaceFirst('Exception: ', '')` kalıbı da güvenle çalışır.
/// 5xx yanıtlarının ham iç mesajı hiçbir zaman [message]'a taşınmaz.
class ApiException implements Exception {
  const ApiException({
    required this.statusCode,
    required this.message,
    this.code,
    this.retryAfter,
    this.resendAfter,
    this.remainingAttempts,
    this.deviceOnline,
    this.offlineDevices = const <String>[],
    this.cause,
    this.details,
  });

  /// HTTP durum kodu. `0` = ağ/zaman aşımı/yanıt çözümlenemedi (sunucuya ulaşılamadı).
  final int statusCode;

  /// Makine kodu (`TOKEN_EXPIRED`, `DEVICE_OFFLINE`, `GUEST_EXPIRED`, `PIN_LOCKED` ...).
  final String? code;

  /// Kullanıcıya gösterilebilir Türkçe mesaj.
  final String message;

  /// `Retry-After` başlığı veya `retry_after` alanı (423 / 429).
  final Duration? retryAfter;

  /// OTP / sıfırlama kodu yeniden gönderim bekleme süresi (`resend_after`, 429 yanıtlarında).
  /// Süre dolmadan "Yeniden gönder" kapalı tutulur.
  final Duration? resendAfter;

  /// Hatalı kod girişinde kalan deneme hakkı (`remaining_attempts`; OTP / sıfırlama doğrulaması).
  final int? remainingAttempts;

  /// Cihaz komutu hatalarında (`409 DEVICE_OFFLINE`) `device_online` alanı (bilinmiyorsa `null`).
  final bool? deviceOnline;

  /// Komutun iletilemediği çevrimdışı panoların kimlikleri (`offline_devices`; çok panolu ev).
  final List<String> offlineDevices;

  /// Ağ hatalarında altta yatan istisna (loglama için; kullanıcıya gösterilmez).
  final Object? cause;

  /// 4xx yanıtın ayrıştırılmış gövdesi (E2: `409 SOLE_OWNER` ev listesi gibi koda özgü ek alanlar
  /// için). 5xx'te ve ağ hatalarında `null` (iç ayrıntı taşınmaz). Kullanıcıya gösterilmez.
  final Map<String, dynamic>? details;

  /// Yerel (istemci tarafı) doğrulama hatası.
  factory ApiException.validation(String message) =>
      ApiException(statusCode: 400, code: 'VALIDATION', message: message);

  /// Yetkisiz yerel çağrı (UI kapısı atlatılmış olsa bile işlem başlamaz).
  factory ApiException.forbidden([String message = 'Bu işlem için yetkiniz yok.']) =>
      ApiException(statusCode: 403, code: 'FORBIDDEN', message: message);

  /// Sunucuya ulaşılamadı.
  factory ApiException.network({Object? cause, String? message}) => ApiException(
        statusCode: 0,
        code: 'NETWORK',
        message: message ?? 'Sunucuya ulaşılamadı. İnternet bağlantınızı kontrol edin.',
        cause: cause,
      );

  /// Sunucuya ulaşılamadı (ağ/zaman aşımı).
  bool get isNetwork => statusCode == 0;
  bool get isUnauthorized => statusCode == 401;
  bool get isForbidden => statusCode == 403;
  bool get isNotFound => statusCode == 404;
  bool get isServerError => statusCode >= 500;

  /// Cihaz çevrimdışı; komut iletilmedi (409 `DEVICE_OFFLINE`).
  bool get isDeviceOffline => code == 'DEVICE_OFFLINE';

  /// Misafir süresi doldu (403 `GUEST_EXPIRED`).
  bool get isGuestExpired => code == 'GUEST_EXPIRED';

  /// PIN deneme kilidi (423 `PIN_LOCKED`).
  bool get isPinLocked => code == 'PIN_LOCKED' || statusCode == 423;

  /// Hız sınırı (429 `RATE_LIMITED`).
  bool get isRateLimited => code == 'RATE_LIMITED' || statusCode == 429;

  /// MQTT broker'a yayın yapılamadı (502 `BROKER_UNAVAILABLE`).
  bool get isBrokerUnavailable => code == 'BROKER_UNAVAILABLE';

  /// Servis oturumu süresi doldu (401 `SERVICE_SESSION_EXPIRED`).
  bool get isServiceSessionExpired => code == 'SERVICE_SESSION_EXPIRED';

  /// E-posta/telefon veya parola/kod hatalı (401/400 `INVALID_CREDENTIALS`; kullanıcı varlığı sızmaz).
  bool get isInvalidCredentials => code == 'INVALID_CREDENTIALS';

  /// Hesap dondurulmuş (403 `ACCOUNT_DISABLED`).
  bool get isAccountDisabled => code == 'ACCOUNT_DISABLED';

  /// Hesap etkinleştirme (davet) bekliyor (403 `ACCOUNT_PENDING`).
  bool get isAccountPending => code == 'ACCOUNT_PENDING';

  /// Hassas işlem için mevcut parolayla yeniden doğrulama gerekli (403 `REAUTH_REQUIRED`).
  bool get isReauthRequired => code == 'REAUTH_REQUIRED';

  /// Kod / bağlantı süresi doldu ya da zaten kullanıldı (410 `GONE`).
  bool get isGone => code == 'GONE' || statusCode == 410;

  /// E-posta / SMS gönderilemedi (503 `DELIVERY_FAILED`).
  bool get isDeliveryFailed => code == 'DELIVERY_FAILED';

  /// İlgili özellik sunucuda yapılandırılmamış (503 `SERVICE_UNAVAILABLE`).
  bool get isServiceUnavailable => code == 'SERVICE_UNAVAILABLE';

  /// Girdi doğrulaması (400 `VALIDATION`).
  bool get isValidation => code == 'VALIDATION';

  /// Yazma çakışması (409 `CONFLICT`): sunucudaki durum istemcinin bildiği listeden ilerlemiş. Örnek: uç nokta
  /// güncellenirken pano yerleşimi eşitlemesi satırı değiştirdi ("Kanal tipi değişti; listeyi yenileyin.",
  /// CONTRACTS §2.4b). Çare listeyi yenileyip işlemi yeniden denemektir. Yalnızca KOD'a bakar: 409'un öteki kodları
  /// (`DEVICE_OFFLINE`, `SOLE_OWNER` ...) başka anlam taşır ve yenilemeyle düzelmez.
  bool get isConflict => code == 'CONFLICT';

  /// Hesap silinemiyor: kullanıcı bazı evlerin **tek sahibi** (409 `SOLE_OWNER`); önce devretmelidir.
  bool get isSoleOwner => code == 'SOLE_OWNER';

  @override
  String toString() => message;

  /// HTTP durum koduna göre varsayılan Türkçe mesaj (sunucu mesaj vermediyse).
  static String defaultMessageFor(int statusCode) {
    if (statusCode == 0) return 'Sunucuya ulaşılamadı. İnternet bağlantınızı kontrol edin.';
    if (statusCode == 400) return 'Girilen bilgiler geçersiz.';
    if (statusCode == 401) return 'Oturumunuz sona erdi. Lütfen tekrar giriş yapın.';
    if (statusCode == 403) return 'Bu işlem için yetkiniz yok.';
    if (statusCode == 404) return 'Kayıt bulunamadı.';
    if (statusCode == 405) return 'Bu işlem bu şekilde yapılamaz.';
    if (statusCode == 409) return 'İşlem çakıştı. Lütfen tekrar deneyin.';
    if (statusCode == 410) return 'Kodun veya bağlantının süresi doldu ya da zaten kullanıldı.';
    if (statusCode == 413) return 'Gönderilen veri çok büyük.';
    if (statusCode == 423) return 'Çok fazla hatalı deneme. Lütfen biraz bekleyin.';
    if (statusCode == 429) return 'Çok fazla istek gönderildi. Lütfen biraz bekleyin.';
    if (statusCode >= 500) {
      return 'Sunucu şu anda yanıt veremiyor. Lütfen daha sonra tekrar deneyin.';
    }
    return 'İşlem tamamlanamadı (Kod: $statusCode).';
  }
}

/// Oturumun neden sonlandığı (`onSessionExpired` geri çağrısı ve `SessionExpiredEvent`).
enum SessionEndReason {
  /// Refresh token sunucu tarafından kalıcı olarak reddedildi (iptal/süre/yeniden kullanım).
  refreshRejected,

  /// Access token geçersiz (`INVALID_TOKEN`) ve yenilenemedi.
  invalidToken,

  /// Yenilenecek bir refresh token yok ve access token reddedildi.
  noRefreshToken,

  /// 2 saatlik servis oturumu bitti (`SERVICE_SESSION_EXPIRED` veya yerel süre).
  serviceSessionExpired,

  /// Kullanıcı kendi isteğiyle çıkış yaptı (olay üretilmez; yalnızca iç kullanım).
  userLogout,
}
