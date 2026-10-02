import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/capabilities.dart';
import '../../services/automation_state.dart';
import '../widgets/settings/action_cards.dart';
import '../widgets/settings/appearance_cards.dart';
import '../widgets/settings/child_lock_card.dart';
import '../widgets/settings/device_host_card.dart';
import '../widgets/settings/info_cards.dart';
import '../widgets/settings/peace_notification_card.dart';
import '../widgets/settings/scheduled_rules_card.dart';
import '../widgets/settings/service_pin_card.dart';
import '../theme/app_theme.dart';

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

    final cards = <Widget>[
      if (caps.hasHomeAccess || direct) const HardwareNoticeCard(),
      const RoleNoticeCard(),
      if (caps.hasHomeAccess && caps.canChangeChildLock) const SystemDoctorCard(),
      if (caps.canViewState) const ChildLockCard(),
      if (cloud && caps.canChangeChildLock && caps.hasHomeAccess) const PeaceNotificationCard(),
      if (cloud && caps.canManageRules) const ScheduledRulesCard(),
      if (vm.hasUser) const BiometricCard(),
      const ThemeSelectorCard(),
      if (cloud && caps.canGenerateServicePin) const ServicePinCard(),
      if (caps.canOpenWifiRecovery) const WifiRecoveryCard(),
      if (caps.canReplaceBoard) const ReplaceBoardCard(),
      if (caps.canEditDeviceHost) const DeviceHostCard(),
      if (vm.hasStatus && !caps.isGuest) const TelemetryCard(),
      if (vm.hasUser) const AccountCard(),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/images/app_logo.png',
                width: 28,
                height: 28,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const Icon(Icons.settings_outlined, size: 24),
              ),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Cihaz & Sistem Ayarları',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
      // Kartlar tembel listelenmez: ekrandan çıkan kart durumunu (ör. bir kez gösterilen servis
      // PIN'i, yazılmış metinler) kaybetmesin.
      body: SingleChildScrollView(
        key: const Key('view_settings'),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final card in cards) ...[card, const SizedBox(height: 16)],
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
