import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/settings/settings_card.dart' show familyForAccent;

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

  /// Anlamsal renge en yakın Neon Glass ailesi (orb/parıltı için): ok -> emerald, warn -> amber, error -> rose,
  /// info -> cyan, primary -> sky, purple -> violet.
  static AccentFamily family(Color color) => familyForAccent(color);

  /// Birincil düğmenin anlamsal ailesi: `null`/birincil renk -> tema düğmesi (sky -> cyan) aynen kalır.
  static AccentFamily? buttonFamily(Color? color) {
    if (color == null || color == primary) return null;
    return familyForAccent(color);
  }

  /// Bir vurgu renginin **metin/simge** olarak okunur tonu: [AppTheme.readableAccent] (koyu ve açık temada AYNI
  /// kural: ton korunur, açıklık kart zemininde VE %20 vurgu tonlu rozet/bilgi yüzeyinde WCAG AA 4.5:1 olana kadar
  /// ayarlanır). Eskiden koyu temada ham renk, açık temada sabit HSL açıklığı (0.32) döndürüyordu: kırmızı/mavi koyuda,
  /// yeşil/camgöbeği/amber açıkta 3-4:1'de kalıyordu.
  static Color readable(BuildContext context, Color color) => AppTheme.readableAccent(context, color);
}

/// Servis sayfaları ve sihirbazın ortak metin stilleri.
abstract final class SetupText {
  /// Sabit aralıklı yazı tipi (UUID, MAC, PIN, anahtar). `'monospace'` Android'de platform mono yazı tipidir; iOS ve
  /// masaüstünde tanımsız olduğundan sıralı yedek aileler verilir (yoksa platform varsayılanına düşer).
  static const String monoFamily = 'monospace';
  static const List<String> monoFallback = <String>['RobotoMono', 'Menlo', 'Consolas', 'Courier New'];

  /// Sabit aralıklı stil: yazı tipi ailesi + yedekler; boyut/kalınlık/renk çağırandan.
  static TextStyle mono({
    double? fontSize,
    FontWeight? fontWeight,
    Color? color,
    double? letterSpacing,
    double? height,
  }) =>
      TextStyle(
        fontFamily: monoFamily,
        fontFamilyFallback: monoFallback,
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: color,
        letterSpacing: letterSpacing,
        height: height,
      );

  /// Alt sınır 12 sp (şartname §2.3): küçük metinler [AppTouch.minFontSize]'ın altına inemez.
  static double caption(double size) => size < AppTouch.minFontSize ? AppTouch.minFontSize : size;

  /// Metin ölçeği (1.0 = varsayılan) — düzen kararları için ("büyük yazıda dikey düzen").
  static double scaleOf(BuildContext context) => MediaQuery.textScalerOf(context).scale(10) / 10;

  /// Büyük yazı ölçeği eşiği: bu değerin üstünde satır içi (yan yana) düzenler dikeye geçer.
  static const double largeScale = 1.15;

  static bool isLargeText(BuildContext context) => scaleOf(context) > largeScale;
}
