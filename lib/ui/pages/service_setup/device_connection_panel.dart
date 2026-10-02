import 'package:flutter/material.dart';

import 'service_setup_controller.dart';
import 'setup_fields.dart';
import 'setup_style.dart';
import 'setup_widgets.dart';

/// 6-9. adımların üstündeki "panoya yerel bağlantı" paneli.
///
/// Bağlıyken tek satırlık yeşil özet; bağlı değilken pano IP adresi kutusu ("Panoya Bağlan"), anahtar
/// reddedildiyse elle anahtar girişi ve hatanın "Neden? / Ne yapmalıyım?" açıklaması gösterilir.
/// Anahtarlı hiçbir istek, pano kimliği doğrulanmadan gönderilmez.
class DeviceConnectionPanel extends StatefulWidget {
  const DeviceConnectionPanel({super.key, required this.controller});

  final ServiceSetupController controller;

  @override
  State<DeviceConnectionPanel> createState() => _DeviceConnectionPanelState();
}

class _DeviceConnectionPanelState extends State<DeviceConnectionPanel> {
  final TextEditingController _ip = TextEditingController();
  final TextEditingController _key = TextEditingController();
  bool _editing = false;
  bool _ipDirty = false;

  @override
  void dispose() {
    _ip.dispose();
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final target = c.target;
    final conn = c.conn;
    if (target == null) return const SizedBox.shrink();
    if (!_ipDirty && _ip.text != target.ip) _ip.text = target.ip;

    if (conn.ready && !_editing) {
      return SetupCard(
        key: const Key('device_connection_ready'),
        accent: SetupColors.ok,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.link_rounded, color: SetupColors.readable(context, SetupColors.ok)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Pano bağlı • ${target.ip}',
                    style: TextStyle(fontWeight: FontWeight.w700, color: SetupColors.readable(context, SetupColors.ok)),
                  ),
                ),
              ],
            ),
            // Düğme ayrı satırda: dar ekranda ve büyük yazıda yan yana sığmayıp taşmasın.
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const Key('btn_change_device_ip'),
                onPressed: () => setState(() => _editing = true),
                child: const Text('Adresi değiştir'),
              ),
            ),
          ],
        ),
      );
    }

    final problem = conn.problem;
    final needsKey = problem != null && problem.title.contains('anahtar');
    return SetupCard(
      key: const Key('device_connection_panel'),
      accent: conn.busy ? SetupColors.primaryLight : SetupColors.warn,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.router_rounded, color: SetupColors.readable(context, SetupColors.warn)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Panoya bağlanın',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Telefonunuz panoyla aynı ev Wi-Fi ağında olmalı (internet gerekir: cihaz anahtarı sunucudan alınır). '
            'Pano adresi (IP) yanlışsa düzeltin.',
            style: TextStyle(fontSize: 13, height: 1.35, color: SetupColors.muted(context)),
          ),
          SetupTextField(
            key: const Key('field_device_ip'),
            controller: _ip,
            label: 'Pano IP adresi',
            hint: '192.168.1.40',
            prefixIcon: Icons.lan_rounded,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            onChanged: (_) => _ipDirty = true,
            onSubmitted: (_) => _connect(),
          ),
          const SizedBox(height: 10),
          SetupPrimaryButton(
            key: const Key('btn_connect_device'),
            label: 'Panoya Bağlan',
            icon: Icons.link_rounded,
            busy: conn.busy,
            onPressed: _connect,
          ),
          if (problem != null)
            SetupProblemBox(
              problem: problem,
              onRetry: conn.canRetry ? () => conn.retry() : null,
            ),
          if (needsKey) ...[
            const SizedBox(height: 4),
            SecretField(
              key: const Key('field_local_key'),
              controller: _key,
              label: 'Cihaz anahtarı (elle)',
              helperText: 'Sunucudan alınamadıysa fabrika/servis kaydındaki anahtarı yazın.',
              prefixIcon: Icons.key_rounded,
              monospace: true,
              onSubmitted: (_) => _useKey(),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: const Key('btn_use_key'),
              onPressed: conn.busy ? null : _useKey,
              icon: const Icon(Icons.vpn_key_rounded, size: 18),
              label: const Text('Bu Anahtarla Bağlan'),
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _connect() async {
    final ip = _ip.text.trim();
    final ok = await widget.controller.conn.connect(ip: ip.isEmpty ? null : ip);
    if (ok && mounted) {
      setState(() {
        _editing = false;
        _ipDirty = false;
      });
      // Bağlanınca adım mantığı (liste yükleme vb.) yeniden denenir.
      widget.controller.onDeviceConnected();
    }
  }

  Future<void> _useKey() async {
    final ok = await widget.controller.conn.useManualKey(_key.text.trim());
    if (ok && mounted) {
      _key.clear();
      setState(() {
        _editing = false;
        _ipDirty = false;
      });
      widget.controller.onDeviceConnected();
    }
  }
}
