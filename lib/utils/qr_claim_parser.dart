import 'dart:convert';

import '../config/app_config.dart';

/// Etiket karekodundan çıkan cihaz sahiplenme verisi (UID + kurulum PIN'i).
class QrClaimData {
  const QrClaimData({required this.uid, required this.pin});

  /// Normalleştirilmiş cihaz kimliği (`AHBU-...`, büyük harf).
  final String uid;

  /// 6 haneli kurulum PIN'i.
  final String pin;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is QrClaimData &&
          runtimeType == other.runtimeType &&
          uid == other.uid &&
          pin == other.pin;

  @override
  int get hashCode => uid.hashCode ^ pin.hashCode;

  /// PIN gizlenir (log/hata ayıklama çıktısına sızmasın).
  @override
  String toString() => 'QrClaimData(uid: $uid, pin: ******)';
}

/// Sıkı cihaz sahiplenme (claim) karekod çözücü.
///
/// Kabul edilen **yalnızca iki** biçim:
///
/// 1. `https://<izinli ana makine>/claim?uid=AHBU-...&pin=123456` — yalnızca `https`, kullanıcı
///    bilgisi yok, varsayılan port, `path == /claim`, tekrarlayan parametre yok.
/// 2. `{"uid":"AHBU-...","pin":"123456"}` — **yalnızca `String`** değerler (sayı olarak PIN baştaki
///    sıfırı kaybeder, reddedilir).
///
/// UID `^AHBU-[A-Z0-9-]{3,32}$` (kırp + büyük harf), PIN `^\d{6}$`. Metin 512 karakteri aşamaz.
/// **Ham metin hiçbir zaman cihaz kimliği olmaz**: serbest metin (`UID:PIN`, `UID/PIN`, yalnızca UID)
/// reddedilir. Davet/devir/Wi-Fi karekodları için bkz. `QrRouter`.
class QrClaimParser {
  QrClaimParser._();

  /// Karekod / form metni uzunluk sınırı.
  static const int maxLength = 512;

  static final RegExp uidPattern = RegExp(r'^AHBU-[A-Z0-9-]{3,32}$');
  static final RegExp pinPattern = RegExp(r'^\d{6}$');

  /// Davet/devir kodlarıyla karışmaması için cihaz kimliği olamayacak ön ekler.
  static const List<String> _reservedUidPrefixes = <String>[
    'AHBU-INVITE',
    'AHBU-TRANSFER',
    'AHBU-TR-',
  ];

  /// İzinli ana makineler: üretim sitesi (+ yalnızca hata ayıklama/QA derlemesinde `API_BASE_URL`
  /// ana makinesi; release derlemede `AppConfig` override'ı yok sayar).
  static Set<String> get defaultAllowedHosts {
    final hosts = <String>{AppConfig.productionHost.toLowerCase()};
    final apiHost = AppConfig.current.apiHost.toLowerCase();
    if (apiHost.isNotEmpty) hosts.add(apiHost);
    return hosts;
  }

  /// Cihaz kimliğini normalleştirir (kırp + büyük harf) ve doğrular; geçersizse `null`.
  static String? normalizeUid(String? raw) {
    if (raw == null) return null;
    final uid = raw.trim().toUpperCase();
    if (!uidPattern.hasMatch(uid)) return null;
    for (final prefix in _reservedUidPrefixes) {
      if (uid.startsWith(prefix)) return null;
    }
    return uid;
  }

  static bool isValidUid(String? raw) => normalizeUid(raw) != null;

  /// PIN tam 6 rakam mı (kırpılmış).
  static bool isValidPin(String? raw) => raw != null && pinPattern.hasMatch(raw.trim());

  /// Sıkı çözümleme; geçerli bir sahiplenme karekodu değilse `null`.
  static QrClaimData? parse(String? raw, {Set<String>? allowedHosts}) {
    final result = parseDetailed(raw, allowedHosts: allowedHosts);
    return result.data;
  }

  /// Neden reddedildiğini de döndürür.
  static QrClaimParseResult parseDetailed(String? raw, {Set<String>? allowedHosts}) {
    if (raw == null) return const QrClaimParseResult.failed(QrClaimError.empty);
    final text = raw.trim();
    if (text.isEmpty) return const QrClaimParseResult.failed(QrClaimError.empty);
    if (text.length > maxLength) return const QrClaimParseResult.failed(QrClaimError.tooLong);
    if (_hasControlCharacters(text)) {
      return const QrClaimParseResult.failed(QrClaimError.malformed);
    }
    if (text.startsWith('{')) return _fromJson(text);
    return _fromUrl(text, allowedHosts ?? defaultAllowedHosts);
  }

