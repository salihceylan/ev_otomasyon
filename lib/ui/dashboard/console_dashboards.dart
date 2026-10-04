import 'dart:async';
import 'dart:math' as math;

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
import '../motion/motion.dart';
import '../theme/app_theme.dart';
import '../theme/feature_accent.dart';
import '../theme/tokens.dart';
import '../widgets/orb/orb.dart';
import '../widgets/surface_card.dart';
import '../widgets/glass_pill.dart';
import 'endpoint_sections.dart' show SectionHeader;

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

// =============================================================================
// Ortak yerleşim sabitleri
// =============================================================================

/// Konsol içeriğinin en geniş değeri (dp): geniş ekranda (büyük tablet / masaüstü) içerik ortalanır; hero ve kartlar
/// 1200+ dp'lik çubuklara gerilmez.
const double _kConsoleMaxWidth = 960;

/// Kartlar arası boşluk.
const double _kGap = 10;

/// Bu içerik genişliğinin (dp) üstünde sayaç/eylem ızgarası çok sütunlu olur.
const double _kGridBreak = 550;

/// Yazı ölçeği bu çarpanın üstündeyse (büyük yazı) bileşenler dikey/sarmalı düzene geçer.
const double _kLargeText = 1.15;

/// Çok büyük yazı: sayaç ızgarası tek sütuna iner.
const double _kHugeText = 1.75;

