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
import '../setup_widgets.dart';
import '../steps/step_common.dart';

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

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final caps = context.watch<AutomationState>().capabilities;
    final tools = <_Tool>[
      if (includeSetup)
        _Tool(
          cardKey: 'card_tool_setup',
          icon: Icons.rocket_launch_outlined,
          title: 'Kurulum Sihirbazı',
          subtitle: 'Yeni pano kurulumu, devam eden kurulumlar ve mevcut cihazlar',
          onTap: () => _push(context, ServiceModePage(scanner: scanner)),
        ),
      if (caps.canViewInventory)
        _Tool(
          cardKey: 'card_tool_subscribers',
          icon: Icons.people_alt_outlined,
          title: 'Aboneler ve Home Admin',
          subtitle: 'Daireler, panolar ve ev yöneticisi atama / devretme',
          onTap: () => _push(context, const ServiceSubscribersPage()),
        ),
      if (caps.canViewInventory)
        _Tool(
          cardKey: 'card_tool_inventory',
          icon: Icons.inventory_2_outlined,
          title: 'Cihaz Envanteri',
          subtitle: caps.canManageInventory
              ? 'Stok, karekod ve etiket yönetimi'
              : 'Stoğunuzdaki panolar ve karekodları',
          onTap: () => _push(context, const DeviceInventoryPage()),
        ),
      if (caps.canReplaceBoard)
        _Tool(
          cardKey: 'card_tool_replace',
          icon: Icons.sync_alt_rounded,
          title: 'Pano Değişimi',
          subtitle: 'Arızalı panonun ayarlarını yeni panoya aktarın',
          onTap: () => ReplaceBoardDialog.show(context, scanner: scanner),
        ),
      _Tool(
        cardKey: 'card_tool_doctor',
        icon: Icons.health_and_safety_outlined,
        title: 'Sistem Doktoru',
        subtitle: 'Bulut, ev ağı ve pano gücünü tek dokunuşla denetleyin',
        onTap: () => SystemDoctorDialog.show(context),
      ),
      if (includeManagement && caps.canOpenServiceManagement)
        _Tool(
          cardKey: 'card_tool_management',
          icon: Icons.admin_panel_settings_outlined,
          title: 'Servis Hesapları',
          subtitle: caps.canManageAdminAccounts
              ? 'Servis sorumlularını ve yöneticileri yönetin'
              : 'Oluşturduğunuz müşteri hesapları',
          onTap: () => _push(context, const ServiceManagementPage()),
        ),
    ];
    return Column(
      key: const Key('service_tool_cards'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SetupSectionTitle('Yönetim araçları'),
        for (final tool in tools) _ToolTile(tool: tool),
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
  });

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
    return SetupCard(
      key: Key(tool.cardKey),
      padding: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: tool.onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Icon(tool.icon, color: SetupColors.readable(context, SetupColors.info), size: 26),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tool.title,
                        style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        tool.subtitle,
                        style: TextStyle(fontSize: 12.5, height: 1.3, color: SetupColors.muted(context)),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: SetupColors.muted(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
