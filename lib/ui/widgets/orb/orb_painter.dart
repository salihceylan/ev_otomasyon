import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../motion/ambient_clock.dart';
import 'orb_colors.dart';

/// Orb parıltısı (şartname §3.1 ①): `RadialGradient` (BoxShadow/`MaskFilter.blur` DEĞİL → kare başına güvenle
/// değiştirilebilir). [alpha] ≤ 0 ise çizmez. Parıltı orb'un dışına [radiusFactor] × yarıçapa kadar taşar.
void paintOrbGlow(Canvas canvas, Offset center, double radius, Color glow, double alpha, double radiusFactor) {
  if (alpha <= 0.002) return;
  final outer = radius * radiusFactor;
  final k = radius / outer;
  final shader = RadialGradient(
    colors: [
      glow.withValues(alpha: alpha),
      glow.withValues(alpha: alpha * 0.70),
      glow.withValues(alpha: alpha * 0.22),
      glow.withValues(alpha: 0),
    ],
    stops: [0.0, k, k + (1 - k) * 0.5, 1.0],
  ).createShader(Rect.fromCircle(center: center, radius: outer));
  canvas.drawCircle(center, outer, Paint()..shader = shader);
}

/// Orb gövdesi (şartname §3.1 ② ③ ④ ⑤), alttan üste:
/// ② radyal gövde `RadialGradient(center: Alignment(-0.35,-0.45), radius: 1.05, [light, base, deep], [0, .55, 1])`,
/// ③ alt iç gölge (alt %35 yay, `black@0.25 → 0`) + (şartname dışı ince eklenti) alt yansıma ışığı (`light@0.42 → 0`,
/// alt kenardan yukarı; camsı derinlik), ④ speküler elips (0.62 d × 0.34 d, üstten 0.10 d,
/// `white@0.62 → 0`), ⑤ 1.5 px kenar ışığı (`rimStart → rimEnd`, sol-üst → sağ-alt).
///
/// `OrbPainter` ve kaydırıcı başparmağı aynı işlevi paylaşır. Speküler/yansıma gücü `colors.specular × specularScale`. Simge (⑥) widget katmanında
/// bu çizimin ÜSTÜNE konur.
void paintOrbBody(
  Canvas canvas,
  Offset center,
  double radius,
  OrbColors colors, {
  double specularScale = 1.0,
  double flash = 0.0,
  Color flashColor = const Color(0xFFF43F5E),
}) {
  final rect = Rect.fromCircle(center: center, radius: radius);
  final d = radius * 2;
  // Etkin speküler/yansıma gücü: takımın kendi gücü × çağıran çarpanı (basılıyken azalır).
  final spec = (colors.specular * specularScale).clamp(0.0, 1.0);

  // ② gövde
  canvas.drawCircle(
    center,
    radius,
    Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.35, -0.45),
        radius: 1.05,
        colors: [colors.light, colors.base, colors.deep],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(rect),
  );

  // ③ alt iç gölge
  canvas.drawCircle(
    center,
    radius,
    Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0x00000000), Color(0x00000000), Color(0x40000000)],
        stops: [0.0, 0.65, 1.0],
      ).createShader(rect),
  );

  // yansıyan alt ışık (bounce light): alt iç gölgenin içinde ince, aile renginde sıcak bir ışık; camsı derinlik.
  canvas.drawCircle(
    center,
    radius,
    Paint()
      ..shader = RadialGradient(
        center: const Alignment(0.0, 1.0),
        radius: 0.78,
        colors: [colors.light.withValues(alpha: 0.42 * spec), colors.light.withValues(alpha: 0)],
      ).createShader(rect),
  );

  // hata parlaması (rose flaş)
  if (flash > 0.01) {
    canvas.drawCircle(center, radius, Paint()..color = flashColor.withValues(alpha: 0.55 * flash.clamp(0.0, 1.0)));
  }

  // ④ speküler elips
  final specRect = Rect.fromLTWH(center.dx - d * 0.31, center.dy - radius + d * 0.10, d * 0.62, d * 0.34);
  final specAlpha = 0.62 * spec;
  if (specAlpha > 0.01) {
    canvas.drawOval(
      specRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white.withValues(alpha: specAlpha), Colors.white.withValues(alpha: 0)],
        ).createShader(specRect),
    );
  }

  // ⑤ kenar ışığı
  canvas.drawCircle(
    center,
    radius - 0.75,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [colors.rimStart, colors.rimEnd],
      ).createShader(rect),
  );
}

