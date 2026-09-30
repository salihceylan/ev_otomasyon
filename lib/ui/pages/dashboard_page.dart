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
import '../widgets/super_user_drawer.dart';
import '../../utils/qr_claim_parser.dart';
import 'claim/claim_manual_dialog.dart';
import 'claim/qr_scanner_page.dart';
import 'device_settings_page.dart';
import 'service_mode_page.dart';
import 'family/family_members_page.dart';
import 'wifi_recovery_dialog.dart';
import 'system_doctor_dialog.dart';
import 'service_management_page.dart';
import 'device_inventory_page.dart';
import 'replace_board_dialog.dart';
import 'family/transfer_ownership_dialog.dart';
import 'family/join_home_dialog.dart';
import '../widgets/biometric_prompt_dialog.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  String _selectedRoom = 'Tümü';
  Map<String, dynamic>? _superUserSummary;
  bool _loadingSuperUserSummary = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = context.read<AutomationState>();
      if (state.shouldPromptBiometrics) {
        BiometricPromptDialog.show(context, label: state.biometricLabel);
      }
      if (state.isSuperUser) {
        _loadSuperUserSummary();
      }
    });
  }

  Future<void> _loadSuperUserSummary() async {
    final state = context.read<AutomationState>();
    if (!state.isSuperUser) return;
    if (_loadingSuperUserSummary) return;

    setState(() => _loadingSuperUserSummary = true);
    try {
      final summary = await state.cloudApi.getServiceSummary();
      if (mounted) {
        setState(() {
          _superUserSummary = summary;
          _loadingSuperUserSummary = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loadingSuperUserSummary = false);
      }
    }
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
    final isSuper = state.isSuperUser;
    final isService = state.isServiceUser;
    final isStaff = state.isServiceManagerOrSuper;
    // Dairesi olmayan bireysel kullanıcı: staff değil, giriş yapmış ama hiçbir eve üye değil
    final isHomelessUser = !isStaff &&
        state.currentUser != null &&
        (state.activeHome == null || state.homes.isEmpty);
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
      key: _scaffoldKey,
      drawer: isStaff ? const SuperUserDrawer() : null,
      appBar: AppBar(
        leading: isStaff
            ? IconButton(
                icon: const Icon(
                  Icons.menu,
                  color: AppTheme.accentCyan,
                ),
                tooltip: 'Sandviç Menü',
                onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              )
            : null,
        title: isStaff
            ? Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isSuper
                            ? const Color(0xFF38BDF8)
                            : AppTheme.accentCyan,
                        width: 0.6,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: (isSuper
                                  ? const Color(0xFF38BDF8)
                                  : AppTheme.accentCyan)
                              .withValues(alpha: 0.4),
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
                          isSuper
                              ? 'Süper Yönetici Konsolu'
                              : 'Yetkili Servis Konsolu',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          isSuper
                              ? 'AHBU Altyapı & Servis Denetimi'
                              : 'Saha Operasyon & Montaj Yönetimi',
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppTheme.accentCyan,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              )
            : Row(
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
        actions: isStaff
            ? [
                IconButton(
                  icon: const Icon(Icons.health_and_safety_outlined, color: Colors.cyanAccent),
                  tooltip: 'Sistem Doktoru (Teşhis)',
                  onPressed: () => SystemDoctorDialog.show(context),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, color: AppTheme.textMuted),
                  tooltip: 'Yenile',
                  onPressed: () {
                    state.refresh();
                    _loadSuperUserSummary();
                  },
                ),
                IconButton(
                  icon: _buildUserAvatar(state),
                  tooltip: 'Kullanıcı Profili & Oturum',
                  onPressed: () => UserProfileDialog.show(context),
                ),
              ]
            : isHomelessUser
                ? [
                    // Dairesi olmayan kullanıcı: sadece Yenile + Profil
                    IconButton(
                      icon: const Icon(Icons.refresh, color: AppTheme.textMuted),
                      tooltip: 'Yenile',
                      onPressed: () => state.refresh(),
                    ),
                    IconButton(
                      icon: _buildUserAvatar(state),
                      tooltip: 'Kullanıcı Profili & Oturum',
                      onPressed: () => UserProfileDialog.show(context),
                    ),
                  ]
                : [
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
                    // Cihaz Ayarları (Owner görebilir)
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
                      icon: _buildUserAvatar(state),
                      tooltip: 'Kullanıcı Profili & Oturum',
                      onPressed: () => UserProfileDialog.show(context),
                    ),
                  ],
      ),
      body: isSuper
          ? _buildSuperUserDashboard(context, state)
          : isService
              ? _buildServiceUserDashboard(context, state)
              : isHomelessUser
                  ? _buildNoHomeIndividualDashboard(context, state)
                  : _buildApartmentDashboard(
                      context: context,
                      state: state,
                      activeLightCount: activeLightCount,
                      activeShutterCount: activeShutterCount,
                      isConnected: isConnected,
                      isCloud: isCloud,
                      status: status,
                    ),
    );
  }

  /// Süper Yönetici Konsol Arayüzü (Daire Kontrollerinden Tamamen Arındırılmış)
  Widget _buildSuperUserDashboard(BuildContext context, AutomationState state) {
    final user = state.currentUser;
    final summary = _superUserSummary;

    return RefreshIndicator(
      onRefresh: () async {
        await state.refresh();
        await _loadSuperUserSummary();
      },
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. Yönetici Hoş Geldiniz & Sistem Statü Kartı
            _buildSuperUserHeaderCard(user),
            const SizedBox(height: 16),

            // 2. Canlı Altyapı & Sağlık Çubuğu (API, DB, MQTT)
            _buildInfrastructureStatusRow(),
            const SizedBox(height: 20),

            // 3. Operasyonel Sayaçlar (Servis Sorumluları, Pano Envanteri, Devreye Alınan)
            _buildSuperUserMetricCards(summary),
            const SizedBox(height: 24),

            // 4. Hızlı Yönetici İşlemleri
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    '⚡ Hızlı Yönetici İşlemleri',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).brightness == Brightness.dark ? Colors.white : AppTheme.textPrimaryLight,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const ServiceManagementPage()),
                    );
                  },
                  icon: const Icon(Icons.arrow_forward_rounded, size: 16, color: AppTheme.accentCyan),
                  label: const Text(
                    'Tüm Paneli Aç',
                    style: TextStyle(fontSize: 12.5, color: AppTheme.accentCyan, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _buildSuperUserActionGrid(context),
            const SizedBox(height: 20),

            // 5. Sandviç Menü Hatırlatma İpucu
            _buildDrawerTipBox(context),
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }

  /// Yetkili Servis Sorumlusu Konsolu (Daire Kontrollerinden Arındırılmış, Saha & Montaj Odaklı)
  Widget _buildServiceUserDashboard(BuildContext context, AutomationState state) {
    final user = state.currentUser;
    final summary = _superUserSummary;

    return RefreshIndicator(
      onRefresh: () async {
        await state.refresh();
        await _loadSuperUserSummary();
      },
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. Servis Sorumlusu Hoş Geldiniz & Yetki Kartı
            _buildServiceUserHeaderCard(user),
            const SizedBox(height: 16),

            // 2. Canlı Altyapı & Sağlık Çubuğu (API, DB, MQTT)
            _buildInfrastructureStatusRow(),
            const SizedBox(height: 20),

            // 3. Saha Operasyon Sayaçları (Pano Envanteri, Daireler)
            _buildServiceUserMetricCards(summary),
            const SizedBox(height: 24),

            // 4. Yetkili Servis Saha İş Akışı & Eylemleri
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                '🛠️ Saha Servis & Devreye Alma Görevleri',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).brightness == Brightness.dark ? Colors.white : AppTheme.textPrimaryLight,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 8),
            _buildServiceUserActionGrid(context),
            const SizedBox(height: 20),

            // 5. Güvenlik Uyarısı
            _buildServiceSafetyNotice(),
            const SizedBox(height: 16),

            // 6. Sandviç Menü Hatırlatma İpucu
            _buildDrawerTipBox(context),
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }

  Widget _buildServiceUserHeaderCard(dynamic user) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.cardDark : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? AppTheme.accentCyan.withValues(alpha: 0.35)
              : AppTheme.accentCyan.withValues(alpha: 0.5),
        ),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? AppTheme.accentCyan.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.05),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.accentCyan.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.engineering_rounded, color: AppTheme.accentCyan, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            user?.fullName?.isNotEmpty == true ? user!.fullName : 'Yetkili Servis Sorumlusu',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : AppTheme.textPrimaryLight,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppTheme.accentCyan.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'YETKİLİ SERVİS',
                            style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.accentCyan,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      user?.email?.isNotEmpty == true ? user!.email : 'servis@gudeteknoloji.com.tr',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? AppTheme.textMuted : AppTheme.textMutedLight,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Saha panolarını envantere alabilir, dairelere takılan panoları devreye alabilir, afet durumunda pano klonlama ve daire devir işlemlerini yürütebilirsiniz.',
            style: TextStyle(
              fontSize: 12.5,
              color: isDark ? AppTheme.textMuted : AppTheme.textMutedLight,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildServiceUserMetricCards(Map<String, dynamic>? summary) {
    final deviceCount = summary?['total_devices'] ?? 0;
    final homeCount = summary?['commissioned_homes_count'] ?? 0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth = (constraints.maxWidth - 10) / 2;

        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            SizedBox(
              width: cardWidth,
              child: _buildMetricCard(
                title: 'Pano Envanteri',
                value: '$deviceCount',
                icon: Icons.inventory_2_outlined,
                color: AppTheme.accentCyan,
                badgeText: 'STOK & PANO',
                onTap: null, // Yalnızca bilgilendirme, envanter yönetimi Süper Yöneticiye aittir
              ),
            ),
            SizedBox(
              width: cardWidth,
              child: _buildMetricCard(
                title: 'Devreye Alınan',
                value: '$homeCount',
                icon: Icons.task_alt,
                color: AppTheme.accentGreen,
                badgeText: 'AKTİF DAİRE',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const ServiceModePage(),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildServiceUserActionGrid(BuildContext context) {
    final actions = [
      {
        'title': 'Devreye Alma (Commissioning)',
        'subtitle': 'Pano karekod eşleme & müşteri OTP onayı, 8 röle/8 giriş canlı test ve devreye alma',
        'icon': Icons.verified_outlined,
        'color': AppTheme.accentCyan,
        'onTap': () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ServiceModePage()),
            ),
      },
      {
        'title': 'Pano Değişimi (Afet & Hasar)',
        'subtitle': 'Arızalı panonun UUID\'sini yenisiyle değiştirip daire verilerini aktarın',
        'icon': Icons.published_with_changes_outlined,
        'color': Colors.tealAccent,
        'onTap': () => ReplaceBoardDialog.show(context),
      },
      {
        'title': 'Wi-Fi Yapılandırma & Kurtarma',
        'subtitle': 'Modem değişikliğinde panoya yeni Wi-Fi adı ve şifresini aktarın',
        'icon': Icons.wifi_find_rounded,
        'color': Colors.orangeAccent,
        'onTap': () => WifiRecoveryDialog.show(context),
      },
      {
        'title': 'Acil Sıfırlama & Mülk Devri',
        'subtitle': 'Eski sahibine ulaşılamayan panoyu sıfırlayıp daireye devret',
        'icon': Icons.sync_problem_rounded,
        'color': Colors.redAccent,
        'onTap': () => showDialog(
              context: context,
              builder: (_) => const TransferOwnershipDialog(),
            ),
      },
    ];

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 550;
        final itemWidth = isWide ? (constraints.maxWidth - 10) / 2 : constraints.maxWidth;

        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: actions.map((item) {
            final color = item['color'] as Color;
            return SizedBox(
              width: itemWidth,
              child: InkWell(
                onTap: item['onTap'] as VoidCallback,
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: isDark ? AppTheme.cardDark : Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isDark ? AppTheme.cardBorder : AppTheme.cardBorderLight,
                    ),
                    boxShadow: isDark
                        ? null
                        : [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.04),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(item['icon'] as IconData, color: color, size: 22),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              item['title'] as String,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white : AppTheme.textPrimaryLight,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              item['subtitle'] as String,
                              style: TextStyle(
                                fontSize: 11,
                                color: isDark ? AppTheme.textMuted : AppTheme.textMutedLight,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: isDark ? AppTheme.textMuted : AppTheme.textMutedLight,
                        size: 20,
                      ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }

  Widget _buildServiceSafetyNotice() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.accentAmber.withValues(alpha: 0.1) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppTheme.accentAmber.withValues(alpha: isDark ? 0.3 : 0.5),
        ),
        boxShadow: isDark
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.shield_outlined, color: AppTheme.accentAmber, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Yetkili Servis Güvenlik Uyarısı',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.accentAmber,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Yüksek gerilim (220V AC) hatlarında bağlantı yaparken ana sigortayı mutlaka kapatınız. 8 Röle ve 8 Dijital Giriş testleri tamamlandıktan sonra Servis Modundan "Devreye Alma Onayını" vermeyi unutmayınız.',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? AppTheme.textMuted : AppTheme.textMutedLight,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSuperUserHeaderCard(dynamic user) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.cardDark : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? AppTheme.accentCyan.withValues(alpha: 0.35)
              : AppTheme.accentCyan.withValues(alpha: 0.5),
        ),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? AppTheme.accentCyan.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.05),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.accentCyan.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.admin_panel_settings_rounded, color: AppTheme.accentCyan, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            user?.fullName?.isNotEmpty == true ? user!.fullName : 'Salih Ceylan',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : AppTheme.textPrimaryLight,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppTheme.accentCyan.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'SÜPER',
                            style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.accentCyan,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      user?.email?.isNotEmpty == true ? user!.email : 'salihceylan@gmail.com',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? AppTheme.textMuted : AppTheme.textMutedLight,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Sistem genelindeki yetkili servis yöneticilerini tanımlayabilir, montaj ekiplerini denetleyebilir ve altyapı bileşenlerini izleyebilirsiniz.',
            style: TextStyle(
              fontSize: 12.5,
              color: isDark ? AppTheme.textMuted : AppTheme.textMutedLight,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfrastructureStatusRow() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _buildStatusChip(
              icon: Icons.cloud_done_rounded,
              title: 'API Sunucusu',
              subtitle: 'Online (Port 5000)',
              color: AppTheme.accentGreen,
            ),
            _buildStatusChip(
              icon: Icons.storage_rounded,
              title: 'Veritabanı',
              subtitle: 'PostgreSQL 5434',
              color: AppTheme.accentGreen,
            ),
            _buildStatusChip(
              icon: Icons.hub_rounded,
              title: 'MQTT Köprüsü',
              subtitle: 'EMQX Aktif',
              color: AppTheme.accentGreen,
            ),
          ],
        );
      },
    );
  }

  Widget _buildStatusChip({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isDark ? color.withValues(alpha: 0.1) : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: isDark ? 0.3 : 0.45)),
        boxShadow: isDark
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color),
              ),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 9.5,
                  color: isDark ? AppTheme.textMuted : AppTheme.textMutedLight,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSuperUserMetricCards(Map<String, dynamic>? summary) {
    final serviceCount = summary?['total_service_managers'] ?? 1;
    final deviceCount = summary?['total_devices'] ?? 0;
    final homeCount = summary?['commissioned_homes_count'] ?? 0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 550;
        final cardWidth = isWide ? (constraints.maxWidth - 20) / 3 : (constraints.maxWidth - 10) / 2;

        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            SizedBox(
              width: cardWidth,
              child: _buildMetricCard(
                title: 'Servis Sorumluları',
                value: '$serviceCount',
                icon: Icons.admin_panel_settings,
                color: AppTheme.accentCyan,
                badgeText: 'YÖNETİCİ',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const ServiceManagementPage(initialTabIndex: 0),
                    ),
                  );
                },
              ),
            ),
            SizedBox(
              width: cardWidth,
              child: _buildMetricCard(
                title: 'Pano Envanteri',
                value: '$deviceCount',
                icon: Icons.inventory_2_outlined,
                color: AppTheme.accentAmber,
                badgeText: 'ENVANTER',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const DeviceInventoryPage(),
                    ),
                  );
                },
              ),
            ),
            SizedBox(
              width: isWide ? cardWidth : constraints.maxWidth,
              child: _buildMetricCard(
                title: 'Devreye Alınan',
                value: '$homeCount',
                icon: Icons.task_alt,
                color: AppTheme.accentGreen,
                badgeText: 'AKTİF DAİRE',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const ServiceManagementPage(initialTabIndex: 2),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildMetricCard({
    required String title,
    required String value,
    required IconData icon,
    required Color color,
    required String badgeText,
    VoidCallback? onTap,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.cardDark : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isDark ? color.withValues(alpha: 0.3) : color.withValues(alpha: 0.4),
          ),
          boxShadow: isDark
              ? null
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Icon(icon, color: color, size: 22),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    badgeText,
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              value,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : AppTheme.textPrimaryLight,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              title,
              style: TextStyle(
                fontSize: 12,
                color: isDark ? AppTheme.textMuted : AppTheme.textMutedLight,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSuperUserActionGrid(BuildContext context) {
    final actions = [
      {
        'title': 'Cihaz Envanteri & Ekleme',
        'subtitle': 'Fabrika panolarını tanımla, seri no & QR ekle/düzenle',
        'icon': Icons.inventory_2_outlined,
        'color': AppTheme.accentAmber,
        'onTap': () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DeviceInventoryPage()),
            ),
      },
      {
        'title': 'Servis Sorumluları Yönetimi',
        'subtitle': 'Yetkili servis sorumlularını sisteme ekle & düzenle',
        'icon': Icons.people_outline,
        'color': AppTheme.accentCyan,
        'onTap': () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ServiceManagementPage(initialTabIndex: 0)),
            ),
      },
      {
        'title': 'Sistem Doktoru (Sağlık & Teşhis)',
        'subtitle': 'Altyapı sağlığı, DB gecikmesi, MQTT köprüsü denetimi',
        'icon': Icons.health_and_safety_outlined,
        'color': Colors.cyanAccent,
        'onTap': () => SystemDoctorDialog.show(context),
      },
    ];

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 550;
        final itemWidth = isWide ? (constraints.maxWidth - 10) / 2 : constraints.maxWidth;

        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: actions.map((item) {
            final color = item['color'] as Color;
            return SizedBox(
              width: itemWidth,
              child: InkWell(
                onTap: item['onTap'] as VoidCallback,
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: isDark ? AppTheme.cardDark : Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isDark ? AppTheme.cardBorder : AppTheme.cardBorderLight,
                    ),
                    boxShadow: isDark
                        ? null
                        : [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.04),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(item['icon'] as IconData, color: color, size: 22),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item['title'] as String,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white : AppTheme.textPrimaryLight,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              item['subtitle'] as String,
                              style: TextStyle(
                                fontSize: 11,
                                color: isDark ? AppTheme.textMuted : AppTheme.textMutedLight,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.chevron_right,
                        size: 18,
                        color: isDark ? AppTheme.textMuted : AppTheme.textMutedLight,
                      ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }

  Widget _buildDrawerTipBox(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? AppTheme.cardBorder : AppTheme.cardBorderLight,
        ),
        boxShadow: isDark
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppTheme.accentCyan.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.menu_open_rounded, color: AppTheme.accentCyan, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Tüm yönetim araçlarına ve personel listelerine sol üstteki sandviç menüden (☰) de hızlıca ulaşabilirsiniz.',
              style: TextStyle(
                fontSize: 12,
                color: isDark ? AppTheme.textMuted : AppTheme.textMutedLight,
              ),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              side: const BorderSide(color: AppTheme.accentCyan),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Menüyü Aç', style: TextStyle(fontSize: 11.5, color: AppTheme.accentCyan)),
          ),
        ],
      ),
    );
  }

  Widget _buildUserAvatar(AutomationState state) {
    if (state.currentUser != null) {
      return CircleAvatar(
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
      );
    }
    return const Icon(Icons.account_circle_outlined, color: AppTheme.textMuted);
  }

  /// Daire Sakini & Müşteri Arayüzü (Mevcut Çalışan Daire Yönetimi)
  Widget _buildApartmentDashboard({
    required BuildContext context,
    required AutomationState state,
    required int activeLightCount,
    required int activeShutterCount,
    required bool isConnected,
    required bool isCloud,
    required dynamic status,
  }) {
    return RefreshIndicator(
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
    final state = Provider.of<AutomationState>(context);
    final isServiceOrSuper = state.isServiceManagerOrSuper;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.cardDark : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark ? AppTheme.cardBorder : Colors.black12,
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Colors.black.withValues(alpha: 0.3)
                : Colors.black.withValues(alpha: 0.05),
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
          Text(
            'Evinize Hoş Geldiniz!',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : AppTheme.textPrimaryLight,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          Text(
            'Akıllı panonuzun lamba ve panjurlarını yönetebilmek için pano kapağındaki karekodu tarayarak kurulumu tamamlayın.',
            style: TextStyle(
              fontSize: 14,
              color: isDark ? AppTheme.textMuted : AppTheme.textMutedLight,
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
              icon: Icon(
                Icons.keyboard_alt_outlined,
                size: 18,
                color: isDark ? AppTheme.textMuted : AppTheme.textMutedLight,
              ),
              label: Text(
                'Kodu Elle Gir (Manuel Eşleme)',
                style: TextStyle(
                  fontSize: 14,
                  color: isDark ? AppTheme.textPrimary : AppTheme.textPrimaryLight,
                ),
              ),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                side: BorderSide(
                  color: isDark ? AppTheme.cardBorder : Colors.black12,
                ),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          if (isServiceOrSuper) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.accentCyan.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.accentCyan.withValues(alpha: 0.3)),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        state.isSuperUser ? Icons.verified_user : Icons.engineering,
                        color: AppTheme.accentCyan,
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        state.isSuperUser ? 'Süper Yönetici Oturumu' : 'Servis Sorumlusu Oturumu',
                        style: const TextStyle(
                          color: AppTheme.accentCyan,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const ServiceManagementPage()),
                        );
                      },
                      icon: const Icon(Icons.admin_panel_settings_rounded, size: 18),
                      label: const Text(
                        'Süper Yönetici & Servis Paneline Git',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.accentCyan,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: isDark ? Colors.white : AppTheme.textPrimaryLight,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: isDark
                ? AppTheme.cardBorder.withValues(alpha: 0.4)
                : Colors.black.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isDark ? Colors.transparent : Colors.black12,
            ),
          ),
          child: Text(
            badge,
            style: TextStyle(
              fontSize: 11,
              color: isDark ? AppTheme.textMuted : AppTheme.textMutedLight,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  /// Dairesi olmayan yeni bireysel kullanıcı için basitleştirilmiş giriş ekranı.
  /// Yalnızca "Kod ile Bir Eve Katıl" seçeneğini gösterir.
  /// Kullanıcı bir eve katıldıktan sonra state güncellenir ve normal dashboard açılır.
  Widget _buildNoHomeIndividualDashboard(BuildContext context, AutomationState state) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final userName = state.currentUser?.fullName ?? state.currentUser?.email ?? 'Kullanıcı';

    return RefreshIndicator(
      onRefresh: () async => state.refresh(),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Karşılama Kartı ──────────────────────────────────────────
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    AppTheme.primaryBlue.withValues(alpha: isDark ? 0.18 : 0.10),
                    AppTheme.primaryBlueLight.withValues(alpha: isDark ? 0.08 : 0.04),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                color: isDark ? null : Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: AppTheme.primaryBlueLight.withValues(alpha: isDark ? 0.3 : 0.4),
                ),
                boxShadow: isDark
                    ? null
                    : [
                        BoxShadow(
                          color: AppTheme.primaryBlue.withValues(alpha: 0.06),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
              ),
              child: Column(
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppTheme.primaryBlue.withValues(alpha: 0.2),
                      border: Border.all(color: AppTheme.primaryBlueLight.withValues(alpha: 0.5), width: 1.5),
                    ),
                    child: const Icon(Icons.key_rounded, color: AppTheme.primaryBlueLight, size: 36),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Hoş Geldiniz, ${userName.split(' ').first}!',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : AppTheme.textPrimaryLight,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppTheme.accentAmber.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.accentAmber.withValues(alpha: 0.4)),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.info_outline, color: AppTheme.accentAmber, size: 14),
                        SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            'Henüz kayıtlı bir daireniz yok',
                            style: TextStyle(fontSize: 13, color: AppTheme.accentAmber),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 28),

            // ── Ev Katılım Butonu ─────────────────────────────────────────
            Text(
              'Daireye Katılmak İçin',
              style: TextStyle(
                fontSize: 13,
                color: isDark ? AppTheme.textMuted : AppTheme.textMutedLight,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.4,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),

            // Birincil: Kod ile Katıl
            FilledButton.icon(
              icon: const Icon(Icons.vpn_key_outlined, size: 20),
              label: const Text(
                'Kod ile Bir Eve Katıl',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.primaryBlue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: () async {
                final joined = await JoinHomeDialog.show(context);
                if (joined == true && context.mounted) {
                  state.refresh();
                }
              },
            ),

            const SizedBox(height: 12),

            // İkincil: QR Kodu ile Katıl
            OutlinedButton.icon(
              icon: const Icon(Icons.qr_code_scanner, size: 20),
              label: const Text('Karekod ile Katıl', style: TextStyle(fontSize: 15)),
              style: OutlinedButton.styleFrom(
                foregroundColor: isDark ? AppTheme.primaryBlueLight : AppTheme.primaryBlue,
                side: BorderSide(
                  color: isDark
                      ? AppTheme.primaryBlueLight.withValues(alpha: 0.5)
                      : AppTheme.primaryBlue.withValues(alpha: 0.5),
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: () async {
                final raw = await Navigator.push<String>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => QrScannerPage(
                      onManualFallback: () => JoinHomeDialog.show(context),
                    ),
                  ),
                );
                if (raw != null && raw.isNotEmpty && context.mounted) {
                  final trimmed = raw.trim();
                  if (trimmed.startsWith('AHBU-INVITE:') ||
                      (trimmed.startsWith('AHBU-') && !trimmed.contains(':'))) {
                    try {
                      final res = await state.joinHome(trimmed);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Row(children: [
                            const Icon(Icons.check_circle_outline, color: Colors.white, size: 20),
                            const SizedBox(width: 8),
                            Expanded(child: Text((res['message'] ?? 'Eve başarıyla katıldınız!').toString())),
                          ]),
                          backgroundColor: AppTheme.accentGreen,
                          duration: const Duration(seconds: 4),
                        ),
                      );
                      state.refresh();
                    } catch (e) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Katılım hatası: ${e.toString().replaceAll("Exception: ", "")}'),
                          backgroundColor: AppTheme.accentRed,
                        ),
                      );
                    }
                  } else {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Bu karekod bir eve katılım kodu değil. Lütfen ev sahibinden davet kodu alın.'),
                        backgroundColor: AppTheme.accentRed,
                      ),
                    );
                  }
                }
              },
            ),

            const SizedBox(height: 32),

            // ── Bilgilendirme Kartı ───────────────────────────────────────
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isDark ? AppTheme.cardDark : Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isDark ? AppTheme.cardBorder : Colors.black12,
                ),
                boxShadow: isDark
                    ? null
                    : [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.04),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.help_outline_rounded, color: AppTheme.accentCyan, size: 18),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          'Nasıl Daireye Katılırım?',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : AppTheme.textPrimaryLight,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _buildInstructionStep(
                    step: '1',
                    text: 'Dairenizin sahibinden veya yöneticisinden bir davet kodu alın.',
                    color: AppTheme.primaryBlueLight,
                    isDark: isDark,
                  ),
                  const SizedBox(height: 8),
                  _buildInstructionStep(
                    step: '2',
                    text: '"Kod ile Bir Eve Katıl" butonuna basın ve size iletilen kodu girin.',
                    color: AppTheme.accentCyan,
                    isDark: isDark,
                  ),
                  const SizedBox(height: 8),
                  _buildInstructionStep(
                    step: '3',
                    text: 'Katılım onaylandıktan sonra dairenizin tüm kontrolleri otomatik olarak açılacaktır.',
                    color: AppTheme.accentGreen,
                    isDark: isDark,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInstructionStep({
    required String step,
    required String text,
    required Color color,
    required bool isDark,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: 0.2),
            border: Border.all(color: color.withValues(alpha: 0.5)),
          ),
          child: Center(
            child: Text(
              step,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              color: isDark ? AppTheme.textMuted : AppTheme.textMutedLight,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}
