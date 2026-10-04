import 'package:flutter/widgets.dart';

import '../theme/tokens.dart';
import 'motion_scope.dart';

/// Durum geçişi (yükleme → içerik → boş/hata; hareket v3 §2.3): [stateKey] değişince yeni çocuk solarak ve
/// 8 dp aşağıdan yukarı kayarak gelir; eski çocuk HEMEN kalkar (`reverseDuration: Duration.zero`), ağaçta her an
/// tek çocuk olur (eski+yeni metin birlikte görünmez). Aynı [stateKey] ile çocuk değişirse animasyon yoktur.
/// `MotionMode.off` / "hareketi azalt" → anında.
class StateSwitcher extends StatelessWidget {
  const StateSwitcher({
    super.key,
    required this.stateKey,
    required this.child,
    this.duration,
    this.alignment = AlignmentDirectional.topStart,
  });

  final Object stateKey;
  final Widget child;

  /// Varsayılan [AppMotion.base] (220 ms).
  final Duration? duration;
  final AlignmentGeometry alignment;

  static const double _rise = 8.0;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: MotionScope.durationOf(context, duration ?? AppMotion.base),
      reverseDuration: Duration.zero,
      switchInCurve: AppMotion.standard,
      layoutBuilder: (current, previous) => Stack(
        alignment: alignment,
        children: <Widget>[...previous, ?current],
      ),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: AnimatedBuilder(
          animation: animation,
          builder: (context, c) => Transform.translate(offset: Offset(0, _rise * (1 - animation.value)), child: c),
          child: child,
        ),
      ),
      child: KeyedSubtree(key: ValueKey<Object>(stateKey), child: child),
    );
  }
}