/// Orb'un TEK `CustomPainter`'ı: parıltı → radyal gövde → alt iç gölge → speküler → rim (simge widget katmanı).
///
/// * [glowLevel] 0..1 (parıltı yoğunluğu: idle ≈ 0.25, aktif ≈ 0.6).
/// * [clock] verilirse parıltı **nefes alır** (`repaint: clock`; yalnız slot alan orb'a verilir) ve aralığı
///   ~[breathPeriodSeconds] sn'dir; `null` ise STATİK. Nefes yalnız `RadialGradient` alfa/yarıçapını değiştirir.
/// * [pressed] speküler vurguyu azaltır (parmak değdiği an).
class OrbPainter extends CustomPainter {
  OrbPainter({
    required this.colors,
    required this.dark,
    this.glowLevel = 0.25,
    this.pressed = false,
    this.clock,
    this.phase = 0.0,
    this.flash = 0.0,
  })  : warmGain = warmGlowGain(colors.glow),
        super(repaint: clock);

  /// Sıcak tonlu (kırmızı-turuncu-sarı) parıltının koyu temadaki alfa çarpanı. Amber/rose parıltı lacivert yüzeyde
  /// düşük alfada gri-kahve "sise" döner (turuncu ile mavi tamamlayıcıdır, karışınca nötrleşir); soğuk tonlarla (sky
  /// S≈0.63) aynı canlılık için sıcak ailelerin halesi daha güçlü başlar.
  static const double warmGainDark = 1.40;

  /// [glow] sıcak tonluysa (ton 0–70° ya da 330–360°) [warmGainDark], değilse 1.
  static double warmGlowGain(Color glow) {
    final hsv = HSVColor.fromColor(glow);
    if (hsv.saturation < 0.25) return 1.0; // nötr (slate/gri): ton anlamsız
    final h = hsv.hue;
    return (h <= 70 || h >= 330) ? warmGainDark : 1.0;
  }

  /// Hesaplanmış sıcak ton çarpanı (yalnız koyu temada uygulanır).
  final double warmGain;

  final OrbColors colors;
  final bool dark;
  final double glowLevel;
  final bool pressed;
  final AmbientClock? clock;

  /// Nefes faz kayması (0..1 tur); orb'ların senkron nefes almasını kırmak için çağıran verebilir.
  final double phase;

  /// Hata parlaması 0..1.
  final double flash;

  /// Bir nefes turunun süresi (sn).
  static const double breathPeriodSeconds = 2.6;

  /// Nefes eğrisi (0..1) — test edilebilir saf işlev.
  static double breath(double seconds, double phase) =>
      0.5 + 0.5 * math.sin(2 * math.pi * (seconds / breathPeriodSeconds + phase));

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;

    var level = glowLevel.clamp(0.0, 1.0) * colors.glowScale;
    var factor = 1.7 + 0.45 * glowLevel;
    final c = clock;
    if (c != null) {
      final s = breath(c.time, phase);
      level *= 0.70 + 0.30 * s;
      factor += 0.10 * s;
    }
    if (pressed) level *= 0.65; // parmak değerken parıltı da biraz çekilir
    final alpha = ((dark ? 0.58 * warmGain : 0.30) * level).clamp(0.0, 0.92);
    paintOrbGlow(canvas, center, radius, colors.glow, alpha, factor);

    paintOrbBody(
      canvas,
      center,
      radius,
      colors,
      specularScale: pressed ? 0.55 : 1.0,
      flash: flash,
    );
  }

  @override
  bool shouldRepaint(OrbPainter old) =>
      old.colors != colors ||
      old.dark != dark ||
      old.glowLevel != glowLevel ||
      old.pressed != pressed ||
      old.clock != clock ||
      old.phase != phase ||
      old.flash != flash;
}
