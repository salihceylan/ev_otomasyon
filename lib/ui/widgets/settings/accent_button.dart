import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../theme/tone_button_surface.dart';

/// Birincil form düğmesinin ([ElevatedButton]) anlamsal renkli (aile) gradyan stili.
///
/// Yıkıcı (rose), onay (emerald), dikkat (amber) ya da misafir (violet) düğmeleri için AYNI hap şeklini koruyup
/// rengi değiştirir. [family] `null` ise tema düğmesi aynen kalır. Devre dışıyken tema'nın düz cam yüzeyi çizilir.
///
/// Gerçekleme ortaktır: gradyan, cila, kenar, gölge ve mürekkep seçimi [ToneButtonSurface] / [ButtonTone]'dadır
/// (tema da ekranlardaki yerel `backgroundColor`'ı aynı yüzeyle çizer; bu API ile yerel renk AYNI görünür).
/// Metin/simge rengi gradyanın her ucunda ≥ 4.5:1'dir: koyu aileler için beyaz, açık aileler (amber, cyan) için
/// koyu mürekkep.
ButtonStyle accentButtonStyle(AccentFamily? family, {Size? minimumSize}) {
  if (family == null) return ElevatedButton.styleFrom(minimumSize: minimumSize);
  return toneButtonStyle(family, minimumSize: minimumSize);
}

/// Düğme içi simge boyutu: yazı ölçeğiyle büyür (taban [base] dp; en çok 28 dp). Büyük yazıda etiket iki satıra
/// sarınca sabit 16 dp'lik simge etiketin yanında minik kalıyordu.
double accentIconSize(BuildContext context, {double base = 18}) =>
    MediaQuery.textScalerOf(context).scale(base).clamp(base, 28.0).toDouble();

/// İkincil (çerçeveli) düğme stili ([OutlinedButton] türü KALIR): tema hap (stadium) şekli + min 48 dp; **çerçeve
/// ve metin/simge AYNI aileden**: metin/simge [AppTheme.readableAccent] (AA), çerçeve 1.5 dp ve [AppTheme.outlinedBorder]
/// (TEK ton kuralı: iki temada, kart/diyalog/sayfa zeminlerinin hepsinde ≥ 3:1; tema `OutlinedButton`ıyla AYNI kural olduğundan
/// açıkta `accentOutlinedButtonStyle(context, sky)` ile varsayılan çerçeveli düğme birebir aynı çerçeve tonunu verir). Eskiden
/// koyuda `family.base@0.70` (sky/rose/violet ≈ 2.7–2.8:1) ve açıkta `family.deep` (amber ≈ 2.8:1; tema varsayılanı ise ≈ 2.4:1)
/// idi. Şekil/dolgu geçersiz KILINMAZ (tema stadium'u + yatay 22 dolgu); ham Material renkleri (cyanAccent, amber …)
/// kullanılmaz.
///
/// Pasifken (`onPressed == null`) tema'nın soluk çerçevesi/metni geçerlidir.
ButtonStyle accentOutlinedButtonStyle(BuildContext context, AccentFamily family, {Size? minimumSize}) {
  final ink = AppTheme.readableAccent(context, family.base);
  final border = AppTheme.outlinedBorder(context, family);
  return OutlinedButton.styleFrom(
    minimumSize: minimumSize ?? const Size.fromHeight(AppTouch.minTarget),
    foregroundColor: ink,
    iconColor: ink,
  ).copyWith(
    side: WidgetStateProperty.resolveWith(
      // Pasifte null: tema'nın pasif çerçevesi geçerli olur.
      (states) => states.contains(WidgetState.disabled) ? null : BorderSide(color: border, width: 1.5),
    ),
  );
}
