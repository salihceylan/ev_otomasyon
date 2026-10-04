import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../motion/ambient_clock.dart';
import '../../motion/motion_scope.dart';
import '../../theme/tokens.dart';
import '../../widgets/orb/orb.dart';

/// Karekod tarayıcı çerçevesi: yuvarlak köşe işaretleri, tarama çizgisi ve başarıda ✓ mikro-hareketi.
/// Etkileşimi engellemez ([IgnorePointer]); tüm çizim tek `RepaintBoundary`'dedir.
///
/// * Tarama çizgisi **ambient**'tir: yalnız `MotionMode.full` iken paylaşılan [AmbientClock]'tan türetilir
///   (kendi `Ticker`'ı yok); `off` kipte ve sabit saatte statik (orta konum) çizilir. [accepted] olunca durur.
/// * [accepted]: kod kabul edildi → köşeler yeşile döner ve ✓ diski yaylanarak belirir (tek seferlik, `off`'ta anında).
class ScannerFrame extends StatefulWidget {
  const ScannerFrame({super.key, required this.size, this.accepted = false});

  final double size;
  final bool accepted;

  @override
  State<ScannerFrame> createState() => _ScannerFrameState();
}

class _ScannerFrameState extends State<ScannerFrame> {
  /// Tarama çizgisinin konumu (0..1, gidiş-dönüş).
  final ValueNotifier<double> _line = ValueNotifier<double>(0.5);
  AmbientClock? _clock;

  static const double _period = 2.4; // sn, tam gidiş-dönüş

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(ScannerFrame old) {
    super.didUpdateWidget(old);
    if (old.accepted != widget.accepted) _sync();
  }

  void _sync() {
    final clock = MotionScope.enabledOf(context) && !widget.accepted ? MotionScope.clockOf(context) : null;
    if (identical(clock, _clock)) return;
    _clock?.removeListener(_tick);
    _clock = clock;
    clock?.addListener(_tick);
    if (clock != null) _tick();
  }

  void _tick() {
    final t = (_clock!.time % _period) / _period; // 0..1
    final tri = t < 0.5 ? t * 2 : (1 - t) * 2; // üçgen dalga
    _line.value = Curves.easeInOut.transform(tri);
  }

  @override
  void dispose() {
    _clock?.removeListener(_tick);
    _line.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.accepted ? AppFamilies.emerald : AppFamilies.cyan;
    return IgnorePointer(
      child: SizedBox.square(
        dimension: widget.size,
        child: RepaintBoundary(
          child: Stack(
            fit: StackFit.expand,
            children: [
              CustomPaint(
                painter: _FramePainter(
                  line: _line,
                  color: accent.light,
                  glow: accent.base,
                  showLine: !widget.accepted,
                ),
              ),
              if (widget.accepted)
                Center(
                  child: TweenAnimationBuilder<double>(
                    key: const Key('scanner_success_check'),
                    tween: Tween<double>(begin: 0, end: 1),
                    duration: MotionScope.durationOf(context, AppMotion.slow),
                    curve: AppMotion.spring,
                    builder: (context, v, child) => Transform.scale(scale: v.clamp(0.0, 1.2), child: child),
                    // Elle çizilmiş düz disk yerine ortak orb: speküler vurgu + kenar ışığı + parıltı, ✓ simgesi
                    // otomatik koyu mürekkep (beyaz ✓ zümrüt gövdede ≈2.5:1 idi).
                    child: const OrbIconBadge(
                      icon: Icons.check_rounded,
                      family: AppFamilies.emerald,
                      size: OrbSize.xl,
                      active: true,
                      status: OrbStatus.success,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FramePainter extends CustomPainter {
  _FramePainter({required this.line, required this.color, required this.glow, required this.showLine})
      : super(repaint: line);

  final ValueListenable<double> line;
  final Color color;
  final Color glow;
  final bool showLine;

  static const double _radius = 22;
  static const double _arm = 34;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect.deflate(1), const Radius.circular(_radius));

    // İnce iç kenar (cam çerçeve).
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        // .28: .16'da iç çerçeve koyu kamera zemininde ≈1.5:1 ile neredeyse görünmezdi.
        ..color = Colors.white.withValues(alpha: 0.28),
    );

    // Köşe işaretleri: yuvarlak köşeli L'ler.
    const r = _radius;
    const a = _arm;
    final w = size.width - 2;
    final h = size.height - 2;
    const o = 2.0;
    final path = Path()
      ..moveTo(o, o + a)
      ..lineTo(o, o + r)
      ..arcToPoint(const Offset(o + r, o), radius: const Radius.circular(r))
      ..lineTo(o + a, o)
      ..moveTo(w - a, o)
      ..lineTo(w - r, o)
      ..arcToPoint(Offset(w, o + r), radius: const Radius.circular(r))
      ..lineTo(w, o + a)
      ..moveTo(w, h - a)
      ..lineTo(w, h - r)
      ..arcToPoint(Offset(w - r, h), radius: const Radius.circular(r))
      ..lineTo(w - a, h)
      ..moveTo(o + a, h)
      ..lineTo(o + r, h)
      ..arcToPoint(Offset(o, h - r), radius: const Radius.circular(r))
      ..lineTo(o, h - a);
    // Neon parıltı: blur YOK; üst üste binen, giderek incelen ve koyulaşan yarı saydam vuruşlar (koyu zeminde
    // tek geniş vuruş sert kenarlı "dış çizgi" gibi okunuyordu).
    for (final (width, alpha) in const [(18.0, 0.05), (13.0, 0.09), (9.0, 0.16)]) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round
          ..color = glow.withValues(alpha: alpha),
      );
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.5
        ..strokeCap = StrokeCap.round
        ..color = color,
    );

    if (!showLine) return;
    // Tarama çizgisi: yatay gradyan çizgi + üstünde dikey sönen ışık bandı.
    const inset = r * 0.6;
    final y = inset + (size.height - 2 * inset) * line.value;
    final band = Rect.fromLTRB(inset, y - 34, size.width - inset, y);
    // Yuvarlak köşeli band (r8): sert dikey kesimli düz dikdörtgen, yuvarlak çerçeve köşeleri ve uçlarda sönen tarama
    // çizgisiyle uyuşmuyordu.
    canvas.drawRRect(
      RRect.fromRectAndRadius(band, const Radius.circular(8)),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [glow.withValues(alpha: 0), glow.withValues(alpha: 0.38)],
        ).createShader(band),
    );
    canvas.drawLine(
      Offset(inset, y),
      Offset(size.width - inset, y),
      Paint()
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..shader = LinearGradient(
          colors: [color.withValues(alpha: 0), color, color.withValues(alpha: 0)],
        ).createShader(Rect.fromLTWH(inset, y, size.width - 2 * inset, 1)),
    );
  }

  @override
  bool shouldRepaint(_FramePainter old) =>
      old.color != color || old.glow != glow || old.showLine != showLine;
}
