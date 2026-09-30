import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../../services/automation_state.dart';
import '../../../utils/qr_claim_parser.dart';
import '../claim/qr_scanner_page.dart';
import '../../theme/app_theme.dart';

class TransferOwnershipDialog extends StatefulWidget {
  final int initialTab;
  const TransferOwnershipDialog({super.key, this.initialTab = 0});

  static Future<void> show(BuildContext context, {int initialTab = 0}) {
    final state = context.read<AutomationState>();
    return showDialog(
      context: context,
      builder: (ctx) => ChangeNotifierProvider<AutomationState>.value(
        value: state,
        child: TransferOwnershipDialog(initialTab: initialTab),
      ),
    );
  }

  @override
  State<TransferOwnershipDialog> createState() => _TransferOwnershipDialogState();
}

class _TransferOwnershipDialogState extends State<TransferOwnershipDialog> {
  final _targetController = TextEditingController();
  final _emergencyUuidController = TextEditingController();
  final _emergencyReasonController = TextEditingController();
  final _emergencyNewOwnerController = TextEditingController();

  late int _selectedTab;
  bool _isLoading = true;
  bool _isActionLoading = false;
  bool _isEmergencyResetting = false;
  String? _errorMessage;
  Map<String, dynamic>? _pendingTransfer;

