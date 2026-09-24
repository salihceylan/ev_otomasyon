import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/automation_models.dart';
import '../../services/automation_state.dart';
import '../theme/app_theme.dart';

class ShutterCard extends StatefulWidget {
  final ShutterItem shutter;

  const ShutterCard({super.key, required this.shutter});

  @override
  State<ShutterCard> createState() => _ShutterCardState();
}

class _ShutterCardState extends State<ShutterCard> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AutomationState>();
    final shutter = widget.shutter;
    final currentPos = state.getShutterPosition(shutter.pairIndex);
    final sliderVal = (_dragValue ?? currentPos.toDouble()).clamp(0.0, 100.0);

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
          // Başlık ve Rozetler
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
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppTheme.primaryBlue.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '%${sliderVal.round()}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.primaryBlueLight,
                  ),
                ),
              ),
              if (shutter.isExt) ...[
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppTheme.accentPurple.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    'RS485',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.accentPurple,
                    ),
                  ),
                ),
              ],
            ],
          ),

          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Durum: $statusText',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: statusColor,
                ),
              ),
              const Flexible(
                child: Text(
                  '0%: Kapalı • 100%: Tam Açık (Limit Korumalı)',
                  style: TextStyle(fontSize: 10, color: AppTheme.textMuted),
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // Yüzde Kaydırıcı (Slider)
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 6,
              activeTrackColor: AppTheme.primaryBlue,
              inactiveTrackColor: AppTheme.cardBorder,
              thumbColor: AppTheme.primaryBlueLight,
              overlayColor: AppTheme.primaryBlue.withValues(alpha: 0.2),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
            ),
            child: Slider(
              value: sliderVal,
              min: 0,
              max: 100,
              onChanged: (val) {
                setState(() {
                  _dragValue = val;
                });
              },
              onChangeEnd: (val) {
                setState(() {
                  _dragValue = null;
                });
                state.cmdShutter(shutter.pairIndex, 'pos', percent: val.round());
              },
            ),
          ),

          const SizedBox(height: 8),

          // Hızlı Butonlar: Aç, Durdur, Kapat
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
