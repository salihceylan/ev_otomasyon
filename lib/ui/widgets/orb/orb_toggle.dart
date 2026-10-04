import 'package:flutter/material.dart';

import '../../motion/motion_scope.dart';
import '../../motion/pressable.dart';
import '../../theme/tokens.dart';
import 'orb_core.dart';

/// Açık/kapalı orb anahtarı (lamba güç orb'u): KAPALI = koyu cam küre + soluk simge; AÇIK = aile renginde parlak
/// küre + nefes alan parıltı. Geçiş `slow` (320 ms) **yaylanma** ([SpringCurve]); AÇILIŞTA orb 1.0 → 1.08 → 1.0
/// büyür (yalnız `MotionMode.full`; `off` kipinde durum anında değişir).
///
/// Sözleşme (bkz. [OrbButton]): dokunma alanı ≥ 48 dp; `onChanged(!value)` pointer-up ile eşzamanlı çağrılır;
/// pressed ölçeği parmak değdiği AN; `onChanged == null` ⇒ devre dışı. Anlamsal: `button` + **`toggled`**
/// (+ `enabled`, [semanticLabel]).
///
/// Değer sahibi widget'tır (kontrollü bileşen): `onChanged` çağrılınca durum, sahibi tarafından güncellenir
/// (iyimser UI `AutomationState`'te).
///
/// ```dart
/// OrbToggle(
///   key: Key('switch_relay_$id'),
///   value: isOn,
///   onChanged: (v) => state.toggleRelay(id, v),
///   icon: Icons.lightbulb_outline_rounded,
///   activeIcon: Icons.lightbulb_rounded,
///   family: AppFamilies.amber,
///   semanticLabel: 'Salon Avize',
///   size: OrbSize.md,
/// )
/// ```
class OrbToggle extends StatefulWidget {
  const OrbToggle({
    super.key,
    required this.value,
    required this.onChanged,
    required this.icon,
    this.activeIcon,
    required this.family,
    required this.semanticLabel,
    this.size = OrbSize.lg,
    this.pending = false,
    this.status = OrbStatus.none,
    this.haptic = PressHaptic.selection,
    this.breathPhase = 0.0,
    this.glowWhenOn = true,
    this.dimmed = false,
  });

  final bool value;

  /// `null` ⇒ devre dışı.
  final ValueChanged<bool>? onChanged;

  /// Kapalıyken simge (ör. ampul çizgisi).
  final IconData icon;

  /// Açıkken simge (ör. dolu ampul); null ise [icon].
  final IconData? activeIcon;
  final AccentFamily family;
  final String semanticLabel;
  final OrbSize size;
  final bool pending;
  final OrbStatus status;
  final PressHaptic haptic;
  final double breathPhase;

  /// Açıkken nefes alan parıltı (slot bütçesi dahilinde).
  final bool glowWhenOn;

  /// Etkin ama SOLUK anahtar (çevrimdışı/son bilinen durum): AÇIKken aile renginin soluk tonu, parıltı/nefes yok; dokunuş
  /// aynen çalışır. KAPALI anahtar normal cam küre kalır. Bkz. [OrbCore.dimmed]. Varsayılan `false`.
  final bool dimmed;

  @override
  State<OrbToggle> createState() => _OrbToggleState();
}

class _OrbToggleState extends State<OrbToggle> with TickerProviderStateMixin {
  late final AnimationController _progress =
      AnimationController(vsync: this, duration: AppMotion.slow, value: widget.value ? 1.0 : 0.0);
  late final AnimationController _pop = AnimationController(vsync: this, duration: AppMotion.slow);

  static final Animatable<double> _popScale = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.08).chain(CurveTween(curve: Curves.easeOutCubic)), weight: 40),
    TweenSequenceItem(tween: Tween(begin: 1.08, end: 1.0).chain(CurveTween(curve: Curves.easeInOut)), weight: 60),
  ]);

  @override
  void didUpdateWidget(OrbToggle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value == widget.value) return;
    final target = widget.value ? 1.0 : 0.0;
    if (MotionScope.enabledOf(context)) {
      _progress.animateTo(target, curve: AppMotion.spring);
      if (widget.value) _pop.forward(from: 0);
    } else {
      _progress.stop();
      _progress.value = target;
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    _pop.dispose();
    super.dispose();
  }

  void _toggle() => widget.onChanged?.call(!widget.value);

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onChanged != null;
    return Semantics(
      button: true,
      toggled: widget.value,
      enabled: enabled,
      label: widget.semanticLabel,
      onTap: enabled ? _toggle : null,
      excludeSemantics: true,
      child: Pressable(
        onTap: enabled ? _toggle : null,
        enabled: enabled,
        pressedScale: 0.92,
        releaseOvershoot: 1.04,
        haptic: widget.haptic,
        builder: (context, pressed) => SizedBox.square(
          dimension: widget.size.footprint,
          child: Center(
            child: AnimatedBuilder(
              animation: Listenable.merge([_progress, _pop]),
              builder: (context, _) => Transform.scale(
                scale: _pop.isAnimating ? _popScale.evaluate(_pop) : 1.0,
                child: OrbCore(
                  size: widget.size,
                  family: widget.family,
                  icon: widget.value ? (widget.activeIcon ?? widget.icon) : widget.icon,
                  active: widget.value && widget.glowWhenOn,
                  pending: widget.pending,
                  status: widget.status,
                  enabled: enabled,
                  pressed: pressed,
                  progress: _progress.value.clamp(0.0, 1.0),
                  breathPhase: widget.breathPhase,
                  // Salt-okunur AÇIK anahtar gri görünmez: soluk aile tonu (değer orb'dan da okunur).
                  mutedFamily: true,
                  dimmed: widget.dimmed,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
