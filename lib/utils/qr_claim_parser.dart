import 'dart:convert';

class QrClaimData {
  final String uid;
  final String pin;

  const QrClaimData({
    required this.uid,
    required this.pin,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is QrClaimData &&
          runtimeType == other.runtimeType &&
          uid == other.uid &&
          pin == other.pin;

  @override
  int get hashCode => uid.hashCode ^ pin.hashCode;

  @override
  String toString() => 'QrClaimData(uid: $uid, pin: $pin)';
}

class QrClaimParser {
  /// Ham taranmış QR kod metnini çözümler.
  /// Desteklenen formatlar:
  /// 1. URL: `https://.../claim?uid=XYZ&pin=123456` (veya `device_uuid` & `setup_pin`)
  /// 2. JSON: `{"uid": "XYZ", "pin": "123456"}`
  /// 3. Düz Metin: `XYZ:123456` veya `XYZ/123456`
  static QrClaimData? parse(String? raw) {
    if (raw == null) return null;
    final text = raw.trim();
    if (text.isEmpty) return null;

    // 1. JSON Formatı
    if (text.startsWith('{') && text.endsWith('}')) {
      try {
        final map = jsonDecode(text) as Map<String, dynamic>;
        final uid = (map['uid'] ?? map['device_uuid'] ?? map['uuid'] ?? map['device_id'])?.toString().trim();
        final pin = (map['pin'] ?? map['setup_pin'] ?? map['code'])?.toString().trim();
        if (_isValid(uid, pin)) {
          return QrClaimData(uid: uid!, pin: pin!);
        }
      } catch (_) {}
    }

    // 2. URL Formatı
    try {
      final uri = Uri.parse(text);
      if (uri.hasQuery) {
        final q = uri.queryParameters;
        final uid = (q['uid'] ?? q['device_uuid'] ?? q['uuid'] ?? q['id'])?.trim();
        final pin = (q['pin'] ?? q['setup_pin'] ?? q['code'])?.trim();
        if (_isValid(uid, pin)) {
          return QrClaimData(uid: uid!, pin: pin!);
        }
      }
    } catch (_) {}

    // 3. Düz Metin Bölücüleri: ":" veya "/"
    if (text.contains(':')) {
      final parts = text.split(':');
      if (parts.length == 2) {
        final uid = parts[0].trim();
        final pin = parts[1].trim();
        if (_isValid(uid, pin)) {
          return QrClaimData(uid: uid, pin: pin);
        }
      }
    }

    if (text.contains('/')) {
      final parts = text.split('/');
      if (parts.length == 2) {
        final uid = parts[0].trim();
        final pin = parts[1].trim();
        if (_isValid(uid, pin)) {
          return QrClaimData(uid: uid, pin: pin);
        }
      }
    }

    return null;
  }

  static bool _isValid(String? uid, String? pin) {
    if (uid == null || uid.isEmpty) return false;
    if (pin == null || pin.length < 4 || pin.length > 10) return false;
    return true;
  }
}

