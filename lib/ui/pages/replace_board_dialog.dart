import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/automation_state.dart';
import '../theme/app_theme.dart';

class ReplaceBoardDialog extends StatefulWidget {
  const ReplaceBoardDialog({super.key});

  static Future<void> show(BuildContext context) {
    final state = context.read<AutomationState>();
    return showDialog(
      context: context,
      builder: (ctx) => ChangeNotifierProvider<AutomationState>.value(
        value: state,
        child: const ReplaceBoardDialog(),
      ),
    );
  }

  @override
  State<ReplaceBoardDialog> createState() => _ReplaceBoardDialogState();
}

class _ReplaceBoardDialogState extends State<ReplaceBoardDialog> {
  final _uuidController = TextEditingController();
  final _pinController = TextEditingController();
  final _reasonController = TextEditingController(text: 'Yıldırım / Donanım arızası, yeni pano montajı');

  bool _isSubmitting = false;
  bool _isSuccess = false;
  String? _errorMessage;
  Map<String, dynamic>? _resultData;

  @override
  void dispose() {
    _uuidController.dispose();
    _pinController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _submitReplace() async {
    final newUuid = _uuidController.text.trim();
    final pin = _pinController.text.trim();
    final reason = _reasonController.text.trim();

    if (newUuid.isEmpty) {
      setState(() => _errorMessage = 'Lütfen yeni panonun UUID kodunu girin.');
      return;
    }
    if (pin.isEmpty || pin.length < 6) {
      setState(() => _errorMessage = 'Lütfen 6 haneli fabrika kurulum PIN kodunu girin.');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      final state = context.read<AutomationState>();
      final result = await state.replaceBoard(
        newDeviceUuid: newUuid,
        setupPin: pin,
        reason: reason.isNotEmpty ? reason : null,
      );

      if (mounted) {
        setState(() {
          _isSubmitting = false;
          _isSuccess = true;
          _resultData = result;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
          _errorMessage = e.toString().replaceAll('Exception: ', '');
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
                      color: AppTheme.accentPurple.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.sync_alt_rounded, color: AppTheme.accentPurple, size: 22),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Pano Değişimi & Kurtarma',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          'Disaster Recovery (5 Saniyede Aktarım)',
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
                _buildFormView(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFormView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.primaryBlue.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.primaryBlue.withValues(alpha: 0.25)),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.bolt, color: Colors.amber, size: 20),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Yıldırım, aşırı gerilim veya arıza sebebiyle değiştirilen panonun yerine takılan yeni boş karta tüm oda isimleri, klemensler ve panjur süreleri sıfır zahmetle 5 saniyede yüklenir.',
                  style: TextStyle(fontSize: 12, color: AppTheme.textMuted, height: 1.35),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Yeni UUID
        TextField(
          controller: _uuidController,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(
            labelText: 'Yeni Pano Seri No (UUID)',
            hintText: 'Örn: AHBU-S3-A1B2C3D4',
            labelStyle: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
            hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
            prefixIcon: const Icon(Icons.qr_code, size: 20),
            filled: true,
            fillColor: AppTheme.cardDark,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        const SizedBox(height: 12),

        // Kurulum PIN
        TextField(
          controller: _pinController,
          keyboardType: TextInputType.number,
          maxLength: 6,
          decoration: InputDecoration(
            labelText: 'Yeni Panonun 6 Haneli Kurulum PIN\'i',
            hintText: 'Örn: 123456',
            counterText: '',
            labelStyle: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
            hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
            prefixIcon: const Icon(Icons.lock_outline, size: 20),
            filled: true,
            fillColor: AppTheme.cardDark,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        const SizedBox(height: 12),

        // Gerekçe
        TextField(
          controller: _reasonController,
          decoration: InputDecoration(
            labelText: 'Değişim Nedeni (Opsiyonel)',
            hintText: 'Arıza / hasar açıklaması',
            labelStyle: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
            hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
            prefixIcon: const Icon(Icons.note_alt_outlined, size: 20),
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
          onPressed: _isSubmitting ? null : _submitReplace,
          icon: _isSubmitting
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.cloud_download_outlined, size: 18),
          label: const Text('Eski Pano Ayarlarını Yeni Karta Aktar'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.accentPurple,
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
    final count = _resultData?['migratedEndpointsCount'] ?? 0;
    final newUuid = _resultData?['newDeviceUuid'] ?? '';

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
        const SizedBox(height: 14),
        const Text(
          'Pano Değişimi Başarılı!',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.accentGreen),
        ),
        const SizedBox(height: 8),
        Text(
          'Eski panonun tüm konfigürasyonu ve $count adet kontrol noktası (lamba, panjur, priz) yeni panoya ($newUuid) aktarıldı.',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12.5, color: AppTheme.textMuted, height: 1.35),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accentGreen,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Tamamla ve Kapat', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
      ],
    );
  }
}

