import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../common/app_dialogs.dart';
import '../../../theme/app_theme.dart';
import '../logic/claim_logic.dart';
import '../service_setup_controller.dart';
import '../setup_fields.dart';
import '../setup_style.dart';
import '../setup_widgets.dart';
import 'step_common.dart';

/// Adım 4 - Daireye Bağla (claim): özet + onay; başarıda ev kimliği alınır ve sonraki adımlar bu eve işlem yapar.
class Step4Claim extends StatefulWidget {
  const Step4Claim({super.key, required this.controller});

  final ServiceSetupController controller;

  @override
  State<Step4Claim> createState() => _Step4ClaimState();
}

class _Step4ClaimState extends State<Step4Claim> {
  /// Kurulum yetkisi bitiş tarihi biçimi (her kurulumda yeniden oluşturulmaz).
  static final DateFormat _accessFormat = DateFormat('dd.MM.yyyy HH:mm');

  final TextEditingController _homeName = TextEditingController();

  @override
  void initState() {
    super.initState();
    _homeName.text = widget.controller.claim.homeNameInput;
  }

  @override
  void dispose() {
    _homeName.dispose();
    super.dispose();
  }

  Future<void> _claim() async {
    final c = widget.controller;
    final confirmed = await showAppDialog<bool>(
      context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // küçük ekranda / büyük yazıda içerik kaydırılır (taşma olmaz)
        title: const Text('Cihaz daireye bağlansın mı?'),
        content: Text(
          '${c.identify.uid} cihazı, ${c.customer.hint} müşterisinin dairesine bağlanacak. '
          'Bu işlem geri alınamaz.',
        ),
        actions: [
          TextButton(
            key: const Key('btn_claim_cancel'),
            style: AppTheme.quietTextButtonStyle(ctx),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Vazgeç'),
          ),
          ElevatedButton(
            key: const Key('btn_claim_confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Evet, Bağla'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await c.claim.claim(homeName: _homeName.text);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final claim = c.claim;

    Widget body;
    if (c.access.isPinSession) {
      body = SetupCard(
        accent: SetupColors.info,
        child: SetupInfoRow(
          icon: Icons.info_outline_rounded,
          text: 'Geçici servis oturumunda bu adım gerekmez: cihaz ev sahibinin dairesine zaten bağlıdır.',
        ),
      );
    } else if (claim.summary != null) {
      body = _result(context, claim.summary!);
    } else {
      body = _form(context, c);
    }

    return stepScaffold(
      context,
      c,
      4,
      continueHint: 'Devam etmek için cihazı müşterinin dairesine bağlayın.',
      statusText: claim.isComplete ? 'Daireye bağlandı' : null,
      body: body,
    );
  }

  Widget _form(BuildContext context, ServiceSetupController c) {
    final ready = c.identify.hasPin && c.customer.isComplete;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SetupSectionTitle('Özet'),
        SetupCard(
          key: const Key('claim_summary_card'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SetupInfoRow(icon: Icons.developer_board_rounded, text: 'Cihaz: ${c.identify.uid ?? '-'}', bold: true),
              SetupInfoRow(
                icon: Icons.person_rounded,
                text: 'Müşteri: ${c.customer.hint.isEmpty ? '-' : c.customer.hint}',
              ),
              SetupInfoRow(
                icon: ready ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
                color: ready ? SetupColors.ok : SetupColors.warn,
                text: ready
                    ? 'Kurulum PIN\'i ve müşteri kodu hazır.'
                    : 'Kurulum PIN\'i veya müşteri kodu eksik: önceki adımlara dönün.',
              ),
            ],
          ),
        ),
        SetupTextField(
          key: const Key('field_home_name'),
          controller: _homeName,
          label: 'Daire adı (isteğe bağlı)',
          hint: 'Daire 5',
          prefixIcon: Icons.home_rounded,
          maxLength: 100,
          textInputAction: TextInputAction.done,
          onChanged: c.claim.setHomeName,
        ),
        const SizedBox(height: 12),
        SetupPrimaryButton(
          key: const Key('btn_claim'),
          label: 'Daireye Bağla',
          icon: Icons.link_rounded,
          busy: c.claim.busy,
          onPressed: ready ? _claim : null,
        ),
      ],
    );
  }

  Widget _result(BuildContext context, ClaimSummary s) {
    final fmt = _accessFormat;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SetupCard(
          key: const Key('claim_result_card'),
          accent: SetupColors.ok,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SetupResultHeader(text: 'Cihaz müşterinin dairesine bağlandı.'),
              SetupInfoRow(icon: Icons.home_rounded, text: 'Daire: ${s.homeName.isEmpty ? '-' : s.homeName}'),
              SetupInfoRow(icon: Icons.developer_board_rounded, text: 'Cihaz: ${s.deviceUuid}'),
              if (s.customerAccountCreated)
                SetupInfoRow(
                  icon: Icons.person_add_alt_1_rounded,
                  text: s.inviteSent == true
                      ? 'Müşteri için yeni hesap açıldı; etkinleştirme e-postası gönderildi.'
                      : 'Müşteri için yeni hesap açıldı ancak davet e-postası gönderilemedi.',
                ),
              if (s.technicianAccessExpiresAt != null)
                SetupInfoRow(
                  icon: Icons.schedule_rounded,
                  text: 'Bu daire için kurulum yetkiniz ${fmt.format(s.technicianAccessExpiresAt!.toLocal())} '
                      'tarihine kadar geçerlidir.',
                ),
            ],
          ),
        ),
        if (s.hasWarnings)
          SetupCard(
            key: const Key('claim_warnings_card'),
            accent: SetupColors.warn,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Dikkat: kısmi başarı uyarıları',
                  style: TextStyle(fontWeight: FontWeight.w800, color: SetupColors.readable(context, SetupColors.warn)),
                ),
                const SizedBox(height: 6),
                for (final w in s.warnings) SetupInfoRow(icon: Icons.warning_amber_rounded, text: w, color: SetupColors.warn),
              ],
            ),
          ),
        if (!s.credentialReceived)
          SetupCard(
            accent: SetupColors.info,
            child: SetupInfoRow(
              icon: Icons.info_outline_rounded,
              text: 'Bulut kimliği bu yanıtta gelmedi; 6. adımda sunucudan yeniden üretilecek.',
            ),
          ),
        SetupCard(
          key: const Key('claim_next_info'),
          accent: SetupColors.info,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SetupInfoRow(
                icon: Icons.wifi_tethering_rounded,
                text: 'Sonraki adımda telefon panonun kurulum ağına geçer ve internet olmaz: 5. adım internetsiz ve '
                    'cihaz anahtarı olmadan yapılır. Cihaz anahtarı ve bulut kimliği 6. adımda (telefon ev '
                    'Wi-Fi\'sine dönünce) kullanılır.',
              ),
              SetupInfoRow(
                key: const Key('claim_key_state'),
                icon: s.localKeyReady ? Icons.key_rounded : Icons.key_off_rounded,
                color: s.localKeyReady ? SetupColors.ok : SetupColors.warn,
                text: s.localKeyReady
                    ? 'Cihaz anahtarı şimdiden (yalnızca bellekte) hazırlandı: hazırlanmamış bir pano çıkarsa kurulum '
                        'ağında kullanılabilir.'
                    : 'Cihaz anahtarı şimdi alınamadı; sorun değil: 6. adımda, internet geri gelince alınacak.',
              ),
            ],
          ),
        ),
      ],
    );
  }
}
