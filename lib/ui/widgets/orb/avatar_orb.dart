import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import 'orb_colors.dart';

/// Avatar orb'u: radyal gradyan gövde + üst speküler vurgu + kenar ışığı + renkli (statik) gölge; ortada harf.
/// Etkileşimsizdir (sahibi dokunmayı yönetir); [ringed] ile dışında ince aile halkası çizilir.
class AvatarOrb extends StatelessWidget {
  const AvatarOrb({
    super.key,
    required this.letter,
    required this.family,
    this.size = 56,
    this.ringed = false,
    this.letterKey,
  });

  final String letter;
  final AccentFamily family;
  final double size;
  final bool ringed;
  final Key? letterKey;

  @override
  Widget build(BuildContext context) {
    final ink = OrbColors.iconFor(family);
    final dark = AppTheme.isDark(context);
    final orb = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          center: const Alignment(-0.35, -0.45),
          radius: 1.05,
          colors: [family.light, family.base, family.deep],
          stops: const [0.0, 0.55, 1.0],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.55), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: family.base.withValues(alpha: dark ? 0.38 : 0.32),
            blurRadius: size > 60 ? 20 : 12,
            offset: Offset(0, size > 60 ? 8 : 4),
          ),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            top: size * 0.08,
            child: Container(
              width: size * 0.62,
              height: size * 0.34,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(size),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.white.withValues(alpha: 0.55), Colors.white.withValues(alpha: 0)],
                ),
              ),
            ),
          ),
          // Harf yazı ölçeğiyle büyümez (orb sabit çaplı; taşma yok).
          Text(
            letter,
            key: letterKey,
            textScaler: TextScaler.noScaling,
            style: TextStyle(fontSize: size * 0.42, fontWeight: FontWeight.w800, color: ink),
          ),
        ],
      ),
    );
    return RepaintBoundary(
      child: ringed
          ? Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: family.base.withValues(alpha: 0.45), width: 1.5),
              ),
              child: orb,
            )
          : orb,
    );
  }
}
