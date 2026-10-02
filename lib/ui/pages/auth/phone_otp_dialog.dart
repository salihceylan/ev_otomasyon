import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../models/api_models.dart';
import '../../../services/automation_state.dart';
import '../../../utils/friendly_error.dart';
import '../../common/cooldown.dart';
import '../../common/date_format.dart';
import '../../common/inline_message.dart';
import '../../common/validators.dart';
import '../../theme/app_theme.dart';

/// Telefon numarasıyla şifresiz giriş (SMS kodu).
///
/// * Telefon doğrulanır ve ayırıcılardan arındırılarak (`+905551234567` / `05551234567`) gönderilir.
/// * "Yeniden gönder", sunucunun `resend_after` süresi dolana kadar kapalıdır (429'da
///   `resend_after` / `retry_after` ile de); kodun geçerlilik süresi geri sayılır.
/// * Hatalı kodda kalan deneme hakkı (`remaining_attempts`) gösterilir; deneme bitince bekleme.
class PhoneOtpDialog extends StatefulWidget {
  const PhoneOtpDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PhoneOtpDialog(),
    );
  }

  @override
  State<PhoneOtpDialog> createState() => _PhoneOtpDialogState();
}

class _PhoneOtpDialogState extends State<PhoneOtpDialog> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  late final Cooldown _resend;
  late final Cooldown _expiry;

  bool _isCodeSent = false;
  bool _isLoading = false;
  bool _hasExpiry = false;
  String? _phone; // gönderimde kullanılan normalleştirilmiş numara
  String? _phoneError;
  String? _error;
  String? _info;
  int? _remainingAttempts;

  @override
  void initState() {
    super.initState();
    final clock = context.read<AutomationState>().clock;
    _resend = Cooldown(clock, _refresh);
    _expiry = Cooldown(clock, _refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _resend.dispose();
    _expiry.dispose();
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _handleSendCode() async {
    if (_isLoading || _resend.isActive) return;
    final phoneError = AuthValidators.phoneError(_phoneController.text, required: true);
    if (phoneError != null) {
      setState(() => _phoneError = phoneError);
      return;
    }
    final phone = AuthValidators.normalizePhone(_phoneController.text)!;

    setState(() {
      _isLoading = true;
      _phoneError = null;
      _error = null;
      _info = null;
    });
    try {
      final state = context.read<AutomationState>();
      final CodeChallenge challenge = await state.sendPhoneOtp(phone);
      if (!mounted) return;
      setState(() {
        _isCodeSent = true;
        _phone = phone;
        _remainingAttempts = null;
        _codeController.clear();
        _info = challenge.message.isNotEmpty ? challenge.message : 'Doğrulama kodu gönderildi.';
      });
      _resend.start(challenge.resendAfter);
      final expiresIn = challenge.expiresIn;
      _hasExpiry = expiresIn != null;
      if (expiresIn != null) _expiry.start(expiresIn);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e, fallback: 'Kod gönderilemedi. Lütfen tekrar deneyin.'));
      if (e is ApiException && e.isRateLimited) {
        final wait = e.resendAfter ?? e.retryAfter;
        if (wait != null) _resend.start(wait);
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleVerifyCode() async {
    if (_isLoading) return;
    final code = _codeController.text.trim();
    final codeError = AuthValidators.sixDigitCodeError(code, emptyMessage: 'Lütfen 6 haneli doğrulama kodunu giriniz');
    if (codeError != null) {
      setState(() => _error = codeError);
      return;
    }
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      await context.read<AutomationState>().verifyPhoneOtp(_phone ?? '', code);
      if (!mounted) return;
      Navigator.of(context).pop(); // başarılı giriş: AuthGate paneli gösterir
    } catch (e) {
      if (!mounted) return;
      String text = friendlyError(e, fallback: 'Doğrulama tamamlanamadı. Lütfen tekrar deneyin.');
      int? remaining;
      if (e is ApiException) {
        remaining = e.remainingAttempts;
        if (e.isGone) {
          text = 'Kodun süresi dolmuş. Yeni bir kod isteyin.';
        } else if (e.isRateLimited) {
          final wait = e.retryAfter ?? e.resendAfter;
          text = 'Çok fazla hatalı deneme yapıldı. '
              '${wait == null ? 'Biraz bekleyip' : '${formatCountdown(wait.inSeconds)} sonra'} yeni kod isteyin.';
          if (wait != null) _resend.start(wait);
        }
      }
      setState(() {
        _error = remaining == null ? text : '$text Kalan deneme: $remaining.';
        _remainingAttempts = remaining;
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  InputDecoration _decoration(String label, String hint, IconData icon, Color accent, {String? errorText, String? counter}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      counterText: counter,
      errorText: errorText,
      errorMaxLines: 3,
      hintStyle: const TextStyle(color: AppTheme.textMuted, letterSpacing: 1),
      prefixIcon: Icon(icon, color: accent, size: 20),
      filled: true,
      fillColor: AppTheme.cardDark,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppTheme.cardBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: accent, width: 1.8),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final expiryText = _expiry.isActive
        ? 'Kod süresi: ${formatCountdown(_expiry.remainingSeconds)}'
        : (_hasExpiry ? 'Kodun süresi doldu' : '');
    return PopScope(
      canPop: !_isLoading,
      child: AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: AppTheme.cardBorder, width: 1.2),
        ),
        titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
        contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppTheme.primaryBlue.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.sms_rounded, color: AppTheme.primaryBlueLight, size: 24),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Şifresiz SMS Girişi',
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 18, fontWeight: FontWeight.bold),
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
              const SizedBox(height: 8),
              Text(
                !_isCodeSent
                    ? 'Telefon numaranızı girin, size 6 haneli tek kullanımlık doğrulama kodu gönderelim.'
                    : '${_info ?? 'Doğrulama kodu gönderildi.'} $_phone numarasına gelen 6 haneli kodu girin.',
                key: const Key('otp_info'),
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 18),
              TextField(
                key: const Key('field_phone'),
                controller: _phoneController,
                enabled: !_isCodeSent && !_isLoading,
                keyboardType: TextInputType.phone,
                autofillHints: const [AutofillHints.telephoneNumber],
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9+\-\s().]')),
                  LengthLimitingTextInputFormatter(20),
                ],
                onChanged: (_) {
                  if (_phoneError != null) setState(() => _phoneError = null);
                },
                onSubmitted: (_) => _handleSendCode(),
                style: const TextStyle(color: AppTheme.textPrimary, fontSize: 15),
                decoration: _decoration('Telefon Numarası', '0555 123 45 67', Icons.phone_iphone_rounded, AppTheme.primaryBlue,
                    errorText: _phoneError),
              ),
              if (_isCodeSent) ...[
                const SizedBox(height: 16),
                TextField(
                  key: const Key('field_code'),
                  controller: _codeController,
                  enabled: !_isLoading,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  textAlign: TextAlign.center,
                  autocorrect: false,
                  enableSuggestions: false,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                  onSubmitted: (_) => _handleVerifyCode(),
                  style: const TextStyle(color: AppTheme.textPrimary, fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: 8),
                  decoration: _decoration('Doğrulama Kodu', '••••••', Icons.pin_rounded, AppTheme.accentGreen, counter: ''),
                ),
                if (_remainingAttempts != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Kalan deneme hakkı: $_remainingAttempts',
                      key: const Key('otp_remaining_attempts'),
                      style: const TextStyle(fontSize: 12, color: AppTheme.accentAmber, fontWeight: FontWeight.w600),
                    ),
                  ),
                const SizedBox(height: 8),
                // Wrap: dar ekranda / büyük yazıda "Tekrar Kod İste" düğmesi alt satıra geçer (Row taşardı).
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    Text(
                      expiryText,
                      key: const Key('otp_expiry'),
                      style: TextStyle(
                        color: (_hasExpiry && !_expiry.isActive) ? AppTheme.accentRed : AppTheme.textMuted,
                        fontSize: 12,
                      ),
                    ),
                    TextButton(
                      key: const Key('btn_resend_code'),
                      onPressed: (_isLoading || _resend.isActive) ? null : () async {
                        // Yeni kod isteği: önceki kod girişi sıfırlanır, telefon aynı kalır.
                        setState(() => _isCodeSent = false);
                        await _handleSendCode();
                      },
                      style: TextButton.styleFrom(padding: EdgeInsets.zero),
                      child: Text(
                        _resend.isActive ? 'Tekrar Kod İste (${formatCountdown(_resend.remainingSeconds)})' : 'Tekrar Kod İste',
                        style: const TextStyle(color: AppTheme.primaryBlueLight, fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                InlineMessage.error(_error!, key: const Key('otp_error')),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const Key('btn_otp_cancel'),
            onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
            child: const Text('İptal', style: TextStyle(color: AppTheme.textMuted)),
          ),
          ElevatedButton(
            key: Key(_isCodeSent ? 'btn_otp_verify' : 'btn_otp_send'),
            onPressed: _isLoading ? null : (!_isCodeSent ? (_resend.isActive ? null : _handleSendCode) : _handleVerifyCode),
            style: ElevatedButton.styleFrom(
              backgroundColor: !_isCodeSent ? AppTheme.primaryBlue : AppTheme.accentGreen,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            ),
            child: _isLoading
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Text(!_isCodeSent ? 'Kod Gönder' : 'Giriş Yap', style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}
