import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../services/automation_state.dart';
import '../../../utils/friendly_error.dart';
import '../../common/cooldown.dart';
import '../../common/date_format.dart';
import '../../common/inline_message.dart';
import '../../common/validators.dart';
import '../../theme/app_theme.dart';

/// Yetkili servis girişi: ev sahibinin ürettiği 6 haneli, 2 saat geçerli tek eve kapsamlı PIN.
///
/// PIN yalnızca rakamdır (6 hane). Yanlış denemede sunucunun bekleme süresi (`retry_after`, 423/429)
/// geri sayılır ve düğme o sürece pasif kalır. Ham istisna metni gösterilmez.
class ServicePinDialog extends StatefulWidget {
  const ServicePinDialog({super.key});

  static Future<void> show(BuildContext context) {
    final state = context.read<AutomationState>();
    return showDialog<void>(
      context: context,
      builder: (ctx) => ChangeNotifierProvider<AutomationState>.value(
        value: state,
        child: const ServicePinDialog(),
      ),
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
      child: AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppTheme.cardBorder),
        ),
        title: const Row(
          children: [
            Icon(Icons.build_circle_outlined, color: AppTheme.accentAmber, size: 28),
            SizedBox(width: 10),
            Flexible(
              child: Text(
                'Yetkili Servis Girişi',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Ev sahibinin oluşturduğu 6 haneli geçici servis PIN kodunu giriniz. PIN 2 saat geçerlidir ve '
                'yalnızca o eve erişim sağlar.',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 13, height: 1.4),
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
                style: const TextStyle(
                  fontSize: 24,
                  letterSpacing: 8,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textPrimary,
                ),
                decoration: InputDecoration(
                  counterText: '',
                  hintText: '••••••',
                  hintStyle: const TextStyle(color: AppTheme.textMuted, letterSpacing: 8),
                  filled: true,
                  fillColor: AppTheme.cardDark,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: AppTheme.cardBorder),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: AppTheme.cardBorder),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: AppTheme.accentAmber, width: 1.8),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              TextField(
                key: const Key('field_service_technician'),
                controller: _nameController,
                enabled: !_submitting,
                maxLength: 100,
                textCapitalization: TextCapitalization.words,
                style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14),
                decoration: InputDecoration(
                  counterText: '',
                  labelText: 'Adınız Soyadınız (isteğe bağlı)',
                  helperText: 'Ev sahibi oturumu kimin açtığını görebilir.',
                  labelStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
                  filled: true,
                  fillColor: AppTheme.cardDark,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: AppTheme.cardBorder),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: AppTheme.cardBorder),
                  ),
                ),
              ),
              if (_lock.isActive) ...[
                const SizedBox(height: 8),
                InlineMessage.warning(
                  'Çok fazla hatalı deneme. ${formatCountdown(_lock.remainingSeconds)} sonra tekrar deneyebilirsiniz.',
                  key: const Key('service_pin_lock'),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                InlineMessage.error(_error!, key: const Key('service_pin_error')),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const Key('btn_service_cancel'),
            onPressed: _submitting ? null : () => Navigator.of(context).pop(),
            child: const Text('İptal', style: TextStyle(color: AppTheme.textMuted)),
          ),
          ElevatedButton(
            key: const Key('btn_service_login'),
            onPressed: (_submitting || _lock.isActive) ? null : _submit,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accentAmber,
              foregroundColor: Colors.black87,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: _submitting
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black87))
                : const Text('Doğrula', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}
