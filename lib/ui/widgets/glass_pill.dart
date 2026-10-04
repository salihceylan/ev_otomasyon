import 'package:flutter/material.dart';

import 'app_pill.dart';

/// Rol / durum hapı: [AppPill]'in İNCE sarmalayıcısıdır (WP-V9; eski adı ve imzası korunur, görünüm tek rozet diline inmiştir):
/// stadium + vurgu tonu (`.14`) + kenar (`.40`), solda isteğe bağlı [leading] ([GlowDot] ya da simge), 12 sp / w700 etiket;
/// etiket rengi vurgunun **okunabilir tonudur** ([AppTheme.readableAccent]; [textColor] ile ezilebilir).
///
/// Konsol başlık rozeti, çekmece rol rozeti, profil rol hapı, sayaç kutucuğu rozeti ve üst çubuk durum hapı bu bileşenden çizilir.
///
/// * [maxLines] > 1 ⇒ etiket satıra **sarılır** (büyük yazı ölçeğinde "SÜPER YÖNETİCİ KONS…" gibi metin kaybı yok);
///   1 ise tek satır + üç nokta (üst çubuk: yer yoksa hap hiç çizilmez, bkz. `dashboard_app_bar.dart`).
/// * [compact] ⇒ dikey dolgu 2 dp (üst çubuğun 64 dp'lik yüksekliğine sığar).
class GlassPill extends StatelessWidget {
  const GlassPill({
    super.key,
    required this.color,
    required this.label,
    this.leading,
    this.textKey,
    this.letterSpacing,
    this.maxLines = 2,
    this.compact = false,
    this.textColor,
  });

  /// Vurgu rengi (ham aile/vurgu tonu: kenar, dolgu tonu, nokta). Etiket rengi bundan türetilir.
  final Color color;
  final String label;

  /// Soldaki gösterge (genelde `GlowDot(size: 8)` ya da 13-14 dp simge).
  final Widget? leading;

  /// Etiket `Text`'inin anahtarı (testler/erişim için).
  final Key? textKey;
  final double? letterSpacing;
  final int maxLines;
  final bool compact;

  /// Etiket rengi (varsayılan: [color]'ın okunabilir tonu).
  final Color? textColor;

  /// Etiket dışında kalan sabit yatay genişlik: dolgular + kenar (+ [leadingWidth] ve boşluk). Üst çubuk, hapın
  /// SIĞIP SIĞMAYACAĞINI etiket genişliğine bunu ekleyerek önceden ölçer ([AppPill.chromeWidth] ile aynı).
  static double chromeWidth({double leadingWidth = 0}) => AppPill.chromeWidth(leadingWidth: leadingWidth);

  @override
  Widget build(BuildContext context) => AppPill.tinted(
        color: color,
        label: label,
        leading: leading,
        textKey: textKey,
        letterSpacing: letterSpacing,
        maxLines: maxLines,
        compact: compact,
        textColor: textColor,
      );
}
