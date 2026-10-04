import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../models/api_models.dart';
import '../../../services/automation_state.dart';
import '../../../utils/friendly_error.dart';
import '../../common/auth_form.dart';
import '../../common/confirm_dialogs.dart' show AuthDialogActions, AuthDialogShell, authPrimaryLabel, authSecondaryLabel;
import '../../common/cooldown.dart';
import '../../common/date_format.dart';
import '../../common/inline_message.dart';
import '../../common/validators.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
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
///
/// Kimlik (biçimden) telefon numarasıysa, yalnız telefonla açılmış hesaplara kod gönderilemeyeceği ipucu gösterilir
/// (UYELIK-08). İpucu yalnız kimlik TÜRÜNE bağlıdır, sunucu yanıtına değil: hesap varlığı sızmaz.
///
/// Görünüm: auth/onay akışının ORTAK diyalog kabuğu ([AuthDialogShell]); eylem satırı gövdeyle kaydırılmaz.
class ForgotPasswordDialog extends StatefulWidget {
  const ForgotPasswordDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog(context: context, barrierDismissible: false, builder: (_) => const ForgotPasswordDialog());
  }

  @override
  State<ForgotPasswordDialog> createState() => _ForgotPasswordDialogState();
}

class _ForgotPasswordDialogState extends State<ForgotPasswordDialog> {
  /// Telefon kimliği ipucu (UYELIK-08): telefon-OTP hesabının parolası yoktur, e-postası sunucunun teknik yer
  /// tutucusudur; sunucu genel "gönderildi" yanıtı verse de kod hiçbir kanala ulaşmaz.
  static const String _phoneOnlyHint =
      'Yalnızca telefonla açılmış hesapların şifresi ve e-postası yoktur; bu hesaplara sıfırlama kodu gönderilemez.';

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

  /// Kimlik alanındaki değer (yalnız BİÇİMDEN) telefon numarası mı: ipucu bunun için gösterilir.
  bool _identifierIsPhone = false;
  String? _error;

  /// `true`: [_error] KOD alanıyla ilgilidir (eksik/hatalı/süresi dolmuş kod): alan kırmızı çizilir ve ileti alanın
  /// hemen altında durur. Şifre politikası/uyuşmazlık/ağ hataları formun sonundaki ileti yerinde kalır.
  bool _codeError = false;
  String? _info;
  bool _hasExpiry = false;

