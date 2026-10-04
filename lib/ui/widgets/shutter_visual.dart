import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../motion/motion_scope.dart';
import '../theme/tokens.dart';

/// Panjur penceresi (çıta görseli, şartname §3.4): 64x72 çerçeveli cam + 9 çıta.
///
/// * [position]: açıklık yüzdesi (0 = tam kapalı, 100 = tam açık). Kapalı oran `(100 - position) / 100`,
///   çıtalar yukarıdan aşağı iner; alt rayda parlak çizgi vardır.
/// * [moving] iken ardışık raporlar arasında konum **lineer** akar (süre = ölçülen rapor aralığı, en çok
///   1,2 sn; ilk raporda 1 sn varsayılır) ve hedefte durur. Yeni rapor gelince akış kesilir ve görünen
///   konumdan yenisine devam eder. Hareket yokken değişiklik kısa bir yumuşak geçişle (220 ms) uygulanır.
/// * [dragging] (kaydırıcı sürükleniyor): konum ANINDA izlenir (canlı geri bildirim).
/// * `MotionMode.off` ya da sistem "animasyonları kaldır": her değişim anında.
///
/// Çizim tek `CustomPaint`'tir (`RepaintBoundary` içinde); yalnız denetleyici bildirince yeniden çizilir. Blur,
/// `saveLayer` ve `Opacity` yoktur. Anlamdan hariçtir (kart başlığı konumu zaten söyler).
class ShutterVisual extends StatefulWidget {
  const ShutterVisual({
    super.key,
    required this.position,
    this.moving = false,
    this.dragging = false,
    this.muted = false,
    this.accent,
    this.width = 64,
    this.height = 72,
  });

  final double position;
  final bool moving;
  final bool dragging;

  /// Çevrimdışı/son bilinen: soluk (doygunluğu düşük) çizim.
  final bool muted;

  /// Alt ray vurgusu (hareket yönü: Aç = emerald, Kapat = sky). Null ise nötr.
  final Color? accent;
  final double width;
  final double height;

  /// Rapor aralığı üst sınırı (şartname: en çok 1,2 sn).
  static const Duration maxTween = Duration(milliseconds: 1200);

  @override
  State<ShutterVisual> createState() => _ShutterVisualState();
}

class _ShutterVisualState extends State<ShutterVisual> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);
  late double _from = widget.position;
  late double _to = widget.position;
  Curve _curve = Curves.linear;
  final Stopwatch _sinceReport = Stopwatch();
  bool _hadReport = false;

  double get _shown => _from + (_to - _from) * _curve.transform(_c.value);

  @override
  void didUpdateWidget(ShutterVisual old) {
    super.didUpdateWidget(old);
    if (old.position == widget.position) return;
    final shown = _shown;
    final full = MotionScope.enabledOf(context);
    if (!full || widget.dragging) {
      _c.stop();
      _from = _to = widget.position;
      _c.value = 0;
    } else if (widget.moving) {
      var d = _hadReport ? _sinceReport.elapsed : const Duration(milliseconds: 1000);
      if (d < const Duration(milliseconds: 250)) d = const Duration(milliseconds: 250);
      if (d > ShutterVisual.maxTween) d = ShutterVisual.maxTween;
      _from = shown;
      _to = widget.position;
      _curve = Curves.linear;
      _c.duration = d;
      _c.forward(from: 0);
    } else {
      _from = shown;
      _to = widget.position;
      _curve = Curves.easeOutCubic;
      _c.duration = AppMotion.base;
      _c.forward(from: 0);
    }
    _hadReport = true;
    _sinceReport
      ..reset()
      ..start();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => CustomPaint(
            size: Size(widget.width, widget.height),
            painter: ShutterWindowPainter(
              position: _shown,
              muted: widget.muted,
              accent: widget.accent,
              dark: dark,
            ),
          ),
        ),
      ),
    );
  }
}

/// [ShutterVisual] çizicisi (golden/test için dışa açık).
class ShutterWindowPainter extends CustomPainter {
  const ShutterWindowPainter({
    required this.position,
    this.muted = false,
    this.accent,
    this.dark = true,
  });

  final double position;
  final bool muted;
  final Color? accent;
  final bool dark;

  static const int slatCount = 9;