bool _isLargeText(BuildContext context) => MediaQuery.textScalerOf(context).scale(14) > 14 * _kLargeText;

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

    return _ConsoleBody(
      scrollKey: const Key('view_super_console'),
      onRefresh: () async {
        await state.refresh();
        await _load();
      },
      children: [
        _enter(
          0,
          'header',
          _ConsoleHeader(
            badge: 'SÜPER',
            fallbackName: 'Süper Yönetici',
            description: 'Sistem genelindeki yetkili servis yöneticilerini tanımlayabilir, montaj '
                'ekiplerini denetleyebilir ve cihaz envanterini yönetebilirsiniz.',
            icon: Icons.admin_panel_settings_rounded,
            // Konsol kimliği (rol): çekmece başlığıyla AYNI aile ([AppFeature.superConsole]).
            family: AppFeature.superConsole.accentFamily,
          ),
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
              value: counts?.serviceManagers,
              icon: Icons.admin_panel_settings_rounded,
              family: AppFeature.management.accentFamily,
              badge: 'YÖNETİCİ',
              onTap: caps.canManageAdminAccounts
                  ? () => _push(context, const ServiceManagementPage(initialTabIndex: 0))
                  : null,
            ),
            _Metric(
              cardKey: const Key('card_metric_devices'),
              title: 'Pano Envanteri',
              value: counts?.devices,
              icon: Icons.inventory_2_rounded,
              family: AppFeature.inventory.accentFamily,
              badge: 'ENVANTER',
              onTap: caps.canManageInventory ? () => _push(context, const DeviceInventoryPage()) : null,
            ),
            _Metric(
              cardKey: const Key('card_metric_commissioned'),
              title: 'Devreye Alınan',
              value: counts?.commissioned,
              icon: Icons.task_alt_rounded,
              // 'Devreye Alınan' sayacı abone/daire listesine bağlıdır: aboneler ailesi (servis konsolundaki sayaçla AYNI).
              family: AppFeature.subscribers.accentFamily,
              badge: 'AKTİF PANO',
              onTap: caps.canManageAdminAccounts
                  ? () => _push(context, const ServiceManagementPage(initialTabIndex: 2))
                  : null,
            ),
          ],
        ),
        const SizedBox(height: 10),
        // Pano bölüm başlıklarıyla AYNI bileşen ([SectionHeader]: mini orb + 15/800). Dar ekran / büyük yazı: bağlantı
        // başlığın altına iner (taşma yok) ve başlık metniyle sol kenarda hizalanır.
        _enter(
          4,
          'actions_title',
          SectionHeader(
            icon: Icons.bolt_rounded,
            title: 'Hızlı Yönetici İşlemleri',
            action: caps.canOpenServiceManagement
                ? TextButton.icon(
                    key: const Key('btn_open_service_management'),
                    style: TextButton.styleFrom(minimumSize: const Size(48, 48), padding: EdgeInsets.zero),
                    onPressed: () => _push(context, const ServiceManagementPage()),
                    icon: const Icon(Icons.arrow_forward_rounded, size: 16),
                    label: const Text('Tüm Paneli Aç', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                  )
                : null,
          ),
        ),
        const SizedBox(height: 10),
        _ActionGrid(
          actions: [
            if (caps.canManageInventory)
              _Action(
                cardKey: const Key('card_action_inventory'),
                title: 'Cihaz Envanteri & Ekleme',
                subtitle: 'Fabrika panolarını tanımla, seri no & QR ekle/düzenle',
                icon: Icons.inventory_2_rounded,
                family: AppFeature.inventory.accentFamily,
                onTap: () => _push(context, const DeviceInventoryPage()),
              ),
            if (caps.canManageAdminAccounts)
              _Action(
                cardKey: const Key('card_action_service_managers'),
                title: 'Servis Sorumluları Yönetimi',
                subtitle: 'Yetkili servis sorumlularını sisteme ekle & düzenle',
                icon: Icons.people_rounded,
                family: AppFeature.management.accentFamily,
                onTap: () => _push(context, const ServiceManagementPage(initialTabIndex: 0)),
              ),
            if (caps.canViewInventory)
              _Action(
                cardKey: const Key('card_action_subscribers'),
                title: 'Tüm Aboneler & Atamalar',
                subtitle: 'Daireler, panolar ve Home Admin listesi',
                icon: Icons.people_alt_rounded,
                family: AppFeature.subscribers.accentFamily,
                onTap: () => _push(context, const ServiceSubscribersPage()),
              ),
            _Action(
              cardKey: const Key('card_action_doctor'),
              title: 'Sistem Doktoru (Sağlık & Teşhis)',
              subtitle: 'Altyapı sağlığı, DB gecikmesi, MQTT köprüsü denetimi',
              icon: Icons.health_and_safety_rounded,
              family: AppFeature.doctor.accentFamily,
              onTap: () => SystemDoctorDialog.show(context),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _enter(7, 'tip', const _DrawerTip()),
        const SizedBox(height: 30),
      ],
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

    return _ConsoleBody(
      scrollKey: const Key('view_service_console'),
      onRefresh: () async {
        await state.refresh();
        await _load();
      },
      children: [
        _enter(
          0,
          'header',
          _ConsoleHeader(
            badge: 'YETKİLİ SERVİS',
            fallbackName: 'Yetkili Servis Sorumlusu',
            description: 'Müşteri dairelerinde pano kurulumu, devreye alma ve saha desteği '
                'işlemlerini buradan yürütebilirsiniz.',
            icon: Icons.engineering_rounded,
            family: AppFeature.serviceConsole.accentFamily,
          ),
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
              value: counts.devices,
              icon: Icons.inventory_2_rounded,
              family: AppFeature.inventory.accentFamily,
              badge: 'STOK & PANO',
              onTap: null,
            ),
            _Metric(
              cardKey: const Key('card_metric_commissioned'),
              title: 'Devreye Alınan',
              value: counts.subscribers,
              icon: Icons.task_alt_rounded,
              family: AppFeature.subscribers.accentFamily,
              badge: 'ABONE DAİRE',
              onTap: caps.canViewInventory ? () => _push(context, const ServiceSubscribersPage()) : null,
            ),
          ],
        ),
        const SizedBox(height: 10),
        _enter(
          3,
          'actions_title',
          const SectionHeader(icon: Icons.checklist_rounded, title: 'Saha Servis & Devreye Alma Görevleri'),
        ),
        const SizedBox(height: 10),
        _ActionGrid(
          firstIndex: 4,
          actions: [
            _Action(
              cardKey: const Key('card_action_commissioning'),
              title: 'Devreye Alma (Servis Modu)',
              subtitle: 'Pano karekod eşleme, müşteri OTP onayı, canlı testler ve devreye alma',
              icon: Icons.verified_rounded,
              family: AppFeature.commissioning.accentFamily,
              onTap: () => _push(context, const ServiceModePage()),
            ),
            if (caps.canViewInventory)
              _Action(
                cardKey: const Key('card_action_subscribers'),
                title: 'Abonelerim & Cihaz Atama',
                subtitle: 'Kayıtlı panolar ve Home Admin atama',
                icon: Icons.people_alt_rounded,
                family: AppFeature.subscribers.accentFamily,
                onTap: () => _push(context, const ServiceSubscribersPage()),
              ),
            _Action(
              cardKey: const Key('card_action_replace_board'),
              title: 'Pano Değişimi (Afet & Hasar)',
              subtitle: 'Arızalı panonun kimliğini yenisiyle değiştirip daire verilerini aktarın',
              icon: Icons.published_with_changes_rounded,
              family: AppFeature.boardReplace.accentFamily,
              onTap: () => ReplaceBoardDialog.show(context),
            ),
            _Action(
              cardKey: const Key('card_action_wifi_recovery'),
              title: 'Wi-Fi Yapılandırma & Kurtarma',
              subtitle: 'Modem değişikliğinde panoya yeni Wi-Fi bilgisini aktarın',
              icon: Icons.wifi_rounded,
              family: AppFeature.wifiRecovery.accentFamily,
              onTap: () => WifiRecoveryDialog.show(context),
            ),
            if (caps.canEmergencyReset)
              _Action(
                cardKey: const Key('card_action_emergency_reset'),
                title: 'Acil Sıfırlama',
                subtitle: 'Eski sahibine ulaşılamayan panoyu sıfırlayıp yeniden eşleyin',
                icon: Icons.sync_problem_rounded,
                family: AppFeature.emergencyReset.accentFamily,
                onTap: () => TransferOwnershipDialog.show(context, initialTab: 1),
              ),
          ],
        ),
        const SizedBox(height: 20),
        _enter(7, 'safety', const _SafetyNotice()),
        const SizedBox(height: 16),
        _enter(7, 'tip', const _DrawerTip()),
        const SizedBox(height: 30),
      ],
    );
  }
}

