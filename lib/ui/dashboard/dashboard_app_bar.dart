import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/capabilities.dart';
import '../../services/automation_state.dart';
import '../common/qr_flow.dart';
import '../pages/device_settings_page.dart';
import '../pages/family/family_members_page.dart';
import '../pages/service_mode_page.dart';
import '../pages/system_doctor_dialog.dart';
import '../theme/app_theme.dart';
import '../widgets/user_profile_dialog.dart';
import 'connection_status.dart';
import 'dashboard_states.dart';
import 'labels.dart';

/// Panonun hangi görünümü gösterdiği (rol/konsol ayrımı).
enum DashboardView { superConsole, serviceConsole, apartment }

DashboardView dashboardViewOf(AutomationState s) {
  if (s.isSuperUser) return DashboardView.superConsole;
  if (s.isServiceUser) return DashboardView.serviceConsole;
  return DashboardView.apartment;
}

typedef _BarVm = ({
  DashboardView view,
  Capabilities caps,
  AppMode mode,
  String title,
  ConnectionBadge badge,
  String initial,
  bool hasUser,
  bool multiHome,
  bool showSettings,
});

_BarVm _barVmOf(AutomationState s) {
  final view = dashboardViewOf(s);
  final caps = s.capabilities;
  String title;
  switch (view) {
    case DashboardView.superConsole:
      title = 'Süper Yönetici Konsolu';
    case DashboardView.serviceConsole:
      title = 'Yetkili Servis Konsolu';
    case DashboardView.apartment:
      title = s.mode == AppMode.cloud
          ? (s.activeHome?.name ?? 'Evim')
          : (s.status?.deviceName ?? 'AHBU Akıllı Ev');
  }
  return (
    view: view,
    caps: caps,
    mode: s.mode,
    title: title,
    badge: connectionBadgeOf(s),
    initial: initialOf(s.currentUser?.fullName),
    hasUser: s.currentUser != null,
    multiHome: s.homes.length > 1,
    showSettings: s.mode == AppMode.direct || caps.hasHomeAccess || caps.canEditDeviceHost,
  );
}

class _NavItem {
  const _NavItem({
    required this.name,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
    this.primary = false,
  });

  /// `Key('nav_<name>')`.
  final String name;
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color? color;

  /// Dar ekranlarda da simge olarak görünür; diğerleri "Diğer" menüsüne girer.
  final bool primary;
}

/// Pano üst çubuğu. Gezinme girdileri **`Capabilities`'ten** türetilir:
///
/// | Anahtar | Koşul |
/// |---|---|
/// | `nav_menu` | süper / servis konsolu (çekmece) |
/// | `nav_home_switcher` | birden çok dairesi olan kullanıcı |
/// | `nav_qr` | oturum açmış, servis PIN oturumu değil (katıl / eşle) |
/// | `nav_settings` | aktif eve erişim (misafir dahil, salt-okunur sayfa) |
/// | `nav_family` | `canInvite` / `canManageMembers` (ev sahibi) |
/// | `nav_mode` | `canSwitchMode` (misafir ✖) |
/// | `nav_service` | servis PIN oturumu (`isServiceSession`) |
/// | `nav_doctor` | `canChangeChildLock` (tanılama misafire kapalı) / konsollarda `canOpenServiceManagement` |
/// | `nav_refresh`, `nav_profile`, `nav_login` | herkes / oturum açık / girişsiz yerel mod |
///
/// Dar ekranda (< 640 dp) yalnızca birincil simgeler görünür, kalanlar `nav_overflow` menüsündedir.
class DashboardAppBar extends StatelessWidget implements PreferredSizeWidget {
  const DashboardAppBar({super.key, this.onOpenDrawer});

  /// Konsol görünümlerinde çekmeceyi açar.
  final VoidCallback? onOpenDrawer;

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    final vm = context.select<AutomationState, _BarVm>(_barVmOf);
    final state = context.read<AutomationState>();
    final caps = vm.caps;
    final isConsole = vm.view != DashboardView.apartment;
    final isDark = AppTheme.isDark(context);
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 640;

