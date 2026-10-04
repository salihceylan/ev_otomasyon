import 'package:flutter/material.dart';

import '../../motion/staggered_entrance.dart';
import '../../theme/tokens.dart';
import '../../widgets/orb/orb.dart';
import '../../widgets/settings/accent_button.dart';
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
  const DeviceConnectionPanel({super.key, required this.controller, this.primaryConnect = true});

  final ServiceSetupController controller;

  /// "Panoya Bağlan" gradyanlı birincil düğme mi (varsayılan), yoksa çerçeveli ikincil mi. Adımın kendi birincil eylemi
  /// aynı ekrandaysa (6. adım: "Buluta Bağla ve Bekle") `false` verilir: ekranda TEK gradyan birincil kalır.
  final bool primaryConnect;

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
      // Tek satırlık özet: "Adresi değiştir" ayrı satırdaki metin düğmesi YERİNE sağdaki kalem düğmesidir (kart ≈ 107 dp
      // yerine ≈ 70 dp; 6-9. adımlarda her seferinde boş bir 48 dp satır kalmaz).
      final summaryStyle = TextStyle(fontWeight: FontWeight.w700, color: SetupColors.readable(context, SetupColors.ok));
      return SetupCard(
        key: const Key('device_connection_ready'),
        accent: SetupColors.ok,
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            const SetupMiniOrb(family: AppFamilies.emerald, icon: Icons.link_rounded, size: 28),
            const SizedBox(width: 10),
            Expanded(
              // Büyük yazıda başlık ve adres iki ayrı satır (eskiden tek Text sarıp ayraç nokta satır sonunda yetim kalıyordu:
              // "Pano bağlı •" / "192.168.1.42"); normal yazıda tek satır özeti.
              child: SetupText.isLargeText(context)
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Pano bağlı', style: summaryStyle),
                        Text(target.ip, style: summaryStyle),
                      ],
                    )
                  : Text('Pano bağlı • ${target.ip}', style: summaryStyle),
            ),
            GlassIconButton(
              key: const Key('btn_change_device_ip'),
              icon: Icons.edit_rounded,
              semanticLabel: 'Adresi değiştir',
              onTap: () => setState(() => _editing = true),
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
              const SetupMiniOrb(family: AppFamilies.amber, icon: Icons.router_rounded, size: 28),
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
          if (widget.primaryConnect)
            SetupPrimaryButton(
              key: const Key('btn_connect_device'),
              label: 'Panoya Bağlan',
              icon: Icons.link_rounded,
              busy: conn.busy,
              onPressed: _connect,
            )
          else
            SetupSecondaryButton(
              key: const Key('btn_connect_device'),
              label: 'Panoya Bağlan',
              icon: Icons.link_rounded,
              busy: conn.busy,
              onPressed: _connect,
            ),
          if (problem != null)
            StaggeredEntrance(
              index: 0,
              offset: 8,
              child: SetupProblemBox(
                problem: problem,
                onRetry: conn.canRetry ? () => conn.retry() : null,
                // "Panoya Bağlan" hemen yukarıda (bu panelin birincil eylemi): yeniden deneme aynı işi yapar, çerçeveli kalır.
                retrySecondary: true,
              ),
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
              icon: Icon(Icons.vpn_key_rounded, size: accentIconSize(context, base: 18)),
              label: const Text('Bu Anahtarla Bağlan'),
              // Çerçeve + metin + simge AYNI aileden ve AA (tema varsayılan çerçevesi açıkta ≈ 2.4:1'di).
              style: accentOutlinedButtonStyle(context, AppFamilies.sky),
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
