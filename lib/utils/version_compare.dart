/// Pano yazılım sürümü karşılaştırması (bireysel-1): `fw` alanı `MAJOR.MINOR[.PATCH]` (ör. `1.3.1`).
///
/// * Baştaki `v`/`V` ve sondaki ön sürüm / yapı eki (`-rc1`, `+abc`) yok sayılır: `1.3.0-rc1` = `1.3.0`
///   (pano yeteneği çekirdek sürüme bağlıdır).
/// * Eksik yama 0 sayılır (`1.3` = `1.3.0`); tek parça (`1`) ya da dörtten fazla parça bozuk sayılır.
/// * Biçim bozuksa (boş, sayı olmayan parça) sonuç `null`dur: çağıran sürüme dayalı uyarı GÖSTERMEZ.
library;

/// Bulut kimliğini kendiliğinden alan (`POST /devices/bootstrap`, CONTRACTS §3f) ilk pano yazılımı.
const String kCloudBootstrapMinFirmware = '1.3.0';

final RegExp _part = RegExp(r'^[0-9]{1,6}$');

/// [raw] -> `[major, minor, patch]`; bozuksa `null`.
List<int>? parseVersion(String? raw) {
  if (raw == null) return null;
  var s = raw.trim();
  if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
  for (final sep in const <String>['-', '+', ' ']) {
    final cut = s.indexOf(sep);
    if (cut >= 0) s = s.substring(0, cut);
  }
  if (s.isEmpty) return null;
  final parts = s.split('.');
  if (parts.length < 2 || parts.length > 3) return null;
  final out = <int>[];
  for (final p in parts) {
    if (!_part.hasMatch(p)) return null;
    out.add(int.parse(p));
  }
  while (out.length < 3) {
    out.add(0);
  }
  return out;
}

/// [a] ile [b]'yi karşılaştırır: negatif = [a] eski, 0 = eşit, pozitif = [a] yeni. Biri bozuksa `null`.
int? compareVersions(String? a, String? b) {
  final x = parseVersion(a);
  final y = parseVersion(b);
  if (x == null || y == null) return null;
  for (var i = 0; i < 3; i++) {
    final d = x[i].compareTo(y[i]);
    if (d != 0) return d;
  }
  return 0;
}

/// [version] en az [minimum] mi? Biri bozuksa `null` (bilinmiyor).
bool? versionAtLeast(String? version, String minimum) {
  final c = compareVersions(version, minimum);
  return c == null ? null : c >= 0;
}