    final items = <_NavItem>[];
    if (isConsole) {
      if (caps.canOpenServiceManagement) {
        items.add(_NavItem(
          name: 'doctor',
          icon: Icons.health_and_safety_outlined,
          tooltip: 'Sistem Doktoru (Teşhis)',
          color: Colors.cyanAccent,
          primary: true,
          onPressed: () => SystemDoctorDialog.show(context),
        ));
      }
      items.add(_NavItem(
        name: 'refresh',
        icon: Icons.refresh,
        tooltip: 'Yenile',
        primary: true,
        onPressed: () => unawaited(state.refresh()),
      ));
    } else {
      if (caps.isAuthenticated && !caps.isServiceSession) {
        items.add(_NavItem(
          name: 'qr',
          icon: Icons.qr_code_scanner,
          tooltip: 'Karekod Tara (Cihaz / Eve Katıl)',
          color: isDark ? AppTheme.primaryBlueLight : AppTheme.primaryBlue,
          primary: true,
          onPressed: () => unawaited(scanAndRouteQr(context)),
        ));
      }
      if (vm.showSettings) {
        items.add(_NavItem(
          name: 'settings',
          icon: Icons.settings_outlined,
          tooltip: 'Cihaz Ayarları',
          primary: true,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const DeviceSettingsPage()),
          ),
        ));
      }
      if (caps.canInvite || caps.canManageMembers) {
        items.add(_NavItem(
          name: 'family',
          icon: Icons.group_outlined,
          tooltip: 'Aile & Misafir Yönetimi',
          color: isDark ? AppTheme.primaryBlueLight : AppTheme.primaryBlue,
          primary: true,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const FamilyMembersPage()),
          ),
        ));
      }
      if (caps.canSwitchMode) {
        final cloud = vm.mode == AppMode.cloud;
        items.add(_NavItem(
          name: 'mode',
          icon: cloud ? Icons.cloud_outlined : Icons.wifi_outlined,
          tooltip: cloud ? 'Bulut Modu (yerel moda geç)' : 'Yerel Ağ Modu (buluta geç)',
          color: cloud ? AppTheme.primaryBlueLight : AppTheme.accentAmber,
          onPressed: () => unawaited(_toggleMode(context, state, cloud)),
        ));
      }
      if (caps.isServiceSession) {
        items.add(_NavItem(
          name: 'service',
          icon: Icons.engineering_outlined,
          tooltip: 'Servis Modu (devreye alma)',
          color: AppTheme.accentCyan,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const ServiceModePage()),
          ),
        ));
      }
      if (caps.canChangeChildLock && caps.hasHomeAccess) {
        items.add(_NavItem(
          name: 'doctor',
          icon: Icons.health_and_safety_outlined,
          tooltip: 'Sistem Doktoru (Teşhis)',
          color: Colors.cyanAccent,
          onPressed: () => SystemDoctorDialog.show(context),
        ));
      }
      items.add(_NavItem(
        name: 'refresh',
        icon: Icons.refresh,
        tooltip: 'Yenile',
        onPressed: () => unawaited(state.refresh()),
      ));
    }

    final visible = wide ? items : items.where((i) => i.primary).toList();
    final overflow = wide ? const <_NavItem>[] : items.where((i) => !i.primary).toList();

    return AppBar(
      toolbarHeight: 64,
      automaticallyImplyLeading: false,
      titleSpacing: isConsole ? 0 : 16,
      leading: isConsole
          ? IconButton(
              key: const Key('nav_menu'),
              icon: Icon(Icons.menu, color: AppTheme.readableAccent(context, AppTheme.accentCyan)),
              tooltip: 'Menü',
              onPressed: onOpenDrawer,
            )
          : null,
      title: _Title(vm: vm, isConsole: isConsole),
      actions: [
        for (final item in visible) _NavButton(item: item),
        if (overflow.isNotEmpty)
          PopupMenuButton<String>(
            key: const Key('nav_overflow'),
            tooltip: 'Diğer işlemler',
            icon: const Icon(Icons.more_vert),
            onSelected: (name) {
              for (final item in overflow) {
                if (item.name == name) item.onPressed();
              }
            },
            itemBuilder: (_) => [
              for (final item in overflow)
                PopupMenuItem<String>(
                  key: Key('nav_${item.name}'),
                  value: item.name,
                  height: 48,
                  child: Row(
                    children: [
                      Icon(item.icon, size: 20, color: item.color),
                      const SizedBox(width: 12),
                      Flexible(child: Text(item.tooltip)),
                    ],
                  ),
                ),
            ],
          ),
        if (vm.hasUser)
          IconButton(
            key: const Key('nav_profile'),
            icon: CircleAvatar(
              radius: 14,
              backgroundColor: AppTheme.primaryBlue.withValues(alpha: 0.2),
              child: Text(
                vm.initial,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.infoText(context),
                ),
              ),
            ),
            tooltip: 'Kullanıcı Profili & Oturum',
            onPressed: () => UserProfileDialog.show(context),
          )
        else
          IconButton(
            key: const Key('nav_login'),
            icon: Icon(Icons.login, color: AppTheme.infoText(context)),
            tooltip: 'Giriş yap (buluta geç)',
            onPressed: () => unawaited(state.setMode(AppMode.cloud)),
          ),
      ],
    );
  }

  Future<void> _toggleMode(BuildContext context, AutomationState state, bool cloud) async {
    final ok = await state.setMode(cloud ? AppMode.direct : AppMode.cloud);
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? (cloud ? 'Yerel ağ moduna geçildi' : 'Bulut moduna geçildi')
                : 'Bu hesapla mod değiştirilemez.',
          ),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({required this.item});

  final _NavItem item;

  @override
  Widget build(BuildContext context) {
    final color = item.color == null
        ? AppTheme.getTextMuted(context)
        : AppTheme.readableAccent(context, item.color!);
    return IconButton(
      key: Key('nav_${item.name}'),
      icon: Icon(item.icon, color: color),
      tooltip: item.tooltip,
      onPressed: item.onPressed,
    );
  }
}