// =============================================================================
// Ortak parçalar
// =============================================================================

void _push(BuildContext context, Widget page) {
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
}

/// Kademeli giriş sarmalayıcısı: en çok 8 öğe (fazlası aynı kademede), tek sefer. Sabit [id] anahtarı, koşullu
/// öğeler (hata kartı) eklenip çıkınca girişin yeniden oynamasını önler.
Widget _enter(int index, String id, Widget child) => StaggeredEntrance(
      key: ValueKey<String>('enter_$id'),
      index: math.min(index, AppMotion.staggerMaxItems - 1),
      child: child,
    );

/// Konsol gövdesi (iki konsol için ortak): çekerek yenile + kaydırma + 16 dp dolgu; içerik [_kConsoleMaxWidth] ile
/// sınırlanıp ortalanır (geniş ekranda kartlar 1200+ dp'lik çubuklara gerilmez).
class _ConsoleBody extends StatelessWidget {
  const _ConsoleBody({required this.scrollKey, required this.onRefresh, required this.children});

  final Key scrollKey;
  final Future<void> Function() onRefresh;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: SingleChildScrollView(
        key: scrollKey,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _kConsoleMaxWidth),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
          ),
        ),
      ),
    );
  }
}

/// Kartları [columns] sütunlu satırlara dizer: satırdaki kartlar EŞİT yükseklikte ([IntrinsicHeight]; kart sayısı ≤ 6,
/// maliyet önemsiz), sütun sayısına bölünmeyen SON kart tam genişliğe yayılır (yetim hücre yok).
class _CardRows extends StatelessWidget {
  const _CardRows({required this.columns, required this.children});

