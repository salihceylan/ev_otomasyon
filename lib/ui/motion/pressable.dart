import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../theme/tokens.dart';
import 'motion_scope.dart';

/// Haptik geri bildirimi tetikler (beklenmez; hata yutulur). `PressHaptic.none` hiçbir şey yapmaz.
void firePressHaptic(PressHaptic haptic) {
  final Future<void>? call = switch (haptic) {
    PressHaptic.none => null,
    PressHaptic.selection => HapticFeedback.selectionClick(),
    PressHaptic.light => HapticFeedback.lightImpact(),
    PressHaptic.medium => HapticFeedback.mediumImpact(),
    PressHaptic.heavy => HapticFeedback.heavyImpact(),
  };
  if (call != null) unawaited(call.catchError((Object _) {}));
}

/// Basınç geri bildirimi veren dokunma sarmalayıcısı (kart, orb, düğme).
///
/// Sözleşme (şartname §3.1/§4):
/// * **Pressed ölçeği parmak değdiği AN uygulanır**: ham `Listener.onPointerDown` ile, `onTapDown`'un 100 ms
///   `kPressTimeout` gecikmesi beklenmeden (aynı kare, tween YOK).
/// * **`onTap` ASLA gecikmez**: parmak kalkınca eşzamanlı çağrılır; çift dokunma/uzun basma tanıyıcısı eklenmez;
///   hiçbir animasyon `AbsorbPointer`/kuyruk oluşturmaz.
/// * Bırakınca (yalnız `MotionMode.full`): yaylanma `pressedScale → [releaseOvershoot] → 1.0` (≤ 320 ms,
///   kesilebilir: yeni dokunuş animasyonu durdurur). `off` kipinde ölçek anında 1.0'a döner.
/// * Parmak [slop] kadar kayarsa (kaydırma) basılı durum bırakılır.
///
/// Anlamsal düğüm EKLEMEZ (çağıran `Semantics` verir); `GestureDetector` yerleşik `onTap` eylemini sağlar.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    this.child,
    this.builder,
    this.onTap,
    this.onLongPress,
    this.enabled = true,
    this.pressedScale = 0.96,
    this.releaseOvershoot = 1.0,
    this.haptic = PressHaptic.none,
    this.behavior = HitTestBehavior.opaque,
    this.slop = kTouchSlop,
  })  : assert((child != null) != (builder != null), 'child veya builder (yalnız biri) verilmeli'),
        assert(pressedScale > 0 && pressedScale <= 1),
        assert(releaseOvershoot >= 1);

  /// Sabit içerik (basılı durumdan bağımsız).
  final Widget? child;

  /// Basılı duruma bağlı içerik: `builder(context, pressed)`.
  final Widget Function(BuildContext context, bool pressed)? builder;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// `false` ise dokunuş yok sayılır ve ölçek uygulanmaz (`onTap == null` de aynı etkidedir).
  final bool enabled;

  /// Basılıyken ölçek (orb 0.92, kart 0.985, düğme 0.97).
  final double pressedScale;

  /// Bırakınca aşım ölçeği (1.0 = aşım yok; orb 1.04).
  final double releaseOvershoot;

  final PressHaptic haptic;
  final HitTestBehavior behavior;

  /// Bu mesafeden fazla kayınca basılı durum bırakılır.
  final double slop;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> with SingleTickerProviderStateMixin {
  bool _pressed = false;
  int? _pointer;
  Offset _origin = Offset.zero;
  double _releaseFrom = 1.0;

  late final AnimationController _release = AnimationController(vsync: this, duration: AppMotion.slow);

  bool get _interactive => widget.enabled && (widget.onTap != null || widget.onLongPress != null);

  @override
  void didUpdateWidget(Pressable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_interactive && _pressed) {
      _pointer = null;
      _pressed = false;
    }
  }

  @override
  void dispose() {
    _release.dispose();
    super.dispose();
  }

  void _onDown(PointerDownEvent event) {
    if (!_interactive || _pointer != null) return;
    _pointer = event.pointer;
    _origin = event.position;
    _release.stop();
    setState(() => _pressed = true);
  }

  void _onMove(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    if ((event.position - _origin).distance > widget.slop) _end();
  }

  void _onUpOrCancel(PointerEvent event) {
    if (event.pointer != _pointer) return;
    _end();
  }

  void _end() {
    if (_pointer == null) return;
    _pointer = null;
    if (!mounted) return;
    setState(() => _pressed = false);
    if (MotionScope.enabledOf(context)) {
      _releaseFrom = widget.pressedScale;
      _release.forward(from: 0);
    }
  }

  void _handleTap() {
    firePressHaptic(widget.haptic);
    widget.onTap?.call();
  }

  double _scale() {
    if (_pressed) return widget.pressedScale;
    if (!_release.isAnimating) return 1.0;
    final t = _release.value;
    final overshoot = widget.releaseOvershoot;
    if (overshoot <= 1.0) {
      return lerpDouble(_releaseFrom, 1.0, Curves.easeOutCubic.transform(t))!;
    }
    const split = 0.55;
    if (t < split) {
      return lerpDouble(_releaseFrom, overshoot, Curves.easeOutCubic.transform(t / split))!;
    }
    return lerpDouble(overshoot, 1.0, Curves.easeInOut.transform((t - split) / (1 - split)))!;
  }

  @override
  Widget build(BuildContext context) {
    final content = widget.builder != null ? widget.builder!(context, _pressed) : widget.child!;
    return Listener(
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUpOrCancel,
      onPointerCancel: _onUpOrCancel,
      child: GestureDetector(
        behavior: widget.behavior,
        onTap: _interactive && widget.onTap != null ? _handleTap : null,
        onLongPress: _interactive ? widget.onLongPress : null,
        child: AnimatedBuilder(
          animation: _release,
          child: content,
          builder: (context, child) => Transform.scale(scale: _scale(), child: child),
        ),
      ),
    );
  }
}
