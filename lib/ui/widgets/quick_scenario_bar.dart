import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/automation_state.dart';
import '../dashboard/command_retry.dart';
import '../theme/app_theme.dart';

/// Tek tıkla çalışan toplu komut senaryosu.
class QuickScenario {
  const QuickScenario({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.result,
    required this.icon,
    required this.color,
    required this.commands,
  });

  /// Anahtar: `Key('card_scenario_<id>')`.
  final String id;
  final String title;
  final String subtitle;

  /// Tüm komutlar iletildiğinde gösterilen kısa sonuç.
  final String result;
  final IconData icon;
  final Color color;

  /// Sırayla gönderilen toplu komutlar (`AutomationState.cmdAll` kanonik adları).
  final List<String> commands;
}

/// Hazır senaryolar (toplu komutlar; misafire kapalıdır — `canUseGroupCommands`).
const List<QuickScenario> kQuickScenarios = <QuickScenario>[
  QuickScenario(
    id: 'leaving',
    title: 'Evden Çıkıyorum',
    subtitle: 'Işıkları kapat, panjurları indir',
    result: 'Evden çıkış: ışıklar ve panjurlar için komut iletildi.',
    icon: Icons.exit_to_app,
    color: AppTheme.accentRed,
    commands: <String>['all_lights_off', 'all_shutters_down'],
  ),
  QuickScenario(
    id: 'morning',
    title: 'Günaydın',
    subtitle: 'Panjurları aç',
    result: 'Günaydın: panjurları açma komutu iletildi.',
    icon: Icons.wb_sunny_outlined,
    color: AppTheme.accentAmber,
    commands: <String>['all_shutters_up'],
  ),
  QuickScenario(
    id: 'night',
    title: 'İyi Geceler',
    subtitle: 'Işıkları söndür, panjurları kapat',
    result: 'İyi geceler: ışıklar ve panjurlar için komut iletildi.',
    icon: Icons.bedtime_outlined,
    color: AppTheme.accentPurple,
    commands: <String>['all_lights_off', 'all_shutters_down'],
  ),
  QuickScenario(
    id: 'lights_off',
    title: 'Tüm Lambalar',
    subtitle: 'Hepsini söndür',
    result: 'Tüm lambaları kapatma komutu iletildi.',
    icon: Icons.lightbulb_outline,
    color: AppTheme.primaryBlueLight,
    commands: <String>['all_lights_off'],
  ),
  QuickScenario(
    id: 'shutters_stop',
    title: 'Panjurları Durdur',
    subtitle: 'Anlık acil durdurma',
    result: 'Panjurları durdurma komutu iletildi.',
    icon: Icons.stop_circle_outlined,
    color: AppTheme.textMuted,
    commands: <String>['all_shutters_stop'],
  ),
];

/// Hızlı senaryo çubuğu.
///
/// Senaryo komutları sırayla `AutomationState.cmdAll` ile gönderilir; **ilk hatada durur** (kısmi
/// uygulama yerine açık bir hata). Hata mesajını ve "Tekrar dene"yi kabuktaki tek abone gösterir;
/// bu widget yalnızca **tüm komutlar iletildiğinde** kısa bir sonuç mesajı gösterir. Çalışırken
/// düğmeler pasiftir (çift dokunuş yok).
class QuickScenarioBar extends StatefulWidget {
  const QuickScenarioBar({super.key});

  @override
  State<QuickScenarioBar> createState() => _QuickScenarioBarState();
}

class _QuickScenarioBarState extends State<QuickScenarioBar> {
  String? _running;

  Future<void> _run(QuickScenario scenario) async {
    if (_running != null) return;
    final state = context.read<AutomationState>();
    if (!state.capabilities.canUseGroupCommands) return;
    HapticFeedback.mediumImpact();
    setState(() => _running = scenario.id);
    var allDelivered = true;
    try {
      for (final command in scenario.commands) {
        final ok = await runCommand(context, 'group:$command', () => state.cmdAll(command));
        if (!ok) {
          allDelivered = false;
          break;
        }
      }
    } finally {
      if (mounted) setState(() => _running = null);
    }
    if (!mounted || !allDelivered) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(scenario.result, style: const TextStyle(fontSize: 12.5)),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final canUse = context.select<AutomationState, bool>((s) => s.capabilities.canUseGroupCommands);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.bolt, size: 16, color: AppTheme.warningText(context)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Hızlı Senaryolar',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.getTextMuted(context),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < kQuickScenarios.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  _ScenarioCard(
                    scenario: kQuickScenarios[i],
                    enabled: canUse && _running == null,
                    running: _running == kQuickScenarios[i].id,
                    onTap: () => _run(kQuickScenarios[i]),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ScenarioCard extends StatelessWidget {
  const _ScenarioCard({
    required this.scenario,
    required this.enabled,
    required this.running,
    required this.onTap,
  });

  final QuickScenario scenario;
  final bool enabled;
  final bool running;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = scenario.color;
    final textColor = AppTheme.readableAccent(context, color);
    return Semantics(
      button: true,
      enabled: enabled,
      excludeSemantics: true,
      label: '${scenario.title}. ${scenario.subtitle}${running ? ', çalışıyor' : ''}',
      onTap: enabled ? onTap : null,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: Key('card_scenario_${scenario.id}'),
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            width: 156,
            constraints: const BoxConstraints(minHeight: 96),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: color.withValues(alpha: enabled || running ? 0.1 : 0.04),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: color.withValues(alpha: 0.4), width: 1.2),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                  child: running
                      ? Padding(
                          padding: const EdgeInsets.all(8),
                          child: CircularProgressIndicator(strokeWidth: 2, color: textColor),
                        )
                      : Icon(scenario.icon, size: 18, color: textColor),
                ),
                const SizedBox(height: 8),
                Text(
                  scenario.title,
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: textColor),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  scenario.subtitle,
                  style: TextStyle(fontSize: 10.5, color: AppTheme.getTextMuted(context)),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
