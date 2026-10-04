import 'package:flutter/material.dart';

import '../widgets/orb/orb_colors.dart';
import '../widgets/orb/orb_painter.dart';
import 'tokens.dart';

/// Parlak kaydırıcı izi: dolu kısım **gradyan** (`activeTrackColor`'dan türetilen koyu → açık ton) + iz
/// yüksekliğinden biraz kalın yarı saydam "parıltı" şeridi (blur YOK: sürükleme sırasında kare başına çizim
/// ucuzdur). `Slider` widget türü KALIR; yalnız `SliderThemeData.trackShape` olarak bağlanır.
///
/// Renkler `SliderThemeData`'dan okunur (`activeTrackColor`, `inactiveTrackColor`, `disabled*`): panjur kartı
/// vb. `SliderTheme.of(context).copyWith(activeTrackColor: ...)` ile renk ailesini değiştirebilir.
///
/// **Pasif iz sınırı ([inactiveRim])**: pasif (kalan aralık) iz yarı saydam ve zemine yakın bir dolgudur (kontrast
/// ~1.4:1); WCAG 1.4.11 (UI bileşeni ≥ 3:1) için tam uzunlukta 1 px'lik "oluk" kenarı çizilir. Kenar yalnız pasif
/// bölümde görünür (aktif gradyan üstüne biner). `null` ⇒ kenar yok (eski görünüm). Pasif (disabled) durumda kenar
/// yumuşar.
class GlowSliderTrackShape extends SliderTrackShape with BaseSliderTrackShape {
  const GlowSliderTrackShape({this.inactiveRim});

  /// Pasif izin dış kenarı (1 px). Genelde temada: koyu `white@0.38`, açık `#7F8EA3` (kartlarda ≥ 3:1).
  final Color? inactiveRim;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 0,
  }) {
    final height = sliderTheme.trackHeight;
    if (height == null || height <= 0) return;

    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final radius = Radius.circular(rect.height / 2);
    final canvas = context.canvas;

    final inactive = ColorTween(begin: sliderTheme.disabledInactiveTrackColor, end: sliderTheme.inactiveTrackColor)
        .evaluate(enableAnimation)!;
    final active = ColorTween(begin: sliderTheme.disabledActiveTrackColor, end: sliderTheme.activeTrackColor)
        .evaluate(enableAnimation)!;

    // Pasif iz (tam uzunluk) + oluk kenarı.
    final trackRRect = RRect.fromRectAndRadius(rect, radius);
    canvas.drawRRect(trackRRect, Paint()..color = inactive);
    final rim = inactiveRim;
    if (rim != null) {
      // Pasif durumda kenar yumuşar (WCAG pasif bileşenleri muaf tutar); etkinken tam renk.
      final rimAlpha = rim.a * (0.45 + 0.55 * enableAnimation.value);
      canvas.drawRRect(
        trackRRect.deflate(0.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0
          ..color = rim.withValues(alpha: rimAlpha),
      );
    }

    // Aktif iz: soldan (RTL'de sağdan) başparmağa.
    final ltr = textDirection == TextDirection.ltr;
    final activeRect = ltr
        ? Rect.fromLTRB(rect.left, rect.top, thumbCenter.dx, rect.bottom)
        : Rect.fromLTRB(thumbCenter.dx, rect.top, rect.right, rect.bottom);
    if (activeRect.width <= 0.5) return;

    // Parıltı şeridi (statik alfa; blur yok).
    final glowRect = activeRect.inflate(2.5);
    canvas.drawRRect(
      RRect.fromRectAndRadius(glowRect, Radius.circular(glowRect.height / 2)),
      Paint()..color = active.withValues(alpha: 0.20 * enableAnimation.value),
    );

    final deep = Color.lerp(active, const Color(0xFF000000), 0.22)!;
    final light = Color.lerp(active, const Color(0xFFFFFFFF), 0.38)!;
    final shader = LinearGradient(
      begin: ltr ? Alignment.centerLeft : Alignment.centerRight,
      end: ltr ? Alignment.centerRight : Alignment.centerLeft,
      colors: [deep, active, light],
      stops: const [0.0, 0.55, 1.0],
    ).createShader(activeRect);
    canvas.drawRRect(RRect.fromRectAndRadius(activeRect, radius), Paint()..shader = shader);

    // İnce üst cila çizgisi.
    final gloss = Rect.fromLTWH(activeRect.left + rect.height / 2, activeRect.top + rect.height * 0.18, activeRect.width - rect.height, rect.height * 0.22);
    if (gloss.width > 2) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(gloss, Radius.circular(gloss.height / 2)),
        Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: 0.28),
      );
    }
  }
}

