import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../models/automation_models.dart';
import '../../../models/capabilities.dart';
import '../../../models/cloud_models.dart';
import '../../../services/automation_state.dart';
import '../../common/confirm_dialogs.dart';
import '../../dashboard/labels.dart';
import '../../theme/app_theme.dart';
import '../../theme/feature_accent.dart';
import '../../theme/tokens.dart';
import '../orb/orb.dart';
import '../surface_card.dart';
import '../user_profile_dialog.dart';
import 'accent_button.dart';
import 'settings_card.dart';

/// Donanım & motor koruma bilgilendirmesi. Anahtar: `Key('card_hardware_notice')`.
class HardwareNoticeCard extends StatelessWidget {
  const HardwareNoticeCard({super.key});

  @override
  Widget build(BuildContext context) {
    // Statik bilgi kartı: kart KENARI vurgusuz (nötr), başlık kart başlığı dili (15/700, birincil metin). Kart kenarı yalnız
    // canlı (active) durumda vurgulanır; sürekli sky kenarlı + mavi başlıklı statik kart "seçili/etkin" gibi görünüp sayfanın
    // ilk ekranındaki en vurgulu kart oluyordu. Mavi ton yalnız orb'da kalır.
    return SurfaceCard(
      key: const Key('card_hardware_notice'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Etkileşimsiz bilgi kartı: soluk parıltı (glow) ama "active" değil; sayfanın en parlak öğesi asıl
          // kontroller (çocuk kilidi, servis PIN'i …) olmalıdır.
          const OrbIconBadge(icon: Icons.security_rounded, family: AppFamilies.sky, glow: true),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Donanım & Motor Koruması',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: AppText.cardTitle,
                    color: AppTheme.getTextPrimary(context),
                  ),
                ),
                const SizedBox(height: 4),
                const CardCaption(
                  'Elektrik kesintisi dönüşünde lambalar kapalı kalır, panjurlar hareket etmez. '
                  'Panjurlar tam açma/kapamada mekanik limite oturması için kısa bir ek süre çalışır. '
                  'Çocuk kilidi açıksa elektrik gelince de sürer.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Evin servisi (salt okunur): **`Servisiniz: ad · telefon`**. Sunucu `GET /homes` yanıtında her evde `service:
/// {name, phone}` verir (servis sorumlusu kapsamı, migration 045); ev kök kapsamındaysa ya da eski sunucuda `service`
/// yoktur ve kart HİÇ çizilmez. Müşteri servisi kaldıramaz, değiştiremez: değişikliği yalnız kök yönetici yapar (kart bunu
/// söyler). Telefon yanındaki düğme numarayı panoya kopyalar (uygulamada arama paketi yoktur).
///
/// Anahtarlar: `Key('card_home_service')`, `Key('home_service_line')`, `Key('btn_copy_service_phone')`.
class HomeServiceCard extends StatelessWidget {
  const HomeServiceCard({super.key});

  /// Karttaki satır: "Servisiniz: Ad · Telefon" (telefon yoksa yalnız ad).
  static String lineOf(HomeServiceInfo service) {
    final phone = service.phone;
    return 'Servisiniz: ${service.name}${phone == null ? '' : ' · $phone'}';
  }

  @override
  Widget build(BuildContext context) {
    final service = context.select<AutomationState, HomeServiceInfo?>((s) => s.activeHome?.service);
    if (service == null) return const SizedBox.shrink();
    final phone = service.phone;
    final primary = AppTheme.getTextPrimary(context);

    return SurfaceCard(
      key: const Key('card_home_service'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Etkileşimsiz bilgi kartı: servis kimliği (konsol ailesi) orb'u; parıltı yok (asıl kontroller öne çıksın).
          OrbIconBadge(icon: Icons.engineering_rounded, family: AppFeature.serviceConsole.accentFamily),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  lineOf(service),
                  key: const Key('home_service_line'),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: AppText.cardTitle, height: 1.25, color: primary),
                ),
                const SizedBox(height: 4),
                const CardCaption(
                  'Bu bilgi salt okunurdur; servis değişikliğini yalnızca yönetici yapabilir.',
                ),
              ],
            ),
          ),
          if (phone != null) ...[
            const SizedBox(width: 8),
            GlassIconButton(
              key: const Key('btn_copy_service_phone'),
              icon: Icons.copy_rounded,
              semanticLabel: 'Servis telefonunu kopyala',
              size: 36,
              onTap: () {
                Clipboard.setData(ClipboardData(text: phone));
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(
                    const SnackBar(
                      content: Text('Servis telefonu panoya kopyalandı.'),
                      duration: Duration(seconds: 2),
                    ),
                  );
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// Rol bilgilendirmesi: misafir salt-okunur görünümde, aile üyesi kısıtlı ayarlarda uyarılır.
/// Anahtar: `Key('notice_role')`.
class RoleNoticeCard extends StatelessWidget {
  const RoleNoticeCard({super.key});

  @override
  Widget build(BuildContext context) {
    final caps = context.select<AutomationState, Capabilities>((s) => s.capabilities);
    final String? text;
    if (caps.isGuest) {
      text = 'Misafir erişimi: ayarlar salt-okunurdur. Cihaz ayarlarını yalnızca ev sahibi ve '
          'aile üyeleri değiştirebilir.';
    } else if (caps.isResident) {
      text = 'Aile üyesi hesabı: panjur kalibrasyonu, davet ve servis PIN\'i gibi bazı ayarları '
          'yalnızca ev sahibi değiştirebilir.';
    } else {
      text = null;
    }
    if (text == null) return const SizedBox.shrink();

    final color = AppTheme.warningText(context);
    return SurfaceCard(
      key: const Key('notice_role'),
      accent: AppFamilies.amber.base,
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          const OrbIconBadge(icon: Icons.lock_rounded, family: AppFamilies.amber),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: TextStyle(fontSize: 12, color: color, height: 1.35))),
        ],
      ),
    );
  }
}

/// Cihaz telemetrisi (yalnızca cihaz yanıt verdiyse). Anahtar: `Key('card_telemetry')`.
class TelemetryCard extends StatelessWidget {
  const TelemetryCard({super.key});

