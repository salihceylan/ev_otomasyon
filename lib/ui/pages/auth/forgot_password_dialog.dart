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
import 'magic_link_dialog.dart';

/// Şifre yenileme / hesap kurtarma diyaloğu (koyu giriş ekranı üzerinde).
///
/// 1. E-posta veya telefon (biçim doğrulanır) -> sunucu kod gönderir (hesap var olsun ya da olmasın
///    aynı genel yanıt: kullanıcı varlığı sızmaz).
/// 2. 6 haneli kod + yeni şifre (en az 10 karakter, kırpılmaz). Yeniden gönderme, sunucunun
///    `resend_after` süresi dolmadan kapalıdır; hatalı kodda kalan deneme hakkı gösterilir.
///
/// Sıfırlama sonrası mesaj dönen **duruma göre** verilir: sunucu oturum açtıysa "oturumunuz açıldı",
/// açmadıysa "yeni şifrenizle giriş yapın". Kod ekranda gösterilmez (geliştirme `debug_code` alanı dahil).
class ForgotPasswordDialog extends StatefulWidget {
  const ForgotPasswordDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const ForgotPasswordDialog(),
    );
  }

  @override
  State<ForgotPasswordDialog> createState() => _ForgotPasswordDialogState();
}

class _ForgotPasswordDialogState extends State<ForgotPasswordDialog> {
  final _identifierController = TextEditingController();
  final _codeController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  late final Cooldown _resend;
  late final Cooldown _expiry;