  @override
  void initState() {
    super.initState();
    _selectedTab = widget.initialTab;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadTransferStatus();
    });
  }

  @override
  void dispose() {
    _targetController.dispose();
    _emergencyUuidController.dispose();
    _emergencyReasonController.dispose();
    _emergencyNewOwnerController.dispose();
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

              // TAB SEÇİCİ
              Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () => setState(() => _selectedTab = 0),
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        decoration: BoxDecoration(
                          color: _selectedTab == 0
                              ? AppTheme.accentAmber.withValues(alpha: 0.15)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: _selectedTab == 0
                                ? AppTheme.accentAmber
                                : Colors.white12,
                          ),
                        ),
                        child: Text(
                          'Daire Devri (Kod & QR)',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: _selectedTab == 0 ? FontWeight.bold : FontWeight.normal,
                            color: _selectedTab == 0 ? AppTheme.accentAmber : AppTheme.textMuted,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: InkWell(
                      onTap: () => setState(() => _selectedTab = 1),
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        decoration: BoxDecoration(
                          color: _selectedTab == 1
                              ? AppTheme.accentRed.withValues(alpha: 0.15)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: _selectedTab == 1
                                ? AppTheme.accentRed
                                : Colors.white12,
                          ),
                        ),
                        child: Text(
                          'Acil Pano Sıfırlama',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: _selectedTab == 1 ? FontWeight.bold : FontWeight.normal,
                            color: _selectedTab == 1 ? AppTheme.accentRed : AppTheme.textMuted,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              if (_selectedTab == 1) ...[
                _buildEmergencyResetView(),
              ] else if (_isLoading) ...[
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

  Widget _buildEmergencyResetView() {
    final state = context.read<AutomationState>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.accentRed.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.accentRed.withValues(alpha: 0.3)),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded, color: AppTheme.accentRed, size: 20),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Eski kiracı ulaşılamıyorsa veya telefon kayıpsa; panonun QR kodunu okutarak cihazı boşa çıkarabilir veya doğrudan yeni malike devredebilirsiniz.',
                  style: TextStyle(fontSize: 11.5, color: AppTheme.textMuted, height: 1.3),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // 1. KAREKOD TARA BUTONU
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () async {
              final raw = await Navigator.push<String>(
                context,
                MaterialPageRoute(builder: (_) => const QrScannerPage()),
              );
              if (raw != null && raw.trim().isNotEmpty && mounted) {
                final parsed = QrClaimParser.parse(raw);
                setState(() {
                  _emergencyUuidController.text = parsed?.uid ?? raw.trim();
                });
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('✅ Pano karekodu okundu (UUID: ${_emergencyUuidController.text})'),
                    backgroundColor: AppTheme.accentGreen,
                  ),
                );
              }
            },
            icon: const Icon(Icons.qr_code_scanner, color: AppTheme.accentRed, size: 20),
            label: const Text(
              'Pano QR Kodunu Tara (Kamera)',
              style: TextStyle(color: AppTheme.accentRed, fontWeight: FontWeight.bold),
            ),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: AppTheme.accentRed.withValues(alpha: 0.5)),
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
        const SizedBox(height: 12),

        // Cihaz UUID
        TextField(
          controller: _emergencyUuidController,
          decoration: InputDecoration(
            labelText: 'Cihaz UUID (Pano Etiketi)',
            hintText: 'AHBU-S3-PANEL-XXXX',
            labelStyle: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
            hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
            prefixIcon: const Icon(Icons.qr_code, size: 20),
            filled: true,
            fillColor: AppTheme.cardDark,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            suffixIcon: IconButton(
              icon: const Icon(Icons.qr_code_scanner, color: AppTheme.accentRed),
              tooltip: 'Kamera ile Tara',
              onPressed: () async {
                final raw = await Navigator.push<String>(
                  context,
                  MaterialPageRoute(builder: (_) => const QrScannerPage()),
                );
                if (raw != null && raw.trim().isNotEmpty && mounted) {
                  final parsed = QrClaimParser.parse(raw);
                  setState(() {
                    _emergencyUuidController.text = parsed?.uid ?? raw.trim();
                  });
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('✅ Pano karekodu okundu: ${_emergencyUuidController.text}'),
                      backgroundColor: AppTheme.accentGreen,
                    ),
                  );
                }
              },
            ),
          ),
        ),
        const SizedBox(height: 10),

        // Sıfırlama Gerekçesi (Zorunlu)
        TextField(
          controller: _emergencyReasonController,
          decoration: InputDecoration(
            labelText: 'Sıfırlama Gerekçesi (Zorunlu)',
            hintText: 'Örn: Kiracı tahliye edildi, sözleşme ibraz edildi',
            labelStyle: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
            hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
            prefixIcon: const Icon(Icons.description_outlined, size: 20),
            filled: true,
            fillColor: AppTheme.cardDark,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        const SizedBox(height: 10),

        // Yeni Malik (Opsiyonel)
        TextField(
          controller: _emergencyNewOwnerController,
          decoration: InputDecoration(
            labelText: 'Yeni Malik E-posta / Telefon (Opsiyonel)',
            hintText: 'Boş bırakılırsa fabrika stok durumuna döner',
            labelStyle: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
            hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
            prefixIcon: const Icon(Icons.person_outline, size: 20),
            filled: true,
            fillColor: AppTheme.cardDark,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        const SizedBox(height: 16),

        ElevatedButton.icon(
          onPressed: _isEmergencyResetting ? null : () => _executeEmergencyReset(state),
          icon: _isEmergencyResetting
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.restore, size: 18),
          label: const Text('Acil Sıfırla & Eski Aileyi Azlet'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.accentRed,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 13),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            textStyle: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  Future<void> _executeEmergencyReset(AutomationState state) async {
    final uuid = _emergencyUuidController.text.trim();
    final reason = _emergencyReasonController.text.trim();
    final newOwner = _emergencyNewOwnerController.text.trim();

    if (uuid.isEmpty || reason.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Lütfen cihaz UUID ve sıfırlama gerekçesini eksiksiz girin.'),
          backgroundColor: AppTheme.accentRed,
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppTheme.cardBorder),
        ),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: AppTheme.accentRed, size: 24),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Acil Sıfırlama Onayı',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: Text(
          '$uuid kimlikli cihaz sıfırlanacak ve eski ailenin tüm yetki ve oturumları sonlandırılacaktır. Bu işlemi onaylıyor musunuz?',
          style: const TextStyle(fontSize: 13, color: AppTheme.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Vazgeç', style: TextStyle(color: AppTheme.textMuted)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accentRed, foregroundColor: Colors.white),
            child: const Text('Evet, Sıfırla'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isEmergencyResetting = true);

    try {
      final res = await state.emergencyResetDevice(
        deviceUuid: uuid,
        reason: reason,
        newOwnerIdentifier: newOwner.isNotEmpty ? newOwner : null,
      );

      if (!mounted) return;
      setState(() => _isEmergencyResetting = false);
      final message = res['message'] ?? 'Acil servis sıfırlaması başarıyla tamamlandı.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ $message'),
          backgroundColor: AppTheme.accentGreen,
        ),
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isEmergencyResetting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Hata: ${e.toString().replaceAll('Exception: ', '')}'),
          backgroundColor: AppTheme.accentRed,
        ),
      );
    }
  }
}

