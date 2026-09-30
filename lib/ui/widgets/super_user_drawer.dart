import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/automation_state.dart';
import '../pages/device_inventory_page.dart';
import '../pages/replace_board_dialog.dart';
import '../pages/service_management_page.dart';
import '../pages/service_mode_page.dart';
import '../pages/system_doctor_dialog.dart';
import '../pages/wifi_recovery_dialog.dart';
import '../pages/family/transfer_ownership_dialog.dart';
import '../theme/app_theme.dart';

/// AHBU Süper Yönetici Sandviç (Hamburger) Menüsü (Drawer)
class SuperUserDrawer extends StatelessWidget {
  const SuperUserDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AutomationState>(context);
    final user = state.currentUser;
    final isDark = state.themeMode == ThemeMode.dark;

    final isSuper = state.isSuperUser;
    final isService = state.isServiceUser;

    final badgeColor = isSuper ? AppTheme.accentPurple : AppTheme.accentCyan;
    final badgeText = isSuper ? 'SÜPER YÖNETİCİ KONSOLU' : 'YETKİLİ SERVİS KONSOLU';
    final badgeIcon = isSuper ? Icons.verified_user : Icons.engineering_rounded;

    return Drawer(
      backgroundColor: AppTheme.bgDark,
      child: SafeArea(
        child: Column(
          children: [
            // 1. ÜST BAŞLIK (HEADER)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
              decoration: BoxDecoration(
                color: AppTheme.cardDark,
                border: const Border(
                  bottom: BorderSide(color: AppTheme.cardBorder, width: 1),
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
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              user?.fullName.isNotEmpty == true
                                  ? user!.fullName
                                  : (isSuper ? 'Süper Yönetici' : 'Yetkili Servis Sorumlusu'),
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: AppTheme.textPrimary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              user?.email.isNotEmpty == true ? user!.email : 'servis@gudeteknoloji.com.tr',
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.textMuted,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  // Süper Kullanıcı / Servis Sorumlusu Rozeti
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
                        Icon(badgeIcon, color: badgeColor, size: 14),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            badgeText,
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.5,
                              color: badgeColor,
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

            // 2. MENÜ ELEMANLARI (NAVİGASYON)
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                children: [
                  _buildDrawerItem(
                    context: context,
                    icon: Icons.dashboard_outlined,
                    activeIcon: Icons.dashboard,
                    title: isSuper ? 'Yönetici Konsolu' : 'Servis Konsolu',
                    subtitle: isSuper
                        ? 'Sistem durumu & ana kontroller'
                        : 'Saha operasyonları & ana kontroller',
                    onTap: () {
                      Navigator.pop(context); // Menüyü kapat, zaten konsoldayız
                    },
                  ),
                  // =========================================================================
                  // YALNIZCA SÜPER YÖNETİCİ MENÜLERİ (Cihaz Ekleme/Düzenleme, Sorumlu & Sağlık)
                  // (Servis Sorumluları bu menüleri KESİNLİKLE GÖRMEZ)
                  // =========================================================================
                  if (isSuper) ...[
                    _buildDrawerItem(
                      context: context,
                      icon: Icons.inventory_2_outlined,
                      activeIcon: Icons.inventory_2,
                      title: 'Cihaz Envanteri',
                      subtitle: 'Karekodlar, seri no & fabrika kayıtları',
                      color: AppTheme.accentAmber,
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const DeviceInventoryPage()),
                        );
                      },
                    ),
                    _buildDrawerItem(
                      context: context,
                      icon: Icons.admin_panel_settings_outlined,
                      activeIcon: Icons.admin_panel_settings,
                      title: 'Servis Sorumluları',
                      subtitle: 'Yetkili servisleri ekle & düzenle',
                      color: AppTheme.accentCyan,
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const ServiceManagementPage(initialTabIndex: 0),
                          ),
                        );
                      },
                    ),
                    _buildDrawerItem(
                      context: context,
                      icon: Icons.health_and_safety_outlined,
                      activeIcon: Icons.health_and_safety,
                      title: 'Sistem Doktoru',
                      subtitle: 'DB, MQTT ve sistem sağlığı teşhisi',
                      color: Colors.cyanAccent,
                      onTap: () {
                        Navigator.pop(context);
                        SystemDoctorDialog.show(context);
                      },
                    ),
                  ],
                  // =========================================================================
                  // YALNIZCA SERVİS SORUMLULARI İÇİN SAHA & MONTAJ OPERASYON ARAÇLARI
                  // (Süper Kullanıcıda bu menüler bulunmaz; Servis Sorumlularına özgüdür)
                  // =========================================================================
                  if (isService) ...[
                    _buildDrawerItem(
                      context: context,
                      icon: Icons.verified_outlined,
                      activeIcon: Icons.verified,
                      title: 'Devreye Alma & Servis Modu',
                      subtitle: 'Karekod eşleme, canlı test & onay',
                      color: AppTheme.accentCyan,
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const ServiceModePage()),
                        );
                      },
                    ),
                    _buildDrawerItem(
                      context: context,
                      icon: Icons.published_with_changes_outlined,
                      activeIcon: Icons.published_with_changes,
                      title: 'Pano Değişimi (Afet Modu)',
                      subtitle: 'Buluttan birebir pano aktarımı',
                      color: Colors.tealAccent,
                      onTap: () {
                        Navigator.pop(context);
                        ReplaceBoardDialog.show(context);
                      },
                    ),
                    _buildDrawerItem(
                      context: context,
                      icon: Icons.wifi_find_outlined,
                      activeIcon: Icons.wifi_find,
                      title: 'Wi-Fi Yapılandırma & Kurtarma',
                      subtitle: 'Modem değişimi & Pano Smart AP',
                      color: AppTheme.accentAmber,
                      onTap: () {
                        Navigator.pop(context);
                        WifiRecoveryDialog.show(context);
                      },
                    ),
                    _buildDrawerItem(
                      context: context,
                      icon: Icons.sync_problem_rounded,
                      activeIcon: Icons.sync_problem,
                      title: 'Acil Sıfırlama & Mülk Devri',
                      subtitle: 'Eski sahibini boşa çıkar & yeni daireye devret',
                      color: Colors.redAccent,
                      onTap: () {
                        Navigator.pop(context);
                        showDialog(
                          context: context,
                          builder: (_) => const TransferOwnershipDialog(),
                        );
                      },
                    ),
                  ],
                  const Divider(color: AppTheme.cardBorder, height: 24, indent: 8, endIndent: 8),
                  // Tema Geçişi
                  ListTile(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    leading: Icon(
                      isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
                      color: isDark ? AppTheme.accentAmber : AppTheme.primaryBlueLight,
                      size: 22,
                    ),
                    title: Text(
                      isDark ? 'Aydınlık Temaya Geç' : 'Karanlık Temaya Geç',
                      style: const TextStyle(fontSize: 14, color: AppTheme.textPrimary),
                    ),
                    onTap: () {
                      state.setThemeMode(isDark ? ThemeMode.light : ThemeMode.dark);
                    },
                  ),
                ],
              ),
            ),

            // 3. ALT ÇIKIŞ BUTONU (FOOTER)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: AppTheme.cardBorder, width: 1)),
              ),
              child: ListTile(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                tileColor: AppTheme.accentRed.withValues(alpha: 0.1),
                leading: const Icon(Icons.logout, color: AppTheme.accentRed, size: 22),
                title: const Text(
                  'Güvenli Çıkış Yap',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.accentRed,
                  ),
                ),
                onTap: () async {
                  Navigator.pop(context);
                  await state.logout();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDrawerItem({
    required BuildContext context,
    required IconData icon,
    required IconData activeIcon,
    required String title,
    required String subtitle,
    Color? color,
    required VoidCallback onTap,
  }) {
    final itemColor = color ?? AppTheme.primaryBlueLight;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: itemColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: itemColor, size: 20),
        ),
        title: Text(
          title,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: AppTheme.textPrimary,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          subtitle,
          style: const TextStyle(
            fontSize: 11.5,
            color: AppTheme.textMuted,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.chevron_right, size: 18, color: AppTheme.textMuted),
        onTap: onTap,
      ),
    );
  }
}
