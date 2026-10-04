import 'dart:math' as math;

import 'package:flutter/material.dart';

/// AHBU "Neon Glass" tasarım belirteçleri (TEK kaynak).
///
/// Şartname: `docs/superpowers/analysis/gorsel-tasarim-v2.md` §2. Bu dosya yalnızca **veri** içerir
/// (renk aileleri, yüzey/rim/gölge, yarıçap/boşluk/orb boyutu, hareket süre/eğrileri); widget içermez ve
/// `app_theme.dart`/orb/hareket bileşenleri buna bağlanır. Mevcut `AppTheme.accent*`/`primary*` sabitleri
/// geriye uyum için KALIR; yeni bileşenler buradaki aileleri kullanır.

/// İki rengin WCAG kontrast oranı (1:1 .. 21:1). `AppTheme.contrastRatio` bunu kullanır.
double wcagContrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

// ---------------------------------------------------------------------------------------------
// 2.1 Renk aileleri
// ---------------------------------------------------------------------------------------------

/// Orb/parıltı için tek anlamsal renk ailesi: açık ton [light], ana ton [base], koyu ton [deep] ve parıltı
/// (halo) tonu [glow] (opak; çağıran alfa uygular).
@immutable
class AccentFamily {
  const AccentFamily({
    required this.name,
    required this.light,
    required this.base,
    required this.deep,
    required this.glow,
  });

  /// Hata ayıklama/test adı ('amber', 'emerald', ...).
  final String name;
  final Color light;
  final Color base;
  final Color deep;
  final Color glow;

  @override
  String toString() => 'AccentFamily($name)';
}

/// Şartname §2.1 tablosu. Anlamlar: amber = lamba AÇIK/uyarı/çocuk kilidi, emerald = panjur AÇ/başarı/bağlı,
/// sky = panjur KAPAT/birincil eylem, rose = DURDUR/tehlike/hata, violet = gece senaryosu/ek modül,
/// cyan = marka/teknoloji vurgusu/odak halkası, slate = nötr/pasif.
abstract final class AppFamilies {
  static const AccentFamily amber = AccentFamily(
    name: 'amber',
    light: Color(0xFFFFD36B),
    base: Color(0xFFFFB020),
    deep: Color(0xFFE07A00),
    glow: Color(0xFFFFBC3A),
  );
  static const AccentFamily emerald = AccentFamily(
    name: 'emerald',
    light: Color(0xFF6EE7B7),
    base: Color(0xFF10B981),
    deep: Color(0xFF047857),
    glow: Color(0xFF31C994),
  );
  static const AccentFamily sky = AccentFamily(
    name: 'sky',
    light: Color(0xFF93C5FD),
    base: Color(0xFF3B82F6),
    deep: Color(0xFF1D4ED8),
    glow: Color(0xFF5A99F8),
  );
  static const AccentFamily rose = AccentFamily(
    name: 'rose',
    light: Color(0xFFFDA4AF),
    base: Color(0xFFF43F5E),
    deep: Color(0xFFBE123C),
    glow: Color(0xFFF7627A),
  );
  static const AccentFamily violet = AccentFamily(
    name: 'violet',
    light: Color(0xFFD8B4FE),
    base: Color(0xFFA855F7),
    deep: Color(0xFF7E22CE),
    glow: Color(0xFFB976F9),
  );
  static const AccentFamily cyan = AccentFamily(
    name: 'cyan',
    light: Color(0xFFA5F3FC),
    base: Color(0xFF22D3EE),
    deep: Color(0xFF0E7490),
    glow: Color(0xFF50DEF3),
  );
  static const AccentFamily slate = AccentFamily(
    name: 'slate',
    light: Color(0xFFCBD5E1),
    base: Color(0xFF64748B),
    deep: Color(0xFF334155),
    glow: Color(0xFF8896A9),
  );

  /// Tüm aileler (test/galeri için sabit sıra).
  static const List<AccentFamily> all = <AccentFamily>[amber, emerald, sky, rose, violet, cyan, slate];
}

