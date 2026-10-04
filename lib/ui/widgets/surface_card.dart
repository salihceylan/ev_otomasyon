import 'package:flutter/material.dart';

import '../motion/pressable.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Camsı kart yüzeyi (Neon Glass, şartname §3.2): dikey gradyan gövde + **gradyan kenar ışığı** (sol-üst →
/// sağ-alt) + yumuşak gölge; [active] iken (ve [accent] varsa) vurgu kenarı + sol-üstte radyal parıltı.
///
/// * `BackdropFilter` YOK (cam görünümü gradyan + rim ile kurulur).
/// * Her kart bir `RepaintBoundary` içindedir; kaydırma/animasyon komşu kartları yeniden boyatmaz.
/// * [onTap] verilirse kart [Pressable] olur: parmak değdiği AN küçük ölçek (0.985), `onTap` gecikmesiz.
///   Dokunma yoksa pasif yüzeydir (basma geri bildirimi yok).
/// * [semanticLabel] verilirse kart tek `button` düğümü olur; verilmezse çocukların anlamı korunur.
///
/// ```dart
/// SurfaceCard(
///   key: Key('card_relay_$id'),
///   accent: AppFamilies.amber.base,
///   active: isOn,
///   onTap: toggle,
///   child: Row(children: [...]),
/// )
/// ```
class SurfaceCard extends StatelessWidget {
  const SurfaceCard({
    super.key,
    required this.child,
    this.accent,
    this.active = false,
    this.onTap,
    this.onLongPress,
    this.padding = const EdgeInsets.all(AppSpace.s16),
    this.margin,
    this.radius = AppRadius.card,
    this.semanticLabel,
    this.haptic = PressHaptic.none,
    this.pressedScale = 0.985,
  });

  final Widget child;

  /// Vurgu rengi (kenar/parıltı). Genelde `AppFamilies.<aile>.base`.
  final Color? accent;

  /// Aktif/vurgulu kart: `accent@0.55` 1.4 px kenar + `accent@0.14` radyal parıltı (accent gerekir).
  final bool active;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  final String? semanticLabel;
  final PressHaptic haptic;
  final double pressedScale;

  @override
  Widget build(BuildContext context) {
    final dark = AppTheme.isDark(context);
    final tokens = SurfaceTokens.of(dark ? Brightness.dark : Brightness.light);
    final emphasized = active && accent != null;

    Widget card = RepaintBoundary(
      child: DecoratedBox(
        decoration: AppTheme.glassDecoration(
          context,
          accent: accent,
          radius: radius,
          emphasized: emphasized,
          solidRim: false,
        ),
        child: CustomPaint(
          foregroundPainter: SurfaceRimPainter(
            radius: radius,
            rimStart: tokens.rimStart,
            rimEnd: tokens.rimEnd,
            accent: accent,
            emphasized: emphasized,
          ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );

    if (onTap != null || onLongPress != null) {
      card = Pressable(
        onTap: onTap,
        onLongPress: onLongPress,
        pressedScale: pressedScale,
        haptic: haptic,
        child: card,
      );
      if (semanticLabel != null) {
        card = Semantics(button: true, label: semanticLabel, onTap: onTap, child: card);
      }
    } else if (semanticLabel != null) {
      card = Semantics(label: semanticLabel, container: true, child: card);
    }

    if (margin != null) card = Padding(padding: margin!, child: card);
    return card;
  }
}

/// [SurfaceCard] kenar ışığı: 1 px, sol-üstten sağ-alta `rimStart → rimEnd` gradyan; vurgulu kartta
/// `accent@0.55` 1.4 px düz kenar, vurgu rengi var ama pasifse `accent@0.28`.
class SurfaceRimPainter extends CustomPainter {
  const SurfaceRimPainter({
    required this.radius,
    required this.rimStart,
    required this.rimEnd,
    this.accent,
    this.emphasized = false,
  });

  final double radius;
  final Color rimStart;
  final Color rimEnd;
  final Color? accent;
  final bool emphasized;

  @override
  void paint(Canvas canvas, Size size) {
    final width = emphasized ? AppGlass.accentRimWidth : 1.0;
    final rect = (Offset.zero & size).deflate(width / 2);
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular((radius - width / 2).clamp(0.0, double.infinity)));
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    if (accent != null) {
      paint.color = accent!.withValues(alpha: emphasized ? AppGlass.accentRimAlpha : 0.28);
    } else {
      paint.shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [rimStart, rimEnd],
      ).createShader(rect);
    }
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(SurfaceRimPainter old) =>
      old.radius != radius ||
      old.rimStart != rimStart ||
      old.rimEnd != rimEnd ||
      old.accent != accent ||
      old.emphasized != emphasized;
}
