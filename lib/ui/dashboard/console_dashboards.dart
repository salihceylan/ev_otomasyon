import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/capabilities.dart';
import '../../models/json_utils.dart';
import '../../services/automation_state.dart';
import '../../utils/friendly_error.dart';
import '../pages/device_inventory_page.dart';
import '../pages/family/transfer_ownership_dialog.dart';
import '../pages/replace_board_dialog.dart';
import '../pages/service_management_page.dart';
import '../pages/service_mode_page.dart';
import '../pages/service_subscribers_page.dart';
import '../pages/system_doctor_dialog.dart';
import '../pages/wifi_recovery_dialog.dart';
import '../theme/app_theme.dart';

/// Süper yönetici sayaçları (`GET /admin/service-summary` -> `users` / `devices` / `homes`).
/// Yüklenmemiş sayaç `null`'dır ve arayüzde "—" gösterilir (uydurma `0` yok).
class ConsoleCounts {
  const ConsoleCounts({
    this.serviceManagers,
    this.superUsers,
    this.devices,
    this.commissioned,
    this.homes,
  });

  final int? serviceManagers;
  final int? superUsers;
  final int? devices;
  final int? commissioned;
  final int? homes;

  /// Sunucunun iç içe yanıtını (`users.service_users`, `devices.total_devices`,
  /// `devices.commissioned_devices` ...) çözer; eski düz anahtarlar yedek olarak okunur.
  factory ConsoleCounts.fromSummary(Map<String, dynamic> json) {
    final users = asMap(json['users']);
    final devices = asMap(json['devices']);
    final homes = asMap(json['homes']);
    return ConsoleCounts(
      serviceManagers: asInt(users?['service_users'] ?? json['total_service_managers']),
      superUsers: asInt(users?['super_users']),
      devices: asInt(devices?['total_devices'] ?? json['total_devices']),
      commissioned: asInt(devices?['commissioned_devices'] ?? json['commissioned_homes_count']),
      homes: asInt(homes?['total_homes']),
    );
  }
}

String _countText(int? value) => value == null ? '—' : '$value';

// =============================================================================
// Süper yönetici konsolu
// =============================================================================

/// Süper yönetici konsolu (daire kontrollerinden arındırılmış). Sayaçlar sunucudan yüklenir;
/// yüklenemezse "—" ve yeniden dene gösterilir. Sabit altyapı satırı yoktur.
class SuperConsole extends StatefulWidget {
  const SuperConsole({super.key});

  @override
  State<SuperConsole> createState() => _SuperConsoleState();
}

