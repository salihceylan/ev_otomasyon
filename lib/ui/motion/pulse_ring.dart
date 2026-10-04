import 'dart:ui' show lerpDouble;

import 'package:flutter/widgets.dart';

import 'motion_scope.dart';

/// **Tek seferlik** genişleyen ve sönen halka (başarı geri bildirimi, 450 ms).
///
/// [trigger] değiştiğinde (ya da [playOnMount] ile bağlanışta) bir kez oynar ve biter; sonsuz döngü YOK
/// (`pumpAndSettle` biter). `MotionMode.off` kipinde hiçbir şey çizilmez ve animasyon kurulmaz.
/// Etkileşimi engellemez (`IgnorePointer`); halka kendi kutusunun DIŞINA taşar ([diameter] × [maxScale]).
///
/// ```dart
/// PulseRing(color: AppFamilies.emerald.light, diameter: 64, trigger: successCount)
/// ```
class PulseRing extends StatefulWidget {
  const PulseRing({
    super.key,
    required this.color,
    required this.diameter,
    this.trigger = 0,
    this.playOnMount = false,
    this.duration = const Duration(milliseconds: 450),
    this.maxScale = 1.55,
    this.strokeWidth = 2.5,
  });

  final Color color;

  /// Başlangıç halka çapı (genelde orb çapı).
  final double diameter;

  /// Değiştiğinde halka bir kez oynar.
  final int trigger;
  final bool playOnMount;
  final Duration duration;
  final double maxScale;
  final double strokeWidth;

  @override
  State<PulseRing> createState() => _PulseRingState();
}

class _PulseRingState extends State<PulseRing> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: widget.duration);
  bool _mounted = false;

  void _play() {
    if (!MotionScope.enabledOf(context)) return;
    _controller.forward(from: 0);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_mounted) return;
    _mounted = true;
    if (widget.playOnMount) _play();
  }

  @override
  void didUpdateWidget(PulseRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.duration = widget.duration;
    if (widget.trigger != oldWidget.trigger) _play();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox.square(
        dimension: widget.diameter,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => CustomPaint(
            painter: _PulseRingPainter(
              progress: _controller.isAnimating ? _controller.value : 0.0,
              color: widget.color,
              maxScale: widget.maxScale,
              strokeWidth: widget.strokeWidth,
            ),
          ),
        ),
      ),
    );
  }
}

class _PulseRingPainter extends CustomPainter {
  const _PulseRingPainter({
    required this.progress,
    required this.color,
    required this.maxScale,
    required this.strokeWidth,
  });

  final double progress;
  final Color color;
  final double maxScale;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0 || progress >= 1) return;
    final eased = Curves.easeOutCubic.transform(progress);
    final radius = size.width / 2 * lerpDouble(1.0, maxScale, eased)!;
    final alpha = (1 - progress) * 0.95;
    canvas.drawCircle(
      size.center(Offset.zero),
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth * (1 - 0.5 * progress)
        ..color = color.withValues(alpha: alpha),
    );
  }

  @override
  bool shouldRepaint(_PulseRingPainter old) =>
      old.progress != progress || old.color != color || old.maxScale != maxScale || old.strokeWidth != strokeWidth;
}
