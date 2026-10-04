import 'package:flutter/widgets.dart';

import '../../motion/ambient_clock.dart';
import '../../motion/motion_scope.dart';
import 'ambient_breath.dart';
import 'orb_painter.dart';

/// Canlı durum noktası (bağlantı/çevrimiçi/uyarı): dolu nokta + yumuşak halo (`RadialGradient`; blur yok).
///
/// * [pulses] > 0: bağlanışta o kadar **nabız** (genişleyen halka) atar ve SABİTLENİR ("bağlanıyor" için 3);
///   sonlu animasyondur (`pumpAndSettle` biter). Yalnız `MotionMode.full`.
/// * [breathing]: canlı nokta yavaşça nefes alır — paylaşılan `AmbientClock`'tan, slot bütçesi dahilinde
///   (yalnız `MotionMode.full`, ön plan).
/// * Anlamsal olarak yok sayılır: durum metni yanında ayrıca yazılmalıdır (renk TEK ipucu değildir).
///
/// ```dart
/// GlowDot(color: AppFamilies.emerald.base, breathing: true)
/// GlowDot(color: AppFamilies.amber.base, pulses: 3)   // "bağlanıyor"
/// ```
class GlowDot extends StatefulWidget {
  const GlowDot({
    super.key,
    required this.color,
    this.size = 10,
    this.breathing = false,
    this.pulses = 0,
  }) : assert(pulses >= 0);

  final Color color;

  /// Nokta çapı (halo bunun ~2.6 katına taşar).
  final double size;
  final bool breathing;
  final int pulses;

  @override
  State<GlowDot> createState() => _GlowDotState();
}

class _GlowDotState extends State<GlowDot> with SingleTickerProviderStateMixin, AmbientBreathMixin<GlowDot> {
  static const Duration _pulseDuration = Duration(milliseconds: 900);

  late final AnimationController _pulse = AnimationController(vsync: this);
  bool _mountedOnce = false;

  @override
  bool get wantsBreath => widget.breathing;

  void _startPulses() {
    if (widget.pulses <= 0 || !MotionScope.enabledOf(context)) return;
    _pulse.duration = _pulseDuration * widget.pulses;
    _pulse.forward(from: 0);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_mountedOnce) return;
    _mountedOnce = true;
    _startPulses();
  }

  @override
  void didUpdateWidget(GlowDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pulses != widget.pulses) {
      _pulse.stop();
      _startPulses();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final extent = widget.size * 2.6;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: widget.size,
        child: OverflowBox(
          minWidth: extent,
          maxWidth: extent,
          minHeight: extent,
          maxHeight: extent,
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: _pulse,
              builder: (context, _) => CustomPaint(
                size: Size.square(extent),
                painter: _GlowDotPainter(
                  color: widget.color,
                  dotSize: widget.size,
                  clock: breathClock,
                  pulse: _pulse.isAnimating ? _pulse.value : null,
                  pulses: widget.pulses,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlowDotPainter extends CustomPainter {
  _GlowDotPainter({
    required this.color,
    required this.dotSize,
    required this.clock,
    required this.pulse,
    required this.pulses,
  }) : super(repaint: clock);

  final Color color;
  final double dotSize;
  final AmbientClock? clock;
  final double? pulse;
  final int pulses;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = dotSize / 2;

    // Halo (nefes alıyorsa genlik değişir; slot yoksa orta düzeyde statik).
    final clk = clock;
    final breath = clk == null ? 0.5 : OrbPainter.breath(clk.time, 0);
    final haloAlpha = 0.22 + 0.22 * breath;
    final haloR = r * 2.3;
    canvas.drawCircle(
      c,
      haloR,
      Paint()
        ..shader = RadialGradient(
          colors: [color.withValues(alpha: haloAlpha), color.withValues(alpha: haloAlpha * 0.35), color.withValues(alpha: 0)],
          stops: [0.0, r / haloR, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: haloR)),
    );

    // Nabız halkaları: 0..pulses arasındaki ilerleme; her nabız 0..1.
    final p = pulse;
    if (p != null && pulses > 0) {
      final local = (p * pulses) % 1.0;
      final ringR = r + (size.width / 2 - r) * Curves.easeOutCubic.transform(local);
      canvas.drawCircle(
        c,
        ringR,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = color.withValues(alpha: (1 - local) * 0.7),
      );
    }

    // Nokta + küçük speküler.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.4),
          radius: 1.0,
          colors: [Color.lerp(color, const Color(0xFFFFFFFF), 0.55)!, color, Color.lerp(color, const Color(0xFF000000), 0.25)!],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );
    canvas.drawCircle(
      c + Offset(-r * 0.28, -r * 0.34),
      r * 0.28,
      Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: 0.55),
    );
  }

  @override
  bool shouldRepaint(_GlowDotPainter old) =>
      old.color != color || old.dotSize != dotSize || old.clock != clock || old.pulse != pulse || old.pulses != pulses;
}