class _Title extends StatelessWidget {
  const _Title({required this.vm, required this.isConsole});

  final _BarVm vm;
  final bool isConsole;

  @override
  Widget build(BuildContext context) {
    final cyan = AppTheme.accentCyan;
    final ringColor = isConsole ? (vm.view == DashboardView.superConsole ? const Color(0xFF38BDF8) : cyan) : const Color(0xFF38BDF8);
    final subtitleColor = isConsole ? AppTheme.readableAccent(context, cyan) : vm.badge.color(context);
    final subtitle = isConsole
        ? (vm.view == DashboardView.superConsole
            ? 'AHBU Altyapı & Servis Denetimi'
            : 'Saha Operasyon & Montaj Yönetimi')
        : '${vm.badge.label} • ${vm.badge.detail}';

    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          vm.title,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: AppTheme.getTextPrimary(context),
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          subtitle,
          key: const Key('text_connection'),
          style: TextStyle(fontSize: 11, color: subtitleColor),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );

    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: ringColor, width: 0.6),
            boxShadow: [BoxShadow(color: ringColor.withValues(alpha: 0.4), blurRadius: 8)],
          ),
          child: ClipOval(
            child: Image.asset(
              'assets/images/round_app_logo.png',
              width: 32,
              height: 32,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Icon(Icons.home_work_rounded, size: 20, color: ringColor),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: !isConsole && vm.multiHome
              ? InkWell(
                  key: const Key('nav_home_switcher'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => showHomeSwitcherSheet(context),
                  child: Row(
                    children: [
                      Expanded(child: text),
                      Icon(Icons.arrow_drop_down, color: AppTheme.getTextMuted(context)),
                    ],
                  ),
                )
              : text,
        ),
      ],
    );
  }
}
