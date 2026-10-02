import 'package:flutter/material.dart';

import '../service_setup_controller.dart';
import '../setup_style.dart';
import '../setup_widgets.dart';
import 'step_common.dart';

/// Adım 1 - Hazırlık: oturum + sunucu doğrulaması, gerekenler listesi, geri sayım.
class Step1Preparation extends StatelessWidget {
  const Step1Preparation({super.key, required this.controller});

  final ServiceSetupController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final access = c.access;
    final prep = c.prep;
    final target = c.target;

    return stepScaffold(
      context,
      c,
      1,
      continueHint: 'Devam etmek için oturum ve sunucu bağlantısı doğrulanmalı.',
      statusText: prep.verified ? 'Doğrulandı' : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SetupCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SetupInfoRow(
                  icon: Icons.person_rounded,
                  text: 'Teknisyen: ${access.technicianName.isEmpty ? '-' : access.technicianName}',
                  bold: true,
                ),
                if (access.isPinSession) ...[
                  SetupInfoRow(
                    icon: Icons.timer_rounded,
                    text: 'Geçici servis oturumu: yalnızca '
                        '"${(access.sessionHomeName ?? '').isEmpty ? 'ev sahibinin' : access.sessionHomeName}" '
                        'dairesi için geçerlidir.',
                  ),
                  if (access.sessionExpiresAt != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 26),
                      child: CountdownText(
                        key: const Key('setup_session_countdown'),
                        tick: c.clockTick,
                        remaining: () => c.sessionRemaining ?? Duration.zero,
                        prefix: 'Kalan süre: ',
                        doneText: 'Oturum süresi doldu',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                          color: SetupColors.readable(context, SetupColors.warn),
                        ),
                      ),
                    ),
                ] else
                  SetupInfoRow(
                    icon: access.isSuperUser ? Icons.shield_rounded : Icons.verified_user_rounded,
                    text: access.isSuperUser
                        ? 'Süper yönetici hesabı (cihaz anahtarını sunucudan alamaz; gerekirse elle girilir).'
                        : 'Kalıcı servis personeli hesabı: kurulum yetkiniz müşteriye bağladığınız daire için süreli verilir.',
                  ),
                if (c.isExistingDevice && target != null)
                  SetupInfoRow(
                    icon: Icons.developer_board_rounded,
                    text: 'Mevcut cihazda devam: ${target.deviceUuid}',
                    color: SetupColors.info,
                  ),
              ],
            ),
          ),
          const SetupSectionTitle('Yanınızda olması gerekenler'),
          const SetupCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SetupInfoRow(icon: Icons.qr_code_2_rounded, text: 'Pano etiketi: karekod, seri numarası ve kurulum PIN\'i'),
                SetupInfoRow(icon: Icons.alternate_email_rounded, text: 'Müşterinin e-posta adresi veya telefonu (kod alacak)'),
                SetupInfoRow(icon: Icons.wifi_rounded, text: 'Müşterinin ev Wi-Fi adı ve şifresi'),
                SetupInfoRow(icon: Icons.battery_charging_full_rounded, text: 'Şarjlı telefon ve internet bağlantısı'),
                SetupInfoRow(icon: Icons.bolt_rounded, text: 'Elektriği verilmiş, ışıkları yanan pano'),
              ],
            ),
          ),
          const SetupSectionTitle('Sunucu bağlantısı'),
          SetupCard(
            key: const Key('setup_verify_card'),
            accent: prep.verified ? SetupColors.ok : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SetupInfoRow(
                  icon: prep.verified ? Icons.check_circle_rounded : Icons.cloud_sync_rounded,
                  color: prep.verified ? SetupColors.ok : null,
                  bold: prep.verified,
                  text: prep.verified
                      ? 'Oturumunuz geçerli ve sunucuya ulaşıldı.'
                      : 'Oturumunuzun geçerli olduğu ve sunucuya ulaşıldığı henüz doğrulanmadı.',
                ),
                if (!prep.verified || prep.problem != null) ...[
                  const SizedBox(height: 8),
                  SetupPrimaryButton(
                    key: const Key('btn_verify_session'),
                    label: 'Bağlantıyı Doğrula',
                    icon: Icons.verified_rounded,
                    busy: prep.busy,
                    onPressed: () => prep.verify(),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
