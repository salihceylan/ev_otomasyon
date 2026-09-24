import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/automation_state.dart';
import '../../services/ev_cloud_api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/circuit_background.dart';
import 'device_inventory_page.dart';
import 'replace_board_dialog.dart';
import 'service_mode_page.dart';
import 'system_doctor_dialog.dart';
import 'family/transfer_ownership_dialog.dart';

/// AHBU Akıllı Ev & Bina Otomasyonu
/// Süper Yönetici & Servis Sorumlusu Yönetim Paneli (ADIM 19)
class ServiceManagementPage extends StatefulWidget {
  final bool autoLoad;
  final int initialTabIndex;
  const ServiceManagementPage({
    super.key,
    this.autoLoad = true,
    this.initialTabIndex = 0,
  });

  @override
  State<ServiceManagementPage> createState() => _ServiceManagementPageState();
}

class _ServiceManagementPageState extends State<ServiceManagementPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  EvCloudApiService get _api => Provider.of<AutomationState>(context, listen: false).cloudApi;

  bool _isLoading = true;
  String? _errorMessage;
  Map<String, dynamic>? _summary;

  List<dynamic> _superAndServiceUsers = [];
  List<dynamic> _installers = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 3,
      vsync: this,
      initialIndex: widget.initialTabIndex.clamp(0, 2),
    );
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
    if (widget.autoLoad) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadAllData();
      });
    } else {
      _isLoading = false;
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadAllData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final state = Provider.of<AutomationState>(context, listen: false);
      final api = state.cloudApi;
      final isSuper = state.isSuperUser;

      // Paralel ve hataya dayanıklı istekler
      final summaryFuture = api.getServiceSummary().catchError((_) => <String, dynamic>{});
      final superUsersFuture = isSuper
          ? api.listAdminUsers(role: 'super_user').catchError((_) => <String, dynamic>{'users': []})
          : Future.value(<String, dynamic>{'users': []});
      final serviceUsersFuture = api.listAdminUsers(role: 'service_user').catchError((_) => <String, dynamic>{'users': []});
      final installersFuture = api.listAdminUsers(role: 'installer').catchError((_) => <String, dynamic>{'users': []});

      final results = await Future.wait([
        summaryFuture,
        superUsersFuture,
        serviceUsersFuture,
        installersFuture,
      ]);

      final summaryData = results[0] as Map<String, dynamic>;
      final superUsersRes = results[1] as Map<String, dynamic>;
      final serviceUsersRes = results[2] as Map<String, dynamic>;
      final installersRes = results[3] as Map<String, dynamic>;

      final List<dynamic> combinedManagers = [
        ...(superUsersRes['users'] as List? ?? []),
        ...(serviceUsersRes['users'] as List? ?? []),
      ];

      if (mounted) {
        setState(() {
          _summary = summaryData;
          _superAndServiceUsers = combinedManagers;
          _installers = installersRes['users'] as List? ?? [];
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
    final state = Provider.of<AutomationState>(context);
    final isSuper = state.isSuperUser;

    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Servis & Yönetici Paneli',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            SizedBox(height: 2),
            Text(
              'Güde Teknoloji • Yetkili Servis Ağı',
              style: TextStyle(
                fontSize: 11,
                color: AppTheme.accentCyan,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: AppTheme.accentCyan),
            tooltip: 'Yenile',
            onPressed: _loadAllData,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppTheme.accentCyan,
          indicatorWeight: 3,
          labelColor: Colors.white,
          unselectedLabelColor: AppTheme.textMuted,
          labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          tabs: const [
            Tab(
              icon: Icon(Icons.shield_outlined, size: 18),
              text: 'Sorumlular',
            ),
            Tab(
              icon: Icon(Icons.handyman_outlined, size: 18),
              text: 'Teknisyenler',
            ),
            Tab(
              icon: Icon(Icons.task_alt_rounded, size: 18),
              text: 'Görevler & Araçlar',
            ),
          ],
        ),
      ),
      body: CircuitBackground(
        child: SafeArea(
          child: _isLoading
              ? const Center(
                  child: CircularProgressIndicator(color: AppTheme.accentCyan),
                )
              : _errorMessage != null
                  ? _buildErrorView()
                  : TabBarView(
                      controller: _tabController,
                      children: [
                        _buildManagersTab(isSuper),
                        _buildInstallersTab(isSuper),
                        _buildTasksAndToolsTab(context),
                      ],
                    ),
        ),
      ),
      floatingActionButton: _buildFloatingActionButton(isSuper),
    );
  }

  Widget? _buildFloatingActionButton(bool isSuper) {
    if (_tabController.index == 0) {
      if (!isSuper) return null; // Servis sorumlusu sorumlu ekleyemez!
      return FloatingActionButton.extended(
        onPressed: () => _openCreateUserDialog(context, isSuper, defaultRole: 'service_user'),
        backgroundColor: AppTheme.accentCyan,
        icon: const Icon(Icons.person_add_alt_1_rounded, color: Colors.black),
        label: const Text(
          'Sorumlu Ekle',
          style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
        ),
      );
    } else if (_tabController.index == 1) {
      return FloatingActionButton.extended(
        onPressed: () => _openCreateUserDialog(context, isSuper, defaultRole: 'installer'),
        backgroundColor: Colors.amberAccent,
        icon: const Icon(Icons.engineering_rounded, color: Colors.black),
        label: const Text(
          'Teknisyen Ekle',
          style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
        ),
      );
    }
    return null;
  }

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 48),
            const SizedBox(height: 12),
            Text(
              _errorMessage ?? 'Bilinmeyen bir hata oluştu',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _loadAllData,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Tekrar Dene'),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accentCyan),
            ),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // TAB 1: SÜPER VE SERVİS SORUMLULARI
  // ===========================================================================
  Widget _buildManagersTab(bool isSuper) {
    return RefreshIndicator(
      onRefresh: _loadAllData,
      color: AppTheme.accentCyan,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
        children: [
          _buildMetricsOverview(),
          const SizedBox(height: 16),
          if (!isSuper) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.accentCyan.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.accentCyan.withValues(alpha: 0.3)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline_rounded, color: AppTheme.accentCyan, size: 20),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Servis sorumlusu ve yönetici hesapları yalnızca Süper Yönetici tarafından tanımlanabilir ve yönetilebilir.',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Süper Yöneticiler & Servis Sorumluları',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceDark,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white10),
                ),
                child: Text(
                  '${_superAndServiceUsers.length} Yetkili',
                  style: const TextStyle(color: AppTheme.accentCyan, fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_superAndServiceUsers.isEmpty)
            _buildEmptyState('Kayıtlı servis sorumlusu veya süper kullanıcı bulunamadı.')
          else
            ..._superAndServiceUsers.map((u) => _buildUserCard(u, isSuper)),
        ],
      ),
    );
  }

  // ===========================================================================
  // TAB 2: SAHA TEKNİSYENLERİ
  // ===========================================================================
  Widget _buildInstallersTab(bool isSuper) {
    return RefreshIndicator(
      onRefresh: _loadAllData,
      color: AppTheme.accentCyan,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Saha Montaj & Servis Teknisyenleri',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceDark,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white10),
                ),
                child: Text(
                  '${_installers.length} Teknisyen',
                  style: const TextStyle(color: AppTheme.accentPurple, fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_installers.isEmpty)
            _buildEmptyState('Henüz saha teknisyeni kaydı yapılmamış.')
          else
            ..._installers.map((u) => _buildUserCard(u, isSuper)),
        ],
      ),
    );
  }

  // ===========================================================================
  // TAB 3: SERVİS GÖREVLERİ & ARAÇLARI
  // ===========================================================================
  Widget _buildTasksAndToolsTab(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
      children: [
        const Text(
          'Tanımlı Servis Görevleri & Eylemleri',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Servis sorumluları ve teknisyenlerin sahada yürüteceği görevler aşağıda gruplanmıştır:',
          style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
        ),
        const SizedBox(height: 16),

        _buildTaskCard(
          icon: Icons.inventory_2_outlined,
          color: Colors.amberAccent,
          title: '1. Cihaz Envanteri & Fabrika Kaydı',
          description:
              'Üretimden çıkan ESP32-S3 panolarının UUID, Setup PIN ve model bilgilerini sistem envanterine işleyin.',
          buttonLabel: 'Envanter İşlemleri',
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DeviceInventoryPage()),
            );
          },
        ),

        const SizedBox(height: 12),
        _buildTaskCard(
          icon: Icons.verified_outlined,
          color: AppTheme.accentCyan,
          title: '2. Devreye Alma (Commissioning) Onayı',
          description:
              'Daireye montajı biten panonun tüm lamba, panjur ve opto-izole DI girişlerini test edip devreye alma raporunu onaylayın.',
          buttonLabel: 'Devreye Alma Sihirbazı',
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ServiceModePage()),
            );
          },
        ),

        const SizedBox(height: 12),
        _buildTaskCard(
          icon: Icons.sync_problem_rounded,
          color: Colors.redAccent,
          title: '3. Acil Servis Sıfırlaması & Daire Devri',
          description:
              'Eski kiracı veya ev sahibine ulaşılamadığında; fiziksel mülk doğrulamasıyla panoyu güvenle boşa çıkarıp yeni daireye atayın.',
          buttonLabel: 'Acil Sıfırlama & Devir',
          onTap: () {
            showDialog(
              context: context,
              builder: (_) => const TransferOwnershipDialog(),
            );
          },
        ),

        const SizedBox(height: 12),
        _buildTaskCard(
          icon: Icons.medical_services_outlined,
          color: Colors.tealAccent,
          title: '4. Buluttan Tek Tıkla Pano Değişimi (Disaster Recovery)',
          description:
              'Yıldırım veya arıza sebebiyle değişen panonun tüm 40 röle, isim ve kalibrasyon yedeğini 5 saniyede yeni panoya aktarın.',
          buttonLabel: 'Pano Değişimi Aç',
          onTap: () {
            showDialog(
              context: context,
              builder: (_) => const ReplaceBoardDialog(),
            );
          },
        ),

        const SizedBox(height: 12),
        _buildTaskCard(
          icon: Icons.health_and_safety_outlined,
          color: Colors.blueAccent,
          title: '5. Sistem Doktoru (Otomatik Donanım Teşhisi)',
          description:
              'MQTTS bulut, yerel Wi-Fi ve pano güç katmanlarını tek tıkla test ederek arıza kaynağını milisaniyede belirleyin.',
          buttonLabel: 'Sistem Doktorunu Çalıştır',
          onTap: () {
            showDialog(
              context: context,
              builder: (_) => const SystemDoctorDialog(),
            );
          },
        ),
      ],
    );
  }

  // ===========================================================================
  // WIDGET HELPER METODLARI
  // ===========================================================================

  Widget _buildMetricsOverview() {
    final users = _summary?['users'] as Map<String, dynamic>?;
    final devices = _summary?['devices'] as Map<String, dynamic>?;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surfaceDark.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Sistem & Servis Genel Durumu',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white70),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _buildMiniStat(
                label: 'Süper',
                value: '${users?['super_users'] ?? 0}',
                color: AppTheme.accentPurple,
                icon: Icons.shield_rounded,
              ),
              const SizedBox(width: 8),
              _buildMiniStat(
                label: 'Servis',
                value: '${users?['service_users'] ?? 0}',
                color: AppTheme.accentCyan,
                icon: Icons.verified_user_rounded,
              ),
              const SizedBox(width: 8),
              _buildMiniStat(
                label: 'Teknisyen',
                value: '${users?['installers'] ?? 0}',
                color: Colors.amberAccent,
                icon: Icons.engineering_rounded,
              ),
              const SizedBox(width: 8),
              _buildMiniStat(
                label: 'Pano',
                value: '${devices?['total_devices'] ?? 0}',
                color: Colors.greenAccent,
                icon: Icons.router_rounded,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMiniStat({
    required String label,
    required String value,
    required Color color,
    required IconData icon,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(fontSize: 10, color: Colors.white70),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUserCard(Map<String, dynamic> user, bool isSuper) {
    final role = user['role']?.toString() ?? 'user';
    final isActive = user['is_active'] == true;
    final fullName = user['full_name']?.toString() ?? 'İsimsiz';
    final email = user['email']?.toString() ?? '';
    final phone = user['phone']?.toString() ?? '';
    final adminNotes = user['admin_notes']?.toString();
    final userId = user['id']?.toString() ?? '';

    Color badgeColor;
    String badgeText;
    IconData badgeIcon;

    switch (role) {
      case 'super_user':
        badgeColor = AppTheme.accentPurple;
        badgeText = 'SÜPER YÖNETİCİ';
        badgeIcon = Icons.shield_rounded;
        break;
      case 'service_user':
        badgeColor = AppTheme.accentCyan;
        badgeText = 'SERVİS SORUMLUSU';
        badgeIcon = Icons.verified_user_rounded;
        break;
      case 'installer':
        badgeColor = Colors.amberAccent;
        badgeText = 'SAHA TEKNİSYENİ';
        badgeIcon = Icons.engineering_rounded;
        break;
      default:
        badgeColor = Colors.grey;
        badgeText = 'STANDART KULLANICI';
        badgeIcon = Icons.person_rounded;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: AppTheme.surfaceDark.withValues(alpha: 0.85),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isActive ? badgeColor.withValues(alpha: 0.3) : Colors.redAccent.withValues(alpha: 0.3),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: badgeColor.withValues(alpha: 0.2),
                  child: Icon(badgeIcon, color: badgeColor, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        fullName,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        email,
                        style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: badgeColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: badgeColor.withValues(alpha: 0.4)),
                  ),
                  child: Text(
                    badgeText,
                    style: TextStyle(
                      color: badgeColor,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            if (phone.isNotEmpty || (adminNotes != null && adminNotes.isNotEmpty)) ...[
              const SizedBox(height: 10),
              Divider(color: Colors.white.withValues(alpha: 0.08), height: 1),
              const SizedBox(height: 8),
              if (phone.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      const Icon(Icons.phone_outlined, size: 14, color: AppTheme.textMuted),
                      const SizedBox(width: 6),
                      Text(phone, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    ],
                  ),
                ),
              if (adminNotes != null && adminNotes.isNotEmpty)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.sticky_note_2_outlined, size: 14, color: AppTheme.textMuted),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        adminNotes,
                        style: const TextStyle(color: Colors.white54, fontSize: 11, fontStyle: FontStyle.italic),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
            ],
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isActive ? Colors.greenAccent : Colors.redAccent,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      isActive ? 'Aktif Hesap' : 'Pasife Alınmış',
                      style: TextStyle(
                        fontSize: 11,
                        color: isActive ? Colors.greenAccent : Colors.redAccent,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                if (isSuper || (role != 'super_user' && role != 'service_user'))
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 18, color: AppTheme.textMuted),
                        tooltip: 'Düzenle & Şifre Değiştir',
                        onPressed: () => _openEditUserDialog(context, user, isSuper),
                      ),
                      IconButton(
                        icon: Icon(
                          isActive ? Icons.block_outlined : Icons.check_circle_outline,
                          size: 18,
                          color: isActive ? Colors.amberAccent : Colors.greenAccent,
                        ),
                        tooltip: isActive ? 'Hesabı Dondur' : 'Hesabı Aktifleştir',
                        onPressed: () => _toggleUserStatus(userId, role, !isActive, isSuper),
                      ),
                    ],
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white10,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'Salt Okunur',
                      style: TextStyle(fontSize: 10, color: Colors.white54, fontWeight: FontWeight.bold),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTaskCard({
    required IconData icon,
    required Color color,
    required String title,
    required String description,
    required String buttonLabel,
    required VoidCallback onTap,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surfaceDark.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            description,
            style: const TextStyle(fontSize: 12, color: AppTheme.textMuted, height: 1.4),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton.icon(
              onPressed: onTap,
              icon: Icon(Icons.arrow_forward_rounded, size: 16, color: Colors.black),
              label: Text(
                buttonLabel,
                style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 12),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: color,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 16),
      alignment: Alignment.center,
      child: Column(
        children: [
          const Icon(Icons.groups_outlined, size: 40, color: Colors.white24),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // DİYALOGLAR (EKLEME / DÜZENLEME)
  // ===========================================================================

  void _openCreateUserDialog(BuildContext context, bool isSuper, {String? defaultRole}) {
    final nameCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final notesCtrl = TextEditingController();

    // Sorumlu ekleme yetkisi sadece Süper Kullanıcıya aittir.
    // Servis sorumlusu sadece saha teknisyeni veya daire kullanıcısı ekleyebilir.
    String selectedRole = defaultRole ?? (isSuper ? 'service_user' : 'installer');
    if (!isSuper && (selectedRole == 'super_user' || selectedRole == 'service_user')) {
      selectedRole = 'installer';
    }

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            backgroundColor: AppTheme.surfaceDark,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: const BorderSide(color: AppTheme.accentCyan, width: 1.5),
            ),
            title: Text(
              isSuper
                  ? (selectedRole == 'service_user' || selectedRole == 'super_user'
                      ? 'Yeni Servis Sorumlusu / Yönetici Ekle'
                      : 'Yeni Saha Teknisyeni / Müşteri Ekle')
                  : 'Yeni Saha Teknisyeni / Müşteri Ekle',
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Rol / Yetki Tipi:', style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: Colors.black26,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: selectedRole,
                        dropdownColor: AppTheme.surfaceDark,
                        isExpanded: true,
                        items: [
                          if (isSuper) ...[
                            const DropdownMenuItem(
                              value: 'super_user',
                              child: Text('👑 Süper Yönetici (super_user)', style: TextStyle(color: AppTheme.accentPurple)),
                            ),
                            const DropdownMenuItem(
                              value: 'service_user',
                              child: Text('🛠️ Servis Sorumlusu (service_user)', style: TextStyle(color: AppTheme.accentCyan)),
                            ),
                          ],
                          const DropdownMenuItem(
                            value: 'installer',
                            child: Text('👷 Saha Teknisyeni (installer)', style: TextStyle(color: Colors.amberAccent)),
                          ),
                          const DropdownMenuItem(
                            value: 'user',
                            child: Text('👤 Daire Sakini / Müşteri (user)', style: TextStyle(color: Colors.white70)),
                          ),
                        ],
                        onChanged: (val) {
                          if (val != null) setDialogState(() => selectedRole = val);
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: nameCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Ad Soyad',
                      labelStyle: const TextStyle(color: AppTheme.textMuted),
                      prefixIcon: const Icon(Icons.person_outline, color: AppTheme.accentCyan, size: 20),
                      filled: true,
                      fillColor: Colors.black26,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'E-posta Adresi',
                      labelStyle: const TextStyle(color: AppTheme.textMuted),
                      prefixIcon: const Icon(Icons.email_outlined, color: AppTheme.accentCyan, size: 20),
                      filled: true,
                      fillColor: Colors.black26,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: passCtrl,
                    obscureText: true,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Şifre (En az 6 karakter)',
                      labelStyle: const TextStyle(color: AppTheme.textMuted),
                      prefixIcon: const Icon(Icons.lock_outline, color: AppTheme.accentCyan, size: 20),
                      filled: true,
                      fillColor: Colors.black26,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: phoneCtrl,
                    keyboardType: TextInputType.phone,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Telefon Numarası (Opsiyonel)',
                      labelStyle: const TextStyle(color: AppTheme.textMuted),
                      prefixIcon: const Icon(Icons.phone_outlined, color: AppTheme.accentCyan, size: 20),
                      filled: true,
                      fillColor: Colors.black26,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: notesCtrl,
                    maxLines: 2,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Görev / Bölge Notu (Opsiyonel)',
                      labelStyle: const TextStyle(color: AppTheme.textMuted),
                      prefixIcon: const Icon(Icons.notes_rounded, color: AppTheme.accentCyan, size: 20),
                      filled: true,
                      fillColor: Colors.black26,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('İptal', style: TextStyle(color: Colors.white60)),
              ),
              ElevatedButton(
                onPressed: () async {
                  if (nameCtrl.text.trim().isEmpty ||
                      emailCtrl.text.trim().isEmpty ||
                      passCtrl.text.trim().isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Lütfen ad soyad, e-posta ve şifre alanlarını doldurun.')),
                    );
                    return;
                  }

                  if (!isSuper && (selectedRole == 'super_user' || selectedRole == 'service_user')) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Servis sorumluları veya süper kullanıcılar yalnızca Süper Yönetici tarafından tanımlanabilir.')),
                    );
                    return;
                  }

                  final messenger = ScaffoldMessenger.of(context);
                  Navigator.pop(ctx);
                  try {
                    await _api.createAdminUser(
                      fullName: nameCtrl.text.trim(),
                      email: emailCtrl.text.trim(),
                      password: passCtrl.text.trim(),
                      phone: phoneCtrl.text.trim().isNotEmpty ? phoneCtrl.text.trim() : null,
                      role: selectedRole,
                      adminNotes: notesCtrl.text.trim().isNotEmpty ? notesCtrl.text.trim() : null,
                    );
                    if (mounted) {
                      messenger.showSnackBar(
                        SnackBar(content: Text('${nameCtrl.text.trim()} başarıyla sisteme eklendi.')),
                      );
                    }
                    _loadAllData();
                  } catch (e) {
                    if (mounted) {
                      messenger.showSnackBar(
                        SnackBar(content: Text('Hata: ${e.toString().replaceAll("Exception: ", "")}')),
                      );
                    }
                  }
                },
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accentCyan),
                child: const Text('Kaydet', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  void _openEditUserDialog(BuildContext context, Map<String, dynamic> user, bool isSuper) {
    final role = user['role']?.toString() ?? 'user';
    if (!isSuper && (role == 'super_user' || role == 'service_user')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Servis sorumlusu hesapları yalnızca Süper Yönetici tarafından düzenlenebilir.')),
      );
      return;
    }

    final userId = user['id']?.toString() ?? '';
    final nameCtrl = TextEditingController(text: user['full_name']?.toString() ?? '');
    final phoneCtrl = TextEditingController(text: user['phone']?.toString() ?? '');
    final notesCtrl = TextEditingController(text: user['admin_notes']?.toString() ?? '');
    final newPassCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            backgroundColor: AppTheme.surfaceDark,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: const BorderSide(color: AppTheme.accentPurple, width: 1.5),
            ),
            title: Text(
              '${user['full_name']} Düzenle',
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Ad Soyad',
                      labelStyle: const TextStyle(color: AppTheme.textMuted),
                      prefixIcon: const Icon(Icons.person_outline, color: AppTheme.accentPurple, size: 20),
                      filled: true,
                      fillColor: Colors.black26,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: phoneCtrl,
                    keyboardType: TextInputType.phone,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Telefon Numarası',
                      labelStyle: const TextStyle(color: AppTheme.textMuted),
                      prefixIcon: const Icon(Icons.phone_outlined, color: AppTheme.accentPurple, size: 20),
                      filled: true,
                      fillColor: Colors.black26,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: newPassCtrl,
                    obscureText: true,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Yeni Şifre (Değiştirmeyecekseniz boş bırakın)',
                      labelStyle: const TextStyle(color: AppTheme.textMuted),
                      prefixIcon: const Icon(Icons.key_outlined, color: AppTheme.accentPurple, size: 20),
                      filled: true,
                      fillColor: Colors.black26,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: notesCtrl,
                    maxLines: 2,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Görev / Bölge Notu',
                      labelStyle: const TextStyle(color: AppTheme.textMuted),
                      prefixIcon: const Icon(Icons.notes_rounded, color: AppTheme.accentPurple, size: 20),
                      filled: true,
                      fillColor: Colors.black26,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('İptal', style: TextStyle(color: Colors.white60)),
              ),
              ElevatedButton(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  Navigator.pop(ctx);
                  try {
                    await _api.updateAdminUser(
                      userId,
                      fullName: nameCtrl.text.trim(),
                      phone: phoneCtrl.text.trim().isNotEmpty ? phoneCtrl.text.trim() : null,
                      adminNotes: notesCtrl.text.trim().isNotEmpty ? notesCtrl.text.trim() : null,
                      password: newPassCtrl.text.trim().isNotEmpty ? newPassCtrl.text.trim() : null,
                    );
                    if (mounted) {
                      messenger.showSnackBar(
                        const SnackBar(content: Text('Kullanıcı bilgileri başarıyla güncellendi.')),
                      );
                    }
                    _loadAllData();
                  } catch (e) {
                    if (mounted) {
                      messenger.showSnackBar(
                        SnackBar(content: Text('Hata: ${e.toString().replaceAll("Exception: ", "")}')),
                      );
                    }
                  }
                },
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accentPurple),
                child: const Text('Güncelle', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _toggleUserStatus(String userId, String userRole, bool newStatus, bool isSuper) async {
    if (!isSuper && (userRole == 'super_user' || userRole == 'service_user')) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Servis sorumlusu hesapları yalnızca Süper Yönetici tarafından dondurulabilir veya aktifleştirilebilir.')),
        );
      }
      return;
    }
    try {
      await _api.updateAdminUser(userId, isActive: newStatus);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(newStatus ? 'Kullanıcı hesabı aktif edildi.' : 'Kullanıcı hesabı donduruldu/pasife alındı.'),
          ),
        );
      }
      _loadAllData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Hata: ${e.toString().replaceAll("Exception: ", "")}')),
        );
      }
    }
  }
}
