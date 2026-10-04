import 'package:flutter/material.dart';

import '../../pages/replace_board_dialog.dart';
import '../../pages/system_doctor_dialog.dart';
import '../../pages/wifi_recovery_dialog.dart';
import '../../theme/feature_accent.dart';
import 'accent_button.dart';
import 'settings_card.dart';

/// Sistem doktoru (teşhis) kartı. Yetki sayfada denetlenir (`canChangeChildLock`: tanılama
/// misafire kapalıdır). Anahtarlar: `Key('card_system_doctor')`, `Key('btn_system_doctor')`.
class SystemDoctorCard extends StatelessWidget {
  const SystemDoctorCard({super.key});

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: const Key('card_system_doctor'),
      child: SettingsCard(
        icon: Icons.health_and_safety,
        title: 'Sistem Doktoru (Teşhis & Analiz)',
        accent: AppFeature.doctor.accentFamily.base,
        children: [
          const CardCaption(
            'Uygulama veya otomasyon panosunda sorun mu yaşıyorsunuz? Bulut, internet ve pano '
            'durumunu tek dokunuşla analiz edin.',
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const Key('btn_system_doctor'),
              onPressed: () => SystemDoctorDialog.show(context),
              icon: Icon(Icons.medical_services_outlined, size: accentIconSize(context)),
              label: const Text(
                'Sistem Doktorunu Çalıştır',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              style: accentOutlinedButtonStyle(context, AppFeature.doctor.accentFamily),
            ),
          ),
        ],
      ),
    );
  }
}

/// Wi-Fi şifre değişimi & kurtarma kartı. Yetki sayfada denetlenir (`canOpenWifiRecovery`).
/// Anahtarlar: `Key('card_wifi_recovery')`, `Key('btn_wifi_recovery')`.
class WifiRecoveryCard extends StatelessWidget {
  const WifiRecoveryCard({super.key});

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: const Key('card_wifi_recovery'),
      child: SettingsCard(
        // Dolu/kalın glif (wifi_find ince "göz + büyüteç" okunuyordu): Wi-Fi + kilit = şifre değişimi.
        icon: Icons.wifi_password_rounded,
        title: 'Wi-Fi Şifre Değişimi & Kurtarma',
        accent: AppFeature.wifiRecovery.accentFamily.base,
        children: [
          const CardCaption(
            'Evinizdeki modem veya Wi-Fi şifresi değiştiyse panoya yeni bilgileri aktarmak için '
            'kurtarma sihirbazını başlatın.',
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const Key('btn_wifi_recovery'),
              onPressed: () => WifiRecoveryDialog.show(context),
              icon: Icon(Icons.settings_ethernet, size: accentIconSize(context)),
              label: const Text(
                'Kurtarma Modu Sihirbazını Aç',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              style: accentOutlinedButtonStyle(context, AppFeature.wifiRecovery.accentFamily),
            ),
          ),
        ],
      ),
    );
  }
}

/// Pano değişimi kartı. Yetki sayfada denetlenir (`canReplaceBoard`: ev sahibi, servis, süper).
/// Anahtarlar: `Key('card_replace_board')`, `Key('btn_replace_board')`.
class ReplaceBoardCard extends StatelessWidget {
  const ReplaceBoardCard({super.key});

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: const Key('card_replace_board'),
      child: SettingsCard(
        icon: Icons.swap_horiz_rounded,
        title: 'Felaket Kurtarma & Pano Değişimi',
        accent: AppFeature.boardReplace.accentFamily.base,
        children: [
          const CardCaption(
            'Arızalanan veya yıldırım düşen panoyu yenisiyle değiştirdiğinizde oda isimleri ve '
            'ayarlarınız yeni panoya aktarılır.',
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const Key('btn_replace_board'),
              onPressed: () => ReplaceBoardDialog.show(context),
              icon: Icon(Icons.settings_backup_restore, size: accentIconSize(context)),
              label: const Text(
                'Pano Değişimi Sihirbazını Aç',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              style: accentOutlinedButtonStyle(context, AppFeature.boardReplace.accentFamily),
            ),
          ),
        ],
      ),
    );
  }
}
