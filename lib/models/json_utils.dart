import 'package:flutter/foundation.dart';

/// Sunucu/cihaz JSON'u için savunmacı dönüştürücüler.
///
/// Denetimde bulunan "tip hatası" sınıfındaki çökmelerin (ör. UUID'nin `int`e atanması,
/// `num` yerine `int` beklenmesi, tek bozuk kaydın tüm listeyi silmesi) kaynağı gevşek
/// dönüşümlerin olmamasıydı. Tüm modeller bu yardımcıları kullanır.

/// `int`, `num` (ondalık kesilir) veya sayı içeren `String` -> `int`; olmazsa `null`.
int? asInt(Object? value) {
  if (value is int) return value;
  if (value is num) {
    if (value.isNaN || value.isInfinite) return null;
    return value.toInt();
  }
  if (value is String) {
    final text = value.trim();
    if (text.isEmpty) return null;
    return int.tryParse(text) ?? double.tryParse(text)?.toInt();
  }
  return null;
}

/// `bool`, sayı (0 = false) veya yaygın metin biçimleri -> `bool`; anlaşılmazsa `null`.
bool? asBool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    switch (value.trim().toLowerCase()) {
      case 'true':
      case 't':
      case '1':
      case 'yes':
      case 'on':
        return true;
      case 'false':
      case 'f':
      case '0':
      case 'no':
      case 'off':
        return false;
    }
  }
  return null;
}

/// `String` olduğu gibi, sayı/bool metne çevrilir; diğerleri (Map/List/null) `null`.
String? asString(Object? value) {
  if (value is String) return value;
  if (value is num || value is bool) return value.toString();
  return null;
}

/// Boş olmayan (kırpılmış) metin; yoksa `null`.
String? asNonEmptyString(Object? value) {
  final text = asString(value)?.trim();
  if (text == null || text.isEmpty) return null;
  return text;
}

/// `Map` -> `Map<String, dynamic>`; olmazsa `null`.
Map<String, dynamic>? asMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, dynamic v) => MapEntry(key.toString(), v));
  }
  return null;
}

/// `List` -> `List<dynamic>`; olmazsa `null`.
List<dynamic>? asList(Object? value) => value is List ? value : null;

final RegExp _hasZone = RegExp(r'(Z|z|[+-]\d{2}:?\d{2})$');

/// ISO-8601 zaman damgası. Sunucu sözleşmesi UTC (`...Z`) üretir; saat dilimi eki
/// eksikse değer UTC kabul edilir (yerel saat sanılmaz). Geçersizse `null`.
DateTime? asDate(Object? value) {
  if (value is DateTime) return value;
  final text = asNonEmptyString(value);
  if (text == null) return null;
  final normalized = (text.contains('T') && !_hasZone.hasMatch(text)) ? '${text}Z' : text;
  return DateTime.tryParse(normalized);
}

/// Bir değeri [min]..[max] aralığına sıkıştırır.
int clampInt(int value, int min, int max) => value < min ? min : (value > max ? max : value);

/// Ham liste içindeki her kaydı ayrı ayrı çözer; **bozuk bir kayıt tüm listeyi düşürmez**
/// (atlanır ve içerik yazdırılmadan loglanır).
List<T> parseList<T>(
  Object? raw,
  T Function(Map<String, dynamic> json) parse, {
  String? label,
}) {
  final list = asList(raw);
  if (list == null) return <T>[];
  final out = <T>[];
  var skipped = 0;
  for (final item in list) {
    final map = asMap(item);
    if (map == null) {
      skipped++;
      continue;
    }
    try {
      out.add(parse(map));
    } catch (_) {
      skipped++;
    }
  }
  if (skipped > 0 && kDebugMode) {
    debugPrint('[Model] ${label ?? T.toString()}: $skipped bozuk kayıt atlandı');
  }
  return out;
}