  bool _isCodeSent = false;
  bool _isLoading = false;
  bool _obscureNew = true;
  bool _obscureConfirm = true;
  String? _identifier; // gönderimde kullanılan, normalleştirilmiş kimlik
  String? _identifierError;
  String? _error;
  String? _info;
  int? _remainingAttempts;
  bool _hasExpiry = false;

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
    _identifierController.dispose();
    _codeController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _handleSendCode() async {
    if (_isLoading || _resend.isActive) return;
    final text = _identifierController.text;
    final identifierError = AuthValidators.identifierError(text);
    if (identifierError != null) {
      setState(() => _identifierError = identifierError);
      return;
    }
    final parsed = AuthValidators.parseIdentifier(text)!;

    setState(() {
      _isLoading = true;
      _identifierError = null;
      _error = null;
      _info = null;
    });
    try {
      final state = context.read<AutomationState>();
      final CodeChallenge challenge = await state.forgotPassword(parsed.value);
      if (!mounted) return;
      setState(() {
        _isCodeSent = true;
        _identifier = parsed.value;
        _remainingAttempts = null;
        _codeController.clear();
        // Sunucu genel bir ileti döndürür (hesap varlığını sızdırmaz); yoksa aynı nitelikte genel ileti.
        _info = challenge.message.isNotEmpty
            ? challenge.message
            : 'Bu hesap kayıtlıysa kurtarma kodu ve bağlantısı iletildi.';
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

  Future<void> _handleResetPassword() async {
    if (_isLoading) return;
    final code = _codeController.text.trim();
    // Şifreler KIRPILMAZ.
    final newPassword = _newPasswordController.text;
    final confirmPassword = _confirmPasswordController.text;

    final codeError = AuthValidators.sixDigitCodeError(code, emptyMessage: 'Lütfen 6 haneli kurtarma kodunu girin');
    final passwordError = AuthValidators.passwordPolicyError(newPassword, emptyMessage: 'Lütfen yeni şifrenizi girin');
    String? message = codeError ?? passwordError;
    if (message == null && newPassword != confirmPassword) message = 'Girdiğiniz şifreler birbiriyle uyuşmuyor';
    if (message != null) {
      setState(() => _error = message);
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });
    final state = context.read<AutomationState>();
    final messenger = ScaffoldMessenger.maybeOf(context);
    final navigator = Navigator.of(context, rootNavigator: true);
    try {
      await state.resetPassword(identifier: _identifier, code: code, newPassword: newPassword);
      if (!mounted) return;
      // Mesaj dönen duruma göre: sunucu oturum verdiyse giriş yapılmıştır.
      final loggedIn = state.isAuthenticated;
      navigator.pop();
      messenger?.showSnackBar(
        SnackBar(
          content: Text(loggedIn
              ? 'Şifreniz yenilendi ve oturumunuz açıldı.'
              : 'Şifreniz yenilendi. Yeni şifrenizle giriş yapabilirsiniz.'),
          backgroundColor: AppTheme.accentGreen,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      String text = friendlyError(e, fallback: 'Şifre sıfırlanamadı. Lütfen tekrar deneyin.');
      int? remaining;
      if (e is ApiException) {
        remaining = e.remainingAttempts;
        if (e.isGone) {
          text = 'Kodun süresi dolmuş veya kullanılmış. Yeni bir kod isteyin.';
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

  InputDecoration _decoration({
    required String label,
    required IconData icon,
    String? hint,
    String? errorText,
    Widget? suffix,
    String? counter,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      counterText: counter,
      errorText: errorText,
      errorMaxLines: 3,
      labelStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
      hintStyle: TextStyle(color: AppTheme.textMuted.withValues(alpha: 0.5)),
      prefixIcon: Icon(icon, color: AppTheme.primaryBlueLight),
      suffixIcon: suffix,
      filled: true,
      fillColor: AppTheme.bgDark,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: AppTheme.primaryBlue.withValues(alpha: 0.2)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: AppTheme.primaryBlue.withValues(alpha: 0.2)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppTheme.primaryBlueLight, width: 1.5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isLoading,
      child: Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 440),
          decoration: BoxDecoration(
            color: AppTheme.surfaceDark,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppTheme.primaryBlue.withValues(alpha: 0.3)),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 28, offset: const Offset(0, 10)),
            ],
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryBlue.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(Icons.lock_reset_rounded, color: AppTheme.primaryBlueLight, size: 26),
                    ),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Şifre Yenileme',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
                            overflow: TextOverflow.ellipsis,
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Hesap kurtarma',
                            style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                if (!_isCodeSent) ..._buildStepOne() else ..._buildStepTwo(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildStepOne() {
    return [
      Text(
        'Hesabınıza kayıtlı e-posta adresinizi veya telefon numaranızı girin. Hesap kayıtlıysa size 6 haneli '
        'tek kullanımlık bir kurtarma kodu ileteceğiz.',
        style: TextStyle(fontSize: 13, color: AppTheme.textMuted.withValues(alpha: 0.9), height: 1.4),
      ),
      const SizedBox(height: 18),
      TextField(
        key: const Key('field_identifier'),
        controller: _identifierController,
        enabled: !_isLoading,
        keyboardType: TextInputType.emailAddress,
        autocorrect: false,
        enableSuggestions: false,
        onSubmitted: (_) => _handleSendCode(),
        onChanged: (_) {
          if (_identifierError != null) setState(() => _identifierError = null);
        },
        style: const TextStyle(color: AppTheme.textPrimary),
        decoration: _decoration(
          label: 'E-posta veya Telefon',
          icon: Icons.person_outline_rounded,
          hint: 'ornek@ahbu.com veya 0555 123 45 67',
          errorText: _identifierError,
        ),
      ),
      if (_error != null) ...[
        const SizedBox(height: 12),
        InlineMessage.error(_error!, key: const Key('forgot_error')),
      ],
      const SizedBox(height: 10),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          key: const Key('btn_have_link'),
          onPressed: _isLoading ? null : () => MagicLinkDialog.show(context),
          child: const Text('E-postadaki bağlantım var', style: TextStyle(fontSize: 12.5, color: AppTheme.primaryBlueLight)),
        ),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: TextButton(
              key: const Key('btn_forgot_cancel'),
              onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 13)),
              child: const Text('İptal', style: TextStyle(color: AppTheme.textMuted)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: ElevatedButton(
              key: const Key('btn_send_code'),
              onPressed: (_isLoading || _resend.isActive) ? null : _handleSendCode,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryBlue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: _isLoading
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Text(
                      _resend.isActive ? 'Bekleyin (${formatCountdown(_resend.remainingSeconds)})' : 'Kod Gönder',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _buildStepTwo() {
    final expiryText = _expiry.isActive
        ? 'Kod geçerlilik süresi: ${formatCountdown(_expiry.remainingSeconds)}'
        : (_hasExpiry ? 'Kodun süresi dolmuş olabilir; gerekirse yeni kod isteyin.' : '');
    return [
      Text(
        _info ?? 'Kurtarma kodunu ve yeni şifrenizi girin.',
        key: const Key('forgot_info'),
        style: TextStyle(fontSize: 13, color: AppTheme.textMuted.withValues(alpha: 0.9), height: 1.4),
      ),
      const SizedBox(height: 4),
      Text(
        '$_identifier adresine/numarasına gönderilen 6 haneli kodu girin.',
        style: TextStyle(fontSize: 12, color: AppTheme.textMuted.withValues(alpha: 0.8), height: 1.4),
      ),
      const SizedBox(height: 14),
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
        style: const TextStyle(color: AppTheme.textPrimary, fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: 8),
        decoration: _decoration(
          label: '6 Haneli Kurtarma Kodu',
          icon: Icons.pin_rounded,
          hint: '000000',
          counter: '',
        ),
      ),
      if (_remainingAttempts != null) ...[
        const SizedBox(height: 4),
        Text(
          'Kalan deneme hakkı: $_remainingAttempts',
          key: const Key('forgot_remaining_attempts'),
          style: const TextStyle(fontSize: 12, color: AppTheme.accentAmber, fontWeight: FontWeight.w600),
        ),
      ],
      const SizedBox(height: 10),
      TextField(
        key: const Key('field_new_password'),
        controller: _newPasswordController,
        enabled: !_isLoading,
        obscureText: _obscureNew,
        autocorrect: false,
        enableSuggestions: false,
        style: const TextStyle(color: AppTheme.textPrimary),
        decoration: _decoration(
          label: 'Yeni Şifre (En az ${AuthValidators.passwordMinLength} karakter)',
          icon: Icons.lock_outline_rounded,
          suffix: IconButton(
            tooltip: _obscureNew ? 'Şifreyi göster' : 'Şifreyi gizle',
            icon: Icon(_obscureNew ? Icons.visibility_off_outlined : Icons.visibility_outlined, color: AppTheme.textMuted, size: 20),
            onPressed: () => setState(() => _obscureNew = !_obscureNew),
          ),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        key: const Key('field_confirm_password'),
        controller: _confirmPasswordController,
        enabled: !_isLoading,
        obscureText: _obscureConfirm,
        autocorrect: false,
        enableSuggestions: false,
        style: const TextStyle(color: AppTheme.textPrimary),
        decoration: _decoration(
          label: 'Yeni Şifre Tekrar',
          icon: Icons.lock_clock_outlined,
          suffix: IconButton(
            tooltip: _obscureConfirm ? 'Şifreyi göster' : 'Şifreyi gizle',
            icon: Icon(_obscureConfirm ? Icons.visibility_off_outlined : Icons.visibility_outlined, color: AppTheme.textMuted, size: 20),
            onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
          ),
        ),
      ),
      const SizedBox(height: 12),
      const InlineMessage.warning(
        'Şifreniz yenilendiğinde diğer tüm cihazlardaki açık oturumlar otomatik kapatılır.',
        key: Key('forgot_security_notice'),
      ),
      if (_error != null) ...[
        const SizedBox(height: 12),
        InlineMessage.error(_error!, key: const Key('forgot_error')),
      ],
      const SizedBox(height: 12),
      Center(
        child: Column(
          children: [
            if (expiryText.isNotEmpty)
              Text(
                expiryText,
                key: const Key('forgot_expiry'),
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.accentAmber),
                textAlign: TextAlign.center,
              ),
            TextButton(
              key: const Key('btn_resend_code'),
              onPressed: (_isLoading || _resend.isActive) ? null : _handleSendCode,
              child: Text(
                _resend.isActive ? 'Kodu Tekrar Gönder (${formatCountdown(_resend.remainingSeconds)})' : 'Kodu Tekrar Gönder',
                style: const TextStyle(color: AppTheme.primaryBlueLight, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: TextButton(
              key: const Key('btn_forgot_back'),
              onPressed: _isLoading ? null : () => setState(() {
                    _isCodeSent = false;
                    _error = null;
                  }),
              style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 13)),
              child: const Text('Geri', style: TextStyle(color: AppTheme.textMuted)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: ElevatedButton(
              key: const Key('btn_reset_password'),
              onPressed: _isLoading ? null : _handleResetPassword,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accentGreen,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: _isLoading
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Şifreyi Yenile', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    ];
  }
}
