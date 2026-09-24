import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../../services/automation_state.dart';
import '../../theme/app_theme.dart';

class TransferOwnershipDialog extends StatefulWidget {
  const TransferOwnershipDialog({super.key});

  static Future<void> show(BuildContext context) {
    final state = context.read<AutomationState>();
    return showDialog(
      context: context,
      builder: (ctx) => ChangeNotifierProvider<AutomationState>.value(
        value: state,
        child: const TransferOwnershipDialog(),
      ),
    );
  }

  @override
  State<TransferOwnershipDialog> createState() => _TransferOwnershipDialogState();
}

class _TransferOwnershipDialogState extends State<TransferOwnershipDialog> {
  final _targetController = TextEditingController();
  bool _isLoading = true;
  bool _isActionLoading = false;
  String? _errorMessage;
  Map<String, dynamic>? _pendingTransfer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadTransferStatus();
    });
  }

  @override
  void dispose() {
    _targetController.dispose();
    super.dispose();
  }

  Future<void> _loadTransferStatus() async {
    final state = context.read<AutomationState>();
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final transfer = await state.getHomeTransferStatus();
      if (mounted) {
        setState(() {
          _pendingTransfer = transfer;
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

  Future<void> _initiateTransfer() async {
    final state = context.read<AutomationState>();
    setState(() {
      _isActionLoading = true;
      _errorMessage = null;
    });

    try {
      final target = _targetController.text.trim();
      final res = await state.initiateHomeTransfer(
        targetIdentifier: target.isNotEmpty ? target : null,
      );

      if (mounted) {
        setState(() {
          _pendingTransfer = res;
          _isActionLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().replaceAll('Exception: ', '');
          _isActionLoading = false;
        });
      }
    }
  }

  Future<void> _cancelTransfer() async {
    final state = context.read<AutomationState>();
    setState(() {
      _isActionLoading = true;
      _errorMessage = null;
    });

    try {
      await state.cancelHomeTransfer();
      if (mounted) {
        setState(() {
          _pendingTransfer = null;
          _isActionLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Daire devir işlemi başarıyla iptal edildi.'),
            backgroundColor: AppTheme.accentGreen,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().replaceAll('Exception: ', '');
          _isActionLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AutomationState>();
    final homeName = state.activeHome?.name ?? 'Evim';

    return Dialog(
      backgroundColor: AppTheme.surfaceDark,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: AppTheme.cardBorder),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
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
                      color: AppTheme.accentAmber.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.transfer_within_a_station, color: AppTheme.accentAmber, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Daire Devri (Mülkiyet Transferi)',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          homeName,
                          style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
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
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ] else if (_errorMessage != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.accentRed.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppTheme.accentRed.withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    _errorMessage!,
                    style: const TextStyle(color: AppTheme.accentRed, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: _loadTransferStatus,
                  child: const Text('Tekrar Dene'),
                ),
              ] else if (_pendingTransfer != null) ...[
                _buildActiveTransferView(_pendingTransfer!),
              ] else ...[
                _buildNewTransferForm(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActiveTransferView(Map<String, dynamic> transfer) {
    final transferCode = transfer['transfer_code'] ?? transfer['transferCode'] ?? '';
    final target = transfer['target_identifier'] ?? transfer['targetIdentifier'];
    final qrPayload = transfer['qrPayload'] ?? 'AHBU-TRANSFER:$transferCode';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.accentAmber.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.accentAmber.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              const Icon(Icons.info_outline, color: AppTheme.accentAmber, size: 20),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Aktif devir kodu üretildi. Yeni malik bu kodu veya QR\'ı okuttuğunda eski ailenin tüm yetkileri silinecektir.',
                  style: TextStyle(fontSize: 12, color: AppTheme.accentAmber),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // QR Kodu
        Center(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.accentAmber.withValues(alpha: 0.2),
                  blurRadius: 16,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: QrImageView(
              data: qrPayload,
              version: QrVersions.auto,
              size: 160.0,
              backgroundColor: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 14),

        // 6 Haneli Kod ve Kopyala
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: AppTheme.cardDark,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.cardBorder),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('DEVİR KODU (48 Saat Geçerli)', style: TextStyle(fontSize: 10, color: AppTheme.textMuted)),
                    const SizedBox(height: 2),
                    Text(
                      transferCode,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: 1.5, color: AppTheme.accentAmber),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 20, color: AppTheme.primaryBlueLight),
                tooltip: 'Kodu Kopyala',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: transferCode));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Devir kodu panoya kopyalandı!')),
                  );
                },
              ),
            ],
          ),
        ),
        if (target != null && target.toString().isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'Yalnızca $target kullanıcısı devralabilir.',
            style: const TextStyle(fontSize: 11.5, color: AppTheme.textMuted, fontStyle: FontStyle.italic),
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 20),

        // İptal Butonu
        OutlinedButton.icon(
          onPressed: _isActionLoading ? null : _cancelTransfer,
          icon: _isActionLoading
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.cancel_outlined, size: 18, color: AppTheme.accentRed),
          label: const Text('Devir İşlemini İptal Et', style: TextStyle(color: AppTheme.accentRed)),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: AppTheme.accentRed),
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ],
    );
  }

  Widget _buildNewTransferForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Kritik Uyarı Kutusu
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.accentRed.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.accentRed.withValues(alpha: 0.3)),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: AppTheme.accentRed, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'DİKKAT: Eski Ailenin Azli',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppTheme.accentRed),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              SizedBox(height: 6),
              Text(
                'Daire satıldığında veya kiracı değiştiğinde devir başlatılır. Yeni malik kodu onayladığı an mevcut evinizin tüm sakinleri kalıcı olarak silinir ve tüm oturumları kapatılır.',
                style: TextStyle(fontSize: 11.5, color: AppTheme.textMuted, height: 1.3),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Hedef Kullanıcı Girişi (Opsiyonel)
        TextField(
          controller: _targetController,
          decoration: InputDecoration(
            labelText: 'Yeni Malik E-posta / Telefon (Opsiyonel)',
            hintText: 'ornek@email.com veya 0555...',
            labelStyle: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
            hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
            prefixIcon: const Icon(Icons.person_outline, size: 20),
            filled: true,
            fillColor: AppTheme.cardDark,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Boş bırakılırsa kodu giren ilk yetkili kullanıcı daireyi devralabilir.',
          style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
        ),
        const SizedBox(height: 20),

        ElevatedButton.icon(
          onPressed: _isActionLoading ? null : _initiateTransfer,
          icon: _isActionLoading
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.qr_code_2, size: 18),
          label: const Text('48 Saatlik Devir Kodu & QR Üret'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.accentAmber,
            foregroundColor: Colors.black87,
            padding: const EdgeInsets.symmetric(vertical: 13),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            textStyle: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}

