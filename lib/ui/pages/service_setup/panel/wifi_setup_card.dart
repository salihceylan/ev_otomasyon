import 'package:flutter/material.dart';

import '../../../../config/app_config.dart';
import '../../wifi_recovery_dialog.dart';
import '../device_link.dart';
import '../setup_style.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/orb/orb_icon_badge.dart';
import 'service_glass.dart';
import '../setup_widgets.dart';
import '../../../theme/feature_accent.dart';

/// "Pano Wi-Fi & Modem Kurulumu" kartı ve "Wi-Fi Kurulum & Kurtarma Sihirbazı" düğmesi
/// (canlı test listesi Aşama 16.1).
///
/// **Giriş durumundan bağımsızdır**: servis PIN'iyle ya da personel hesabıyla girilmiş olsun ya da
/// olmasın görünür ve çalışır; yetki kapısı ve internet gerektirmez. Düğme E2'nin
/// [WifiRecoveryDialog]'unu açar (kopya yok): pano yalnızca kendi WPA2 kurulum ağından (SoftAP) gelen
/// Wi-Fi isteklerine anahtarsız izin verir (CONTRACTS §3d), bu yüzden sunucudan anahtar alınmaz.
///
/// Anahtarlar: `card_wifi_setup`, `btn_wifi_setup_wizard`.
class WifiSetupCard extends StatelessWidget {
  const WifiSetupCard({super.key, this.margin = const EdgeInsets.only(top: 12), this.deviceApiFactory});

  final EdgeInsetsGeometry margin;

  /// Yalnızca testlerde: kurulum ağı (AP) istemcisini üretir (sahte `http.Client`). `null` ise sihirbaz kendi
  /// istemcisini kurar (`AutomationApiService.recoveryAp`, adres `AppConfig.deviceApHost`).
  final DeviceApiFactory? deviceApiFactory;

  Future<void> _open(BuildContext context) async {
    final api = deviceApiFactory?.call(AppConfig.current.deviceApHost);
    try {
      await WifiRecoveryDialog.show(context, api: api);
    } finally {
      api?.dispose(); // sihirbaz çağıranın verdiği istemciye sahip değildir
    }
  }

  @override
  Widget build(BuildContext context) {
    // Özellik rengi (Wi-Fi: amber) orb'da ve düğmede taşınır; kart KENARI vurgulu DEĞİL (çapraz eleştirmen #7: servis girişi
    // ekranında PIN kartıyla yan yana iki amber kenarlı kart "her şey yanıyor" izlenimi veriyordu).
    return ServiceCard(
      key: const Key('card_wifi_setup'),
      margin: margin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              OrbIconBadge(icon: Icons.wifi_rounded, family: AppFeature.wifiRecovery.accentFamily),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Pano Wi-Fi & Modem Kurulumu',
                  style: TextStyle(fontSize: AppText.cardTitle, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Müşterinin modemi ya da Wi-Fi şifresi değiştiyse telefonu panonun kurulum ağına (AHBU-...) bağlayıp '
            'yeni bilgiyi panoya yükleyin. Giriş yapmanız ya da internet olması gerekmez.',
            style: TextStyle(fontSize: AppText.body, height: 1.4, color: SetupColors.muted(context)),
          ),
          const SizedBox(height: 12),
          // İkincil akış: çerçeveli hap (gradyan hap sayfa başına tek birincil eylemdir: "Servis Oturumu Aç" / "Yeni Kurulum Başlat").
          SetupSecondaryButton(
            key: const Key('btn_wifi_setup_wizard'),
            label: 'Wi-Fi Kurulum & Kurtarma Sihirbazı',
            icon: Icons.wifi_tethering_rounded,
            family: AppFeature.wifiRecovery.accentFamily,
            onPressed: () => _open(context),
          ),
        ],
      ),
    );
  }
}
