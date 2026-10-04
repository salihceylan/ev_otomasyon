import 'package:flutter/material.dart';

import '../../../widgets/settings/accent_button.dart';
import '../service_setup_controller.dart';
import '../setup_fields.dart';
import '../setup_style.dart';
import '../setup_widgets.dart';
import 'step_common.dart';

/// Adım 3 - Müşteri: e-posta/telefon, "kendi adına" engeli, OTP gönder -> kodu yaz, geri sayım.
class Step3Customer extends StatefulWidget {
  const Step3Customer({super.key, required this.controller});

  final ServiceSetupController controller;

  @override
  State<Step3Customer> createState() => _Step3CustomerState();
}

class _Step3CustomerState extends State<Step3Customer> {
  final TextEditingController _customer = TextEditingController();
  final TextEditingController _otp = TextEditingController();
  String? _customerError;

  @override
  void dispose() {
    _customer.dispose();
    _otp.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final logic = widget.controller.customer;
    final error = logic.validateIdentifier(_customer.text);
    setState(() => _customerError = error);
    if (error != null) return;
    final ok = await logic.sendCode(_customer.text);
    if (ok && mounted) {
      _otp.clear(); // yeni kod istendi: önceki (başka cihaz/eski kod) için yazılmış değer kalmasın
      setState(() => _customerError = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final customer = c.customer;

    Widget body;
    if (c.access.isPinSession) {
      body = SetupCard(
        accent: SetupColors.info,
        child: SetupInfoRow(
          icon: Icons.info_outline_rounded,
          text: 'Geçici servis oturumunda bu adım gerekmez: cihaz ev sahibi tarafından zaten eşlenmiştir.',
        ),
      );
    } else if (c.claim.isComplete) {
      body = SetupCard(
        key: const Key('step3_done_card'),
        accent: SetupColors.ok,
        child: SetupResultHeader(text: 'Müşteri doğrulandı${customer.hint.isEmpty ? '' : ': ${customer.hint}'}'),
      );
    } else {
      body = _form(context, c);
    }

    return stepScaffold(
      context,
      c,
      3,
      continueHint: 'Devam etmek için müşteriye kod gönderin ve müşterinin söylediği 6 haneli kodu yazın.',
      statusText: c.isStepComplete(3) ? 'Kod girildi' : null,
      body: body,
    );
  }

  Widget _form(BuildContext context, ServiceSetupController c) {
    final customer = c.customer;
    final sent = customer.codeSent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SetupTextField(
          key: const Key('field_customer'),
          controller: _customer,
          // Kısa etiket (yüzen etiket 1.5 yazı ölçeğinde "Müşteri e-posta veya …" diye kesiliyordu); örnek metin ipucunda.
          label: 'E-posta veya telefon',
          hint: 'musteri@ornek.com veya 0555 123 45 67',
          helperText: 'Cihazın bağlanacağı müşterinin bilgisi',
          prefixIcon: Icons.person_outline_rounded,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.done,
          errorText: _customerError,
          enabled: !sent && !customer.busy,
          onChanged: (_) {
            if (_customerError != null) setState(() => _customerError = null);
          },
          onSubmitted: (_) => _send(),
        ),
        if (sent)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('btn_change_customer'),
              style: setupInlineActionStyle(),
              onPressed: customer.busy
                  ? null
                  : () {
                      _otp.clear();
                      customer.resetCustomer();
                    },
              icon: Icon(Icons.edit_rounded, size: accentIconSize(context, base: 18)),
              label: const Text('Müşteriyi değiştir'),
            ),
          ),
        const SizedBox(height: 10),
        ValueListenableBuilder<int>(
          valueListenable: c.clockTick,
          builder: (context, _, _) {
            final now = c.ctx.clock.now();
            final canResend = !sent || customer.canResend(now);
            final left = customer.resendRemaining(now);
            final label = !sent
                ? 'Kod Gönder'
                : (canResend ? 'Kodu Yeniden Gönder' : 'Yeniden gönder: ${(left.inMilliseconds / 1000).ceil()} sn sonra');
            return SetupPrimaryButton(
              key: const Key('btn_send_otp'),
              label: label,
              icon: Icons.send_rounded,
              busy: customer.busy,
              onPressed: (!customer.busy && canResend) ? _send : null,
            );
          },
        ),
        if (sent) ...[
          SetupCard(
            key: const Key('otp_sent_card'),
            accent: SetupColors.ok,
            child: SetupResultHeader(
              icon: Icons.mark_email_read_rounded,
              text: customer.sentMessage ?? 'Doğrulama kodu müşteriye gönderildi.',
            ),
          ),
          SetupTextField(
            key: const Key('field_otp'),
            controller: _otp,
            label: '6 haneli kod',
            helperText: 'Müşterinin söylediği kod',
            prefixIcon: Icons.password_rounded,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            maxLength: 6,
            inputFormatters: [digitsOnly],
            monospace: true,
            onChanged: customer.setCode,
          ),
          if (customer.codeExpiresAt != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ValueListenableBuilder<int>(
                valueListenable: c.clockTick,
                builder: (context, _, _) {
                  final now = c.ctx.clock.now();
                  final expired = customer.isCodeExpired(now);
                  final left = customer.codeExpiresAt!.difference(now);
                  return Text(
                    expired
                        ? 'Kodun süresi doldu: yeni kod isteyin.'
                        : 'Kodun geçerlilik süresi: ${CountdownText.format(left)}',
                    key: const Key('otp_expiry_text'),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: expired ? SetupColors.error : SetupColors.muted(context),
                    ),
                  );
                },
              ),
            ),
          if (customer.hasCode)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Kod, cihaz daireye bağlanırken (4. adım) sunucu tarafından doğrulanır.',
                style: TextStyle(fontSize: 12.5, color: SetupColors.muted(context)),
              ),
            ),
        ],
      ],
    );
  }
}