  static QrClaimParseResult _fromJson(String text) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return const QrClaimParseResult.failed(QrClaimError.malformed);
    }
    if (decoded is! Map) return const QrClaimParseResult.failed(QrClaimError.malformed);

    final uidRaw = decoded.containsKey('uid') ? decoded['uid'] : decoded['device_uuid'];
    final pinRaw = decoded.containsKey('pin') ? decoded['pin'] : decoded['setup_pin'];
    // Yalnızca String: sayı/boolean/null değerler reddedilir.
    if (uidRaw is! String) return const QrClaimParseResult.failed(QrClaimError.badUid);
    if (pinRaw is! String) return const QrClaimParseResult.failed(QrClaimError.badPin);
    return _build(uidRaw, pinRaw);
  }

  static QrClaimParseResult _fromUrl(String text, Set<String> allowedHosts) {
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasScheme) {
      return const QrClaimParseResult.failed(QrClaimError.malformed);
    }
    if (uri.scheme != 'https') return const QrClaimParseResult.failed(QrClaimError.notHttps);
    if (uri.userInfo.isNotEmpty) {
      return const QrClaimParseResult.failed(QrClaimError.hostNotAllowed);
    }
    final host = uri.host.toLowerCase();
    final normalizedAllowed = allowedHosts.map((h) => h.toLowerCase()).toSet();
    if (host.isEmpty || !normalizedAllowed.contains(host)) {
      return const QrClaimParseResult.failed(QrClaimError.hostNotAllowed);
    }
    if (uri.hasPort && uri.port != 443) {
      return const QrClaimParseResult.failed(QrClaimError.hostNotAllowed);
    }
    if (uri.path != '/claim') return const QrClaimParseResult.failed(QrClaimError.badPath);

    final all = uri.queryParametersAll;
    String? single(List<String> names) {
      String? found;
      for (final name in names) {
        final values = all[name];
        if (values == null) continue;
        if (values.length != 1 || found != null) return null; // tekrar / çakışma
        found = values.first;
      }
      return found;
    }

    final uid = single(const ['uid', 'device_uuid']);
    final pin = single(const ['pin', 'setup_pin']);
    if (uid == null) return const QrClaimParseResult.failed(QrClaimError.badUid);
    if (pin == null) return const QrClaimParseResult.failed(QrClaimError.missingPin);
    return _build(uid, pin);
  }

  static QrClaimParseResult _build(String uidRaw, String pinRaw) {
    final uid = normalizeUid(uidRaw);
    if (uid == null) return const QrClaimParseResult.failed(QrClaimError.badUid);
    final pin = pinRaw.trim();
    if (!pinPattern.hasMatch(pin)) return const QrClaimParseResult.failed(QrClaimError.badPin);
    return QrClaimParseResult.ok(QrClaimData(uid: uid, pin: pin));
  }

  static bool _hasControlCharacters(String value) {
    for (final unit in value.codeUnits) {
      if (unit < 0x20 || unit == 0x7f) return true;
    }
    return false;
  }
}

/// Sahiplenme karekodu hata türü.
enum QrClaimError {
  empty('Karekod boş.'),
  tooLong('Karekod çok uzun.'),
  malformed('Karekod okunamadı veya bozuk.'),
  notHttps('Karekod güvenli (https) bir adres içermiyor.'),
  hostNotAllowed('Bu karekod tanınan bir sunucuya ait değil.'),
  badPath('Bu karekod bir cihaz eşleme karekodu değil.'),
  badUid('Cihaz kimliği geçersiz.'),
  missingPin('Karekodda kurulum PIN\'i yok.'),
  badPin('Kurulum PIN\'i 6 haneli olmalıdır.');

  const QrClaimError(this.message);

  /// Kullanıcıya gösterilebilir Türkçe mesaj.
  final String message;
}

class QrClaimParseResult {
  const QrClaimParseResult.ok(QrClaimData this.data) : error = null;
  const QrClaimParseResult.failed(QrClaimError this.error) : data = null;

  final QrClaimData? data;
  final QrClaimError? error;

  bool get isOk => data != null;
}
