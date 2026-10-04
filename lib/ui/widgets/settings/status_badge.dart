import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../app_pill.dart';

/// Durum / rol rozeti (WP-F2): aile listesi, davet ve ayar kartlarında AYNI görünen yerel bileşen. WP-V9'dan beri
/// [AppPill]'in İNCE sarmalayıcısıdır (adı ve imzası korunur; görünüm tek rozet dilindedir):
///
/// * Hap (stadium) şekli, **en az 12 sp / w700** metin (şartname §2.3), vurgu tonu (`.14`) + kenar (`.40`).
/// * Metin ve simge HER temada [AppTheme.readableAccent] ile çizilir (WCAG AA ≥ 4.5:1: açık temada koyulaşır, koyu temada
///   gerekirse açılır): ham vurgu rengi ASLA yazı rengi olarak kullanılmaz.
/// * Yazı ölçeği büyüdüğünde etiket en çok [maxLines] satıra sarar (taşma/kırpılma yok); anlamsal etiket görünen metindir.
///
/// Etiket metni olduğu gibi gösterilir (büyük/küçük harf dönüşümü yapılmaz): testler metni birebir arar.
class StatusBadge extends StatelessWidget {
  const StatusBadge({
    super.key,
    required this.label,
    required this.family,
    this.icon,
    this.maxLines = 2,
  });

  final String label;
  final AccentFamily family;

  /// Etiketin önünde küçük simge (isteğe bağlı; renk tek ipucu olmasın diye).
  final IconData? icon;
  final int maxLines;

  @override
  Widget build(BuildContext context) => AppPill(label: label, family: family, icon: icon, maxLines: maxLines);
}
