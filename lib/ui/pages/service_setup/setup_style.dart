import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Servis kurulum sihirbazı ve servis sayfalarının renkleri (tek noktadan).
///
/// Tema belirteçleri değişirse yalnızca burası güncellenir; sayfalar doğrudan `AppTheme`'e
/// bağlanmaz.
class SetupColors {
  SetupColors._();

  static const Color ok = AppTheme.accentGreen;
  static const Color warn = AppTheme.accentAmber;
  static const Color error = AppTheme.accentRed;
  static const Color info = AppTheme.accentCyan;
  static const Color primary = AppTheme.primaryBlue;
  static const Color primaryLight = AppTheme.primaryBlueLight;
  static const Color purple = AppTheme.accentPurple;

  static Color card(BuildContext context) => AppTheme.getCardColor(context);
  static Color border(BuildContext context) => AppTheme.getCardBorder(context);
  static Color text(BuildContext context) => AppTheme.getTextPrimary(context);
  static Color muted(BuildContext context) => AppTheme.getTextMuted(context);
  static Color surface(BuildContext context) => AppTheme.getSurfaceColor(context);
  static Color background(BuildContext context) => AppTheme.getScaffoldBg(context);
  static bool isDark(BuildContext context) => AppTheme.isDark(context);

  /// Açık temada amber/yeşil metin okunaklı kalsın diye bir ton koyulaştırılır.
  static Color readable(BuildContext context, Color color) {
    if (isDark(context)) return color;
    return HSLColor.fromColor(color).withLightness(0.32).toColor();
  }
}
