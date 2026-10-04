import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'ambient_clock.dart';
import 'motion_scope.dart';

/// İskelet (skeleton) yükleme bloğu: spinner YERİNE içeriğin şeklini gösterir.
///
/// * **Tek paylaşılan süpürme**: parıltı bandı her iskelette aynı [AmbientClock] zamanından türetilir (hepsi
///   eş zamanlı akar, ayrı controller YOK); kendi `Ticker`'ı yoktur.
/// * **12 sn sonra durur** ([maxSweep]): iskelet bağlandığı andan itibaren süpürme [maxSweep] sürer, sonra
///   dinleyici bırakılır ve statik kalır (sonsuz animasyon bırakmaz).
/// * `MotionMode.off`: statik blok (saat dinlenmez).
/// * Anlamsal olarak yok sayılır (`ExcludeSemantics`); yükleme metni/`liveRegion` kapsayıcıda verilir.
///
/// ```dart
/// const Skeleton(width: 120, height: 14)
/// const Skeleton.circle(size: 44)
/// ```
class Skeleton extends StatefulWidget {
  const Skeleton({
    super.key,
    this.width,
    this.height = 14,
    this.radius = AppRadius.r8,
    this.maxSweep = defaultMaxSweep,
  }) : circle = false;

  /// Dairesel iskelet (avatar/orb yer tutucusu).
  const Skeleton.circle({
    super.key,
    double size = 44,
    this.maxSweep = defaultMaxSweep,
  })  : width = size,
        height = size,
        radius = 0,
        circle = true;

  /// `null` ise üst kısıtın tüm genişliği (üst kısıt sınırlı olmalı: Column/Expanded/FractionallySizedBox).
  final double? width;
  final double height;
  final double radius;
  final bool circle;

  /// Süpürmenin en uzun süresi (şartname: 12 sn).
  final Duration maxSweep;

  static const Duration defaultMaxSweep = Duration(seconds: 12);

  /// Bir süpürme turunun süresi.
  static const double sweepPeriodSeconds = 1.4;

  /// Taban ve süpürme (parıltı bandı) renkleri. İKİ temada da band tabandan AÇIKTIR ("parlayan süpürme"): açık temada
  /// eskiden band tabandan KOYUYDU (ink@10% > ink@6%) ve iskelet "kirli leke" gibi akıyordu; taban da ≈ 1.13:1 ile
  /// neredeyse görünmezdi. Açık: slate@22% taban (beyaz kartta ve kart alt ucunda ≈ 1.32:1; eskisi 1.13:1), beyaz@80% band
  /// (merkezde tabana göre ≈ 35 seviye daha açık: süpürme belirgin); koyu: white@10% taban, white@18% band.
  static const Color skeletonBaseDark = Color(0x1AFFFFFF);
  static const Color skeletonHighlightDark = Color(0x2EFFFFFF);
  static const Color skeletonBaseLight = Color(0x38647489);
  static const Color skeletonHighlightLight = Color(0xCCFFFFFF);

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> {
  final ValueNotifier<double> _phase = ValueNotifier<double>(-1);
  AmbientClock? _clock;
  double _t0 = 0;
  bool _expired = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final clock = MotionScope.clockOf(context);
    final enabled = MotionScope.enabledOf(context);
    if (!enabled || _expired) {
      _detach();
      _phase.value = -1;
      return;
    }
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
    if (clock == null) return;
    _update(clock);
  }

  void _update(AmbientClock clock) {
    final elapsed = clock.time - _t0;
    if (elapsed * Duration.microsecondsPerSecond >= widget.maxSweep.inMicroseconds) {
      _expired = true;
      _detach();
      _phase.value = -1;
      return;
    }
    _phase.value = (clock.time % Skeleton.sweepPeriodSeconds) / Skeleton.sweepPeriodSeconds;
  }

  @override
  void dispose() {
    _detach();
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = AppTheme.isDark(context);
    return ExcludeSemantics(
      child: SizedBox(
        width: widget.width ?? double.infinity,
        height: widget.height,
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _SkeletonPainter(
              base: dark ? Skeleton.skeletonBaseDark : Skeleton.skeletonBaseLight,
              highlight: dark ? Skeleton.skeletonHighlightDark : Skeleton.skeletonHighlightLight,
              radius: widget.radius,
              circle: widget.circle,
              phase: _phase,
            ),
          ),
        ),
      ),
    );
  }
}

