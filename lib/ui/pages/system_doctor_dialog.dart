import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/automation_state.dart';
import '../theme/app_theme.dart';
import 'wifi_recovery_dialog.dart';

class SystemDoctorDialog extends StatefulWidget {
  final Map<String, dynamic>? initialData;

  const SystemDoctorDialog({super.key, this.initialData});

  static Future<void> show(BuildContext context, {Map<String, dynamic>? initialData}) {
    final state = context.read<AutomationState>();
    return showDialog(
      context: context,
      builder: (ctx) => ChangeNotifierProvider<AutomationState>.value(
        value: state,
        child: SystemDoctorDialog(initialData: initialData),
      ),
    );
  }

  @override
  State<SystemDoctorDialog> createState() => _SystemDoctorDialogState();
}

class _SystemDoctorDialogState extends State<SystemDoctorDialog> {
  bool _isLoading = true;
  String? _errorMessage;
  Map<String, dynamic>? _diagnosticData;

  @override
  void initState() {
    super.initState();
    if (widget.initialData != null) {
      _diagnosticData = widget.initialData;
      _isLoading = false;
    } else {
      _runDiagnostic();
    }
  }

  Future<void> _runDiagnostic() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final state = context.read<AutomationState>();
      final data = await state.fetchSystemDiagnostic();
      if (mounted) {
        setState(() {
          _diagnosticData = data;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().replaceAll('Exception: ', '');
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.surfaceDark,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: AppTheme.cardBorder),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Başlık
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryBlue.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.health_and_safety_outlined, color: AppTheme.primaryBlueLight, size: 22),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Sistem Doktoru',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          'Self-Diagnostic & Otomatik Teşhis',
                          style: TextStyle(fontSize: 11.5, color: AppTheme.textMuted),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: AppTheme.textMuted, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const Divider(height: 24, color: AppTheme.cardBorder),

              if (_isLoading) ...[
                const SizedBox(height: 30),
                const Center(
                  child: Column(
                    children: [
                      CircularProgressIndicator(color: AppTheme.primaryBlue),
                      SizedBox(height: 16),
                      Text(
                        'Sistem katmanları teşhis ediliyor...\n(Bulut, İnternet, Pano Gücü)',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, color: AppTheme.textMuted, height: 1.3),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 30),
              ] else if (_errorMessage != null) ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppTheme.accentRed.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.accentRed.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: AppTheme.accentRed, size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: const TextStyle(fontSize: 12.5, color: AppTheme.accentRed),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: _runDiagnostic,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Tekrar Dene'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryBlue,
                    foregroundColor: Colors.white,
                  ),
                ),
              ] else if (_diagnosticData != null) ...[
                _buildDiagnosticContent(_diagnosticData!),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDiagnosticContent(Map<String, dynamic> data) {
    final cloud = (data['cloud'] as Map<String, dynamic>?) ?? {};
    final network = (data['home_network'] as Map<String, dynamic>?) ?? {};
    final hardware = (data['hardware_power'] as Map<String, dynamic>?) ?? {};

    final cloudStatus = cloud['status']?.toString() ?? 'OK';
    final netStatus = network['status']?.toString() ?? 'UNKNOWN';
    final powerStatus = hardware['status']?.toString() ?? 'UNKNOWN';

    final diagLevel = data['diagnosis_level']?.toString() ?? 'ok';
    final diagTitle = data['diagnosis_title']?.toString() ?? 'Teşhis Raporu';
    final diagSummary = data['diagnosis_summary']?.toString() ?? '';
    final actionRecommendation = data['action_recommendation']?.toString();

    Color summaryColor = AppTheme.accentGreen;
    IconData summaryIcon = Icons.check_circle_outline;
    if (diagLevel == 'warning') {
      summaryColor = Colors.amber;
      summaryIcon = Icons.warning_amber_rounded;
    } else if (diagLevel == 'error') {
      summaryColor = AppTheme.accentRed;
      summaryIcon = Icons.error_outline;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 3 Katmanlı Kartlar
        _buildTierRow(
          icon: Icons.cloud_done_outlined,
          title: '1. Bulut Sunucu & MQTTS',
          subtitle: cloudStatus == 'OK' ? 'Aktif (Gecikme: ${cloud['latency_ms'] ?? 20} ms)' : 'Bulutta kesinti var',
          isOk: cloudStatus == 'OK',
          badgeText: cloudStatus == 'OK' ? 'OK' : 'HATA',
        ),
        const SizedBox(height: 10),

        _buildTierRow(
          icon: Icons.wifi_outlined,
          title: '2. Ev Modemi & İnternet',
          subtitle: netStatus == 'OK'
              ? 'Çevrimiçi (${network['device_ip'] ?? 'Bağlı'})'
              : (netStatus == 'WARNING' ? 'Sinyal Gecikmeli' : 'İnternet / Modem Kesik'),
          isOk: netStatus == 'OK',
          isWarning: netStatus == 'WARNING',
          badgeText: netStatus == 'OK' ? 'OK' : (netStatus == 'WARNING' ? 'UYARI' : 'HATA'),
        ),
        const SizedBox(height: 10),

        _buildTierRow(
          icon: Icons.electric_bolt_outlined,
          title: '3. Pano Gücü & Donanım',
          subtitle: powerStatus == 'OK' ? 'Besleme Normal (Online)' : 'Pano Gücü / Sigorta Kesik',
          isOk: powerStatus == 'OK',
          badgeText: powerStatus == 'OK' ? 'OK' : 'KESİK',
        ),
        const SizedBox(height: 16),

        // Teşhis Özeti Kartı
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: summaryColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: summaryColor.withValues(alpha: 0.35)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(summaryIcon, color: summaryColor, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      diagTitle,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13.5,
                        color: summaryColor,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                diagSummary,
                style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary, height: 1.35),
              ),
              if (actionRecommendation != null && actionRecommendation.isNotEmpty) ...[
                const SizedBox(height: 10),
                const Text(
                  'Çözüm Önerileri:',
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: AppTheme.textMuted),
                ),
                const SizedBox(height: 4),
                Text(
                  actionRecommendation,
                  style: const TextStyle(fontSize: 11.5, color: AppTheme.textMuted, height: 1.35),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Aksiyon Butonları
        if (netStatus == 'OFFLINE') ...[
          OutlinedButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              WifiRecoveryDialog.show(context);
            },
            icon: const Icon(Icons.wifi_find_rounded, color: Colors.amber, size: 18),
            label: const Text(
              'Modem/Şifre Değiştiyse: Kurtarma Modu',
              style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 12),
            ),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.amber),
              padding: const EdgeInsets.symmetric(vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
          const SizedBox(height: 8),
        ],

        ElevatedButton.icon(
          onPressed: _runDiagnostic,
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text('Testi Yeniden Çalıştır'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primaryBlue,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 10),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ],
    );
  }

  Widget _buildTierRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool isOk,
    bool isWarning = false,
    required String badgeText,
  }) {
    Color badgeColor = AppTheme.accentGreen;
    if (isWarning) {
      badgeColor = Colors.amber;
    } else if (!isOk) {
      badgeColor = AppTheme.accentRed;
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Row(
        children: [
          Icon(icon, color: badgeColor, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: badgeColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: badgeColor.withValues(alpha: 0.4)),
            ),
            child: Text(
              badgeText,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: badgeColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

