import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// Bir orb'un çözümlenmiş renk takımı (gövde gradyanı, parıltı, simge, rim).
///
/// Üç hazır takım vardır: aile rengi ([OrbColors.family]), koyu/açık "cam" (kapalı `OrbToggle`:
/// [OrbColors.glass]) ve devre dışı ([OrbColors.disabled]). [lerp] iki takım arasında geçiş yapar
/// (`OrbToggle` kapalı → açık).
@immutable
class OrbColors {
  const OrbColors({
    required this.light,
    required this.base,
    required this.deep,
    required this.glow,
    required this.icon,
    required this.rimStart,
    required this.rimEnd,
    required this.specular,
    required this.glowScale,
  });

  /// Gövde radyal gradyanı: [light] → [base] → [deep] (stops 0 / .55 / 1).
  final Color light;
  final Color base;
  final Color deep;

  /// Dış parıltı (halo) rengi (opak; alfa çizimde uygulanır).
  final Color glow;

  /// Simge rengi: gövde üstünde ≥ 3:1 kontrast (beyaz ya da koyu mürekkep).
  final Color icon;

  /// Kenar ışığı gradyanı (sol-üst → sağ-alt).
  final Color rimStart;
  final Color rimEnd;

  /// Speküler vurgu çarpanı (0..1; devre dışı/cam daha sönük).
  final double specular;

  /// Parıltı çarpanı (0 = hiç parıltı yok: devre dışı).
  final double glowScale;

  /// Koyu mürekkep (açık gövdeler üstündeki simge).
  static Color inkFor(AccentFamily f) {
    final hsl = HSLColor.fromColor(f.deep);
    return hsl.withLightness(0.09).withSaturation((hsl.saturation * 0.8).clamp(0.3, 0.7)).toColor();
  }

  /// Simgenin altındaki gövde örnekleri (merkez, merkezin biraz açığı, taban); beyaz için en kötü durum
  /// speküler vurgunun bindirdiği beyazı da içerir.
  static List<Color> _samples(AccentFamily f) {
    final center = Color.lerp(f.light, f.base, 0.49)!;
    return <Color>[
      center,
      Color.lerp(f.light, f.base, 0.25)!,
      f.base,
      Color.alphaBlend(Colors.white.withValues(alpha: 0.28), center),
    ];
  }

  /// Simge rengi: beyaz ve koyu mürekkepten, en kötü örnekte daha yüksek kontrast verenini seçer.
  static Color iconFor(AccentFamily f) {
    final ink = inkFor(f);
    double worst(Color c) {
      var w = double.infinity;
      for (final s in _samples(f)) {
        final r = wcagContrast(c, s);
        if (r < w) w = r;
      }
      return w;
    }

    return worst(Colors.white) >= worst(ink) ? Colors.white : ink;
  }

  static final Map<AccentFamily, OrbColors> _familyCache = <AccentFamily, OrbColors>{};

  /// Aile rengi takımı (koyu/açık temada aynı gövde; parıltı/gölge farkı çizimde). Sonuç önbelleklenir.
  factory OrbColors.family(AccentFamily f) => _familyCache.putIfAbsent(f, () => OrbColors._family(f));

  factory OrbColors._family(AccentFamily f) => OrbColors(
        light: f.light,
        base: f.base,
        deep: f.deep,
        glow: f.glow,
        icon: iconFor(f),
        rimStart: Colors.white.withValues(alpha: 0.70),
        rimEnd: Colors.white.withValues(alpha: 0.05),
        specular: 1.0,
        glowScale: 1.0,
      );

  /// Kapalı `OrbToggle`: koyu cam küre (açık temada açık cam).
  factory OrbColors.glass(Brightness brightness) {
    if (brightness == Brightness.dark) {
      return OrbColors(
        light: const Color(0xFF34456B),
        base: const Color(0xFF202D4A),
        deep: const Color(0xFF121A2E),
        glow: AppFamilies.slate.glow,
        icon: const Color(0xFFD2DBEC),
        rimStart: Colors.white.withValues(alpha: 0.38),
        rimEnd: Colors.white.withValues(alpha: 0.05),
        specular: 0.35,
        glowScale: 0.0,
      );
    }
    return OrbColors(
      light: const Color(0xFFFFFFFF),
      base: const Color(0xFFEDF1F8),
      deep: const Color(0xFFCBD5E3),
      glow: AppFamilies.slate.glow,
      icon: const Color(0xFF55657C),
      rimStart: const Color(0xFFFFFFFF).withValues(alpha: 0.95),
      rimEnd: const Color(0xFF0B1016).withValues(alpha: 0.16),
      specular: 0.8,
      glowScale: 0.0,
    );
  }

