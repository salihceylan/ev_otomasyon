import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/automation_state.dart';
import '../theme/app_theme.dart';
import '../widgets/quick_scenario_bar.dart';
import '../widgets/shutter_card.dart';
import '../widgets/relay_switch_card.dart';
import '../widgets/di_status_pill.dart';
import 'device_settings_page.dart';

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AutomationState>();
    final status = state.status;
    final isConnected = state.isConnected;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: AppTheme.primaryBlue.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.home_outlined, size: 20, color: AppTheme.primaryBlueLight),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    status?.deviceName ?? 'AHBU Akıllı Ev',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    isConnected ? '🟢 Çevrimiçi (${state.host})' : '🔴 Bağlantı Bekleniyor...',
                    style: TextStyle(
                      fontSize: 11,
                      color: isConnected ? AppTheme.accentGreen : AppTheme.accentRed,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: AppTheme.textMuted),
            tooltip: 'Cihaz Ayarları',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DeviceSettingsPage()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: AppTheme.textMuted),
            tooltip: 'Yenile',
            onPressed: () => state.refresh(),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => state.refresh(),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Hızlı Senaryolar
              const QuickScenarioBar(),
              const SizedBox(height: 24),

              // Panjurlar Bölümü
              if (status != null && status.shutters.isNotEmpty) ...[
                _buildSectionHeader('🪟 Panjur Kontrolleri', '${status.shutters.length} Motor'),
                const SizedBox(height: 10),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isWide = constraints.maxWidth > 600;
                    final itemWidth = isWide ? (constraints.maxWidth - 12) / 2 : constraints.maxWidth;
                    return Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: status.shutters.map((s) {
                        return SizedBox(
                          width: itemWidth,
                          child: ShutterCard(shutter: s),
                        );
                      }).toList(),
                    );
                  },
                ),
                const SizedBox(height: 24),
              ],

              // Lambalar ve Bağımsız Röleler
              if (status != null && status.relays.where((r) => r.isLight || r.isImpulse).isNotEmpty) ...[
                _buildSectionHeader('💡 Aydınlatma & Çıkışlar', 'Lamba & Kilit'),
                const SizedBox(height: 10),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isWide = constraints.maxWidth > 600;
                    final itemWidth = isWide ? (constraints.maxWidth - 12) / 2 : constraints.maxWidth;
                    final singleRelays = status.relays.where((r) => r.isLight || r.isImpulse).toList();
                    return Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: singleRelays.map((r) {
                        return SizedBox(
                          width: itemWidth,
                          child: RelaySwitchCard(relay: r),
                        );
                      }).toList(),
                    );
                  },
                ),
                const SizedBox(height: 24),
              ],

              // Girişler (Duvar Butonları)
              if (status != null && status.dis.isNotEmpty) ...[
                _buildSectionHeader('🔘 Duvar Butonları & Girişler (DI)', 'Kuru Kontak Durumları'),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: status.dis.map((d) => DIStatusPill(di: d)).toList(),
                ),
                const SizedBox(height: 30),
              ],

              // Offline İkazı
              if (!isConnected)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppTheme.accentAmber.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppTheme.accentAmber.withValues(alpha: 0.35)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.wifi_off_outlined, color: AppTheme.accentAmber),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Cihaza Bağlanılamıyor',
                              style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.accentAmber),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Telefonunuzun ev Wi-Fi ağına bağlı olduğundan veya cihazın IP adresinin (${state.host}) doğru girildiğinden emin olun.',
                              style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, String badge) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppTheme.textPrimary,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: AppTheme.cardBorder.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            badge,
            style: const TextStyle(fontSize: 11, color: AppTheme.textMuted, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
