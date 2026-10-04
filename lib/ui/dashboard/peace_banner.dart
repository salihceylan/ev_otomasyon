import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/automation_state.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/orb/orb.dart';
import '../widgets/surface_card.dart';
import 'close_all_lights_button.dart';

/// Gece huzur bandı: evde açık lamba varsa "Hepsini Kapat" önerir. Toplu komut yetkisi
/// (`canUseGroupCommands`) yoksa (misafir) görünmez. Anahtar: `Key('banner_peace')`.
class PeaceBanner extends StatelessWidget {
  const PeaceBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.select<AutomationState, ({int lights, bool canUse})>(
      (s) => (lights: s.openLightsCount, canUse: s.capabilities.canUseGroupCommands),
    );
    if (!vm.canUse || vm.lights <= 0) return const SizedBox.shrink();

    final accent = AppFamilies.amber.base;
    // Yazı boyutları şartname tabanının (12 sp) üstünde: başlık 14 (AppText.body) / alt metin 12.5 (AppText.caption).
    final texts = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Huzur Modu / Gece Kontrolü',
          style: TextStyle(
            fontSize: AppText.body,
            fontWeight: FontWeight.bold,
            color: AppTheme.getTextPrimary(context),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '${vm.lights} lamba açık kaldı.',
          style: TextStyle(fontSize: AppText.caption, color: AppTheme.getTextMuted(context)),
        ),
      ],
    );
    const icon = OrbIconBadge(icon: Icons.nightlight_round, family: AppFamilies.amber, size: OrbSize.sm, active: true);

    // Amber "bloom": vurgulu cam kart (kenar + radyal parıltı; BoxShadow/blur yok).
    return SurfaceCard(
      key: const Key('banner_peace'),
      accent: accent,
      active: true,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Dar ekran / büyük yazı: düğme alta iner (yatay taşma olmaz) ve kartın tam genişliğini alır; böylece
          // kartın sol-alt köşesi boş kalmaz ve düğme kenarı kartın iç kenarlarıyla hizalıdır.
          final compact = constraints.maxWidth < 420 || MediaQuery.textScalerOf(context).scale(10) > 12;
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [icon, const SizedBox(width: 12), Expanded(child: texts)],
                ),
                const SizedBox(height: 12),
                const CloseAllLightsButton(),
              ],
            );
          }
          return Row(
            children: [
              icon,
              const SizedBox(width: 12),
              Expanded(child: texts),
              const SizedBox(width: 8),
              const CloseAllLightsButton(),
            ],
          );
        },
      ),
    );
  }
}
