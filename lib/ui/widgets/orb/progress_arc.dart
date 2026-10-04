import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../motion/ambient_clock.dart';
import '../../motion/motion_scope.dart';

/// Orb çevresinde dönen "bekliyor" (pending) yayı: komut hattında bekleyen komutu gösterir.
///
/// * Dönüş paylaşılan [AmbientClock]'tan türetilir (kendi `Ticker`'ı/`AnimationController`'ı yok); bir tur
///   [period] (varsayılan 1.1 sn ≤ 2.5 sn).
/// * **Güvenlik sınırı:** [maxSpin] (varsayılan 10 sn: komut hattının toplam üst sınırı) dolunca dönüş durur ve
///   yay statik kalır; sahibi unutsa bile sonsuz animasyon bırakılmaz.
/// * `MotionMode.off`: dönmez; sabit bir yay çizer (durum yine görülür).
/// * Etkileşimi engellemez (`IgnorePointer`). Kutusunun (çember çapı [diameter]) etrafına çizer.
///
/// ```dart
/// Positioned(left: -5, top: -5, right: -5, bottom: -5, child: ProgressArc(diameter: 74, color: AppFamilies.sky.light))
/// ```
class ProgressArc extends StatefulWidget {
  const ProgressArc({
    super.key,
    required this.diameter,
    required this.color,
    this.strokeWidth = 3.0,
    this.sweep = 0.42,
    this.period = const Duration(milliseconds: 1100),
    this.maxSpin = const Duration(seconds: 10),
  }) : assert(sweep > 0 && sweep <= 1);

  /// Yay çemberinin çapı (orb çapı + 2 × boşluk).
  final double diameter;
  final Color color;
  final double strokeWidth;

  /// Yayın çember oranı (0.42 ≈ 150°; eskiden 0.36 ≈ 130° idi ve kuyruk soluk olduğundan görünür yay ≈ 60–70°'ye düşüyordu).
  final double sweep;
  final Duration period;
  final Duration maxSpin;

  @override
  State<ProgressArc> createState() => _ProgressArcState();
}

class _ProgressArcState extends State<ProgressArc> {
  final ValueNotifier<double> _angle = ValueNotifier<double>(-math.pi / 2);
  AmbientClock? _clock;
  double _t0 = 0;
  bool _expired = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!MotionScope.enabledOf(context) || _expired) {
      _detach();
      return;
    }
    final clock = MotionScope.clockOf(context);
    if (!identical(_clock, clock)) {
      _detach();
      _clock = clock;
      _t0 = clock.time;
      clock.addListener(_onTick);
    }
    _update(clock);
  }

  void _detach() {
    _clock?.removeListener(_onTick);
    _clock = null;
  }

  void _onTick() {
    final clock = _clock;
    if (clock != null) _update(clock);
  }

  void _update(AmbientClock clock) {
    final elapsed = clock.time - _t0;
    if (elapsed * Duration.microsecondsPerSecond >= widget.maxSpin.inMicroseconds) {
      _expired = true;
      _detach();
      return;
    }
    final turn = (elapsed % (widget.period.inMicroseconds / Duration.microsecondsPerSecond)) /
        (widget.period.inMicroseconds / Duration.microsecondsPerSecond);
    _angle.value = -math.pi / 2 + turn * 2 * math.pi;
  }

  @override
  void dispose() {
    _detach();
    _angle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox.square(
        dimension: widget.diameter,
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _ArcPainter(
              angle: _angle,
              color: widget.color,
              strokeWidth: widget.strokeWidth,
              sweep: widget.sweep,
            ),
          ),
        ),
      ),
    );
  }
}

class _ArcPainter extends CustomPainter {
  _ArcPainter({
    required this.angle,
    required this.color,
    required this.strokeWidth,
    required this.sweep,
  }) : super(repaint: angle);

  final ValueListenable<double> angle;
  final Color color;
  final double strokeWidth;
  final double sweep;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(strokeWidth / 2);
    final start = angle.value;
    final sweepAngle = sweep * 2 * math.pi;
    // Kuyruktan başa doğru görünür hale gelen gradyan: kuyruk saydam, baş dolu renk. Kuyruk alfası 0.20: eskiden 0.12'ydi
    // ve görünür yay ≈ 60–70°'ye düşüp ince kalıyordu (komut bekliyor göstergesi).
    final shader = SweepGradient(
      startAngle: 0,
      endAngle: sweepAngle,
      colors: [color.withValues(alpha: 0.20), color],
      transform: GradientRotation(start),
    ).createShader(rect);
    canvas.drawArc(
      rect,
      start,
      sweepAngle,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..shader = shader,
    );
  }

  @override
  bool shouldRepaint(_ArcPainter old) =>
      old.color != color || old.strokeWidth != strokeWidth || old.sweep != sweep || old.angle != angle;
}
