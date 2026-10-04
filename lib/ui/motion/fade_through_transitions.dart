import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// "Fade through" sayfa geçişi (şartname §3.3): giden sayfa ilk **%35**'te solar, gelen sayfa sonraki **%65**'te
/// belirir (hafif 12 dp yukarı kayma ile). Aynı anda iki sayfa da tam opak OLMAZ ve saydam `Scaffold`
/// (bu uygulamada `scaffoldBackgroundColor` saydam) "hayalet" üst üste binmesi oluşmaz: giden sayfa tamamen
/// kaybolmadan gelen belirmeye başlamaz.
///
/// * Süre: ileri [AppMotion.pageTransition] (260 ms), geri 240 ms (≤ 280 ms).
/// * `ThemeData.pageTransitionsTheme` içinde TÜM platformlara bağlanır (`AppTheme`).
/// * `MotionScope` kapsamından bağımsızdır (rota sürelerini Flutter belirler); `disableAnimations` açıkken
///   Flutter zaten geçişi anında yapar.
class FadeThroughPageTransitionsBuilder extends PageTransitionsBuilder {
  const FadeThroughPageTransitionsBuilder();

  /// Giden sayfanın solma payı (0..0.35); gelen sayfa bundan sonra belirir.
  static const double fadeOutEnd = 0.35;

  static const double _slideDp = 12;

  static final Animatable<double> _incoming =
      CurveTween(curve: const Interval(fadeOutEnd, 1.0, curve: Curves.easeOutCubic));
  static final Animatable<double> _outgoing =
      Tween<double>(begin: 1, end: 0).chain(CurveTween(curve: const Interval(0.0, fadeOutEnd, curve: Curves.easeIn)));

  @override
  Duration get transitionDuration => AppMotion.pageTransition;

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 240);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final incoming = animation.drive(_incoming);
    return FadeTransition(
      opacity: secondaryAnimation.drive(_outgoing),
      child: FadeTransition(
        opacity: incoming,
        child: AnimatedBuilder(
          animation: incoming,
          child: child,
          builder: (context, child) => Transform.translate(
            offset: Offset(0, (1 - incoming.value) * _slideDp),
            child: child,
          ),
        ),
      ),
    );
  }
}