  @override
  void initState() {
    super.initState();
    final clock = context.read<AutomationState>().clock;
    // PF-23: tikler diyaloğu kurmaz; geri sayım metinleri `remaining` ile yalnız küçük builder'larda güncellenir,
    // düğme kilidi başlangıç/bitişte `_refresh` ile yeniden kurulur.
    _resend = Cooldown(clock, _refresh, notifyOnTick: false);
    _expiry = Cooldown(clock, _refresh, notifyOnTick: false);
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
      _codeError = false;
      _info = null;
    });
    try {
      final state = context.read<AutomationState>();
      final CodeChallenge challenge = await state.forgotPassword(parsed.value);
      if (!mounted) return;
      setState(() {
        _isCodeSent = true;
        _identifier = parsed.value;
        _codeController.clear();
        // Sunucu genel bir ileti döndürür (hesap varlığını sızdırmaz); yoksa aynı nitelikte genel ileti.
        _info = challenge.message.isNotEmpty ? challenge.message : 'Bu hesap kayıtlıysa kurtarma kodu ve bağlantısı iletildi.';
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
      setState(() {
        _error = message;
        _codeError = codeError != null;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
      _codeError = false;
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
          content: Text(
            loggedIn ? 'Şifreniz yenilendi ve oturumunuz açıldı.' : 'Şifreniz yenilendi. Yeni şifrenizle giriş yapabilirsiniz.',
          ),
          // Beyaz iletiyle AA (ham #10B981 ile ~2.5:1'di).
          backgroundColor: AppTheme.filledAccent(AppTheme.accentGreen),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      String text = friendlyError(e, fallback: 'Şifre sıfırlanamadı. Lütfen tekrar deneyin.');
      int? remaining;
      var codeRelated = false;
      if (e is ApiException) {
        remaining = e.remainingAttempts;
        // Kod sorunları (hatalı kod + kalan hak, süresi dolmuş/kullanılmış, deneme hakkı bitti) kod alanına aittir.
        codeRelated = remaining != null || e.isGone || e.isRateLimited;
        if (e.isGone) {
          text = 'Kodun süresi dolmuş veya kullanılmış. Yeni bir kod isteyin.';
        } else if (e.isRateLimited) {
          final wait = e.retryAfter ?? e.resendAfter;
          text =
              'Çok fazla hatalı deneme yapıldı. '
              '${wait == null ? 'Biraz bekleyip' : '${formatCountdown(wait.inSeconds)} sonra'} yeni kod isteyin.';
          if (wait != null) _resend.start(wait);
        }
      }
      // Kalan hak TEK yerde: iletinin içinde (bölünmeyen boşlukla; "2." yetim kalmaz). Alan altında ikinci satır yok.
      setState(() {
        _error = remaining == null ? text : '$text ${remainingAttemptsText(remaining)}';
        _codeError = codeRelated;
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isLoading,
      child: AuthDialogShell(
        icon: Icons.lock_reset_rounded,
        family: AppFamilies.sky,
        title: 'Şifre Yenileme',
        subtitle: 'Hesap kurtarma',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: !_isCodeSent ? _buildStepOne() : _buildStepTwo(),
        ),
        actions: !_isCodeSent ? _buildStepOneActions() : _buildStepTwoActions(),
      ),
    );
  }

  List<Widget> _buildStepOne() {
    return [
      Text(
        'Hesabınıza kayıtlı e-posta adresinizi veya telefon numaranızı girin. Hesap kayıtlıysa size 6 haneli '
        'tek kullanımlık bir kurtarma kodu ileteceğiz.',
        style: TextStyle(fontSize: 13, color: AppTheme.getTextMuted(context), height: 1.4),
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
        onChanged: (text) {
          // Yalnız değişince yeniden kurulur (her tuşta değil): hata temizlenir / telefon ipucu açılır-kapanır.
          final isPhone = AuthValidators.parseIdentifier(text)?.isPhone ?? false;
          if (_identifierError != null || isPhone != _identifierIsPhone) {
            setState(() {
              _identifierError = null;
              _identifierIsPhone = isPhone;
            });
          }
        },
        style: TextStyle(color: AppTheme.getTextPrimary(context)),
        decoration: authInputDecoration(
          context,
          label: 'E-posta veya Telefon',
          prefixIcon: Icons.person_outline_rounded,
          hint: 'ornek@ahbu.com veya 0555 123 45 67',
          errorText: _identifierError,
        ),
      ),
      if (_identifierIsPhone) ...[
        const SizedBox(height: 12),
        const InlineMessage.info(_phoneOnlyHint, key: Key('forgot_phone_hint')),
      ],
      if (_error != null) ...[const SizedBox(height: 12), InlineMessage.error(_error!, key: const Key('forgot_error'))],
      const SizedBox(height: 4),
      // Bağlantı gövde metniyle AYNI sol hizada (iç boşluk yok), hedef >= 48 dp.
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          key: const Key('btn_have_link'),
          onPressed: _isLoading ? null : () => MagicLinkDialog.show(context),
          style: TextButton.styleFrom(padding: EdgeInsets.zero, alignment: Alignment.centerLeft, minimumSize: const Size(48, 48)),
          child: Text(
            'E-postadaki bağlantım var',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.infoText(context)),
          ),
        ),
      ),
    ];
  }

  Widget _buildStepOneActions() {
    return AuthDialogActions(
      secondaryLabel: 'İptal',
      secondary: TextButton(
        key: const Key('btn_forgot_cancel'),
        onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
        child: authSecondaryLabel(context, 'İptal'),
      ),
      // Ölçüm: bekleme etiketi ("Bekleyin (10:00)") en uzunudur; düzen geri sayımda sıçramaz.
      primaryLabel: 'Bekleyin (10:00)',
      primary: ElevatedButton(
        key: const Key('btn_send_code'),
        onPressed: (_isLoading || _resend.isActive) ? null : _handleSendCode,
        child: _isLoading
            ? buttonSpinner()
            : ValueListenableBuilder<int>(
                valueListenable: _resend.remaining,
                builder: (context, seconds, _) => authPrimaryLabel(
                  seconds > 0 ? 'Bekleyin (${formatCountdown(seconds)})' : 'Kod Gönder',
                  // Bekleme: kalan süre kullanıcının TEK bilgisi; pasif düğmenin soluk ön planı (≈3.4:1) yerine tam soluk metin (≥ 6:1).
                  color: seconds > 0 ? AppTheme.getTextMuted(context) : null,
                ),
              ),
      ),
    );
  }

  List<Widget> _buildStepTwo() {
    final muted = AppTheme.getTextMuted(context);
    final primary = AppTheme.getTextPrimary(context);
    // Hata iletisi: kod hatasıysa kod alanının HEMEN altında (alan kırmızı çizilir), değilse (şifre politikası,
    // uyuşmazlık, ağ) formun sonunda. Aynı anda tek ileti vardır; anahtar aynıdır.
    final errorBox = _error == null ? null : InlineMessage.error(_error!, key: const Key('forgot_error'));
    final codeScoped = errorBox != null && _codeError;
    // Kod telefon kimliğiyle istendiyse ipucu burada da kalır (sunucunun genel "gönderildi" iletisinin altında).
    final sentToPhone = AuthValidators.parseIdentifier(_identifier)?.isPhone ?? false;
    return [
      Text(
        _info ?? 'Kurtarma kodunu ve yeni şifrenizi girin.',
        key: const Key('forgot_info'),
        style: TextStyle(fontSize: 13, color: muted, height: 1.4),
      ),
      const SizedBox(height: 4),
      Text(
        '$_identifier adresine/numarasına gönderilen 6 haneli kodu girin.',
        style: TextStyle(fontSize: 12, color: muted, height: 1.4),
      ),
      if (sentToPhone) ...[
        const SizedBox(height: 12),
        const InlineMessage.info(_phoneOnlyHint, key: Key('forgot_phone_hint')),
      ],
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
        style: authCodeTextStyle(context),
        decoration: authCodeInputDecoration(context, label: '6 Haneli Kurtarma Kodu', hint: '000000', hasError: codeScoped),
      ),
      if (codeScoped) ...[const SizedBox(height: 8), errorBox],
      const SizedBox(height: 14),
      TextField(
        key: const Key('field_new_password'),
        controller: _newPasswordController,
        enabled: !_isLoading,
        obscureText: _obscureNew,
        autocorrect: false,
        enableSuggestions: false,
        style: TextStyle(color: primary),
        decoration: authInputDecoration(
          context,
          label: 'Yeni Şifre',
          helper: 'En az ${AuthValidators.passwordMinLength} karakter',
          prefixIcon: Icons.lock_outline_rounded,
          suffixIcon: passwordVisibilityButton(
            context: context,
            obscured: _obscureNew,
            onToggle: () => setState(() => _obscureNew = !_obscureNew),
          ),
        ),
      ),
      const SizedBox(height: 14),
      TextField(
        key: const Key('field_confirm_password'),
        controller: _confirmPasswordController,
        enabled: !_isLoading,
        obscureText: _obscureConfirm,
        autocorrect: false,
        enableSuggestions: false,
        style: TextStyle(color: primary),
        decoration: authInputDecoration(
          context,
          label: 'Yeni Şifre Tekrar',
          prefixIcon: Icons.verified_user_outlined,
          suffixIcon: passwordVisibilityButton(
            context: context,
            obscured: _obscureConfirm,
            onToggle: () => setState(() => _obscureConfirm = !_obscureConfirm),
          ),
        ),
      ),
      const SizedBox(height: 14),
      const InlineMessage.warning(
        'Şifreniz yenilendiğinde diğer tüm cihazlardaki açık oturumlar otomatik kapatılır.',
        key: Key('forgot_security_notice'),
      ),
      if (errorBox != null && !codeScoped) ...[const SizedBox(height: 12), errorBox],
      const SizedBox(height: 8),
      Center(
        child: Column(
          children: [
            ValueListenableBuilder<int>(
              valueListenable: _expiry.remaining,
              builder: (context, seconds, _) {
                final text = seconds > 0
                    ? 'Kod geçerlilik süresi: ${formatCountdown(seconds)}'
                    : (_hasExpiry ? 'Kodun süresi dolmuş olabilir; gerekirse yeni kod isteyin.' : '');
                if (text.isEmpty) return const SizedBox.shrink();
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (seconds > 0) ...[
                      CooldownArc(remaining: _expiry.remaining, color: AppTheme.warningText(context)),
                      const SizedBox(width: 8),
                    ],
                    Flexible(
                      child: Text(
                        text,
                        key: const Key('forgot_expiry'),
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.warningText(context)),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                );
              },
            ),
            TextButton(
              key: const Key('btn_resend_code'),
              onPressed: (_isLoading || _resend.isActive) ? null : _handleSendCode,
              child: ValueListenableBuilder<int>(
                valueListenable: _resend.remaining,
                builder: (context, seconds, _) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (seconds > 0) ...[CooldownArc(remaining: _resend.remaining, color: muted), const SizedBox(width: 6)],
                    Flexible(
                      child: Text(
                        seconds > 0 ? 'Kodu Tekrar Gönder (${formatCountdown(seconds)})' : 'Kodu Tekrar Gönder',
                        // Bekleme sürerken düğme pasif: bağlantı rengi değil soluk metin (çelişkili sinyal yok).
                        style: TextStyle(color: seconds > 0 ? muted : AppTheme.infoText(context), fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ];
  }

  Widget _buildStepTwoActions() {
    return AuthDialogActions(
      secondaryLabel: 'Geri',
      secondary: TextButton(
        key: const Key('btn_forgot_back'),
        onPressed: _isLoading
            ? null
            : () => setState(() {
                _isCodeSent = false;
                _error = null;
                _codeError = false;
              }),
        child: authSecondaryLabel(context, 'Geri'),
      ),
      primaryLabel: 'Şifreyi Yenile',
      primary: ElevatedButton(
        key: const Key('btn_reset_password'),
        onPressed: _isLoading ? null : _handleResetPassword,
        child: _isLoading ? buttonSpinner() : authPrimaryLabel('Şifreyi Yenile'),
      ),
    );
  }
}
