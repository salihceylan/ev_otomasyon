import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/capabilities.dart';
import '../../services/automation_state.dart';
import '../common/confirm_dialogs.dart';
import '../motion/motion.dart';
import '../pages/device_inventory_page.dart';
import '../pages/family/transfer_ownership_dialog.dart';
import '../pages/replace_board_dialog.dart';
import '../pages/service_management_page.dart';
import '../pages/service_mode_page.dart';
import '../pages/service_subscribers_page.dart';
import '../pages/system_doctor_dialog.dart';
import '../pages/wifi_recovery_dialog.dart';
import '../theme/app_theme.dart';
import '../theme/feature_accent.dart';
import '../theme/tokens.dart';
import 'orb/orb.dart';
import 'glass_pill.dart';
import 'scroll_cue.dart';

/// Süper yönetici / yetkili servis çekmecesi (sandviç menü), Neon Glass dili: başlıkta avatar orb halkası,
/// öğeler [OrbIconBadge]'li yuvarlatılmış satırlar, açılışta kademeli belirme (her açılışta tek sefer).
///
/// Girdiler **`Capabilities`'ten** türetilir (rol adı karşılaştırması yok):
/// * süper kullanıcı: envanter (`canManageInventory`), servis sorumluları (`canManageAdminAccounts`),
///   tüm aboneler (`canViewInventory`), sistem doktoru;
/// * kalıcı servis personeli (`isStaff`): servis modu, aboneler, pano değişimi, Wi-Fi kurtarma;
///   acil sıfırlama (`canEmergencyReset`).
///
/// Çıkış, onaylı çıkıştır ([confirmAndLogout]; navigator yığınını temizler). Anahtarlar:
/// `Key('nav_drawer')`, `Key('nav_drawer_<ad>')`, `Key('nav_drawer_logout')`.
/// Çekmece içinde **`Scaffold` YOKTUR** (yönetici panosunun tek `Scaffold`'u korunur).
///
/// Büyük yazı ölçeğinde (1.5/2.0) başlık/alt başlıklar **kesilmez** (satıra sarılır; satırlar uzar) ve rol rozeti
/// iki satıra sarılır; liste sığmazsa sağ kenarda kalıcı ince kaydırma çubuğu gösterilir ([ScrollCue]).
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

    // Konsol kimliği (rol): çekmece başlığı + 'Konsol' satırı + konsol başlık kartı AYNI özellik ailesi ([AppFeature.superConsole]/
    // [AppFeature.serviceConsole]).
    final family = (isSuper ? AppFeature.superConsole : AppFeature.serviceConsole).accentFamily;
    final badgeColor = family.base;
    final badgeText = isSuper ? 'SÜPER YÖNETİCİ KONSOLU' : 'YETKİLİ SERVİS KONSOLU';
    final badgeIcon = isSuper ? Icons.verified_user_rounded : Icons.engineering_rounded;
    final displayName = user.name.trim().isNotEmpty
        ? user.name.trim()
        : (isSuper ? 'Süper Yönetici' : 'Yetkili Servis Sorumlusu');
    final tokens = SurfaceTokens.of(isDark ? Brightness.dark : Brightness.light);
    // Koyu temada çekmece yüzeyi sayfa zemininden (#0B1120) AYRIŞIR: bir kademe açık yüzey (#131D31) + sağ kenarda
    // rim (önceden scrim altındaki sayfadan ≈ 1.1:1 ile ayrışıyor, tablette kenarı kayboluyordu).
    final drawerBg = isDark ? AppTheme.surfaceDark : AppTheme.getDrawerBg(context);
    final muted = AppTheme.getTextMuted(context);

    // Öğe listesi (görünürlük kuralları rolden değil Capabilities'ten); kademe sırası bu listedir. Aile (renk) atamaları TEK
    // özellik haritasından gelir ([AppFeature]): aynı özellik konsolda, araç kartında ve sayfa başlığında AYNI renktedir; listedeki
    // iki özellik aynı aileyi paylaşmaz ([FeatureGroups.superDrawer]/[FeatureGroups.serviceDrawer]).
    final items = <Widget>[
      _DrawerItem(
        itemKey: const Key('nav_drawer_console'),
        icon: Icons.dashboard_rounded,
        title: isSuper ? 'Yönetici Konsolu' : 'Servis Konsolu',
        subtitle: isSuper ? 'Sistem durumu & ana kontroller' : 'Saha operasyonları & ana kontroller',
        family: family,
        selected: true,
        onTap: () => Navigator.pop(context),
      ),
      if (caps.canManageInventory)
        _DrawerItem(
          itemKey: const Key('nav_drawer_inventory'),
          icon: Icons.inventory_2_rounded,
          title: 'Cihaz Envanteri',
          subtitle: 'Karekodlar, seri no & fabrika kayıtları',
          family: AppFeature.inventory.accentFamily,
          onTap: () => _push(context, const DeviceInventoryPage()),
        ),
      if (caps.canManageAdminAccounts)
        _DrawerItem(
          itemKey: const Key('nav_drawer_service_managers'),
          icon: Icons.admin_panel_settings_rounded,
          title: 'Servis Sorumluları',
          subtitle: 'Yetkili servisleri ekle & düzenle',
          family: AppFeature.management.accentFamily,
          onTap: () => _push(context, const ServiceManagementPage(initialTabIndex: 0)),
        ),
      if (caps.canViewInventory)
        _DrawerItem(
          itemKey: const Key('nav_drawer_subscribers'),
          icon: Icons.people_alt_rounded,
          title: isSuper ? 'Tüm Aboneler & Atamalar' : 'Abonelerim & Cihaz Atama',
          subtitle: isSuper ? 'Daireler, panolar & Home Admin listesi' : 'Kayıtlı panolar & Home Admin atama',
          family: AppFeature.subscribers.accentFamily,
          onTap: () => _push(context, const ServiceSubscribersPage()),
        ),
      if (isSuper)
        _DrawerItem(
          itemKey: const Key('nav_drawer_doctor'),
          icon: Icons.health_and_safety_rounded,
          title: 'Sistem Doktoru',
          subtitle: 'DB, MQTT ve sistem sağlığı teşhisi',
          family: AppFeature.doctor.accentFamily,
          onTap: () {
            Navigator.pop(context);
            SystemDoctorDialog.show(context);
          },
        ),
      if (fieldStaff) ...[
        _DrawerItem(
          itemKey: const Key('nav_drawer_commissioning'),
          icon: Icons.verified_rounded,
          title: 'Devreye Alma & Servis Modu',
          subtitle: 'Karekod eşleme, canlı test & onay',
          family: AppFeature.commissioning.accentFamily,
          onTap: () => _push(context, const ServiceModePage()),
        ),
        _DrawerItem(
          itemKey: const Key('nav_drawer_replace_board'),
          icon: Icons.published_with_changes_rounded,
          title: 'Pano Değişimi (Afet Modu)',
          subtitle: 'Buluttan birebir pano aktarımı',
          family: AppFeature.boardReplace.accentFamily,
          onTap: () {
            Navigator.pop(context);
            ReplaceBoardDialog.show(context);
          },
        ),
        _DrawerItem(
          itemKey: const Key('nav_drawer_wifi_recovery'),
          icon: Icons.wifi_rounded,
          title: 'Wi-Fi Yapılandırma & Kurtarma',
          subtitle: 'Modem değişimi & Pano Smart AP',
          family: AppFeature.wifiRecovery.accentFamily,
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
          family: AppFeature.emergencyReset.accentFamily,
          onTap: () {
            Navigator.pop(context);
            TransferOwnershipDialog.show(context, initialTab: 1);
          },
        ),
    ];

    return Drawer(
      key: const Key('nav_drawer'),
      backgroundColor: drawerBg,
      // Sağ kenar: yuvarlatılmış köşe + 1 px rim (yüzey scrim altındaki sayfadan seçilsin).
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadiusDirectional.horizontal(end: Radius.circular(AppRadius.sheet)),
        side: BorderSide(color: tokens.rimSolid),
      ),
      child: SafeArea(
        child: Column(
          children: [
            // 1. ÜST BAŞLIK (HEADER)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 18),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color.alphaBlend(badgeColor.withValues(alpha: isDark ? 0.20 : 0.14), AppTheme.getDrawerHeaderBg(context)),
                    AppTheme.getDrawerHeaderBg(context),
                  ],
                ),
                border: Border(bottom: BorderSide(color: tokens.rimSolid, width: 1)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _HeaderAvatar(family: family, fallbackIcon: badgeIcon),
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
                                style: TextStyle(fontSize: 12, color: muted),
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
                  // Rol rozeti: ortak [GlassPill]; yazı ölçeği büyüyünce satıra SARILIR (önceden 1.5x'te
                  // 'SÜPER YÖNETİCİ KONS…' diye kesiliyordu).
                  GlassPill(
                    color: badgeColor,
                    label: badgeText,
                    letterSpacing: 0.4,
                    leading: Icon(badgeIcon, color: AppTheme.readableAccent(context, badgeColor), size: 14),
                  ),
                ],
              ),
            ),

            // 2. MENÜ ELEMANLARI (en çok 8 öğe kademeli belirir; kalanı anında)
            Expanded(
              child: ScrollCue(
                color: muted.withValues(alpha: 0.55),
                builder: (context, controller) => ListView(
                  controller: controller,
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
                  children: [
                    for (var i = 0; i < items.length; i++)
                      StaggeredEntrance(
                        key: ValueKey<int>(i),
                        index: math.min(i, AppMotion.staggerMaxItems - 1),
                        child: items[i],
                      ),
                    Divider(color: tokens.rimSolid, height: 24, indent: 8, endIndent: 8),
                    _DrawerRow(
                      itemKey: const Key('nav_drawer_theme'),
                      // Ters yönde geçiş: koyuyken aydınlığa (güneş), aydınlıkken karanlığa (ay). Tema satırı bir ÖZELLİK
                      // değil uygulama aracıdır: özellik haritasının dışında NÖTR (slate) orb; eskiden koyuda amber / açıkta
                      // violet idi ve aynı listedeki 'Wi-Fi Kurtarma' / 'Pano Değişimi' / 'Yönetici Konsolu' renklerini tekrar ediyordu.
                      icon: isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                      family: AppFamilies.slate,
                      title: isDark ? 'Aydınlık Temaya Geç' : 'Karanlık Temaya Geç',
                      semanticLabel: isDark ? 'Aydınlık Temaya Geç' : 'Karanlık Temaya Geç',
                      // Sayfaya GİTMEZ, anında geçiş yapar: ok (›) yerine geçiş simgesi (yanlış yönlendirme sinyali yok).
                      trailing: Icon(Icons.swap_horiz_rounded, size: 20, color: muted),
                      onTap: () => state.setThemeMode(isDark ? ThemeMode.light : ThemeMode.dark),
                    ),
                  ],
                ),
              ),
            ),

            // 3. ALT ÇIKIŞ BUTONU (FOOTER)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: tokens.rimSolid, width: 1)),
              ),
              child: _DrawerRow(
                itemKey: const Key('nav_drawer_logout'),
                icon: Icons.logout_rounded,
                family: AppFamilies.rose,
                title: 'Güvenli Çıkış Yap',
                semanticLabel: 'Güvenli Çıkış Yap',
                danger: true,
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

/// Başlık avatarı: logo, aile renginde parlak halka (statik) içinde.
class _HeaderAvatar extends StatelessWidget {
  const _HeaderAvatar({required this.family, required this.fallbackIcon});

  final AccentFamily family;
  final IconData fallbackIcon;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Container(
        width: 60,
        height: 60,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: SweepGradient(
            colors: [family.light, family.base, family.deep, family.base, family.light],
          ),
          boxShadow: [BoxShadow(color: family.base.withValues(alpha: 0.38), blurRadius: 16, offset: const Offset(0, 5))],
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppTheme.getDrawerHeaderBg(context),
          ),
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: ClipOval(
              child: Image.asset(
                'assets/images/round_app_logo.png',
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Icon(fallbackIcon, color: family.base),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Ortak çekmece satırı: yuvarlatılmış cam yüzey + [OrbIconBadge] + başlık (+ alt başlık) + ok; basınca ölçek
/// geri bildirimi ([Pressable], `onTap` gecikmesiz). Dokunma hedefi ≥ 56 dp.
///
/// Başlık ve alt başlık **satır sınırı olmadan** sarılır (büyük yazı ölçeğinde 'Eski sahibine ulaşılamayan panoy…'
/// gibi kelime ortasından kesilmez; satır uzar, liste kaydırılır). Köşe yarıçapı [AppRadius.r16]: liste SATIRI sınıfı
/// (kartlar r20, kart içi kutular r12).
class _DrawerRow extends StatelessWidget {
  const _DrawerRow({
    required this.itemKey,
    required this.icon,
    required this.family,
    required this.title,
    required this.semanticLabel,
    required this.onTap,
    this.subtitle,
    this.selected = false,
    this.danger = false,
    this.trailing,
  });

  final Key itemKey;
  final IconData icon;
  final AccentFamily family;
  final String title;
  final String? subtitle;
  final String semanticLabel;
  final bool selected;
  final bool danger;
  final VoidCallback onTap;

  /// Sağdaki öğe; `null` ise gezinme oku (›). Sayfaya gitmeyen satırlar (anlık geçiş) kendi simgesini verir.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final dark = AppTheme.isDark(context);
    final tokens = SurfaceTokens.of(dark ? Brightness.dark : Brightness.light);
    final tint = family.base;
    final titleColor = danger ? AppTheme.dangerText(context) : AppTheme.getTextPrimary(context);
    final emphasis = selected || danger;

    return Semantics(
      button: true,
      selected: selected,
      excludeSemantics: true,
      label: subtitle == null ? semanticLabel : '$semanticLabel. $subtitle',
      onTap: onTap,
      child: Pressable(
        key: itemKey,
        onTap: onTap,
        pressedScale: 0.975,
        child: RepaintBoundary(
          child: Container(
            constraints: const BoxConstraints(minHeight: 56),
            padding: const EdgeInsetsDirectional.fromSTEB(8, 6, 10, 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.r16),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color.alphaBlend(tint.withValues(alpha: emphasis ? 0.18 : 0.05), tokens.cardTop),
                  Color.alphaBlend(tint.withValues(alpha: emphasis ? 0.08 : 0.02), tokens.cardBottom),
                ],
              ),
              border: Border.all(color: emphasis ? tint.withValues(alpha: 0.50) : tokens.rimSolid),
            ),
            child: Row(
              children: [
                OrbIconBadge(icon: icon, family: family, active: selected),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: danger || selected ? FontWeight.w700 : FontWeight.w600,
                          color: titleColor,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          style: TextStyle(fontSize: 12, color: AppTheme.getTextMuted(context)),
                        ),
                      ],
                    ],
                  ),
                ),
                if (!danger) ...[
                  const SizedBox(width: 6),
                  trailing ?? Icon(Icons.chevron_right_rounded, size: 20, color: AppTheme.getTextMuted(context)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DrawerItem extends StatelessWidget {
  const _DrawerItem({
    required this.itemKey,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    required this.family,
    this.selected = false,
  });

  final Key itemKey;
  final IconData icon;
  final String title;
  final String subtitle;
  final AccentFamily family;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: _DrawerRow(
        itemKey: itemKey,
        icon: icon,
        family: family,
        title: title,
        subtitle: subtitle,
        semanticLabel: title,
        selected: selected,
        onTap: onTap,
      ),
    );
  }
}
