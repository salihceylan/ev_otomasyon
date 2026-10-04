import 'package:flutter/material.dart';

import '../../motion/motion_scope.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';

/// Diyaloglar için adım ilerleme çubuğu: [total] parça, [step] kadarı dolu (1 tabanlı). Yalnız görseldir;
/// ekran okuyucuya "Adım n / m" özeti verir. Dolum geçişi `base` süreli (kapalı hareket kipinde anında).
class StepProgress extends StatelessWidget {
  const StepProgress({
    super.key,
    required this.step,
    required this.color,
    this.total = 3,
    this.padding = const EdgeInsets.fromLTRB(20, 0, 20, 12),
  });

  final int step;
  final int total;
  final AccentFamily color;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Adım $step / $total',
      excludeSemantics: true,
      child: Padding(
        padding: padding,
        child: Row(
          children: [
            for (var i = 1; i <= total; i++) ...[
              if (i > 1) const SizedBox(width: 6),
              Expanded(
                child: AnimatedContainer(
                  duration: MotionScope.durationOf(context, AppMotion.base),
                  curve: AppMotion.standard,
                  height: 5,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    gradient: i <= step ? LinearGradient(colors: [color.light, color.base]) : null,
                    // Henüz gelinmemiş adımların pasif izi, "kaç adım kaldı" bilgisini taşır: ≥ 3:1 (dekoratif kart
                    // kenarı açıkta 1.4:1'di; boşta çubuk görünmüyordu).
                    color: i <= step ? null : AppTheme.getFieldBorder(context),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