  final int columns;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var start = 0; start < children.length; start += columns) {
      final slice = children.sublist(start, math.min(start + columns, children.length));
      if (rows.isNotEmpty) rows.add(const SizedBox(height: _kGap));
      if (slice.length == 1) {
        rows.add(slice.first);
      } else {
        rows.add(
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < slice.length; i++) ...[
                  if (i > 0) const SizedBox(width: _kGap),
                  Expanded(child: slice[i]),
                ],
              ],
            ),
          ),
        );
      }
    }
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }
}

/// Konsol başlık kartı (kullanıcı adı, rol rozeti, açıklama): orb rozetli, vurgulu cam kart. Ekrandaki TEK vurgulu
/// (aktif) karttır: kategori renkleri sayaç/eylem kartlarında yalnız orb ve rozette taşınır.
class _ConsoleHeader extends StatelessWidget {
  const _ConsoleHeader({
    required this.badge,
    required this.fallbackName,
    required this.description,
    required this.icon,
    required this.family,
  });

  final String badge;
  final String fallbackName;
  final String description;
  final IconData icon;
  final AccentFamily family;

  @override
  Widget build(BuildContext context) {
    final user = context.select<AutomationState, ({String name, String email})>(
      (s) => (name: s.currentUser?.fullName ?? '', email: s.currentUser?.email ?? ''),
    );
    final name = user.name.trim().isEmpty ? fallbackName : user.name.trim();
    final accent = family.base;

    final identity = Row(
      children: [
        OrbIconBadge(icon: icon, family: family, size: OrbSize.md, active: true, glow: true),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: AppTheme.getTextPrimary(context)),
              ),
              const SizedBox(height: 4),
              GlassPill(
                color: accent,
                label: badge,
                letterSpacing: 0.4,
                leading: GlowDot(color: accent, size: 8),
              ),
              if (user.email.trim().isNotEmpty) ...[
                const SizedBox(height: 4),
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
    );
    final descriptionText = Text(
      description,
      style: TextStyle(fontSize: 12.5, height: 1.4, color: AppTheme.getTextMuted(context)),
    );

    return SurfaceCard(
      key: const Key('card_console_header'),
      accent: accent,
      active: true,
      padding: const EdgeInsets.all(18),
      child: SizedBox(
        width: double.infinity,
        // Geniş kartta (tablet/masaüstü) kimlik solda, açıklama sağda (hero'nun sağ yarısı boş kalmaz).
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth >= 560) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(flex: 5, child: identity),
                  const SizedBox(width: 24),
                  Expanded(flex: 6, child: descriptionText),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [identity, const SizedBox(height: 14), descriptionText],
            );
          },
        ),
      ),
    );
  }
}

