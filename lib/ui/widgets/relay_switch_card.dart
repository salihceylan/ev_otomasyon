import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/automation_models.dart';
import '../../services/automation_state.dart';
import '../theme/app_theme.dart';

class RelaySwitchCard extends StatelessWidget {
  final RelayItem relay;

  const RelaySwitchCard({super.key, required this.relay});

  @override
  Widget build(BuildContext context) {
    final state = context.read<AutomationState>();
    final isLight = relay.isLight;
    final isOn = relay.state;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isOn ? AppTheme.accentGreen.withValues(alpha: 0.5) : AppTheme.cardBorder,
          width: 1.2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isOn ? AppTheme.accentGreen : AppTheme.cardBorder,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${isLight ? "💡" : "⚡"} ${relay.name}',
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 6),
              if (relay.isExt)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppTheme.accentPurple.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '📦 CH ${relay.id - 8}',
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.accentPurple,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  isOn ? 'AÇIK' : 'KAPALI',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: isOn ? AppTheme.accentGreen : AppTheme.textMuted,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isLight)
                Transform.scale(
                  scale: 0.85,
                  child: Switch(
                    value: isOn,
                    activeThumbColor: AppTheme.accentGreen,
                    activeTrackColor: AppTheme.accentGreen.withValues(alpha: 0.3),
                    inactiveThumbColor: AppTheme.textMuted,
                    inactiveTrackColor: const Color(0xFF0F172A),
                    onChanged: (_) => state.toggleRelay(relay.id),
                  ),
                )
              else
                ElevatedButton(
                  onPressed: () => state.triggerImpulse(relay.id),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryBlue.withValues(alpha: 0.2),
                    foregroundColor: AppTheme.primaryBlueLight,
                    side: const BorderSide(color: AppTheme.primaryBlue, width: 1),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text(
                    '⚡ Tetikle',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
