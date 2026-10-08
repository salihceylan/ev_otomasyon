import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../common/confirm_dialogs.dart' show showSimpleConfirm;
import '../../../theme/tokens.dart';
import '../../../widgets/settings/accent_button.dart';
import '../device_connection_panel.dart';
import '../logic/cloud_logic.dart';
import '../panel/service_glass.dart';
import '../service_setup_controller.dart';
import '../setup_style.dart';
import '../setup_widgets.dart';
import 'step_common.dart';

/// Adım 6 - Bulut Bağlantısı: bulut kimliği panoya yazılır; sunucuda çevrimiçi + yeni durum beklenir.
class Step6Cloud extends StatelessWidget {
  const Step6Cloud({super.key, required this.controller});

  final ServiceSetupController controller;

  /// "Son görülme" saati biçimi (her kurulumda yeniden oluşturulmaz).
  static final DateFormat _seenFormat = DateFormat('dd.MM.yyyy HH:mm:ss');

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
      // Bekleme kartı (halka + geri sayım) varken sabit alandaki "kuruluyor" hapı aynı bilgiyi ikinci kez yazmasın.
      showBusy: !cloud.waiting,
      // Bu adımın birincil eylemi "Buluta Bağla ve Bekle"dir ("Tekrar dene" aynı işi yapar): hata kutusundaki yeniden deneme
      // çerçeveli ikincil olur, ekranda tek gradyan birincil kalır.
      retrySecondary: true,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!cloud.online) ...[
            // Bekleme sürerken "telefonu ev ağına alın" uyarısı bayattır (pano zaten bağlı, yanıt bekleniyor): gizlenir.
            if (!cloud.waiting) _homeWifiCard(context, c),
            // "Panoya Bağlan" burada İKİNCİL (çerçeveli): adım pano bağlantısını kendisi kurar ("Buluta Bağla ve Bekle"); elle
            // adres/anahtar yolu yardımcıdır. Eskiden iki gradyan birincil yan yana duruyordu ve hangisinin basılacağı belli değildi.
            DeviceConnectionPanel(controller: c, primaryConnect: false),
            if (cloud.keyMismatch) _keyMismatchCard(context, cloud),
            SetupCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SetupInfoRow(
                    icon: Icons.cloud_upload_rounded,
                    text: 'Pano bulut sunucusuna bağlanınca sunucuda "çevrimiçi" görünür. Bu adım bunu doğrular.',
                  ),
                  // Elle girilen anahtar sunucu kaydıyla doğrulanamadı (servis_kurulum-5).
                  if (c.ctx.manualKeyUnverified)
                    const SetupInfoRow(
                      key: Key('cloud_manual_key_unverified'),
                      icon: Icons.warning_amber_rounded,
                      color: SetupColors.warn,
                      text: 'Elle girilen cihaz anahtarı sunucudaki kayıtla doğrulanamadı; yanlışsa pano buluta bağlanamaz.',
                    ),
                  const SizedBox(height: 10),
                  SetupPrimaryButton(
                    key: const Key('btn_cloud_connect'),
                    label: cloud.credentialWritten ? 'Tekrar Bekle' : 'Buluta Bağla ve Bekle',
                    icon: Icons.cloud_sync_rounded,
                    // Bekleme kartı kendi göstergesini taşır: düğmede ikinci bir dönen yay çizilmez.
                    busy: cloud.busy && !cloud.waiting,
                    onPressed: cloud.busy ? null : () => cloud.connectAndWait(),
                  ),
                  if (cloud.credentialWritten && !cloud.busy)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: OutlinedButton.icon(
                        key: const Key('btn_rewrite_credential'),
                        onPressed: () => cloud.rewriteCredential(),
                        icon: Icon(Icons.vpn_key_rounded, size: accentIconSize(context, base: 18)),
                        label: const Text('Kimliği Yeniden Yaz'),
                        style: accentOutlinedButtonStyle(context, AppFamilies.sky),
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

  /// Panodaki anahtar izi sunucudakinden farklı (servis_kurulum-1): onaylı eşitleme, sonra bulut adımı sürer.
  Widget _keyMismatchCard(BuildContext context, CloudLogic cloud) {
    return SetupCard(
      key: const Key('cloud_key_mismatch_card'),
      accent: SetupColors.warn,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SetupInfoRow(
            icon: Icons.key_rounded,
            color: SetupColors.warn,
            bold: true,
            text: 'Panodaki cihaz anahtarı sunucudaki kayıttan farklı. Eşitlenirse panonun anahtarı sunucudakiyle '
                'değiştirilir.',
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const Key('btn_sync_board_key'),
            onPressed: cloud.busy
                ? null
                : () async {
                    final ok = await showSimpleConfirm(
                      context,
                      title: 'Panonun anahtarı eşitlensin mi?',
                      message: 'Panonun yerel anahtarı sunucudaki anahtarla değiştirilecek. Panoyu eski anahtarla yerel '
                          'ağdan kullanan cihazlar anahtarı sunucudan yeniden alır.',
                      confirmLabel: 'Eşitle',
                      icon: Icons.key_rounded,
                      confirmKey: const Key('btn_sync_key_confirm'),
                    );
                    if (!ok) return;
                    if (await cloud.syncBoardKey()) unawaited(cloud.connectAndWait());
                  },
            icon: Icon(Icons.sync_lock_rounded, size: accentIconSize(context, base: 18)),
            label: const Text('Panonun Anahtarını Eşitle'),
            style: accentOutlinedButtonStyle(context, AppFamilies.amber),
          ),
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

  /// Tek bekleme kartı: **belirli** halka (kalan süre / 90 sn boşalır) + ortada tabular `mm:ss` + açıklama. (Eskiden yalnız
  /// dönen belirsiz yay + "Kalan bekleme süresi" ayrı satırdı; sürenin ne kadar ilerlediği görünmüyordu.)
  Widget _waitingCard(BuildContext context, ServiceSetupController c, CloudLogic cloud) {
    final family = AppFamilies.sky;
    final ink = SetupColors.readable(context, family.base);
    Duration remaining() {
      final started = cloud.waitStartedAt;
      if (started == null) return Duration.zero;
      return CloudLogic.waitLimit - c.ctx.clock.now().difference(started);
    }

    return SetupCard(
      key: const Key('cloud_waiting_card'),
      accent: SetupColors.primaryLight,
      child: Row(
        children: [
          ValueListenableBuilder<int>(
            valueListenable: c.clockTick,
            builder: (context, _, _) {
              final left = remaining();
              final fraction = (left.inMilliseconds / CloudLogic.waitLimit.inMilliseconds).clamp(0.0, 1.0);
              return ServiceProgressRing(
                value: fraction,
                color: ink,
                size: 64,
                strokeWidth: 5,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: CountdownText(
                      key: const Key('cloud_waiting_countdown'),
                      tick: c.clockTick,
                      remaining: remaining,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: SetupColors.text(context),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Pano sunucuya bağlanıyor, bekleniyor...',
                  style: TextStyle(fontWeight: FontWeight.w800, color: SetupColors.text(context)),
                ),
                const SizedBox(height: 4),
                Text(
                  'Kalan bekleme süresi (en çok ${CloudLogic.waitLimit.inSeconds} sn).',
                  style: TextStyle(fontSize: 12.5, color: SetupColors.muted(context)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _diagCard(BuildContext context, CloudLogic cloud) {
    final lan = cloud.lanStatus!;
    Widget chip(String label, bool? ok) {
      final color = ok == null ? SetupColors.warn : (ok ? SetupColors.ok : SetupColors.error);
      return DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 5, 12, 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SetupMiniOrb(
                family: SetupColors.family(color),
                icon: ok == null ? Icons.question_mark_rounded : (ok ? Icons.check_rounded : Icons.close_rounded),
                size: 20,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: SetupColors.readable(context, color)),
                ),
              ),
            ],
          ),
        ),
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
          SetupResultHeader(
            icon: Icons.cloud_done_rounded,
            text: cloud.alreadyOnline
                ? 'Pano sunucuda zaten çevrimiçi: çalışan panonun bulut kimliği DEĞİŞTİRİLMEDİ.'
                : 'Pano sunucuda çevrimiçi: bulut bağlantısı doğrulandı.',
          ),
          if (seen != null)
            SetupInfoRow(
              icon: Icons.schedule_rounded,
              text: 'Son görülme: ${_seenFormat.format(seen.toLocal())}',
            ),
        ],
      ),
    );
  }
}