/// Orb başparmak: kaydırıcı başparmağı mini parlak küre (`paintOrbBody` ile aynı gövde: radyal gradyan +
/// speküler + rim) ve basılıyken ([activationAnimation]) büyüyen halo. Renk `SliderThemeData.thumbColor`.
///
/// [outlined] (AÇIK tema): başparmak beyaz kartta kaybolmasın diye dış kenara ince, koyulaştırılmış bir halka çizilir. Gövdenin
/// beyaz rim'i beyaz kartta görünmez; açık tonlu başparmak (`family.light` ≈ #93C5FD) kartta ≈ 1.8:1 verip yalnız yumuşak
/// gölgesiyle ayrışıyordu. Halka rengi başparmak renginin %40 koyusudur (açık tonlu başparmakta bile kartta ≥ 3:1); koyu
/// temada gerekmez.
class OrbSliderThumbShape extends SliderComponentShape {
  const OrbSliderThumbShape({this.radius = 13, this.outlined = false});

  /// Dinlenme yarıçapı (basılıyken ×1.18'e kadar büyür).
  final double radius;

  /// Açık tema: dış kenarda ince koyu halka (bkz. sınıf belgesi).
  final bool outlined;

  /// Halka kalınlığı, rengi (başparmak renginin siyaha karışımı) ve opaklığı.
  static const double outlineWidth = 1.2;
  static const double outlineDarken = 0.40;
  static const double outlineAlpha = 0.9;

  static const double _pressGrowth = 0.18;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => Size.fromRadius(radius * (1 + _pressGrowth));

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    final enabled = enableAnimation.value;
    final base = Color.lerp(
      sliderTheme.disabledThumbColor ?? const Color(0xFF64748B),
      sliderTheme.thumbColor ?? AppFamilies.sky.base,
      enabled,
    )!;
    final press = activationAnimation.value;
    final r = radius * (1 + _pressGrowth * press);

    // Basılıyken halo (RadialGradient).
    paintOrbGlow(canvas, center, r, base, 0.50 * press * enabled, 2.1);

    // Blur'suz yapay gölge (iki yarı saydam disk).
    canvas.drawCircle(center + const Offset(0, 3.0), r + 1.5, Paint()..color = const Color(0x14000000));
    canvas.drawCircle(center + const Offset(0, 1.8), r + 0.5, Paint()..color = const Color(0x24000000));

    final colors = OrbColors(
      light: Color.lerp(base, const Color(0xFFFFFFFF), 0.55)!,
      base: base,
      deep: Color.lerp(base, const Color(0xFF000000), 0.35)!,
      glow: base,
      icon: const Color(0x00000000),
      rimStart: const Color(0xFFFFFFFF).withValues(alpha: 0.75),
      rimEnd: const Color(0xFFFFFFFF).withValues(alpha: 0.08),
      specular: 1.0,
      glowScale: 1.0,
    );
    paintOrbBody(canvas, center, r, colors);

    if (outlined) {
      final ring = Color.lerp(base, const Color(0xFF000000), outlineDarken)!;
      canvas.drawCircle(
        center,
        r - 0.1,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = outlineWidth
          ..color = ring.withValues(alpha: outlineAlpha),
      );
    }
  }
}
