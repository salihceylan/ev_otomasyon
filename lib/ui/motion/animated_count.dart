import 'package:flutter/widgets.dart';

import '../theme/tokens.dart';
import 'motion_scope.dart';

/// Sayı/yüzde değişiminde ara değerleri sayarak gösteren metin (`28/800` sayaçlar için).
///
/// * `MotionMode.off` (varsayılan, kapsam yok, `disableAnimations`): **ara değer YOK**; yeni değer anında
///   gösterilir ve hiçbir animasyon/zamanlayıcı kurulmaz.
/// * `MotionMode.full`: değer, [duration] boyunca yeni hedefe akar; akış sürerken hedef değişirse **görünen
///   değerden** yeni hedefe devam edilir (kesilebilir).
/// * Ağaçta her an TEK `Text` bulunur (eski+yeni metin birlikte olmaz: `find.text` testleri güvenlidir).
/// * Rakamlar tabular ([FontFeature.tabularFigures]): sayı değişirken genişlik titremez.
/// * Anlamsal etiket yalnız **son değeri** söyler (ara değerler ekran okuyucuya sızmaz).
///
/// ```dart
/// AnimatedCount(value: pos, format: (v) => '%$v', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800))
/// ```
class AnimatedCount extends StatefulWidget {
  const AnimatedCount({
    super.key,
    required this.value,
    this.format,
    this.style,
    this.duration = AppMotion.slow,
    this.curve = AppMotion.standard,
    this.textAlign,
    this.maxLines = 1,
    this.overflow = TextOverflow.clip,
  });

  final int value;

  /// Metin biçimi (varsayılan `'$v'`). Ara değerler de bu biçimle üretilir.
  final String Function(int value)? format;

  final TextStyle? style;
  final Duration duration;
  final Curve curve;
  final TextAlign? textAlign;
  final int maxLines;
  final TextOverflow overflow;

  @override
  State<AnimatedCount> createState() => _AnimatedCountState();
}

class _AnimatedCountState extends State<AnimatedCount> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);
  late int _from = widget.value;
  late int _to = widget.value;

  String _text(int v) => (widget.format ?? _plain)(v);
  static String _plain(int v) => '$v';

  int get _current {
    if (!_controller.isAnimating) return _to;
    final t = widget.curve.transform(_controller.value.clamp(0.0, 1.0));
    return (_from + (_to - _from) * t).round();
  }

  @override
  void didUpdateWidget(AnimatedCount oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value == oldWidget.value) return;
    final animate = MotionScope.enabledOf(context) && widget.duration > Duration.zero;
    _from = animate ? _current : widget.value;
    _to = widget.value;
    _controller.stop();
    if (animate && _from != _to) {
      _controller.duration = widget.duration;
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = (widget.style ?? DefaultTextStyle.of(context).style).copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Semantics(
      label: _text(_to),
      excludeSemantics: true,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => Text(
          _text(_current),
          style: style,
          textAlign: widget.textAlign,
          maxLines: widget.maxLines,
          overflow: widget.overflow,
        ),
      ),
    );
  }
}