  /// Çevrimdışı / son bilinen: renk doygunluğu düşer, **parlaklık korunur**. (Eskiden renkler #64748B'ye
  /// karıştırılıyordu: koyu temada koyu cam/çerçeve koyulaşmak yerine AÇILIYOR ve soluk pencere kartın en dikkat çeken
  /// bloğu oluyordu.) Aynı parlaklıkta griye %78 yaklaştırılır; açık temada da aynı kural geçerlidir.
  Color _m(Color c) {
    if (!muted) return c;
    final l = c.computeLuminance();
    final v = l <= 0.0031308 ? 12.92 * l : 1.055 * math.pow(l, 1 / 2.4) - 0.055;
    final g = (v * 255).round().clamp(0, 255);
    return Color.lerp(c, Color.fromARGB(255, g, g, g), 0.78)!;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final pos = position.clamp(0.0, 100.0);
    final outer = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(10));

    // Çerçeve.
    canvas.drawRRect(
      outer,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_m(dark ? const Color(0xFF3B4C6B) : const Color(0xFFE2E8F0)), _m(dark ? const Color(0xFF1B2740) : const Color(0xFF94A3B8))],
        ).createShader(Offset.zero & size),
    );

    final inner = RRect.fromRectAndRadius((Offset.zero & size).deflate(4), const Radius.circular(7));
    final ir = inner.outerRect;
    canvas.save();
    canvas.clipRRect(inner);

    // Cam: koyu mavi gradyan + açıkken gökyüzü parıltısı.
    canvas.drawRect(
      ir,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_m(const Color(0xFF1E3A5F)), _m(const Color(0xFF0F172A))],
        ).createShader(ir),
    );
    final openFrac = pos / 100;
    if (openFrac > 0) {
      canvas.drawRect(
        ir,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(0.0, 0.7),
            radius: 0.9,
            colors: [
              _m(const Color(0xFF60A5FA)).withValues(alpha: 0.38 * openFrac),
              _m(const Color(0xFF60A5FA)).withValues(alpha: 0.0),
            ],
          ).createShader(ir),
      );
    }

    // Çıtalar: perde yüksekliği kapalı orandır; 9 çıta bu yüksekliği eşit paylaşır.
    final closedH = ir.height * (100 - pos) / 100;
    if (closedH > 0.5) {
      final sh = closedH / slatCount;
      final light = _m(dark ? const Color(0xFFB7C6DD) : const Color(0xFFCBD5E1));
      final deep = _m(dark ? const Color(0xFF5B6E8C) : const Color(0xFF64748B));
      for (var i = 0; i < slatCount; i++) {
        final r = Rect.fromLTWH(ir.left, ir.top + i * sh, ir.width, sh);
        canvas.drawRect(
          r,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [light, deep],
            ).createShader(r),
        );
        // Çıta arası ince koyu aralık.
        canvas.drawRect(
          Rect.fromLTWH(r.left, r.bottom - (sh > 3 ? 1 : 0.5), r.width, sh > 3 ? 1 : 0.5),
          Paint()..color = const Color(0x59000000),
        );
      }
      // Alt ray: parlak çizgi (+ yön rengi ince parıltı).
      final railY = ir.top + closedH;
      final railColor = accent == null ? const Color(0xFFFFFFFF) : _m(accent!);
      canvas.drawRect(
        Rect.fromLTRB(ir.left, railY - 6, ir.right, railY),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [railColor.withValues(alpha: 0.0), railColor.withValues(alpha: accent == null ? 0.18 : 0.38)],
          ).createShader(Rect.fromLTRB(ir.left, railY - 6, ir.right, railY)),
      );
      canvas.drawRect(
        Rect.fromLTWH(ir.left, railY - 2, ir.width, 2),
        Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: muted ? 0.55 : 0.92),
      );
    }

    // Üst kasa (kutu).
    canvas.drawRect(
      Rect.fromLTWH(ir.left, ir.top, ir.width, 3),
      Paint()..color = const Color(0xFF0B1220).withValues(alpha: 0.85),
    );

    // Cam yansıması: sol-üstten çapraz hafif şerit.
    final glare = Path()
      ..moveTo(ir.left, ir.top + ir.height * 0.12)
      ..lineTo(ir.left + ir.width * 0.55, ir.top)
      ..lineTo(ir.left + ir.width * 0.8, ir.top)
      ..lineTo(ir.left, ir.top + ir.height * 0.62)
      ..close();
    canvas.drawPath(glare, Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: 0.07));
    canvas.restore();

    // İç kenar + dış kenar ışığı.
    canvas.drawRRect(
      inner,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0xFF000000).withValues(alpha: 0.45),
    );
    canvas.drawRRect(
      outer.deflate(0.75),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white.withValues(alpha: 0.55), Colors.white.withValues(alpha: 0.05)],
        ).createShader(Offset.zero & size),
    );
  }

  @override
  bool shouldRepaint(ShutterWindowPainter old) =>
      old.position != position || old.muted != muted || old.accent != accent || old.dark != dark;
}
