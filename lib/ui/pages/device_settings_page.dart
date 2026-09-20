import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/automation_state.dart';
import '../theme/app_theme.dart';

class DeviceSettingsPage extends StatefulWidget {
  const DeviceSettingsPage({super.key});

  @override
  State<DeviceSettingsPage> createState() => _DeviceSettingsPageState();
}

class _DeviceSettingsPageState extends State<DeviceSettingsPage> {
  late TextEditingController _hostCtrl;

  @override
  void initState() {
    super.initState();
    final currentHost = context.read<AutomationState>().host;
    _hostCtrl = TextEditingController(text: currentHost);
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AutomationState>();
    final status = state.status;

    return Scaffold(
      appBar: AppBar(
        title: const Text('⚙️ Cihaz Bağlantı Ayarları'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.cardDark,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.cardBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'ESP32-S3 Cihaz IP Adresi',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Cihazın ev modeminizden aldığı yerel IP adresini veya AP modundaki IP\'sini girin.',
                    style: TextStyle(fontSize: 12.5, color: AppTheme.textMuted),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _hostCtrl,
                    decoration: InputDecoration(
                      hintText: 'Örn: 192.168.1.197 veya 192.168.4.1',
                      prefixIcon: const Icon(Icons.lan_outlined, color: AppTheme.primaryBlue),
                      filled: true,
                      fillColor: const Color(0xFF0F172A),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: AppTheme.cardBorder),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: AppTheme.cardBorder),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: AppTheme.primaryBlue, width: 1.5),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _buildQuickIpChip('192.168.4.1 (AP Varsayılan)'),
                      _buildQuickIpChip('192.168.1.197 (Ev Ağı)'),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        final val = _hostCtrl.text.trim();
                        if (val.isNotEmpty) {
                          await state.setHost(val);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('IP $val olarak güncellendi!'),
                                backgroundColor: AppTheme.accentGreen,
                              ),
                            );
                          }
                        }
                      },
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text('Kaydet ve Bağlan', style: TextStyle(fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryBlue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            if (status != null) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.cardDark,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppTheme.cardBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('ℹ️ Cihaz Telemetrisi', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14.5)),
                    const SizedBox(height: 10),
                    _buildInfoRow('Cihaz Adı:', status.deviceName),
                    _buildInfoRow('Cihaz AP IP:', status.ip),
                    _buildInfoRow('Ev Wi-Fi (STA):', status.wifiConnected ? '${status.wifiStaSsid} (${status.wifiStaIp})' : 'Bağlı Değil'),
                    _buildInfoRow('Sinyal Gücü:', '${status.wifiStaRssi} dBm'),
                    _buildInfoRow('Kesintisiz Çalışma (Uptime):', '${status.uptimeSec ~/ 3600}s ${(status.uptimeSec % 3600) ~/ 60}d'),
                    _buildInfoRow('Toplam Röle / DI:', '${status.relays.length} Röle / ${status.dis.length} Giriş'),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildQuickIpChip(String ipLabel) {
    final ip = ipLabel.split(' ')[0];
    return ActionChip(
      label: Text(ipLabel, style: const TextStyle(fontSize: 11)),
      backgroundColor: const Color(0xFF0F172A),
      side: const BorderSide(color: AppTheme.cardBorder),
      onPressed: () {
        _hostCtrl.text = ip;
      },
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 12.5, color: AppTheme.textMuted)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              value,
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppTheme.textPrimary),
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}
