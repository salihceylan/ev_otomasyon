import 'package:flutter/material.dart';

import '../../pages/replace_board_dialog.dart';
import '../../pages/system_doctor_dialog.dart';
import '../../pages/wifi_recovery_dialog.dart';
import '../../theme/app_theme.dart';
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
        accent: Colors.cyanAccent,
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
              icon: const Icon(Icons.medical_services_outlined, size: 16),
              label: const Text(
                'Sistem Doktorunu Çalıştır',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                foregroundColor: AppTheme.readableAccent(context, Colors.cyanAccent),
                side: const BorderSide(color: Colors.cyanAccent),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
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
        icon: Icons.wifi_find_rounded,
        title: 'Wi-Fi Şifre Değişimi & Kurtarma',
        accent: Colors.amber,
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
              icon: const Icon(Icons.settings_ethernet, size: 16),
              label: const Text(
                'Kurtarma Modu Sihirbazını Aç',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                foregroundColor: AppTheme.readableAccent(context, Colors.amber),
                side: const BorderSide(color: Colors.amber),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
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
        icon: Icons.swap_horizontal_circle_outlined,
        title: 'Felaket Kurtarma & Pano Değişimi',
        accent: Colors.deepPurpleAccent,
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
              icon: const Icon(Icons.settings_backup_restore, size: 16),
              label: const Text(
                'Pano Değişimi Sihirbazını Aç',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                foregroundColor: AppTheme.readableAccent(context, Colors.deepPurpleAccent),
                side: const BorderSide(color: Colors.deepPurpleAccent),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
