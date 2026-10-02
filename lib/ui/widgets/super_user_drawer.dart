import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/capabilities.dart';
import '../../services/automation_state.dart';
import '../common/confirm_dialogs.dart';
import '../pages/device_inventory_page.dart';
import '../pages/family/transfer_ownership_dialog.dart';
import '../pages/replace_board_dialog.dart';
import '../pages/service_management_page.dart';
import '../pages/service_mode_page.dart';
import '../pages/service_subscribers_page.dart';
import '../pages/system_doctor_dialog.dart';
import '../pages/wifi_recovery_dialog.dart';
import '../theme/app_theme.dart';

/// Süper yönetici / yetkili servis çekmecesi (sandviç menü).
///
/// Girdiler **`Capabilities`'ten** türetilir (rol adı karşılaştırması yok):
/// * süper kullanıcı: envanter (`canManageInventory`), servis sorumluları (`canManageAdminAccounts`),
///   tüm aboneler (`canViewInventory`), sistem doktoru;
/// * kalıcı servis personeli (`isStaff`): servis modu, aboneler, pano değişimi, Wi-Fi kurtarma;
///   acil sıfırlama (`canEmergencyReset`).
///
/// Çıkış, onaylı çıkıştır ([confirmAndLogout]; navigator yığınını temizler). Anahtarlar:
/// `Key('nav_drawer')`, `Key('nav_drawer_<ad>')`, `Key('nav_drawer_logout')`.
class SuperUserDrawer extends StatelessWidget {
  const SuperUserDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.read<AutomationState>();
    final caps = context.select<AutomationState, Capabilities>((s) => s.capabilities);
    final user = context.select<AutomationState, ({String name, String email})>(
      (s) => (name: s.currentUser?.fullName ?? '', email: s.currentUser?.email ?? ''),
    );
    final isDark = AppTheme.isDark(context);

    final isSuper = caps.isSuperUser;
    final fieldStaff = caps.isStaff && !caps.isSuperUser;

    final badgeColor = isSuper ? AppTheme.accentPurple : AppTheme.accentCyan;
    final badgeText = isSuper ? 'SÜPER YÖNETİCİ KONSOLU' : 'YETKİLİ SERVİS KONSOLU';
    final badgeIcon = isSuper ? Icons.verified_user : Icons.engineering_rounded;
    final displayName = user.name.trim().isNotEmpty
        ? user.name.trim()
        : (isSuper ? 'Süper Yönetici' : 'Yetkili Servis Sorumlusu');

