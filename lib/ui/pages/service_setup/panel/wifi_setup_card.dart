import 'package:flutter/material.dart';

import '../../../../config/app_config.dart';
import '../../wifi_recovery_dialog.dart';
import '../device_link.dart';
import '../setup_style.dart';
import '../setup_widgets.dart';

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
    return SetupCard(
      key: const Key('card_wifi_setup'),
      accent: SetupColors.info,
      margin: margin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.wifi_find_rounded, color: SetupColors.readable(context, SetupColors.info), size: 24),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Pano Wi-Fi & Modem Kurulumu',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Müşterinin modemi ya da Wi-Fi şifresi değiştiyse telefonu panonun kurulum ağına (AHBU-...) bağlayıp '
            'yeni bilgiyi panoya yükleyin. Giriş yapmanız ya da internet olması gerekmez.',
            style: TextStyle(fontSize: 13.5, height: 1.4, color: SetupColors.muted(context)),
          ),
          const SizedBox(height: 12),
          SetupPrimaryButton(
            key: const Key('btn_wifi_setup_wizard'),
            label: 'Wi-Fi Kurulum & Kurtarma Sihirbazı',
            icon: Icons.wifi_tethering_rounded,
            onPressed: () => _open(context),
          ),
        ],
      ),
    );
  }
}
