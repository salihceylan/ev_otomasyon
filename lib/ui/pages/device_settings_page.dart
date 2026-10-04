import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/capabilities.dart';
import '../../services/automation_state.dart';
import '../theme/feature_accent.dart';
import '../widgets/neon_app_bar.dart';
import '../widgets/settings/action_cards.dart';
import '../widgets/settings/appearance_cards.dart';
import '../widgets/settings/child_lock_card.dart';
import '../widgets/settings/device_host_card.dart';
import '../widgets/settings/info_cards.dart';
import '../widgets/settings/peace_notification_card.dart';
import '../widgets/settings/scheduled_rules_card.dart';
import '../widgets/settings/service_pin_card.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/settings/settings_card.dart';

typedef _PageVm = ({Capabilities caps, AppMode mode, bool hasUser, bool hasStatus});

/// Cihaz & Sistem Ayarları.
///
/// Her kart **`Capabilities`'e göre** gösterilir (beyaz liste; kara liste yok):
///
/// | Kart | Koşul |
/// |---|---|
/// | Çocuk kilidi | `canViewState` (misafir salt-okunur görür; değiştirme `canChangeChildLock`) |
/// | Gece huzur bildirimi | bulut modu + `canChangeChildLock` |
/// | Zamanlı kurallar | bulut modu + `canManageRules` |
/// | Sistem doktoru | aktif eve erişim + `canChangeChildLock` |
/// | Servis PIN'i | bulut modu + `canGenerateServicePin` (ev sahibi) |
/// | Wi-Fi kurtarma / cihaz adresi | `canOpenWifiRecovery` / `canEditDeviceHost` (misafir ✖) |
/// | Pano değişimi | `canReplaceBoard` |
/// | Telemetri | cihaz yanıt verdi + misafir değil |
///
/// Sayfa kökü durumu izlemez; yalnızca kart görünürlüğü için tek bir `select` kullanır, kartlar
/// kendi değerlerini seçer. Bu dosya yalnızca iskelettir; kartlar `lib/ui/widgets/settings/**` altındadır.
class DeviceSettingsPage extends StatelessWidget {
  const DeviceSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.select<AutomationState, _PageVm>(
      (s) => (
        caps: s.capabilities,
        mode: s.mode,
        hasUser: s.currentUser != null,
        hasStatus: s.status != null,
      ),
    );
    final caps = vm.caps;
    final cloud = vm.mode == AppMode.cloud;
    final direct = vm.mode == AppMode.direct;

    final notices = <Widget>[
      if (caps.hasHomeAccess || direct) const HardwareNoticeCard(),
      const RoleNoticeCard(),
    ];
    // Bölümler: çocuk kilidi Güvenlik'in ilk kartıdır (sayfadaki ilk Switch sözleşmesi). Bölüm başlığı rengi de özellik haritasından
    // gelir ([AppFeature]): bölümün kartlarıyla AYNI aile.
    final sections = <(String, IconData, AccentFamily, List<Widget>)>[
      (
        'Güvenlik',
        Icons.shield_rounded,
        AppFeature.childLock.accentFamily,
        [
          if (caps.canViewState) const ChildLockCard(),
          if (vm.hasUser) const BiometricCard(),
          if (cloud && caps.canGenerateServicePin) const ServicePinCard(),
        ],
      ),
      ('Görünüm', Icons.palette_rounded, AppFeature.appearance.accentFamily, [const ThemeSelectorCard()]),
      (
        'Cihaz',
        Icons.developer_board_rounded,
        AppFeature.settings.accentFamily,
        [
          if (caps.hasHomeAccess && caps.canChangeChildLock) const SystemDoctorCard(),
          if (caps.canOpenWifiRecovery) const WifiRecoveryCard(),
          if (caps.canReplaceBoard) const ReplaceBoardCard(),
          if (caps.canEditDeviceHost) const DeviceHostCard(),
          if (vm.hasStatus && !caps.isGuest) const TelemetryCard(),
        ],
      ),
      (
        'Otomasyon',
        Icons.auto_mode_rounded,
        AppFeature.nightPeace.accentFamily,
        [
          if (cloud && caps.canChangeChildLock && caps.hasHomeAccess) const PeaceNotificationCard(),
          if (cloud && caps.canManageRules) const ScheduledRulesCard(),
        ],
      ),
      ('Aile', Icons.family_restroom_rounded, AppFeature.family.accentFamily, [if (vm.hasUser) const AccountCard()]),
    ];

    return Scaffold(
      // Ortak Neon Glass üst çubuk (geri diski + özellik orb'u + başlık; kaydırınca ton yok): başlık kesilmez.
      appBar: const NeonAppBar(
        title: 'Cihaz & Sistem Ayarları',
        feature: AppFeature.settings,
        icon: Icons.settings_rounded,
      ),
      // Kartlar tembel listelenmez: ekrandan çıkan kart durumunu (ör. bir kez gösterilen servis
      // PIN'i, yazılmış metinler) kaybetmesin.
      body: SingleChildScrollView(
        key: const Key('view_settings'),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final notice in notices) ...[notice, const SizedBox(height: 12)],
            for (var i = 0; i < sections.length; i++)
              if (sections[i].$4.isNotEmpty) ...[
                SettingsSection(
                  index: i,
                  title: sections[i].$1,
                  icon: sections[i].$2,
                  family: sections[i].$3,
                  children: sections[i].$4,
                ),
                const SizedBox(height: 20),
              ],
            const _AppInfo(),
          ],
        ),
      ),
    );
  }
}

class _AppInfo extends StatelessWidget {
  const _AppInfo();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 12),
      child: Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.asset(
              'assets/images/app_logo.png',
              width: 68,
              height: 68,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const Icon(Icons.home_work_rounded, size: 48),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'AHBU OTOMASYON',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: AppTheme.getTextPrimary(context),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Akıllı Ev & Bina Otomasyon Sistemleri',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: AppTheme.getTextMuted(context)),
          ),
        ],
      ),
    );
  }
}
