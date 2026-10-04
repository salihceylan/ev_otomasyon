import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../motion/motion_scope.dart';
import '../../motion/pulse_ring.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import 'ambient_breath.dart';
import 'orb_colors.dart';
import 'orb_painter.dart';
import 'progress_arc.dart';

/// Orb'un tek seferlik sonuç durumu. `success`: halka (yalnız `full`) + parlak kenar; `error`: sarsıntı + rose
/// flaş (yalnız `full`) + rose kenar. Sahibi, sonucu gösterdikten sonra `none`'a çevirir (zamanlayıcı
/// orb'da DEĞİL, sahibindedir).
enum OrbStatus { none, success, error }

/// Orb görsel gövdesi: [OrbButton]/[OrbToggle]/[OrbIconBadge] bunu kullanır (genelde doğrudan kullanılmaz).
///
/// Katman sırası (alttan üste): açık temada renkli statik gölge → parıltı → radyal gövde → alt iç gölge →
/// speküler → rim (`OrbPainter`, TEK painter) → simge → bekleme yayı ([ProgressArc]) → başarı halkası
/// ([PulseRing]). Tamamı bir `RepaintBoundary` içindedir; nefes yalnız painter'ı yeniden çizer.
///
/// Durumlar: idle / pressed ([pressed]) / active ([active]; nefes alan parıltı, slot bütçesi dahilinde) /
/// pending ([pending]) / success·error ([status]) / disabled ([enabled] = false).
class OrbCore extends StatefulWidget {
  const OrbCore({
    super.key,
    required this.size,
    required this.family,
    this.icon,
    this.iconBuilder,
    this.active = false,
    this.pending = false,
    this.status = OrbStatus.none,
    this.enabled = true,
    this.pressed = false,
    this.progress = 1.0,
    this.breathPhase = 0.0,
    this.glow = true,
    this.mutedFamily = false,
    this.dimmed = false,
  }) : assert(icon != null || iconBuilder != null, 'icon veya iconBuilder verilmeli');

  final OrbSize size;
  final AccentFamily family;
  final IconData? icon;

  /// Özel simge: `(context, renk, boyut)`. Verilirse [icon] yok sayılır.
  final Widget Function(BuildContext context, Color color, double size)? iconBuilder;

  /// Hareketli/etkin (parıltı güçlenir ve — `full` kipte, slot varsa — nefes alır).
  final bool active;

  /// Komut bekliyor: orb çevresinde dönen yay.
  final bool pending;
  final OrbStatus status;

  /// `false` ise devre dışı görünüm (gri küre, parıltı yok).
  final bool enabled;

  /// Parmak değiyor (speküler azalır). `Pressable` bunu sağlar.
  final bool pressed;

  /// 0 = kapalı cam küre, 1 = aile rengi (`OrbToggle` geçişi).
  final double progress;

  /// Nefes faz kayması (0..1).
  final double breathPhase;

  /// `false` ise idle parıltı çizilmez (yoğun ızgaralarda sadeleştirme).
  final bool glow;

  /// Yalnız devre dışıyken ([enabled] = false): gri küre yerine ailenin SOLUK tonu ([progress] ile ölçeklenir; parıltı
  /// yine yok, simge devre dışı simge rengi). Salt-okunur ama AÇIK bir anahtarın (`OrbToggle(value: true, onChanged: null)`)
  /// "açık" olduğu orb'dan da okunsun diye: gri orb "kapalı/pasif" ile karışıyordu. Varsayılan `false` (düz gri).
  final bool mutedFamily;

  /// ETKİN ama "soluk" orb: gövde ailenin soluk tonu ([OrbColors.mutedFamily]), parıltı/nefes/renkli gölge YOK; dokunuş
  /// ve anlamsal ağaç aynen çalışır ([enabled] true kalır). Çevrimdışı/son bilinen durum gibi "komut hâlâ verilebilir ama
  /// değer taze değil" hâllerinde: tam doygun parlak orb ile soluk kart/kaydırıcı çelişiyordu. Varsayılan `false`.
  final bool dimmed;

  /// Soluk aile tonunun devre dışı griye karışım oranı (en çok): simge (devre dışı simge rengi) bu gövde üstünde ≥ 3:1.
  static const double mutedFamilyMix = 0.40;

  /// Başarı halkasının en büyük çarpanı (orb çapına göre). `PulseRing` varsayılanı 1.55'tir; orb içinde 1.38 kullanılır:
  /// halka komşu orb'un yayı/halkasıyla ve altındaki etiketle çakışmasın (lg 64 → en çok ≈ 88 dp çap).
  static const double ringMaxScale = 1.38;

  @override
  State<OrbCore> createState() => _OrbCoreState();
}

class _OrbCoreState extends State<OrbCore> with SingleTickerProviderStateMixin, AmbientBreathMixin<OrbCore> {
  /// Hata sarsıntısı + flaş: 420 ms (sarsıntı ilk ~%43'te).
  late final AnimationController _fx = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
  int _successCount = 0;

  @override
  bool get wantsBreath => widget.active && widget.enabled && !widget.dimmed;

  @override
  void didUpdateWidget(OrbCore oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status != widget.status) {
      if (widget.status == OrbStatus.success) _successCount++;
      if (widget.status == OrbStatus.error && MotionScope.enabledOf(context)) _fx.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _fx.dispose();
    super.dispose();
  }

