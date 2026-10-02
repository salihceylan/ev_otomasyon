import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/automation_models.dart';
import '../../../models/capabilities.dart';
import '../../../services/automation_state.dart';
import '../../common/confirm_dialogs.dart';
import '../../dashboard/labels.dart';
import '../../theme/app_theme.dart';
import '../user_profile_dialog.dart';
import 'settings_card.dart';

/// Donanım & motor koruma bilgilendirmesi. Anahtar: `Key('card_hardware_notice')`.
class HardwareNoticeCard extends StatelessWidget {
  const HardwareNoticeCard({super.key});

  @override
  Widget build(BuildContext context) {
    final blue = AppTheme.primaryBlue;
    return Container(
      key: const Key('card_hardware_notice'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: blue.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: blue.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.security_outlined, color: AppTheme.infoText(context), size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Donanım & Motor Koruması',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13.5,
                    color: AppTheme.infoText(context),
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
    return Container(
      key: const Key('notice_role'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.accentAmber.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.accentAmber.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_outline, color: color, size: 20),
          const SizedBox(width: 10),
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
        accent: AppTheme.accentCyan,
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
        icon: Icons.account_circle_outlined,
        title: 'Kullanıcı Hesabı',
        accent: AppTheme.primaryBlue,
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
              icon: const Icon(Icons.manage_accounts_outlined, size: 18),
              label: const Text('Profili Yönet'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: TextButton.icon(
              key: const Key('btn_logout'),
              onPressed: () => confirmAndLogout(context, state),
              icon: const Icon(Icons.logout, size: 18),
              label: const Text('Oturumu Kapat'),
              style: TextButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                foregroundColor: AppTheme.dangerText(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
