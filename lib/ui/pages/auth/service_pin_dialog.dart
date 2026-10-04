import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../services/automation_state.dart';
import '../../../utils/friendly_error.dart';
import '../../common/app_dialogs.dart';
import '../../common/auth_form.dart';
import '../../common/confirm_dialogs.dart' show AuthDialogActions, AuthDialogShell, authPrimaryLabel, authSecondaryLabel;
import '../../common/cooldown.dart';
import '../../common/date_format.dart';
import '../../common/inline_message.dart';
import '../../common/validators.dart';
import '../../theme/app_theme.dart';
import '../../theme/feature_accent.dart';

/// Yetkili servis girişi: ev sahibinin ürettiği 6 haneli, 2 saat geçerli tek eve kapsamlı PIN.
///
/// PIN yalnızca rakamdır (6 hane). Yanlış denemede sunucunun bekleme süresi (`retry_after`, 423/429)
/// geri sayılır ve düğme o sürece pasif kalır. Ham istisna metni gösterilmez.
///
/// Görünüm: auth/onay akışının ORTAK diyalog kabuğu ([AuthDialogShell]).
class ServicePinDialog extends StatefulWidget {
  const ServicePinDialog({super.key});

  static Future<void> show(BuildContext context) {
    final state = context.read<AutomationState>();
    return showAppDialog<void>(
      context,
      builder: (ctx) => ChangeNotifierProvider<AutomationState>.value(value: state, child: const ServicePinDialog()),
    );
  }

  @override
  State<ServicePinDialog> createState() => _ServicePinDialogState();
}

class _ServicePinDialogState extends State<ServicePinDialog> {
  final _pinController = TextEditingController();
  final _nameController = TextEditingController();
  late final Cooldown _lock;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _lock = Cooldown(context.read<AutomationState>().clock, () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _lock.dispose();
    _pinController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting || _lock.isActive) return;
    final pin = _pinController.text.trim();
    final pinError = AuthValidators.sixDigitCodeError(pin, emptyMessage: 'Lütfen 6 haneli geçerli PIN giriniz');
    if (pinError != null) {
      setState(() => _error = 'Lütfen 6 haneli geçerli PIN giriniz');
      return;
    }
    final state = context.read<AutomationState>();
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final name = _nameController.text.trim();
      await state.loginWithServicePin(pin, technicianName: name.isEmpty ? null : name);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = friendlyError(e, fallback: 'Servis girişi başarısız. PIN\'i kontrol edip tekrar deneyin.');
      });
      if (e is ApiException && (e.isPinLocked || e.isRateLimited)) {
        final wait = e.retryAfter ?? e.resendAfter;
        if (wait != null) _lock.start(wait);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_submitting,
      child: AuthDialogShell(
        icon: Icons.handyman_rounded,
        family: AppFeature.servicePin.accentFamily,
        title: 'Yetkili Servis Girişi',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Ev sahibinin oluşturduğu 6 haneli geçici servis PIN kodunu giriniz. PIN 2 saat geçerlidir ve '
              'yalnızca o eve erişim sağlar.',
              style: TextStyle(color: AppTheme.getTextMuted(context), fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('field_service_pin'),
              controller: _pinController,
              enabled: !_submitting,
              keyboardType: TextInputType.number,
              maxLength: 6,
              textAlign: TextAlign.center,
              autocorrect: false,
              enableSuggestions: false,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
              onSubmitted: (_) => _submit(),
              style: authCodeTextStyle(context),
              // Kod alanları ailesiyle AYNI görünüm (ortalı etiket + büyük rakamlar).
              decoration: authCodeInputDecoration(context, label: 'Servis PIN Kodu', hint: '••••••', prefixIcon: Icons.pin_outlined),
            ),
            const SizedBox(height: 14),
            TextField(
              key: const Key('field_service_technician'),
              controller: _nameController,
              enabled: !_submitting,
              maxLength: 100,
              textCapitalization: TextCapitalization.words,
              style: TextStyle(color: AppTheme.getTextPrimary(context), fontSize: 14),
              // Kısa etiket; "isteğe bağlı" bilgisi yardımcı metinde (etiket büyük yazıda kesilmesin).
              decoration: authInputDecoration(
                context,
                label: 'Adınız Soyadınız',
                prefixIcon: Icons.person_outline_rounded,
                helper: 'İsteğe bağlı. Ev sahibi oturumu kimin açtığını görebilir.',
                counterText: '',
              ),
            ),
            if (_lock.isActive) ...[
              const SizedBox(height: 8),
              InlineMessage.warning(
                'Çok fazla hatalı deneme. ${formatCountdown(_lock.remainingSeconds)} sonra tekrar deneyebilirsiniz.',
                key: const Key('service_pin_lock'),
              ),
            ],
            if (_error != null) ...[const SizedBox(height: 8), InlineMessage.error(_error!, key: const Key('service_pin_error'))],
          ],
        ),
        actions: AuthDialogActions(
          secondaryLabel: 'İptal',
          secondary: TextButton(
            key: const Key('btn_service_cancel'),
            onPressed: _submitting ? null : () => Navigator.of(context).pop(),
            child: authSecondaryLabel(context, 'İptal'),
          ),
          primaryLabel: 'Doğrula',
          primary: ElevatedButton(
            key: const Key('btn_service_login'),
            onPressed: (_submitting || _lock.isActive) ? null : _submit,
            child: _submitting ? buttonSpinner() : authPrimaryLabel('Doğrula'),
          ),
        ),
      ),
    );
  }
}
