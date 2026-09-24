import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/automation_models.dart';
import '../../services/automation_state.dart';
import '../theme/app_theme.dart';
import '../widgets/quick_scenario_bar.dart';
import '../widgets/shutter_card.dart';
import '../widgets/relay_switch_card.dart';
import '../widgets/di_status_pill.dart';
import '../widgets/user_profile_dialog.dart';
import '../../utils/qr_claim_parser.dart';
import 'claim/claim_manual_dialog.dart';
import 'claim/qr_scanner_page.dart';
import 'device_settings_page.dart';
import 'service_mode_page.dart';
import 'family/family_members_page.dart';
import 'wifi_recovery_dialog.dart';
import 'system_doctor_dialog.dart';
import '../widgets/biometric_prompt_dialog.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  String _selectedRoom = 'Tümü';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = context.read<AutomationState>();
      if (state.shouldPromptBiometrics) {
        BiometricPromptDialog.show(context, label: state.biometricLabel);
      }
    });
  }

  Future<void> _openQrClaimFlow(BuildContext context) async {
    final raw = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => QrScannerPage(
          onManualFallback: () {
            ClaimManualDialog.show(context);
          },
        ),
      ),
    );

    if (raw != null && raw.isNotEmpty && context.mounted) {
      final trimmed = raw.trim();

      // 1. Aile Katılım veya Süreli Misafir QR'ı mı? (AHBU-INVITE:AHBU-XXXXXX veya AHBU-XXXXXX)
      if (trimmed.startsWith('AHBU-INVITE:') ||
          (trimmed.startsWith('AHBU-') && !trimmed.contains(':'))) {
        final state = context.read<AutomationState>();
        try {
          final res = await state.joinHome(trimmed);
          if (!context.mounted) return;
          final msg = res['message'] ?? 'Eve başarıyla katıldınız!';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.check_circle_outline, color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                  Expanded(child: Text(msg.toString())),
                ],
              ),
              backgroundColor: AppTheme.accentGreen,
              duration: const Duration(seconds: 4),
            ),
          );
          return;
        } catch (e) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Katılım hatası: ${e.toString().replaceAll("Exception: ", "")}'),
              backgroundColor: AppTheme.accentRed,
            ),
          );
          return;
        }
      }

      // 2. Donanım Pano Eşleme (Claiming) QR'ı
      final claimData = QrClaimParser.parse(raw);
      if (claimData != null) {
        ClaimManualDialog.show(
          context,
          initialUid: claimData.uid,
          initialPin: claimData.pin,
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Geçersiz karekod formatı! Lütfen bilgileri kontrol ediniz.'),
            backgroundColor: AppTheme.accentRed,
          ),
        );
        ClaimManualDialog.show(context);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AutomationState>();
    final status = state.status;
    final isConnected = state.isConnected;
    final isCloud = state.mode == AppMode.cloud;

    // Durum Hapları Hesaplamaları
    int activeLightCount = 0;
    int activeShutterCount = 0;

    if (isCloud) {
      activeLightCount = state.cloudEndpoints.where((e) => e.isLight && e.currentState).length;
      activeShutterCount = state.cloudEndpoints.where((e) => e.isShutter && e.shutterPosition > 0).length;
    } else if (status != null) {
      activeLightCount = status.relays.where((r) => r.isLight && r.state).length;
      activeShutterCount = status.shutters.where((s) => s.isMoving).length;
    }

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF38BDF8), width: 0.6),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF38BDF8).withValues(alpha: 0.4),
                    blurRadius: 8,
                  ),
                ],
              ),
              child: ClipOval(
                child: Image.asset(
                  'assets/images/round_app_logo.png',
                  width: 32,
                  height: 32,
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    isCloud ? (state.activeHome?.name ?? 'Evim') : (status?.deviceName ?? 'AHBU Akıllı Ev'),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isConnected ? AppTheme.accentGreen : AppTheme.accentRed,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          isConnected
                              ? (isCloud ? 'MQTTS TLS 1.3 (Bulut)' : 'Yerel Ağ (${state.host})')
                              : 'Bağlantı Bekleniyor...',
                          style: TextStyle(
                            fontSize: 11,
                            color: isConnected ? AppTheme.accentGreen : AppTheme.accentRed,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          // Mod Değiştirici (Bulut / Yerel)
          IconButton(
            icon: Icon(
              isCloud ? Icons.cloud_outlined : Icons.wifi_outlined,
              color: isCloud ? AppTheme.primaryBlueLight : AppTheme.accentAmber,
            ),
            tooltip: isCloud ? 'Bulut Modu (MQTTS)' : 'Yerel Ağ Modu (LAN)',
            onPressed: () {
              state.setMode(isCloud ? AppMode.direct : AppMode.cloud);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(isCloud ? 'Direct LAN Moduna geçildi' : 'Cloud MQTTS Moduna geçildi'),
                  duration: const Duration(seconds: 1),
                ),
              );
            },
          ),
          // Kurulumcu / Servis Menüsü (Yalnızca Yetkili Kurulumcu / Teknisyen görebilir - ADIM 11 RBAC)
          if (state.isInstaller)
            IconButton(
              icon: const Icon(Icons.build_outlined, color: AppTheme.accentPurple),
              tooltip: 'Kurulumcu & Servis Menüsü',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ServiceModePage()),
                );
              },
            ),
          // Cihaz Ayarları (Owner veya Installer görebilir)
          if (!state.isMember)
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
          // Aile & Misafir Yönetimi (Yalnızca Ev Sahibi görebilir - ADIM 12)
          if (state.isOwner)
            IconButton(
              icon: const Icon(Icons.group_outlined, color: AppTheme.primaryBlueLight),
              tooltip: 'Aile & Misafir Yönetimi',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const FamilyMembersPage()),
                );
              },
            ),
          // Karekod ile Cihaz Eşle / Eve Katıl
          IconButton(
            icon: const Icon(Icons.qr_code_scanner, color: AppTheme.primaryBlueLight),
            tooltip: 'Karekod Tara (Cihaz / Eve Katıl)',
            onPressed: () => _openQrClaimFlow(context),
          ),
          // Sistem Doktoru (Hızlı Teşhis)
          IconButton(
            icon: const Icon(Icons.health_and_safety_outlined, color: Colors.cyanAccent),
            tooltip: 'Sistem Doktoru (Teşhis)',
            onPressed: () => SystemDoctorDialog.show(context),
          ),
          // Yenile
          IconButton(
            icon: const Icon(Icons.refresh, color: AppTheme.textMuted),
            tooltip: 'Yenile',
            onPressed: () => state.refresh(),
          ),
          // Kullanıcı Profili & Çıkış
          IconButton(
            icon: state.currentUser != null
                ? CircleAvatar(
                    radius: 13,
                    backgroundColor: AppTheme.primaryBlue.withValues(alpha: 0.2),
                    child: Text(
                      state.currentUser!.fullName.isNotEmpty
                          ? state.currentUser!.fullName.substring(0, 1).toUpperCase()
                          : 'U',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.primaryBlueLight,
                      ),
                    ),
                  )
                : const Icon(Icons.account_circle_outlined, color: AppTheme.textMuted),
            tooltip: 'Kullanıcı Profili & Oturum',
            onPressed: () => UserProfileDialog.show(context),
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
              // 1. ÜST DURUM HAPLARI (GLANCEABLE STATUS PILLS)
              _buildGlanceableStatusBar(activeLightCount, activeShutterCount, isConnected, childLock: state.childLock),
              const SizedBox(height: 16),

              // ADIM 17: Gece Huzur Bildirimi Bannerı (Açık Lamba Uyarısı & Hepsini Kapat)
              _buildPeaceBanner(state, activeLightCount),

              // 2. HIZLI SENARYO ÇUBUĞU
              const QuickScenarioBar(),
              const SizedBox(height: 20),

              // 3. ODA FİLTRELEME ÇİPLERİ (ROOM FILTER CHIPS)
              _buildRoomFilterChips(),
              const SizedBox(height: 20),

              // 4. İÇERİK: BULUT VEYA DİREKT MOD
              if (isCloud) ...[
                _buildCloudEndpointsSection(state),
              ] else ...[
                _buildDirectStatusSection(status, state),
              ],

              // 5. BAĞLANTI UYARISI
              if (!isConnected) ...[
                const SizedBox(height: 20),
                _buildOfflineNotice(state, isCloud),
              ],
              const SizedBox(height: 30),
            ],
          ),
        ),
      ),
    );
  }

  /// ADIM 17: Gece Huzur Bildirimi Bannerı
  Widget _buildPeaceBanner(AutomationState state, int activeLightCount) {
    if (activeLightCount <= 0) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.indigoAccent.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.indigoAccent.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.nightlight_round, color: Colors.indigoAccent, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Huzur Modu / Gece Kontrolü',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '$activeLightCount lamba açık kaldı.',
                  style: const TextStyle(fontSize: 11.5, color: AppTheme.textMuted),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: () async {
              try {
                await state.closeAllOpenLights();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Tüm açık lambalar kapatıldı, huzur modu aktif.')),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Kapatma hatası: $e')),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.indigoAccent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Hepsini Kapat', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  /// Üst Bar Glanceable Durum Hapları
  Widget _buildGlanceableStatusBar(int lightsOn, int shuttersActive, bool isConnected, {bool childLock = false}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _buildStatusPill(
              icon: Icons.lightbulb,
              label: lightsOn > 0 ? '$lightsOn Işık Açık' : 'Tüm Işıklar Kapalı',
              color: lightsOn > 0 ? AppTheme.accentAmber : AppTheme.textMuted,
              isActive: lightsOn > 0,
            ),
            _buildStatusPill(
              icon: Icons.window_outlined,
              label: shuttersActive > 0 ? '$shuttersActive Panjur Hareketli' : 'Panjurlar Sabit',
              color: shuttersActive > 0 ? AppTheme.primaryBlueLight : AppTheme.textMuted,
              isActive: shuttersActive > 0,
            ),
            if (childLock)
              _buildStatusPill(
                icon: Icons.lock_outline,
                label: 'Çocuk Kilidi Aktif',
                color: Colors.amber,
                isActive: true,
              ),
            _buildStatusPill(
              icon: isConnected ? Icons.wifi : Icons.wifi_off,
              label: isConnected ? 'Sistem Hazır' : 'Bağlantı Yok',
              color: isConnected ? AppTheme.accentGreen : AppTheme.accentRed,
              isActive: isConnected,
            ),
          ],
        );
      },
    );
  }

  Widget _buildStatusPill({
    required IconData icon,
    required String label,
    required Color color,
    required bool isActive,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isActive ? color.withValues(alpha: 0.12) : const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isActive ? color.withValues(alpha: 0.35) : AppTheme.cardBorder,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: color,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// Oda Filtreleme Çipleri
  Widget _buildRoomFilterChips() {
    final rooms = ['Tümü', 'Salon', 'Mutfak', 'Yatak Odası', 'Antre', 'Balkon'];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
        children: rooms.map((room) {
          final isSelected = _selectedRoom == room;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              label: Text(room),
              selected: isSelected,
              onSelected: (selected) {
                setState(() {
                  _selectedRoom = room;
                });
              },
              backgroundColor: const Color(0xFF1E293B),
              selectedColor: AppTheme.primaryBlue.withValues(alpha: 0.25),
              checkmarkColor: AppTheme.primaryBlueLight,
              labelStyle: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? AppTheme.primaryBlueLight : AppTheme.textMuted,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(
                  color: isSelected ? AppTheme.primaryBlueLight : AppTheme.cardBorder,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  /// Bulut Modu Uç Noktaları (Cloud Mode Endpoints)
  Widget _buildCloudEndpointsSection(AutomationState state) {
    var endpoints = state.cloudEndpoints;
    if (_selectedRoom != 'Tümü') {
      endpoints = endpoints.where((e) => e.room.toLowerCase() == _selectedRoom.toLowerCase()).toList();
    }

    if (endpoints.isEmpty) {
      if (state.cloudEndpoints.isEmpty) {
        return _buildWelcomeClaimCard(context);
      }
      return Container(
        padding: const EdgeInsets.all(24),
        alignment: Alignment.center,
        child: Column(
          children: [
            const Icon(Icons.inbox_outlined, size: 40, color: AppTheme.textMuted),
            const SizedBox(height: 8),
            Text(
              '$_selectedRoom odasında cihaz bulunamadı',
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
            ),
          ],
        ),
      );
    }

    final lights = endpoints.where((e) => e.isLight || e.isImpulse || e.isPlug).toList();
    final shutters = endpoints.where((e) => e.isShutter).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (shutters.isNotEmpty) ...[
          _buildSectionHeader('🪟 Panjurlar', '${shutters.length} Motor'),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth > 600;
              final itemWidth = isWide ? (constraints.maxWidth - 12) / 2 : constraints.maxWidth;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: shutters.map((s) {
                  final shutterItem = ShutterItem(
                    pairIndex: s.channel ~/ 2,
                    name: s.name,
                    isMoving: false,
                    direction: 0,
                    runtimeSec: s.shutterDurationSec,
                  );
                  return SizedBox(
                    width: itemWidth,
                    child: ShutterCard(shutter: shutterItem),
                  );
                }).toList(),
              );
            },
          ),
          const SizedBox(height: 24),
        ],
        if (lights.isNotEmpty) ...[
          _buildSectionHeader('💡 Aydınlatma & Prizler', '${lights.length} Çıkış'),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth > 600;
              final itemWidth = isWide ? (constraints.maxWidth - 12) / 2 : constraints.maxWidth;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: lights.map((e) {
                  final relayItem = RelayItem(
                    id: e.channel,
                    name: e.name,
                    type: e.isImpulse ? 3 : 0,
                    state: e.currentState,
                  );
                  return SizedBox(
                    width: itemWidth,
                    child: RelaySwitchCard(relay: relayItem),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ],
    );
  }

  /// Karşılama ve Cihaz Sahiplenme Kartı (Empty State)
  Widget _buildWelcomeClaimCard(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.cardBorder, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppTheme.primaryBlue.withValues(alpha: 0.12),
              shape: BoxShape.circle,
              border: Border.all(color: AppTheme.primaryBlueLight.withValues(alpha: 0.3), width: 1.5),
            ),
            child: const Icon(
              Icons.qr_code_scanner_rounded,
              color: AppTheme.primaryBlueLight,
              size: 56,
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Evinize Hoş Geldiniz!',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          const Text(
            'Akıllı panonuzun lamba ve panjurlarını yönetebilmek için pano kapağındaki karekodu tarayarak kurulumu tamamlayın.',
            style: TextStyle(
              fontSize: 14,
              color: AppTheme.textMuted,
              height: 1.4,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => _openQrClaimFlow(context),
              icon: const Icon(Icons.camera_alt_outlined, size: 20),
              label: const Text(
                'Karekod ile Cihaz Eşle',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryBlue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => ClaimManualDialog.show(context),
              icon: const Icon(Icons.keyboard_alt_outlined, size: 18, color: AppTheme.textMuted),
              label: const Text(
                'Kodu Elle Gir (Manuel Eşleme)',
                style: TextStyle(fontSize: 14, color: AppTheme.textPrimary),
              ),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                side: const BorderSide(color: AppTheme.cardBorder),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Doğrudan Yerel Ağ Modu (Direct LAN Status)
  Widget _buildDirectStatusSection(DeviceStatus? status, AutomationState state) {
    if (status == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(),
        ),
      );
    }

    var shutters = status.shutters;
    var singleRelays = status.relays.where((r) => r.isLight || r.isImpulse).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (shutters.isNotEmpty) ...[
          _buildSectionHeader('🪟 Panjur Kontrolleri', '${shutters.length} Motor'),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth > 600;
              final itemWidth = isWide ? (constraints.maxWidth - 12) / 2 : constraints.maxWidth;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: shutters.map((s) {
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
        if (singleRelays.isNotEmpty) ...[
          _buildSectionHeader('💡 Aydınlatma & Çıkışlar', '${singleRelays.length} Röle'),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth > 600;
              final itemWidth = isWide ? (constraints.maxWidth - 12) / 2 : constraints.maxWidth;
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
        if (status.dis.isNotEmpty) ...[
          _buildSectionHeader('🔘 Duvar Butonları & Girişler (DI)', 'Kuru Kontak'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: status.dis.map((d) => DIStatusPill(di: d)).toList(),
          ),
        ],
      ],
    );
  }

  Widget _buildOfflineNotice(AutomationState state, bool isCloud) {
    return Container(
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
                  'Bağlantı Bekleniyor',
                  style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.accentAmber),
                ),
                const SizedBox(height: 4),
                Text(
                  isCloud
                      ? 'EMQX MQTTS broker veya REST API sunucusuna erişilemiyor. İnternet bağlantınızı kontrol edin.'
                      : 'Cihaza bağlanılamıyor (${state.host}). Yerel Wi-Fi ağına bağlı olduğunuzdan emin olun.',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton.icon(
                      onPressed: () => SystemDoctorDialog.show(context),
                      icon: const Icon(Icons.health_and_safety, size: 16, color: Colors.cyanAccent),
                      label: const Text(
                        'Sistem Doktoru (Teşhis Başlat)',
                        style: TextStyle(fontSize: 11.5, color: Colors.cyanAccent, fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.cyanAccent.withValues(alpha: 0.15),
                        side: const BorderSide(color: Colors.cyanAccent),
                        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => WifiRecoveryDialog.show(context),
                      icon: const Icon(Icons.wifi_find, size: 16, color: AppTheme.accentAmber),
                      label: const Text(
                        'Wi-Fi Kurtarma Modu',
                        style: TextStyle(fontSize: 11.5, color: AppTheme.accentAmber, fontWeight: FontWeight.bold),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: AppTheme.accentAmber),
                        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
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