/// Sayaç / yükleme hatası kartı: rose orb rozet + ileti + "Yeniden dene" (anlamlı hata durumu). Kalıcı hata = rose
/// (şartname §2.1). Dar genişlikte ya da büyük yazıda DİKEY düzen: ileti tam genişlikte okunur, "Yeniden dene" altta
/// sağda durur (yan yana iken ileti ≈ 88 dp'lik sütunda 7-8 satıra bölünüyordu).
class _CountersError extends StatelessWidget {
  const _CountersError({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final rose = AppFamilies.rose;
    final color = AppTheme.dangerText(context);
    final retry = OutlinedButton.icon(
      key: const Key('btn_retry'),
      onPressed: () => unawaited(onRetry()),
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        // Kenar: tüm çerçeveli düğmelerle AYNI tek ton kuralı (iki temada ≥ 3:1; eskiden rose@.55 açıkta ≈ 2.1:1 idi).
        side: AppTheme.outlinedSide(context, AppFamilies.rose),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      ),
      icon: const Icon(Icons.refresh_rounded, size: 18),
      label: const Text('Yeniden dene', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
    );
    const orb = OrbIconBadge(icon: Icons.priority_high_rounded, family: AppFamilies.rose);
    final text = Text(message, style: TextStyle(fontSize: 13, height: 1.35, color: color));

    return SurfaceCard(
      key: const Key('banner_counters_error'),
      accent: rose.base,
      padding: const EdgeInsets.all(14),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stacked = constraints.maxWidth < 400 || _isLargeText(context);
          if (stacked) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    orb,
                    const SizedBox(width: 12),
                    Expanded(child: text),
                  ],
                ),
                const SizedBox(height: 10),
                Align(alignment: AlignmentDirectional.centerEnd, child: retry),
              ],
            );
          }
          return Row(
            children: [
              orb,
              const SizedBox(width: 12),
              Expanded(child: text),
              const SizedBox(width: 12),
              retry,
            ],
          );
        },
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
    required this.family,
    required this.badge,
    required this.onTap,
  });

  final Key cardKey;
  final String title;

  /// `null` = yüklenmemiş/bilinmiyor ("—" gösterilir; uydurma `0` yok).
  final int? value;
  final IconData icon;
  final AccentFamily family;
  final String badge;
  final VoidCallback? onTap;
}

/// Sayaç kartları: telefonda 2 sütun (sayı tek ise SON kart tam genişlikte yatay düzen), tablette kart sayısı kadar
/// sütun (en çok 3); satırdaki kartlar eşit yükseklikte.
class _MetricGrid extends StatelessWidget {
  const _MetricGrid({required this.cards, this.loading = false});