// ---------------------------------------------------------------------------------------------
// 2.2 Yüzey / rim / gölge
// ---------------------------------------------------------------------------------------------

/// Camsı yüzey belirteçleri (bir tema parlaklığı için). Şartname §2.2.
@immutable
class SurfaceTokens {
  const SurfaceTokens({
    required this.cardTop,
    required this.cardBottom,
    required this.raised,
    required this.rimStart,
    required this.rimEnd,
    required this.rimSolid,
    required this.shadow,
    required this.shadowBlur,
    required this.shadowOffset,
    required this.orbShadowAlpha,
    required this.orbShadowBlur,
    required this.orbShadowOffset,
  });

  /// Kart gövdesi dikey gradyanı: üst ve alt renk (opak).
  final Color cardTop;
  final Color cardBottom;

  /// Yükseltilmiş / basılı yüzey.
  final Color raised;

  /// Kenar ışığı (rim): sol-üstten sağ-alta gradyan başlangıç/bitiş renkleri.
  final Color rimStart;
  final Color rimEnd;

  /// `BoxDecoration.border` gibi gradyan taşımayan yerler için tek renkli rim karşılığı.
  final Color rimSolid;

  /// Çevresel gölge (statik; blur ≤ 24).
  final Color shadow;
  final double shadowBlur;
  final Offset shadowOffset;

  /// Orb gölgesi (açık temada parıltı yerine renkli gölge): vurgu rengine uygulanacak alfa/blur/öteleme.
  final double orbShadowAlpha;
  final double orbShadowBlur;
  final Offset orbShadowOffset;

  /// Koyu yüzeyler: zemin `#0B1120`, kart `#1B2740 → #141E33`, basılı `#223253`, rim `white@0.18 → 0.02`,
  /// gölge `black@0.40` blur 22 y+10.
  static const SurfaceTokens dark = SurfaceTokens(
    cardTop: Color(0xFF1B2740),
    cardBottom: Color(0xFF141E33),
    raised: Color(0xFF223253),
    rimStart: Color(0x2EFFFFFF), // white @ 0.18
    rimEnd: Color(0x05FFFFFF), // white @ 0.02
    rimSolid: Color(0x1AFFFFFF), // white @ 0.10
    shadow: Color(0x66000000), // black @ 0.40
    shadowBlur: 22,
    shadowOffset: Offset(0, 10),
    orbShadowAlpha: 0.0, // koyu temada orb gölgesi yerine parıltı (radyal gradyan) kullanılır
    orbShadowBlur: 0,
    orbShadowOffset: Offset.zero,
  );

  /// Açık yüzeyler: kart `#FFFFFF → #F6F8FC`, rim `#0B1016@0.08`, gölge `#101820@0.14` blur 18 y+8;
  /// orb gölgesi `accent@0.30` blur 14 y+6.
  static const SurfaceTokens light = SurfaceTokens(
    cardTop: Color(0xFFFFFFFF),
    cardBottom: Color(0xFFF6F8FC),
    raised: Color(0xFFEEF2F8),
    rimStart: Color(0x140B1016), // #0B1016 @ 0.08
    rimEnd: Color(0x0A0B1016),
    rimSolid: Color(0x140B1016),
    shadow: Color(0x24101820), // #101820 @ 0.14
    shadowBlur: 18,
    shadowOffset: Offset(0, 8),
    orbShadowAlpha: 0.30,
    orbShadowBlur: 14,
    orbShadowOffset: Offset(0, 6),
  );

  static SurfaceTokens of(Brightness brightness) => brightness == Brightness.dark ? dark : light;
}

/// Gradyan taşıyan "camsı" kart yüzeyi ve orb parıltısı için sabitler.
abstract final class AppGlass {
  /// Vurgulu (aktif) kartta kenar: `accent@0.55`, 1.4 px; parıltı `accent@0.14`.
  static const double accentRimAlpha = 0.55;
  static const double accentRimWidth = 1.4;
  static const double accentGlowAlpha = 0.14;

