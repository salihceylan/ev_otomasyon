/// Sunucu UTC zamanlarını (`...Z`) kullanıcıya **yerel saatle** gösteren küçük biçimleyiciler
/// (CONTRACTS §0: "İstemci gösterirken `toLocal()` kullanır"). `intl` gerekmez.
String _two(int value) => value.toString().padLeft(2, '0');

/// `gg.aa.yyyy ss:dd` (yerel saat). UTC değer `toLocal()` ile çevrilir.
String formatLocalDateTime(DateTime value) {
  final l = value.toLocal();
  return '${_two(l.day)}.${_two(l.month)}.${l.year} ${_two(l.hour)}:${_two(l.minute)}';
}

/// `ss:dd` (yerel saat).
String formatLocalTime(DateTime value) {
  final l = value.toLocal();
  return '${_two(l.hour)}:${_two(l.minute)}';
}

/// Kalan süre: `2 gün 3 saat`, `5 saat 20 dk`, `12 dk`, `45 sn`; süre bittiyse `Süresi doldu`.
String formatRemaining(Duration remaining) {
  if (remaining.isNegative || remaining == Duration.zero) return 'Süresi doldu';
  final days = remaining.inDays;
  final hours = remaining.inHours % 24;
  final minutes = remaining.inMinutes % 60;
  if (days > 0) return hours > 0 ? '$days gün $hours saat' : '$days gün';
  if (remaining.inHours > 0) return minutes > 0 ? '${remaining.inHours} saat $minutes dk' : '${remaining.inHours} saat';
  if (remaining.inMinutes > 0) return '${remaining.inMinutes} dk';
  return '${remaining.inSeconds} sn';
}

/// `d:ss` (geri sayım sayacı).
String formatCountdown(int totalSeconds) {
  final s = totalSeconds < 0 ? 0 : totalSeconds;
  return '${s ~/ 60}:${_two(s % 60)}';
}
