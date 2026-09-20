import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/automation_models.dart';
import '../../services/automation_state.dart';
import '../theme/app_theme.dart';

class ShutterCard extends StatelessWidget {
  final ShutterItem shutter;

  const ShutterCard({super.key, required this.shutter});

  @override
  Widget build(BuildContext context) {
    final state = context.read<AutomationState>();

    String statusText = 'Durdu';
    Color statusColor = AppTheme.textMuted;
    if (shutter.isMoving) {
      if (shutter.direction == 1) {
        statusText = 'Açılıyor...';
        statusColor = AppTheme.accentGreen;
      } else if (shutter.direction == 2) {
        statusText = 'Kapanıyor...';
        statusColor = AppTheme.accentAmber;
      }
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: shutter.isMoving ? statusColor.withValues(alpha: 0.5) : AppTheme.cardBorder,
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
                  color: shutter.isMoving ? statusColor : AppTheme.cardBorder,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '🪟 ${shutter.name}',
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
              if (shutter.isExt)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppTheme.accentPurple.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    '📦 Ek Modül',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.accentPurple,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Durum: $statusText',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: statusColor,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildActionBtn(
                  label: '▲ AÇ',
                  isActive: shutter.direction == 1 && shutter.isMoving,
                  color: AppTheme.accentGreen,
                  onTap: () => state.cmdShutter(shutter.pairIndex, 'up'),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _buildActionBtn(
                  label: '⏹ DURDUR',
                  isActive: false,
                  color: AppTheme.textMuted,
                  onTap: () => state.cmdShutter(shutter.pairIndex, 'stop'),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _buildActionBtn(
                  label: '▼ KAPAT',
                  isActive: shutter.direction == 2 && shutter.isMoving,
                  color: AppTheme.primaryBlueLight,
                  onTap: () => state.cmdShutter(shutter.pairIndex, 'down'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActionBtn({
    required String label,
    required bool isActive,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: isActive ? color.withValues(alpha: 0.3) : const Color(0xFF0F172A),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isActive ? color : AppTheme.cardBorder,
              width: 1,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: isActive ? color : AppTheme.textPrimary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}
