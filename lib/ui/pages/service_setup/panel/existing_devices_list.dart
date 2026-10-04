import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../models/api_models.dart';
import '../../../../models/cloud_models.dart';
import '../../../../services/automation_state.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/settings/accent_button.dart';
import '../service_target.dart';
import '../setup_steps.dart';
import '../setup_style.dart';
import 'service_glass.dart';
import '../setup_widgets.dart';

/// "Mevcut cihazlarım": aktif dairedeki, **zaten kurulu** panolar. Bir panoya dokunmak sihirbazı
/// "mevcut cihaz" kipinde açar (2-4. adımlar atlanır): bağlantıyı yeniden kurmak (5. adım) ya da
/// testleri yeniden yapmak (7. adım) için.
class ExistingDevicesList extends StatelessWidget {
  const ExistingDevicesList({super.key, required this.onOpen});

  /// [device] panosu için sihirbazı [startStep]'ten açar; [homeId]/[homeName] aktif dairedir.
  final void Function(ServiceTarget target, int startStep) onOpen;

  @override
  Widget build(BuildContext context) {
    // Yalnız bu listeyi ilgilendiren alanlar izlenir: AutomationState'in her bildirimi (MQTT/yoklama) listeyi yeniden kurmaz.
    final home = context.select<AutomationState, HomeModel?>((s) => s.activeHome);
    final devices = context.select<AutomationState, List<DeviceInfo>>((s) => s.devices);
    final selectedUuid = context.select<AutomationState, String>((s) => s.selectedDeviceUuid);
    final selectedIp = context.select<AutomationState, String>((s) => s.selectedDeviceIp);
    return Column(
      key: const Key('existing_devices_list'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SetupSectionTitle('Mevcut cihazlarım'),
        if (home == null)
          const ServiceCard(
            key: Key('existing_no_home'),
            child: ServiceEmptyState(
              icon: Icons.home_work_rounded,
              title: 'Aktif daire seçili değil',
              message: 'Bir daire seçtiğinizde o dairedeki panolar burada listelenir.',
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              'Daire: ${home.name}',
              key: const Key('existing_home_name'),
              style: TextStyle(fontSize: AppText.caption, color: SetupColors.muted(context)),
            ),
          ),
          if (devices.isEmpty)
            const ServiceCard(
              key: Key('existing_empty'),
              child: ServiceEmptyState(
                icon: Icons.developer_board_off_rounded,
                title: 'Bu dairede kayıtlı pano yok',
                message: 'Yeni Kurulum Başlat ile bir pano ekleyebilirsiniz.',
              ),
            ),
          for (final device in devices)
            _DeviceCard(
              device: device,
              onOpen: (step) => onOpen(
                ServiceTarget(
                  homeId: home.id,
                  deviceUuid: device.deviceUuid,
                  homeName: home.name,
                  ip: selectedUuid == device.deviceUuid ? selectedIp : '',
                ),
                step,
              ),
            ),
        ],
      ],
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.device, required this.onOpen});

  final DeviceInfo device;
  final void Function(int startStep) onOpen;

  @override
  Widget build(BuildContext context) {
    final color = device.online ? SetupColors.ok : SetupColors.warn;
    final title = device.name.isEmpty ? device.deviceUuid : device.name;
    final pill = ServiceStatusPill(label: device.online ? 'Çevrimiçi' : 'Çevrimdışı', color: color);
    final titleText = Text(
      title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: AppText.cardTitle, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
    );
    return ServiceCard(
      key: Key('card_existing_${device.deviceUuid}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Büyük yazıda hap adı sıkıştırmasın: başlığın altına iner.
          if (SetupText.isLargeText(context)) ...[
            titleText,
            const SizedBox(height: 6),
            Wrap(children: [pill]),
          ] else
            Row(children: [Expanded(child: titleText), const SizedBox(width: 8), pill]),
          const SizedBox(height: 4),
          // Kimlik tek satır: tireden bölünüp iki satıra yayılmaz, sığmazsa küçülür.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              device.deviceUuid + (device.firmware.isEmpty ? '' : '  •  v${device.firmware}'),
              maxLines: 1,
              softWrap: false,
              style: SetupText.mono(fontSize: AppText.badge, color: SetupColors.muted(context)),
            ),
          ),
          const SizedBox(height: 12),
          ServiceActionGrid(
            children: [
              OutlinedButton.icon(
                key: Key('btn_reconnect_${device.deviceUuid}'),
                onPressed: () => onOpen(SetupSteps.wifi),
                icon: Icon(Icons.wifi_rounded, size: accentIconSize(context, base: 18)),
                label: const Text('Bağlantıyı yeniden kur', textAlign: TextAlign.center),
                style: accentOutlinedButtonStyle(context, AppFamilies.sky),
              ),
              OutlinedButton.icon(
                key: Key('btn_retest_${device.deviceUuid}'),
                onPressed: () => onOpen(SetupSteps.relays),
                icon: Icon(Icons.fact_check_outlined, size: accentIconSize(context, base: 18)),
                label: const Text('Testleri yap', textAlign: TextAlign.center),
                style: accentOutlinedButtonStyle(context, AppFamilies.sky),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