    return Drawer(
      key: const Key('nav_drawer'),
      backgroundColor: AppTheme.getDrawerBg(context),
      child: SafeArea(
        child: Column(
          children: [
            // 1. ÜST BAŞLIK (HEADER)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
              decoration: BoxDecoration(
                color: AppTheme.getDrawerHeaderBg(context),
                border: Border(
                  bottom: BorderSide(color: AppTheme.getCardBorder(context), width: 1),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: badgeColor, width: 1.2),
                          boxShadow: [
                            BoxShadow(
                              color: badgeColor.withValues(alpha: 0.3),
                              blurRadius: 10,
                            ),
                          ],
                        ),
                        child: ClipOval(
                          child: Image.asset(
                            'assets/images/round_app_logo.png',
                            width: 46,
                            height: 46,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Icon(badgeIcon, color: badgeColor),
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              displayName,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: AppTheme.getTextPrimary(context),
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (user.email.trim().isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                user.email.trim(),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.getTextMuted(context),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: badgeColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: badgeColor.withValues(alpha: 0.4)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(badgeIcon, color: AppTheme.readableAccent(context, badgeColor), size: 14),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            badgeText,
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.5,
                              color: AppTheme.readableAccent(context, badgeColor),
                            ),
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

            // 2. MENÜ ELEMANLARI
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                children: [
                  _DrawerItem(
                    itemKey: const Key('nav_drawer_console'),
                    icon: Icons.dashboard_outlined,
                    title: isSuper ? 'Yönetici Konsolu' : 'Servis Konsolu',
                    subtitle: isSuper
                        ? 'Sistem durumu & ana kontroller'
                        : 'Saha operasyonları & ana kontroller',
                    onTap: () => Navigator.pop(context),
                  ),
                  if (caps.canManageInventory)
                    _DrawerItem(
                      itemKey: const Key('nav_drawer_inventory'),
                      icon: Icons.inventory_2_outlined,
                      title: 'Cihaz Envanteri',
                      subtitle: 'Karekodlar, seri no & fabrika kayıtları',
                      color: AppTheme.accentAmber,
                      onTap: () => _push(context, const DeviceInventoryPage()),
                    ),
                  if (caps.canManageAdminAccounts)
                    _DrawerItem(
                      itemKey: const Key('nav_drawer_service_managers'),
                      icon: Icons.admin_panel_settings_outlined,
                      title: 'Servis Sorumluları',
                      subtitle: 'Yetkili servisleri ekle & düzenle',
                      color: AppTheme.accentCyan,
                      onTap: () => _push(context, const ServiceManagementPage(initialTabIndex: 0)),
                    ),
                  if (caps.canViewInventory)
                    _DrawerItem(
                      itemKey: const Key('nav_drawer_subscribers'),
                      icon: Icons.people_alt_outlined,
                      title: isSuper ? 'Tüm Aboneler & Atamalar' : 'Abonelerim & Cihaz Atama',
                      subtitle: isSuper
                          ? 'Daireler, panolar & Home Admin listesi'
                          : 'Kayıtlı panolar & Home Admin atama',
                      color: AppTheme.accentGreen,
                      onTap: () => _push(context, const ServiceSubscribersPage()),
                    ),
                  if (isSuper)
                    _DrawerItem(
                      itemKey: const Key('nav_drawer_doctor'),
                      icon: Icons.health_and_safety_outlined,
                      title: 'Sistem Doktoru',
                      subtitle: 'DB, MQTT ve sistem sağlığı teşhisi',
                      color: Colors.cyanAccent,
                      onTap: () {
                        Navigator.pop(context);
                        SystemDoctorDialog.show(context);
                      },
                    ),
                  if (fieldStaff) ...[
                    _DrawerItem(
                      itemKey: const Key('nav_drawer_commissioning'),
                      icon: Icons.verified_outlined,
                      title: 'Devreye Alma & Servis Modu',
                      subtitle: 'Karekod eşleme, canlı test & onay',
                      color: AppTheme.accentCyan,
                      onTap: () => _push(context, const ServiceModePage()),
                    ),
                    _DrawerItem(
                      itemKey: const Key('nav_drawer_replace_board'),
                      icon: Icons.published_with_changes_outlined,
                      title: 'Pano Değişimi (Afet Modu)',
                      subtitle: 'Buluttan birebir pano aktarımı',
                      color: Colors.tealAccent,
                      onTap: () {
                        Navigator.pop(context);
                        ReplaceBoardDialog.show(context);
                      },
                    ),
                    _DrawerItem(
                      itemKey: const Key('nav_drawer_wifi_recovery'),
                      icon: Icons.wifi_find_outlined,
                      title: 'Wi-Fi Yapılandırma & Kurtarma',
                      subtitle: 'Modem değişimi & Pano Smart AP',
                      color: AppTheme.accentAmber,
                      onTap: () {
                        Navigator.pop(context);
                        WifiRecoveryDialog.show(context);
                      },
                    ),
                  ],
                  if (caps.canEmergencyReset)
                    _DrawerItem(
                      itemKey: const Key('nav_drawer_emergency_reset'),
                      icon: Icons.sync_problem_rounded,
                      title: 'Acil Sıfırlama',
                      subtitle: 'Eski sahibine ulaşılamayan panoyu sıfırla',
                      color: Colors.redAccent,
                      onTap: () {
                        Navigator.pop(context);
                        TransferOwnershipDialog.show(context, initialTab: 1);
                      },
                    ),
                  Divider(
                    color: AppTheme.getCardBorder(context),
                    height: 24,
                    indent: 8,
                    endIndent: 8,
                  ),
                  ListTile(
                    key: const Key('nav_drawer_theme'),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    minTileHeight: 48,
                    leading: Icon(
                      isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
                      color: isDark ? AppTheme.accentAmber : AppTheme.primaryBlue,
                      size: 22,
                    ),
                    title: Text(
                      isDark ? 'Aydınlık Temaya Geç' : 'Karanlık Temaya Geç',
                      style: TextStyle(fontSize: 14, color: AppTheme.getTextPrimary(context)),
                    ),
                    onTap: () => state.setThemeMode(isDark ? ThemeMode.light : ThemeMode.dark),
                  ),
                ],
              ),
            ),

            // 3. ALT ÇIKIŞ BUTONU (FOOTER)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: AppTheme.getCardBorder(context), width: 1)),
              ),
              child: ListTile(
                key: const Key('nav_drawer_logout'),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                tileColor: AppTheme.accentRed.withValues(alpha: 0.1),
                minTileHeight: 48,
                leading: Icon(Icons.logout, color: AppTheme.dangerText(context), size: 22),
                title: Text(
                  'Güvenli Çıkış Yap',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.dangerText(context),
                  ),
                ),
                // Onay + çıkış + navigator yığınını temizleme paylaşılan yardımcıdadır.
                onTap: () => confirmAndLogout(context, state),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static void _push(BuildContext context, Widget page) {
    Navigator.pop(context);
    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));
  }
}

class _DrawerItem extends StatelessWidget {
  const _DrawerItem({
    required this.itemKey,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.color,
  });

  final Key itemKey;
  final IconData icon;
  final String title;
  final String subtitle;
  final Color? color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final itemColor = color ?? (AppTheme.isDark(context) ? AppTheme.primaryBlueLight : AppTheme.primaryBlue);
    final iconColor = AppTheme.readableAccent(context, itemColor);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ListTile(
        key: itemKey,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        minTileHeight: 56,
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: itemColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: iconColor, size: 20),
        ),
        title: Text(
          title,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: AppTheme.getTextPrimary(context),
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(fontSize: 11.5, color: AppTheme.getTextMuted(context)),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Icon(Icons.chevron_right, size: 18, color: AppTheme.getTextMuted(context)),
        onTap: onTap,
      ),
    );
  }
}
