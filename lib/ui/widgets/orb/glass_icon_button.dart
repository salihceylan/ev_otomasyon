import 'package:flutter/material.dart';

import '../../motion/pressable.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';

/// Üst çubuk eylemleri için **cam disk** düğme: kart gradyanı + 1 px kenar ışığı + yumuşak statik gölge.
/// Görsel çap 44, **dokunma hedefi 48 dp**; isteğe bağlı **rozet noktası** (bildirim/uyarı).
///
/// Sözleşme (bkz. [OrbButton]): `onTap` gecikmesiz; pressed ölçeği (0.92) parmak değdiği AN; `onTap == null`
/// ⇒ devre dışı. Anlamsal: `button`, `enabled`, etiket ([semanticLabel], rozet varsa [badgeSemantics] eklenir).
///
/// ```dart
/// GlassIconButton(
///   key: Key('nav_settings'),
///   icon: Icons.settings_outlined,
///   semanticLabel: 'Ayarlar',
///   showBadge: hasWarning,
///   badgeSemantics: 'Uyarı var',
///   onTap: openSettings,
/// )
/// ```
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    required this.semanticLabel,
    this.size = 44,
    this.showBadge = false,
    this.badgeColor,
    this.badgeSemantics,
    this.iconColor,
    this.haptic = PressHaptic.light,
  });

  final IconData icon;

  /// `null` ⇒ devre dışı.
  final VoidCallback? onTap;
  final String semanticLabel;

  /// Görsel disk çapı (dp). Düzen/dokunma kutusu `max(size, 48)`.
  final double size;
  final bool showBadge;

  /// Rozet rengi (varsayılan rose).
  final Color? badgeColor;

  /// Rozet açıklaması (ekran okuyucu); rozet gösteriliyorsa etikete eklenir.
  final String? badgeSemantics;
  final Color? iconColor;
  final PressHaptic haptic;

  static const double badgeSize = 10;

  @override
  Widget build(BuildContext context) {
    final dark = AppTheme.isDark(context);
    final tokens = SurfaceTokens.of(dark ? Brightness.dark : Brightness.light);
    final enabled = onTap != null;
    final footprint = size < AppTouch.minTarget ? AppTouch.minTarget : size;
    final fg = iconColor ??
        (enabled ? AppTheme.getTextPrimary(context) : AppTheme.getTextMuted(context).withValues(alpha: 0.8));
    final badge = badgeColor ?? AppFamilies.rose.base;
    final label = showBadge && badgeSemantics != null ? '$semanticLabel, $badgeSemantics' : semanticLabel;

    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: Pressable(
        onTap: onTap,
        enabled: enabled,
        pressedScale: 0.92,
        releaseOvershoot: 1.04,
        haptic: haptic,
        builder: (context, pressed) => SizedBox.square(
          dimension: footprint,
          child: Center(
            child: SizedBox.square(
              dimension: size,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: RepaintBoundary(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: dark ? const Color(0x59000000) : tokens.shadow,
                              blurRadius: 12,
                              offset: const Offset(0, 5),
                            ),
                          ],
                        ),
                        child: CustomPaint(
                          painter: GlassDiskPainter(dark: dark, pressed: pressed),
                          child: Center(child: Icon(icon, size: size * 0.5, color: fg)),
                        ),
                      ),
                    ),
                  ),
                  if (showBadge)
                    Positioned(
                      right: size * 0.06,
                      top: size * 0.06,
                      child: Container(
                        key: const ValueKey('glass_badge_dot'),
                        width: badgeSize,
                        height: badgeSize,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: badge,
                          border: Border.all(color: tokens.cardTop, width: 2),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Cam disk boyayıcısı: dikey kart gradyanı + üst parlaklık + 1 px sol-üst → sağ-alt kenar ışığı.
class GlassDiskPainter extends CustomPainter {
  const GlassDiskPainter({required this.dark, this.pressed = false});

  final bool dark;
  final bool pressed;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final center = rect.center;
    final radius = size.shortestSide / 2;

    final fill = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: dark
          ? [const Color(0xFF2A3A5E), const Color(0xFF172238)]
          : [const Color(0xFFFFFFFF), const Color(0xFFEEF2F8)],
    ).createShader(rect);
    canvas.drawCircle(center, radius, Paint()..shader = fill);

    // Üst cam parlaklığı (ince elips).
    final sheen = Rect.fromLTWH(center.dx - radius * 0.62, center.dy - radius * 0.92, radius * 1.24, radius * 0.9);
    canvas.drawOval(
      sheen,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            (dark ? Colors.white : Colors.white).withValues(alpha: pressed ? 0.06 : (dark ? 0.16 : 0.70)),
            Colors.white.withValues(alpha: 0),
          ],
        ).createShader(sheen),
    );

    canvas.drawCircle(
      center,
      radius - 0.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? [Colors.white.withValues(alpha: 0.34), Colors.white.withValues(alpha: 0.05)]
              : [const Color(0xFF0B1016).withValues(alpha: 0.10), const Color(0xFF0B1016).withValues(alpha: 0.18)],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(GlassDiskPainter old) => old.dark != dark || old.pressed != pressed;
}
