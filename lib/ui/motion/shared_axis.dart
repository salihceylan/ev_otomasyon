import 'package:flutter/widgets.dart';

import '../theme/tokens.dart';
import 'motion_scope.dart';

/// Yönlü adım geçişi (sihirbaz; hareket v3 §2.4): [index] artınca gelen çocuk sağdan (+0.04 genişlik), azalınca
/// soldan (−0.04) solarak kayar; eski çocuk HEMEN kalkar (`reverseDuration: Duration.zero`), ağaçta her an tek
/// çocuk olur. `MotionMode.off` / "hareketi azalt" → anında.
class SharedAxisSwitcher extends StatefulWidget {
  const SharedAxisSwitcher({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<SharedAxisSwitcher> createState() => _SharedAxisSwitcherState();
}

class _SharedAxisSwitcherState extends State<SharedAxisSwitcher> {
  static const double _shift = 0.04;

  /// +1 ileri, −1 geri; son değişimin yönü (aynı index'le yeniden kurulumda korunur).
  double _direction = 1;

  @override
  void didUpdateWidget(SharedAxisSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index != oldWidget.index) _direction = widget.index > oldWidget.index ? 1 : -1;
  }

  @override
  Widget build(BuildContext context) {
    final begin = Offset(_shift * _direction, 0);
    return AnimatedSwitcher(
      duration: MotionScope.durationOf(context, AppMotion.base),
      reverseDuration: Duration.zero,
      switchInCurve: AppMotion.standard,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(begin: begin, end: Offset.zero).animate(animation),
          child: child,
        ),
      ),
      child: KeyedSubtree(key: ValueKey<int>(widget.index), child: widget.child),
    );
  }
}
