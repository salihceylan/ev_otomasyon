import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../models/api_models.dart';
import '../../../../services/automation_state.dart';
import '../service_target.dart';
import '../setup_steps.dart';
import '../setup_style.dart';
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
    final state = context.watch<AutomationState>();
    final home = state.activeHome;
    final devices = state.devices;
    return Column(
      key: const Key('existing_devices_list'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SetupSectionTitle('Mevcut cihazlarım'),
        if (home == null)
          SetupCard(
            key: const Key('existing_no_home'),
            child: Text(
              'Aktif daire seçili değil. Bir daire seçtiğinizde o dairedeki panolar burada listelenir.',
              style: TextStyle(color: SetupColors.muted(context), height: 1.35),
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              'Daire: ${home.name}',
              key: const Key('existing_home_name'),
              style: TextStyle(fontSize: 13, color: SetupColors.muted(context)),
            ),
          ),
          if (devices.isEmpty)
            SetupCard(
              key: const Key('existing_empty'),
              child: Text(
                'Bu dairede kayıtlı pano yok.',
                style: TextStyle(color: SetupColors.muted(context)),
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
                  ip: state.selectedDeviceUuid == device.deviceUuid ? state.selectedDeviceIp : '',
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
    return SetupCard(
      key: Key('card_existing_${device.deviceUuid}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: color.withValues(alpha: 0.5)),
                ),
                child: Text(
                  device.online ? 'Çevrimiçi' : 'Çevrimdışı',
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: SetupColors.readable(context, color)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            device.deviceUuid + (device.firmware.isEmpty ? '' : '  •  v${device.firmware}'),
            style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: SetupColors.muted(context)),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: Key('btn_reconnect_${device.deviceUuid}'),
                onPressed: () => onOpen(SetupSteps.wifi),
                icon: const Icon(Icons.wifi_find_rounded, size: 18),
                label: const Text('Bağlantıyı yeniden kur'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              ),
              OutlinedButton.icon(
                key: Key('btn_retest_${device.deviceUuid}'),
                onPressed: () => onOpen(SetupSteps.relays),
                icon: const Icon(Icons.fact_check_outlined, size: 18),
                label: const Text('Testleri yap'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