  final List<_Metric> cards;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Çok büyük yazıda (>= 1.75x) iki dar sütunda sözcükler ortadan kırılırdı ('YÖNETİ/Cİ'): tek sütun, yatay kartlar.
        // (320 dp + 1.5x'te 'ENVANTER' rozeti artık `AppPill`in [WordSafeLabel]'iyle sözcük ortasından kırılmaz, küçülür.)
        final hugeText = MediaQuery.textScalerOf(context).scale(14) >= 14 * _kHugeText;
        final columns = hugeText ? 1 : (constraints.maxWidth > _kGridBreak ? cards.length.clamp(1, 3) : 2);
        final cardWidth = (constraints.maxWidth - _kGap * (columns - 1)) / columns;
        return _CardRows(
          columns: columns,
          children: [
            for (var i = 0; i < cards.length; i++)
              _enter(
                1 + i,
                'metric_${i}_${cards.length}',
                _MetricCard(
                  metric: cards[i],
                  loading: loading,
                  // Yatay düzen: kart yeterince genişse ya da satırda tek başına kalan son kartsa.
                  wide: cardWidth >= 300 || columns == 1 || (i == cards.length - 1 && cards.length % columns == 1),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.metric, required this.loading, this.wide = false});

  final _Metric metric;
  final bool loading;

  /// Yatay düzen (orb | sayı + başlık + rozet | ok): geniş ya da satırda tek kalan kart.
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final family = metric.family;
    final readable = AppTheme.readableAccent(context, family.base);
    final tappable = metric.onTap != null;
    final loaded = !loading && metric.value != null;
    final tokens = SurfaceTokens.of(Theme.of(context).brightness);
    final valueStyle = TextStyle(
      fontSize: 28,
      fontWeight: FontWeight.w800,
      height: 1.1,
      color: AppTheme.getTextPrimary(context),
    );
    // İskelet yüksekliği gerçek sayı satırıyla AYNI (28 sp x 1.1 x yazı ölçeği): veri gelince kart zıplamaz.
    final valueHeight = MediaQuery.textScalerOf(context).scale(28) * 1.1;

    final Widget value;
    if (loading) {
      value = SizedBox(
        height: valueHeight,
        child: const Align(
          alignment: AlignmentDirectional.centerStart,
          child: Skeleton(width: 64, height: 24, radius: 8),
        ),
      );
    } else if (metric.value == null) {
      // Bilinmeyen sayaç: gerçek sayıdan SOLUK (muted, daha ince) ki "eksi/sıfır" gibi okunmasın.
      value = Text('—', style: valueStyle.copyWith(color: AppTheme.getTextMuted(context), fontWeight: FontWeight.w600));
    } else {
      value = AnimatedCount(value: metric.value!, format: (v) => '$v', style: valueStyle);
    }

    final orb = OrbIconBadge(
      icon: metric.icon,
      family: family,
      active: loaded,
      pending: loading,
      glow: loaded,
      // Veri yokken (hata) orb soluk; yüklenirken (dönen yay) canlı.
      enabled: loading || metric.value != null,
    );
    final arrow = Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: family.base.withValues(alpha: 0.14),
        border: Border.all(color: tokens.rimSolid),
      ),
      child: Icon(Icons.arrow_outward_rounded, size: 15, color: readable),
    );
    final title = Text(
      metric.title,
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.getTextMuted(context)),
    );
    // Rozet ortak GlassPill: büyük yazıda satıra sarılır ('ABONE DAİ…' diye kesilmez).
    final badge = GlassPill(color: family.base, label: metric.badge, letterSpacing: 0.3);

    final Widget content;
    if (wide) {
      content = Row(
        children: [
          orb,
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [value, const SizedBox(height: 2), title, const SizedBox(height: 8), badge],
            ),
          ),
          if (tappable) ...[const SizedBox(width: 8), arrow],
        ],
      );
    } else {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        // Rozet kartın ALTINA yaslanır (komşu kartın başlığı 2 satıra sarılsa da rozetler hizalı kalır).
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [orb, if (tappable) arrow],
              ),
              const SizedBox(height: 12),
              value,
              const SizedBox(height: 4),
              title,
            ],
          ),
          Padding(padding: const EdgeInsets.only(top: 8), child: badge),
        ],
      );
    }

    return Semantics(
      container: true,
      excludeSemantics: true,
      label: '${metric.title}: ${loading ? 'yükleniyor' : (metric.value == null ? '—' : '${metric.value}')}',
      button: tappable,
      onTap: metric.onTap,
      // Kategori rengi yalnız orb + rozette: kart kenarı nötr (rim). Vurgulu kart ekranda yalnız başlık kartıdır.
      child: SurfaceCard(
        key: metric.cardKey,
        onTap: metric.onTap,
        padding: const EdgeInsets.all(14),
        child: SizedBox(width: double.infinity, child: content),
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
    required this.family,
    required this.onTap,
  });

  final Key cardKey;
  final String title;
  final String subtitle;
  final IconData icon;
  final AccentFamily family;
  final VoidCallback onTap;
}

/// Eylem kartları: telefonda tek sütun, tablette 2 sütun (satırdaki kartlar eşit yükseklikte; tek kalan SON kart
/// tam genişlikte).
class _ActionGrid extends StatelessWidget {
  const _ActionGrid({required this.actions, this.firstIndex = 4});

  final List<_Action> actions;

  /// Kademeli girişte ilk kartın sırası.
  final int firstIndex;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return _CardRows(
          columns: constraints.maxWidth > _kGridBreak ? 2 : 1,
          children: [
            for (var i = 0; i < actions.length; i++)
              _enter(firstIndex + i, 'action_${actions[i].cardKey}', _ActionCard(action: actions[i])),
          ],
        );
      },
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({required this.action});

  final _Action action;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      excludeSemantics: true,
      label: '${action.title}. ${action.subtitle}',
      onTap: action.onTap,
      // Kategori rengi yalnız orb'da: kart kenarı nötr (rim).
      child: SurfaceCard(
        key: action.cardKey,
        onTap: action.onTap,
        padding: const EdgeInsets.all(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Row(
            children: [
              OrbIconBadge(icon: action.icon, family: action.family, glow: true),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      action.title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.getTextPrimary(context),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      action.subtitle,
                      style: TextStyle(fontSize: 12, color: AppTheme.getTextMuted(context)),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, size: 22, color: AppTheme.getTextMuted(context)),
            ],
          ),
        ),
      ),
    );
  }
}