  OrbColors _colors(Brightness brightness) {
    if (!widget.enabled) {
      // Salt-okunur AÇIK anahtar: gri yerine soluk aile tonu (progress ile ölçeklenir; kapalıyken düz gri).
      final mix = OrbCore.mutedFamilyMix * widget.progress.clamp(0.0, 1.0);
      if (!widget.mutedFamily || mix <= 0) return OrbColors.disabled(brightness);
      return OrbColors.mutedFamily(widget.family, brightness, mix);
    }
    // Soluk (dimmed) etkin orb: aile yerine soluk aile tonu; kapalı toggle (progress 0) normal cam küre kalır.
    final body = widget.dimmed
        ? OrbColors.mutedFamily(widget.family, brightness, OrbCore.mutedFamilyMix)
        : OrbColors.family(widget.family);
    var colors = widget.progress >= 1 ? body : OrbColors.lerp(OrbColors.glass(brightness), body, widget.progress);
    switch (widget.status) {
      case OrbStatus.success:
        colors = colors.withRim(Colors.white.withValues(alpha: 0.95), AppFamilies.emerald.light.withValues(alpha: 0.55));
      case OrbStatus.error:
        colors = colors.withRim(AppFamilies.rose.light.withValues(alpha: 0.95), AppFamilies.rose.base.withValues(alpha: 0.60));
      case OrbStatus.none:
        break;
    }
    return colors;
  }

  @override
  Widget build(BuildContext context) {
    final dark = AppTheme.isDark(context);
    final brightness = dark ? Brightness.dark : Brightness.light;
    final full = MotionScope.enabledOf(context);
    final d = widget.size.diameter;
    final colors = _colors(brightness);
    final tokens = SurfaceTokens.of(brightness);

    final glowLevel = !widget.enabled || !widget.glow || widget.dimmed
        ? 0.0
        : (widget.active ? AppGlass.orbGlowActive : AppGlass.orbGlowIdle);

    final iconSize = widget.size.iconSize;
    final iconColor = colors.icon;
    final iconShadow = iconColor.computeLuminance() > 0.5
        ? const Color(0x4D000000)
        : const Color(0x47FFFFFF);
    final Widget iconWidget = widget.iconBuilder != null
        ? widget.iconBuilder!(context, iconColor, iconSize)
        : Icon(
            widget.icon,
            size: iconSize,
            color: iconColor,
            shadows: [Shadow(color: iconShadow, blurRadius: 2, offset: const Offset(0, 1))],
          );

    // Açık temada parıltı yerine renkli STATİK gölge (kendi RepaintBoundary'sinde: nefes bunu yeniden çizdirmez).
    Widget? shadowLayer;
    if (!dark && widget.enabled) {
      final accentAlpha = widget.active ? 0.42 : tokens.orbShadowAlpha;
      // Soluk orb renkli gölge taşımaz (nötr gölge): çevrimdışı orb parlak görünmesin.
      final shadowColor = widget.dimmed
          ? const Color(0x1A101820)
          : Color.lerp(
              const Color(0x1A101820),
              widget.family.base.withValues(alpha: accentAlpha),
              widget.progress.clamp(0.0, 1.0),
            )!;
      shadowLayer = Positioned.fill(
        key: const ValueKey('orb_shadow'),
        child: RepaintBoundary(
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: shadowColor,
                  blurRadius: widget.active ? tokens.orbShadowBlur + 4 : tokens.orbShadowBlur,
                  offset: tokens.orbShadowOffset,
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Bekleme yayı ve sonuç halkası tema duyarlıdır: koyuda açık ton, açıkta koyu ton. (Açık temada `light` ton
    // beyaz/pastel zeminde ≈ 1.3:1 verip kayboluyordu.)
    final arcColor = dark ? widget.family.light : widget.family.deep;
    final ringFamily = widget.status == OrbStatus.error
        ? AppFamilies.rose
        : (widget.status == OrbStatus.success ? AppFamilies.emerald : widget.family);
    final ringColor = dark ? ringFamily.light : ringFamily.deep;

    return RepaintBoundary(
      child: SizedBox.square(
        dimension: d,
        child: AnimatedBuilder(
          animation: _fx,
          builder: (context, _) {
            final running = _fx.isAnimating;
            final v = _fx.value;
            final dx = running && v < 0.43 ? 3.0 * math.sin(v / 0.43 * 4 * math.pi) : 0.0;
            final flash = running ? math.pow(1 - v, 2).toDouble() : 0.0;
            return Transform.translate(
              offset: Offset(dx, 0),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  ?shadowLayer,
                  Positioned.fill(
                    key: const ValueKey('orb_body'),
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: OrbPainter(
                          colors: colors,
                          dark: dark,
                          glowLevel: glowLevel,
                          pressed: widget.pressed,
                          clock: breathClock,
                          phase: widget.breathPhase,
                          flash: flash,
                        ),
                        child: Center(child: iconWidget),
                      ),
                    ),
                  ),
                  if (widget.pending)
                    Positioned(
                      key: const ValueKey('orb_arc'),
                      left: -5,
                      top: -5,
                      right: -5,
                      bottom: -5,
                      child: ProgressArc(diameter: d + 10, color: arcColor, strokeWidth: 3.5),
                    ),
                  if (full)
                    Positioned.fill(
                      key: const ValueKey('orb_ring'),
                      // Halka orb'un düzen kutusunun dışına en çok ~%20 taşar (eskiden %55: komşu orb/etiketle çakışıyordu).
                      child: PulseRing(color: ringColor, diameter: d, trigger: _successCount, maxScale: OrbCore.ringMaxScale),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
