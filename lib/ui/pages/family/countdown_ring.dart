import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../motion/ambient_clock.dart';
import '../../motion/motion_scope.dart';

/// Süre geri sayım halkası: kalan süre oranı kadar dolu yay (dolu = tam süre, boş = bitti).
///
/// * Oran her çizimde [now]'dan hesaplanır; `Timer`/`AnimationController` YOK. `MotionMode.full` iken
///   paylaşılan [AmbientClock] ticki yalnız küçük bir `CustomPainter`'ı yeniden boyar (kartı kurmaz); `off`
///   kipte (ve sabit saatte) ilk build'in oranı statik çizilir.
/// * Merkezde isteğe bağlı [child] (ör. simge). Anlamsal ağaçtan hariçtir (süre metni yanında yazılmalıdır).
class CountdownRing extends StatefulWidget {
  const CountdownRing({
    super.key,
    required this.expiresAt,
    required this.total,
    required this.now,
    required this.color,
    this.diameter = 44,
    this.strokeWidth = 3.5,
    this.child,
  });

  final DateTime expiresAt;

  /// Halkanın "tam dolu" sayıldığı toplam süre.
  final Duration total;
  final DateTime Function() now;
  final Color color;
  final double diameter;
  final double strokeWidth;
  final Widget? child;

  @override
  State<CountdownRing> createState() => _CountdownRingState();
}

class _CountdownRingState extends State<CountdownRing> {
  final ValueNotifier<double> _fraction = ValueNotifier<double>(1);
  AmbientClock? _clock;

  double _compute() {
    final totalMs = widget.total.inMilliseconds;
    if (totalMs <= 0) return 0;
    final left = widget.expiresAt.difference(widget.now()).inMilliseconds;
    return (left / totalMs).clamp(0.0, 1.0);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _fraction.value = _compute();
    final clock = MotionScope.enabledOf(context) ? MotionScope.clockOf(context) : null;
    if (!identical(clock, _clock)) {
      _clock?.removeListener(_tick);
      _clock = clock;
      clock?.addListener(_tick);
    }
  }

  @override
  void didUpdateWidget(CountdownRing old) {
    super.didUpdateWidget(old);
    _fraction.value = _compute();
  }

  void _tick() {
    final next = _compute();
    if ((next - _fraction.value).abs() >= 0.002) _fraction.value = next;
  }

  @override
  void dispose() {
    _clock?.removeListener(_tick);
    _fraction.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final track = widget.color.withValues(alpha: 0.2);
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: widget.diameter,
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _RingPainter(
              fraction: _fraction,
              color: widget.color,
              track: track,
              strokeWidth: widget.strokeWidth,
            ),
            child: Center(child: widget.child),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.fraction, required this.color, required this.track, required this.strokeWidth})
      : super(repaint: fraction);

  final ValueListenable<double> fraction;
  final Color color;
  final Color track;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(strokeWidth / 2);
    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = track,
    );
    final f = fraction.value;
    if (f <= 0) return;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * f,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.color != color || old.track != track || old.strokeWidth != strokeWidth;
}
