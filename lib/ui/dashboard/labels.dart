import 'package:flutter/material.dart';

import '../../models/capabilities.dart';

// =============================================================================
// Arayüz metin/biçim yardımcıları (saf fonksiyonlar; widget bağımsız, birim testli).
// =============================================================================

/// Türkçe'ye duyarlı küçük harf (`I` -> `ı`, `İ` -> `i`).
String turkishLower(String input) =>
    input.replaceAll('İ', 'i').replaceAll('I', 'ı').toLowerCase();

/// Türkçe'ye duyarlı büyük harf (`i` -> `İ`, `ı` -> `I`).
String turkishUpper(String input) =>
    input.replaceAll('i', 'İ').replaceAll('ı', 'I').toUpperCase();

/// Her sözcüğün ilk harfi büyük, kalanı küçük (Türkçe harf kurallarıyla).
String turkishTitleCase(String input) {
  final words = input.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  return words.map((word) {
    final chars = word.characters;
    final first = turkishUpper(chars.first);
    final rest = turkishLower(chars.skip(1).toString());
    return '$first$rest';
  }).join(' ');
}

/// Adı olmayan kullanıcı için güvenli baş harf (emoji/yedek çift kodlu karakterlerde bile bozulmaz).
String initialOf(String? name, {String fallback = 'U'}) {
  final text = (name ?? '').trim();
  if (text.isEmpty) return fallback;
  return turkishUpper(text.characters.first);
}

/// "Ayşe Yılmaz" -> "Ayşe"; boşsa e-postanın yerel kısmı, o da yoksa [fallback].
String firstNameOf(String? fullName, {String? email, String fallback = 'Kullanıcı'}) {
  final name = (fullName ?? '').trim();
  if (name.isNotEmpty) return name.split(RegExp(r'\s+')).first;
  final mail = (email ?? '').trim();
  final at = mail.indexOf('@');
  if (at > 0) return mail.substring(0, at);
  return fallback;
}

// -----------------------------------------------------------------------------
// Odalar (sunucudaki `room` değeri serbest metindir: `salon`, `yatak_odasi`, `Yatak Odası` ...)
// -----------------------------------------------------------------------------

/// Oda adının karşılaştırma anahtarı: küçük harf, aksansız, `_`/`-` -> boşluk. Boşsa `genel`.
String roomKey(String raw) {
  var s = turkishLower(raw.trim());
  s = s
      .replaceAll('ı', 'i')
      .replaceAll('ö', 'o')
      .replaceAll('ü', 'u')
      .replaceAll('ş', 's')
      .replaceAll('ç', 'c')
      .replaceAll('ğ', 'g')
      .replaceAll(RegExp(r'[_\-\s]+'), ' ')
      .trim();
  return s.isEmpty ? 'genel' : s;
}

const Map<String, String> _knownRooms = <String, String>{
  'genel': 'Genel',
  'salon': 'Salon',
  'mutfak': 'Mutfak',
  'yatak odasi': 'Yatak Odası',
  'cocuk odasi': 'Çocuk Odası',
  'misafir odasi': 'Misafir Odası',
  'oturma odasi': 'Oturma Odası',
  'yemek odasi': 'Yemek Odası',
  'calisma odasi': 'Çalışma Odası',
  'antre': 'Antre',
  'giris': 'Giriş',
  'hol': 'Hol',
  'koridor': 'Koridor',
  'balkon': 'Balkon',
  'teras': 'Teras',
  'banyo': 'Banyo',
  'wc': 'WC',
  'tuvalet': 'Tuvalet',
  'bahce': 'Bahçe',
  'garaj': 'Garaj',
  'depo': 'Depo',
  'kiler': 'Kiler',
  'cati': 'Çatı',
  'ofis': 'Ofis',
};

/// Oda adının okunur etiketi (`yatak_odasi` -> `Yatak Odası`). Bilinmeyen adlar baş harfleri
/// büyütülerek gösterilir; boşsa `Genel`.
String roomLabel(String raw) {
  final key = roomKey(raw);
  final known = _knownRooms[key];
  if (known != null) return known;
  return turkishTitleCase(raw.replaceAll(RegExp(r'[_\-]+'), ' '));
}

// -----------------------------------------------------------------------------
// Roller
// -----------------------------------------------------------------------------

/// Aktif evdeki rolün Türkçe adı.
String homeRoleLabel(HomeRole? role) {
  switch (role) {
    case HomeRole.owner:
      return 'Ev Sahibi';
    case HomeRole.resident:
      return 'Aile Üyesi';
    case HomeRole.guest:
      return 'Misafir';
    case HomeRole.serviceUser:
      return 'Yetkili Servis';
    case HomeRole.serviceSession:
      return 'Servis Oturumu';
    case HomeRole.unknown:
    case null:
      return 'Tanımsız';
  }
}

/// Hesabın küresel rolünün Türkçe adı.
String globalRoleLabel(GlobalRole role) {
  switch (role) {
    case GlobalRole.user:
      return 'Ev Kullanıcısı';
    case GlobalRole.serviceUser:
      return 'Yetkili Servis Sorumlusu';
    case GlobalRole.superUser:
      return 'Süper Yönetici';
    case GlobalRole.serviceSession:
      return 'Geçici Servis Oturumu';
    case GlobalRole.unknown:
      return 'Tanımsız';
  }
}

// -----------------------------------------------------------------------------
// Zaman
// -----------------------------------------------------------------------------

String _two(int v) => v.toString().padLeft(2, '0');

/// `HH:mm` (yerel saat).
String formatClock(DateTime time) {
  final local = time.toLocal();
  return '${_two(local.hour)}:${_two(local.minute)}';
}

/// Bugünse `HH:mm`, değilse `gg.aa HH:mm` ([now] verilmezse sistem saati).
String formatWhen(DateTime time, {DateTime? now}) {
  final local = time.toLocal();
  final ref = (now ?? DateTime.now()).toLocal();
  final sameDay = local.year == ref.year && local.month == ref.month && local.day == ref.day;
  return sameDay ? formatClock(local) : '${_two(local.day)}.${_two(local.month)} ${formatClock(local)}';
}

/// Kalan süre: 1 saat ve üstüyse `S sa DD dk SS sn`, değilse `DD:SS` (negatif süre `00:00`).
String formatRemaining(Duration remaining) {
  final total = remaining.isNegative ? 0 : remaining.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  if (h > 0) return '$h sa ${_two(m)} dk ${_two(s)} sn';
  return '${_two(m)}:${_two(s)}';
}

/// "123456" -> "123 456" (gösterim; değer değişmez).
String groupDigits(String value) {
  final cleaned = value.trim();
  if (cleaned.length <= 3) return cleaned;
  final mid = cleaned.length ~/ 2;
  return '${cleaned.substring(0, mid)} ${cleaned.substring(mid)}';
}
