import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/automation_state.dart';
import '../theme/app_theme.dart';

class QuickScenarioBar extends StatelessWidget {
  const QuickScenarioBar({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AutomationState>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '⚡ Hızlı Senaryolar & Genel Komutlar',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: AppTheme.textMuted,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _buildBtn(
              context: context,
              icon: Icons.lightbulb_outline,
              label: 'Tüm Lambaları Kapat',
              color: AppTheme.accentAmber,
              onTap: () => state.cmdAll('lightsoff'),
            ),
            _buildBtn(
              context: context,
              icon: Icons.keyboard_double_arrow_down,
              label: 'Tüm Panjurları İndir',
              color: AppTheme.primaryBlue,
              onTap: () => state.cmdAll('shuttersdown'),
            ),
            _buildBtn(
              context: context,
              icon: Icons.keyboard_double_arrow_up,
              label: 'Tüm Panjurları Aç',
              color: AppTheme.accentGreen,
              onTap: () => state.cmdAll('shuttersup'),
            ),
            _buildBtn(
              context: context,
              icon: Icons.stop_circle_outlined,
              label: 'Panjurları Durdur',
              color: AppTheme.accentRed,
              onTap: () => state.cmdAll('shuttersstop'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildBtn({
    required BuildContext context,
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: color.withValues(alpha: 0.35),
              width: 1.2,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
