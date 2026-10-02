import 'qr_claim_parser.dart';
import 'wifi_qr_parser.dart';

/// Taranan/girilen metnin türü (sıkı, bilinen biçimlerden biri ya da [QrUnknown]).
///
/// **Ham metin hiçbir zaman cihaz kimliği (UUID) olmaz**: tanınmayan her şey [QrUnknown]'dır.
sealed class QrPayload {
  const QrPayload();
}

/// Cihaz etiketi: UID + kurulum PIN'i (`https://.../claim?uid=...&pin=...`).
final class QrClaim extends QrPayload {
  const QrClaim({required this.uid, required this.pin});

  final String uid;
  final String pin;

  QrClaimData get data => QrClaimData(uid: uid, pin: pin);

  @override
  String toString() => 'QrClaim(uid: $uid, pin: ******)';
}

/// Aile / misafir daveti (`AHBU-INVITE:<kod>`).
final class QrInvite extends QrPayload {
  const QrInvite(this.code);

  final String code;

  @override
  String toString() => 'QrInvite(****)';
}

/// Daire devir kodu (`AHBU-TRANSFER:<kod>` veya çıplak `AHBU-TR-<kod>`).
final class QrTransfer extends QrPayload {
  const QrTransfer(this.code);

  /// Sunucuya `transfer_code` olarak gönderilecek kod (ör. `AHBU-TR-...`).
  final String code;

  @override
  String toString() => 'QrTransfer(****)';
}

/// Wi-Fi ağ bilgisi (`WIFI:T:WPA;S:...;P:...;;`).
final class QrWifi extends QrPayload {
  const QrWifi(this.credentials);

  final WifiQrCredentials credentials;

  @override
  String toString() => 'QrWifi(ssid: ${credentials.ssid})';
}

/// Tanınmayan / geçersiz içerik.
final class QrUnknown extends QrPayload {
  const QrUnknown(this.reason, {this.detail});

  final QrUnknownReason reason;

  /// Kullanıcıya gösterilebilir ayrıntı (ör. "WEP desteklenmiyor").
  final String? detail;

  /// Kullanıcıya gösterilebilir Türkçe mesaj.
  String get message => detail ?? reason.message;

  @override
  String toString() => 'QrUnknown($reason)';
}

enum QrUnknownReason {
  empty('Karekod boş.'),
  tooLong('Karekod çok uzun.'),
  malformed('Karekod okunamadı veya bozuk.'),
  unrecognized('Geçersiz karekod formatı. Lütfen bilgileri kontrol edin.'),
  claimInvalid('Cihaz eşleme karekodu geçersiz.'),
  wifiInvalid('Wi-Fi karekodu geçersiz veya desteklenmiyor.');

  const QrUnknownReason(this.message);

  final String message;
}

/// Karekod/kod metnini türüne göre sınıflandırır. İzin listesi, https zorunluluğu, UID/PIN
/// desenleri ve uzunluk sınırı [QrClaimParser] / [WifiQrParser]'dadır.
///
/// Ayrım (büyük/küçük harf duyarsız önek):
///
/// | Önek / biçim | Sonuç |
/// |---|---|
/// | `AHBU-INVITE:<kod>` | [QrInvite] |
/// | `AHBU-TRANSFER:<kod>` veya `AHBU-TR-<kod>` | [QrTransfer] |
/// | `WIFI:...` | [QrWifi] (WEP/EAP/bozuk -> [QrUnknown]) |
/// | `https://<izinli>/claim?uid=&pin=` veya `{"uid":"","pin":""}` | [QrClaim] |
/// | (yalnızca [allowBareInviteCodes]) `AHBU-XXXXXX` / `AHBU-G-XXXXXX` | [QrInvite] |
/// | diğer her şey | [QrUnknown] |
class QrRouter {
  const QrRouter({this.allowedHosts, this.allowBareInviteCodes = false});

  /// Claim URL'si için izinli ana makineler (`null` = varsayılan: üretim sitesi).
  final Set<String>? allowedHosts;

  /// Elle kod girişi alanları için: çıplak davet kodlarını (`AHBU-123456`) davet sayar.
  /// Karekod taramasında kapalı tutulur (UID ile karışmasın).
  final bool allowBareInviteCodes;

  static const QrRouter instance = QrRouter();

  static final RegExp _inviteCode = RegExp(r'^[A-Z0-9][A-Z0-9-]{3,31}$');
  static final RegExp _transferCode = RegExp(r'^[A-Z0-9][A-Z0-9-]{3,39}$');
  static final RegExp _bareInvite = RegExp(r'^AHBU-(?:G-)?[A-Z0-9]{4,24}$');

  /// Kısa yol: varsayılan yönlendirici.
  static QrPayload route(String? raw) => instance.parse(raw);

  QrPayload parse(String? raw) {
    if (raw == null) return const QrUnknown(QrUnknownReason.empty);
    final text = raw.trim();
    if (text.isEmpty) return const QrUnknown(QrUnknownReason.empty);
    if (text.length > QrClaimParser.maxLength) return const QrUnknown(QrUnknownReason.tooLong);
    if (_hasControlCharacters(text)) return const QrUnknown(QrUnknownReason.malformed);

    final upper = text.toUpperCase();

    // 1) Önekli davet / devir kodları (en özel olan önce).
    if (upper.startsWith('AHBU-INVITE:')) {
      final code = upper.substring('AHBU-INVITE:'.length).trim();
      return _inviteCode.hasMatch(code)
          ? QrInvite(code)
          : const QrUnknown(QrUnknownReason.malformed);
    }
    if (upper.startsWith('AHBU-TRANSFER:')) {
      final code = upper.substring('AHBU-TRANSFER:'.length).trim();
      return _transferCode.hasMatch(code)
          ? QrTransfer(code)
          : const QrUnknown(QrUnknownReason.malformed);
    }
    if (upper.startsWith('AHBU-TR-')) {
      return _transferCode.hasMatch(upper)
          ? QrTransfer(upper)
          : const QrUnknown(QrUnknownReason.malformed);
    }

    // 2) Wi-Fi.
    if (upper.startsWith('WIFI:')) {
      final result = WifiQrParser.parseDetailed(text);
      final credentials = result.credentials;
      if (credentials != null) return QrWifi(credentials);
      return QrUnknown(QrUnknownReason.wifiInvalid, detail: result.error?.message);
    }

    // 3) Cihaz sahiplenme: https claim URL'si veya yalnızca-String JSON.
    if (text.startsWith('{') || upper.startsWith('HTTPS://') || upper.startsWith('HTTP://')) {
      final result = QrClaimParser.parseDetailed(text, allowedHosts: allowedHosts);
      final data = result.data;
      if (data != null) return QrClaim(uid: data.uid, pin: data.pin);
      return QrUnknown(QrUnknownReason.claimInvalid, detail: result.error?.message);
    }

    // 4) Elle giriş: çıplak davet kodu.
    if (allowBareInviteCodes && _bareInvite.hasMatch(upper)) return QrInvite(upper);

    return const QrUnknown(QrUnknownReason.unrecognized);
  }

  static bool _hasControlCharacters(String value) {
    for (final unit in value.codeUnits) {
      if (unit < 0x20 || unit == 0x7f) return true;
    }
    return false;
  }
}