  /// Devre dışı: doygunluğu düşük gri küre, parıltı yok, kenar ≥ 3:1.
  factory OrbColors.disabled(Brightness brightness) {
    if (brightness == Brightness.dark) {
      return OrbColors(
        light: const Color(0xFF4A5A75),
        base: const Color(0xFF334155),
        deep: const Color(0xFF1E293B),
        glow: AppFamilies.slate.glow,
        icon: const Color(0xFFC3CEE0),
        rimStart: AppFamilies.slate.light.withValues(alpha: 0.60),
        rimEnd: AppFamilies.slate.light.withValues(alpha: 0.50),
        specular: 0.15,
        glowScale: 0.0,
      );
    }
    // Açık tema: kenar kartta ≥ 3:1 KALIR (testle pinli) ama eskisinden (slate.deep@0.75 ≈ 5:1 → @0.65 ≈ 3.8:1) hafiftir
    // (@0.68 ≈ 4.1 → @0.60 ≈ 3.3): pasif orb sayfanın en koyu konturu olup etkin orb'dan baskın okunmasın. Simge `muted`
    // metin rengi (#4B5B70; eskiden #3F4D61): pasif satırda tek soluk mürekkep.
    return OrbColors(
      light: const Color(0xFFE2E8F0),
      base: const Color(0xFFCBD5E1),
      deep: const Color(0xFFA9B6C8),
      glow: AppFamilies.slate.glow,
      icon: const Color(0xFF4B5B70),
      rimStart: AppFamilies.slate.deep.withValues(alpha: 0.68),
      rimEnd: AppFamilies.slate.deep.withValues(alpha: 0.60),
      specular: 0.3,
      glowScale: 0.0,
    );
  }

  static final Map<(AccentFamily, Brightness, int), OrbColors> _mutedCache = <(AccentFamily, Brightness, int), OrbColors>{};

  /// Salt-okunur ama AÇIK bir anahtarın (`OrbToggle(value: true, onChanged: null)`) gövdesi: devre dışı griyle [family]
  /// tonunun [mix] (0..1) karışımı. Gri orb "kapalı/pasif" ile karışıyordu (açık bir lamba kartı amber kenar/parıltı
  /// gösterirken orb'u gri kalıyordu); soluk aile tonu "açık" olduğunu orb'dan da okutur. Parıltı yok; kenar, speküler
  /// ve parıltı çarpanı devre dışı takımından kalır. Simge rengi karışık gövde üstünde ≥ 3:1 olacak biçimde seçilir:
  /// önce devre dışı simge rengi (gri görünüm korunur), yetmezse beyaz, sonra koyu mürekkep. `mix <= 0` ⇒ düz
  /// [OrbColors.disabled]. Sonuç önbelleklenir.
  factory OrbColors.mutedFamily(AccentFamily family, Brightness brightness, double mix) {
    // Karışım 1/20 adımlara yuvarlanır: toggle geçişi sırasında önbellek sınırsız büyümez (en çok 21 giriş/aile/tema).
    final step = (mix.clamp(0.0, 1.0) * 20).round();
    if (step <= 0) return OrbColors.disabled(brightness);
    final k = step / 20;
    return _mutedCache.putIfAbsent((family, brightness, step), () {
      if (brightness == Brightness.light) return _mutedLight(family, k);
      final grey = OrbColors.disabled(brightness);
      final tint = OrbColors.lerp(grey, OrbColors.family(family), k);
      final center = Color.lerp(tint.light, tint.base, 0.49)!;
      final bodies = <Color>[
        Color.lerp(tint.light, tint.base, 0.20)!,
        center,
        tint.base,
        Color.lerp(tint.base, tint.deep, 0.30)!,
        Color.alphaBlend(Colors.white.withValues(alpha: 0.28 * grey.specular), center),
      ];
      double worst(Color icon) => bodies.map((b) => wcagContrast(icon, b)).reduce((a, b) => a < b ? a : b);
      final candidates = <Color>[grey.icon, Colors.white, inkFor(family)];
      var icon = candidates.first;
      var best = -1.0;
      for (final c in candidates) {
        final w = worst(c);
        if (w >= 3.3) {
          icon = c;
          best = double.infinity;
          break;
        }
        if (w > best) {
          best = w;
          icon = c;
        }
      }
      return OrbColors(
        light: tint.light,
        base: tint.base,
        deep: tint.deep,
        glow: tint.glow,
        icon: icon,
        rimStart: grey.rimStart,
        rimEnd: grey.rimEnd,
        specular: grey.specular,
        glowScale: grey.glowScale,
      );
    });
  }

  /// Açık temada pastel gövdenin TAM ağırlığa ulaştığı karışım (`OrbCore.mutedFamilyMix` ile aynı: 0.40). Daha azı
  /// (toggle geçişinde `0.4 × progress`) gövdeyi devre dışı griden pasteline orantılı taşır.
  static const double _paleFullMix = 0.40;

  /// Açık temada kenarın kartlara karşı hedef kontrastı (≥ 3:1 + küçük pay); soluk orb'un kenarı etkin orb'unkinden hafiftir.
  static const double _paleRimContrast = 3.1;

