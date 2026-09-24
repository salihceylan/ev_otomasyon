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
        const Row(
          children: [
            Icon(Icons.bolt, size: 16, color: AppTheme.accentAmber),
            SizedBox(width: 6),
            Text(
              'Hızlı Senaryolar & Akıllı Rutinler',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: AppTheme.textMuted,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: Row(
            children: [
              _buildScenarioCard(
                icon: Icons.exit_to_app,
                title: 'Evden Çıkıyorum',
                subtitle: 'Işıkları kapat, panjurları indir',
                color: AppTheme.accentRed,
                onTap: () {
                  state.cmdAll('lightsoff');
                  state.cmdAll('shuttersdown');
                  _showSnack(context, '🏠 Evden çıkış senaryosu devrede: Tüm ışıklar ve panjurlar kapatılıyor');
                },
              ),
              const SizedBox(width: 8),
              _buildScenarioCard(
                icon: Icons.wb_sunny_outlined,
                title: 'Günaydın',
                subtitle: 'Panjurları aç',
                color: AppTheme.accentAmber,
                onTap: () {
                  state.cmdAll('shuttersup');
                  _showSnack(context, '🌅 Günaydın senaryosu devrede: Panjurlar açılıyor');
                },
              ),
              const SizedBox(width: 8),
              _buildScenarioCard(
                icon: Icons.bedtime_outlined,
                title: 'İyi Geceler',
                subtitle: 'Işıkları söndür, panjuru kapat',
                color: AppTheme.accentPurple,
                onTap: () {
                  state.cmdAll('lightsoff');
                  state.cmdAll('shuttersdown');
                  _showSnack(context, '🌙 İyi geceler senaryosu devrede');
                },
              ),
              const SizedBox(width: 8),
              _buildScenarioCard(
                icon: Icons.lightbulb_outline,
                title: 'Tüm Lambalar',
                subtitle: 'Hepsini söndür',
                color: AppTheme.primaryBlueLight,
                onTap: () {
                  state.cmdAll('lightsoff');
                  _showSnack(context, '💡 Tüm lambalar kapatıldı');
                },
              ),
              const SizedBox(width: 8),
              _buildScenarioCard(
                icon: Icons.stop_circle_outlined,
                title: 'Panjurları Durdur',
                subtitle: 'Anlık acil durdurma',
                color: AppTheme.textMuted,
                onTap: () {
                  state.cmdAll('shuttersstop');
                  _showSnack(context, '⏹ Tüm panjurlar durduruldu');
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildScenarioCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: 148,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: color.withValues(alpha: 0.35),
              width: 1.2,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 18, color: color),
              ),
              const SizedBox(height: 8),
              Text(
                title,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 10,
                  color: AppTheme.textMuted,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSnack(BuildContext context, String message) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontSize: 12.5)),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