  /// Açık temada vurgulu kartın sol-üst radyal parıltısı. Koyudan (0.14) YÜKSEK olursa geniş kartlarda (tablet/masaüstü
  /// hero) üst kenara yapışık soluk bir "bulut lekesi" gibi okunur; açıkta beyaz zemin parıltıyı zaten belli eder.
  static const double accentGlowAlphaLight = 0.12;

  /// Vurgulu OLMAYAN ama `accent` verilmiş kartın gövde tonu (accent'in kart üst rengine karışma alfası). Koyu temada
  /// sıcak tonlar (amber, rose) lacivert yüzeyde gri-kahve "kir" gibi çıktığından çok hafif tutulur; vurgu ipucunu kenar
  /// (`accent@0.28`) verir.
  static const double accentTintAlphaDark = 0.02;
  static const double accentTintAlphaLight = 0.05;

  /// Orb parıltı seviyeleri (0..1): boşta (idle, "soluk parıltı") ve etkin (active). Tüm orb bileşenleri (`OrbCore`) buradan
  /// okur: ekranlar arası parıltı şiddeti tek belirteçten gelir.
  static const double orbGlowIdle = 0.30;
  static const double orbGlowActive = 0.85;

  /// Modal perde (diyalog `barrierColor`, alt sayfa `modalBarrierColor`, çekmece `scrimColor`): lacivert tonlu. Varsayılan
  /// `Colors.black54` açık temada soluk PCB görselini donuk gri-yeşil bir sisle örtüyordu.
  static const Color scrimDark = Color(0xA8050A14); // #050A14 @ 0.66
  static const Color scrimLight = Color(0x660F172A); // #0F172A @ 0.40
}

// ---------------------------------------------------------------------------------------------
// 2.3 Şekil / boşluk / boyut
// ---------------------------------------------------------------------------------------------

/// Köşe yarıçapları: 8 / 12 / 16 / **20 (kart)** / 24 (diyalog) / 28 (sheet) / 999 (hap/orb).
///
/// Kullanım kuralı: iç kutu/alan/bilgi kutusu [r12], kart içindeki kart/satır [r16], kart [card], diyalog [dialog], alt sayfa
/// [sheet]; düğme ve çip [pill] (stadium). 6/10/14 gibi ölçek dışı değerler KULLANILMAZ (en yakın belirtece indirilir).
abstract final class AppRadius {
  static const double r8 = 8;
  static const double r12 = 12;
  static const double r16 = 16;
  static const double card = 20;

  /// Diyalog yüzeyi (`dialogTheme`) ve onu taklit eden özel diyalog kabukları.
  static const double dialog = 24;
  static const double sheet = 28;
  static const double pill = 999;
}

/// 4'lü ızgara boşlukları.
abstract final class AppSpace {
  static const double s4 = 4;
  static const double s8 = 8;
  static const double s12 = 12;
  static const double s16 = 16;
  static const double s20 = 20;
  static const double s24 = 24;
  static const double s32 = 32;
}

/// Orb görsel çapları (xl 76 · lg 64 · md 52 · sm 44). Dokunma alanı HER ZAMAN en az
/// [AppTouch.minTarget] (48 dp): `sm` orb 44 dp çizilir, 48 dp yer kaplar.
enum OrbSize {
  xl(76),
  lg(64),
  md(52),
  sm(44);

  const OrbSize(this.diameter);

  /// Görsel çap (dp).
  final double diameter;

  /// Düzende kaplanan kenar: görsel çap ve dokunma hedefinin büyüğü.
  double get footprint => math.max(diameter, AppTouch.minTarget);

  /// Simge çapı (0.44 d).
  double get iconSize => diameter * 0.44;
}

/// Dokunma ve yazı alt sınırları.
abstract final class AppTouch {
  static const double minTarget = 48;
  static const double minFontSize = 12;
}