  /// AÇIK tema "soluk" (çevrimdışı / salt-okunur AÇIK) orb: pasif durum etkinden baskın okunmaz.
  ///
  /// Eski tarif devre dışı griyle aile tonunu karıştırıyordu: bej/haki "kirli" gövde (amber), kart yüzeyinde sayfanın en koyu
  /// konturu olan koyu slate halka (slate.deep@0.75 ≈ 5:1) ve koyu mürekkep simge: çevrimdışı kart canlı karttan DAHA ağır
  /// görünüyordu. Şimdi: gövde ailenin PASTEL tonu (açık tonun beyazla seyreltilmişi; temiz, parıltısız), kenar aileye
  /// çalan ve kartta yine ≥ 3:1 olan İNCE halka (alfa her ailede [_paleRimContrast]'i yakalayan en küçük değer), simge TEK
  /// soluk mürekkep (`glass` simgesi #55657C; yetmezse devre dışı simgesi): hiçbir ailede near-black'e düşmez.
  static OrbColors _mutedLight(AccentFamily family, double k) {
    final grey = OrbColors.disabled(Brightness.light);
    final w = (k / _paleFullMix).clamp(0.0, 1.0);
    Color pale(Color c, double t) => Color.lerp(c, Colors.white, t)!;
    final light = Color.lerp(grey.light, pale(family.light, 0.72), w)!;
    final base = Color.lerp(grey.base, pale(family.light, 0.30), w)!;
    final deep = Color.lerp(grey.deep, family.light, w)!;

    final center = Color.lerp(light, base, 0.49)!;
    final bodies = <Color>[
      Color.lerp(light, base, 0.20)!,
      center,
      base,
      Color.lerp(base, deep, 0.30)!,
      Color.alphaBlend(Colors.white.withValues(alpha: 0.28 * grey.specular), center),
    ];
    double worst(Color icon) => bodies.map((b) => wcagContrast(icon, b)).reduce((a, b) => a < b ? a : b);
    final candidates = <Color>[OrbColors.glass(Brightness.light).icon, grey.icon, Colors.white, inkFor(family)];
    var icon = candidates.first;
    var best = -1.0;
    for (final c in candidates) {
      final contrast = worst(c);
      if (contrast >= 3.3) {
        icon = c;
        break;
      }
      if (contrast > best) {
        best = contrast;
        icon = c;
      }
    }

    // Kenar: slate.deep ile aile derin tonunun karışımı; alfa, kartın en koyu ucunda ([OrbColors] kenar sözleşmesi) ≥ 3.1:1
    // olan en küçük değer (üst uçta +0.04: sol-üstten sağ-alta hafifçe solar).
    final rimBase = Color.lerp(AppFamilies.slate.deep, family.deep, 0.35)!;
    final surfaces = <Color>[const Color(0xFFFFFFFF), SurfaceTokens.light.cardBottom, const Color(0xFFF1F5F9)];
    var rimAlpha = 0.95;
    for (var percent = 50; percent <= 95; percent += 1) {
      final candidate = rimBase.withValues(alpha: percent / 100);
      if (surfaces.every((s) => wcagContrast(Color.alphaBlend(candidate, s), s) >= _paleRimContrast)) {
        rimAlpha = percent / 100;
        break;
      }
    }
    return OrbColors(
      light: light,
      base: base,
      deep: deep,
      glow: Color.lerp(grey.glow, family.glow, w)!,
      icon: icon,
      rimStart: rimBase.withValues(alpha: (rimAlpha + 0.04).clamp(0.0, 1.0)),
      rimEnd: rimBase.withValues(alpha: rimAlpha),
      specular: grey.specular,
      glowScale: grey.glowScale,
    );
  }

  /// İki takım arasında [t] (0..1) ile geçiş.
  static OrbColors lerp(OrbColors a, OrbColors b, double t) {
    final k = t.clamp(0.0, 1.0);
    if (k == 0) return a;
    if (k == 1) return b;
    return OrbColors(
      light: Color.lerp(a.light, b.light, k)!,
      base: Color.lerp(a.base, b.base, k)!,
      deep: Color.lerp(a.deep, b.deep, k)!,
      glow: Color.lerp(a.glow, b.glow, k)!,
      icon: Color.lerp(a.icon, b.icon, k)!,
      rimStart: Color.lerp(a.rimStart, b.rimStart, k)!,
      rimEnd: Color.lerp(a.rimEnd, b.rimEnd, k)!,
      specular: a.specular + (b.specular - a.specular) * k,
      glowScale: a.glowScale + (b.glowScale - a.glowScale) * k,
    );
  }

  /// Rim renklerini değiştirir (başarı/hata durumunda renkli kenar).
  OrbColors withRim(Color start, Color end) => OrbColors(
        light: light,
        base: base,
        deep: deep,
        glow: glow,
        icon: icon,
        rimStart: start,
        rimEnd: end,
        specular: specular,
        glowScale: glowScale,
      );

  @override
  bool operator ==(Object other) =>
      other is OrbColors &&
      other.light == light &&
      other.base == base &&
      other.deep == deep &&
      other.glow == glow &&
      other.icon == icon &&
      other.rimStart == rimStart &&
      other.rimEnd == rimEnd &&
      other.specular == specular &&
      other.glowScale == glowScale;

  @override
  int get hashCode => Object.hash(light, base, deep, glow, icon, rimStart, rimEnd, specular, glowScale);
}