  static String _uptime(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    return h > 0 ? '$h sa $m dk' : '$m dk';
  }

  @override
  Widget build(BuildContext context) {
    final DeviceStatus? status = context.select<AutomationState, DeviceStatus?>((s) => s.status);
    if (status == null) return const SizedBox.shrink();

    return KeyedSubtree(
      key: const Key('card_telemetry'),
      child: SettingsCard(
        icon: Icons.memory_rounded,
        title: 'Cihaz Telemetrisi',
        accent: AppFeature.telemetry.accentFamily.base,
        children: [
          InfoRow(label: 'Cihaz adı', value: status.deviceName),
          if (status.ip.isNotEmpty) InfoRow(label: 'Cihaz IP adresi', value: status.ip),
          InfoRow(
            label: 'Ev Wi-Fi ağı',
            value: status.wifiConnected
                ? '${status.wifiStaSsid}${status.wifiStaIp.isEmpty ? '' : ' (${status.wifiStaIp})'}'
                : 'Bağlı değil',
          ),
          if (status.wifiConnected) InfoRow(label: 'Sinyal gücü', value: '${status.wifiStaRssi} dBm'),
          InfoRow(label: 'Çalışma süresi', value: _uptime(status.uptimeSec)),
          InfoRow(
            label: 'Röle / Giriş',
            value: '${status.totalRelays ?? status.relays.length} Röle / ${status.totalDis ?? status.dis.length} Giriş',
          ),
          if (status.firmware != null) InfoRow(label: 'Yazılım sürümü', value: status.firmware!),
        ],
      ),
    );
  }
}

/// Uygulama kimliği + kullanıcı hesabı kartı. Rol adı Türkçe gösterilir (ham `SERVICE_USER` yok).
/// Anahtarlar: `Key('card_account')`, `Key('btn_profile')`, `Key('btn_logout')`.
class AccountCard extends StatelessWidget {
  const AccountCard({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.read<AutomationState>();
    final vm = context.select<AutomationState, ({String name, String email, GlobalRole global, HomeRole? home})>(
      (s) => (
        name: s.currentUser?.fullName ?? '',
        email: s.currentUser?.email ?? '',
        global: s.currentUser?.globalRole ?? GlobalRole.unknown,
        home: s.activeHome?.homeRole,
      ),
    );

    return KeyedSubtree(
      key: const Key('card_account'),
      child: SettingsCard(
        icon: Icons.account_circle_rounded,
        title: 'Kullanıcı Hesabı',
        accent: AppFamilies.sky.base,
        children: [
          InfoRow(label: 'Ad Soyad', value: vm.name.trim().isEmpty ? '—' : vm.name.trim()),
          InfoRow(label: 'E-posta', value: vm.email.trim().isEmpty ? '—' : vm.email.trim()),
          InfoRow(label: 'Hesap türü', value: globalRoleLabel(vm.global)),
          if (vm.home != null) InfoRow(label: 'Bu dairedeki rolünüz', value: homeRoleLabel(vm.home)),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const Key('btn_profile'),
              onPressed: () => UserProfileDialog.show(context),
              icon: Icon(Icons.manage_accounts_rounded, size: accentIconSize(context)),
              label: const Text('Profili Yönet', style: TextStyle(fontWeight: FontWeight.bold)),
              style: accentOutlinedButtonStyle(context, AppFamilies.sky),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            // Çıkış eylemi ortak dilde: çerçeveli rose hap (servis paneli "Çıkış Yap" ve profil diyaloğuyla aynı); eskiden
            // bu kartta çıplak kırmızı metin düğmesiydi (aynı anlam, dört ayrı stil).
            child: OutlinedButton.icon(
              key: const Key('btn_logout'),
              onPressed: () => confirmAndLogout(context, state),
              icon: Icon(Icons.logout_rounded, size: accentIconSize(context)),
              label: const Text('Oturumu Kapat', style: TextStyle(fontWeight: FontWeight.bold)),
              style: accentOutlinedButtonStyle(context, AppFamilies.rose),
            ),
          ),
        ],
      ),
    );
  }
}
