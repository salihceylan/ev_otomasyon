import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/app_pill.dart';

/// Kartlardaki küçük "ek modül" rozeti (röle kartında `CH 3`, panjur kartında `RS485`): kartlar arasında TEK rozet dili.
///
/// [AppPill]'in İNCE sarmalayıcısıdır (WP-V9; adı ve imzası korunur): hap (stadium) şekli, en az 12 sp / 700 yazı (şartname
/// §2.3), aile tonlu zemin (`.14`) + ince kenar (`.40`); metin [AppTheme.readableAccent] ile rozet zemininde de AA
/// kontrastlıdır. Tek satır. Anlamsal düğüm EKLEMEZ (kartın tek anlam düğümü kanalı zaten söyler).
class ModuleBadge extends StatelessWidget {
  const ModuleBadge({super.key, required this.text, this.family = AppFamilies.violet});

  final String text;
  final AccentFamily family;

  @override
  Widget build(BuildContext context) => AppPill(label: text, family: family, maxLines: 1);
}

/// Röle / panjur kartı ADININ en çok satır sayısı. Ad kartın tek tanımlayıcı metnidir ve kesilmemelidir (üst çubuk başlığı
/// gibi SARILIR): normal yazıda 3 satır, büyük yazıda (>= 1.3x) 4 satır; kart yüksekliği zaten esnektir. Eskiden 2 satırdı ve
/// 1.5 ölçekte kilit rozetli 'Teras Aydınlatma Uzun Adlı Şerit LED' adı 'Uzun Adlı Şerit L…' diye kesiliyordu.
int cardNameMaxLines(BuildContext context) => MediaQuery.textScalerOf(context).scale(10) / 10 >= 1.3 ? 4 : 3;

/// Çocuk kilidi göstergesi: amber tonlu yuvarlak içinde kilit simgesi (kartlarda ve hapta tek biçim).
///
/// Simge `Icons.lock_outline` KALIR (testler bu simgeyi arar); çizgi kalınlığı yerine boyut/zemin vurgusu verilir.
/// Boyut yazı ölçeğiyle (en çok 1.3x) büyür; böylece büyük yazıda simge metne oranla küçük kalmaz.
class LockBadge extends StatelessWidget {
  const LockBadge({super.key, this.size = 28});

  /// Yuvarlağın 1.0 ölçekteki çapı (dp). Simge 0.64 x çapıdır.
  final double size;

  @override
  Widget build(BuildContext context) {
    final scale = (MediaQuery.textScalerOf(context).scale(10) / 10).clamp(1.0, 1.3);
    final d = size * scale;
    return Container(
      width: d,
      height: d,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppFamilies.amber.base.withValues(alpha: AppTheme.isDark(context) ? 0.20 : 0.16),
        border: Border.all(color: AppFamilies.amber.base.withValues(alpha: 0.40)),
      ),
      child: Icon(Icons.lock_outline, size: d * 0.64, color: AppTheme.warningText(context)),
    );
  }
}