class _SlideGradient extends GradientTransform {
  const _SlideGradient(this.slide);
  final double slide;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * slide, 0, 0);
}

class _SkeletonPainter extends CustomPainter {
  _SkeletonPainter({
    required this.base,
    required this.highlight,
    required this.radius,
    required this.circle,
    required this.phase,
  }) : super(repaint: phase);

  final Color base;
  final Color highlight;
  final double radius;
  final bool circle;
  final ValueListenable<double> phase;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final shape = circle ? RRect.fromRectAndRadius(rect, Radius.circular(size.shortestSide / 2)) : RRect.fromRectAndRadius(rect, Radius.circular(radius));
    canvas.drawRRect(shape, Paint()..color = base);
    final p = phase.value;
    if (p < 0) return;
    final slide = p * 2 - 1; // -1 .. +1: bant kutunun dışından girip dışına çıkar
    final shader = LinearGradient(
      colors: [highlight.withValues(alpha: 0), highlight, highlight.withValues(alpha: 0)],
      stops: const [0.30, 0.5, 0.70],
      transform: _SlideGradient(slide),
    ).createShader(rect);
    canvas.drawRRect(shape, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_SkeletonPainter old) =>
      old.base != base || old.highlight != highlight || old.radius != radius || old.circle != circle || old.phase != phase;
}

/// Metin satırı yer tutucusu: yüksekliği YAZI ÖLÇEĞİNE göre ([MediaQuery.textScalerOf]) hesaplanır, yani veri gelip
/// gerçek metin (aynı [fontSize] × [lineHeight]) yerine geçtiğinde düzen ZIPLAMAZ. Sabit yükseklikli
/// `Skeleton(height: 28)` 1.5 yazı ölçeğinde gerçek sayıdan ≈ 17 dp kısa kalıp içeriği aşağı itiyordu.
///
/// Çubuk, satır kutusunun [barHeightFactor] kadarını doldurur ve [alignment] ile hizalanır. `width` null ise
/// üst kısıtın tüm genişliği ([Skeleton] ile aynı kural).
///
/// ```dart
/// const SkeletonText(fontSize: 28, lineHeight: 1.1, width: 64)   // sayaç değeri
/// ```
class SkeletonText extends StatelessWidget {
  const SkeletonText({
    super.key,
    this.width,
    this.fontSize = 14,
    this.lineHeight = 1.2,
    this.barHeightFactor = 0.78,
    this.radius = AppRadius.r8,
    this.alignment = AlignmentDirectional.centerStart,
  })  : assert(fontSize > 0),
        assert(lineHeight > 0),
        assert(barHeightFactor > 0 && barHeightFactor <= 1);

  final double? width;

  /// Yer tuttuğu metnin yazı boyutu (sp, ölçeklenmemiş).
  final double fontSize;

  /// Yer tuttuğu metnin satır yüksekliği çarpanı (`TextStyle.height`; yoksa ≈ 1.2).
  final double lineHeight;
  final double barHeightFactor;
  final double radius;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    final line = MediaQuery.textScalerOf(context).scale(fontSize) * lineHeight;
    return SizedBox(
      height: line,
      child: Align(
        alignment: alignment,
        child: Skeleton(width: width, height: line * barHeightFactor, radius: radius),
      ),
    );
  }
}

/// Kart biçiminde iskelet: [showLeading] daire + [lines] satır. Camsı kart yüzeyi (`AppTheme.cardDecoration`).
///
/// Sabit yükseklik YOK: içerik yüksekliğine göre büyür, yazı ölçeğinden etkilenmez.
class SkeletonCard extends StatelessWidget {
  const SkeletonCard({
    super.key,
    this.lines = 2,
    this.showLeading = true,
    this.leadingSize = 44,
    this.padding = const EdgeInsets.all(AppSpace.s16),
  }) : assert(lines >= 1);

  final int lines;
  final bool showLeading;
  final double leadingSize;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    const widths = [1.0, 0.62, 0.8, 0.45];
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: DecoratedBox(
          decoration: AppTheme.cardDecoration(context),
          child: Padding(
            padding: padding,
            child: Row(
              children: [
                if (showLeading) ...[
                  Skeleton.circle(size: leadingSize),
                  const SizedBox(width: AppSpace.s16),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < lines; i++) ...[
                        if (i > 0) const SizedBox(height: AppSpace.s12),
                        FractionallySizedBox(
                          widthFactor: widths[i % widths.length],
                          child: Skeleton(height: i == 0 ? 16 : 12),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