class _SuperConsoleState extends State<SuperConsole> {
  ConsoleCounts? _counts;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  Future<void> _load() async {
    if (_loading) return;
    final state = context.read<AutomationState>();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final json = await state.cloudApi.getServiceSummary().timeout(const Duration(seconds: 20));
      if (!mounted) return;
      setState(() {
        _counts = ConsoleCounts.fromSummary(json);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyError(e, fallback: 'Sayaçlar yüklenemedi. Lütfen tekrar deneyin.');
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AutomationState>();
    final caps = context.select<AutomationState, Capabilities>((s) => s.capabilities);
    final counts = _counts;

    return RefreshIndicator(
      onRefresh: () async {
        await state.refresh();
        await _load();
      },
      child: SingleChildScrollView(
        key: const Key('view_super_console'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _ConsoleHeader(
              badge: 'SÜPER',
              fallbackName: 'Süper Yönetici',
              description: 'Sistem genelindeki yetkili servis yöneticilerini tanımlayabilir, montaj '
                  'ekiplerini denetleyebilir ve cihaz envanterini yönetebilirsiniz.',
              icon: Icons.admin_panel_settings_rounded,
            ),
            const SizedBox(height: 16),
            if (_error != null) ...[
              _CountersError(message: _error!, onRetry: _load),
              const SizedBox(height: 12),
            ],
            _MetricGrid(
              loading: _loading && counts == null,
              cards: [
                _Metric(
                  cardKey: const Key('card_metric_service_managers'),
                  title: 'Servis Sorumluları',
                  value: _countText(counts?.serviceManagers),
                  icon: Icons.admin_panel_settings,
                  color: AppTheme.accentCyan,
                  badge: 'YÖNETİCİ',
                  onTap: caps.canManageAdminAccounts
                      ? () => _push(context, const ServiceManagementPage(initialTabIndex: 0))
                      : null,
                ),
                _Metric(
                  cardKey: const Key('card_metric_devices'),
                  title: 'Pano Envanteri',
                  value: _countText(counts?.devices),
                  icon: Icons.inventory_2_outlined,
                  color: AppTheme.accentAmber,
                  badge: 'ENVANTER',
                  onTap: caps.canManageInventory ? () => _push(context, const DeviceInventoryPage()) : null,
                ),
                _Metric(
                  cardKey: const Key('card_metric_commissioned'),
                  title: 'Devreye Alınan',
                  value: _countText(counts?.commissioned),
                  icon: Icons.task_alt,
                  color: AppTheme.accentGreen,
                  badge: 'AKTİF PANO',
                  onTap: caps.canManageAdminAccounts
                      ? () => _push(context, const ServiceManagementPage(initialTabIndex: 2))
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 24),
            // Dar ekran / büyük yazı: düğme başlığın altına iner (taşma yok).
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              runSpacing: 4,
              children: [
                Text(
                  'Hızlı Yönetici İşlemleri',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.getTextPrimary(context),
                  ),
                ),
                if (caps.canOpenServiceManagement)
                  TextButton.icon(
                    key: const Key('btn_open_service_management'),
                    style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: () => _push(context, const ServiceManagementPage()),
                    icon: const Icon(Icons.arrow_forward_rounded, size: 16),
                    label: const Text('Tüm Paneli Aç', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            _ActionGrid(
              actions: [
                if (caps.canManageInventory)
                  _Action(
                    cardKey: const Key('card_action_inventory'),
                    title: 'Cihaz Envanteri & Ekleme',
                    subtitle: 'Fabrika panolarını tanımla, seri no & QR ekle/düzenle',
                    icon: Icons.inventory_2_outlined,
                    color: AppTheme.accentAmber,
                    onTap: () => _push(context, const DeviceInventoryPage()),
                  ),
                if (caps.canManageAdminAccounts)
                  _Action(
                    cardKey: const Key('card_action_service_managers'),
                    title: 'Servis Sorumluları Yönetimi',
                    subtitle: 'Yetkili servis sorumlularını sisteme ekle & düzenle',
                    icon: Icons.people_outline,
                    color: AppTheme.accentCyan,
                    onTap: () => _push(context, const ServiceManagementPage(initialTabIndex: 0)),
                  ),
                if (caps.canViewInventory)
                  _Action(
                    cardKey: const Key('card_action_subscribers'),
                    title: 'Tüm Aboneler & Atamalar',
                    subtitle: 'Daireler, panolar ve Home Admin listesi',
                    icon: Icons.people_alt_outlined,
                    color: AppTheme.accentGreen,
                    onTap: () => _push(context, const ServiceSubscribersPage()),
                  ),
                _Action(
                  cardKey: const Key('card_action_doctor'),
                  title: 'Sistem Doktoru (Sağlık & Teşhis)',
                  subtitle: 'Altyapı sağlığı, DB gecikmesi, MQTT köprüsü denetimi',
                  icon: Icons.health_and_safety_outlined,
                  color: Colors.cyanAccent,
                  onTap: () => SystemDoctorDialog.show(context),
                ),
              ],
            ),
            const SizedBox(height: 20),
            const _DrawerTip(),
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Yetkili servis konsolu
// =============================================================================

/// Kalıcı servis personeli konsolu (saha & montaj odaklı). Sayaçlar yetkili olunan kendi
/// kapsamından gelir (envanter stoğu + aboneler); yüklenmemişse "—".
class ServiceConsole extends StatefulWidget {
  const ServiceConsole({super.key});

  @override
  State<ServiceConsole> createState() => _ServiceConsoleState();
}

class _ServiceConsoleState extends State<ServiceConsole> {
  bool _loading = false;
  bool _loadedOnce = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  Future<void> _load() async {
    if (_loading) return;
    final state = context.read<AutomationState>();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await Future.wait<void>([
        state.fetchInventory(),
        state.fetchServiceSubscribers(),
      ]).timeout(const Duration(seconds: 20));
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadedOnce = state.inventoryError == null && state.subscribersError == null;
        _error = state.inventoryError ?? state.subscribersError;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e, fallback: 'Sayaçlar yüklenemedi. Lütfen tekrar deneyin.');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AutomationState>();
    final caps = context.select<AutomationState, Capabilities>((s) => s.capabilities);
    final counts = context.select<AutomationState, ({int? devices, int? subscribers})>(
      (s) => (
        devices: _loadedOnce ? s.inventoryStats['total'] : null,
        subscribers: _loadedOnce ? s.serviceSubscribers.length : null,
      ),
    );

    return RefreshIndicator(
      onRefresh: () async {
        await state.refresh();
        await _load();
      },
      child: SingleChildScrollView(
        key: const Key('view_service_console'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _ConsoleHeader(
              badge: 'YETKİLİ SERVİS',
              fallbackName: 'Yetkili Servis Sorumlusu',
              description: 'Müşteri dairelerinde pano kurulumu, devreye alma ve saha desteği '
                  'işlemlerini buradan yürütebilirsiniz.',
              icon: Icons.engineering_rounded,
            ),
            const SizedBox(height: 16),
            if (_error != null) ...[
              _CountersError(message: _error!, onRetry: _load),
              const SizedBox(height: 12),
            ],
            _MetricGrid(
              loading: _loading && !_loadedOnce,
              cards: [
                _Metric(
                  cardKey: const Key('card_metric_devices'),
                  title: 'Pano Envanteri',
                  value: _countText(counts.devices),
                  icon: Icons.inventory_2_outlined,
                  color: AppTheme.accentCyan,
                  badge: 'STOK & PANO',
                  onTap: null,
                ),
                _Metric(
                  cardKey: const Key('card_metric_commissioned'),
                  title: 'Devreye Alınan',
                  value: _countText(counts.subscribers),
                  icon: Icons.task_alt,
                  color: AppTheme.accentGreen,
                  badge: 'ABONE DAİRE',
                  onTap: caps.canViewInventory ? () => _push(context, const ServiceSubscribersPage()) : null,
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(
              'Saha Servis & Devreye Alma Görevleri',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: AppTheme.getTextPrimary(context),
              ),
            ),
            const SizedBox(height: 8),
            _ActionGrid(
              actions: [
                _Action(
                  cardKey: const Key('card_action_commissioning'),
                  title: 'Devreye Alma (Servis Modu)',
                  subtitle: 'Pano karekod eşleme, müşteri OTP onayı, canlı testler ve devreye alma',
                  icon: Icons.verified_outlined,
                  color: AppTheme.accentCyan,
                  onTap: () => _push(context, const ServiceModePage()),
                ),
                if (caps.canViewInventory)
                  _Action(
                    cardKey: const Key('card_action_subscribers'),
                    title: 'Abonelerim & Cihaz Atama',
                    subtitle: 'Kayıtlı panolar ve Home Admin atama',
                    icon: Icons.people_alt_outlined,
                    color: AppTheme.accentGreen,
                    onTap: () => _push(context, const ServiceSubscribersPage()),
                  ),
                _Action(
                  cardKey: const Key('card_action_replace_board'),
                  title: 'Pano Değişimi (Afet & Hasar)',
                  subtitle: 'Arızalı panonun kimliğini yenisiyle değiştirip daire verilerini aktarın',
                  icon: Icons.published_with_changes_outlined,
                  color: Colors.tealAccent,
                  onTap: () => ReplaceBoardDialog.show(context),
                ),
                _Action(
                  cardKey: const Key('card_action_wifi_recovery'),
                  title: 'Wi-Fi Yapılandırma & Kurtarma',
                  subtitle: 'Modem değişikliğinde panoya yeni Wi-Fi bilgisini aktarın',
                  icon: Icons.wifi_find_rounded,
                  color: Colors.orangeAccent,
                  onTap: () => WifiRecoveryDialog.show(context),
                ),
                if (caps.canEmergencyReset)
                  _Action(
                    cardKey: const Key('card_action_emergency_reset'),
                    title: 'Acil Sıfırlama',
                    subtitle: 'Eski sahibine ulaşılamayan panoyu sıfırlayıp yeniden eşleyin',
                    icon: Icons.sync_problem_rounded,
                    color: Colors.redAccent,
                    onTap: () => TransferOwnershipDialog.show(context, initialTab: 1),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            const _SafetyNotice(),
            const SizedBox(height: 16),
            const _DrawerTip(),
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Ortak parçalar
// =============================================================================

void _push(BuildContext context, Widget page) {
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
}

class _ConsoleHeader extends StatelessWidget {
  const _ConsoleHeader({
    required this.badge,
    required this.fallbackName,
    required this.description,
    required this.icon,
  });

  final String badge;
  final String fallbackName;
  final String description;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final user = context.select<AutomationState, ({String name, String email})>(
      (s) => (name: s.currentUser?.fullName ?? '', email: s.currentUser?.email ?? ''),
    );
    final name = user.name.trim().isEmpty ? fallbackName : user.name.trim();
    final accent = AppTheme.accentCyan;
    final readable = AppTheme.readableAccent(context, accent);

    return Container(
      key: const Key('card_console_header'),
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: AppTheme.cardDecoration(context, accent: accent, radius: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: readable, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          name,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.getTextPrimary(context),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            badge,
                            style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.bold,
                              color: readable,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (user.email.trim().isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        user.email.trim(),
                        style: TextStyle(fontSize: 12, color: AppTheme.getTextMuted(context)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            description,
            style: TextStyle(fontSize: 12.5, height: 1.35, color: AppTheme.getTextMuted(context)),
          ),
        ],
      ),
    );
  }
}

class _CountersError extends StatelessWidget {
  const _CountersError({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final color = AppTheme.warningText(context);
    return Container(
      key: const Key('banner_counters_error'),
      padding: const EdgeInsets.all(12),
      decoration: AppTheme.cardDecoration(context, accent: AppTheme.accentAmber, radius: 12),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: TextStyle(fontSize: 12.5, color: color))),
          TextButton(
            key: const Key('btn_retry'),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => unawaited(onRetry()),
            child: const Text('Yeniden dene'),
          ),
        ],
      ),
    );
  }
}

class _Metric {
  const _Metric({
    required this.cardKey,
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
    required this.badge,
    required this.onTap,
  });

  final Key cardKey;
  final String title;
  final String value;
  final IconData icon;
  final Color color;
  final String badge;
  final VoidCallback? onTap;
}

class _MetricGrid extends StatelessWidget {
  const _MetricGrid({required this.cards, this.loading = false});

  final List<_Metric> cards;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth > 550 ? cards.length.clamp(1, 3) : 2;
        final width = (constraints.maxWidth - 10 * (columns - 1)) / columns;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final card in cards)
              SizedBox(width: width, child: _MetricCard(metric: card, loading: loading)),
          ],
        );
      },
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.metric, required this.loading});

  final _Metric metric;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final readable = AppTheme.readableAccent(context, metric.color);
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: '${metric.title}: ${loading ? 'yükleniyor' : metric.value}',
      button: metric.onTap != null,
      onTap: metric.onTap,
      child: InkWell(
        key: metric.cardKey,
        onTap: metric.onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          constraints: const BoxConstraints(minHeight: 96),
          padding: const EdgeInsets.all(14),
          decoration: AppTheme.cardDecoration(context, accent: metric.color),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Icon(metric.icon, color: readable, size: 22),
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: metric.color.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        metric.badge,
                        style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: readable),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (loading)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Text(
                  metric.value,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.getTextPrimary(context),
                  ),
                ),
              const SizedBox(height: 2),
              Text(
                metric.title,
                style: TextStyle(fontSize: 12, color: AppTheme.getTextMuted(context)),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Action {
  const _Action({
    required this.cardKey,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final Key cardKey;
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
}

class _ActionGrid extends StatelessWidget {
  const _ActionGrid({required this.actions});

  final List<_Action> actions;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 550;
        final width = isWide ? (constraints.maxWidth - 10) / 2 : constraints.maxWidth;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final action in actions)
              SizedBox(
                width: width,
                child: Semantics(
                  button: true,
                  excludeSemantics: true,
                  label: '${action.title}. ${action.subtitle}',
                  onTap: action.onTap,
                  child: InkWell(
                    key: action.cardKey,
                    onTap: action.onTap,
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 72),
                      padding: const EdgeInsets.all(14),
                      decoration: AppTheme.cardDecoration(context),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: action.color.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              action.icon,
                              color: AppTheme.readableAccent(context, action.color),
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  action.title,
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.bold,
                                    color: AppTheme.getTextPrimary(context),
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  action.subtitle,
                                  style: TextStyle(fontSize: 11, color: AppTheme.getTextMuted(context)),
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          Icon(Icons.chevron_right_rounded, size: 20, color: AppTheme.getTextMuted(context)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _SafetyNotice extends StatelessWidget {
  const _SafetyNotice();

  @override
  Widget build(BuildContext context) {
    final warn = AppTheme.warningText(context);
    return Container(
      key: const Key('notice_service_safety'),
      padding: const EdgeInsets.all(14),
      decoration: AppTheme.cardDecoration(context, accent: AppTheme.accentAmber),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.shield_outlined, color: warn, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Yetkili Servis Güvenlik Uyarısı',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: warn),
                ),
                const SizedBox(height: 4),
                Text(
                  'Yüksek gerilim (220V AC) hatlarında bağlantı yaparken ana sigortayı mutlaka kapatın. '
                  'Röle, giriş ve panjur testleri tamamlandıktan sonra Servis Modundan devreye alma '
                  'onayını vermeyi unutmayın.',
                  style: TextStyle(fontSize: 12, height: 1.35, color: AppTheme.getTextMuted(context)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DrawerTip extends StatelessWidget {
  const _DrawerTip();

  @override
  Widget build(BuildContext context) {
    final cyan = AppTheme.readableAccent(context, AppTheme.accentCyan);
    return Container(
      key: const Key('tip_drawer'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: AppTheme.cardDecoration(context, radius: 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppTheme.accentCyan.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.menu_open_rounded, color: cyan, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Tüm yönetim araçlarına sol üstteki menüden (☰) de ulaşabilirsiniz.',
              style: TextStyle(fontSize: 12, color: AppTheme.getTextMuted(context)),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            key: const Key('btn_open_drawer'),
            onPressed: () => Scaffold.maybeOf(context)?.openDrawer(),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(48, 48),
              side: BorderSide(color: cyan),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: Text('Menüyü Aç', style: TextStyle(fontSize: 11.5, color: cyan)),
          ),
        ],
      ),
    );
  }
}
