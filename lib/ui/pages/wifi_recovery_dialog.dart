import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/automation_state.dart';
import '../theme/app_theme.dart';

class WifiRecoveryDialog extends StatefulWidget {
  const WifiRecoveryDialog({super.key});

  static Future<void> show(BuildContext context) {
    final state = context.read<AutomationState>();
    return showDialog(
      context: context,
      builder: (ctx) => ChangeNotifierProvider<AutomationState>.value(
        value: state,
        child: const WifiRecoveryDialog(),
      ),
    );
  }

  @override
  State<WifiRecoveryDialog> createState() => _WifiRecoveryDialogState();
}

class _WifiRecoveryDialogState extends State<WifiRecoveryDialog> {
  final _ssidController = TextEditingController();
  final _passController = TextEditingController();

  bool _isObscure = true;
  bool _isCheckingConnection = false;
  bool _isConnectedToPanel = false;
  bool _isScanning = false;
  bool _isSubmitting = false;
  bool _isSuccess = false;

  String? _errorMessage;
  List<Map<String, dynamic>> _scannedNetworks = [];

  @override
  void dispose() {
    _ssidController.dispose();
    _passController.dispose();
    super.dispose();
  }

  Future<void> _checkPanelConnection() async {
    final state = context.read<AutomationState>();
    setState(() {
      _isCheckingConnection = true;
      _errorMessage = null;
    });

    try {
      final status = await state.api.fetchStatus();
      if (mounted) {
        setState(() {
          _isConnectedToPanel = true;
          _isCheckingConnection = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Pano ile bağlantı kuruldu (${status.deviceName})!'),
            backgroundColor: AppTheme.accentGreen,
          ),
        );
        _scanWifi();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isConnectedToPanel = false;
          _isCheckingConnection = false;
          _errorMessage =
              'Pano bulunamadı. Lütfen telefonunuzun Wi-Fi ayarlarına girip "AHBU-Kurtarma-..." ağına bağlı olduğunuzdan emin olun (Şifre: ahbu1234).';
        });
      }
    }
  }

  Future<void> _scanWifi() async {
    final state = context.read<AutomationState>();
    setState(() {
      _isScanning = true;
      _errorMessage = null;
    });

    try {
      final networks = await state.scanRecoveryWifiNetworks();
      if (mounted) {
        setState(() {
          _scannedNetworks = networks;
          _isScanning = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isScanning = false);
      }
    }
  }

  Future<void> _sendNewCredentials() async {
    final ssid = _ssidController.text.trim();
    final pass = _passController.text.trim();

    if (ssid.isEmpty) {
      setState(() => _errorMessage = 'Lütfen yeni Wi-Fi ağ adını (SSID) girin.');
      return;
    }

    final state = context.read<AutomationState>();
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      await state.sendRecoveryWifiCredentials(ssid, pass);
      if (mounted) {
        setState(() {
          _isSubmitting = false;
          _isSuccess = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
          _errorMessage = 'Şifre gönderilemedi: ${e.toString().replaceAll('Exception: ', '')}';
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
        constraints: const BoxConstraints(maxWidth: 440),
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
                    child: const Icon(Icons.wifi_find, color: AppTheme.primaryBlueLight, size: 22),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Wi-Fi Kurtarma Modu',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          'Smart AP Fallback / Şifre Yenileme',
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

              if (_isSuccess) ...[
                _buildSuccessView(),
              ] else ...[
                _buildInstructionsStep(),
                const SizedBox(height: 16),
                _buildCredentialsForm(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInstructionsStep() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _isConnectedToPanel
              ? AppTheme.accentGreen.withValues(alpha: 0.5)
              : AppTheme.primaryBlue.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _isConnectedToPanel ? Icons.check_circle : Icons.info_outline,
                color: _isConnectedToPanel ? AppTheme.accentGreen : AppTheme.primaryBlueLight,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _isConnectedToPanel
                      ? 'Pano ile Bağlantı Kuruldu (192.168.4.1)'
                      : 'Adım 1: Panonun Kurtarma Ağına Bağlanın',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: _isConnectedToPanel ? AppTheme.accentGreen : AppTheme.primaryBlueLight,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Modeminiz veya şifreniz değiştiğinde panonuz 3 dakika sonra otomatik olarak acil kurtarma ağı açar.\n\n'
            '1. Telefonunuzun Wi-Fi ayarlarına gidin.\n'
            '2. "AHBU-Kurtarma-..." ağına bağlanın (Şifre: ahbu1234).\n'
            '3. Bağlandıktan sonra aşağıdaki butona tıklayın.',
            style: TextStyle(fontSize: 12, color: AppTheme.textMuted, height: 1.35),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _isCheckingConnection ? null : _checkPanelConnection,
              icon: _isCheckingConnection
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh, size: 16),
              label: Text(_isConnectedToPanel ? 'Bağlantıyı Yeniden Kontrol Et' : 'Pano Bağlantısını Test Et'),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: _isConnectedToPanel ? AppTheme.accentGreen : AppTheme.primaryBlueLight),
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCredentialsForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Flexible(
              child: Text(
                'Adım 2: Yeni Ev Wi-Fi Bilgileri',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (_isConnectedToPanel)
              TextButton.icon(
                onPressed: _isScanning ? null : _scanWifi,
                icon: _isScanning
                    ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.wifi_tethering, size: 16),
                label: const Text('Ağları Tara', style: TextStyle(fontSize: 12)),
              ),
          ],
        ),
        const SizedBox(height: 10),

        if (_scannedNetworks.isNotEmpty) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: AppTheme.cardDark,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.cardBorder),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                hint: const Text('Çevredeki bir Wi-Fi ağını seçin', style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                isExpanded: true,
                dropdownColor: AppTheme.cardDark,
                items: _scannedNetworks.map((net) {
                  final ssid = (net['ssid'] ?? '').toString();
                  final rssi = net['rssi']?.toString() ?? '';
                  return DropdownMenuItem<String>(
                    value: ssid,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(
                          child: Text(
                            ssid,
                            style: const TextStyle(fontSize: 13),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text('$rssi dBm', style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
                      ],
                    ),
                  );
                }).toList(),
                onChanged: (val) {
                  if (val != null) {
                    setState(() => _ssidController.text = val);
                  }
                },
              ),
            ),
          ),
          const SizedBox(height: 10),
        ],

        // SSID
        TextField(
          controller: _ssidController,
          decoration: InputDecoration(
            labelText: 'Yeni Wi-Fi Ağ Adı (SSID)',
            hintText: 'Ev Wi-Fi ağınızın adı',
            labelStyle: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
            hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
            prefixIcon: const Icon(Icons.wifi, size: 20),
            filled: true,
            fillColor: AppTheme.cardDark,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        const SizedBox(height: 12),

        // Şifre
        TextField(
          controller: _passController,
          obscureText: _isObscure,
          decoration: InputDecoration(
            labelText: 'Yeni Wi-Fi Şifresi',
            hintText: 'Wi-Fi şifrenizi girin',
            labelStyle: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
            hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
            prefixIcon: const Icon(Icons.lock_outline, size: 20),
            suffixIcon: IconButton(
              icon: Icon(_isObscure ? Icons.visibility_off : Icons.visibility, size: 18),
              onPressed: () => setState(() => _isObscure = !_isObscure),
            ),
            filled: true,
            fillColor: AppTheme.cardDark,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        const SizedBox(height: 14),

        if (_errorMessage != null) ...[
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.accentRed.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.accentRed.withValues(alpha: 0.3)),
            ),
            child: Text(
              _errorMessage!,
              style: const TextStyle(color: AppTheme.accentRed, fontSize: 12),
            ),
          ),
          const SizedBox(height: 12),
        ],

        ElevatedButton.icon(
          onPressed: _isSubmitting ? null : _sendNewCredentials,
          icon: _isSubmitting
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.send_rounded, size: 18),
          label: const Text('Yeni Wi-Fi Şifresini Panoya Yükle'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primaryBlue,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            textStyle: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  Widget _buildSuccessView() {
    return Column(
      children: [
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.accentGreen.withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.check_circle_outline, color: AppTheme.accentGreen, size: 48),
        ),
        const SizedBox(height: 16),
        const Text(
          'Wi-Fi Bilgileri Başarıyla Aktarıldı!',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.accentGreen),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 10),
        const Text(
          'Pano yeni Wi-Fi şifrenizi kaydetti ve ev ağınıza bağlanıyor. Kurtarma modu otomatik olarak sonlandırılacaktır.\n\n'
          '👉 Şimdi telefonunuzu tekrar ev Wi-Fi ağınıza veya mobil veriye bağlayabilirsiniz.',
          style: TextStyle(fontSize: 12.5, color: AppTheme.textMuted, height: 1.4),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accentGreen,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Tamam'),
          ),
        ),
      ],
    );
  }
}