/// Yazı boyutu belirteçleri (ölçeklenmemiş sp; kullanıcının yazı ölçeği çarpar). HEPSİ [AppTouch.minFontSize] (12 sp) ve
/// üstündedir: rozet, çip, durum hapı, istatistik etiketi ve yardımcı metin 12 sp'nin altına İNMEZ (kodda 9.5–11.5 sp'lik
/// ≈ 48 yer vardı). Yeni metin `fontSize: 11` yerine bu belirteçlerden birini kullanmalıdır.
abstract final class AppText {
  /// Rozet / çip / durum hapı / istatistik etiketi (kalın).
  static const double badge = 12;

  /// Kart içi ikincil metin, alt başlık, yardımcı/dipnot metni.
  static const double caption = 12.5;

  /// Gövde metni (kart satırı, açıklama).
  static const double body = 14;

  /// Kart başlığı.
  static const double cardTitle = 15;

  /// Bölüm / diyalog / AppBar başlığı (`AppBarTheme` ve `DialogThemeData` ile aynı).
  static const double title = 18;

  /// Sayaç / büyük değer.
  static const double metric = 28;
}

// ---------------------------------------------------------------------------------------------
// 2.4 Hareket belirteçleri
// ---------------------------------------------------------------------------------------------

/// Hareket süreleri/eğrileri. Dekoratif hareket 120–350 ms, imza hareketler ≤ 480 ms; sayfa geçişi ≤ 280 ms.
abstract final class AppMotion {
  static const Duration instant = Duration(milliseconds: 90);
  static const Duration fast = Duration(milliseconds: 140);
  static const Duration base = Duration(milliseconds: 220);
  static const Duration slow = Duration(milliseconds: 320);
  static const Duration hero = Duration(milliseconds: 480);

  /// Sayfa geçişi (giden + gelen birlikte) en çok 280 ms.
  static const Duration pageTransition = Duration(milliseconds: 260);

  /// Kademeli girişte öğe başına aralık (40–45 ms) ve en çok kademelenen öğe sayısı.
  static const Duration staggerStep = Duration(milliseconds: 40);
  static const int staggerMaxItems = 8;

  /// Varsayılan eğri.
  static const Curve standard = Curves.easeOutCubic;

  /// Basma-bırakma/açılma yaylanması (`SpringCurve(damping: 0.72)`).
  static const Curve spring = SpringCurve();

  /// `Curves.linear` YALNIZ motor hareketi/ilerleme için.
  static const Curve linear = Curves.linear;
}

/// Sönümlü yay adım yanıtı: `0 → 1` arasında en fazla yüzde birkaç aşar ve oturur.
///
/// `damping` (ζ, 0..1): küçük değer daha çok aşım. Varsayılan 0.72 ≈ %3.8 aşım ("1.0 → 1.04 → 1.0" yaylanması).
/// [settle]: eğrinin sonunda kalan genlik (yay süresi buna göre ölçeklenir; 0.01 = %1).
/// `transform(0) == 0` ve `transform(1) == 1` TAM olarak sağlanır (artık, doğrusal düzeltmeyle yok edilir).
class SpringCurve extends Curve {
  const SpringCurve({this.damping = 0.72, this.settle = 0.01})
      : assert(damping > 0 && damping < 1),
        assert(settle > 0 && settle < 1);

  final double damping;
  final double settle;

  @override
  double transformInternal(double t) {
    final zeta = damping;
    final omega = -math.log(settle) / zeta; // sönüm: e^{-ζωt} = settle @ t = 1
    final wd = omega * math.sqrt(1 - zeta * zeta);
    final k = zeta / math.sqrt(1 - zeta * zeta);
    double raw(double x) =>
        1 - math.exp(-zeta * omega * x) * (math.cos(wd * x) + k * math.sin(wd * x));
    // y(1) tam 1 olmayabilir (artık ≤ settle): doğrusal terimle uca oturt.
    return raw(t) + (1 - raw(1)) * t;
  }

  @override
  String toString() => 'SpringCurve(damping: $damping)';
}

/// Haptik geri bildirim seçenekleri (şartname §5): `selectionClick` aç/kapat, `lightImpact` senaryo,
/// `mediumImpact` durdur/yıkıcı onay.
enum PressHaptic { none, selection, light, medium, heavy }
