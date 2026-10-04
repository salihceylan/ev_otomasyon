import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../services/automation_state.dart';
import '../../device_inventory_page.dart';
import '../../replace_board_dialog.dart';
import '../../service_management_page.dart';
import '../../service_mode_page.dart';
import '../../service_subscribers_page.dart';
import '../../system_doctor_dialog.dart';
import '../setup_style.dart';
import '../../../motion/staggered_entrance.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/orb/orb_icon_badge.dart';
import 'service_glass.dart';
import '../setup_widgets.dart';
import '../steps/step_common.dart';
import '../../../theme/feature_accent.dart';

/// Servis panelinin yönetim araçları: her kart yalnızca rolün **gerçekten** kullanabildiği araç için
/// görünür (UI gizleme yetki değildir; sunucu denetler).
///
/// Anahtarlar: `card_tool_subscribers`, `card_tool_inventory`, `card_tool_replace`,
/// `card_tool_doctor`, `card_tool_management`. (Wi-Fi kurulum/kurtarma, giriş durumundan bağımsız olduğu
/// için yönetim aracı değil, ayrı bir kartıdır: `WifiSetupCard`, anahtar `card_wifi_setup`.)
class ServiceToolCards extends StatelessWidget {
  const ServiceToolCards({
    super.key,
    this.scanner = defaultSetupScanner,
    this.includeManagement = true,
    this.includeSetup = false,
  });

  final SetupScanner scanner;

  /// Servis yönetimi sayfasının kendi içinde "Servis hesapları" kartı gösterilmez.
  final bool includeManagement;

  /// Servis panelinin (kurulum sihirbazının) kısayolu: yönetim sayfasında gösterilir, panelin kendisinde değil.
  final bool includeSetup;

  /// Geçiş animasyonu sürerken (ya da üstte başka rota varken) ikinci dokunuş ikinci rota/diyalog açmaz: kartın rotası
  /// artık güncel rota değilse dokunuş yok sayılır. (Rota bilinmiyorsa eskisi gibi çalışır.)
  bool _canOpen(BuildContext context) => ModalRoute.of(context)?.isCurrent ?? true;

  void _push(BuildContext context, Widget page) {
    if (!_canOpen(context)) return;
    Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => page));
  }

  void _openDialog(BuildContext context, void Function() open) {
    if (!_canOpen(context)) return;
    open();
  }

  @override
  Widget build(BuildContext context) {
    // Yalnız kartları belirleyen yetkiler izlenir (AutomationState'in her bildirimi bu listeyi yeniden kurmasın).
    final caps = context.select<
        AutomationState,
        ({bool view, bool manageInventory, bool replace, bool openManagement, bool manageAccounts})>((s) {
      final c = s.capabilities;
      return (
        view: c.canViewInventory,
        manageInventory: c.canManageInventory,
        replace: c.canReplaceBoard,
        openManagement: c.canOpenServiceManagement,
        manageAccounts: c.canManageAdminAccounts,
      );
    });
    final tools = <_Tool>[
      if (includeSetup)
        _Tool(
          cardKey: 'card_tool_setup',
          family: AppFeature.commissioning.accentFamily,
          icon: Icons.rocket_launch_rounded,
          title: 'Kurulum Sihirbazı',
          subtitle: 'Yeni kurulum ve mevcut cihazlar',
          onTap: () => _push(context, ServiceModePage(scanner: scanner)),
        ),
      if (caps.view)
        _Tool(
          cardKey: 'card_tool_subscribers',
          family: AppFeature.subscribers.accentFamily,
          icon: Icons.groups_rounded,
          title: 'Aboneler ve Home Admin',
          subtitle: 'Daireler, panolar ve Home Admin atama',
          onTap: () => _push(context, const ServiceSubscribersPage()),
        ),
      if (caps.view)
        _Tool(
          cardKey: 'card_tool_inventory',
          family: AppFeature.inventory.accentFamily,
          icon: Icons.inventory_2_rounded,
          title: 'Cihaz Envanteri',
          subtitle: caps.manageInventory
              ? 'Stok, karekod ve etiket yönetimi'
              : 'Stoğunuzdaki panolar ve karekodları',
          onTap: () => _push(context, const DeviceInventoryPage()),
        ),
      if (caps.replace)
        _Tool(
          cardKey: 'card_tool_replace',
          family: AppFeature.boardReplace.accentFamily,
          icon: Icons.sync_alt_rounded,
          title: 'Pano Değişimi',
          subtitle: 'Arızalı panonun ayarlarını yenisine aktarın',
          onTap: () => _openDialog(context, () => ReplaceBoardDialog.show(context, scanner: scanner)),
        ),
      _Tool(
        cardKey: 'card_tool_doctor',
        family: AppFeature.doctor.accentFamily,
        icon: Icons.health_and_safety_rounded,
        title: 'Sistem Doktoru',
        subtitle: 'Bulut, ev ağı ve pano gücünü denetleyin',
        onTap: () => _openDialog(context, () => SystemDoctorDialog.show(context)),
      ),
      if (includeManagement && caps.openManagement)
        _Tool(
          cardKey: 'card_tool_management',
          family: AppFeature.management.accentFamily,
          icon: Icons.admin_panel_settings_rounded,
          title: 'Servis Hesapları',
          subtitle: caps.manageAccounts
              ? 'Servis sorumluları ve yöneticiler'
              : 'Oluşturduğunuz müşteri hesapları',
          onTap: () => _push(context, const ServiceManagementPage()),
        ),
    ];
    return Column(
      key: const Key('service_tool_cards'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SetupSectionTitle('Yönetim araçları'),
        for (var i = 0; i < tools.length; i++)
          StaggeredEntrance(index: i, child: _ToolTile(tool: tools[i])),
      ],
    );
  }
}

class _Tool {
  const _Tool({
    required this.cardKey,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    required this.family,
  });

  final AccentFamily family;
  final String cardKey;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({required this.tool});

  final _Tool tool;

  @override
  Widget build(BuildContext context) {
    return ServiceCard(
      key: Key(tool.cardKey),
      padding: EdgeInsets.zero,
      onTap: tool.onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 72),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.s16, vertical: AppSpace.s12),
          child: Row(
            children: [
              OrbIconBadge(icon: tool.icon, family: tool.family),
              const SizedBox(width: AppSpace.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tool.title,
                      style: TextStyle(fontSize: AppText.cardTitle, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tool.subtitle,
                      style: TextStyle(fontSize: AppText.caption, height: 1.3, color: SetupColors.muted(context)),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: SetupColors.muted(context)),
            ],
          ),
        ),
      ),
    );
  }
}
