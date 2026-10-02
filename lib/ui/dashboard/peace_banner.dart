import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/automation_state.dart';
import '../theme/app_theme.dart';
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

    final accent = Colors.indigoAccent;
    final texts = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Huzur Modu / Gece Kontrolü',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: AppTheme.getTextPrimary(context),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '${vm.lights} lamba açık kaldı.',
          style: TextStyle(fontSize: 11.5, color: AppTheme.getTextMuted(context)),
        ),
      ],
    );
    final icon = Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.15),
        shape: BoxShape.circle,
      ),
      child: Icon(Icons.nightlight_round, color: AppTheme.readableAccent(context, accent), size: 20),
    );

    return Container(
      key: const Key('banner_peace'),
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: AppTheme.cardDecoration(context, accent: accent, radius: 14),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Dar ekran / büyük yazı: düğme alta iner (yatay taşma olmaz).
          final compact = constraints.maxWidth < 420 || MediaQuery.textScalerOf(context).scale(10) > 12;
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [icon, const SizedBox(width: 12), Expanded(child: texts)],
                ),
                const SizedBox(height: 10),
                const Align(alignment: AlignmentDirectional.centerEnd, child: CloseAllLightsButton()),
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
