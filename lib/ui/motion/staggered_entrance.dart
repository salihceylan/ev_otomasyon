import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../theme/tokens.dart';
import 'motion_scope.dart';

/// Öğenin ekrana ilk geldiğinde **tek sefer** belirmesi: solma + [offset] dp aşağıdan kayma, [index]'e göre
/// kademeli (öğe başına [step], en çok [AppMotion.staggerMaxItems] öğe).
///
/// * Gecikme `Interval` ile yapılır (tek `AnimationController`); `Timer`/`Future.delayed` YOK → bekleyen
///   zamanlayıcı bırakmaz, `pumpAndSettle` biter.
/// * `MotionMode.off`: çocuk anında tam görünür (ara durum YOK).
/// * Giriş girdiyi bloklamaz (`IgnorePointer` yok); animasyon bitince ağaç yapısı aynı kalır.
/// * Solma tek seferlik ve ≤ ~480 ms'dir (`FadeTransition`); sonsuz/ambient değildir.
///
/// ```dart
/// for (var i = 0; i < cards.length; i++) StaggeredEntrance(index: i, child: cards[i])
/// ```
class StaggeredEntrance extends StatefulWidget {
  const StaggeredEntrance({
    super.key,
    required this.index,
    required this.child,
    this.step = AppMotion.staggerStep,
    this.duration = AppMotion.base,
    this.offset = 12,
    this.curve = AppMotion.standard,
  });

  /// Listedeki sıra (0'dan). [AppMotion.staggerMaxItems]'ten büyükler sonuncuyla aynı gecikmeyi alır.
  final int index;
  final Widget child;
  final Duration step;
  final Duration duration;

  /// Başlangıç dikey kayması (dp).
  final double offset;
  final Curve curve;

  @override
  State<StaggeredEntrance> createState() => _StaggeredEntranceState();
}

class _StaggeredEntranceState extends State<StaggeredEntrance> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _progress;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    final slot = math.min(math.max(widget.index, 0), AppMotion.staggerMaxItems - 1);
    final delay = widget.step * slot;
    final total = delay + widget.duration;
    _controller = AnimationController(vsync: this, duration: total);
    final begin = total.inMicroseconds == 0 ? 0.0 : delay.inMicroseconds / total.inMicroseconds;
    _progress = CurvedAnimation(parent: _controller, curve: Interval(begin, 1.0, curve: widget.curve));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MotionScope.enabledOf(context)) {
      _controller.forward();
    } else {
      _controller.value = 1.0;
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _progress,
      child: AnimatedBuilder(
        animation: _progress,
        child: widget.child,
        builder: (context, child) => Transform.translate(
          offset: Offset(0, (1 - _progress.value) * widget.offset),
          child: child,
        ),
      ),
    );
  }
}
