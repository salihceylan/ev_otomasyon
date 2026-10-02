import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../device_connection_panel.dart';
import '../logic/cloud_logic.dart';
import '../service_setup_controller.dart';
import '../setup_style.dart';
import '../setup_widgets.dart';
import 'step_common.dart';

/// Adım 6 - Bulut Bağlantısı: bulut kimliği panoya yazılır; sunucuda çevrimiçi + yeni durum beklenir.
class Step6Cloud extends StatelessWidget {
  const Step6Cloud({super.key, required this.controller});

  final ServiceSetupController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final cloud = c.cloud;
    final lan = cloud.lanStatus;
    final showDiag = lan != null && !cloud.online && cloud.problem != null;

    return stepScaffold(
      context,
      c,
      6,
      continueHint: 'Devam etmek için panonun sunucuda çevrimiçi olması gerekir.',
      statusText: cloud.online ? 'Çevrimiçi' : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!cloud.online) ...[
            _homeWifiCard(context, c),
            DeviceConnectionPanel(controller: c),
            SetupCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SetupInfoRow(
                    icon: Icons.cloud_upload_rounded,
                    text: 'Pano bulut sunucusuna bağlanınca sunucuda "çevrimiçi" görünür. Bu adım bunu doğrular.',
                  ),
                  const SizedBox(height: 10),
                  SetupPrimaryButton(
                    key: const Key('btn_cloud_connect'),
                    label: cloud.credentialWritten ? 'Tekrar Bekle' : 'Buluta Bağla ve Bekle',
                    icon: Icons.cloud_sync_rounded,
                    busy: cloud.busy,
                    onPressed: cloud.busy ? null : () => cloud.connectAndWait(),
                  ),
                  if (cloud.credentialWritten && !cloud.busy)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: OutlinedButton.icon(
                        key: const Key('btn_rewrite_credential'),
                        onPressed: () => cloud.rewriteCredential(),
                        icon: const Icon(Icons.vpn_key_rounded, size: 18),
                        label: const Text('Kimliği Yeniden Yaz'),
                        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                      ),
                    ),
                ],
              ),
            ),
            if (cloud.waiting) _waitingCard(context, c, cloud),
            if (showDiag) _diagCard(context, cloud),
          ] else
            _onlineCard(context, cloud),
        ],
      ),
    );
  }

  /// Telefon bu adımda ev Wi-Fi ağında (internetli) olmalıdır: 5. adımda kurulum ağındaydı ve internet yoktu.
  Widget _homeWifiCard(BuildContext context, ServiceSetupController c) {
    return SetupCard(
      key: const Key('cloud_home_wifi_card'),
      accent: SetupColors.warn,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Önce telefonu ev Wi-Fi ağına geri alın',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
          ),
          const SizedBox(height: 4),
          SetupInfoRow(
            icon: Icons.phone_android_rounded,
            text: 'Telefonunuz hâlâ panonun kurulum ağındaysa (AHBU-...), o ağdan çıkıp müşterinin ev Wi-Fi ağına '
                'bağlanın. Bu adım internet ister: cihaz anahtarı ve bulut kimliği sunucudan alınır.',
          ),
          SetupInfoRow(
            icon: Icons.lan_rounded,
            text: c.target?.ip.isNotEmpty == true && !c.wifi.usingSetupNetwork
                ? 'Panonun ev ağındaki adresi: ${c.target!.ip}'
                : 'Panonun ev ağındaki adresi (IP) bilinmiyor: modem arayüzündeki cihaz listesinden bakıp aşağıya yazın.',
          ),
        ],
      ),
    );
  }

  Widget _waitingCard(BuildContext context, ServiceSetupController c, CloudLogic cloud) {
    return SetupCard(
      key: const Key('cloud_waiting_card'),
      accent: SetupColors.primaryLight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Pano sunucuya bağlanıyor, bekleniyor...',
                  style: TextStyle(fontWeight: FontWeight.w800, color: SetupColors.text(context)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          CountdownText(
            key: const Key('cloud_waiting_countdown'),
            tick: c.clockTick,
            remaining: () {
              final started = cloud.waitStartedAt;
              if (started == null) return Duration.zero;
              return CloudLogic.waitLimit - c.ctx.clock.now().difference(started);
            },
            prefix: 'Kalan bekleme süresi: ',
            style: TextStyle(fontSize: 13, color: SetupColors.muted(context)),
          ),
        ],
      ),
    );
  }

  Widget _diagCard(BuildContext context, CloudLogic cloud) {
    final lan = cloud.lanStatus!;
    Widget chip(String label, bool? ok) {
      final color = ok == null ? SetupColors.warn : (ok ? SetupColors.ok : SetupColors.error);
      return Chip(
        avatar: Icon(
          ok == null ? Icons.help_outline_rounded : (ok ? Icons.check_rounded : Icons.close_rounded),
          size: 16,
          color: SetupColors.readable(context, color),
        ),
        label: Text(label, style: TextStyle(fontSize: 12.5, color: SetupColors.readable(context, color))),
        backgroundColor: color.withValues(alpha: 0.12),
        side: BorderSide(color: color.withValues(alpha: 0.4)),
        visualDensity: VisualDensity.compact,
      );
    }

    return SetupCard(
      key: const Key('cloud_diag_card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Panonun kendi bildirdiği durum',
            style: TextStyle(fontWeight: FontWeight.w800, color: SetupColors.text(context)),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              chip('Ev Wi-Fi ağı', lan.wifiConnected),
              chip('Saat (internetten)', lan.timeSynced),
              chip('Bulut kimliği kayıtlı', lan.mqttConfigured),
              chip('Bulut bağlantısı', lan.mqttConnected),
            ],
          ),
        ],
      ),
    );
  }

  Widget _onlineCard(BuildContext context, CloudLogic cloud) {
    final seen = cloud.lastSeenAt;
    return SetupCard(
      key: const Key('cloud_online_card'),
      accent: SetupColors.ok,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SetupInfoRow(
            icon: Icons.cloud_done_rounded,
            color: SetupColors.ok,
            bold: true,
            text: cloud.alreadyOnline
                ? 'Pano sunucuda zaten çevrimiçi: çalışan panonun bulut kimliği DEĞİŞTİRİLMEDİ.'
                : 'Pano sunucuda çevrimiçi: bulut bağlantısı doğrulandı.',
          ),
          if (seen != null)
            SetupInfoRow(
              icon: Icons.schedule_rounded,
              text: 'Son görülme: ${DateFormat('dd.MM.yyyy HH:mm:ss').format(seen.toLocal())}',
            ),
        ],
      ),
    );
  }
}
