import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/automation_state.dart';
import '../theme/app_theme.dart';

class ServiceModePage extends StatefulWidget {
  const ServiceModePage({super.key});

  @override
  State<ServiceModePage> createState() => _ServiceModePageState();
}

class _ServiceModePageState extends State<ServiceModePage> {
  final _pinController = TextEditingController();
  final _uuidController = TextEditingController(text: 'AHBU-S3-PANEL-001');
  final _setupPinController = TextEditingController(text: '123456');
  final _targetOwnerController = TextEditingController();
  final _commissioningNotesController = TextEditingController();
  final _emergencyUuidController = TextEditingController(text: 'AHBU-S3-PANEL-001');
  final _emergencyReasonController = TextEditingController();
  final _emergencyNewOwnerController = TextEditingController();

  bool _isLoading = false;
  bool _isClaiming = false;
  bool _isSubmittingCommissioning = false;
  bool _isLoadingCommissioning = false;
  bool _isEmergencyResetting = false;
  String? _errorMessage;
  String? _generatedPin;
  Map<String, dynamic>? _commissioningStatus;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadCommissioningStatus();
    });
  }

  @override
  void dispose() {
    _pinController.dispose();
    _uuidController.dispose();
    _setupPinController.dispose();
    _targetOwnerController.dispose();
    _commissioningNotesController.dispose();
    _emergencyUuidController.dispose();
    _emergencyReasonController.dispose();
    _emergencyNewOwnerController.dispose();
    super.dispose();
  }

  Future<void> _loadCommissioningStatus() async {
    final state = context.read<AutomationState>();
    if (!state.isServiceMode || state.activeHome == null) return;

    setState(() => _isLoadingCommissioning = true);
    try {
      final status = await state.getCommissioningStatus();
      if (mounted) {
        setState(() {
          _commissioningStatus = status;
          _isLoadingCommissioning = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoadingCommissioning = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AutomationState>();
    final isInstaller = state.isServiceMode;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/images/app_logo.png',
                width: 32,
                height: 32,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Kurulumcu & Servis Menüsü',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    'Pano Kalibrasyonu & Devreye Alma',
                    style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await state.refresh();
          await _loadCommissioningStatus();
        },
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!isInstaller) ...[
                _buildHardwareProtectionWarning(),
                const SizedBox(height: 16),
                _buildPinLoginCard(state),
                const SizedBox(height: 16),
                _buildGeneratePinForTechnicianCard(state),
              ] else ...[
                _buildInstallerActiveCard(state),
                const SizedBox(height: 16),
                _buildCommissioningCard(state),
                const SizedBox(height: 16),
                _buildDeviceClaimingCard(state),
                const SizedBox(height: 16),
                _buildCalibrationAndEndpointsCard(state),
                const SizedBox(height: 16),
                _buildEmergencyResetCard(state),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHardwareProtectionWarning() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.accentAmber.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.accentAmber.withValues(alpha: 0.35)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.shield_outlined, color: AppTheme.accentAmber, size: 22),
          SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '🔒 Donanım & Motor Koruması Aktif',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13.5,
                    color: AppTheme.accentAmber,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Pano klemens eşlemeleri ve panjur motor çalışma süreleri donanım güvenliği gereği kilitlidir. Bu ayarlara yalnızca yetkili servis sorumlusu erişebilir.',
                  style: TextStyle(fontSize: 12, color: AppTheme.textMuted, height: 1.3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPinLoginCard(AutomationState state) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.lock_open, color: AppTheme.accentAmber, size: 20),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Yetkili Servis PIN Girişi',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Ev sahibinin oluşturduğu 2 saat geçerli 6 haneli servis PIN kodunu giriniz.',
            style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _pinController,
            keyboardType: TextInputType.number,
            maxLength: 6,
            style: const TextStyle(letterSpacing: 8, fontSize: 20, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
            decoration: InputDecoration(
              counterText: '',
              hintText: '••••••',
              hintStyle: const TextStyle(letterSpacing: 8),
              filled: true,
              fillColor: const Color(0xFF0F172A),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppTheme.cardBorder),
              ),
            ),
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 8),
            Text(
              _errorMessage!,
              style: const TextStyle(color: AppTheme.accentRed, fontSize: 12),
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _isLoading ? null : () => _handleServiceLogin(state),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accentPurple,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: _isLoading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text(
                      'Servis Oturumu Aç',
                      style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGeneratePinForTechnicianCard(AutomationState state) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.primaryBlue.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.vpn_key_outlined, color: AppTheme.primaryBlueLight, size: 20),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Ev Sahibi: Servis PIN\'i Üret',
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Yetkili servisin panoyu ayarlayabilmesi için 2 saat süreli tek kullanımlık servis PIN kodu üretir.',
            style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
          ),
          const SizedBox(height: 12),
          if (_generatedPin != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              decoration: BoxDecoration(
                color: AppTheme.accentGreen.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.accentGreen.withValues(alpha: 0.4)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.check_circle_outline, color: AppTheme.accentGreen, size: 18),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      _generatedPin!,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 6,
                        color: AppTheme.accentGreen,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const Center(
              child: Text(
                '⏳ 2 saat sonra otomatik olarak iptal olacaktır.',
                style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
              ),
            ),
            const SizedBox(height: 10),
          ],
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () async {
                try {
                  final pin = await state.generateServiceToken();
                  if (!mounted) return;
                  setState(() {
                    _generatedPin = pin;
                  });
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Hata: $e')),
                  );
                }
              },
              icon: const Icon(Icons.key, size: 16, color: AppTheme.primaryBlueLight),
              label: Text(
                _generatedPin == null ? '6 Haneli Servis PIN Üret' : 'Yeni PIN Üret',
                style: const TextStyle(color: AppTheme.primaryBlueLight, fontWeight: FontWeight.bold),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppTheme.primaryBlueLight),
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInstallerActiveCard(AutomationState state) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.accentPurple.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.accentPurple.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.accentPurple.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.engineering, color: AppTheme.accentPurple, size: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Aktif Servis Modu',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppTheme.accentPurple),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  'Yetkili Servis: ${state.currentUser?.fullName ?? "Servis Sorumlusu"}',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.exit_to_app, color: AppTheme.accentRed),
            tooltip: 'Servis Oturumunu Kapat',
            onPressed: () => state.logout(),
          ),
        ],
      ),
    );
  }

  Widget _buildCommissioningCard(AutomationState state) {
    final isCommissioned = _commissioningStatus?['is_commissioned'] == true ||
        _commissioningStatus?['commissioning_status'] == 'APPROVED_WORKING';
    final commissionedBy = _commissioningStatus?['commissioned_by_name'] ?? _commissioningStatus?['commissioned_by'];
    final commissionedAt = _commissioningStatus?['commissioned_at'];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isCommissioned
              ? AppTheme.accentGreen.withValues(alpha: 0.5)
              : AppTheme.accentAmber.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isCommissioned ? Icons.verified_outlined : Icons.pending_actions_outlined,
                color: isCommissioned ? AppTheme.accentGreen : AppTheme.accentAmber,
                size: 20,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Sistemi Devreye Alma (Commissioning)',
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_isLoadingCommissioning)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Montaj, klemens ve motor yön testleri tamamlandıktan sonra sistemi ticari olarak "Çalışır" onayına alın.',
            style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: (isCommissioned ? AppTheme.accentGreen : AppTheme.accentAmber).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: (isCommissioned ? AppTheme.accentGreen : AppTheme.accentAmber).withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  isCommissioned ? Icons.check_circle : Icons.warning_amber_rounded,
                  color: isCommissioned ? AppTheme.accentGreen : AppTheme.accentAmber,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isCommissioned ? '✅ Devreye Alındı: ÇALIŞIR ONAYLI' : '⚠️ Henüz Devreye Alınmadı (Test Bekliyor)',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12.5,
                          color: isCommissioned ? AppTheme.accentGreen : AppTheme.accentAmber,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (commissionedBy != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          'Onaylayan: $commissionedBy ${commissionedAt != null ? "($commissionedAt)" : ""}',
                          style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _commissioningNotesController,
            decoration: InputDecoration(
              labelText: 'Devreye Alma / Montaj Notu (İsteğe Bağlı)',
              hintText: 'Örn: Pano montajı ve 4 adet panjur testi eksiksiz tamamlandı.',
              filled: true,
              fillColor: const Color(0xFF0F172A),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isSubmittingCommissioning
                  ? null
                  : () async {
                      setState(() => _isSubmittingCommissioning = true);
                      try {
                        final notes = _commissioningNotesController.text.trim();
                        await state.commissionSystem(notes: notes.isNotEmpty ? notes : null);
                        await _loadCommissioningStatus();
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('✅ Sistem başarıyla "Çalışır" olarak onaylandı ve devreye alındı!'),
                            backgroundColor: AppTheme.accentGreen,
                          ),
                        );
                      } catch (e) {
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Hata: $e'), backgroundColor: AppTheme.accentRed),
                        );
                      } finally {
                        if (mounted) {
                          setState(() => _isSubmittingCommissioning = false);
                        }
                      }
                    },
              icon: _isSubmittingCommissioning
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.verified, size: 18),
              label: Text(
                isCommissioned ? 'Yeniden Onayla & Güncelle' : 'Sistemi Test Et & "Çalışır" Olarak Onayla',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accentGreen,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceClaimingCard(AutomationState state) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.qr_code_scanner, color: AppTheme.primaryBlueLight, size: 20),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Yeni Pano Cihazı Eşleme & Müşteriye Teslim',
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Pano kapağındaki Device UUID ve 6 haneli Setup PIN ile eşleyin. Müşteri hesabına doğrudan teslim edebilirsiniz.',
            style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _uuidController,
            decoration: InputDecoration(
              labelText: 'Pano Device UUID',
              hintText: 'AHBU-S3-PANEL-001',
              filled: true,
              fillColor: const Color(0xFF0F172A),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _setupPinController,
            keyboardType: TextInputType.number,
            maxLength: 6,
            decoration: InputDecoration(
              labelText: '6 Haneli Setup PIN',
              counterText: '',
              hintText: '123456',
              filled: true,
              fillColor: const Color(0xFF0F172A),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _targetOwnerController,
            decoration: InputDecoration(
              labelText: 'Müşteri E-Posta / Telefonu (İsteğe Bağlı)',
              hintText: 'Örn: ahmet@gmail.com veya 05551234567',
              filled: true,
              fillColor: const Color(0xFF0F172A),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isClaiming
                  ? null
                  : () async {
                      final uuid = _uuidController.text.trim();
                      final pin = _setupPinController.text.trim();
                      final target = _targetOwnerController.text.trim();

                      if (uuid.isEmpty || pin.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Lütfen UUID ve PIN alanlarını doldurun')),
                        );
                        return;
                      }

                      setState(() => _isClaiming = true);
                      try {
                        await state.claimDevice(
                          uuid,
                          pin,
                          targetOwner: target.isNotEmpty ? target : null,
                        );
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              target.isNotEmpty
                                  ? '✅ Cihaz başarıyla daireye ve "$target" müşterisine bağlandı!'
                                  : '✅ Cihaz başarıyla daireye bağlandı!',
                            ),
                            backgroundColor: AppTheme.accentGreen,
                          ),
                        );
                      } catch (e) {
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Eşleme Hatası: $e'), backgroundColor: AppTheme.accentRed),
                        );
                      } finally {
                        if (mounted) {
                          setState(() => _isClaiming = false);
                        }
                      }
                    },
              icon: _isClaiming
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.link, size: 18),
              label: const Text('Cihazı Daireye & Müşteriye Sahiplen'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryBlue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCalibrationAndEndpointsCard(AutomationState state) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.tune, color: AppTheme.accentGreen, size: 20),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Panjur Süresi & Röle Kalibrasyonu',
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Panjur motorlarının tam açılma/kapanma süresini test edin ve kalibre edin.',
            style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
          ),
          const SizedBox(height: 14),
          _buildCalibrationRow('Panjur 1 (Salon)', 20),
          const Divider(color: AppTheme.cardBorder, height: 20),
          _buildCalibrationRow('Panjur 2 (Mutfak)', 20),
          const Divider(color: AppTheme.cardBorder, height: 20),
          _buildCalibrationRow('Panjur 3 (Yatak Odası)', 18),
          const Divider(color: AppTheme.cardBorder, height: 20),
          _buildCalibrationRow('Panjur 4 (Balkon)', 22),
        ],
      ),
    );
  }

  Widget _buildCalibrationRow(String label, int defaultSec) {
    int duration = defaultSec;
    return StatefulBuilder(
      builder: (context, setRowState) {
        return Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    'Motor Çalışma Süresi: $duration sn',
                    style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.remove_circle_outline, color: AppTheme.textMuted, size: 20),
              onPressed: () {
                if (duration > 5) {
                  setRowState(() => duration--);
                }
              },
            ),
            Text(
              '$duration s',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            IconButton(
              icon: const Icon(Icons.add_circle_outline, color: AppTheme.textMuted, size: 20),
              onPressed: () {
                if (duration < 60) {
                  setRowState(() => duration++);
                }
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _handleServiceLogin(AutomationState state) async {
    final pin = _pinController.text.trim();
    if (pin.length != 6) {
      setState(() => _errorMessage = 'Lütfen 6 haneli PIN giriniz');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await state.loginWithServicePin(pin);
      setState(() => _isLoading = false);
      await _loadCommissioningStatus();
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString().replaceAll('Exception: ', '');
      });
    }
  }

  Widget _buildEmergencyResetCard(AutomationState state) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppTheme.accentRed.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: AppTheme.accentRed, size: 22),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  '⚠️ Acil Servis Sıfırlaması',
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: AppTheme.accentRed),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Eski kiracı ulaşılamıyorsa veya telefon kayıpsa; tapu/sözleşme ibrazıyla cihazı boşa çıkarın (varsayılan 123456 PIN) veya doğrudan yeni malike devredin.',
            style: TextStyle(fontSize: 11.5, color: AppTheme.textMuted, height: 1.3),
          ),
          const SizedBox(height: 14),

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
              fillColor: AppTheme.surfaceDark,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
          const SizedBox(height: 10),

          // Sıfırlama Gerekçesi (Zorunlu)
          TextField(
            controller: _emergencyReasonController,
            decoration: InputDecoration(
              labelText: 'Sıfırlama Gerekçesi (Zorunlu)',
              hintText: 'Örn: Kiracı tahliye edildi, tapu teyit edildi.',
              labelStyle: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
              hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
              prefixIcon: const Icon(Icons.description_outlined, size: 20),
              filled: true,
              fillColor: AppTheme.surfaceDark,
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
              fillColor: AppTheme.surfaceDark,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
          const SizedBox(height: 14),

          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isEmergencyResetting ? null : () => _confirmAndExecuteEmergencyReset(state),
              icon: _isEmergencyResetting
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.restore, size: 18),
              label: const Text('Acil Sıfırla & Eski Aileyi Azlet'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accentRed,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                textStyle: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmAndExecuteEmergencyReset(AutomationState state) async {
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
      setState(() {
        _isEmergencyResetting = false;
        _emergencyReasonController.clear();
      });

      final message = res['message'] ?? 'Acil servis sıfırlaması başarıyla tamamlandı.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message.toString()),
          backgroundColor: AppTheme.accentGreen,
        ),
      );
      await _loadCommissioningStatus();
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