class _SafetyNotice extends StatelessWidget {
  const _SafetyNotice();

  @override
  Widget build(BuildContext context) {
    final warn = AppTheme.warningText(context);
    // Uyarı: amber kenar + amber orb/başlık; ama `active` (radyal parıltı) YOK: ekrandaki tek aktif kart başlık kartıdır.
    return SurfaceCard(
      key: const Key('notice_service_safety'),
      accent: AppFamilies.amber.base,
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const OrbIconBadge(icon: Icons.shield_rounded, family: AppFamilies.amber, glow: true),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Yetkili Servis Güvenlik Uyarısı',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: warn),
                ),
                const SizedBox(height: 4),
                Text(
                  'Yüksek gerilim (220V AC) hatlarında bağlantı yaparken ana sigortayı mutlaka kapatın. '
                  'Röle, giriş ve panjur testleri tamamlandıktan sonra Servis Modundan devreye alma '
                  'onayını vermeyi unutmayın.',
                  style: TextStyle(fontSize: 12, height: 1.4, color: AppTheme.getTextMuted(context)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Tanıtım kartı: sol üstteki menüye yönlendirir; "Menüyü Aç" çekmeceyi açar. Menü simgesi metin içinde SATIR İÇİ
/// simgedir (önceden "☰" Unicode glifi: Roboto'da yok, boş kutu çiziliyordu; cihazda yedek yazı tipine bağlıydı).
/// Geniş kartta (≥ 480 dp) tek satır: orb | metin | düğme; dar kartta düğme altta sağda.
class _DrawerTip extends StatelessWidget {
  const _DrawerTip();

  @override
  Widget build(BuildContext context) {
    final cyan = AppTheme.readableAccent(context, AppFamilies.cyan.base);
    final muted = AppTheme.getTextMuted(context);
    const orb = OrbIconBadge(icon: Icons.menu_open_rounded, family: AppFamilies.cyan);
    final text = Text.rich(
      TextSpan(
        style: TextStyle(fontSize: 12, height: 1.35, color: muted),
        children: [
          const TextSpan(text: 'Tüm yönetim araçlarına sol üstteki menüden '),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Icon(Icons.menu_rounded, size: 16, color: muted),
          ),
          const TextSpan(text: ' de ulaşabilirsiniz.'),
        ],
      ),
      semanticsLabel: 'Tüm yönetim araçlarına sol üstteki menü düğmesinden de ulaşabilirsiniz.',
    );
    final open = OutlinedButton(
      key: const Key('btn_open_drawer'),
      onPressed: () => Scaffold.maybeOf(context)?.openDrawer(),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        // Kenar: tüm çerçeveli düğmelerle AYNI tek ton kuralı (açıkta cyan.base@.70 ≈ 1.8:1 idi; şimdi ≥ 3:1).
        side: AppTheme.outlinedSide(context, AppFamilies.cyan),
      ),
      child: Text('Menüyü Aç', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: cyan)),
    );

    return SurfaceCard(
      key: const Key('tip_drawer'),
      accent: AppFamilies.cyan.base,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: SizedBox(
        width: double.infinity,
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth >= 480) {
              return Row(
                children: [
                  orb,
                  const SizedBox(width: 12),
                  Expanded(child: text),
                  const SizedBox(width: 12),
                  open,
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Row(
                  children: [
                    orb,
                    const SizedBox(width: 12),
                    Expanded(child: text),
                  ],
                ),
                const SizedBox(height: 6),
                open,
              ],
            );
          },
        ),
      ),
    );
  }
}
